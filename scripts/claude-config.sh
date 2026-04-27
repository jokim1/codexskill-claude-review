#!/usr/bin/env bash

CLAUDE_CONFIG_DEFAULT_EFFORT="xhigh"
CLAUDE_CONFIG_DEFAULT_MODEL="opus"
CLAUDE_CONFIG_DEFAULT_MAX_BUDGET_USD="5.00"
CLAUDE_CONFIG_DEFAULT_REVIEW_TIMEOUT_SECONDS="300"
CLAUDE_CONFIG_DEFAULT_LIVE_PROBE_BUDGET_USD="0.15"
CLAUDE_CONFIG_DEFAULT_LIVE_PROBE_MODEL="sonnet"

claude_config_usage() {
  cat <<'EOF'
Usage:
  claude-config.sh show [--config-file <path>]
  claude-config.sh set effort <low|medium|high|xhigh|extra-high|max> [--config-file <path>]
  claude-config.sh set model <alias-or-full-model> [--config-file <path>]
  claude-config.sh set budget <positive-decimal> [--config-file <path>]
  claude-config.sh set timeout <positive-integer-seconds> [--config-file <path>]
EOF
}

claude_config_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

claude_config_reset_defaults() {
  EFFORT="$CLAUDE_CONFIG_DEFAULT_EFFORT"
  MODEL="$CLAUDE_CONFIG_DEFAULT_MODEL"
  MAX_BUDGET_USD="$CLAUDE_CONFIG_DEFAULT_MAX_BUDGET_USD"
  REVIEW_TIMEOUT_SECONDS="$CLAUDE_CONFIG_DEFAULT_REVIEW_TIMEOUT_SECONDS"
  LIVE_PROBE_BUDGET_USD="$CLAUDE_CONFIG_DEFAULT_LIVE_PROBE_BUDGET_USD"
  LIVE_PROBE_MODEL="$CLAUDE_CONFIG_DEFAULT_LIVE_PROBE_MODEL"
}

claude_config_normalize_effort() {
  case "$1" in
    extra-high|extra_high)
      printf 'xhigh'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

claude_config_load_file() {
  local file="$1"
  local line="" key="" value=""

  claude_config_reset_defaults
  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="$(claude_config_trim "$line")"
    case "$line" in
      ''|\#*)
        continue
        ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"
    key="$(claude_config_trim "$key")"
    value="$(claude_config_trim "$value")"

    case "$key" in
      EFFORT)
        EFFORT="$(claude_config_normalize_effort "$value")"
        ;;
      MODEL)
        MODEL="$value"
        ;;
      MAX_BUDGET_USD)
        MAX_BUDGET_USD="$value"
        ;;
      REVIEW_TIMEOUT_SECONDS)
        REVIEW_TIMEOUT_SECONDS="$value"
        ;;
      LIVE_PROBE_BUDGET_USD)
        LIVE_PROBE_BUDGET_USD="$value"
        ;;
      LIVE_PROBE_MODEL)
        LIVE_PROBE_MODEL="$value"
        ;;
    esac
  done < "$file"
}

claude_config_write_file() {
  local file="$1"
  local dir=""

  dir="$(dirname "$file")"
  mkdir -p "$dir"

  cat > "$file" <<EOF
EFFORT=$EFFORT
MODEL=$MODEL
MAX_BUDGET_USD=$MAX_BUDGET_USD
REVIEW_TIMEOUT_SECONDS=$REVIEW_TIMEOUT_SECONDS
LIVE_PROBE_BUDGET_USD=$LIVE_PROBE_BUDGET_USD
LIVE_PROBE_MODEL=$LIVE_PROBE_MODEL
EOF
}

claude_config_print() {
  printf 'EFFORT=%s\n' "$EFFORT"
  printf 'MODEL=%s\n' "$MODEL"
  printf 'MAX_BUDGET_USD=%s\n' "$MAX_BUDGET_USD"
  printf 'REVIEW_TIMEOUT_SECONDS=%s\n' "$REVIEW_TIMEOUT_SECONDS"
  printf 'LIVE_PROBE_BUDGET_USD=%s\n' "$LIVE_PROBE_BUDGET_USD"
  printf 'LIVE_PROBE_MODEL=%s\n' "$LIVE_PROBE_MODEL"
}

claude_config_validate_effort() {
  case "$1" in
    low|medium|high|xhigh|max)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

claude_config_validate_positive_decimal() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+([.][0-9]+)?$' || return 1
  [ "$(printf '%s\n' "$1" | awk '{ if ($1 > 0) print 1; else print 0 }')" = "1" ]
}

claude_config_validate_positive_integer() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+$' || return 1
  [ "$1" -gt 0 ]
}

claude_config_main() {
  local command="${1:-}"
  local field=""
  local value=""
  local config_file="${PWD}/.codex/claude/config.env"

  [ "$#" -gt 0 ] || {
    claude_config_usage >&2
    return 2
  }
  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config-file)
        config_file="${2:-}"
        shift 2
        ;;
      *)
        case "$command" in
          set)
            if [ -z "$field" ]; then
              field="$1"
            elif [ -z "$value" ]; then
              value="$1"
            else
              claude_config_usage >&2
              return 2
            fi
            shift
            ;;
          show)
            claude_config_usage >&2
            return 2
            ;;
          *)
            claude_config_usage >&2
            return 2
            ;;
        esac
        ;;
    esac
  done

  case "$command" in
    show)
      claude_config_load_file "$config_file"
      claude_config_print
      ;;
    set)
      [ -n "$field" ] && [ -n "$value" ] || {
        claude_config_usage >&2
        return 2
      }
      claude_config_load_file "$config_file"
      case "$field" in
        effort)
          value="$(claude_config_normalize_effort "$value")"
          claude_config_validate_effort "$value" || {
            echo "Invalid effort: $value" >&2
            return 2
          }
          EFFORT="$value"
          ;;
        model)
          MODEL="$value"
          ;;
        budget)
          claude_config_validate_positive_decimal "$value" || {
            echo "Invalid budget: $value" >&2
            return 2
          }
          MAX_BUDGET_USD="$value"
          ;;
        timeout)
          claude_config_validate_positive_integer "$value" || {
            echo "Invalid timeout: $value" >&2
            return 2
          }
          REVIEW_TIMEOUT_SECONDS="$value"
          ;;
        *)
          echo "Unknown setting: $field" >&2
          return 2
          ;;
      esac
      claude_config_write_file "$config_file"
      claude_config_print
      ;;
    *)
      claude_config_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  claude_config_main "$@"
fi
