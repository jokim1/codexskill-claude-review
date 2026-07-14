#!/usr/bin/env bash

# Shared direct Claude command transport. This file must remain source-pure:
# definitions and readonly contract constants only.

readonly CLAUDE_RUNTIME_CONTRACT="direct_inherited_path_v1"

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

  CLAUDE_RUNTIME_COMMAND=(
    "$launch_path"
  )
  while [ "$#" -gt 0 ]; do
    CLAUDE_RUNTIME_COMMAND+=("$1")
    shift
  done
}

claude_runtime_run_direct() {
  local runtime_cwd="$1"
  local launch_path="$2"
  shift 2

  claude_runtime_build_command "$launch_path" "$@"
  (
    claude_runtime_scrub_environment
    CDPATH=
    cd -P -- "$runtime_cwd" || exit 1
    exec "${CLAUDE_RUNTIME_COMMAND[@]}"
  )
}

claude_runtime_check_launcher_dependency() {
  local canonical_target="${1:-}"
  local first_line=""
  local payload=""
  local interpreter=""
  local dependency=""
  local dependency_path=""
  local remainder=""
  local extra=""

  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unknown"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="none"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="none"

  [ -f "$canonical_target" ] || return 0
  IFS= read -r -n 4096 first_line < "$canonical_target" || true
  case "$first_line" in
    '#!'*)
      ;;
    *)
      return 0
      ;;
  esac

  payload="${first_line#\#!}"
  IFS=$' \t' read -r interpreter remainder <<< "$payload"
  if [ -z "$interpreter" ]; then
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unsupported"
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="shebang"
    return 1
  fi

  if [ "$interpreter" = "/usr/bin/env" ]; then
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
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="$dependency"
    dependency_path="$(type -P "$dependency" 2>/dev/null || true)"
    if [ -n "$dependency_path" ]; then
      CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="available"
      CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="$dependency_path"
      return 0
    fi
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="missing"
    return 1
  fi

  case "$interpreter" in
    /*)
      dependency="${interpreter##*/}"
      CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="$dependency"
      if [ -x "$interpreter" ]; then
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="available"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="$interpreter"
        return 0
      fi
      CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="missing"
      return 1
      ;;
  esac

  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unsupported"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="shebang"
  return 1
}

# claude-review-helper-complete: runtime_v1
