#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -Fq '/bin/bash scripts/run-review.sh' "$ROOT/tests/windows-transport.sh" || fail "Windows test lacks production runner coverage"
grep -Fq 'shim_root/claude' "$ROOT/tests/windows-transport.sh" || fail "Windows test lacks extensionless shim coverage"
grep -Fq 'runs-on: windows-latest' "$ROOT/.github/workflows/ci.yml" || fail "Windows Git Bash CI job missing"
grep -Fq 'if os.name == "nt"' "$ROOT/scripts/claude-doctor.sh" || fail "doctor lacks Windows timeout termination"
if grep -Fq 'start_new_session=True' "$ROOT/scripts/claude-doctor.sh"; then
  fail "doctor unconditionally requests a Unix process session"
fi
grep -Fq 'subprocess.CREATE_NEW_PROCESS_GROUP' "$ROOT/scripts/run-review.sh" || fail "runner lacks Windows timeout process-group creation"
if grep -Fq 'start_new_session=True' "$ROOT/scripts/run-review.sh"; then
  fail "runner unconditionally requests a Unix process session"
fi

case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*)
    ;;
  *)
    printf 'ok: Windows transport skipped outside Git Bash\n'
    exit 0
    ;;
esac

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
shim_root="$(mktemp -d "$HOME/claude-review Windows=shim-XXXXXX")"
artifact_file="$(mktemp /tmp/claude-review-windows-artifact-XXXXXX)"
trap 'rm -rf "$fixture_root" "$runtime_cwd" "$shim_root" "$artifact_file"' EXIT
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
  cd "$runtime_cwd"
  MSYS2_ARG_CONV_EXCL='*' "${CLAUDE_RUNTIME_COMMAND[@]}"
})"
printf '%s' "$direct_output" | grep -Fq 'direct-ok' || fail "direct .exe transport or env scrubbing"

claude_runtime_build_command "$CLAUDE_LOCATOR_LAUNCH_PATH" /d /c echo "space arg" "" "equals=value"
argv_output="$({
  claude_runtime_scrub_environment
  cd "$runtime_cwd"
  MSYS2_ARG_CONV_EXCL='*' "${CLAUDE_RUNTIME_COMMAND[@]}"
})"
printf '%s' "$argv_output" | grep -Fq 'space arg' || fail "space argv lost"
printf '%s' "$argv_output" | grep -Fq 'equals=value' || fail "equals argv lost"

python_bin="$(type -P python3 2>/dev/null || type -P python 2>/dev/null || true)"
[ -n "$python_bin" ] || fail "Python unavailable for timeout transport"
claude_runtime_check_launcher_dependency "$CLAUDE_LOCATOR_CANONICAL_TARGET" "$runtime_cwd" || fail "native Windows executable classification"
[ "$CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_KIND" = "direct" ] || fail "native .exe transport kind"
claude_runtime_build_command "$CLAUDE_LOCATOR_LAUNCH_PATH" /d /c "echo timeout-ok"
claude_runtime_prepare_python_argv "${CLAUDE_RUNTIME_COMMAND[@]}" || fail "production Python argv preparation"
timeout_output="$({
  claude_runtime_scrub_environment
  cd "$runtime_cwd"
  MSYS2_ARG_CONV_EXCL='*' "$python_bin" - 10 "${CLAUDE_RUNTIME_PYTHON_ARGV[@]}" <<'PY'
import os
import subprocess
import sys

if sys.argv[2].startswith("/"):
    raise SystemExit(f"executable was not converted for native Python: {sys.argv[2]!r}")
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

# Exercise the actual runner with an extensionless Git Bash/npm-style shim. This
# covers canonical input boundaries, validated shebang transport, internal MSYS
# argument-conversion control, preflight, and the final timeout call site without
# invoking a real or paid Claude installation.
shim_log="$shim_root/calls.log"
cat > "$shim_root/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${MSYS2_ARG_CONV_EXCL-}" = "*" ]; then
  printf 'internal MSYS conversion override leaked to Claude\n' >&2
  exit 91
