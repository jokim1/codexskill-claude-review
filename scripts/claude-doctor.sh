#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INVOCATION_CWD="$(pwd -P)"
REPO_ROOT="$INVOCATION_CWD"
CONFIG_FILE=""
PROBE_TIMEOUT_SECONDS="${CLAUDE_DOCTOR_PROBE_TIMEOUT_SECONDS:-12}"
SKIP_PROBES="false"
SKIP_UPDATE_CHECK="${CLAUDE_DOCTOR_SKIP_UPDATE_CHECK:-false}"
LOCATOR_HELPER="$SCRIPT_DIR/claude-locator.sh"
RUNTIME_HELPER="$SCRIPT_DIR/claude-runtime.sh"
CONFIG_HELPER="$SCRIPT_DIR/claude-config.sh"
CLAUDE_RUNTIME_CWD=""

usage() {
  cat <<'EOF'
Usage:
  claude-doctor.sh [--repo-root <path>] [--skill-root <path>] [--config-file <path>] [--probe-timeout <seconds>] [--skip-probes] [--skip-update-check]

Diagnoses the installed /claude-review bridge. It reports bounded discovery,
trust, inherited-environment, and subscription-only runtime diagnostics.
EOF
}

normalize_path() {
  local path="$1"

  case "$path" in
    ''|/*)
      printf '%s' "$path"
      ;;
    *)
      printf '%s/%s' "$INVOCATION_CWD" "$path"
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$(normalize_path "${2:-}")"
      shift 2
      ;;
    --skill-root)
      SKILL_ROOT="$(normalize_path "${2:-}")"
      SCRIPT_DIR="$SKILL_ROOT/scripts"
      LOCATOR_HELPER="$SCRIPT_DIR/claude-locator.sh"
      RUNTIME_HELPER="$SCRIPT_DIR/claude-runtime.sh"
      CONFIG_HELPER="$SCRIPT_DIR/claude-config.sh"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="$(normalize_path "${2:-}")"
      shift 2
      ;;
    --probe-timeout)
      PROBE_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --skip-probes)
      SKIP_PROBES="true"
      shift
      ;;
    --skip-update-check)
      SKIP_UPDATE_CHECK="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$PROBE_TIMEOUT_SECONDS" in
  ''|*[!0-9]*|0)
    PROBE_TIMEOUT_SECONDS="12"
    ;;
esac

if [ -z "$CONFIG_FILE" ]; then
  CONFIG_FILE="$REPO_ROOT/.codex/claude/config.env"
fi

RUN_REVIEW="$SKILL_ROOT/scripts/run-review.sh"
ROUTER="$SKILL_ROOT/scripts/claude-command-router.sh"
UPDATE_CHECK="$SKILL_ROOT/scripts/claude-update-check.sh"

print_kv() {
  printf '%s=%s\n' "$1" "$2"
}

helper_has_final_marker() {
  local helper_file="$1"
  local expected_marker="$2"
  local line=""
  local final_line=""

  while IFS= read -r line || [ -n "$line" ]; do
    final_line="$line"
  done < "$helper_file"
  [ "$final_line" = "$expected_marker" ]
}

load_required_claude_helper() {
  local helper_file="$1"
  local expected_marker="$2"
  shift 2
  local required_symbol=""

  [ -r "$helper_file" ] && [ -f "$helper_file" ] || return 1
  case "${BASH:-}" in
    /*)
      ;;
    *)
      return 1
      ;;
  esac
  [ -f "$BASH" ] && [ -x "$BASH" ] || return 1
  /usr/bin/env -u BASH_ENV -u ENV -- "$BASH" --noprofile --norc -n "$helper_file" >/dev/null 2>&1 || return 1
  helper_has_final_marker "$helper_file" "$expected_marker" || return 1
  # shellcheck source=/dev/null
  if source "$helper_file" >/dev/null 2>&1; then
    :
  else
    return 1
  fi
  for required_symbol in "$@"; do
    declare -F "$required_symbol" >/dev/null 2>&1 || return 1
  done
  return 0
}

printf 'CLAUDE_REVIEW_DOCTOR\n'
print_kv "repo_root" "$REPO_ROOT"
print_kv "skill_root" "$SKILL_ROOT"
print_kv "config_file" "$CONFIG_FILE"

if ! load_required_claude_helper \
  "$LOCATOR_HELPER" \
  "# claude-review-helper-complete: locator_v1" \
  claude_locator_path_candidate \
  claude_locator_native_supported \
  claude_locator_native_path \
  claude_locator_homebrew_paths \
  claude_locator_first_present_fallback \
  claude_locator_is_dangling_symlink \
  claude_locator_validate_candidate \
  claude_locator_validate_launcher_dependency; then
  print_kv "doctor_status" "bridge_installation_incomplete"
  print_kv "bridge_component" "claude-locator.sh"
  print_kv "bridge_guidance" "Reinstall or update the complete claude-review skill, then retry."
  exit 0
fi

if ! load_required_claude_helper \
  "$RUNTIME_HELPER" \
  "# claude-review-helper-complete: runtime_v1" \
  claude_runtime_check_launcher_dependency \
  claude_runtime_build_command \
  claude_runtime_prepare_python_argv \
  claude_runtime_resolve_path_dependency \
  claude_runtime_run_direct \
  claude_runtime_windows_executable_path \
  claude_runtime_scrub_environment; then
  print_kv "doctor_status" "bridge_installation_incomplete"
  print_kv "bridge_component" "claude-runtime.sh"
  print_kv "bridge_guidance" "Reinstall or update the complete claude-review skill, then retry."
  exit 0
fi

if [ "${CLAUDE_LOCATOR_CONTRACT:-}" != "bounded_path_native_homebrew_v1" ]; then
  print_kv "doctor_status" "bridge_installation_incomplete"
  print_kv "bridge_component" "claude-locator.sh"
  print_kv "bridge_guidance" "Reinstall or update the complete claude-review skill, then retry."
  exit 0
fi

if [ "${CLAUDE_RUNTIME_CONTRACT:-}" != "direct_inherited_path_v1" ]; then
  print_kv "doctor_status" "bridge_installation_incomplete"
  print_kv "bridge_component" "claude-runtime.sh"
  print_kv "bridge_guidance" "Reinstall or update the complete claude-review skill, then retry."
  exit 0
fi

CLAUDE_RUNTIME_CWD="$(mktemp -d /tmp/claude-review-runtime-XXXXXX)"
chmod 700 "$CLAUDE_RUNTIME_CWD"
trap 'rm -rf "$CLAUDE_RUNTIME_CWD"' EXIT

flag_state() {
  local file="$1"
  local pattern="$2"

  if [ -f "$file" ] && grep -q -- "$pattern" "$file"; then
    printf 'ok'
  else
    printf 'missing'
  fi
}

redacted_env_presence() {
  local name="$1"
  if [ -n "${!name+x}" ]; then
    printf 'present'
  else
    printf 'absent'
  fi
}

inherited_home_status() {
  local inherited_home="${HOME:-}"

  case "$inherited_home" in
    /*)
      ;;
    *)
      printf 'missing_or_non_absolute'
      return 0
      ;;
  esac
  if ! type -P python3 >/dev/null 2>&1; then
    printf 'passwd_unavailable'
    return 0
  fi
  python3 - "$inherited_home" <<'PY' 2>/dev/null || printf 'passwd_unavailable'
import os
import pwd
import sys

try:
    passwd_home = pwd.getpwuid(os.getuid()).pw_dir
except Exception:
    print("passwd_unavailable")
else:
    print("matches_passwd" if passwd_home == sys.argv[1] else "differs_passwd")
PY
}

run_doctor_claude_with_timeout() {
  local timeout_seconds="$1"
  local claude_bin="$2"
  local msys_arg_conv_present="${MSYS2_ARG_CONV_EXCL+x}"
  local msys_arg_conv_value="${MSYS2_ARG_CONV_EXCL-}"
  shift 2

  if ! type -P python3 >/dev/null 2>&1; then
    return 125
  fi

  claude_runtime_build_command "$claude_bin" "$@"
  claude_runtime_prepare_python_argv "${CLAUDE_RUNTIME_COMMAND[@]}" || return 126
  (
    claude_runtime_scrub_environment
    CDPATH=
    cd -P -- "$CLAUDE_RUNTIME_CWD" || exit 1
    MSYS2_ARG_CONV_EXCL='*' python3 - \
      "$timeout_seconds" \
      "$msys_arg_conv_present" \
      "$msys_arg_conv_value" \
      "${CLAUDE_RUNTIME_PYTHON_ARGV[@]}" <<'PY'
import os
import signal
import subprocess
import sys

timeout = int(sys.argv[1])
msys_arg_conv_present = sys.argv[2] == "x"
msys_arg_conv_value = sys.argv[3]
cmd = sys.argv[4:]
child_env = os.environ.copy()
if msys_arg_conv_present:
    child_env["MSYS2_ARG_CONV_EXCL"] = msys_arg_conv_value
else:
    child_env.pop("MSYS2_ARG_CONV_EXCL", None)

process_options = {}
if os.name == "nt":
    process_options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
else:
    process_options["start_new_session"] = True

proc = subprocess.Popen(
    cmd,
    cwd=os.getcwd(),
    shell=False,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=child_env,
    **process_options,
)
try:
    out, err = proc.communicate(timeout=timeout)
except subprocess.TimeoutExpired:
    try:
        if os.name == "nt":
            proc.terminate()
        else:
            os.killpg(proc.pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        proc.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            if os.name == "nt":
                proc.kill()
            else:
                os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
    sys.exit(124)

sys.stdout.write(out)
sys.stderr.write(err)
sys.exit(proc.returncode)
PY
  )
}

run_probe() {
  local label="$1"
  local claude_bin="$2"
  local msys_arg_conv_present="${MSYS2_ARG_CONV_EXCL+x}"
  local msys_arg_conv_value="${MSYS2_ARG_CONV_EXCL-}"
  shift 2

  if ! type -P python3 >/dev/null 2>&1; then
    print_kv "${label}_status" "skipped_no_python3"
    return 0
  fi

  claude_runtime_build_command "$claude_bin" "$@"
  if ! claude_runtime_prepare_python_argv "${CLAUDE_RUNTIME_COMMAND[@]}"; then
    print_kv "${label}_status" "transport_unavailable"
    return 0
  fi
  (
    claude_runtime_scrub_environment
    CDPATH=
    cd -P -- "$CLAUDE_RUNTIME_CWD" || exit 1
    MSYS2_ARG_CONV_EXCL='*' python3 - \
      "$label" \
      "$PROBE_TIMEOUT_SECONDS" \
      "$msys_arg_conv_present" \
      "$msys_arg_conv_value" \
      "${CLAUDE_RUNTIME_PYTHON_ARGV[@]}" <<'PY'
import os
import re
import signal
import subprocess
import sys
import time

def stop_process(proc, force=False):
    try:
        if os.name == "nt":
            proc.kill() if force else proc.terminate()
        else:
            os.killpg(proc.pid, signal.SIGKILL if force else signal.SIGTERM)
    except OSError:
        pass

label = sys.argv[1]
timeout = int(sys.argv[2])
msys_arg_conv_present = sys.argv[3] == "x"
msys_arg_conv_value = sys.argv[4]
cmd = sys.argv[5:]
child_env = os.environ.copy()
if msys_arg_conv_present:
    child_env["MSYS2_ARG_CONV_EXCL"] = msys_arg_conv_value
else:
    child_env.pop("MSYS2_ARG_CONV_EXCL", None)

started = time.time()
process_options = {}
if os.name == "nt":
    process_options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
else:
    process_options["start_new_session"] = True
try:
    proc = subprocess.Popen(
        cmd,
        cwd=os.getcwd(),
        shell=False,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=child_env,
        **process_options,
    )
except OSError as exc:
    print(f"{label}_status=spawn_failed")
    print(f"{label}_error_type={type(exc).__name__}")
    sys.exit(0)

try:
    out, err = proc.communicate("OK\n", timeout=timeout)
    status = "completed"
except subprocess.TimeoutExpired:
    stop_process(proc)
    try:
        out, err = proc.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        stop_process(proc, force=True)
        out, err = proc.communicate()
    status = "timeout"

combined = f"{out or ''}\n{err or ''}"
if re.search(r"oauth_refresh|\.claude", combined, re.I) and re.search(r"EPERM|EACCES|permission denied|operation not permitted", combined, re.I):
    classification = "claude_state_write_denied"
elif re.search(r"not logged in|auth login|setup-token|authentication", combined, re.I):
    classification = "authentication_unavailable"
elif re.search(r"maximum budget|error_max_budget_usd", combined, re.I):
    classification = "budget_exhausted"
elif proc.returncode == 0:
    classification = "ok"
else:
    classification = "unexpected_failure"

elapsed = time.time() - started
print(f"{label}_status={status}")
print(f"{label}_returncode={proc.returncode}")
print(f"{label}_elapsed_seconds={elapsed:.2f}")
print(f"{label}_stdout_bytes={len(out or '')}")
print(f"{label}_stderr_bytes={len(err or '')}")
print(f"{label}_classification={classification}")
PY
  )
}

print_kv "doctor_status" "ok"
print_kv "run_review" "$RUN_REVIEW"
print_kv "router" "$ROUTER"

if git -C "$SKILL_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  print_kv "skill_git_head" "$(git -C "$SKILL_ROOT" rev-parse --short=12 HEAD)"
  skill_git_branch="$(git -C "$SKILL_ROOT" branch --show-current 2>/dev/null || true)"
  if [ -z "$skill_git_branch" ]; then
    skill_git_branch="detached"
  fi
  print_kv "skill_git_branch" "$skill_git_branch"
  if [ -n "$(git -C "$SKILL_ROOT" status --porcelain --untracked-files=no 2>/dev/null || true)" ]; then
    print_kv "skill_git_tracked_changes" "yes"
  else
    print_kv "skill_git_tracked_changes" "no"
  fi
else
  print_kv "skill_git_head" "not_git_checkout"
fi

if [ -x "$RUN_REVIEW" ]; then
  print_kv "run_review_executable" "yes"
else
  print_kv "run_review_executable" "no"
fi
if [ -x "$ROUTER" ]; then
  print_kv "router_executable" "yes"
else
  print_kv "router_executable" "no"
fi

print_kv "runner_safe_mode" "$(flag_state "$RUN_REVIEW" "--safe-mode")"
print_kv "runner_tools_empty" "$(flag_state "$RUN_REVIEW" "--tools")"
print_kv "runner_strict_mcp_config" "$(flag_state "$RUN_REVIEW" "--strict-mcp-config")"
print_kv "runner_disable_slash_commands" "$(flag_state "$RUN_REVIEW" "--disable-slash-commands")"
print_kv "router_present" "$([ -f "$ROUTER" ] && printf 'ok' || printf 'missing')"

if [ "$SKIP_UPDATE_CHECK" = "true" ]; then
  print_kv "update_check" "skipped"
elif [ -x "$UPDATE_CHECK" ]; then
  update_output="$(CLAUDE_UPDATE_CHECK_TIMEOUT_SECONDS=5 bash "$UPDATE_CHECK" --show-up-to-date 2>&1 || true)"
  print_kv "update_check" "$(printf '%s' "$update_output" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
fi

if [ -f "$CONFIG_HELPER" ]; then
  printf 'effective_config_begin\n'
  bash "$CONFIG_HELPER" show --config-file "$CONFIG_FILE" 2>/dev/null || true
  printf 'effective_config_end\n'
fi

for inherited_name in \
  CLAUDE_CONFIG_DIR \
  HTTP_PROXY \
  HTTPS_PROXY \
  NO_PROXY \
  NODE_EXTRA_CA_CERTS \
  CLAUDE_CODE_CERT_STORE \
  CLAUDE_CODE_CLIENT_CERT \
  CLAUDE_CODE_CLIENT_KEY \
  CLAUDE_CODE_CLIENT_KEY_PASSPHRASE; do
  print_kv "inherited_env_${inherited_name}" "$(redacted_env_presence "$inherited_name")"
done
print_kv "login_profile_loaded" "false"
print_kv "inherited_env_note" "absent means not inherited by Codex; doctor does not source profiles or inspect Claude settings.json"
print_kv "inherited_env_guidance" "Put required config, proxy, CA, certificate-store, and mTLS values in Codex's launch environment or Claude settings.json; do not rely on profile sourcing."
print_kv "claude_auth_context" "subscription_only_credentials_scrubbed"

checked_native_path="unavailable"
if claude_locator_native_supported "${OSTYPE:-}"; then
  case "${HOME:-}" in
    /*)
      checked_native_path="$HOME/.local/bin/claude"
      ;;
  esac
fi
home_status="$(inherited_home_status)"
print_kv "checked_native_path" "$checked_native_path"
print_kv "inherited_home_status" "$home_status"
if [ "$home_status" = "differs_passwd" ]; then
  print_kv "inherited_home_guidance" "Codex has a remapped HOME; fix its launch environment and rerun doctor. Passwd HOME is diagnostic only and is never executed."
fi

candidate_path=""
candidate_source="missing"
stale_source="none"
stale_path="none"
stale_status="none"
if claude_locator_path_candidate "$INVOCATION_CWD"; then
  candidate_path="$CLAUDE_LOCATOR_CANDIDATE_PATH"
  candidate_source="path"
elif claude_locator_first_present_fallback; then
  candidate_path="$CLAUDE_LOCATOR_CANDIDATE_PATH"
  candidate_source="$CLAUDE_LOCATOR_CANDIDATE_SOURCE"
  stale_source="$CLAUDE_LOCATOR_DEFERRED_SOURCE"
  stale_path="$CLAUDE_LOCATOR_DEFERRED_PATH"
  stale_status="$CLAUDE_LOCATOR_DEFERRED_STATUS"
fi

path_status="not_found"
claude_bin="missing"
claude_target="missing"
trust_scope="none"
trust_reason="none"
launcher_dependency="none"
launcher_dependency_path="none"
launcher_dependency_resolution="none"
launcher_dependency_trust_scope="none"
launcher_dependency_trust_reason="none"
dependency_path=""
candidate_safe="false"

if [ -n "$candidate_path" ]; then
  if claude_locator_validate_candidate "$candidate_path" "$REPO_ROOT" "$INVOCATION_CWD"; then
    candidate_safe="true"
    claude_bin="$CLAUDE_LOCATOR_LAUNCH_PATH"
    claude_target="$CLAUDE_LOCATOR_CANONICAL_TARGET"
    if [ "$candidate_source" = "path" ]; then
      path_status="available"
    else
      path_status="installed_not_on_path"
    fi
    if ! claude_runtime_check_launcher_dependency "$claude_target" "$CLAUDE_RUNTIME_CWD"; then
      candidate_safe="false"
      launcher_dependency="$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY"
      launcher_dependency_resolution="${CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_RESOLUTION:-none}"
      case "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS" in
        unsupported)
          path_status="launcher_dependency_unsupported"
          ;;
        unreadable)
          path_status="launcher_dependency_unreadable"
          launcher_dependency_path="$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH"
          ;;
        *)
          path_status="launcher_dependency_missing"
          launcher_dependency_path="$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH"
          ;;
      esac
    else
      for dependency_path in "${CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATHS[@]+"${CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATHS[@]}"}"; do
        if ! claude_locator_validate_launcher_dependency \
          "$dependency_path" \
          "$REPO_ROOT" \
          "$INVOCATION_CWD"; then
          candidate_safe="false"
          path_status="launcher_dependency_unsafe"
          launcher_dependency="${dependency_path##*/}"
          launcher_dependency_path="${CLAUDE_LOCATOR_DEPENDENCY_LAUNCH_PATH:-$dependency_path}"
          launcher_dependency_trust_scope="${CLAUDE_LOCATOR_DEPENDENCY_VALIDATION_SCOPE:-launch}"
          launcher_dependency_trust_reason="${CLAUDE_LOCATOR_DEPENDENCY_VALIDATION_STATUS:-missing}"
          break
        fi
      done
    fi
  else
    claude_bin="${CLAUDE_LOCATOR_LAUNCH_PATH:-$candidate_path}"
    claude_target="${CLAUDE_LOCATOR_CANONICAL_TARGET:-missing}"
    trust_scope="${CLAUDE_LOCATOR_VALIDATION_SCOPE:-launch}"
    trust_reason="${CLAUDE_LOCATOR_VALIDATION_STATUS:-missing}"
    case "$CLAUDE_LOCATOR_VALIDATION_STATUS" in
      not_executable)
        path_status="not_executable"
        ;;
      not_regular)
        path_status="not_regular"
        ;;
      dangling_symlink)
        path_status="dangling_symlink"
        ;;
      temporary_path|repository_path|invocation_cwd_path|world_writable_file|world_writable_parent|validation_unavailable)
        path_status="unsafe_candidate"
        ;;
      *)
        path_status="not_found"
        ;;
    esac
  fi
