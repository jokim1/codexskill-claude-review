#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*)
    ;;
  *)
    printf 'ok: Windows transport skipped outside Git Bash\n'
    exit 0
    ;;
esac

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=/dev/null
source "$ROOT/scripts/claude-locator.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/claude-runtime.sh"

for platform in msys mingw64_nt cygwin; do
  if claude_locator_native_supported "$platform"; then
    fail "native fallback unexpectedly enabled for $platform"
  fi
done

fixture_root="$(mktemp -d "$HOME/claude-review Windows=transport-XXXXXX")"
runtime_cwd="$(mktemp -d /tmp/claude-review-runtime-windows-XXXXXX)"
trap 'rm -rf "$fixture_root" "$runtime_cwd"' EXIT
windows_cmd="$(cygpath -u "$WINDIR/System32/cmd.exe")"
cp "$windows_cmd" "$fixture_root/claude.exe"
chmod 755 "$fixture_root/claude.exe"

PATH="$fixture_root:$PATH"
export PATH
claude_locator_path_candidate "$PWD" || fail "Git Bash did not resolve claude.exe from PATH"
[ "$CLAUDE_LOCATOR_CANDIDATE_SOURCE" = "path" ] || fail "Windows candidate source"
case "$CLAUDE_LOCATOR_CANDIDATE_PATH" in
  *claude.exe) ;;
  *) fail "Windows PATH result omitted .exe: $CLAUDE_LOCATOR_CANDIDATE_PATH" ;;
esac
if ! claude_locator_validate_candidate "$CLAUDE_LOCATOR_CANDIDATE_PATH" "$ROOT" "$PWD"; then
  fail "Windows .exe trust validation: $CLAUDE_LOCATOR_VALIDATION_SCOPE:$CLAUDE_LOCATOR_VALIDATION_STATUS"
fi

export ANTHROPIC_API_KEY=secret
export ANTHROPIC_AUTH_TOKEN=secret
export ANTHROPIC_BEARER_TOKEN=secret
export ANTHROPIC_CONSOLE_API_KEY=secret
export ANTHROPIC_CONSOLE_AUTH_TOKEN=secret
export BASH_ENV="$fixture_root/never-source"
export ENV="$fixture_root/never-source-env"

claude_runtime_build_command "$CLAUDE_LOCATOR_LAUNCH_PATH" /d /c "if defined ANTHROPIC_API_KEY (exit /b 41) else (echo direct-ok)"
direct_output="$({
  claude_runtime_scrub_environment
  export MSYS2_ARG_CONV_EXCL='*'
  cd "$runtime_cwd"
  "${CLAUDE_RUNTIME_COMMAND[@]}"
})"
printf '%s' "$direct_output" | grep -Fq 'direct-ok' || fail "direct .exe transport or env scrubbing"

claude_runtime_build_command "$CLAUDE_LOCATOR_LAUNCH_PATH" /d /c echo "space arg" "" "equals=value"
argv_output="$({
  claude_runtime_scrub_environment
  export MSYS2_ARG_CONV_EXCL='*'
  cd "$runtime_cwd"
  "${CLAUDE_RUNTIME_COMMAND[@]}"
})"
printf '%s' "$argv_output" | grep -Fq 'space arg' || fail "space argv lost"
printf '%s' "$argv_output" | grep -Fq 'equals=value' || fail "equals argv lost"

python_bin="$(type -P python3 2>/dev/null || type -P python 2>/dev/null || true)"
[ -n "$python_bin" ] || fail "Python unavailable for timeout transport"
claude_runtime_build_command "$CLAUDE_LOCATOR_LAUNCH_PATH" /d /c "echo timeout-ok"
timeout_output="$({
  claude_runtime_scrub_environment
  export MSYS2_ARG_CONV_EXCL='*'
  cd "$runtime_cwd"
  "$python_bin" - 10 "${CLAUDE_RUNTIME_COMMAND[@]}" <<'PY'
import os
import subprocess
import sys

completed = subprocess.run(
    sys.argv[2:],
    cwd=os.getcwd(),
    shell=False,
    capture_output=True,
    text=True,
    timeout=int(sys.argv[1]),
)
sys.stdout.write(completed.stdout)
sys.stderr.write(completed.stderr)
raise SystemExit(completed.returncode)
PY
})"
printf '%s' "$timeout_output" | grep -Fq 'timeout-ok' || fail "Python discrete-argv .exe transport"

printf 'ok: Windows Git Bash PATH-only .exe direct and Python transport\n'
