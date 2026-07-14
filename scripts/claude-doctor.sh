#!/usr/bin/env bash

case "$-" in
  *p*) ;;
  *)
    builtin printf '%s\n' 'claude-doctor.sh requires Bash privileged mode before line 1; invoke it with: BASH_ENV= ENV= <trusted-bash> --noprofile --norc -p <installed-doctor>' >&2
    builtin exit 2
    ;;
esac
if [[ -n "${BASH_ENV-}" || -n "${ENV-}" ]]; then
  builtin printf '%s\n' 'claude-doctor.sh requires BASH_ENV and ENV to be empty before Bash starts; invoke it with: BASH_ENV= ENV= <trusted-bash> --noprofile --norc -p <installed-doctor>' >&2
  builtin exit 2
fi

CLAUDE_RUNTIME_INHERITED_PATH="${PATH-}"
export CLAUDE_RUNTIME_INHERITED_PATH

claude_bootstrap_fhs_symlink_safe() {
  local current="$1"
  local trusted_readlink="$2"
  local fhs_usr_bin="$3"
  local fhs_bin="$4"
  local alternatives_root="$5"
  local link_output=""
  local link_target=""
  local parent=""
  local physical_parent=""
  local basename_part=""
  local depth=0

  [ -x "$trusted_readlink" ] || return 1
  fhs_usr_bin="$(CDPATH=; cd -P -- "$fhs_usr_bin" 2>/dev/null && pwd -P)" || return 1
  fhs_bin="$(CDPATH=; cd -P -- "$fhs_bin" 2>/dev/null && pwd -P)" || return 1
  if [ -d "$alternatives_root" ]; then
    alternatives_root="$(CDPATH=; cd -P -- "$alternatives_root" 2>/dev/null && pwd -P)" || return 1
  else
    alternatives_root=""
  fi
  basename_part="${current##*/}"
  parent="${current%/*}"
  [ -n "$parent" ] || parent="/"
  physical_parent="$(CDPATH=; cd -P -- "$parent" 2>/dev/null && pwd -P)" || return 1
  if [ "$physical_parent" = "/" ]; then
    current="/$basename_part"
  else
    current="$physical_parent/$basename_part"
  fi
  while [ -L "$current" ]; do
    depth=$((depth + 1))
    [ "$depth" -le 8 ] || return 1
    case "$current" in
      "$fhs_usr_bin"/*|"$fhs_bin"/*) ;;
      "$alternatives_root"/*) [ -n "$alternatives_root" ] || return 1 ;;
      *) return 1 ;;
    esac
    link_output="$("$trusted_readlink" -n "$current" 2>/dev/null && printf '\001')" || return 1
    case "$link_output" in
      *$'\001') ;;
      *) return 1 ;;
    esac
    link_target="${link_output%$'\001'}"
    case "$link_target" in
      /*) current="$link_target" ;;
      *) current="${current%/*}/$link_target" ;;
    esac
    basename_part="${current##*/}"
    parent="${current%/*}"
    [ -n "$parent" ] || parent="/"
    physical_parent="$(CDPATH=; cd -P -- "$parent" 2>/dev/null && pwd -P)" || return 1
    if [ "$physical_parent" = "/" ]; then
      current="/$basename_part"
    else
      current="$physical_parent/$basename_part"
    fi
  done

  [ -f "$current" ] && [ -x "$current" ] && [ ! -L "$current" ] || return 1
  case "$current" in
    "$fhs_usr_bin"/*|"$fhs_bin"/*) return 0 ;;
    *) return 1 ;;
  esac
}

claude_bootstrap_utility_safe() {
  local utility="$1"
  local candidate_path="$2"
  local trusted_store_root="$3"
  local fhs_usr_bin="$4"
  local fhs_bin="$5"
  local alternatives_root="$6"
  local trusted_readlink="$7"
  local trusted_root=""
  local store_entry=""
  local store_target=""
  shift 7

  case "$candidate_path" in
    "$fhs_usr_bin"/*|"$fhs_bin"/*|"$trusted_store_root"/*)
      ;;
    *)
      for trusted_root in "$@"; do
        case "$candidate_path" in
          "$trusted_root"/*)
            break
            ;;
        esac
      done
      [ -n "$trusted_root" ] || return 1
      case "$candidate_path" in
        "$trusted_root"/*) ;;
        *) return 1 ;;
      esac
      ;;
  esac

  if [ -f "$candidate_path" ] && [ -x "$candidate_path" ] && [ ! -L "$candidate_path" ]; then
    return 0
  fi

  case "$candidate_path" in
    "$fhs_usr_bin"/*|"$fhs_bin"/*)
      claude_bootstrap_fhs_symlink_safe \
        "$candidate_path" \
        "$trusted_readlink" \
        "$fhs_usr_bin" \
        "$fhs_bin" \
        "$alternatives_root"
      return $?
      ;;
  esac

  # Nix profiles expose immutable store executables through per-command
  # symlinks. Match the resolved inode to a regular executable target in the
  # store without executing an unvalidated readlink helper.
  case "$candidate_path" in
    "$trusted_store_root"/*)
      [ -L "$candidate_path" ] || return 1
      for store_entry in \
        "$trusted_store_root"/*/bin/"$utility" \
        "$trusted_store_root"/*/sbin/"$utility"; do
        [ -e "$store_entry" ] || continue
        [ "$candidate_path" -ef "$store_entry" ] || continue
        if [ -f "$store_entry" ] && [ -x "$store_entry" ] && [ ! -L "$store_entry" ]; then
          return 0
        fi
        for store_target in "${store_entry%/*}"/*; do
          [ -f "$store_target" ] && [ -x "$store_target" ] && [ ! -L "$store_target" ] || continue
          if [ "$candidate_path" -ef "$store_target" ]; then
            return 0
          fi
        done
      done
      ;;
  esac
  return 1
}

claude_build_trusted_bootstrap_path() {
  local inherited_path="$1"
  local trusted_store_root="$2"
  local fhs_usr_bin="$3"
  local fhs_bin="$4"
  local candidate_path=""
  local physical_path=""
  local remaining=""
  local trusted_path=""
  local required_utility=""
  local optional_utility=""
  local trusted_readlink=""
  local trusted_windows_roots=()

  if [ -d "$trusted_store_root" ]; then
    trusted_store_root="$(CDPATH=; cd -P -- "$trusted_store_root" 2>/dev/null && pwd -P)" || return 1
  fi
  for candidate_path in "$fhs_usr_bin" "$fhs_bin"; do
    [ -d "$candidate_path" ] || continue
    case ":$trusted_path:" in
      *":$candidate_path:"*) ;;
      *) trusted_path="${trusted_path:+$trusted_path:}$candidate_path" ;;
    esac
  done

  # Git for Windows installs the native git.exe outside Git Bash's /usr/bin.
  # Admit only the fixed installation roots supplied by Git for Windows, and
  # only on its POSIX compatibility hosts.
  case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*)
      for candidate_path in "/mingw64/bin" "/mingw32/bin"; do
        [ -d "$candidate_path" ] || continue
        physical_path="$(CDPATH=; cd -P -- "$candidate_path" 2>/dev/null && pwd -P)" || continue
        trusted_windows_roots+=("$physical_path")
        case ":$trusted_path:" in
          *":$physical_path:"*) ;;
          *) trusted_path="${trusted_path:+$trusted_path:}$physical_path" ;;
        esac
      done
      ;;
  esac

  remaining="${inherited_path}:"
  while [ -n "$remaining" ]; do
    candidate_path="${remaining%%:*}"
    remaining="${remaining#*:}"
    [ -n "$candidate_path" ] || continue
    physical_path="$(CDPATH=; cd -P -- "$candidate_path" 2>/dev/null && pwd -P)" || continue
    case "$physical_path" in
      "$trusted_store_root"/*)
        case ":$trusted_path:" in
          *":$physical_path:"*) ;;
          *) trusted_path="${trusted_path:+$trusted_path:}$physical_path" ;;
        esac
        ;;
    esac
  done

  [ -n "$trusted_path" ] || return 1
  PATH="$trusted_path"
  trusted_readlink="$(type -P readlink 2>/dev/null || true)"
  if ! claude_bootstrap_utility_safe \
    readlink \
    "$trusted_readlink" \
    "$trusted_store_root" \
    "$fhs_usr_bin" \
    "$fhs_bin" \
    "/etc/alternatives" \
    "" \
    "${trusted_windows_roots[@]+"${trusted_windows_roots[@]}"}"; then
    printf 'Unsafe bootstrap utility entry: readlink\n' >&2
    return 1
  fi
  for required_utility in awk basename bash cat chmod cut dirname git grep mkdir mktemp readlink rm sed stat tr wc; do
    candidate_path="$(type -P "$required_utility" 2>/dev/null || true)"
    if ! claude_bootstrap_utility_safe \
      "$required_utility" \
      "$candidate_path" \
      "$trusted_store_root" \
      "$fhs_usr_bin" \
      "$fhs_bin" \
      "/etc/alternatives" \
      "$trusted_readlink" \
      "${trusted_windows_roots[@]+"${trusted_windows_roots[@]}"}"; then
      printf 'Unsafe bootstrap utility entry: %s\n' "$required_utility" >&2
      return 1
    fi
  done
  for optional_utility in jq; do
    candidate_path="$(type -P "$optional_utility" 2>/dev/null || true)"
    [ -n "$candidate_path" ] || continue
    if ! claude_bootstrap_utility_safe \
      "$optional_utility" \
      "$candidate_path" \
      "$trusted_store_root" \
      "$fhs_usr_bin" \
      "$fhs_bin" \
      "/etc/alternatives" \
      "$trusted_readlink" \
      "${trusted_windows_roots[@]+"${trusted_windows_roots[@]}"}"; then
      printf 'Unsafe optional bootstrap utility entry: %s\n' "$optional_utility" >&2
      return 1
    fi
  done
  printf '%s' "$trusted_path"
}

PATH="$(claude_build_trusted_bootstrap_path "$CLAUDE_RUNTIME_INHERITED_PATH" "/nix/store" "/usr/bin" "/bin")" || {
  printf '%s\n' 'No trusted FHS or immutable Nix bootstrap utilities were available.' >&2
  exit 2
}
export PATH
unset -f claude_build_trusted_bootstrap_path
unset -f claude_bootstrap_utility_safe
unset -f claude_bootstrap_fhs_symlink_safe
unset BASH_ENV ENV

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INVOCATION_CWD="$(pwd -P)"
REPO_ROOT="$INVOCATION_CWD"
CONFIG_FILE=""
PROBE_TIMEOUT_SECONDS="${CLAUDE_DOCTOR_PROBE_TIMEOUT_SECONDS:-12}"
SKIP_PROBES="false"
LOCATOR_HELPER="$SCRIPT_DIR/claude-locator.sh"
RUNTIME_HELPER="$SCRIPT_DIR/claude-runtime.sh"
CONFIG_HELPER="$SCRIPT_DIR/claude-config.sh"
CLAUDE_RUNTIME_CWD=""
CLAUDE_PROCESS_DRIVER=""
CLAUDE_PROCESS_DRIVER_TRANSPORT=""

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
      # Compatibility no-op: doctor is always report-only and never updates.
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
  "$BASH" --noprofile --norc -p -n "$helper_file" >/dev/null 2>&1 || return 1
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

config_helper_contract_valid() {
  local required_variable=""

  [ "${CLAUDE_CONFIG_CONTRACT:-}" = "config_v1" ] || return 1
  for required_variable in \
    CLAUDE_CONFIG_DEFAULT_EFFORT \
    CLAUDE_CONFIG_DEFAULT_MODEL \
    CLAUDE_CONFIG_DEFAULT_MAX_BUDGET_USD \
    CLAUDE_CONFIG_DEFAULT_REVIEW_TIMEOUT_SECONDS \
    CLAUDE_CONFIG_DEFAULT_LIVE_PROBE_BUDGET_USD \
    CLAUDE_CONFIG_DEFAULT_LIVE_PROBE_MODEL; do
    [ "${!required_variable+x}" = "x" ] && [ -n "${!required_variable}" ] || return 1
  done
}

printf 'CLAUDE_REVIEW_DOCTOR\n'
print_kv "repo_root" "$REPO_ROOT"
print_kv "skill_root" "$SKILL_ROOT"
print_kv "config_file" "$CONFIG_FILE"

if ! load_required_claude_helper \
  "$CONFIG_HELPER" \
  "# claude-review-helper-complete: config_v1" \
  claude_config_load_file \
  claude_config_main || ! config_helper_contract_valid; then
  print_kv "doctor_status" "bridge_installation_incomplete"
  print_kv "bridge_component" "claude-config.sh"
  print_kv "bridge_guidance" "Reinstall or update the complete claude-review skill, then retry."
  exit 0
fi

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
  claude_runtime_probe_with_timeout \
  claude_runtime_prepare_python_argv \
  claude_runtime_python_transport_path \
  claude_runtime_resolve_trusted_python \
  claude_runtime_resolve_path_dependency \
  claude_runtime_run_direct \
  claude_runtime_run_with_timeout \
  claude_runtime_windows_executable_path \
  claude_runtime_scrub_environment \
  claude_runtime_write_python_driver; then
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
CLAUDE_PROCESS_DRIVER="$CLAUDE_RUNTIME_CWD/process-driver.py"
if claude_runtime_resolve_trusted_python "$REPO_ROOT" "$INVOCATION_CWD" "$CLAUDE_RUNTIME_CWD"; then
  if ! claude_runtime_write_python_driver "$CLAUDE_PROCESS_DRIVER" || \
    ! CLAUDE_PROCESS_DRIVER_TRANSPORT="$(claude_runtime_python_transport_path "$CLAUDE_PROCESS_DRIVER")" || \
    ! MSYS2_ARG_CONV_EXCL='*' "$CLAUDE_RUNTIME_PYTHON_BIN" -I - "$CLAUDE_PROCESS_DRIVER_TRANSPORT" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys

driver = Path(sys.argv[1])
compile(driver.read_text(encoding="utf-8"), str(driver), "exec")
PY
  then
    print_kv "doctor_status" "bridge_installation_incomplete"
    print_kv "bridge_component" "claude-runtime.sh"
    print_kv "bridge_guidance" "Reinstall or update the complete claude-review skill, then retry."
    exit 0
  fi
fi

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
  local passwd_status=""

  case "$inherited_home" in
    /*)
      ;;
    *)
      printf 'missing_or_non_absolute'
      return 0
      ;;
  esac
  if [ -z "${CLAUDE_RUNTIME_PYTHON_BIN:-}" ] || [ ! -r "$CLAUDE_PROCESS_DRIVER" ]; then
    printf 'passwd_unavailable'
    return 0
  fi
  if passwd_status="$(
    claude_runtime_run_with_timeout \
      "$CLAUDE_RUNTIME_PYTHON_BIN" \
      "$CLAUDE_PROCESS_DRIVER" \
      "$CLAUDE_RUNTIME_CWD" \
      "$PROBE_TIMEOUT_SECONDS" \
      - \
      "$CLAUDE_RUNTIME_PYTHON_BIN" -I -c '
import os
import sys

try:
    import pwd
    passwd_home = pwd.getpwuid(os.getuid()).pw_dir
except Exception:
    print("passwd_unavailable")
else:
    print("matches_passwd" if passwd_home == sys.argv[1] else "differs_passwd")
' "$inherited_home" 2>/dev/null
  )"; then
    case "$passwd_status" in
      matches_passwd|differs_passwd|passwd_unavailable)
        printf '%s' "$passwd_status"
        return 0
        ;;
    esac
  fi
  printf 'passwd_unavailable'
}

run_doctor_claude_with_timeout() {
  local timeout_seconds="$1"
  local claude_bin="$2"
  shift 2

  if [ -z "${CLAUDE_RUNTIME_PYTHON_BIN:-}" ] || [ ! -r "$CLAUDE_PROCESS_DRIVER" ]; then
    return 125
  fi

  claude_runtime_build_command "$claude_bin" "$@"
  claude_runtime_run_with_timeout \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$CLAUDE_PROCESS_DRIVER" \
    "$CLAUDE_RUNTIME_CWD" \
    "$timeout_seconds" \
    - \
    "${CLAUDE_RUNTIME_COMMAND[@]}"
}

run_probe() {
  local label="$1"
  local claude_bin="$2"
  shift 2

  if [ -z "${CLAUDE_RUNTIME_PYTHON_BIN:-}" ] || [ ! -r "$CLAUDE_PROCESS_DRIVER" ]; then
    if [ "${CLAUDE_RUNTIME_PYTHON_STATUS:-missing}" = "missing" ]; then
      print_kv "${label}_status" "skipped_no_python3"
    else
      print_kv "${label}_status" "skipped_untrusted_python3"
    fi
    return 0
  fi

  claude_runtime_build_command "$claude_bin" "$@"
  if ! claude_runtime_probe_with_timeout \
    "$label" \
    "$CLAUDE_RUNTIME_PYTHON_BIN" \
    "$CLAUDE_PROCESS_DRIVER" \
    "$CLAUDE_RUNTIME_CWD" \
    "$PROBE_TIMEOUT_SECONDS" \
    @probe \
    "${CLAUDE_RUNTIME_COMMAND[@]}"; then
    print_kv "${label}_status" "transport_unavailable"
  fi
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

print_kv "update_check" "skipped"

if [ -f "$CONFIG_HELPER" ]; then
  printf 'effective_config_begin\n'
  "$BASH" --noprofile --norc -p "$CONFIG_HELPER" show --config-file "$CONFIG_FILE" 2>/dev/null || true
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
print_kv "python_runtime_status" "${CLAUDE_RUNTIME_PYTHON_STATUS:-missing}"
print_kv "python_validation_scope" "${CLAUDE_RUNTIME_PYTHON_VALIDATION_SCOPE:-none}"
print_kv "python_validation_reason" "${CLAUDE_RUNTIME_PYTHON_VALIDATION_STATUS:-none}"

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
elif [ "$version_status" -eq 0 ] && [ -n "$version_output" ]; then
  print_kv "claude_version" "$version_output"
  print_kv "claude_runtime_status" "available"
else
  print_kv "claude_version" "unknown"
  print_kv "claude_runtime_status" "unusable_runner"
  print_kv "claude_runtime_guidance" "The version command failed or returned no version. Check launcher permissions and required runtime executables in Codex's inherited PATH; no login profile is loaded."
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
  if [ -n "${CLAUDE_RUNTIME_PYTHON_BIN:-}" ]; then
    AUTH_STATUS="$auth_status" "$CLAUDE_RUNTIME_PYTHON_BIN" -I - <<'PY' 2>/dev/null || print_kv "claude_auth_status" "present_unparsed"
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
  --output-format json \
  --disable-slash-commands

run_probe \
  "safe_mode_print_probe" \
  "$claude_bin" \
  -p \
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
