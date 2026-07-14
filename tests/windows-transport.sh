#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -Fq 'runs-on: windows-latest' "$ROOT/.github/workflows/ci.yml" || fail "Windows Git Bash CI job missing"
grep -Fq 'pythonLocation/python3.exe' "$ROOT/.github/workflows/ci.yml" || fail "Windows CI does not materialize production python3.exe"
python3 - "$ROOT/scripts/claude-runtime.sh" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
for token in (
    "JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE",
    "AssignProcessToJobObject",
    "TerminateJobObject",
    "subprocess.CREATE_NEW_PROCESS_GROUP",
    'process_options["start_new_session"] = True',
    "proc.communicate(timeout=3)",
    "proc.wait(timeout=1)",
):
    if token not in text:
        raise SystemExit(f"shared runtime driver lacks {token}")
if "proc.communicate()" in text:
    raise SystemExit("shared runtime driver retains an unbounded final communicate")
PY

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
windows_bash="$(type -P bash 2>/dev/null || true)"
[ -n "$windows_bash" ] || fail "Git Bash executable unavailable"
cp "$windows_bash" "$fixture_root/claude.exe"
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

cygpath_bin="$(type -P cygpath 2>/dev/null || true)"
[ -n "$cygpath_bin" ] || fail "trusted cygpath unavailable"
windows_temp_root="$("$cygpath_bin" -aw "$fixture_root")"
if TEMP="$windows_temp_root" claude_locator_validate_candidate "$CLAUDE_LOCATOR_CANDIDATE_PATH" "$ROOT" "$PWD"; then
  fail "Windows-form TEMP root passed trust validation"
fi
[ "$CLAUDE_LOCATOR_VALIDATION_STATUS" = "temporary_path" ] || fail "Windows-form TEMP trust reason"
claude_locator_validate_candidate "$CLAUDE_LOCATOR_CANDIDATE_PATH" "$ROOT" "$PWD" || fail "Windows candidate did not recover after scoped TEMP test"

export ANTHROPIC_API_KEY=secret
export ANTHROPIC_AUTH_TOKEN=secret
export ANTHROPIC_BEARER_TOKEN=secret
export ANTHROPIC_CONSOLE_API_KEY=secret
export ANTHROPIC_CONSOLE_AUTH_TOKEN=secret
export BASH_ENV="$fixture_root/never-source"
export ENV="$fixture_root/never-source-env"

claude_runtime_build_command \
  "$CLAUDE_LOCATOR_LAUNCH_PATH" \
  --noprofile \
  --norc \
  -c \
  'if [ -n "${ANTHROPIC_API_KEY+x}" ]; then exit 41; else printf "direct-ok\n"; fi'
direct_output="$({
  claude_runtime_scrub_environment
  cd "$runtime_cwd"
  MSYS2_ARG_CONV_EXCL='*' "${CLAUDE_RUNTIME_COMMAND[@]}"
})"
printf '%s' "$direct_output" | grep -Fq 'direct-ok' || fail "direct .exe transport or env scrubbing"

claude_runtime_build_command \
  "$CLAUDE_LOCATOR_LAUNCH_PATH" \
  --noprofile \
  --norc \
  -c \
  'printf "<%s>\n" "$@"' \
  claude \
  "space arg" \
  "" \
  "equals=value"
argv_output="$({
  claude_runtime_scrub_environment
  cd "$runtime_cwd"
  MSYS2_ARG_CONV_EXCL='*' "${CLAUDE_RUNTIME_COMMAND[@]}"
})"
printf '%s' "$argv_output" | grep -Fq 'space arg' || fail "space argv lost"
printf '%s' "$argv_output" | grep -Fq '<>' || fail "empty argv lost"
printf '%s' "$argv_output" | grep -Fq 'equals=value' || fail "equals argv lost"

