#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCATOR="$ROOT/scripts/claude-locator.sh"
RUNTIME="$ROOT/scripts/claude-runtime.sh"
TEST_ROOT="$(mktemp -d "$HOME/.claude-review-helper-test-XXXXXX")"
TEMP_BOUNDARY_ROOT="$(mktemp -d /tmp/claude-review-boundary-test-XXXXXX)"
PLATFORM_TEMP_BOUNDARY_ROOT=""
trap 'chmod -R u+w "$TEST_ROOT" "$TEMP_BOUNDARY_ROOT" ${PLATFORM_TEMP_BOUNDARY_ROOT:+"$PLATFORM_TEMP_BOUNDARY_ROOT"} 2>/dev/null || true; rm -rf "$TEST_ROOT" "$TEMP_BOUNDARY_ROOT"; [ -z "$PLATFORM_TEMP_BOUNDARY_ROOT" ] || rm -rf "$PLATFORM_TEMP_BOUNDARY_ROOT"' EXIT

fail() {
  echo "not ok: $1" >&2
  exit 1
}

pass() {
  echo "ok: $1"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label (expected=$expected actual=$actual)"
}

# shellcheck source=/dev/null
source "$LOCATOR"
# shellcheck source=/dev/null
source "$RUNTIME"

for supported in darwin23 linux-gnu linux-musl; do
  claude_locator_native_supported "$supported" || fail "native predicate accepts $supported"
done
for unsupported in msys mingw64_nt cygwin unknown ""; do
  if claude_locator_native_supported "$unsupported"; then
    fail "native predicate rejects $unsupported"
  fi
done
pass "bounded native platform predicate"

claude_locator_homebrew_paths darwin23 x86_64-apple-darwin
assert_eq "2" "${#CLAUDE_LOCATOR_HOMEBREW_PATHS[@]}" "darwin Homebrew path count"
assert_eq "/opt/homebrew/bin/claude" "${CLAUDE_LOCATOR_HOMEBREW_PATHS[0]}" "darwin arm prefix first"
assert_eq "/usr/local/bin/claude" "${CLAUDE_LOCATOR_HOMEBREW_PATHS[1]}" "darwin intel prefix second"
claude_locator_homebrew_paths darwin23 arm64-apple-darwin
assert_eq "/opt/homebrew/bin/claude" "${CLAUDE_LOCATOR_HOMEBREW_PATHS[0]}" "darwin mapping ignores process architecture"
claude_locator_homebrew_paths linux-gnu x86_64-pc-linux-gnu
assert_eq "/home/linuxbrew/.linuxbrew/bin/claude" "${CLAUDE_LOCATOR_HOMEBREW_PATHS[0]}" "linux x86_64 prefix"
claude_locator_homebrew_paths linux-gnu aarch64-unknown-linux-gnu
assert_eq "0" "${#CLAUDE_LOCATOR_HOMEBREW_PATHS[@]}" "linux arm excluded"
pass "documented Homebrew mapping"

/bin/bash -u - "$LOCATOR" "$ROOT/scripts/run-review.sh" <<'BASH'
locator="$1"
runner="$2"
source "$locator"
claude_locator_native_path() { return 1; }
claude_locator_native_supported() { return 1; }
claude_locator_homebrew_paths() { CLAUDE_LOCATOR_HOMEBREW_PATHS=(); }
claude_locator_first_present_fallback
[ "$CLAUDE_LOCATOR_CANDIDATE_SOURCE" = "missing" ]
eval "$(sed -n '/^checked_claude_locations() {$/,/^}$/p' "$runner")"
[ "$(checked_claude_locations)" = "PATH" ]
BASH
pass "empty Homebrew discovery remains nounset-safe on legacy Bash"

printf '#!/bin/bash\nexit 0\n' > "$TEMP_BOUNDARY_ROOT/claude"
chmod 755 "$TEMP_BOUNDARY_ROOT" "$TEMP_BOUNDARY_ROOT/claude"
if claude_locator_validate_candidate "$TEMP_BOUNDARY_ROOT/claude" "$ROOT" "$TEST_ROOT/work"; then
  fail "temporary candidate passed trust validation"
fi
assert_eq "launch" "$CLAUDE_LOCATOR_VALIDATION_SCOPE" "temporary candidate trust scope"
assert_eq "temporary_path" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "temporary candidate trust reason"
pass "temporary path boundary is independently classified"

configured_temp_root="$TEST_ROOT/configured-user-temp"
mkdir -p "$configured_temp_root"
printf '#!/bin/bash\nexit 0\n' > "$configured_temp_root/claude"
chmod 755 "$configured_temp_root/claude"
if TMPDIR="$configured_temp_root" claude_locator_validate_candidate "$configured_temp_root/claude" "$ROOT" "$TEST_ROOT/work"; then
  fail "configured temporary candidate passed trust validation"
fi
assert_eq "temporary_path" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "configured temporary root trust reason"
pass "configured per-user temporary roots are rejected"

