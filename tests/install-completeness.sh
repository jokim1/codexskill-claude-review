#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/claude-install-completeness-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok: %s\n' "$1"
}

disable_homebrew_paths() {
  local locator="$1"
  local replacement="$2"

  python3 - "$locator" "$replacement" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
for original in (
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    "/home/linuxbrew/.linuxbrew/bin/claude",
):
    text = text.replace(original, sys.argv[2])
path.write_text(text)
PY
}

for helper in scripts/claude-locator.sh scripts/claude-runtime.sh; do
  [ -r "$ROOT/$helper" ] || fail "$helper is not readable"
  [ -x "$ROOT/$helper" ] || fail "$helper is not executable"
  case "$helper" in
    *locator*) tail -n 1 "$ROOT/$helper" | grep -Fqx '# claude-review-helper-complete: locator_v1' || fail "$helper marker" ;;
    *runtime*) tail -n 1 "$ROOT/$helper" | grep -Fqx '# claude-review-helper-complete: runtime_v1' || fail "$helper marker" ;;
  esac
  if git -C "$ROOT" ls-files --error-unmatch "$helper" >/dev/null 2>&1; then
    mode="$(git -C "$ROOT" ls-files -s "$helper" | awk '{print $1}')"
    [ "$mode" = "100755" ] || fail "$helper tracked mode is $mode, expected 100755"
  elif [ "${CI:-false}" = "true" ] || [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
    fail "$helper is not tracked in the clean CI checkout"
  else
    git -C "$ROOT" check-ignore -q "$helper" && fail "$helper is ignored before commit"
  fi
done
pass "new helpers are complete and CI-trackable with executable modes"

git -C "$ROOT" check-ignore -q docs/local-plans/completeness-probe.md || fail "docs/local-plans is not ignored"
if git -C "$ROOT" ls-files --error-unmatch docs/local-plans/CLAUDE_DISCOVERY_AND_DOCTOR_RECOVERY_PLAN.md >/dev/null 2>&1; then
  fail "local plan is tracked"
fi
pass "local implementation plans remain ignored and unpackaged"

if grep -n 'claude-subscription-env' "$ROOT/scripts/run-review.sh" "$ROOT/scripts/claude-doctor.sh" >/dev/null; then
  fail "runner or doctor still references the compatibility helper"
fi
[ -x "$ROOT/scripts/claude-subscription-env.sh" ] || fail "compatibility helper missing"
pass "production callers migrated while compatibility entry point remains"

# Exercise runner and doctor bootstrap from the tested checkout without executing
# a real Claude installation.
bootstrap_skill="$TEST_ROOT/bootstrap-skill"
bootstrap_tools="$TEST_ROOT/bootstrap-tools"
mkdir -p "$TEST_ROOT/home" "$bootstrap_skill/scripts" "$bootstrap_tools"
cp "$ROOT"/scripts/*.sh "$bootstrap_skill/scripts/"
chmod 755 "$bootstrap_skill"/scripts/*.sh
disable_homebrew_paths "$bootstrap_skill/scripts/claude-locator.sh" "$TEST_ROOT/disabled-homebrew/claude"
for tool_name in awk basename chmod cut dirname git grep head id mktemp python3 pwd readlink rm sed sort stat tail tr uname wc; do
  tool_path="$(type -P "$tool_name" 2>/dev/null || true)"
  [ -n "$tool_path" ] || fail "bootstrap tool unavailable: $tool_name"
  ln -s "$tool_path" "$bootstrap_tools/$tool_name"
done
doctor_output="$({
  cd "$ROOT"
  HOME="$TEST_ROOT/home" PATH="$bootstrap_tools" \
    /bin/bash "$bootstrap_skill/scripts/claude-doctor.sh" \
      --repo-root "$ROOT" \
      --skill-root "$bootstrap_skill" \
      --config-file "$ROOT/.codex/claude/config.env" \
      --skip-probes \
      --skip-update-check
})"
printf '%s\n' "$doctor_output" | grep -Fqx 'doctor_status=ok' || fail "doctor bootstrap from checkout"
printf '%s\n' "$doctor_output" | grep -Fqx 'claude_runtime_contract=direct_inherited_path_v1' || fail "doctor runtime helper bootstrap"

printf 'artifact\n' > "$TEST_ROOT/claude-review-artifact.txt"
runner_output="$({
  cd "$ROOT"
  HOME="$TEST_ROOT/home" PATH="$bootstrap_tools" \
    /bin/bash "$bootstrap_skill/scripts/run-review.sh" \
      --mode code \
      --artifact-file "$TEST_ROOT/claude-review-artifact.txt" \
      --base-prompt "$ROOT/prompts/code-review.base.md" \
      --schema-file "$ROOT/schemas/review-output.json" \
      --repo-root "$ROOT"
})"
RUNNER_OUTPUT="$runner_output" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["RUNNER_OUTPUT"])
assert data["status"] == "blocked"
assert "installation is incomplete" not in data["summary"]
PY
pass "runner and doctor bootstrap both helpers from the tested checkout"

# Simulate the whole-tree Git fast-forward used by the updater: an installed
# checkout at commit one receives both helpers from commit two without a manifest.
source_repo="$TEST_ROOT/source-repo"
installed_repo="$TEST_ROOT/installed-repo"
mkdir -p "$source_repo/scripts"
git -C "$source_repo" init -q
git -C "$source_repo" config user.name "Claude Review Test"
git -C "$source_repo" config user.email "claude-review-test@example.invalid"
printf 'base\n' > "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit -qm "base"
git clone -q "$source_repo" "$installed_repo"
cp "$ROOT/scripts/claude-locator.sh" "$source_repo/scripts/claude-locator.sh"
cp "$ROOT/scripts/claude-runtime.sh" "$source_repo/scripts/claude-runtime.sh"
chmod 755 "$source_repo/scripts/claude-locator.sh" "$source_repo/scripts/claude-runtime.sh"
git -C "$source_repo" add scripts/claude-locator.sh scripts/claude-runtime.sh
git -C "$source_repo" commit -qm "add runtime helpers"
git -C "$installed_repo" fetch -q origin
branch="$(git -C "$source_repo" branch --show-current)"
git -C "$installed_repo" merge --ff-only -q "origin/$branch"
[ -x "$installed_repo/scripts/claude-locator.sh" ] || fail "fast-forward omitted locator"
[ -x "$installed_repo/scripts/claude-runtime.sh" ] || fail "fast-forward omitted runtime"
pass "simulated updater fast-forward installs both helpers"