python_bin="$(type -P python3 2>/dev/null || type -P python 2>/dev/null || true)"
[ -n "$python_bin" ] || fail "Python unavailable for timeout transport"
windows_claude_target="$CLAUDE_LOCATOR_CANONICAL_TARGET"
claude_runtime_resolve_trusted_python "$ROOT" "$PWD" "$runtime_cwd" || fail "trusted Windows Python resolution: ${CLAUDE_RUNTIME_PYTHON_STATUS:-missing}"
[ "$CLAUDE_RUNTIME_PYTHON_STATUS" = "safe" ] || fail "trusted Windows Python status"
process_driver="$runtime_cwd/process-driver.py"
claude_runtime_write_python_driver "$process_driver"
claude_runtime_check_launcher_dependency "$windows_claude_target" "$runtime_cwd" || fail "native Windows executable classification"
[ "$CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_KIND" = "direct" ] || fail "native .exe transport kind"
claude_runtime_build_command \
  "$CLAUDE_LOCATOR_LAUNCH_PATH" \
  --noprofile \
  --norc \
  -c \
  'printf "timeout-ok\n"'
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

tree_script="$fixture_root/timeout-tree.sh"
tree_pid_file="$fixture_root/timeout-tree.pid"
cat > "$tree_script" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
(
  trap '' TERM
  while :; do sleep 1; done
) &
printf '%s\n' "$!" > "${WINDOWS_TREE_PID_FILE:?}"
wait
SH
chmod 755 "$tree_script"
set +e
WINDOWS_TREE_PID_FILE="$tree_pid_file" \
  claude_runtime_run_with_timeout \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$process_driver" \
    "$runtime_cwd" \
    1 \
    - \
    "$windows_bash" --noprofile --norc "$tree_script" >/dev/null 2>&1
tree_status=$?
set -e
[ "$tree_status" -eq 124 ] || fail "Windows tree timeout status: $tree_status"
[ -s "$tree_pid_file" ] || fail "Windows timeout grandchild never started"
tree_pid="$(cat "$tree_pid_file")"
for _ in $(seq 1 30); do
  if ! kill -0 "$tree_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$tree_pid" 2>/dev/null; then
  fail "Windows Job Object left the timeout grandchild alive"
fi

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
  prompt="$(cat)"
  printf 'stdin_bytes=%s\n' "${#prompt}" >> "${WINDOWS_SHIM_LOG:?}"
  if [[ "$prompt" == *"Codex Claude skill preflight probe"* ]]; then
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
  BASH_ENV= ENV= /bin/bash --noprofile --norc scripts/run-review.sh \
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
[ "$(grep '^cwd=' "$shim_log" | sort -u | wc -l | tr -d ' ')" = "1" ] || fail "production runner drifted across runtime CWDs"
grep -Eq '^cwd=.*/claude-review-runtime-[^/]+$' "$shim_log" || fail "production runner skipped private runtime CWD"

"$python_bin" -I - "$artifact_file" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"x" * 190000)
PY
near_limit_output="$({
  cd "$ROOT"
  PATH="$shim_root:$PATH" \
  WINDOWS_SHIM_LOG="$shim_log" \
  BASH_ENV= ENV= /bin/bash --noprofile --norc scripts/run-review.sh \
    --mode code \
    --artifact-file "$artifact_file" \
    --base-prompt "$ROOT/prompts/code-review.base.md" \
    --schema-file "$ROOT/schemas/review-output.json" \
    --repo-root "$ROOT" \
    --branch windows-test \
    --base-branch main
})"
RUNNER_OUTPUT="$near_limit_output" "$python_bin" -I - <<'PY'
import json
import os

data = json.loads(os.environ["RUNNER_OUTPUT"])
assert data["status"] == "clean", data
PY
near_limit_stdin_bytes="$(awk -F= '/^stdin_bytes=/{value=$2} END{print value+0}' "$shim_log")"
[ "$near_limit_stdin_bytes" -gt 190000 ] || fail "Windows near-cap artifact was not streamed over stdin"

doctor_output="$({
  cd "$ROOT"
  PATH="$shim_root:$PATH" \
  WINDOWS_SHIM_LOG="$shim_log" \
  ANTHROPIC_API_KEY=doctor-secret \
  ANTHROPIC_AUTH_TOKEN=doctor-secret \
  BASH_ENV= ENV= /bin/bash --noprofile --norc scripts/claude-doctor.sh \
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