fi
if [ -n "${ANTHROPIC_API_KEY+x}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN+x}" ]; then
  printf 'Anthropic credential variable leaked to Claude\n' >&2
  exit 92
fi
{
  printf 'call=%s\n' "${1:-none}"
  printf 'msys=%s\n' "${MSYS2_ARG_CONV_EXCL-absent}"
  printf 'cwd=%s\n' "$(pwd -P)"
} >> "${WINDOWS_SHIM_LOG:?}"

if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
  printf 'Claude Code Windows shim\n'
  exit 0
fi
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf '{"loggedIn":true,"apiProvider":"firstParty"}\n'
  exit 0
fi
if [ "${1:-}" = "-p" ]; then
  if [[ "${2:-}" == *"Codex Claude skill preflight probe"* ]]; then
    printf '{"ok":true}\n'
  else
    printf '{"status":"clean","mode":"code","summary":"windows-runner-ok","findings":[],"open_questions":[]}\n'
  fi
  exit 0
fi
exit 2
SH
chmod 755 "$shim_root/claude"
printf 'windows runner artifact\n' > "$artifact_file"
unset MSYS2_ARG_CONV_EXCL
runner_output="$({
  cd "$ROOT"
  PATH="$shim_root:$PATH" \
  WINDOWS_SHIM_LOG="$shim_log" \
  ANTHROPIC_API_KEY=runner-secret \
  ANTHROPIC_AUTH_TOKEN=runner-secret \
  /bin/bash scripts/run-review.sh \
    --mode code \
    --artifact-file "$artifact_file" \
    --base-prompt "$ROOT/prompts/code-review.base.md" \
    --schema-file "$ROOT/schemas/review-output.json" \
    --repo-root "$ROOT" \
    --branch windows-test \
    --base-branch main
})"
RUNNER_OUTPUT="$runner_output" "$python_bin" - <<'PY'
import json
import os

data = json.loads(os.environ["RUNNER_OUTPUT"])
assert data["status"] == "clean", data
assert data["mode"] == "code", data
assert data["summary"] == "windows-runner-ok", data
PY
grep -Fq 'call=-p' "$shim_log" || fail "production runner never reached shim timeout call sites"
if grep -Fq 'msys=*' "$shim_log"; then
  fail "production transport leaked its internal MSYS conversion override"
fi
grep -Eq '^cwd=/[a-zA-Z]?/?(private/)?tmp/claude-review-runtime-' "$shim_log" || fail "production runner skipped private runtime CWD"

doctor_output="$({
  cd "$ROOT"
  PATH="$shim_root:$PATH" \
  WINDOWS_SHIM_LOG="$shim_log" \
  ANTHROPIC_API_KEY=doctor-secret \
  ANTHROPIC_AUTH_TOKEN=doctor-secret \
  /bin/bash scripts/claude-doctor.sh \
    --repo-root "$ROOT" \
    --skill-root "$ROOT" \
    --config-file "$ROOT/.codex/claude/config.env" \
    --probe-timeout 10 \
    --skip-update-check
})"
printf '%s\n' "$doctor_output" | grep -Fqx 'doctor_status=ok' || fail "production doctor did not complete"
printf '%s\n' "$doctor_output" | grep -Fqx 'claude_path_status=available' || fail "production doctor did not select PATH shim"
printf '%s\n' "$doctor_output" | grep -Fqx 'plain_print_probe_status=completed' || fail "doctor plain probe missed native-Python transport"
printf '%s\n' "$doctor_output" | grep -Fqx 'safe_mode_print_probe_status=completed' || fail "doctor safe-mode probe missed native-Python transport"
if grep -Fq 'msys=*' "$shim_log"; then
  fail "doctor transport leaked its internal MSYS conversion override"
fi

printf 'ok: Windows Git Bash PATH-only .exe and extensionless-shim runner/doctor transport\n'