fi

print_kv "claude_discovery" "$candidate_source"
print_kv "claude_path_status" "$path_status"
print_kv "claude_bin" "$claude_bin"
print_kv "claude_target" "$claude_target"
print_kv "claude_trust_scope" "$trust_scope"
print_kv "claude_trust_reason" "$trust_reason"
print_kv "claude_launcher_dependency" "$launcher_dependency"
print_kv "claude_launcher_dependency_path" "$launcher_dependency_path"
print_kv "claude_launcher_dependency_resolution" "$launcher_dependency_resolution"
print_kv "claude_launcher_dependency_trust_scope" "$launcher_dependency_trust_scope"
print_kv "claude_launcher_dependency_trust_reason" "$launcher_dependency_trust_reason"
print_kv "claude_runtime_contract" "$CLAUDE_RUNTIME_CONTRACT"
print_kv "stale_fallback_source" "$stale_source"
print_kv "stale_fallback_path" "$stale_path"
print_kv "stale_fallback_status" "$stale_status"

if [ "$stale_status" = "dangling_symlink" ]; then
  print_kv "stale_fallback_guidance" "Remove or reinstall the stale launcher; a later healthy default fallback was selected."
fi

if [ "$candidate_safe" != "true" ]; then
  case "$path_status" in
    not_found)
      print_kv "claude_guidance" "Claude was not found in PATH or checked official/default locations; this is inconclusive for custom prefixes. Install native Claude with: curl -fsSL https://claude.ai/install.sh | bash"
      ;;
    not_executable|not_regular|dangling_symlink)
      print_kv "claude_guidance" "Repair or reinstall the exact selected launcher, then rerun /claude-review doctor."
      ;;
    unsafe_candidate)
      print_kv "claude_guidance" "Use a trusted regular executable outside repository, invocation-CWD, temp, and world-writable boundaries."
      ;;
    launcher_dependency_missing)
      if [ "$launcher_dependency_resolution" = "absolute" ]; then
        print_kv "claude_guidance" "Repair or reinstall the launcher so the exact absolute interpreter exists and is executable; PATH changes cannot repair an absolute shebang."
      else
        print_kv "claude_guidance" "Expose the named interpreter to Codex's inherited PATH or install native Claude with: curl -fsSL https://claude.ai/install.sh | bash"
      fi
      ;;
    launcher_dependency_unsafe)
      print_kv "claude_guidance" "Use a trusted launcher interpreter outside repository, invocation-CWD, temp, world-writable file, and world-writable parent boundaries."
      ;;
    launcher_dependency_unsupported)
      print_kv "claude_guidance" "Use an argument-free absolute interpreter or exact '#!/usr/bin/env NAME' launcher shebang, or install native Claude with: curl -fsSL https://claude.ai/install.sh | bash"
      ;;
    launcher_dependency_unreadable)
      print_kv "claude_guidance" "Make the selected launcher and every shebang interpreter readable to Codex, or reinstall native Claude."
      ;;
  esac
  exit 0