case "${TMPDIR:-}" in
  /*)
    if [ -d "$TMPDIR" ]; then
      PLATFORM_TEMP_BOUNDARY_ROOT="$(mktemp -d "${TMPDIR%/}/claude-review-platform-temp-XXXXXX")"
      printf '#!/bin/bash\nexit 0\n' > "$PLATFORM_TEMP_BOUNDARY_ROOT/claude"
      chmod 755 "$PLATFORM_TEMP_BOUNDARY_ROOT/claude"
      if claude_locator_validate_candidate "$PLATFORM_TEMP_BOUNDARY_ROOT/claude" "$ROOT" "$TEST_ROOT/work"; then
        fail "actual TMPDIR candidate passed trust validation"
      fi
      assert_eq "temporary_path" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "actual TMPDIR trust reason"
    fi
    ;;
esac
pass "actual inherited TMPDIR is rejected when present"

windows_identity_root="$TEST_ROOT/windows identity"
mkdir -p "$windows_identity_root"
printf 'native exe\n' > "$windows_identity_root/claude.exe"
chmod 755 "$windows_identity_root/claude.exe"
assert_eq \
  "$windows_identity_root/claude.exe" \
  "$(claude_locator_materialize_windows_executable_path "$windows_identity_root/claude" msys)" \
  "Git Bash materializes the actual exe entry"
printf '#!/usr/bin/env bash\nexit 0\n' > "$windows_identity_root/claude"
chmod 755 "$windows_identity_root/claude"
assert_eq \
  "$windows_identity_root/claude" \
  "$(claude_locator_materialize_windows_executable_path "$windows_identity_root/claude" msys)" \
  "exact extensionless launcher wins over exe sibling"
assert_eq \
  "$windows_identity_root/claude" \
  "$(claude_locator_materialize_windows_executable_path "$windows_identity_root/claude" darwin)" \
  "non-Windows discovery preserves the resolved path"
pass "Windows executable launch identity"

mkdir -p "$TEST_ROOT/trusted/bin" "$TEST_ROOT/work"
cat > "$TEST_ROOT/trusted/bin/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 755 "$TEST_ROOT/trusted/bin/claude"

portable_store="$TEST_ROOT/nix-store"
portable_tools="$portable_store/coreutils-test/bin"
portable_profile_tools="$portable_store/profile/bin"
mkdir -p "$portable_tools" "$portable_profile_tools"
real_stat="$(type -P stat)"
real_readlink="$(type -P readlink)"
{
  printf '#!/bin/bash\n'
  printf 'exec %q "$@"\n' "$real_stat"
} > "$portable_tools/stat"
{
  printf '#!/bin/bash\n'
  printf 'exec %q "$@"\n' "$real_readlink"
} > "$portable_tools/readlink"
chmod 555 "$portable_tools/stat" "$portable_tools/readlink"
ln -s "$portable_tools/stat" "$portable_profile_tools/stat"
ln -s "$portable_tools/readlink" "$portable_profile_tools/readlink"
chmod 555 \
  "$portable_tools" \
  "$portable_profile_tools" \
  "$portable_store/coreutils-test" \
  "$portable_store/profile" \
  "$portable_store"
(
  PATH="/usr/bin:/bin"
  CLAUDE_RUNTIME_INHERITED_PATH="$portable_profile_tools"
  export PATH CLAUDE_RUNTIME_INHERITED_PATH
  resolved_stat="$(claude_locator_resolve_trusted_utility stat "$portable_store" "$TEST_ROOT/missing/stat")"
  resolved_readlink="$(claude_locator_resolve_trusted_utility readlink "$portable_store" "$TEST_ROOT/missing/readlink")"
  [ "$resolved_stat" = "$portable_tools/stat" ] || exit 1
  [ "$resolved_readlink" = "$portable_tools/readlink" ] || exit 1
) || fail "trusted immutable-store utility fallback through captured inherited PATH"
chmod 755 "$portable_profile_tools" "$portable_store/profile" "$portable_store"
portable_external_stat="$TEST_ROOT/portable-external-stat"
cp "$portable_tools/stat" "$portable_external_stat"
rm "$portable_profile_tools/stat"
ln -s "$portable_external_stat" "$portable_profile_tools/stat"
chmod 555 "$portable_profile_tools" "$portable_store/profile" "$portable_store"
(
  PATH="/usr/bin:/bin"
  CLAUDE_RUNTIME_INHERITED_PATH="$portable_profile_tools"
  export PATH CLAUDE_RUNTIME_INHERITED_PATH
  if claude_locator_resolve_trusted_utility stat "$portable_store" "$TEST_ROOT/missing/stat"; then
    exit 1
  fi
) || fail "trusted utility resolver must reject a store link to an external target"
chmod 755 "$portable_profile_tools" "$portable_store/profile" "$portable_store"
rm "$portable_profile_tools/stat"
ln -s "$portable_tools/stat" "$portable_profile_tools/stat"
chmod 555 "$portable_profile_tools" "$portable_store/profile" "$portable_store"
(
  claude_locator_resolve_trusted_utility() {
    case "${1:-}" in
      stat)
        printf '%s' "$portable_tools/stat"
        ;;
      readlink)
        printf '%s' "$portable_tools/readlink"
        ;;
      *)
        return 1
        ;;
    esac
  }
  claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/claude" "$ROOT" "$TEST_ROOT/work" || exit 1
) || fail "candidate validation with non-FHS trusted utilities"
(
  claude_locator_resolve_trusted_utility() { return 1; }
  if claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/claude" "$ROOT" "$TEST_ROOT/work"; then
    exit 1
  fi
  [ "$CLAUDE_LOCATOR_VALIDATION_SCOPE" = "launch" ] || exit 1
  [ "$CLAUDE_LOCATOR_VALIDATION_STATUS" = "validation_unavailable" ] || exit 1
) || fail "missing trust utility fails closed without false world-writable diagnosis"
pass "trusted utility portability preserves fail-closed validation"

gnu_stat="$(type -P gstat 2>/dev/null || true)"
if [ -z "$gnu_stat" ] && stat --version 2>/dev/null | grep -q 'GNU coreutils'; then
  gnu_stat="$(type -P stat)"
fi
if [ -n "$gnu_stat" ]; then
  (
    claude_locator_resolve_trusted_utility() {
      case "${1:-}" in
        stat) printf '%s' "$gnu_stat" ;;
        readlink) printf '%s' "$real_readlink" ;;
        *) return 1 ;;
      esac
    }
    if claude_locator_parent_world_writable /usr/bin/env; then
      exit 1
    else
      [ "$?" -eq 1 ] || exit 1
    fi
    if claude_locator_file_world_writable /usr/bin/env; then
      exit 1
    else
      [ "$?" -eq 1 ] || exit 1
    fi
    mkdir -p "$TEST_ROOT/gnu-stat-cwd"
    : > "$TEST_ROOT/gnu-stat-cwd/%Lp"
    cd "$TEST_ROOT/gnu-stat-cwd"
    if claude_locator_parent_world_writable /usr/bin/env; then
      exit 1
    else
      [ "$?" -eq 1 ] || exit 1
    fi
    if claude_locator_file_world_writable /usr/bin/env; then
      exit 1
    else
      [ "$?" -eq 1 ] || exit 1
    fi
    cp "$TEST_ROOT/trusted/bin/claude" "$TEST_ROOT/trusted/bin/gnu-world-writable"
    chmod 777 "$TEST_ROOT/trusted/bin/gnu-world-writable"
    claude_locator_file_world_writable "$TEST_ROOT/trusted/bin/gnu-world-writable" || exit 1
  ) || fail "GNU stat mode parsing"
  pass "GNU stat fallback discards failed and invalid BSD-probe output"
else
  pass "GNU stat fallback test skipped when GNU stat is unavailable"
fi

(
  cd "$TEST_ROOT/work"
  PATH="../trusted/bin:/usr/bin:/bin"
  export PATH
  claude_locator_path_candidate "$PWD" || exit 1
  [ "$CLAUDE_LOCATOR_CANDIDATE_SOURCE" = "path" ] || exit 1
  claude_locator_validate_candidate "$CLAUDE_LOCATOR_CANDIDATE_PATH" "$ROOT" "$PWD" || exit 1
  [ "$CLAUDE_LOCATOR_LAUNCH_PATH" = "$TEST_ROOT/trusted/bin/claude" ] || exit 1
) || fail "relative PATH candidate normalization"
pass "relative PATH candidate physically normalizes before runtime CWD changes"

bootstrap_only_path="$TEST_ROOT/bootstrap-only-path"
mkdir -p "$bootstrap_only_path"
cp "$TEST_ROOT/trusted/bin/claude" "$bootstrap_only_path/claude"
(
  cd "$TEST_ROOT/work"
  PATH="$bootstrap_only_path"
  CLAUDE_RUNTIME_INHERITED_PATH=""
  export PATH CLAUDE_RUNTIME_INHERITED_PATH
  if claude_locator_path_candidate "$PWD"; then
    exit 1
  fi
  [ "$CLAUDE_LOCATOR_CANDIDATE_SOURCE" = "missing" ] || exit 1
  if claude_locator_resolve_trusted_utility stat "$portable_store" "$TEST_ROOT/missing/stat"; then
    exit 1
  fi
) || fail "empty captured PATH must not fall back to bootstrap utilities"
pass "empty captured PATH remains distinct from an unset capture"

mkdir -p "$TEST_ROOT/path-first" "$TEST_ROOT/path-later"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/path-first/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/path-later/claude"
chmod 644 "$TEST_ROOT/path-first/claude"
chmod 755 "$TEST_ROOT/path-later/claude"
(
  cd "$TEST_ROOT/work"
  PATH="$TEST_ROOT/path-first:$TEST_ROOT/path-later:/usr/bin:/bin"
  export PATH
  claude_locator_path_candidate "$PWD" || exit 1
  [ "$CLAUDE_LOCATOR_CANDIDATE_PATH" = "$TEST_ROOT/path-later/claude" ] || exit 1
) || fail "type -P later executable precedence"
(
  cd "$TEST_ROOT/work"
  PATH="$TEST_ROOT/path-first:/usr/bin:/bin"
  export PATH
  claude_locator_path_candidate "$PWD" || exit 1
  [ "$CLAUDE_LOCATOR_CANDIDATE_PATH" = "$TEST_ROOT/path-first/claude" ] || exit 1
  if claude_locator_validate_candidate "$CLAUDE_LOCATOR_CANDIDATE_PATH" "$ROOT" "$PWD"; then
    exit 1
  fi
  [ "$CLAUDE_LOCATOR_VALIDATION_STATUS" = "not_executable" ] || exit 1
) || fail "diagnostic PATH scan classification"
pass "PATH executable resolution and stale-entry scan precedence"

(
  function claude() { return 0; }
  alias claude='printf alias'
  PATH="/usr/bin:/bin"
  export PATH
  if claude_locator_path_candidate "$TEST_ROOT/work"; then
    exit 1
  fi
) || fail "function and alias ignored"
pass "type -P ignores functions and aliases"

ln -s "$TEST_ROOT/trusted/bin/claude" "$TEST_ROOT/trusted/bin/claude-link"
if ! claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/claude-link" "$ROOT" "$TEST_ROOT/work"; then
  fail "safe symlink validation"
fi
assert_eq "$TEST_ROOT/trusted/bin/claude-link" "$CLAUDE_LOCATOR_LAUNCH_PATH" "launch symlink retained"
assert_eq "$TEST_ROOT/trusted/bin/claude" "$CLAUDE_LOCATOR_CANONICAL_TARGET" "canonical target separated"
pass "launch identity and canonical trust identity remain separate"

newline_target="$TEST_ROOT/trusted/bin/claude"$'\n'
cp "$TEST_ROOT/trusted/bin/claude" "$newline_target"
chmod 777 "$newline_target"
ln -s $'claude\n' "$TEST_ROOT/trusted/bin/claude-newline-link"
if claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/claude-newline-link" "$ROOT" "$TEST_ROOT/work"; then
  fail "newline-bearing symlink target was validated as a different path"
fi
assert_eq "$newline_target" "$CLAUDE_LOCATOR_CANONICAL_TARGET" "trailing newline remains part of canonical target"
assert_eq "world_writable_file" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "newline-bearing target receives its own trust result"
pass "canonical symlink resolution preserves trailing newlines exactly"

newline_parent="$TEST_ROOT/trusted/newline-parent"$'\n'
trimmed_parent="$TEST_ROOT/trusted/newline-parent"
mkdir -p "$newline_parent" "$trimmed_parent"
cp "$TEST_ROOT/trusted/bin/claude" "$newline_parent/claude"
cp "$TEST_ROOT/trusted/bin/claude" "$trimmed_parent/claude"
chmod 777 "$newline_parent/claude"
chmod 755 "$trimmed_parent/claude"
ln -s "$newline_parent/claude" "$TEST_ROOT/trusted/bin/claude-newline-parent-link"
if claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/claude-newline-parent-link" "$ROOT" "$TEST_ROOT/work"; then
  fail "newline-bearing parent was validated as its trimmed sibling"
fi
assert_eq "$newline_parent/claude" "$CLAUDE_LOCATOR_CANONICAL_TARGET" "trailing newline remains part of canonical parent"
assert_eq "world_writable_file" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "newline-parent target receives its own trust result"
pass "canonical parent resolution preserves trailing newlines exactly"

mkdir -p "$TEST_ROOT/intermediate-world"
chmod 777 "$TEST_ROOT/intermediate-world"
ln -s "$TEST_ROOT/trusted/bin/claude" "$TEST_ROOT/intermediate-world/claude-hop"
ln -s "$TEST_ROOT/intermediate-world/claude-hop" "$TEST_ROOT/trusted/bin/claude-chain"
if claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/claude-chain" "$ROOT" "$TEST_ROOT/work"; then
  fail "world-writable intermediate symlink hop rejected"
fi
assert_eq "target" "$CLAUDE_LOCATOR_VALIDATION_SCOPE" "intermediate symlink scope"
assert_eq "world_writable_parent" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "intermediate symlink reason"
pass "every intermediate symlink hop receives boundary validation"

directory_hop_root="$(mktemp -d /tmp/claude-review-directory-hop.XXXXXX)"
ln -s "$TEST_ROOT/trusted/bin" "$directory_hop_root/bin-hop"
ln -s "$directory_hop_root/bin-hop/claude" "$TEST_ROOT/trusted/bin/claude-directory-hop"
if claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/claude-directory-hop" "$ROOT" "$TEST_ROOT/work"; then
  rm -rf "$directory_hop_root"
  fail "temporary directory symlink hop was collapsed before validation"
fi
assert_eq "temporary_path" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "temporary directory symlink hop trust reason"
rm -rf "$directory_hop_root"

safe_directory_hop_root="$TEST_ROOT/trusted/directory-hop"
mkdir -p "$safe_directory_hop_root"
ln -s "$TEST_ROOT/trusted/bin" "$safe_directory_hop_root/bin-hop"
ln -s "$safe_directory_hop_root/bin-hop/claude" "$TEST_ROOT/trusted/bin/claude-safe-directory-hop"
claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/claude-safe-directory-hop" "$ROOT" "$TEST_ROOT/work" || \
  fail "safe directory symlink hop was rejected"
assert_eq "$TEST_ROOT/trusted/bin/claude" "$CLAUDE_LOCATOR_CANONICAL_TARGET" "safe directory hop canonical target"
pass "directory symlink hops are validated before physical collapse"

mkdir -p "$TEST_ROOT/invocation/bin"
cp "$TEST_ROOT/trusted/bin/claude" "$TEST_ROOT/invocation/bin/claude"
if claude_locator_validate_candidate "$TEST_ROOT/invocation/bin/claude" "$ROOT" "$TEST_ROOT/invocation"; then
  fail "invocation CWD candidate rejected"
fi
assert_eq "invocation_cwd_path" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "invocation CWD reason"

claude_locator_boundary_status "$TEST_ROOT/trusted/bin/claude" "" "/" || fail "filesystem-root invocation CWD accepted"
assert_eq "safe" "$CLAUDE_LOCATOR_BOUNDARY_STATUS" "filesystem-root invocation CWD boundary"
pass "filesystem-root invocation CWD does not reject every candidate"

mkdir -p "$TEST_ROOT/world-writable/bin"
cp "$TEST_ROOT/trusted/bin/claude" "$TEST_ROOT/world-writable/bin/claude"
chmod 777 "$TEST_ROOT/world-writable"
if claude_locator_validate_candidate "$TEST_ROOT/world-writable/bin/claude" "$ROOT" "$TEST_ROOT/work"; then
  fail "world-writable candidate rejected"
fi
assert_eq "world_writable_parent" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "world-writable reason"

cp "$TEST_ROOT/trusted/bin/claude" "$TEST_ROOT/trusted/bin/world-writable-claude"
chmod 777 "$TEST_ROOT/trusted/bin/world-writable-claude"
if claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/world-writable-claude" "$ROOT" "$TEST_ROOT/work"; then
  fail "world-writable executable file rejected"
fi
assert_eq "target" "$CLAUDE_LOCATOR_VALIDATION_SCOPE" "world-writable file scope"
assert_eq "world_writable_file" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "world-writable file reason"

mkdir -p "$TEST_ROOT/not-regular/claude"
if claude_locator_validate_candidate "$TEST_ROOT/not-regular/claude" "$ROOT" "$TEST_ROOT/work"; then
  fail "non-regular candidate rejected"
fi
assert_eq "not_regular" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "not-regular reason"

ln -s "$TEST_ROOT/missing-target" "$TEST_ROOT/trusted/bin/dangling"
if claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/dangling" "$ROOT" "$TEST_ROOT/work"; then
  fail "dangling candidate rejected"
fi
assert_eq "dangling_symlink" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "dangling reason"

ln -s "$TEST_ROOT/trusted/bin/loop-b" "$TEST_ROOT/trusted/bin/loop-a"
ln -s "$TEST_ROOT/trusted/bin/loop-a" "$TEST_ROOT/trusted/bin/loop-b"
if claude_locator_is_dangling_symlink "$TEST_ROOT/trusted/bin/loop-a"; then
  fail "symlink loop classified as dangling"
fi
if claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/loop-a" "$ROOT" "$TEST_ROOT/work"; then
  fail "symlink loop accepted"
fi
assert_eq "validation_unavailable" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "symlink loop fails closed"

# Root bypasses these DAC mode bits, so this fixture is meaningful only for an
# identity whose filesystem access is actually constrained by them.
if [ "${EUID:-1}" -ne 0 ]; then
  mkdir -p "$TEST_ROOT/inaccessible-target"
  ln -s "$TEST_ROOT/inaccessible-target/claude" "$TEST_ROOT/trusted/bin/inaccessible-link"
  chmod 000 "$TEST_ROOT/inaccessible-target"
  if claude_locator_is_dangling_symlink "$TEST_ROOT/trusted/bin/inaccessible-link"; then
    chmod 700 "$TEST_ROOT/inaccessible-target"
    fail "inaccessible symlink target classified as dangling"
  fi
  if claude_locator_validate_candidate "$TEST_ROOT/trusted/bin/inaccessible-link" "$ROOT" "$TEST_ROOT/work"; then
    chmod 700 "$TEST_ROOT/inaccessible-target"
    fail "inaccessible symlink target accepted"
  fi
  chmod 700 "$TEST_ROOT/inaccessible-target"
  assert_eq "validation_unavailable" "$CLAUDE_LOCATOR_VALIDATION_STATUS" "inaccessible symlink target fails closed"
fi
pass "independent trust rejection statuses"

mkdir -p "$TEST_ROOT/physical/inside/trusted/bin"
cp "$TEST_ROOT/trusted/bin/claude" "$TEST_ROOT/physical/inside/trusted/bin/claude"
ln -s "$TEST_ROOT/physical/inside/child" "$TEST_ROOT/physical-link"
mkdir -p "$TEST_ROOT/physical/inside/child"
if ! claude_locator_validate_candidate "$TEST_ROOT/physical-link/../trusted/bin/claude" "$ROOT" "$TEST_ROOT/work"; then
  fail "intermediate symlink physical normalization"
fi
assert_eq "$TEST_ROOT/physical/inside/trusted/bin/claude" "$CLAUDE_LOCATOR_LAUNCH_PATH" "physical normalization result"
pass "dot segments follow intermediate symlink filesystem semantics"

claude_runtime_build_command "$TEST_ROOT/trusted/bin/claude" --version
assert_eq "$TEST_ROOT/trusted/bin/claude" "${CLAUDE_RUNTIME_COMMAND[0]}" "runtime exact launch path is argv zero"
assert_eq "--version" "${CLAUDE_RUNTIME_COMMAND[1]}" "runtime version argv"
case " ${CLAUDE_RUNTIME_COMMAND[*]} " in
  *" --tools "*|*" --strict-mcp-config "*) fail "builder injected prompt flags" ;;
esac
claude_runtime_build_command "$TEST_ROOT/trusted/bin/claude" auth status
assert_eq "auth" "${CLAUDE_RUNTIME_COMMAND[1]}" "runtime auth argv one"
assert_eq "status" "${CLAUDE_RUNTIME_COMMAND[2]}" "runtime auth argv two"
claude_runtime_prepare_python_argv "${CLAUDE_RUNTIME_COMMAND[@]}" || fail "Python argv preparation"
assert_eq "$TEST_ROOT/trusted/bin/claude" "${CLAUDE_RUNTIME_PYTHON_ARGV[0]}" "non-Windows Python executable unchanged"
assert_eq "auth" "${CLAUDE_RUNTIME_PYTHON_ARGV[1]}" "Python argv one preserved"
pass "runtime builder is transport-only"

fake_cygpath="$TEST_ROOT/trusted/bin/fake-cygpath"
cat > "$fake_cygpath" <<'SH'
#!/bin/bash
printf 'WIN:%s' "$2"
SH
chmod 755 "$fake_cygpath"
saved_ostype="$OSTYPE"
OSTYPE=msys-test
CLAUDE_RUNTIME_CYGPATH_BIN="$fake_cygpath"
CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND=(/usr/bin/env python3 -I -S /trusted/claude)
claude_runtime_build_command /trusted/claude -v
claude_runtime_prepare_python_argv "${CLAUDE_RUNTIME_COMMAND[@]}" || fail "simulated Windows shebang argv transport"
OSTYPE="$saved_ostype"
assert_eq "6" "${#CLAUDE_RUNTIME_PYTHON_ARGV[@]}" "Windows transport argv count"
assert_eq "WIN:/usr/bin/env" "${CLAUDE_RUNTIME_PYTHON_ARGV[0]}" "Windows transport env path"
assert_eq "python3" "${CLAUDE_RUNTIME_PYTHON_ARGV[1]}" "Windows transport interpreter token"
assert_eq "-I" "${CLAUDE_RUNTIME_PYTHON_ARGV[2]}" "Windows transport isolated flag"
assert_eq "-S" "${CLAUDE_RUNTIME_PYTHON_ARGV[3]}" "Windows transport no-site flag"
assert_eq "WIN:/trusted/claude" "${CLAUDE_RUNTIME_PYTHON_ARGV[4]}" "Windows transport launcher path"
assert_eq "-v" "${CLAUDE_RUNTIME_PYTHON_ARGV[5]}" "Windows transport trailing argv"
unset CLAUDE_RUNTIME_CYGPATH_BIN
pass "Windows shebang transport appends user argv exactly once"

python_injection_root="$TEST_ROOT/python-injection"
python_driver="$TEST_ROOT/work/process-driver.py"
python_injection_marker="$TEST_ROOT/python-injection-ran"
mkdir -p "$python_injection_root"
cat > "$TEST_ROOT/work/subprocess.py" <<'PY'
from pathlib import Path
import os
Path(os.environ["PYTHON_INJECTION_MARKER"]).write_text("cwd")
PY
cp "$TEST_ROOT/work/subprocess.py" "$python_injection_root/subprocess.py"
claude_runtime_resolve_trusted_python "$ROOT" "$TEST_ROOT/work" "$TEST_ROOT/work" || fail "trusted Python resolution"
assert_eq "safe" "$CLAUDE_RUNTIME_PYTHON_STATUS" "trusted Python status"
(
  claude_locator_resolve_trusted_utility() { return 1; }
  if claude_runtime_check_launcher_dependency "$CLAUDE_RUNTIME_PYTHON_CANONICAL_TARGET" "$TEST_ROOT/work"; then
    exit 1
  fi
  [ "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" = "validation_unavailable" ] || exit 1
  [ "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY" = "od" ] || exit 1
) || fail "missing trusted od is validation-unavailable"
claude_runtime_write_python_driver "$python_driver"
"$CLAUDE_RUNTIME_PYTHON_BIN" -I - "$python_driver" <<'PY'
import importlib.util
import io
import subprocess
import sys

spec = importlib.util.spec_from_file_location("claude_runtime_driver", sys.argv[1])
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class TimedOutProcess:
    pid = 999999999

    def __init__(self):
        self.stdin = io.BytesIO()
        self.stdout = io.BytesIO()
        self.stderr = io.BytesIO()
        self.communicate_calls = 0

    def communicate(self, timeout):
        self.communicate_calls += 1
        raise subprocess.TimeoutExpired(
            "fixture",
            timeout,
            output="partial-☃".encode("utf-8"),
            stderr=b"bounded-stderr",
        )

    def wait(self, timeout):
        return 1


proc = TimedOutProcess()
out, err = driver._bounded_timeout_cleanup(proc, None)
if out != "partial-☃" or err != "bounded-stderr":
    raise SystemExit(f"timeout output was not normalized: out={out!r} err={err!r}")
if proc.communicate_calls != 2:
    raise SystemExit(f"unexpected bounded cleanup calls: {proc.communicate_calls}")
if not proc.stdin.closed or not proc.stdout.closed or not proc.stderr.closed:
    raise SystemExit("bounded cleanup did not close retained pipes")
PY
(
  PATH="${CLAUDE_RUNTIME_PYTHON_BIN%/*}"
  CLAUDE_RUNTIME_INHERITED_PATH=""
  export PATH CLAUDE_RUNTIME_INHERITED_PATH
  if claude_runtime_resolve_trusted_python "$ROOT" "$TEST_ROOT/work" "$TEST_ROOT/work"; then
    exit 1
  fi
  [ "$CLAUDE_RUNTIME_PYTHON_STATUS" = "missing" ] || exit 1
) || fail "empty captured PATH must not discover bootstrap Python"
driver_output="$(
  PYTHON_INJECTION_MARKER="$python_injection_marker" \
  PYTHONPATH="$python_injection_root" \
  claude_runtime_run_with_timeout \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    "$TEST_ROOT/work" \
    5 \
    - \
    /bin/bash -c 'printf driver-ok'
)"
assert_eq "driver-ok" "$driver_output" "isolated Python driver output"
[ ! -e "$python_injection_marker" ] || fail "isolated Python loaded startup code from CWD or PYTHONPATH"
unicode_stdout="$TEST_ROOT/work/unicode-stdout"
unicode_stderr="$TEST_ROOT/work/unicode-stderr"
claude_runtime_run_with_timeout \
  "$CLAUDE_RUNTIME_PYTHON_BIN" \
  "$python_driver" \
  "$TEST_ROOT/work" \
  5 \
  - \
  "$CLAUDE_RUNTIME_PYTHON_BIN" -c \
  'import sys; sys.stdout.buffer.write(b"out-\xe2\x98\x83\n"); sys.stderr.buffer.write(b"err-\xe6\x9d\xb1\xe4\xba\xac\n")' \
  >"$unicode_stdout" 2>"$unicode_stderr"
"$CLAUDE_RUNTIME_PYTHON_BIN" -I - "$unicode_stdout" "$unicode_stderr" <<'PY'
from pathlib import Path
import sys

expected_stdout = b"out-\xe2\x98\x83\n"
expected_stderr = b"err-\xe6\x9d\xb1\xe4\xba\xac\n"
actual_stdout = Path(sys.argv[1]).read_bytes()
actual_stderr = Path(sys.argv[2]).read_bytes()
if actual_stdout != expected_stdout or actual_stderr != expected_stderr:
    raise SystemExit(
        f"UTF-8 forwarding changed bytes: stdout={actual_stdout!r} stderr={actual_stderr!r}"
    )
PY
unicode_probe="$(
  claude_runtime_probe_with_timeout \
    unicode \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    "$TEST_ROOT/work" \
    5 \
    @probe \
    "$CLAUDE_RUNTIME_PYTHON_BIN" -c \
    'import sys; sys.stdin.read(); sys.stdout.buffer.write(b"\xe2\x98\x83"); sys.stderr.buffer.write(b"\xe6\x9d\xb1\xe4\xba\xac")'
)"
printf '%s\n' "$unicode_probe" | grep -Fqx 'unicode_stdout_bytes=3' || fail "probe stdout count is not UTF-8 bytes"
printf '%s\n' "$unicode_probe" | grep -Fqx 'unicode_stderr_bytes=6' || fail "probe stderr count is not UTF-8 bytes"
empty_driver_path="$(
  PATH="${CLAUDE_RUNTIME_PYTHON_BIN%/*}" \
  CLAUDE_RUNTIME_INHERITED_PATH="" \
  claude_runtime_run_with_timeout \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    "$TEST_ROOT/work" \
    5 \
    - \
    /bin/bash -c 'printf %s "$PATH"'
)"
assert_eq "" "$empty_driver_path" "Python transport preserves empty inherited PATH"

unsafe_python_root="$TEST_ROOT/unsafe-python-invocation"
mkdir -p "$unsafe_python_root/bin"
cat > "$unsafe_python_root/bin/python3" <<SH
#!/bin/bash
printf executed > "$TEST_ROOT/unsafe-python-executed"
exit 99
SH
chmod 755 "$unsafe_python_root/bin/python3"
if PATH="$unsafe_python_root/bin:$PATH" claude_runtime_resolve_trusted_python "$ROOT" "$unsafe_python_root" "$TEST_ROOT/work"; then
  fail "invocation-CWD Python passed trust validation"
fi
assert_eq "unsafe" "$CLAUDE_RUNTIME_PYTHON_STATUS" "unsafe Python status"
assert_eq "invocation_cwd_path" "$CLAUDE_RUNTIME_PYTHON_VALIDATION_STATUS" "unsafe Python trust reason"
[ ! -e "$TEST_ROOT/unsafe-python-executed" ] || fail "untrusted Python executed during resolution"
pass "trusted isolated Python bootstrap rejects startup injection"

shebangless_python_root="$TEST_ROOT/shebangless-python"
shebangless_python_marker="$TEST_ROOT/shebangless-python-executed"
mkdir -p "$shebangless_python_root/bin"
cat > "$shebangless_python_root/bin/python3" <<'SH'
printf executed > "${SHEBANGLESS_PYTHON_MARKER:?}"
exec /usr/bin/python3 "$@"
SH
chmod 755 "$shebangless_python_root/bin/python3"
(
  CLAUDE_RUNTIME_INHERITED_PATH="$shebangless_python_root/bin:${PATH-}"
  SHEBANGLESS_PYTHON_MARKER="$shebangless_python_marker"
  export CLAUDE_RUNTIME_INHERITED_PATH SHEBANGLESS_PYTHON_MARKER
  if claude_runtime_resolve_trusted_python "$ROOT" "$TEST_ROOT/work" "$TEST_ROOT/work"; then
    exit 1
  fi
  [ "$CLAUDE_RUNTIME_PYTHON_STATUS" = "launcher_dependency_unsupported" ] || exit 1
  [ -z "$CLAUDE_RUNTIME_PYTHON_BIN" ] || exit 1
) || fail "shebangless text Python fails closed"
[ ! -e "$shebangless_python_marker" ] || fail "shebangless Python executed during resolution"

mz_python_root="$TEST_ROOT/mz-text-python"
mkdir -p "$mz_python_root/bin"
cat > "$mz_python_root/bin/python3" <<'SH'
MZ() { :; }
printf executed > "${MZ_PYTHON_MARKER:?}"
SH
chmod 755 "$mz_python_root/bin/python3"
(
  CLAUDE_RUNTIME_INHERITED_PATH="$mz_python_root/bin:${PATH-}"
  MZ_PYTHON_MARKER="$TEST_ROOT/mz-text-python-executed"
  export CLAUDE_RUNTIME_INHERITED_PATH MZ_PYTHON_MARKER
  if claude_runtime_resolve_trusted_python "$ROOT" "$TEST_ROOT/work" "$TEST_ROOT/work"; then
    exit 1
  fi
  [ "$CLAUDE_RUNTIME_PYTHON_STATUS" = "launcher_dependency_unsupported" ] || exit 1
) || fail "MZ-prefixed text Python fails closed"
[ ! -e "$TEST_ROOT/mz-text-python-executed" ] || fail "MZ-prefixed text Python executed during resolution"
pass "Python bootstrap requires a native executable header"

claude_runtime_resolve_trusted_python "$ROOT" "$TEST_ROOT/work" "$TEST_ROOT/work" || \
  fail "trusted Python direct transport resolution"
ENV_LOG="$TEST_ROOT/env.log"
ARGV_LOG="$TEST_ROOT/argv.log"
CWD_LOG="$TEST_ROOT/cwd.log"
cat > "$TEST_ROOT/trusted/bin/claude-env" <<'SH'
#!/usr/bin/env bash
printf '%s' "$PATH" > "$ENV_LOG.path"
for name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BEARER_TOKEN ANTHROPIC_CONSOLE_API_KEY ANTHROPIC_CONSOLE_AUTH_TOKEN BASH_ENV ENV NODE_OPTIONS NODE_PATH PYTHONPATH RUBYOPT PERL5OPT ZDOTDIR; do
  if [ -n "${!name+x}" ]; then printf '%s=present\n' "$name" >> "$ENV_LOG"; else printf '%s=absent\n' "$name" >> "$ENV_LOG"; fi
done
printf '%s' "${PRESERVED_SENTINEL:-}" >> "$ENV_LOG"
printf '\nHOME=%s\n' "${HOME:-}" >> "$ENV_LOG"
printf 'TMPDIR=%s\n' "${TMPDIR:-}" >> "$ENV_LOG"
printf 'LC_ALL=%s\n' "${LC_ALL:-}" >> "$ENV_LOG"
printf 'HTTPS_PROXY=%s\n' "${HTTPS_PROXY:-}" >> "$ENV_LOG"
printf 'NO_PROXY=%s\n' "${NO_PROXY:-}" >> "$ENV_LOG"
printf 'NODE_EXTRA_CA_CERTS=%s\n' "${NODE_EXTRA_CA_CERTS:-}" >> "$ENV_LOG"
printf 'CDPATH=%s\n' "${CDPATH-}" >> "$ENV_LOG"
printf '%s\n' "$@" > "$ARGV_LOG"
pwd -P > "$CWD_LOG"
SH
chmod 755 "$TEST_ROOT/trusted/bin/claude-env"
export ENV_LOG ARGV_LOG CWD_LOG
export ANTHROPIC_API_KEY=a ANTHROPIC_AUTH_TOKEN=b ANTHROPIC_BEARER_TOKEN=c
export ANTHROPIC_CONSOLE_API_KEY=d ANTHROPIC_CONSOLE_AUTH_TOKEN=e
export BASH_ENV="$TEST_ROOT/no-bash-env" ENV="$TEST_ROOT/no-env" PRESERVED_SENTINEL="preserved"
original_path="$PATH"
(
  HOME="$TEST_ROOT/runtime-home"
  TMPDIR="$TEST_ROOT/runtime-tmp"
  LC_ALL=C
  HTTPS_PROXY="https://runtime-proxy"
  NO_PROXY="runtime-no-proxy"
  NODE_EXTRA_CA_CERTS="$TEST_ROOT/runtime-ca"
  NODE_OPTIONS="--require=$TEST_ROOT/runtime-node-injection.js"
  NODE_PATH="$TEST_ROOT/runtime-node-path"
  PYTHONPATH="$TEST_ROOT/runtime-python-path"
  RUBYOPT="-r$TEST_ROOT/runtime-ruby-injection.rb"
  PERL5OPT="-M$TEST_ROOT/runtime-perl-injection"
  ZDOTDIR="$TEST_ROOT/runtime-zdotdir"
  CDPATH="$TEST_ROOT/runtime-cdpath-one:$TEST_ROOT/runtime-cdpath-two"
  export HOME TMPDIR LC_ALL HTTPS_PROXY NO_PROXY NODE_EXTRA_CA_CERTS NODE_OPTIONS NODE_PATH PYTHONPATH RUBYOPT PERL5OPT ZDOTDIR CDPATH
  claude_runtime_run_direct \
    "$TEST_ROOT/work" \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    - \
    "$TEST_ROOT/trusted/bin/claude-env" \
    "space arg" \
    "" \
    "equals=value"
)
assert_eq "$original_path" "$(cat "$ENV_LOG.path")" "PATH preserved byte-for-byte"
assert_eq "$TEST_ROOT/work" "$(cat "$CWD_LOG")" "isolated runtime CWD"
grep -q '^ANTHROPIC_API_KEY=absent$' "$ENV_LOG" || fail "API key scrubbed"
grep -q '^BASH_ENV=absent$' "$ENV_LOG" || fail "BASH_ENV scrubbed"
grep -q '^ENV=absent$' "$ENV_LOG" || fail "ENV scrubbed"
for scrubbed_name in NODE_OPTIONS NODE_PATH PYTHONPATH RUBYOPT PERL5OPT ZDOTDIR; do
  grep -q "^${scrubbed_name}=absent$" "$ENV_LOG" || fail "$scrubbed_name scrubbed"
done
grep -q 'preserved$' "$ENV_LOG" || fail "unrelated env preserved"
grep -Fq "HOME=$TEST_ROOT/runtime-home" "$ENV_LOG" || fail "HOME preserved"
grep -Fq "TMPDIR=$TEST_ROOT/runtime-tmp" "$ENV_LOG" || fail "TMPDIR preserved"
grep -Fq 'LC_ALL=C' "$ENV_LOG" || fail "locale preserved"
grep -Fq 'HTTPS_PROXY=https://runtime-proxy' "$ENV_LOG" || fail "proxy preserved"
grep -Fq 'NO_PROXY=runtime-no-proxy' "$ENV_LOG" || fail "NO_PROXY preserved"
grep -Fq "NODE_EXTRA_CA_CERTS=$TEST_ROOT/runtime-ca" "$ENV_LOG" || fail "custom CA preserved"
grep -Fq "CDPATH=$TEST_ROOT/runtime-cdpath-one:$TEST_ROOT/runtime-cdpath-two" "$ENV_LOG" || fail "direct runtime changed exported CDPATH"
[ "$(sed -n '1p' "$ARGV_LOG")" = "space arg" ] || fail "space argv preserved"
[ "$(sed -n '2p' "$ARGV_LOG")" = "" ] || fail "empty argv preserved"
[ "$(sed -n '3p' "$ARGV_LOG")" = "equals=value" ] || fail "equals argv preserved"
pass "direct runtime preserves PATH/argv/env and scrubs pinned variables"

exported_function_launcher="$TEST_ROOT/trusted/bin/exported-function-launcher"
exported_function_marker="$TEST_ROOT/exported-function-executed"
cat > "$exported_function_launcher" <<'SH'
#!/usr/bin/env bash
if declare -F claude_runtime_exported_function_probe >/dev/null 2>&1; then
  claude_runtime_exported_function_probe
  exit 91
fi
printf safe
SH
chmod 755 "$exported_function_launcher"
export EXPORTED_FUNCTION_MARKER="$exported_function_marker"
claude_runtime_exported_function_probe() {
  /usr/bin/printf imported > "${EXPORTED_FUNCTION_MARKER:?}"
}
export -f claude_runtime_exported_function_probe
direct_function_output="$(
  claude_runtime_run_direct \
    "$TEST_ROOT/work" \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    - \
    "$exported_function_launcher"
)"
timeout_function_output="$(
  claude_runtime_run_with_timeout \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    "$TEST_ROOT/work" \
    5 \
    - \
    "$exported_function_launcher"
)"
unset -f claude_runtime_exported_function_probe
unset EXPORTED_FUNCTION_MARKER
assert_eq "safe" "$direct_function_output" "direct exported-function filter"
assert_eq "safe" "$timeout_function_output" "timeout exported-function filter"
[ ! -e "$exported_function_marker" ] || fail "validated Bash launcher imported an exported function"
pass "direct and timeout transports strip exported Bash functions"

python_injection_launcher="$TEST_ROOT/trusted/bin/python-injection-launcher"
python_injection_path="$TEST_ROOT/interpreter-python-path"
python_interpreter_marker="$TEST_ROOT/interpreter-python-startup-executed"
python_injection_home="$TEST_ROOT/interpreter-python-home"
python_home_marker="$TEST_ROOT/interpreter-python-home-startup-executed"
python_user_site="$(HOME="$python_injection_home" "$CLAUDE_RUNTIME_PYTHON_BIN" -I -S -c 'import site; print(site.getusersitepackages())')"
mkdir -p "$python_injection_path" "$python_user_site"
cat > "$python_injection_path/sitecustomize.py" <<'PY'
from pathlib import Path
import os

Path(os.environ["INTERPRETER_INJECTION_MARKER"]).write_text("executed")
PY
cat > "$python_user_site/sitecustomize.py" <<'PY'
from pathlib import Path
import os

Path(os.environ["INTERPRETER_HOME_MARKER"]).write_text("executed")
PY
cat > "$python_injection_launcher" <<'PY'
#!/usr/bin/env python3
print("safe")
PY
chmod 755 "$python_injection_launcher"
claude_runtime_check_launcher_dependency "$python_injection_launcher" || fail "Python launcher dependency transport"
claude_runtime_build_command "$python_injection_launcher"
python_injection_command=("${CLAUDE_RUNTIME_COMMAND[@]}")
direct_python_output="$(
  HOME="$python_injection_home" \
  PYTHONPATH="$python_injection_path" \
  INTERPRETER_INJECTION_MARKER="$python_interpreter_marker" \
  INTERPRETER_HOME_MARKER="$python_home_marker" \
  claude_runtime_run_direct \
    "$TEST_ROOT/work" \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    - \
    "${python_injection_command[@]}"
)"
timeout_python_output="$(
  HOME="$python_injection_home" \
  PYTHONPATH="$python_injection_path" \
  INTERPRETER_INJECTION_MARKER="$python_interpreter_marker" \
  INTERPRETER_HOME_MARKER="$python_home_marker" \
  claude_runtime_run_with_timeout \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    "$TEST_ROOT/work" \
    5 \
    - \
    "${python_injection_command[@]}"
)"
assert_eq "safe" "$direct_python_output" "direct Python startup filter"
assert_eq "safe" "$timeout_python_output" "timeout Python startup filter"
[ ! -e "$python_interpreter_marker" ] || fail "validated Python launcher loaded inherited startup code"
[ ! -e "$python_home_marker" ] || fail "validated Python launcher loaded HOME user-site startup code"
pass "direct and timeout transports strip interpreter startup injection"

for valid_python_name in python python.exe python3 python3.exe python3.14 python3.14.exe pypy pypy3 pypy3.10.exe; do
  claude_runtime_is_python_interpreter_name "$valid_python_name" || fail "valid Python interpreter name rejected: $valid_python_name"
done
for invalid_python_name in python3evil python3evil.exe python3. pypy3evil pypy.3; do
  if claude_runtime_is_python_interpreter_name "$invalid_python_name"; then
    fail "invalid Python interpreter name accepted: $invalid_python_name"
  fi
done
pass "Python interpreter allowlist accepts only numeric version suffixes"

zsh_bin="$(type -P zsh 2>/dev/null || true)"
if [ -n "$zsh_bin" ]; then
  zsh_injection_home="$TEST_ROOT/interpreter-zsh-home"
  zsh_injection_marker="$TEST_ROOT/interpreter-zsh-startup-executed"
  zsh_injection_launcher="$TEST_ROOT/trusted/bin/zsh-injection-launcher"
  mkdir -p "$zsh_injection_home"
  cat > "$zsh_injection_home/.zshenv" <<SH
printf executed > "$zsh_injection_marker"
SH
  printf '#!%s\nprintf safe\n' "$zsh_bin" > "$zsh_injection_launcher"
  chmod 755 "$zsh_injection_launcher"
  claude_runtime_check_launcher_dependency "$zsh_injection_launcher" || fail "zsh launcher dependency transport"
  claude_runtime_build_command "$zsh_injection_launcher"
  zsh_injection_command=("${CLAUDE_RUNTIME_COMMAND[@]}")
  zsh_output="$(
    HOME="$zsh_injection_home" \
    claude_runtime_run_with_timeout \
      "$CLAUDE_RUNTIME_PYTHON_BIN" \
      "$python_driver" \
      "$TEST_ROOT/work" \
      5 \
      - \
      "${zsh_injection_command[@]}"
  )"
  assert_eq "safe" "$zsh_output" "zsh startup filter"
  [ ! -e "$zsh_injection_marker" ] || fail "validated zsh launcher loaded HOME startup code"
fi
pass "validated zsh launcher suppresses HOME startup files"

nested_startup_bin="$TEST_ROOT/nested-startup-bin"
nested_python_interpreter="$nested_startup_bin/nested-python"
nested_python_launcher="$TEST_ROOT/trusted/bin/nested-python-launcher"
mkdir -p "$nested_startup_bin"
cat > "$nested_python_interpreter" <<'PY'
#!/usr/bin/env python3
print("nested-python-safe")
PY
cat > "$nested_python_launcher" <<'SH'
#!/usr/bin/env nested-python
ignored
SH
chmod 755 "$nested_python_interpreter" "$nested_python_launcher"
saved_path="$PATH"
PATH="$nested_startup_bin:$PATH"
export PATH
claude_runtime_check_launcher_dependency "$nested_python_launcher" || fail "nested Python launcher dependency transport"
claude_runtime_build_command "$nested_python_launcher"
nested_python_command=("${CLAUDE_RUNTIME_COMMAND[@]}")
nested_python_output="$(
  HOME="$python_injection_home" \
  INTERPRETER_HOME_MARKER="$python_home_marker" \
  claude_runtime_run_with_timeout \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    "$TEST_ROOT/work" \
    5 \
    - \
    "${nested_python_command[@]}"
)"
PATH="$saved_path"
export PATH
assert_eq "nested-python-safe" "$nested_python_output" "nested Python startup filter"
[ ! -e "$python_home_marker" ] || fail "nested validated Python interpreter loaded HOME user-site startup code"
pass "nested env-to-Python transport preserves isolated/no-site startup flags"

if [ -n "$zsh_bin" ]; then
  nested_zsh_interpreter="$nested_startup_bin/nested-zsh"
  nested_zsh_launcher="$TEST_ROOT/trusted/bin/nested-zsh-launcher"
  cat > "$nested_zsh_interpreter" <<'SH'
#!/usr/bin/env zsh
printf nested-zsh-safe
SH
  cat > "$nested_zsh_launcher" <<'SH'
#!/usr/bin/env nested-zsh
ignored
SH
  chmod 755 "$nested_zsh_interpreter" "$nested_zsh_launcher"
  saved_path="$PATH"
  PATH="$nested_startup_bin:$PATH"
  export PATH
  claude_runtime_check_launcher_dependency "$nested_zsh_launcher" || fail "nested zsh launcher dependency transport"
  claude_runtime_build_command "$nested_zsh_launcher"
  nested_zsh_command=("${CLAUDE_RUNTIME_COMMAND[@]}")
  nested_zsh_output="$(
    HOME="$zsh_injection_home" \
    claude_runtime_run_with_timeout \
      "$CLAUDE_RUNTIME_PYTHON_BIN" \
      "$python_driver" \
      "$TEST_ROOT/work" \
      5 \
      - \
      "${nested_zsh_command[@]}"
  )"
  PATH="$saved_path"
  export PATH
  assert_eq "nested-zsh-safe" "$nested_zsh_output" "nested zsh startup filter"
  [ ! -e "$zsh_injection_marker" ] || fail "nested validated zsh interpreter loaded HOME startup code"
fi
pass "nested env-to-zsh transport preserves no-startup flag"

timeout_cdpath="$TEST_ROOT/timeout-cdpath-one:$TEST_ROOT/timeout-cdpath-two"
claude_runtime_resolve_trusted_python "$ROOT" "$TEST_ROOT/work" "$TEST_ROOT/work" || fail "trusted Python CDPATH transport resolution"
timeout_cdpath_output="$(
  CDPATH="$timeout_cdpath"
  export CDPATH
  claude_runtime_run_with_timeout \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    "$TEST_ROOT/work" \
    5 \
    - \
    /bin/bash -c 'printf "%s" "${CDPATH-}"'
)"
assert_eq "$timeout_cdpath" "$timeout_cdpath_output" "timeout runtime preserves exported CDPATH"
pass "direct and timeout transports preserve exported CDPATH"

cat > "$TEST_ROOT/trusted/bin/missing-env-interpreter" <<'SH'
#!/usr/bin/env definitely-missing-claude-interpreter
SH
chmod 755 "$TEST_ROOT/trusted/bin/missing-env-interpreter"
if claude_runtime_check_launcher_dependency "$TEST_ROOT/trusted/bin/missing-env-interpreter"; then
  fail "missing env interpreter classified"
fi
assert_eq "missing" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" "missing env status"
assert_eq "definitely-missing-claude-interpreter" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY" "safe env dependency"
assert_eq "path" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_RESOLUTION" "env dependency resolution"
assert_eq "env" "$CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_KIND" "env transport kind"
assert_eq "definitely-missing-claude-interpreter" "$CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_ARGUMENT" "env transport argument"

cat > "$TEST_ROOT/trusted/bin/missing-absolute-interpreter" <<'SH'
#!/definitely/missing/claude-interpreter
SH
chmod 755 "$TEST_ROOT/trusted/bin/missing-absolute-interpreter"
if claude_runtime_check_launcher_dependency "$TEST_ROOT/trusted/bin/missing-absolute-interpreter"; then
  fail "missing absolute interpreter classified"
fi
assert_eq "claude-interpreter" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY" "safe absolute dependency basename"
assert_eq "absolute" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_RESOLUTION" "absolute dependency resolution"
assert_eq "absolute" "$CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_KIND" "absolute transport kind"
assert_eq "/definitely/missing/claude-interpreter" "$CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_INTERPRETER_PATH" "absolute transport interpreter"

cat > "$TEST_ROOT/trusted/bin/unsupported-env-s" <<'SH'
#!/usr/bin/env -S missing --flag
SH
chmod 755 "$TEST_ROOT/trusted/bin/unsupported-env-s"
if claude_runtime_check_launcher_dependency "$TEST_ROOT/trusted/bin/unsupported-env-s"; then
  fail "env -S shebang accepted without deterministic parsing"
fi
assert_eq "unsupported" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" "env -S fails closed"
cat > "$TEST_ROOT/trusted/bin/unsupported-absolute-arg" <<'SH'
#!/bin/bash -e
SH
chmod 755 "$TEST_ROOT/trusted/bin/unsupported-absolute-arg"
if claude_runtime_check_launcher_dependency "$TEST_ROOT/trusted/bin/unsupported-absolute-arg"; then
  fail "absolute shebang argument accepted without cross-platform transport semantics"
fi
assert_eq "unsupported" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" "absolute shebang argument fails closed"
claude_runtime_check_launcher_dependency /bin/echo || fail "native candidate remains unknown"
assert_eq "unknown" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" "native not classified from exit behavior"
assert_eq "direct" "$CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_KIND" "native direct transport kind"
pass "launcher dependency classification is bounded to recognized shebangs"

cat > "$TEST_ROOT/trusted/bin/malformed-shebang" <<'SH'
#!
exit 127
SH
chmod 755 "$TEST_ROOT/trusted/bin/malformed-shebang"
if claude_runtime_check_launcher_dependency "$TEST_ROOT/trusted/bin/malformed-shebang"; then
  fail "malformed shebang accepted"
fi
assert_eq "unsupported" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" "malformed shebang fails closed"
cat > "$TEST_ROOT/trusted/bin/env-extra" <<'SH'
#!/usr/bin/env missing-name extra
exit 127
SH
chmod 755 "$TEST_ROOT/trusted/bin/env-extra"
if claude_runtime_check_launcher_dependency "$TEST_ROOT/trusted/bin/env-extra"; then
  fail "env with extra args accepted"
fi
assert_eq "unsupported" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" "env extra fails closed"

# Root bypasses these DAC mode bits, so this fixture is meaningful only for an
# identity whose read access is actually constrained by them.
if [ "${EUID:-1}" -ne 0 ]; then
  cat > "$TEST_ROOT/trusted/bin/unreadable-launcher" <<'SH'
#!/bin/bash
exit 0
SH
  chmod 111 "$TEST_ROOT/trusted/bin/unreadable-launcher"
  if claude_runtime_check_launcher_dependency "$TEST_ROOT/trusted/bin/unreadable-launcher"; then
    fail "unreadable launcher accepted as native"
  fi
  assert_eq "unreadable" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" "unreadable launcher fails closed"
fi

cycle_a="$TEST_ROOT/trusted/bin/cycle-a"
cycle_b="$TEST_ROOT/trusted/bin/cycle-b"
printf '#!%s\n' "$cycle_b" > "$cycle_a"
printf '#!%s\n' "$cycle_a" > "$cycle_b"
chmod 755 "$cycle_a" "$cycle_b"
if claude_runtime_check_launcher_dependency "$cycle_a"; then
  fail "cyclic shebang chain accepted"
fi
assert_eq "unsupported" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" "cyclic shebang fails closed"
assert_eq "shebang_cycle" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY" "cyclic shebang reason"

cat > "$TEST_ROOT/trusted/bin/existing-interpreter-exit" <<'SH'
#!/bin/bash
exit 127
SH
chmod 755 "$TEST_ROOT/trusted/bin/existing-interpreter-exit"
claude_runtime_check_launcher_dependency "$TEST_ROOT/trusted/bin/existing-interpreter-exit" || fail "existing interpreter available"
assert_eq "available" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" "exit code never drives dependency classification"
assert_eq "/bin/bash" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH" "absolute interpreter path retained for trust validation"
assert_eq "2" "${#CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND[@]}" "absolute transport argv count"
assert_eq "/bin/bash" "${CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND[0]}" "absolute transport executable"
assert_eq "$TEST_ROOT/trusted/bin/existing-interpreter-exit" "${CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND[1]}" "absolute transport launcher"
pass "unsupported shebangs fail closed while exit-code-only cases remain unclassified"

dependency_invocation="$TEST_ROOT/dependency-invocation"
dependency_launcher="$TEST_ROOT/trusted/bin/path-interpreter"
mkdir -p "$dependency_invocation/bin"
ln -s /bin/bash "$dependency_invocation/bin/node"
cat > "$dependency_launcher" <<'SH'
#!/usr/bin/env node
exit 0
SH
chmod 755 "$dependency_launcher"
saved_path="$PATH"
PATH="$dependency_invocation/bin:$PATH"
export PATH
claude_runtime_check_launcher_dependency "$dependency_launcher" || fail "PATH interpreter resolved"
assert_eq "/usr/bin/env" "$CLAUDE_RUNTIME_LAUNCHER_INTERPRETER_PATH" "exact env interpreter retained"
assert_eq "$dependency_invocation/bin/node" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH" "PATH interpreter path retained"
assert_eq "2" "${#CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND[@]}" "env transport argv count"
assert_eq "$dependency_invocation/bin/node" "${CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND[0]}" "env transport resolved executable"
assert_eq "$dependency_launcher" "${CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND[1]}" "env transport launcher"
claude_locator_validate_candidate "$dependency_launcher" "$ROOT" "$TEST_ROOT/work" || fail "launcher remains trusted"
selected_launch="$CLAUDE_LOCATOR_LAUNCH_PATH"
selected_target="$CLAUDE_LOCATOR_CANONICAL_TARGET"
claude_locator_validate_launcher_dependency "$CLAUDE_RUNTIME_LAUNCHER_INTERPRETER_PATH" "$ROOT" "$dependency_invocation" || fail "alternate env interpreter remains trusted"
if claude_locator_validate_launcher_dependency "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH" "$ROOT" "$dependency_invocation"; then
  fail "interpreter inside invocation CWD rejected"
fi
assert_eq "launch" "$CLAUDE_LOCATOR_DEPENDENCY_VALIDATION_SCOPE" "dependency trust scope"
assert_eq "invocation_cwd_path" "$CLAUDE_LOCATOR_DEPENDENCY_VALIDATION_STATUS" "dependency trust reason"
assert_eq "$selected_launch" "$CLAUDE_LOCATOR_LAUNCH_PATH" "launcher diagnostic launch path preserved"
assert_eq "$selected_target" "$CLAUDE_LOCATOR_CANONICAL_TARGET" "launcher diagnostic target preserved"
PATH="$saved_path"
export PATH
pass "exact env and resolved interpreters reuse trust validation without clobbering launcher diagnostics"

unsupported_native_launcher="$TEST_ROOT/trusted/bin/unsupported-native-launcher"
ln -s /bin/bash "$dependency_invocation/bin/python3evil"
cat > "$unsupported_native_launcher" <<'SH'
#!/usr/bin/env python3evil
exit 0
SH
chmod 755 "$unsupported_native_launcher"
saved_path="$PATH"
PATH="$dependency_invocation/bin:$PATH"
export PATH
if claude_runtime_check_launcher_dependency "$unsupported_native_launcher"; then
  fail "unknown native shebang interpreter accepted"
fi
assert_eq "unsupported" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" "unknown native interpreter status"
assert_eq "python3evil" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY" "unknown native interpreter reason"
PATH="$saved_path"
export PATH
pass "unknown native shebang interpreters fail closed before HOME startup"

alternate_env="$TEST_ROOT/trusted/bin/env"
alternate_env_launcher="$TEST_ROOT/trusted/bin/alternate-env-launcher"
ln -s /usr/bin/env "$alternate_env"
printf '#!%s node\nexit 0\n' "$alternate_env" > "$alternate_env_launcher"
chmod 755 "$alternate_env_launcher"
if claude_runtime_check_launcher_dependency "$alternate_env_launcher"; then
  fail "non-exact env shebang accepted"
fi
assert_eq "unsupported" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" "non-exact env shebang fails closed"
assert_eq "shebang" "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY" "non-exact env shebang reason"
pass "only exact /usr/bin/env NAME shebangs are accepted"

execution_root="$TEST_ROOT/execution-cwd-dependency"
execution_invocation="$execution_root/invocation/work"
execution_runtime="$execution_root/runtime/work"
execution_launcher="$TEST_ROOT/trusted/bin/execution-cwd-launcher"
mkdir -p "$execution_invocation" "$execution_root/invocation/bin" "$execution_runtime" "$execution_root/runtime/bin"
printf '#!/bin/bash\nexit 0\n' > "$execution_root/invocation/bin/runtime-node"
printf '#!/bin/bash\nexit 0\n' > "$execution_root/runtime/bin/runtime-node"
printf '#!/usr/bin/env runtime-node\nexit 0\n' > "$execution_launcher"
chmod 755 "$execution_root/invocation/bin/runtime-node" "$execution_root/runtime/bin/runtime-node" "$execution_launcher"
saved_path="$PATH"
(
  runtime_node_path=""
  cd "$execution_invocation"
  PATH="../bin:/usr/bin:/bin"
  export PATH
  claude_runtime_check_launcher_dependency "$execution_launcher" "$execution_runtime" || exit 1
  for dependency_path in "${CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATHS[@]}"; do
    case "$dependency_path" in
      */runtime-node)
        runtime_node_path="$dependency_path"
        ;;
    esac
  done
  [ -n "$runtime_node_path" ] || exit 1
  claude_locator_validate_launcher_dependency "$runtime_node_path" "$ROOT" "$execution_invocation" || exit 1
  [ "$CLAUDE_LOCATOR_DEPENDENCY_LAUNCH_PATH" = "$execution_root/runtime/bin/runtime-node" ] || exit 1
) || fail "env interpreter resolved from runtime execution CWD"
PATH="$saved_path"
export PATH
pass "env shebang PATH lookup matches the private runtime execution CWD"

