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
    '"COMPLUS_"',
    '"COMPlus_"',
    "CREATE_SUSPENDED",
    "AssignProcessToJobObject",
    "NtResumeProcess",
    "TerminateJobObject",
    "subprocess.CREATE_NEW_PROCESS_GROUP",
    'process_options["start_new_session"] = True',
    'encoding="utf-8"',
    'errors="replace"',
    "len(out.encode('utf-8'))",
    "len(err.encode('utf-8'))",
    '_write_utf8(sys.stdout, out)',
    '_write_utf8(sys.stderr, err)',
    'return _as_text(exc.output), _as_text(exc.stderr)',
    "proc.communicate(timeout=3)",
    "proc.wait(timeout=1)",
):
    if token not in text:
        raise SystemExit(f"shared runtime driver lacks {token}")
if "proc.communicate()" in text:
    raise SystemExit("shared runtime driver retains an unbounded final communicate")
run_block = text[text.index("def _run_process"):text.index("def _classify")]
if "subprocess.CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED" not in run_block:
    raise SystemExit("Windows child is not created suspended")
if run_block.index("AssignProcessToJobObject") > run_block.index("_resume_suspended_process(proc)"):
    raise SystemExit("Windows child resumes before Job Object assignment")
PY
for script in "$ROOT/scripts/run-review.sh" "$ROOT/scripts/claude-doctor.sh"; do
  grep -Fq 'CLAUDE_PROCESS_DRIVER_TRANSPORT="$(claude_runtime_python_transport_path "$CLAUDE_PROCESS_DRIVER")"' "$script" || \
    fail "$(basename "$script") does not explicitly convert the early driver pathname"
  if grep -Fq '"$CLAUDE_RUNTIME_PYTHON_BIN" -I - "$CLAUDE_PROCESS_DRIVER"' "$script"; then
    fail "$(basename "$script") retains an unconverted early native-Python path"
  fi
  grep -Fq 'Unsafe bootstrap utility entry: cygpath' "$script" || \
    fail "$(basename "$script") does not validate fixed cygpath during bootstrap"
done

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

cygpath_bin="$(type -P cygpath 2>/dev/null || true)"
[ -n "$cygpath_bin" ] || fail "trusted cygpath unavailable"
CLAUDE_RUNTIME_CYGPATH_BIN="$cygpath_bin"
export CLAUDE_RUNTIME_CYGPATH_BIN

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
export OPENSSL_CONF=untrusted-openssl-conf
export OPENSSL_CONF_INCLUDE=untrusted-openssl-include
export OPENSSL_ENGINES=untrusted-openssl-engines
export OPENSSL_MODULES=untrusted-openssl-modules
export BASH_ENV="$fixture_root/never-source"
export ENV="$fixture_root/never-source-env"

claude_runtime_build_command \
  "$CLAUDE_LOCATOR_LAUNCH_PATH" \
  --noprofile \
  --norc \
  -c \
  'if [ -n "${ANTHROPIC_API_KEY+x}" ] || [ -n "${OPENSSL_CONF+x}" ] || [ -n "${OPENSSL_CONF_INCLUDE+x}" ] || [ -n "${OPENSSL_ENGINES+x}" ] || [ -n "${OPENSSL_MODULES+x}" ]; then exit 41; else printf "direct-ok\n"; fi'
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
windows_claude_launch_path="$CLAUDE_LOCATOR_LAUNCH_PATH"
claude_runtime_resolve_trusted_python "$ROOT" "$PWD" "$runtime_cwd" || fail "trusted Windows Python resolution: ${CLAUDE_RUNTIME_PYTHON_STATUS:-missing}"
[ "$CLAUDE_RUNTIME_PYTHON_STATUS" = "safe" ] || fail "trusted Windows Python status"
process_driver="$runtime_cwd/process-driver.py"
claude_runtime_write_python_driver "$process_driver"
COMPlus_StartupHooks=untrusted-runtime-hook "$python_bin" - "$process_driver" <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("claude_runtime_driver", sys.argv[1])
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
parent_complus = [name for name in os.environ if name.upper().startswith("COMPLUS_")]
if not parent_complus:
    raise SystemExit("Windows COMPlus_ transport precondition was not observed")
