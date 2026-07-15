#!/usr/bin/env bash

# Shared direct Claude command transport. This file must remain source-pure:
# definitions and readonly contract constants only.

readonly CLAUDE_RUNTIME_CONTRACT="direct_inherited_path_v4"

claude_runtime_scrub_environment() {
  unset BASH_ENV
  unset ENV
  unset ANTHROPIC_API_KEY
  unset ANTHROPIC_AUTH_TOKEN
  unset ANTHROPIC_BEARER_TOKEN
  unset ANTHROPIC_CONSOLE_API_KEY
  unset ANTHROPIC_CONSOLE_AUTH_TOKEN
}

claude_runtime_build_command() {
  local launch_path="${1:-}"
  shift || true

  CLAUDE_RUNTIME_COMMAND=("$launch_path" "$@")
}

claude_runtime_prepare_python_argv() {
  local cygpath_bin=""
  local converted_path=""
  local original_argv=()
  local transport_argv=()
  local transport_item=""
  local transport_count=0
  local arg_index=0

  CLAUDE_RUNTIME_PYTHON_ARGV=("$@")
  [ "${#CLAUDE_RUNTIME_PYTHON_ARGV[@]}" -gt 0 ] || return 1

  case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*)
      if [ -x /usr/bin/cygpath ]; then
        cygpath_bin=/usr/bin/cygpath
      elif [ -x /usr/bin/cygpath.exe ]; then
        cygpath_bin=/usr/bin/cygpath.exe
      else
        return 1
      fi
      original_argv=("${CLAUDE_RUNTIME_PYTHON_ARGV[@]}")
      transport_argv=("${CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND[@]+"${CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND[@]}"}")
      if [ "${#transport_argv[@]}" -eq 0 ]; then
        transport_argv=("${original_argv[0]}")
      fi
      transport_count="${#transport_argv[@]}"
      CLAUDE_RUNTIME_PYTHON_ARGV=()
      for ((arg_index = 0; arg_index < transport_count; arg_index++)); do
        transport_item="${transport_argv[$arg_index]}"
        if [ "$arg_index" -eq $((transport_count - 1)) ]; then
          transport_item="${original_argv[0]}"
        fi
        case "$transport_item" in
          /*)
            converted_path="$(claude_runtime_windows_executable_path "$transport_item" "$cygpath_bin")" || return 1
            [ -n "$converted_path" ] || return 1
            CLAUDE_RUNTIME_PYTHON_ARGV+=("$converted_path")
            ;;
          *)
            CLAUDE_RUNTIME_PYTHON_ARGV+=("$transport_item")
            ;;
        esac
      done
      for ((arg_index = 1; arg_index < ${#original_argv[@]}; arg_index++)); do
        CLAUDE_RUNTIME_PYTHON_ARGV+=("${original_argv[$arg_index]}")
      done
      ;;
  esac
  return 0
}

claude_runtime_windows_executable_path() {
  local executable_path="$1"
  local cygpath_bin="$2"

  "$cygpath_bin" -m "$executable_path" 2>/dev/null
}

claude_runtime_resolve_trusted_python() {
  local repo_root="${1:-}"
  local invocation_cwd="${2:-${PWD:-/}}"
  local execution_cwd="${3:-${PWD:-/}}"
  local python_path=""
  local dependency_path=""
  local inherited_path=""

  if [ "${CLAUDE_RUNTIME_INHERITED_PATH+x}" = "x" ]; then
    inherited_path="$CLAUDE_RUNTIME_INHERITED_PATH"
  else
    inherited_path="${PATH-}"
  fi

  CLAUDE_RUNTIME_PYTHON_BIN=""
  CLAUDE_RUNTIME_PYTHON_CANONICAL_TARGET=""
  CLAUDE_RUNTIME_PYTHON_STATUS="missing"
  CLAUDE_RUNTIME_PYTHON_VALIDATION_SCOPE=""
  CLAUDE_RUNTIME_PYTHON_VALIDATION_STATUS=""

  declare -F claude_locator_validate_candidate >/dev/null 2>&1 || {
    CLAUDE_RUNTIME_PYTHON_STATUS="validation_unavailable"
    return 1
  }
  declare -F claude_locator_validate_launcher_dependency >/dev/null 2>&1 || {
    CLAUDE_RUNTIME_PYTHON_STATUS="validation_unavailable"
    return 1
  }

  python_path="$(PATH="$inherited_path" type -P python3 2>/dev/null || true)"
  [ -n "$python_path" ] || return 1
  if ! claude_locator_validate_candidate "$python_path" "$repo_root" "$invocation_cwd"; then
    CLAUDE_RUNTIME_PYTHON_STATUS="unsafe"
    CLAUDE_RUNTIME_PYTHON_VALIDATION_SCOPE="$CLAUDE_LOCATOR_VALIDATION_SCOPE"
    CLAUDE_RUNTIME_PYTHON_VALIDATION_STATUS="$CLAUDE_LOCATOR_VALIDATION_STATUS"
    return 1
  fi

  CLAUDE_RUNTIME_PYTHON_BIN="$CLAUDE_LOCATOR_LAUNCH_PATH"
  CLAUDE_RUNTIME_PYTHON_CANONICAL_TARGET="$CLAUDE_LOCATOR_CANONICAL_TARGET"
  if ! claude_runtime_check_launcher_dependency "$CLAUDE_RUNTIME_PYTHON_CANONICAL_TARGET" "$execution_cwd"; then
    CLAUDE_RUNTIME_PYTHON_STATUS="launcher_dependency_${CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS}"
    CLAUDE_RUNTIME_PYTHON_BIN=""
    return 1
  fi
  # Isolated mode must be an interpreter option. A script-shaped python3
  # launcher would receive -I as a script argument instead, so fail closed.
  if [ "$CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_KIND" != "direct" ]; then
    CLAUDE_RUNTIME_PYTHON_STATUS="launcher_unsupported"
    CLAUDE_RUNTIME_PYTHON_BIN=""
    return 1
  fi
  for dependency_path in "${CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATHS[@]+"${CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATHS[@]}"}"; do
    if ! claude_locator_validate_launcher_dependency "$dependency_path" "$repo_root" "$invocation_cwd"; then
      CLAUDE_RUNTIME_PYTHON_STATUS="launcher_dependency_unsafe"
      CLAUDE_RUNTIME_PYTHON_VALIDATION_SCOPE="$CLAUDE_LOCATOR_DEPENDENCY_VALIDATION_SCOPE"
      CLAUDE_RUNTIME_PYTHON_VALIDATION_STATUS="$CLAUDE_LOCATOR_DEPENDENCY_VALIDATION_STATUS"
      CLAUDE_RUNTIME_PYTHON_BIN=""
      return 1
    fi
  done

  CLAUDE_RUNTIME_PYTHON_STATUS="safe"
  return 0
}

claude_runtime_write_python_driver() {
  local destination="$1"

  (
    umask 077
    while IFS= read -r driver_line || [ -n "$driver_line" ]; do
      printf '%s\n' "$driver_line"
    done > "$destination" <<'PY'
import ctypes
import os
import re
import signal
import subprocess
import sys
import time


JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS = 9
CREATE_SUSPENDED = 0x00000004


if os.name == "nt":
    from ctypes import wintypes

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
        _fields_ = [
            ("ReadOperationCount", ctypes.c_ulonglong),
            ("WriteOperationCount", ctypes.c_ulonglong),
            ("OtherOperationCount", ctypes.c_ulonglong),
            ("ReadTransferCount", ctypes.c_ulonglong),
            ("WriteTransferCount", ctypes.c_ulonglong),
            ("OtherTransferCount", ctypes.c_ulonglong),
        ]

    class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
        _fields_ = [
            ("BasicLimitInformation", JOBOBJECT_BASIC_LIMIT_INFORMATION),
            ("IoInfo", IO_COUNTERS),
            ("ProcessMemoryLimit", ctypes.c_size_t),
            ("JobMemoryLimit", ctypes.c_size_t),
            ("PeakProcessMemoryUsed", ctypes.c_size_t),
            ("PeakJobMemoryUsed", ctypes.c_size_t),
        ]

    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    _kernel32.CreateJobObjectW.restype = wintypes.HANDLE
    _kernel32.SetInformationJobObject.argtypes = [
        wintypes.HANDLE,
        ctypes.c_int,
        ctypes.c_void_p,
        wintypes.DWORD,
    ]
    _kernel32.SetInformationJobObject.restype = wintypes.BOOL
    _kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    _kernel32.AssignProcessToJobObject.restype = wintypes.BOOL
    _kernel32.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
    _kernel32.TerminateJobObject.restype = wintypes.BOOL
    _kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    _kernel32.CloseHandle.restype = wintypes.BOOL
    _ntdll = ctypes.WinDLL("ntdll")
    _ntdll.NtResumeProcess.argtypes = [wintypes.HANDLE]
    _ntdll.NtResumeProcess.restype = ctypes.c_long


def _create_kill_on_close_job():
    if os.name != "nt":
        return None
    job = _kernel32.CreateJobObjectW(None, None)
    if not job:
        raise ctypes.WinError(ctypes.get_last_error())
    info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not _kernel32.SetInformationJobObject(
        job,
        JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
        ctypes.byref(info),
        ctypes.sizeof(info),
    ):
        error = ctypes.WinError(ctypes.get_last_error())
        _kernel32.CloseHandle(job)
        raise error
    return job


def _close_job(job):
    if job is not None:
        _kernel32.CloseHandle(job)


def _resume_suspended_process(proc):
    status = _ntdll.NtResumeProcess(wintypes.HANDLE(int(proc._handle)))
    if status != 0:
        raise OSError(
            f"NtResumeProcess failed with NTSTATUS 0x{status & 0xFFFFFFFF:08x}"
        )


def _stop_process_tree(proc, job, force):
    try:
        if os.name == "nt":
            if job is not None:
                _kernel32.TerminateJobObject(job, 1)
            else:
                proc.kill()
        else:
            os.killpg(proc.pid, signal.SIGKILL if force else signal.SIGTERM)
    except OSError:
        pass


def _close_pipe(pipe):
    if pipe is not None:
        try:
            pipe.close()
        except OSError:
            pass


def _as_text(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value or ""


def _bounded_timeout_cleanup(proc, job):
    _stop_process_tree(proc, job, False)
    try:
        return proc.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        _stop_process_tree(proc, job, True)
        try:
            return proc.communicate(timeout=3)
        except subprocess.TimeoutExpired as exc:
            _close_pipe(proc.stdin)
            _close_pipe(proc.stdout)
            _close_pipe(proc.stderr)
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            return _as_text(exc.output), _as_text(exc.stderr)


def _child_environment(msys_present, msys_value):
    child_env = os.environ.copy()
    for name in tuple(child_env):
        if name.startswith("BASH_FUNC_"):
            child_env.pop(name, None)
    if msys_present:
        child_env["MSYS2_ARG_CONV_EXCL"] = msys_value
    else:
        child_env.pop("MSYS2_ARG_CONV_EXCL", None)
    return child_env


def _exec_process(msys_present, msys_value, input_path, cmd):
    input_handle = None
    try:
        if input_path == "@probe":
            raise ValueError("direct execution does not accept probe input")
        if input_path != "-":
            input_handle = open(input_path, "rb")
            os.dup2(input_handle.fileno(), 0)
        os.execvpe(cmd[0], cmd, _child_environment(msys_present, msys_value))
    finally:
        if input_handle is not None:
            input_handle.close()


def _run_process(timeout, msys_present, msys_value, input_path, cmd):
    input_handle = None
    input_payload = None
    stdin_value = subprocess.DEVNULL
    if input_path == "@probe":
        stdin_value = subprocess.PIPE
        input_payload = "Return OK only.\n"
    elif input_path != "-":
        input_handle = open(input_path, "r", encoding="utf-8", newline="")
        stdin_value = input_handle

    process_options = {}
    job = _create_kill_on_close_job()
    proc = None
    if os.name == "nt":
        process_options["creationflags"] = (
            subprocess.CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED
        )
    else:
        process_options["start_new_session"] = True
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=os.getcwd(),
            shell=False,
            stdin=stdin_value,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=_child_environment(msys_present, msys_value),
            **process_options,
        )
        if os.name == "nt" and not _kernel32.AssignProcessToJobObject(
            job, wintypes.HANDLE(int(proc._handle))
        ):
            error = ctypes.WinError(ctypes.get_last_error())
            proc.terminate()
            try:
                proc.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
            raise error
        if os.name == "nt":
            try:
                _resume_suspended_process(proc)
            except OSError:
                _kernel32.TerminateJobObject(job, 1)
                try:
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
                raise
        try:
            out, err = proc.communicate(input_payload, timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            out, err = _bounded_timeout_cleanup(proc, job)
            timed_out = True
        return proc, out or "", err or "", timed_out
    finally:
        if input_handle is not None:
            input_handle.close()
        _close_job(job)


def _classify(out, err, returncode):
    combined = f"{out}\n{err}"
    if re.search(r"oauth_refresh|\.claude", combined, re.I) and re.search(
        r"EPERM|EACCES|permission denied|operation not permitted", combined, re.I
    ):
        return "claude_state_write_denied"
    if re.search(r"not logged in|auth login|setup-token|authentication", combined, re.I):
        return "authentication_unavailable"
    if re.search(r"maximum budget|error_max_budget_usd", combined, re.I):
        return "budget_exhausted"
    return "ok" if returncode == 0 else "unexpected_failure"


def _write_utf8(stream, value):
    payload = value.encode("utf-8")
    binary_stream = getattr(stream, "buffer", None)
    if binary_stream is None:
        stream.write(value)
        return
    binary_stream.write(payload)
    binary_stream.flush()


def main():
    if len(sys.argv) < 8 or sys.argv[1] not in {"exec", "run", "probe"}:
        raise SystemExit(2)
    mode = sys.argv[1]
    label = sys.argv[2]
    timeout = int(sys.argv[3])
    msys_present = sys.argv[4] == "x"
    msys_value = sys.argv[5]
    input_path = sys.argv[6]
    cmd = sys.argv[7:]
    if mode == "exec":
        try:
            _exec_process(msys_present, msys_value, input_path, cmd)
        except (OSError, ValueError) as exc:
            print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
            return 126
    started = time.monotonic()
    try:
        proc, out, err, timed_out = _run_process(
            timeout, msys_present, msys_value, input_path, cmd
        )
    except (OSError, ValueError) as exc:
        if mode == "probe":
            print(f"{label}_status=spawn_failed")
            print(f"{label}_error_type={type(exc).__name__}")
            return 0
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        return 126

    returncode = proc.returncode if proc.returncode is not None else -1
    if mode == "probe":
        elapsed = time.monotonic() - started
        print(f"{label}_status={'timeout' if timed_out else 'completed'}")
        print(f"{label}_returncode={returncode}")
        print(f"{label}_elapsed_seconds={elapsed:.2f}")
        print(f"{label}_stdout_bytes={len(out.encode('utf-8'))}")
        print(f"{label}_stderr_bytes={len(err.encode('utf-8'))}")
        print(f"{label}_classification={_classify(out, err, returncode)}")
        return 0

    _write_utf8(sys.stdout, out)
    _write_utf8(sys.stderr, err)
    return 124 if timed_out else returncode


if __name__ == "__main__":
    raise SystemExit(main())
PY
  )
}

claude_runtime_python_transport_path() {
  local path="$1"
  local cygpath_bin=""

  case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*)
      if [ -x /usr/bin/cygpath ]; then
        cygpath_bin=/usr/bin/cygpath
      elif [ -x /usr/bin/cygpath.exe ]; then
        cygpath_bin=/usr/bin/cygpath.exe
      else
        return 1
      fi
      claude_runtime_windows_executable_path "$path" "$cygpath_bin"
      ;;
    *)
      printf '%s' "$path"
      ;;
  esac
}

claude_runtime_invoke_python_driver() {
  local mode="$1"
  local label="$2"
  local python_bin="$3"
  local driver_path="$4"
  local runtime_cwd="$5"
  local timeout_seconds="$6"
  local input_path="$7"
  local msys_arg_conv_present="${MSYS2_ARG_CONV_EXCL+x}"
  local msys_arg_conv_value="${MSYS2_ARG_CONV_EXCL-}"
  local driver_transport=""
  local input_transport="$input_path"
  local inherited_path=""
  shift 7

  if [ "${CLAUDE_RUNTIME_INHERITED_PATH+x}" = "x" ]; then
    inherited_path="$CLAUDE_RUNTIME_INHERITED_PATH"
  else
    inherited_path="${PATH-}"
  fi

  claude_runtime_prepare_python_argv "$@" || return 126
  driver_transport="$(claude_runtime_python_transport_path "$driver_path")" || return 126
  case "$input_path" in
    -|@probe)
      ;;
    *)
      input_transport="$(claude_runtime_python_transport_path "$input_path")" || return 126
      ;;
  esac

  (
    claude_runtime_scrub_environment
    PATH="$inherited_path"
    export PATH
    unset CLAUDE_RUNTIME_INHERITED_PATH
    cd -P -- "$runtime_cwd" || exit 1
    MSYS2_ARG_CONV_EXCL='*' "$python_bin" -I "$driver_transport" \
      "$mode" \
      "$label" \
      "$timeout_seconds" \
      "$msys_arg_conv_present" \
      "$msys_arg_conv_value" \
      "$input_transport" \
      "${CLAUDE_RUNTIME_PYTHON_ARGV[@]}"
  )
}

claude_runtime_run_with_timeout() {
  claude_runtime_invoke_python_driver run - "$@"
}

claude_runtime_probe_with_timeout() {
  local label="$1"
  shift
  claude_runtime_invoke_python_driver probe "$label" "$@"
}

claude_runtime_run_direct() {
  local runtime_cwd="$1"
  local python_bin="$2"
  local driver_path="$3"
  local input_path="$4"
  shift 4

  [ -n "$python_bin" ] && [ -r "$driver_path" ] || return 125
  claude_runtime_invoke_python_driver \
    exec \
    - \
    "$python_bin" \
    "$driver_path" \
    "$runtime_cwd" \
    0 \
    "$input_path" \
    "$@"
}

claude_runtime_add_dependency_path() {
  local dependency_path="$1"
  local existing_path=""

  for existing_path in "${CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATHS[@]+"${CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATHS[@]}"}"; do
    [ "$existing_path" = "$dependency_path" ] && return 0
  done
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATHS+=("$dependency_path")
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_COUNT=$((CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_COUNT + 1))
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="$dependency_path"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="${dependency_path##*/}"
}