nested_launcher="$TEST_ROOT/trusted/bin/nested-launcher"
nested_wrapper="$TEST_ROOT/trusted/bin/nested-node"
nested_interpreter="$dependency_invocation/bin/nested-python"
printf '#!/bin/bash\nexit 0\n' > "$nested_interpreter"
printf '#!%s\nexit 0\n' "$nested_interpreter" > "$nested_wrapper"
printf '#!/usr/bin/env nested-node\nexit 0\n' > "$nested_launcher"
chmod 755 "$nested_interpreter" "$nested_wrapper" "$nested_launcher"
saved_path="$PATH"
PATH="$TEST_ROOT/trusted/bin:$PATH"
export PATH
claude_runtime_check_launcher_dependency "$nested_launcher" || fail "nested shebang chain classified"
nested_wrapper_found=false
for dependency_path in "${CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATHS[@]}"; do
  [ "$dependency_path" = "$nested_wrapper" ] && nested_wrapper_found=true
done
[ "$nested_wrapper_found" = true ] || fail "nested wrapper missing from dependency chain"
if claude_locator_validate_launcher_dependency "$nested_interpreter" "$ROOT" "$dependency_invocation"; then
  fail "nested unsafe interpreter accepted"
fi
assert_eq "invocation_cwd_path" "$CLAUDE_LOCATOR_DEPENDENCY_VALIDATION_STATUS" "nested interpreter trust reason"
PATH="$saved_path"
export PATH
pass "recursive shebang inspection exposes nested interpreters to trust validation"

