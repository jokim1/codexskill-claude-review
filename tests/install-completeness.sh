#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/claude-install-completeness-XXXXXX)"
TRUSTED_PYTHON_TOOLS="$(mktemp -d "$HOME/.claude-review-bootstrap-python-XXXXXX")"
trap 'rm -rf "$TEST_ROOT" "$TRUSTED_PYTHON_TOOLS"' EXIT

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

for helper in scripts/claude-config.sh scripts/claude-locator.sh scripts/claude-runtime.sh; do
  [ -r "$ROOT/$helper" ] || fail "$helper is not readable"
  [ -x "$ROOT/$helper" ] || fail "$helper is not executable"
  case "$helper" in
    *config*) tail -n 1 "$ROOT/$helper" | grep -Fqx '# claude-review-helper-complete: config_v1' || fail "$helper marker" ;;
    *locator*) tail -n 1 "$ROOT/$helper" | grep -Fqx '# claude-review-helper-complete: locator_v3' || fail "$helper marker" ;;
    *runtime*) tail -n 1 "$ROOT/$helper" | grep -Fqx '# claude-review-helper-complete: runtime_v3' || fail "$helper marker" ;;
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
for runtime_symbol in \
  claude_runtime_resolve_trusted_python \
  claude_runtime_is_native_executable \
  claude_runtime_write_python_driver \
  claude_runtime_python_transport_path \
  claude_runtime_run_with_timeout \
  claude_runtime_probe_with_timeout; do
  grep -Fq "${runtime_symbol}()" "$ROOT/scripts/claude-runtime.sh" || fail "runtime helper missing $runtime_symbol"
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

for guarded_script in "$ROOT/scripts/run-review.sh" "$ROOT/scripts/claude-doctor.sh"; do
  set +e
  unprivileged_output="$(BASH_ENV= ENV= /bin/bash --noprofile --norc "$guarded_script" --help 2>&1)"
  unprivileged_status=$?
  set -e
  [ "$unprivileged_status" -eq 2 ] || fail "$(basename "$guarded_script") accepted non-privileged Bash"
  printf '%s\n' "$unprivileged_output" | grep -Fq 'requires Bash privileged mode before line 1' || \
    fail "$(basename "$guarded_script") omitted privileged-mode guidance"

  function_marker="$TEST_ROOT/$(basename "$guarded_script").imported-function"
  GUARDED_SCRIPT="$guarded_script" FUNCTION_MARKER="$function_marker" \
    /bin/bash --noprofile --norc -c '
cat() { builtin printf cat > "$FUNCTION_MARKER"; }
type() { builtin printf type > "$FUNCTION_MARKER"; builtin type "$@"; }
export -f cat type
BASH_ENV= ENV= /bin/bash --noprofile --norc -p "$GUARDED_SCRIPT" --help >/dev/null
'
  [ ! -e "$function_marker" ] || fail "$(basename "$guarded_script") imported an exported Bash function"
done
pass "runner and doctor require privileged Bash and ignore exported functions"