child_env = driver._child_environment(False, "")
leaked_complus = [name for name in child_env if name.upper().startswith("COMPLUS_")]
if leaked_complus:
    raise SystemExit(f"Windows COMPlus_ variables leaked to child: {leaked_complus!r}")
leaked_openssl = [
    name
    for name in (
        "OPENSSL_CONF",
        "OPENSSL_CONF_INCLUDE",
        "OPENSSL_ENGINES",
        "OPENSSL_MODULES",
    )
    if name in child_env
]
if leaked_openssl:
    raise SystemExit(f"Windows OpenSSL startup variables leaked to child: {leaked_openssl!r}")
expected = "windows-unicode-☃-東京\n"
proc, out, err, timed_out = driver._run_process(
    10,
    False,
    "",
    "-",
    [
        sys.executable,
        "-c",
        "import sys; sys.stdout.buffer.write(" + repr(expected.encode("utf-8")) + ")",
    ],
)
if proc.returncode != 0 or out != expected or err or timed_out:
    raise SystemExit(
        f"UTF-8 pipe transport failed: rc={proc.returncode} out={out!r} "
        f"err={err!r} timed_out={timed_out}"
    )
PY
forward_stdout="$runtime_cwd/forward-stdout"
forward_stderr="$runtime_cwd/forward-stderr"
claude_runtime_run_with_timeout \
  "$CLAUDE_RUNTIME_PYTHON_BIN" \
  "$process_driver" \
  "$runtime_cwd" \
  10 \
  - \
  "$CLAUDE_RUNTIME_PYTHON_BIN" -c \
  'import sys; sys.stdout.buffer.write(b"out-\xe2\x98\x83\n"); sys.stderr.buffer.write(b"err-\xe6\x9d\xb1\xe4\xba\xac\n")' \
  >"$forward_stdout" 2>"$forward_stderr"
"$python_bin" -I - "$forward_stdout" "$forward_stderr" <<'PY'
from pathlib import Path
import sys

expected_stdout = b"out-\xe2\x98\x83\n"
expected_stderr = b"err-\xe6\x9d\xb1\xe4\xba\xac\n"
actual_stdout = Path(sys.argv[1]).read_bytes()
actual_stderr = Path(sys.argv[2]).read_bytes()
if actual_stdout != expected_stdout or actual_stderr != expected_stderr:
    raise SystemExit(
        f"Windows UTF-8 forwarding changed bytes: stdout={actual_stdout!r} stderr={actual_stderr!r}"
    )
PY
claude_runtime_check_launcher_dependency "$windows_claude_target" "$runtime_cwd" || fail "native Windows executable classification"
[ "$CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_KIND" = "direct" ] || fail "native .exe transport kind"
claude_runtime_build_command \
  "$windows_claude_launch_path" \
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

tree_script="$fixture_root/timeout-tree.py"
tree_pid_file="$fixture_root/timeout-tree.pid"
tree_job_file="$fixture_root/timeout-tree.job"
tree_status_file="$fixture_root/timeout-tree.status"
cat > "$tree_script" <<'PY'
import ctypes
from ctypes import wintypes
from pathlib import Path
import subprocess
import sys
import time

JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS = 9


class JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_longlong),
        ("PerJobUserTimeLimit", ctypes.c_longlong),
        ("LimitFlags", wintypes.DWORD),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", wintypes.DWORD),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", wintypes.DWORD),
        ("SchedulingClass", wintypes.DWORD),
    ]


class IO_COUNTERS(ctypes.Structure):
    _fields_ = [(name, ctypes.c_ulonglong) for name in (
        "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
        "ReadTransferCount", "WriteTransferCount", "OtherTransferCount",
    )]


class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", JOBOBJECT_BASIC_LIMIT_INFORMATION),
        ("IoInfo", IO_COUNTERS),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.QueryInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
kernel32.QueryInformationJobObject.restype = wintypes.BOOL
info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
if not kernel32.QueryInformationJobObject(
    None,
    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
    ctypes.byref(info),
    ctypes.sizeof(info),
    None,
):
    raise ctypes.WinError(ctypes.get_last_error())