# A BASH_ENV/ENV set in an already-running shell must not reach or initialize the
# candidate interpreter.
cat > "$TEST_ROOT/bash-env-sentinel.sh" <<SH
printf loaded > "$TEST_ROOT/bash-env-loaded"
SH
cat > "$TEST_ROOT/env-sentinel.sh" <<SH
printf loaded > "$TEST_ROOT/env-loaded"
SH
cat > "$TEST_ROOT/trusted/bin/startup-check" <<'SH'
#!/bin/bash
exit 0
SH
chmod 755 "$TEST_ROOT/trusted/bin/startup-check"
export BASH_ENV="$TEST_ROOT/bash-env-sentinel.sh"
export ENV="$TEST_ROOT/env-sentinel.sh"
claude_runtime_run_direct \
  "$TEST_ROOT/work" \
  "$CLAUDE_RUNTIME_PYTHON_BIN" \
  "$python_driver" \
  - \
  "$TEST_ROOT/trusted/bin/startup-check"
[ ! -e "$TEST_ROOT/bash-env-loaded" ] || fail "candidate sourced BASH_ENV"
[ ! -e "$TEST_ROOT/env-loaded" ] || fail "candidate sourced ENV"
unset BASH_ENV ENV
pass "already-running Bash startup variables are scrubbed before candidate execution"