claude_runtime_resolve_path_dependency() {
  local dependency="$1"
  local execution_cwd="$2"
  local resolved_dependency=""
  local inherited_path=""

  if [ "${CLAUDE_RUNTIME_INHERITED_PATH+x}" = "x" ]; then
    inherited_path="$CLAUDE_RUNTIME_INHERITED_PATH"
  else
    inherited_path="${PATH-}"
  fi

  (
    builtin cd -P -- "$execution_cwd" 2>/dev/null || exit 1
    resolved_dependency="$(PATH="$inherited_path" type -P "$dependency" 2>/dev/null || true)"
    [ -n "$resolved_dependency" ] || exit 0
    case "$resolved_dependency" in
      /*)
        printf '%s' "$resolved_dependency"
        ;;
      *)
        printf '%s/%s' "$PWD" "$resolved_dependency"
        ;;
    esac
  )
}

claude_runtime_is_native_executable() {
  local executable_path="$1"
  local od_bin=""
  local header_output=""
  local signature_output=""
  local header_bytes=()
  local byte=""
  local has_binary_nul=0
  local pe_offset=0

  od_bin="$(claude_locator_resolve_trusted_utility od 2>/dev/null)" || return 2
  header_output="$(LC_ALL=C "$od_bin" -An -tx1 -v -N80 "$executable_path" 2>/dev/null)" || return 2
  # The trusted od emits only hexadecimal byte tokens. Validate them before
  # using shell word splitting or arithmetic so malformed output fails closed.
  # shellcheck disable=SC2206
  header_bytes=($header_output)
  [ "${#header_bytes[@]}" -ge 4 ] || return 1
  for byte in "${header_bytes[@]}"; do
    case "$byte" in
      [0-9a-fA-F][0-9a-fA-F])
        [ "$byte" != "00" ] || has_binary_nul=1
        ;;
      *)
        return 2
        ;;
    esac
  done
  # Bash will not apply its ENOEXEC text-script fallback to a binary header.
  # Requiring a NUL in the inspected header makes that property explicit even
  # when an otherwise native-looking file is malformed.
  [ "$has_binary_nul" -eq 1 ] || return 1

  case "${header_bytes[0]} ${header_bytes[1]} ${header_bytes[2]} ${header_bytes[3]}" in
    "7f 45 4c 46"|\
    "fe ed fa ce"|"ce fa ed fe"|\
    "fe ed fa cf"|"cf fa ed fe"|\
    "ca fe ba be"|"be ba fe ca"|\
    "ca fe ba bf"|"bf ba fe ca")
      return 0
      ;;
    "4d 5a "*)
      [ "${#header_bytes[@]}" -ge 64 ] || return 1
      pe_offset=$((
        16#${header_bytes[60]} +
        (16#${header_bytes[61]} << 8) +
        (16#${header_bytes[62]} << 16) +
        (16#${header_bytes[63]} << 24)
      ))
      [ "$pe_offset" -ge 64 ] && [ "$pe_offset" -le 16777216 ] || return 1
      signature_output="$(LC_ALL=C "$od_bin" -An -tx1 -v -j "$pe_offset" -N4 "$executable_path" 2>/dev/null)" || return 2
      # shellcheck disable=SC2206
      header_bytes=($signature_output)
      [ "${#header_bytes[@]}" -eq 4 ] || return 1
      for byte in "${header_bytes[@]}"; do
        case "$byte" in
          [0-9a-fA-F][0-9a-fA-F]) ;;
          *) return 2 ;;
        esac
      done
      [ "${header_bytes[0]} ${header_bytes[1]} ${header_bytes[2]} ${header_bytes[3]}" = "50 45 00 00" ] || return 1
      return 0
      ;;
  esac
  return 1
}

claude_runtime_inspect_shebang_path() {
  local current_path="$1"
  local depth="$2"
  local execution_cwd="$3"
  local resolution_kind="$4"
  local first_line=""
  local payload=""
  local interpreter=""
  local dependency=""
  local dependency_path=""
  local remainder=""
  local extra=""
  local stack_index=0
  local native_status=0
  local interpreter_transport=()

  if [ "$depth" -gt 8 ]; then
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unsupported"
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="shebang_depth"
    return 1
  fi
  for ((stack_index = 0; stack_index < depth; stack_index++)); do
    if [ "${CLAUDE_RUNTIME_SHEBANG_STACK[$stack_index]:-}" = "$current_path" ]; then
      CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unsupported"
      CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="shebang_cycle"
      return 1
    fi
  done
  CLAUDE_RUNTIME_SHEBANG_STACK[$depth]="$current_path"

  if [ ! -f "$current_path" ] || [ ! -x "$current_path" ]; then
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="missing"
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="${current_path##*/}"
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="$current_path"
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_RESOLUTION="$resolution_kind"
    return 1
  fi
  if [ ! -r "$current_path" ]; then
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unreadable"
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="${current_path##*/}"
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="$current_path"
    return 1
  fi
  if { IFS= read -r -n 4096 first_line || true; } 2>/dev/null < "$current_path"; then
    :
  else
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unreadable"
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="${current_path##*/}"
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="$current_path"
    return 1
  fi
  first_line="${first_line%$'\r'}"
  case "$first_line" in
    '#!'*)
      ;;
    *)
      if claude_runtime_is_native_executable "$current_path"; then
        CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND=("$current_path")
        return 0
      else
        native_status=$?
      fi
      if [ "$native_status" -eq 2 ]; then
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="validation_unavailable"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="od"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="none"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_RESOLUTION="bootstrap"
        return 1
      fi
      CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unsupported"
      CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="native_format"
      CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="$current_path"
      return 1
      ;;
  esac

  payload="${first_line#\#!}"
  IFS=$' \t' read -r interpreter remainder <<< "$payload"
  if [ -z "$interpreter" ]; then
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unsupported"
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="shebang"
    return 1
  fi

  case "$interpreter" in
    /usr/bin/env)
      CLAUDE_RUNTIME_LAUNCHER_INTERPRETER_PATH="$interpreter"
      if [ ! -f "$interpreter" ] || [ ! -x "$interpreter" ]; then
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="missing"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="env"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="$interpreter"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_RESOLUTION="absolute"
        return 1
      fi
      IFS=$' \t' read -r dependency extra <<< "$remainder"
      if [ -z "$dependency" ] || [ -n "$extra" ]; then
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unsupported"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="env"
        return 1
      fi
      case "$dependency" in
        *[!A-Za-z0-9._+-]*)
          CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unsupported"
          CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="env"
          return 1
          ;;
      esac
      if [ "$depth" -eq 0 ]; then
        CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_KIND="env"
        CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_INTERPRETER_PATH="$interpreter"
        CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_ARGUMENT="$dependency"
      fi
      claude_runtime_add_dependency_path "$interpreter"
      claude_runtime_inspect_shebang_path "$interpreter" "$((depth + 1))" "$execution_cwd" "absolute" || return 1
      interpreter_transport=("${CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND[@]+"${CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND[@]}"}")
      dependency_path="$(claude_runtime_resolve_path_dependency "$dependency" "$execution_cwd" 2>/dev/null || true)"
      if [ -z "$dependency_path" ]; then
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="missing"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="$dependency"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="none"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_RESOLUTION="path"
        return 1
      fi
      claude_runtime_add_dependency_path "$dependency_path"
      claude_runtime_inspect_shebang_path "$dependency_path" "$((depth + 1))" "$execution_cwd" "path" || return 1
      CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND=("${interpreter_transport[@]}" "$dependency" "$current_path")
      return 0
      ;;
    /*)
      if [ -n "$remainder" ]; then
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unsupported"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="shebang"
        return 1
      fi
      if [ "$depth" -eq 0 ]; then
        CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_KIND="absolute"
        CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_INTERPRETER_PATH="$interpreter"
        CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_ARGUMENT="none"
      fi
      CLAUDE_RUNTIME_LAUNCHER_INTERPRETER_PATH="$interpreter"
      if [ ! -f "$interpreter" ] || [ ! -x "$interpreter" ]; then
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="missing"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="${interpreter##*/}"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="$interpreter"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_RESOLUTION="absolute"
        return 1
      fi
      claude_runtime_add_dependency_path "$interpreter"
      claude_runtime_inspect_shebang_path "$interpreter" "$((depth + 1))" "$execution_cwd" "absolute" || return 1
      CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND+=("$current_path")
      return 0
      ;;
  esac

  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unsupported"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="shebang"
  return 1
}

claude_runtime_check_launcher_dependency() {
  local canonical_target="${1:-}"
  local execution_cwd="${2:-${PWD:-/}}"

  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unknown"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="none"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="none"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_RESOLUTION="none"
  CLAUDE_RUNTIME_LAUNCHER_INTERPRETER_PATH="none"
  CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_KIND="direct"
  CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_INTERPRETER_PATH="none"
  CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_ARGUMENT="none"
  CLAUDE_RUNTIME_LAUNCHER_TRANSPORT_COMMAND=()
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATHS=()
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_COUNT=0
  CLAUDE_RUNTIME_SHEBANG_STACK=()

  claude_runtime_inspect_shebang_path "$canonical_target" 0 "$execution_cwd" "launcher" || return 1
  if [ "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_COUNT" -gt 0 ]; then
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="available"
  fi
  return 0
}

# claude-review-helper-complete: runtime_v4