kill_on_close = bool(info.BasicLimitInformation.LimitFlags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
Path(sys.argv[1]).write_text("1" if kill_on_close else "0", encoding="ascii")
if not kill_on_close:
    raise SystemExit(93)
child = subprocess.Popen(
    [sys.executable, "-c", "import time; time.sleep(60)"],
    stdout=sys.stdout,
    stderr=sys.stderr,
)
Path(sys.argv[2]).write_text(str(child.pid), encoding="ascii")
time.sleep(60)
PY
tree_script_windows="$("$cygpath_bin" -aw "$tree_script")"
tree_job_file_windows="$("$cygpath_bin" -aw "$tree_job_file")"
tree_pid_file_windows="$("$cygpath_bin" -aw "$tree_pid_file")"
(
  set +e
  claude_runtime_run_with_timeout \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$process_driver" \
    "$runtime_cwd" \
    3 \
    - \
    "$CLAUDE_RUNTIME_PYTHON_BIN" "$tree_script_windows" "$tree_job_file_windows" "$tree_pid_file_windows" >/dev/null 2>&1
  printf '%s' "$?" > "$tree_status_file"
) &
tree_runtime_pid=$!
for _ in $(seq 1 50); do
  [ -s "$tree_pid_file" ] && break
  sleep 0.1
done
[ -s "$tree_pid_file" ] || fail "Windows timeout grandchild never started"
tree_pid="$(cat "$tree_pid_file")"
MSYS2_ARG_CONV_EXCL='*' "$CLAUDE_RUNTIME_PYTHON_BIN" -I -S - "$tree_pid" <<'PY'
import ctypes
from ctypes import wintypes
import sys

SYNCHRONIZE = 0x00100000
WAIT_OBJECT_0 = 0
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel32.WaitForSingleObject.restype = wintypes.DWORD
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL
handle = kernel32.OpenProcess(SYNCHRONIZE, False, int(sys.argv[1]))
if not handle:
    raise ctypes.WinError(ctypes.get_last_error())
try:
    if kernel32.WaitForSingleObject(handle, 10000) != WAIT_OBJECT_0:
        raise SystemExit("Windows Job Object left the timeout grandchild alive")
finally:
    kernel32.CloseHandle(handle)
PY
wait "$tree_runtime_pid" || true
tree_status="$(cat "$tree_status_file")"
[ "$tree_status" -eq 124 ] || fail "Windows tree timeout status: $tree_status"
[ "$(cat "$tree_job_file")" = "1" ] || fail "Windows child did not observe the runtime's kill-on-close Job Object"

# Exercise the actual runner with an extensionless Git Bash/npm-style shim. This
# covers canonical input boundaries, validated shebang transport, internal MSYS
# argument-conversion control, preflight, and the final timeout call site without
# invoking a real or paid Claude installation.
shim_log="$shim_root/calls.log"
cat > "$shim_root/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${MSYS2_ARG_CONV_EXCL-}" = "*" ] && [ "${EXPECT_INHERITED_MSYS:-}" != "1" ]; then
  printf 'internal MSYS conversion override leaked to Claude\n' >&2
  exit 91
fi
if [ -n "${ANTHROPIC_API_KEY+x}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN+x}" ] || \
   [ -n "${OPENSSL_CONF+x}" ] || [ -n "${OPENSSL_CONF_INCLUDE+x}" ] || \
   [ -n "${OPENSSL_ENGINES+x}" ] || [ -n "${OPENSSL_MODULES+x}" ]; then
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
  OPENSSL_CONF=runner-openssl-conf \
  OPENSSL_CONF_INCLUDE=runner-openssl-include \
  OPENSSL_ENGINES=runner-openssl-engines \
  OPENSSL_MODULES=runner-openssl-modules \
  BASH_ENV= ENV= /bin/bash --noprofile --norc -p scripts/run-review.sh \
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
  BASH_ENV= ENV= /bin/bash --noprofile --norc -p scripts/run-review.sh \
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
  BASH_ENV= ENV= /bin/bash --noprofile --norc -p scripts/claude-doctor.sh \
    --repo-root "$ROOT" \
    --skill-root "$ROOT" \
    --config-file "$ROOT/.codex/claude/config.env" \
    --probe-timeout 10 \
    --skip-update-check
})"
printf '%s\n' "$doctor_output" | grep -Fqx 'doctor_status=ok' || fail "production doctor did not complete"
printf '%s\n' "$doctor_output" | grep -Fqx 'claude_path_status=available' || fail "production doctor did not select PATH shim"
printf '%s\n' "$doctor_output" | grep -Fqx 'plain_print_probe_status=skipped_redundant_hardened_probe' || fail "doctor legacy plain probe status drifted"
printf '%s\n' "$doctor_output" | grep -Fqx 'safe_mode_print_probe_status=completed' || fail "doctor safe-mode probe missed native-Python transport"
if grep -Fq 'msys=*' "$shim_log"; then
  fail "doctor transport leaked its internal MSYS conversion override"