# Permanent projected parity with the retained compatibility helper.
parity_candidate="$TEST_ROOT/trusted/bin/parity-candidate"
cat > "$parity_candidate" <<'SH'
#!/bin/bash
printf 'argv-count=%s\n' "$#" > "$PARITY_OUT.argv"
for arg in "$@"; do printf 'arg=[%s]\n' "$arg" >> "$PARITY_OUT.argv"; done
for name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BEARER_TOKEN ANTHROPIC_CONSOLE_API_KEY ANTHROPIC_CONSOLE_AUTH_TOKEN BASH_ENV ENV HOME PATH TMPDIR CLAUDE_CONFIG_DIR HTTPS_PROXY PRESERVED_SENTINEL; do
  if /usr/bin/env | /usr/bin/grep -q "^${name}="; then
    value="$(/usr/bin/env | /usr/bin/grep "^${name}=" | /usr/bin/sed -n '1s/^[^=]*=//p')"
    printf '%s=present:%s\n' "$name" "$value" >> "$PARITY_OUT.env"
  else
    printf '%s=absent\n' "$name" >> "$PARITY_OUT.env"
  fi
done
pwd -P > "$PARITY_OUT.cwd"
SH
chmod 755 "$parity_candidate"
parity_old="$TEST_ROOT/parity-old"
parity_new="$TEST_ROOT/parity-new"
mkdir -p "$parity_old" "$parity_new"
parity_path="$PATH"
(
  cd "$parity_old"
  PARITY_OUT="$parity_old/result" \
  ANTHROPIC_API_KEY=a ANTHROPIC_AUTH_TOKEN=b ANTHROPIC_BEARER_TOKEN=c \
  ANTHROPIC_CONSOLE_API_KEY=d ANTHROPIC_CONSOLE_AUTH_TOKEN=e \
  BASH_ENV="$TEST_ROOT/nonexistent-bash-env" ENV="$TEST_ROOT/nonexistent-env" \
  TMPDIR="$TEST_ROOT/parity-tmp" CLAUDE_CONFIG_DIR="$TEST_ROOT/parity-config" \
  HTTPS_PROXY="https://parity-proxy" PRESERVED_SENTINEL="same" \
  "$ROOT/scripts/claude-subscription-env.sh" "$parity_candidate" "space arg" "" "equals=value"
)
(
  export PARITY_OUT="$parity_new/result"
  export ANTHROPIC_API_KEY=a ANTHROPIC_AUTH_TOKEN=b ANTHROPIC_BEARER_TOKEN=c
  export ANTHROPIC_CONSOLE_API_KEY=d ANTHROPIC_CONSOLE_AUTH_TOKEN=e
  export BASH_ENV="$TEST_ROOT/nonexistent-bash-env" ENV="$TEST_ROOT/nonexistent-env"
  export TMPDIR="$TEST_ROOT/parity-tmp" CLAUDE_CONFIG_DIR="$TEST_ROOT/parity-config"
  export HTTPS_PROXY="https://parity-proxy" PRESERVED_SENTINEL="same"
  claude_runtime_run_direct \
    "$parity_new" \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    - \
    "$parity_candidate" \
    "space arg" \
    "" \
    "equals=value"
)
cmp "$parity_old/result.argv" "$parity_new/result.argv" >/dev/null || fail "legacy/runtime argv parity"
for name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BEARER_TOKEN ANTHROPIC_CONSOLE_API_KEY ANTHROPIC_CONSOLE_AUTH_TOKEN HOME PATH TMPDIR CLAUDE_CONFIG_DIR HTTPS_PROXY PRESERVED_SENTINEL; do
  old_line="$(grep "^${name}=" "$parity_old/result.env")"
  new_line="$(grep "^${name}=" "$parity_new/result.env")"
  assert_eq "$old_line" "$new_line" "projected parity $name"
