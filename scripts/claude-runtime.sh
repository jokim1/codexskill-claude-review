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

claude_runtime_prepare_python_argv() {
  local cygpath_bin=""
  local converted_path=""

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
      converted_path="$("$cygpath_bin" -w "${CLAUDE_RUNTIME_PYTHON_ARGV[0]}" 2>/dev/null)" || return 1
      [ -n "$converted_path" ] || return 1
      CLAUDE_RUNTIME_PYTHON_ARGV[0]="$converted_path"
      ;;
  esac
  return 0
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

claude_runtime_inspect_shebang_path() {
  local current_path="$1"
  local depth="$2"
  local first_line=""
  local payload=""
  local interpreter=""
  local dependency=""
  local dependency_path=""
  local remainder=""
  local extra=""
  local stack_index=0

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

  case "$interpreter" in
    /*/env|/env)
      CLAUDE_RUNTIME_LAUNCHER_INTERPRETER_PATH="$interpreter"
      if [ ! -f "$interpreter" ] || [ ! -x "$interpreter" ]; then
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="missing"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="env"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="$interpreter"
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
      claude_runtime_add_dependency_path "$interpreter"
      claude_runtime_inspect_shebang_path "$interpreter" "$((depth + 1))" || return 1
      dependency_path="$(type -P "$dependency" 2>/dev/null || true)"
      if [ -z "$dependency_path" ]; then
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="missing"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="$dependency"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="none"
        return 1
      fi
      claude_runtime_add_dependency_path "$dependency_path"
      claude_runtime_inspect_shebang_path "$dependency_path" "$((depth + 1))" || return 1
      return 0
      ;;
    /*)
      CLAUDE_RUNTIME_LAUNCHER_INTERPRETER_PATH="$interpreter"
      if [ ! -f "$interpreter" ] || [ ! -x "$interpreter" ]; then
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="missing"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="${interpreter##*/}"
        CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="$interpreter"
        return 1
      fi
      claude_runtime_add_dependency_path "$interpreter"
      claude_runtime_inspect_shebang_path "$interpreter" "$((depth + 1))" || return 1
      return 0
      ;;
  esac

  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unsupported"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="shebang"
  return 1
}

claude_runtime_check_launcher_dependency() {
  local canonical_target="${1:-}"

  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="unknown"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY="none"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATH="none"
  CLAUDE_RUNTIME_LAUNCHER_INTERPRETER_PATH="none"
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_PATHS=()
  CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_COUNT=0
  CLAUDE_RUNTIME_SHEBANG_STACK=()

  claude_runtime_inspect_shebang_path "$canonical_target" 0 || return 1
  if [ "$CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_COUNT" -gt 0 ]; then
    CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY_STATUS="available"
  fi
  return 0
}

# claude-review-helper-complete: runtime_v1