fi

root_drive="$($cygpath_bin -am "$ROOT")"
artifact_file_drive="$($cygpath_bin -am "$artifact_file")"
base_prompt_drive="$($cygpath_bin -am "$ROOT/prompts/code-review.base.md")"
schema_drive="$($cygpath_bin -am "$ROOT/schemas/review-output.json")"
config_drive="$($cygpath_bin -am "$ROOT/.codex/claude/config.env")"
drive_runner_output="$({
  cd "$ROOT"
  PATH="$shim_root:$PATH" \
  WINDOWS_SHIM_LOG="$shim_log" \
  BASH_ENV= ENV= /bin/bash --noprofile --norc -p scripts/run-review.sh \
    --mode code \
    --artifact-file "$artifact_file_drive" \
    --base-prompt "$base_prompt_drive" \
    --schema-file "$schema_drive" \
    --repo-root "$root_drive" \
    --branch windows-drive-test \
    --base-branch main
})"
RUNNER_OUTPUT="$drive_runner_output" "$python_bin" -I - <<'PY'
import json
import os

data = json.loads(os.environ["RUNNER_OUTPUT"])
assert data["status"] == "clean", data
PY
drive_doctor_output="$({
  cd "$ROOT"
  PATH="$shim_root:$PATH" \
  WINDOWS_SHIM_LOG="$shim_log" \
  BASH_ENV= ENV= /bin/bash --noprofile --norc -p scripts/claude-doctor.sh \
    --repo-root "$root_drive" \
    --skill-root "$root_drive" \
    --config-file "$config_drive" \
    --probe-timeout 10 \
    --skip-probes \
    --skip-update-check
})"
printf '%s\n' "$drive_doctor_output" | grep -Fqx 'doctor_status=ok' || fail "doctor rejected drive-form path arguments"

rm -f "$shim_log"
inherited_msys_runner_output="$({
  cd "$ROOT"
  PATH="$shim_root:$PATH" \
  WINDOWS_SHIM_LOG="$shim_log" \
  EXPECT_INHERITED_MSYS=1 \
  MSYS2_ARG_CONV_EXCL='*' \
  BASH_ENV= ENV= /bin/bash --noprofile --norc -p scripts/run-review.sh \
    --mode code \
    --artifact-file "$artifact_file" \
    --base-prompt "$ROOT/prompts/code-review.base.md" \
    --schema-file "$ROOT/schemas/review-output.json" \
    --repo-root "$ROOT" \
    --branch windows-test \
    --base-branch main
})"
RUNNER_OUTPUT="$inherited_msys_runner_output" "$python_bin" -I - <<'PY'
import json
import os

data = json.loads(os.environ["RUNNER_OUTPUT"])
assert data["status"] == "clean", data
PY
grep -Fq 'msys=*' "$shim_log" || fail "runner did not restore the inherited MSYS conversion setting"

rm -f "$shim_log"
inherited_msys_doctor_output="$({
  cd "$ROOT"
  PATH="$shim_root:$PATH" \
  WINDOWS_SHIM_LOG="$shim_log" \
  EXPECT_INHERITED_MSYS=1 \
  MSYS2_ARG_CONV_EXCL='*' \
  BASH_ENV= ENV= /bin/bash --noprofile --norc -p scripts/claude-doctor.sh \
    --repo-root "$ROOT" \
    --skill-root "$ROOT" \
    --config-file "$ROOT/.codex/claude/config.env" \
    --probe-timeout 10 \
    --skip-update-check
})"
printf '%s\n' "$inherited_msys_doctor_output" | grep -Fqx 'doctor_status=ok' || fail "doctor failed with inherited MSYS conversion disabled"
grep -Fq 'msys=*' "$shim_log" || fail "doctor did not restore the inherited MSYS conversion setting"

printf 'ok: Windows Git Bash PATH-only .exe and extensionless-shim runner/doctor transport\n'