done
grep -q '^BASH_ENV=present:' "$parity_old/result.env" || fail "legacy helper should preserve BASH_ENV"
grep -q '^ENV=present:' "$parity_old/result.env" || fail "legacy helper should preserve ENV"
grep -q '^BASH_ENV=absent$' "$parity_new/result.env" || fail "new runtime removes BASH_ENV"
grep -q '^ENV=absent$' "$parity_new/result.env" || fail "new runtime removes ENV"
assert_eq "$parity_old" "$(cat "$parity_old/result.cwd")" "legacy helper CWD"
assert_eq "$parity_new" "$(cat "$parity_new/result.cwd")" "new isolated CWD"
assert_eq "$parity_path" "$PATH" "test shell PATH unchanged"
pass "retained helper and new runtime projected parity"

# Descendant tools receive exactly the inherited PATH; profiles are never a
# hidden retry source.
descendant_tools="$TEST_ROOT/descendant-tools"
mkdir -p "$descendant_tools"
cat > "$descendant_tools/fake-runtime-tool" <<SH
#!/bin/bash
printf ran > "$TEST_ROOT/descendant-ran"
SH
chmod 755 "$descendant_tools/fake-runtime-tool"
cat > "$TEST_ROOT/trusted/bin/descendant-claude" <<'SH'
#!/bin/bash
fake-runtime-tool
SH
chmod 755 "$TEST_ROOT/trusted/bin/descendant-claude"
(
  PATH="$descendant_tools:$PATH"
  export PATH
  claude_runtime_run_direct \
    "$TEST_ROOT/work" \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    - \
    "$TEST_ROOT/trusted/bin/descendant-claude"
)
[ -e "$TEST_ROOT/descendant-ran" ] || fail "inherited descendant helper did not run"
rm -f "$TEST_ROOT/descendant-ran"
cat > "$TEST_ROOT/profile-only.sh" <<SH
export PATH="$descendant_tools:\$PATH"
printf loaded > "$TEST_ROOT/descendant-profile-loaded"
SH
set +e
(
  PATH="/usr/bin:/bin"
  BASH_ENV="$TEST_ROOT/profile-only.sh"
  export PATH BASH_ENV
  claude_runtime_run_direct \
    "$TEST_ROOT/work" \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    - \
    "$TEST_ROOT/trusted/bin/descendant-claude"
) >/dev/null 2>&1
descendant_status=$?
set -e
[ "$descendant_status" -ne 0 ] || fail "profile-only descendant helper unexpectedly ran"
[ ! -e "$TEST_ROOT/descendant-ran" ] || fail "profile-only descendant helper marker exists"
[ ! -e "$TEST_ROOT/descendant-profile-loaded" ] || fail "runtime loaded descendant profile"
pass "descendant tools obey unchanged inherited PATH without profile retry"