fi

version_status=0
set +e
version_output="$(run_doctor_claude_with_timeout "$PROBE_TIMEOUT_SECONDS" "$claude_bin" --version 2>/dev/null)"
version_status=$?
if [ "$version_status" -ne 0 ] && [ "$version_status" -ne 124 ]; then
  version_output="$(run_doctor_claude_with_timeout "$PROBE_TIMEOUT_SECONDS" "$claude_bin" -v 2>/dev/null)"
  version_status=$?
fi
set -e
version_output="$(printf '%s' "$version_output" | sed -n '1p' | cut -c 1-160)"
if [ "$version_status" -eq 124 ]; then
  print_kv "claude_version" "unknown"
  print_kv "claude_runtime_status" "timeout"
  print_kv "claude_runtime_guidance" "The version check timed out; inspect the launcher/interpreter chain or increase --probe-timeout."
elif [ -n "$version_output" ]; then
  print_kv "claude_version" "$version_output"
  print_kv "claude_runtime_status" "available"
else
  print_kv "claude_version" "unknown"
  print_kv "claude_runtime_status" "unusable_runner"
  print_kv "claude_runtime_guidance" "Check launcher permissions and required runtime executables in Codex's inherited PATH; no login profile is loaded."
fi

auth_status_code=0
set +e
auth_status="$(run_doctor_claude_with_timeout "$PROBE_TIMEOUT_SECONDS" "$claude_bin" auth status 2>/dev/null)"
auth_status_code=$?
set -e
if [ "$auth_status_code" -eq 124 ]; then
  print_kv "claude_auth_status" "timeout"
  print_kv "claude_auth_guidance" "The auth status check timed out; inspect credential/keychain access and network reachability or increase --probe-timeout."