# Exercise runner and doctor bootstrap from the tested checkout without executing
# a real Claude installation.
bootstrap_skill="$TEST_ROOT/bootstrap-skill"
bootstrap_tools="$TEST_ROOT/bootstrap-tools"
mkdir -p "$TEST_ROOT/home" "$bootstrap_skill/scripts" "$bootstrap_tools"
cp "$ROOT"/scripts/*.sh "$bootstrap_skill/scripts/"
chmod 755 "$bootstrap_skill"/scripts/*.sh
disable_homebrew_paths "$bootstrap_skill/scripts/claude-locator.sh" "$TEST_ROOT/disabled-homebrew/claude"
for tool_name in awk basename chmod cut dirname git grep head id mktemp pwd readlink rm sed sort stat tail tr uname wc; do
  tool_path="$(type -P "$tool_name" 2>/dev/null || true)"
  [ -n "$tool_path" ] || fail "bootstrap tool unavailable: $tool_name"
  ln -s "$tool_path" "$bootstrap_tools/$tool_name"
done
python_path="$(type -P python3 2>/dev/null || true)"
[ -n "$python_path" ] || fail "bootstrap tool unavailable: python3"
ln -s "$python_path" "$TRUSTED_PYTHON_TOOLS/python3"
doctor_output="$({
  cd "$ROOT"
  HOME="$TEST_ROOT/home" PATH="$TRUSTED_PYTHON_TOOLS:$bootstrap_tools" \
    BASH_ENV= ENV= /bin/bash --noprofile --norc -p "$bootstrap_skill/scripts/claude-doctor.sh" \
      --repo-root "$ROOT" \
      --skill-root "$bootstrap_skill" \
      --config-file "$ROOT/.codex/claude/config.env" \
      --skip-probes \
      --skip-update-check
})"
printf '%s\n' "$doctor_output" | grep -Fqx 'doctor_status=ok' || fail "doctor bootstrap from checkout"
printf '%s\n' "$doctor_output" | grep -Fqx 'claude_runtime_contract=direct_inherited_path_v3' || fail "doctor runtime helper bootstrap"
printf '%s\n' "$doctor_output" | grep -Fqx 'python_runtime_status=safe' || fail "doctor trusted Python bootstrap"

printf 'artifact\n' > "$TEST_ROOT/claude-review-artifact.txt"
runner_output="$({
  cd "$ROOT"
  HOME="$TEST_ROOT/home" PATH="$TRUSTED_PYTHON_TOOLS:$bootstrap_tools" \
    BASH_ENV= ENV= /bin/bash --noprofile --norc -p "$bootstrap_skill/scripts/run-review.sh" \
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

# Establishing readlink trust must not execute a symlinked candidate to inspect
# its own target. Both entry points reject the candidate before it can create the
# marker outside the simulated fixed-FHS roots.
readlink_anchor_root="$TEST_ROOT/readlink-anchor"
readlink_anchor_usr="$readlink_anchor_root/usr/bin"
readlink_anchor_bin="$readlink_anchor_root/bin"
readlink_anchor_external="$readlink_anchor_root/external-readlink"
readlink_anchor_marker="$readlink_anchor_root/executed"
mkdir -p "$readlink_anchor_usr" "$readlink_anchor_bin"
cat > "$readlink_anchor_external" <<SH
#!/bin/bash
printf executed > "$readlink_anchor_marker"
exit 1
SH
chmod 755 "$readlink_anchor_external"
ln -s "$readlink_anchor_external" "$readlink_anchor_usr/readlink"
for bootstrap_script in "$ROOT/scripts/run-review.sh" "$ROOT/scripts/claude-doctor.sh"; do
  if (
    eval "$(sed -n '/^claude_bootstrap_fhs_symlink_safe() {$/,/^PATH=/p' "$bootstrap_script" | sed '$d')"
    claude_build_trusted_bootstrap_path \
      "" \
      "$TEST_ROOT/missing-store" \
      "$readlink_anchor_usr" \
      "$readlink_anchor_bin" \
      >/dev/null 2>&1
  ); then
    fail "$(basename "$bootstrap_script") accepted a symlinked initial readlink anchor"
  fi
  [ ! -e "$readlink_anchor_marker" ] || fail "$(basename "$bootstrap_script") executed an untrusted readlink anchor"
done
pass "runner and doctor establish readlink trust without candidate execution"

# Validate the standard Debian/Ubuntu alternatives shape without admitting an
# arbitrary symlink target: FHS entry -> /etc/alternatives entry -> FHS binary.
alternatives_root="$TEST_ROOT/fhs-alternatives"
alternatives_usr_bin="$alternatives_root/usr/bin"
alternatives_bin="$alternatives_root/bin"
alternatives_etc="$alternatives_root/etc/alternatives"
alternatives_external="$alternatives_root/external-awk"
trusted_readlink="$(type -P readlink 2>/dev/null || true)"
[ -n "$trusted_readlink" ] || fail "trusted readlink unavailable for alternatives fixture"
mkdir -p "$alternatives_usr_bin" "$alternatives_bin" "$alternatives_etc"
cp "$(type -P awk)" "$alternatives_usr_bin/mawk"
chmod 755 "$alternatives_usr_bin/mawk"
ln -s ../../usr/bin/mawk "$alternatives_etc/awk"
ln -s ../../etc/alternatives/awk "$alternatives_usr_bin/awk"
for bootstrap_script in "$ROOT/scripts/run-review.sh" "$ROOT/scripts/claude-doctor.sh"; do
  (
    eval "$(sed -n '/^claude_bootstrap_fhs_symlink_safe() {$/,/^claude_build_trusted_bootstrap_path() {$/p' "$bootstrap_script" | sed '$d')"
    claude_bootstrap_utility_safe \
      awk \
      "$alternatives_usr_bin/awk" \
      "$TEST_ROOT/missing-store" \
      "$alternatives_usr_bin" \
      "$alternatives_bin" \
      "$alternatives_etc" \
      "$trusted_readlink"
  ) || fail "$(basename "$bootstrap_script") rejected a bounded FHS alternatives chain"

  cp "$alternatives_usr_bin/mawk" "$alternatives_external"
  rm "$alternatives_etc/awk"
  ln -s "$alternatives_external" "$alternatives_etc/awk"
  if (
    eval "$(sed -n '/^claude_bootstrap_fhs_symlink_safe() {$/,/^claude_build_trusted_bootstrap_path() {$/p' "$bootstrap_script" | sed '$d')"
    claude_bootstrap_utility_safe \
      awk \
      "$alternatives_usr_bin/awk" \
      "$TEST_ROOT/missing-store" \
      "$alternatives_usr_bin" \
      "$alternatives_bin" \
      "$alternatives_etc" \
      "$trusted_readlink"
  ); then
    fail "$(basename "$bootstrap_script") accepted an alternatives chain outside fixed FHS roots"
  fi
  rm "$alternatives_etc/awk"
  ln -s ../../usr/bin/mawk "$alternatives_etc/awk"
done
pass "runner and doctor admit only bounded FHS alternatives chains"

# Simulate a non-FHS Nix host end to end. The fixture rewires only the fixed
# production trust roots in a copied doctor, then launches that doctor with no
# FHS utility directories available. macOS may kill relocated system Bash
# binaries, so the launcher stays exact /bin/bash while every bridge utility is
# supplied only by the simulated immutable-store directory.
non_fhs_skill="$TEST_ROOT/non-fhs-skill"
non_fhs_store="$TEST_ROOT/simulated-nix-store"
non_fhs_bin="$non_fhs_store/coreutils/bin"
non_fhs_profile_bin="$non_fhs_store/profile/bin"
non_fhs_missing_usr="$TEST_ROOT/non-fhs-missing/usr/bin"
non_fhs_missing_bin="$TEST_ROOT/non-fhs-missing/bin"
mkdir -p "$non_fhs_skill/scripts" "$non_fhs_bin" "$non_fhs_profile_bin"
cp "$ROOT"/scripts/*.sh "$non_fhs_skill/scripts/"
chmod 755 "$non_fhs_skill"/scripts/*.sh
for tool_name in awk basename bash cat chmod cut dirname git grep mkdir mktemp readlink rm sed stat tr wc; do
  if [ "$tool_name" = "bash" ]; then
    cat > "$non_fhs_bin/bash" <<'SH'
#!/bin/bash
exec /bin/bash "$@"
SH
    chmod 755 "$non_fhs_bin/bash"
    continue
  fi
  tool_path="$(type -P "$tool_name" 2>/dev/null || true)"
  [ -n "$tool_path" ] || fail "non-FHS bootstrap tool unavailable: $tool_name"
  {
    printf '#!/bin/bash\n'
    printf 'exec %q "$@"\n' "$tool_path"
  } > "$non_fhs_bin/$tool_name"
  chmod 755 "$non_fhs_bin/$tool_name"
done
# Model the common Nix `profile/bin/awk -> package/bin/awk -> gawk` chain.
mv "$non_fhs_bin/awk" "$non_fhs_bin/gawk"
ln -s gawk "$non_fhs_bin/awk"
for tool_name in awk basename bash cat chmod cut dirname git grep mkdir mktemp readlink rm sed stat tr wc; do
  ln -s "$non_fhs_bin/$tool_name" "$non_fhs_profile_bin/$tool_name"
done
python3 - "$non_fhs_skill/scripts/claude-doctor.sh" "$non_fhs_store" "$non_fhs_missing_usr" "$non_fhs_missing_bin" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = 'claude_build_trusted_bootstrap_path "$CLAUDE_RUNTIME_INHERITED_PATH" "/nix/store" "/usr/bin" "/bin"'
new = f'claude_build_trusted_bootstrap_path "$CLAUDE_RUNTIME_INHERITED_PATH" "{sys.argv[2]}" "{sys.argv[3]}" "{sys.argv[4]}"'
if old not in text:
    raise SystemExit("production bootstrap root call not found")
path.write_text(text.replace(old, new, 1))
PY
disable_homebrew_paths "$non_fhs_skill/scripts/claude-locator.sh" "$TEST_ROOT/non-fhs-disabled-homebrew/claude"
untrusted_nix_git="$TEST_ROOT/untrusted-nix-git"
cp "$non_fhs_bin/git" "$untrusted_nix_git"
rm "$non_fhs_profile_bin/git"
ln -s "$untrusted_nix_git" "$non_fhs_profile_bin/git"
set +e
HOME="$TEST_ROOT/home" PATH="$non_fhs_profile_bin" \
  BASH_ENV= ENV= /bin/bash --noprofile --norc -p "$non_fhs_skill/scripts/claude-doctor.sh" \
    --repo-root "$ROOT" \
    --skill-root "$non_fhs_skill" \
    --config-file "$ROOT/.codex/claude/config.env" \
    --skip-probes >/dev/null 2>&1
untrusted_nix_status=$?
set -e
[ "$untrusted_nix_status" -ne 0 ] || fail "non-FHS bootstrap accepted a store symlink with an external target"
rm "$non_fhs_profile_bin/git"
ln -s "$non_fhs_bin/git" "$non_fhs_profile_bin/git"
non_fhs_output="$({
  cd "$ROOT"
  HOME="$TEST_ROOT/home" PATH="$non_fhs_profile_bin" \
    BASH_ENV= ENV= /bin/bash --noprofile --norc -p "$non_fhs_skill/scripts/claude-doctor.sh" \
      --repo-root "$ROOT" \
      --skill-root "$non_fhs_skill" \
      --config-file "$ROOT/.codex/claude/config.env" \
      --skip-probes
})"
printf '%s\n' "$non_fhs_output" | grep -Fqx 'doctor_status=ok' || fail "non-FHS doctor bootstrap"
printf '%s\n' "$non_fhs_output" | grep -Fqx 'update_check=skipped' || fail "non-FHS doctor report-only status"
pass "doctor bootstraps through Nix profile symlinks and rejects external targets"

# Exercise the fixed Git-for-Windows root without depending on a Windows host.
# The copied runner rewires only fixed production roots and the platform case;
# the actual Windows CI job below still executes the unmodified production path.
windows_bootstrap_skill="$TEST_ROOT/windows-bootstrap-skill"
windows_bootstrap_usr="$TEST_ROOT/windows-bootstrap/usr/bin"
windows_bootstrap_bin="$TEST_ROOT/windows-bootstrap/bin"
windows_git_bin="$TEST_ROOT/windows-bootstrap/mingw64/bin"
mkdir -p "$windows_bootstrap_skill/scripts" "$windows_bootstrap_usr" "$windows_bootstrap_bin" "$windows_git_bin"
cp "$ROOT"/scripts/*.sh "$windows_bootstrap_skill/scripts/"
chmod 755 "$windows_bootstrap_skill"/scripts/*.sh
for tool_name in awk basename bash cat chmod cut dirname grep mkdir mktemp readlink rm sed stat tr wc; do
  tool_path="$(type -P "$tool_name" 2>/dev/null || true)"
  [ -n "$tool_path" ] || fail "Windows bootstrap tool unavailable: $tool_name"
  {
    printf '#!/bin/bash\n'
    printf 'exec %q "$@"\n' "$tool_path"
  } > "$windows_bootstrap_usr/$tool_name"
  chmod 755 "$windows_bootstrap_usr/$tool_name"
done
tool_path="$(type -P git 2>/dev/null || true)"
[ -n "$tool_path" ] || fail "Windows bootstrap git unavailable"
{
  printf '#!/bin/bash\n'
  printf 'exec %q "$@"\n' "$tool_path"
} > "$windows_git_bin/git"
chmod 755 "$windows_git_bin/git"
python3 - \
  "$windows_bootstrap_skill/scripts/run-review.sh" \
  "$windows_bootstrap_usr" \
  "$windows_bootstrap_bin" \
  "$windows_git_bin" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('case "${OSTYPE:-}" in', 'case "msys-test" in', 1)
text = text.replace('"/mingw64/bin"', f'"{sys.argv[4]}"', 1)
old = 'claude_build_trusted_bootstrap_path "$CLAUDE_RUNTIME_INHERITED_PATH" "/nix/store" "/usr/bin" "/bin"'
new = f'claude_build_trusted_bootstrap_path "$CLAUDE_RUNTIME_INHERITED_PATH" "/nix/store" "{sys.argv[2]}" "{sys.argv[3]}"'
if old not in text:
    raise SystemExit("production bootstrap root call not found")
path.write_text(text.replace(old, new, 1))
PY
HOME="$TEST_ROOT/home" PATH="$windows_bootstrap_usr:$windows_git_bin" \
  BASH_ENV= ENV= /bin/bash --noprofile --norc -p \
  "$windows_bootstrap_skill/scripts/run-review.sh" --help >/dev/null
pass "runner admits git only from the fixed Git-for-Windows root"

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