EMPTY_PATH_LOG="$TEST_ROOT/empty-path.log"
export EMPTY_PATH_LOG
cat > "$TEST_ROOT/trusted/bin/empty-path-claude" <<'SH'
#!/bin/bash
printf '%s' "$PATH" > "$EMPTY_PATH_LOG"
SH
chmod 755 "$TEST_ROOT/trusted/bin/empty-path-claude"
(
  PATH="/usr/bin:/bin"
  CLAUDE_RUNTIME_INHERITED_PATH=""
  export PATH CLAUDE_RUNTIME_INHERITED_PATH
  claude_runtime_run_direct \
    "$TEST_ROOT/work" \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$python_driver" \
    - \
    "$TEST_ROOT/trusted/bin/empty-path-claude"
  [ -z "$(claude_runtime_resolve_path_dependency env "$TEST_ROOT/work")" ] || exit 1
) || fail "direct runtime must preserve an empty inherited PATH"
[ ! -s "$EMPTY_PATH_LOG" ] || fail "direct runtime replaced an empty inherited PATH"
pass "direct and dependency runtimes preserve empty inherited PATH byte-for-byte"

# Bounded source-purity checks: no output, hang, CWD/env mutation, or writes.
python3 - "$LOCATOR" "$RUNTIME" "$TEST_ROOT/source-purity" <<'PY'
from pathlib import Path
import os
import subprocess
import sys