elif [ -n "$auth_status" ]; then
  if type -P python3 >/dev/null 2>&1; then
    AUTH_STATUS="$auth_status" python3 - <<'PY' 2>/dev/null || print_kv "claude_auth_status" "present_unparsed"
import json
import os

try:
    raw = os.environ.get("AUTH_STATUS", "")
    data = json.loads(raw)
except Exception:
    print("claude_auth_status=present_unparsed")
else:
    print(f"claude_auth_logged_in={data.get('loggedIn', 'unknown')}")
    print(f"claude_auth_provider={data.get('apiProvider', 'unknown')}")
PY
  else
    print_kv "claude_auth_status" "present_unparsed"
  fi
else
  print_kv "claude_auth_status" "empty"
  print_kv "claude_auth_guidance" "The bridge tests subscription auth with API credentials intentionally scrubbed; an API-key-only ordinary CLI may still work."
fi

if [ "$SKIP_PROBES" = "true" ]; then
  print_kv "probes" "skipped"
  exit 0
fi

print_kv "probe_timeout_seconds" "$PROBE_TIMEOUT_SECONDS"

run_probe \
  "plain_print_probe" \
  "$claude_bin" \
  -p \
  "Return OK only." \
  --output-format json \
  --disable-slash-commands

run_probe \
  "safe_mode_print_probe" \
  "$claude_bin" \
  -p \
  "Return OK only." \
  --safe-mode \
  --output-format json \
  --tools "" \
  --strict-mcp-config \
  --setting-sources local \
  --disable-slash-commands \
  --no-session-persistence \
  --permission-mode dontAsk \
  --effort low \
  --max-budget-usd 0.15
