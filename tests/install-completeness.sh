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

if rg -n 'claude-subscription-env' "$ROOT/scripts/run-review.sh" "$ROOT/scripts/claude-doctor.sh" >/dev/null; then
  fail "runner or doctor still references the compatibility helper"
fi
[ -x "$ROOT/scripts/claude-subscription-env.sh" ] || fail "compatibility helper missing"
pass "production callers migrated while compatibility entry point remains"

# Exercise runner and doctor bootstrap from the tested checkout without executing
# a real Claude installation.
mkdir -p "$TEST_ROOT/home"
doctor_output="$({
  cd "$ROOT"
  HOME="$TEST_ROOT/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash scripts/claude-doctor.sh \
      --repo-root "$ROOT" \
      --skill-root "$ROOT" \
      --config-file "$ROOT/.codex/claude/config.env" \
      --skip-probes \
      --skip-update-check
})"
printf '%s\n' "$doctor_output" | grep -Fqx 'doctor_status=ok' || fail "doctor bootstrap from checkout"
printf '%s\n' "$doctor_output" | grep -Fqx 'claude_runtime_contract=direct_inherited_path_v1' || fail "doctor runtime helper bootstrap"

printf 'artifact\n' > "$TEST_ROOT/claude-review-artifact.txt"
runner_output="$({
  cd "$ROOT"
  HOME="$TEST_ROOT/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash scripts/run-review.sh \
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