helpers = sys.argv[1:3]
cwd = Path(sys.argv[3])
cwd.mkdir()
before_files = sorted(str(p.relative_to(cwd)) for p in cwd.rglob("*"))
for helper in helpers:
    env = os.environ.copy()
    env.pop("BASH_ENV", None)
    env.pop("ENV", None)
    env["PURITY_SENTINEL"] = "unchanged"
    code = r'''
before_pwd="$PWD"
before_env="$(/usr/bin/env | /usr/bin/sort)"
source "$1"
after_env="$(/usr/bin/env | /usr/bin/sort)"
[ "$PWD" = "$before_pwd" ] || exit 21
[ "$before_env" = "$after_env" ] || exit 22
printf 'purity-ok\n'
'''
    proc = subprocess.run(
        ["/bin/bash", "--noprofile", "--norc", "-c", code, "bash", helper],
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        timeout=3,
        shell=False,
    )
    if proc.returncode != 0 or proc.stdout != "purity-ok\n" or proc.stderr:
        raise SystemExit(f"source purity failed for {helper}: rc={proc.returncode} out={proc.stdout!r} err={proc.stderr!r}")
after_files = sorted(str(p.relative_to(cwd)) for p in cwd.rglob("*"))
if before_files != after_files:
    raise SystemExit(f"helper source wrote files: before={before_files!r} after={after_files!r}")
PY
pass "bounded helper source purity"

assert_eq "direct_inherited_path_v10" "$CLAUDE_RUNTIME_CONTRACT" "runtime contract label"
pass "shared helper contracts"
