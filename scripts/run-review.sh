#!/usr/bin/env bash

set -euo pipefail

MODE=""
ARTIFACT_FILE=""
BASE_PROMPT=""
APPEND_PROMPTS=()
CONFIG_FILE=""
SCHEMA_FILE=""
REPO_ROOT=""
BRANCH=""
BASE_BRANCH=""
PR_NUMBER=""
REVIEW_INSTRUCTIONS=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_HELPER="$SCRIPT_DIR/claude-config.sh"
CLAUDE_LOCATOR_HELPER="$SCRIPT_DIR/claude-locator.sh"
CLAUDE_RUNTIME_HELPER="$SCRIPT_DIR/claude-runtime.sh"
CLAUDE_INVOCATION_CWD="$(pwd -P)"
MAX_ARTIFACT_BYTES=""
# shellcheck source=/dev/null
source "$CONFIG_HELPER"

LIVE_PROBE_BUDGET_USD="$CLAUDE_CONFIG_DEFAULT_LIVE_PROBE_BUDGET_USD"
LIVE_PROBE_MODEL="$CLAUDE_CONFIG_DEFAULT_LIVE_PROBE_MODEL"
EFFORT="$CLAUDE_CONFIG_DEFAULT_EFFORT"
MODEL="$CLAUDE_CONFIG_DEFAULT_MODEL"
MAX_BUDGET_USD="$CLAUDE_CONFIG_DEFAULT_MAX_BUDGET_USD"
REVIEW_TIMEOUT_SECONDS="$CLAUDE_CONFIG_DEFAULT_REVIEW_TIMEOUT_SECONDS"
CLAUDE_RUNTIME_CWD=""

CLAUDE_BIN=""
CLAUDE_TARGET=""
CLAUDE_DISCOVERY_SOURCE="missing"
CLAUDE_RUNNER_DESC=""
CLAUDE_PRECHECK_MODE=""

CLAUDE_FAILURE_CODE=""
CLAUDE_FAILURE_SUMMARY=""
CLAUDE_FAILURE_QUESTION=""
CLAUDE_FOUND_ANY="false"
SELECTED_CLAUDE_CMD=()
REVIEW_EFFECTIVE_TIMEOUT_SECONDS=""
REVIEW_RETRY_TIMEOUT_SECONDS=""
REVIEW_TIMEOUT_ATTEMPTS="0"
REVIEW_TIMEOUT_ATTEMPT_SECONDS=""
LIVE_PROBE_TIMEOUT_SECONDS="${LIVE_PROBE_TIMEOUT_SECONDS:-30}"
CLAUDE_HOME_ERE="$(printf '%s' "$HOME" | sed 's/[][(){}.^$*+?|\\]/\\&/g')"
CLAUDE_CONFIG_DIR_ERE=""
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  CLAUDE_CONFIG_DIR_ERE="$(printf '%s' "$CLAUDE_CONFIG_DIR" | sed 's/[][(){}.^$*+?|\\]/\\&/g')"
fi
CLAUDE_STATE_PATH_PATTERN="oauth_refresh\\.lock|${CLAUDE_HOME_ERE}/\\.claude|~/\\.claude|CLAUDE_CONFIG_DIR"
if [ -n "$CLAUDE_CONFIG_DIR_ERE" ]; then
  CLAUDE_STATE_PATH_PATTERN="${CLAUDE_STATE_PATH_PATTERN}|${CLAUDE_CONFIG_DIR_ERE}"
fi
CLAUDE_PERMISSION_DENIED_PATTERN='EPERM|EACCES|operation not permitted|permission denied'
CLAUDE_ERROR_EXCERPT_PATTERN="${CLAUDE_PERMISSION_DENIED_PATTERN}|oauth_refresh\\.lock|\\.claude"

usage() {
  cat <<'EOF'
Usage:
  run-review.sh --mode <plan|code|pr|challenge_code|challenge_plan> --artifact-file <path> \
    --base-prompt <path> --schema-file <path> [options]

Options:
  --append-prompt <path>
  --config-file <path>
  --repo-root <path>
  --branch <name>
  --base-branch <name>
  --pr-number <number>
  --instructions <text>
EOF
}

normalize_cli_path() {
  local path="$1"

  case "$path" in
    ''|/*)
      printf '%s' "$path"
      ;;
    *)
      printf '%s/%s' "$PWD" "$path"
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --artifact-file)
      ARTIFACT_FILE="${2:-}"
      shift 2
      ;;
    --base-prompt)
      BASE_PROMPT="${2:-}"
      shift 2
      ;;
    --append-prompt)
      APPEND_PROMPTS+=("${2:-}")
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --schema-file)
      SCHEMA_FILE="${2:-}"
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="${2:-}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --base-branch)
      BASE_BRANCH="${2:-}"
      shift 2
      ;;
    --pr-number)
      PR_NUMBER="${2:-}"
      shift 2
      ;;
    --instructions)
      REVIEW_INSTRUCTIONS="${2:-}"
      shift 2
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

if [ -z "$MODE" ] || [ -z "$ARTIFACT_FILE" ] || [ -z "$BASE_PROMPT" ] || [ -z "$SCHEMA_FILE" ]; then
  usage >&2
  exit 2
fi

case "$MODE" in
  plan|code|pr|challenge_code|challenge_plan)
    ;;
  *)
    echo "Unsupported mode: $MODE" >&2
    usage >&2
    exit 2
    ;;
esac

ARTIFACT_FILE="$(normalize_cli_path "$ARTIFACT_FILE")"
BASE_PROMPT="$(normalize_cli_path "$BASE_PROMPT")"
SCHEMA_FILE="$(normalize_cli_path "$SCHEMA_FILE")"
if [ -n "$CONFIG_FILE" ]; then
  CONFIG_FILE="$(normalize_cli_path "$CONFIG_FILE")"
fi
if [ -n "$REPO_ROOT" ]; then
  REPO_ROOT="$(normalize_cli_path "$REPO_ROOT")"
fi
if [ "${#APPEND_PROMPTS[@]}" -gt 0 ]; then
  for append_prompt_index in "${!APPEND_PROMPTS[@]}"; do
    APPEND_PROMPTS[$append_prompt_index]="$(normalize_cli_path "${APPEND_PROMPTS[$append_prompt_index]}")"
  done
fi

json_string() {
  local value="$1"
  local escaped=""

  if command -v jq >/dev/null 2>&1; then
    jq -Rn --arg value "$value" '$value'
    return 0
  fi

  escaped="$value"
  escaped="${escaped//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  escaped="${escaped//$'\n'/\\n}"
  escaped="${escaped//$'\r'/\\r}"
  escaped="${escaped//$'\t'/\\t}"
  printf '"%s"' "$escaped"
}

emit_json() {
  local status="$1"
  local summary="$2"
  local question="$3"

  printf '{\n'
  printf '  "status": %s,\n' "$(json_string "$status")"
  printf '  "mode": %s,\n' "$(json_string "$MODE")"
  printf '  "summary": %s,\n' "$(json_string "$summary")"
  printf '  "findings": [],\n'
  if [ -n "$question" ]; then
    printf '  "open_questions": [%s]\n' "$(json_string "$question")"
  else
    printf '  "open_questions": []\n'
  fi
  printf '}\n'
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

emit_bridge_installation_incomplete() {
  local component="$1"

  emit_json \
    "blocked" \
    "The Claude review bridge installation is incomplete: required helper ${component} could not be loaded safely." \
    "Reinstall or update the complete claude-review skill, then retry."
}

if ! load_required_claude_helper \
  "$CLAUDE_LOCATOR_HELPER" \
  "# claude-review-helper-complete: locator_v1" \
  claude_locator_path_candidate \
  claude_locator_native_supported \
  claude_locator_native_path \
  claude_locator_homebrew_paths \
  claude_locator_first_present_fallback \
  claude_locator_validate_candidate; then
  emit_bridge_installation_incomplete "claude-locator.sh"
  exit 0
fi

if ! load_required_claude_helper \
  "$CLAUDE_RUNTIME_HELPER" \
  "# claude-review-helper-complete: runtime_v1" \
  claude_runtime_check_launcher_dependency \
  claude_runtime_build_command \
  claude_runtime_scrub_environment; then
  emit_bridge_installation_incomplete "claude-runtime.sh"
  exit 0
fi

if [ "${CLAUDE_RUNTIME_CONTRACT:-}" != "direct_inherited_path_v1" ]; then
  emit_bridge_installation_incomplete "claude-runtime.sh"
  exit 0
fi

CLAUDE_RUNTIME_CWD="$(mktemp -d /tmp/claude-review-runtime-XXXXXX)"
chmod 700 "$CLAUDE_RUNTIME_CWD"
trap 'rm -rf "$CLAUDE_RUNTIME_CWD"' EXIT

load_artifact_limits_or_emit_json() {
  local limits_error_file limits_error

  limits_error_file="$(mktemp /tmp/claude-review-limits-XXXXXX)"
  # shellcheck source=/dev/null
  if ! source "$SCRIPT_DIR/artifact-limits.sh" 2>"$limits_error_file"; then
    limits_error="$(cat "$limits_error_file")"
    rm -f "$limits_error_file"
    emit_json \
      "blocked" \
      "${limits_error:-Invalid CLAUDE_REVIEW_MAX_ARTIFACT_BYTES.}" \
      "Set CLAUDE_REVIEW_MAX_ARTIFACT_BYTES to a positive integer byte limit, or unset it to use 200000."
    exit 0
  fi
  rm -f "$limits_error_file"
  MAX_ARTIFACT_BYTES="$CLAUDE_REVIEW_MAX_ARTIFACT_BYTES"
}

load_artifact_limits_or_emit_json

artifact_is_split_part() {
  local first_line=""

  IFS= read -r first_line < "$ARTIFACT_FILE" || true
  [ "$first_line" = "Review Artifact Split Part" ]
}

canonical_path() {
  local path="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$path" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
    return 0
  fi

  if [ -d "$path" ]; then
    (cd "$path" && pwd -P)
    return 0
  fi

  (cd "$(dirname "$path")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")")
}

path_within() {
  local path="$1"
  local dir="$2"
  local path_real=""
  local dir_real=""

  path_real="$(canonical_path "$path" 2>/dev/null || true)"
  dir_real="$(canonical_path "$dir" 2>/dev/null || true)"
  [ -n "$path_real" ] && [ -n "$dir_real" ] || return 1

  case "$path_real" in
    "$dir_real"|"$dir_real"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

config_repo_root() {
  local config_dir=""

  [ -n "$CONFIG_FILE" ] || return 1
  [ "$(basename "$CONFIG_FILE")" = "config.env" ] || return 1
  config_dir="$(dirname "$CONFIG_FILE")"
  [ "$(basename "$config_dir")" = "claude" ] || return 1
  [ "$(basename "$(dirname "$config_dir")")" = ".codex" ] || return 1
  canonical_path "$(dirname "$config_dir")/.."
}

append_prompt_allowed() {
  local prompt="$1"
  local inferred_repo_root=""

  path_within "$prompt" "$HOME/.codex/claude" && return 0
  if [ -n "$REPO_ROOT" ] && path_within "$prompt" "$REPO_ROOT/.codex/claude"; then
    return 0
  fi
  inferred_repo_root="$(config_repo_root 2>/dev/null || true)"
  if [ -n "$inferred_repo_root" ] && path_within "$prompt" "$inferred_repo_root/.codex/claude"; then
    return 0
  fi
  return 1
}

trusted_review_bridge_guidance() {
  local installed_run_review="$HOME/.codex/skills/claude-review/scripts/run-review.sh"

  if [ -e "$installed_run_review" ]; then
    printf 'If this review bridge is running inside the Codex filesystem sandbox, run it outside that sandbox or approve this exact trusted installed-skill command prefix: ["bash", "%s"]. Do not approve repo-local worktree copies or broad prefixes such as ["bash"]. If it still fails outside the sandbox, check ownership and permissions for ~/.claude or CLAUDE_CONFIG_DIR.' "$installed_run_review"
    return 0
  fi

  printf 'If this review bridge is running inside the Codex filesystem sandbox, run it outside that sandbox or approve only the exact installed skill run-review.sh path you trust. Do not approve repo-local worktree copies or broad prefixes such as ["bash"]. If it still fails outside the sandbox, check ownership and permissions for ~/.claude or CLAUDE_CONFIG_DIR.'
}

validate_readable_inputs() {
  local artifact_base=""
  local append_prompt=""
  local inferred_repo_root=""

  artifact_base="$(basename "$ARTIFACT_FILE")"
  if ! path_within "$ARTIFACT_FILE" "/tmp" || [[ "$artifact_base" != claude-review-* ]]; then
    emit_json \
      "blocked" \
      "The review artifact path is outside the allowed Claude review temp-file boundary." \
      "Write the artifact to a /tmp/claude-review-* file, then retry."
    exit 0
  fi

  if ! path_within "$BASE_PROMPT" "$SKILL_DIR/prompts"; then
    emit_json \
      "blocked" \
      "The base prompt path is outside this installed skill's prompts directory." \
      "Use the bundled prompt under $SKILL_DIR/prompts."
    exit 0
  fi

  if ! path_within "$SCHEMA_FILE" "$SKILL_DIR/schemas"; then
    emit_json \
      "blocked" \
      "The schema path is outside this installed skill's schemas directory." \
      "Use the bundled schema under $SKILL_DIR/schemas."
    exit 0
  fi

  if [ -n "$CONFIG_FILE" ]; then
    inferred_repo_root="$(config_repo_root 2>/dev/null || true)"
    if [ -n "$REPO_ROOT" ] && ! path_within "$CONFIG_FILE" "$REPO_ROOT/.codex/claude"; then
      emit_json \
        "blocked" \
        "The config file path is outside the supplied repo root's .codex/claude config boundary." \
        "Use <repo>/.codex/claude/config.env for the same repo passed as --repo-root."
      exit 0
    fi
    if [ -z "$inferred_repo_root" ] || ! path_within "$CONFIG_FILE" "$inferred_repo_root/.codex/claude"; then
      emit_json \
        "blocked" \
        "The config file path is outside the allowed repo .codex/claude config boundary." \
        "Use <repo>/.codex/claude/config.env."
      exit 0
    fi
  fi

  if [ "${#APPEND_PROMPTS[@]}" -gt 0 ]; then
    for append_prompt in "${APPEND_PROMPTS[@]}"; do
      [ -n "$append_prompt" ] || continue
      [ -e "$append_prompt" ] || continue
      if ! append_prompt_allowed "$append_prompt"; then
        emit_json \
          "blocked" \
          "An append prompt path is outside the allowed Claude prompt override boundary." \
          "Use ~/.codex/claude/*.append.md or <repo>/.codex/claude/*.append.md."
        exit 0
      fi
    done
  fi
}

failure_priority() {
  case "${1:-}" in
    missing_binary)
      printf '1'
      ;;
    unusable_runner|launcher_dependency_missing)
      printf '2'
      ;;
    subscription_auth_unavailable)
      printf '3'
      ;;
    probe_budget_too_low)
      printf '4'
      ;;
    ambiguous_auth)
      printf '5'
      ;;
    probe_timed_out)
      printf '6'
      ;;
    claude_state_write_denied)
      printf '6'
      ;;
    review_budget_too_low)
      printf '7'
      ;;
    review_timed_out)
      printf '8'
      ;;
    invocation_failed)
      printf '9'
      ;;
    *)
      printf '0'
      ;;
  esac
}

record_failure() {
  local code="$1"
  local summary="$2"
  local question="$3"

  if failure_offers_doctor "$code"; then
    question="$(append_doctor_offer "$question")"
  fi
  if [ "$(failure_priority "$code")" -ge "$(failure_priority "$CLAUDE_FAILURE_CODE")" ]; then
    CLAUDE_FAILURE_CODE="$code"
    CLAUDE_FAILURE_SUMMARY="$summary"
    CLAUDE_FAILURE_QUESTION="$question"
  fi
}

failure_offers_doctor() {
  case "${1:-}" in
    missing_binary|unusable_runner|launcher_dependency_missing|subscription_auth_unavailable|ambiguous_auth|probe_timed_out|invocation_failed)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

append_doctor_offer() {
  local existing_guidance="$1"

  printf '%s\n\nRun /claude-review doctor now?\nReply Y to run diagnostics, or N to stop.' "$existing_guidance"
}

build_claude_cmd() {
  local claude_bin="$1"
  shift

  claude_runtime_build_command "$claude_bin" "$@"
  SELECTED_CLAUDE_CMD=("${CLAUDE_RUNTIME_COMMAND[@]}")
}

run_candidate_claude() {
  local claude_bin="$1"
  shift

  build_claude_cmd "$claude_bin" "$@"
  (
    claude_runtime_scrub_environment
    CDPATH=
    cd -P -- "$CLAUDE_RUNTIME_CWD" || exit 1
    "${SELECTED_CLAUDE_CMD[@]}"
  )
}

run_selected_claude() {
  run_candidate_claude "$CLAUDE_BIN" "$@"
}

run_built_claude_cmd_with_timeout() {
  local timeout_seconds="$1"
  shift

  if [ -z "$timeout_seconds" ] || [ "${timeout_seconds:-0}" -le 0 ] || ! command -v python3 >/dev/null 2>&1; then
    (
      claude_runtime_scrub_environment
      CDPATH=
      cd -P -- "$CLAUDE_RUNTIME_CWD" || exit 1
      "$@"
    )
    return
  fi

  (
    claude_runtime_scrub_environment
    CDPATH=
    cd -P -- "$CLAUDE_RUNTIME_CWD" || exit 1
    python3 - "$timeout_seconds" "$@" <<'PY'
import os
import subprocess
import sys

timeout = int(sys.argv[1])
cmd = sys.argv[2:]

try:
    completed = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        stdin=subprocess.DEVNULL,
        cwd=os.getcwd(),
        shell=False,
    )
except subprocess.TimeoutExpired as exc:
    if exc.stdout:
        sys.stdout.write(exc.stdout if isinstance(exc.stdout, str) else exc.stdout.decode())
    if exc.stderr:
        sys.stderr.write(exc.stderr if isinstance(exc.stderr, str) else exc.stderr.decode())
    sys.exit(124)

sys.stdout.write(completed.stdout)
sys.stderr.write(completed.stderr)
sys.exit(completed.returncode)
PY
  )
}

run_candidate_claude_with_timeout() {
  local timeout_seconds="$1"
  local claude_bin="$2"
  shift 2

  build_claude_cmd "$claude_bin" "$@"
  run_built_claude_cmd_with_timeout "$timeout_seconds" "${SELECTED_CLAUDE_CMD[@]}"
}

run_selected_claude_with_timeout() {
  local timeout_seconds="$1"
  shift

  run_candidate_claude_with_timeout "$timeout_seconds" "$CLAUDE_BIN" "$@"
}

review_timeout_model_is_opus() {
  case "${MODEL:-}" in
    *[Oo][Pp][Uu][Ss]*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

calculate_review_timeout_seconds() {
  local configured_timeout="${1:-0}"
  local bytes="${2:-0}"
  local timeout artifact_kib artifact_floor effort_floor model_floor

  case "$configured_timeout" in
    ''|*[!0-9]*)
      configured_timeout=0
      ;;
  esac
  case "$bytes" in
    ''|*[!0-9]*)
      bytes=0
      ;;
  esac

  timeout="$configured_timeout"
  artifact_kib=$(( (bytes + 1023) / 1024 ))
  artifact_floor=$((120 + artifact_kib * 4))
  [ "$artifact_floor" -gt 420 ] && artifact_floor=420

  case "${EFFORT:-}" in
    max)
      effort_floor=480
      ;;
    xhigh)
      effort_floor=420
      ;;
    high)
      effort_floor=300
      ;;
    medium)
      effort_floor=240
      ;;
    *)
      effort_floor=180
      ;;
  esac

  model_floor=0
  if review_timeout_model_is_opus; then
    model_floor=300
  fi

  [ "$timeout" -lt "$artifact_floor" ] && timeout="$artifact_floor"
  [ "$timeout" -lt "$effort_floor" ] && timeout="$effort_floor"
  [ "$timeout" -lt "$model_floor" ] && timeout="$model_floor"

  printf '%s' "$timeout"
}

calculate_review_retry_timeout_seconds() {
  local first_timeout="${1:-0}"
  local retry_timeout

  case "$first_timeout" in
    ''|*[!0-9]*)
      first_timeout=0
      ;;
  esac

  if [ "$first_timeout" -ge 900 ]; then
    printf '%s' "$first_timeout"
    return 0
  fi

  retry_timeout=$((first_timeout * 2))
  [ "$retry_timeout" -gt 900 ] && retry_timeout=900
  printf '%s' "$retry_timeout"
}

logged_in_state() {
  local status="$1"

  [ -n "$status" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    if printf '%s\n' "$status" | jq -e '.loggedIn == true' >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  printf '%s\n' "$status" | grep -q '"loggedIn":[[:space:]]*true'
}

logged_out_state() {
  local status="$1"

  [ -n "$status" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    if printf '%s\n' "$status" | jq -e '.loggedIn == false' >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  printf '%s\n' "$status" | grep -q '"loggedIn":[[:space:]]*false'
}

first_party_state() {
  local status="$1"

  [ -n "$status" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    if printf '%s\n' "$status" | jq -e '.apiProvider == "firstParty"' >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  printf '%s\n' "$status" | grep -q '"apiProvider":[[:space:]]*"firstParty"'
}

non_first_party_state() {
  local status="$1"

  [ -n "$status" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    if printf '%s\n' "$status" | jq -e '.apiProvider != null and .apiProvider != "firstParty"' >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  if first_party_state "$status"; then
    return 1
  fi

  printf '%s\n' "$status" | grep -q '"apiProvider":[[:space:]]*"'
}

live_probe_ok() {
  local output="$1"

  [ -n "$output" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    if printf '%s\n' "$output" | jq -e '.ok == true or .structured_output.ok == true' >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  printf '%s\n' "$output" | grep -q '"ok":[[:space:]]*true'
}

result_is_error() {
  local output="$1"

  [ -n "$output" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    if printf '%s\n' "$output" | jq -e '.is_error == true' >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  printf '%s\n' "$output" | grep -q '"is_error":[[:space:]]*true'
}

stamp_review_output_mode() {
  local output="$1"
  local tmp_output=""

  if [ -z "$output" ]; then
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    if printf '%s\n' "$output" | jq --arg mode "$MODE" '
      if type == "object" and (.structured_output | type == "object") then
        (.structured_output.mode = $mode) | .structured_output
      elif type == "object" then
        .mode = $mode
      else
        error("review output is not a JSON object")
      end
    '; then
      return 0
    fi
  fi

  if command -v python3 >/dev/null 2>&1; then
    tmp_output="$(mktemp /tmp/claude-review-output-XXXXXX)"
    printf '%s\n' "$output" > "$tmp_output"
    if python3 - "$MODE" "$tmp_output" <<'PY'
import json
from pathlib import Path
import sys

mode = sys.argv[1]
output_path = Path(sys.argv[2])

with output_path.open() as handle:
    data = json.load(handle)

if not isinstance(data, dict):
    raise ValueError("review output is not a JSON object")

structured_output = data.get("structured_output")
if isinstance(structured_output, dict):
    data = structured_output

data["mode"] = mode
json.dump(data, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
    then
      rm -f "$tmp_output"
      return 0
    fi
    rm -f "$tmp_output"
  fi

  return 1
}

budget_exhausted_output() {
  local output="$1"

  [ -n "$output" ] || return 1
  printf '%s\n' "$output" | grep -Eqi 'error_max_budget_usd|reached maximum budget|maximum budget'
}

auth_unavailable_output() {
  local output="$1"

  [ -n "$output" ] || return 1
  printf '%s\n' "$output" | grep -Eqi 'not logged in|auth login|setup-token|authentication'
}

claude_state_write_denied_output() {
  local output="$1"

  [ -n "$output" ] || return 1

  printf '%s\n' "$output" | grep -Eqi "$CLAUDE_STATE_PATH_PATTERN" || return 1
  printf '%s\n' "$output" | grep -Eqi "$CLAUDE_PERMISSION_DENIED_PATTERN" || return 1

  return 0
}

claude_error_excerpt() {
  local output="$1"
  local excerpt=""
  local strings=""
  local permission_excerpt=""
  local state_excerpt=""

  [ -n "$output" ] || return 0

  if command -v jq >/dev/null 2>&1; then
    strings="$(printf '%s\n' "$output" | jq -r '.. | strings' 2>/dev/null || true)"
  fi

  [ -n "$strings" ] || strings="$output"

  permission_excerpt="$(printf '%s\n' "$strings" | grep -Eim1 "$CLAUDE_PERMISSION_DENIED_PATTERN" || true)"
  state_excerpt="$(printf '%s\n' "$strings" | grep -Eim1 "$CLAUDE_STATE_PATH_PATTERN" || true)"

  if [ -n "$permission_excerpt" ] && [ -n "$state_excerpt" ] && [ "$permission_excerpt" != "$state_excerpt" ]; then
    excerpt="${permission_excerpt} ${state_excerpt}"
  else
    excerpt="${permission_excerpt:-$state_excerpt}"
  fi

  if [ -z "$excerpt" ]; then
    excerpt="$(printf '%s\n' "$strings" | grep -Eim1 "$CLAUDE_ERROR_EXCERPT_PATTERN" || true)"
  fi

  excerpt="$(printf '%s' "$excerpt" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c 1-240)"
  printf '%s' "$excerpt"
}

record_claude_state_write_denied_failure() {
  local output="$1"
  local excerpt=""
  local question=""

  question="$(trusted_review_bridge_guidance)"
  excerpt="$(claude_error_excerpt "$output")"
  if [ -n "$excerpt" ]; then
    question="${question} Claude error: ${excerpt}"
  fi

  record_failure \
    "claude_state_write_denied" \
    "Claude Code was found, but Claude could not write its first-party auth/config state." \
    "$question"
}

select_runner() {
  CLAUDE_BIN="$1"
  CLAUDE_RUNNER_DESC="$2"
  CLAUDE_PRECHECK_MODE="$3"
}

probe_runner_usability() {
  local claude_bin="$1"
  local description="$2"
  local auth_status=""
  local probe_output=""
  local probe_status=0
  local probe_timeout_seconds="$LIVE_PROBE_TIMEOUT_SECONDS"
  local probe_schema='{"type":"object","properties":{"ok":{"const":true}},"required":["ok"],"additionalProperties":false}'
  local probe_args=()

  case "$probe_timeout_seconds" in
    ''|*[!0-9]*|0)
      probe_timeout_seconds="30"
      ;;
  esac

  if ! claude_runtime_check_launcher_dependency "$CLAUDE_TARGET"; then
    record_failure \
      "launcher_dependency_missing" \
      "Claude Code was found, but its launcher interpreter is unavailable from Codex's inherited PATH." \
      "Make the '${CLAUDE_RUNTIME_LAUNCHER_DEPENDENCY}' interpreter available in the environment that launches Codex, or install the recommended native Claude with curl -fsSL https://claude.ai/install.sh | bash. Then run /claude-review doctor."
    return 1
  fi

  if ! run_candidate_claude "$claude_bin" -v >/dev/null 2>&1; then
    record_failure \
      "unusable_runner" \
      "Claude Code was found but could not run with Codex's inherited environment." \
      "Check Claude CLI permissions and ensure any required launcher or runtime executable is present in Codex's inherited PATH, then retry."
    return 1
  fi

  auth_status="$(run_candidate_claude "$claude_bin" auth status 2>/dev/null || true)"
  if non_first_party_state "$auth_status"; then
    record_failure \
      "subscription_auth_unavailable" \
      "Claude Code is authenticated through Anthropic Console or another non-subscription provider. This bridge requires Claude subscription auth." \
      "Run claude auth login --claudeai in the same environment Codex uses, then retry."
    return 1
  fi

  probe_args=(
    -p \
    'Codex Claude skill preflight probe. Return {"ok": true} and nothing else.' \
    --safe-mode
    --output-format
    json
    --json-schema
    "$probe_schema"
    --tools
    ""
    --strict-mcp-config
    --setting-sources
    local
    --disable-slash-commands
    --no-session-persistence
    --permission-mode
    dontAsk
    --effort
    low
    --max-budget-usd
    "$LIVE_PROBE_BUDGET_USD"
  )
  if [ -n "$LIVE_PROBE_MODEL" ]; then
    probe_args+=(
      --model
      "$LIVE_PROBE_MODEL"
    )
  fi

  set +e
  probe_output="$(run_candidate_claude_with_timeout "$probe_timeout_seconds" "$claude_bin" "${probe_args[@]}" 2>&1)"
  probe_status=$?
  set -e

  if [ "$probe_status" -eq 0 ]; then
    if result_is_error "$probe_output"; then
      if budget_exhausted_output "$probe_output"; then
        record_failure \
          "probe_budget_too_low" \
          "Claude subscription preflight hit the CLI budget cap before it could return." \
          "Increase LIVE_PROBE_BUDGET_USD or retry after the Claude model cache is warm."
      elif claude_state_write_denied_output "$probe_output"; then
        record_claude_state_write_denied_failure "$probe_output"
      elif logged_out_state "$auth_status" || auth_unavailable_output "$probe_output"; then
        record_failure \
          "subscription_auth_unavailable" \
          "Claude Code was found, but Claude subscription auth is unavailable from the shell context this skill uses." \
          "Run claude auth login --claudeai in the same environment Codex uses, then retry."
      else
        record_failure \
          "ambiguous_auth" \
          "Claude Code was found, but a subscription-only preflight failed before review could run." \
          "Check PATH and the Claude subscription session visible to Codex, then retry."
      fi
      return 1
    fi

    if live_probe_ok "$probe_output"; then
      select_runner "$claude_bin" "$description" "live_probe"
      return 0
    fi

    record_failure \
      "ambiguous_auth" \
      "Claude Code was found, but the subscription-only preflight returned an unexpected result." \
      "Check the installed Claude CLI and retry from the same environment Codex uses."
    return 1
  fi

  if budget_exhausted_output "$probe_output"; then
    record_failure \
      "probe_budget_too_low" \
      "Claude subscription preflight hit the CLI budget cap before it could return." \
      "Increase LIVE_PROBE_BUDGET_USD or retry after the Claude model cache is warm."
  elif claude_state_write_denied_output "$probe_output"; then
    record_claude_state_write_denied_failure "$probe_output"
  elif logged_out_state "$auth_status" || auth_unavailable_output "$probe_output"; then
    record_failure \
      "subscription_auth_unavailable" \
      "Claude Code was found, but Claude subscription auth is unavailable from the shell context this skill uses." \
      "Run claude auth login --claudeai in the same environment Codex uses, then retry."
  elif [ "$probe_status" -eq 124 ]; then
    record_failure \
      "probe_timed_out" \
      "Claude subscription preflight timed out after ${probe_timeout_seconds}s before it could return." \
      "The review was not started. Check Claude Code startup hooks, MCP/config loading, and user/global settings, or retry after increasing LIVE_PROBE_TIMEOUT_SECONDS."
  else
    record_failure \
      "ambiguous_auth" \
      "Claude Code was found, but a subscription-only preflight failed before review could run." \
      "Check PATH and the Claude subscription session visible to Codex, then retry."
  fi

  return 1
}

record_invalid_claude_candidate() {
  local source="$1"
  local launch_path="$2"
  local scope="$3"
  local status="$4"

  case "$status" in
    not_executable)
      record_failure \
        "unusable_runner" \
        "Claude Code was found, but the selected launcher target is not executable." \
        "Fix or reinstall the Claude launcher at $launch_path, then retry."
      ;;
    not_regular)
      record_failure \
        "unusable_runner" \
        "Claude Code was found, but the selected launcher target is not a regular file." \
        "Remove the conflicting entry at $launch_path and reinstall Claude Code, then retry."
      ;;
    dangling_symlink)
      record_failure \
        "unusable_runner" \
        "Claude Code was found, but the selected launcher is a dangling symlink." \
        "Remove or reinstall the stale Claude launcher at $launch_path, then retry."
      ;;
    *)
      record_failure \
        "unusable_runner" \
        "Claude Code was found at an unsafe path for unsandboxed execution." \
        "Rejecting the $source Claude candidate at $launch_path ($scope:$status). Ensure the real Claude CLI is in a trusted, non-world-writable location outside the repo, invocation directory, and temp directories."
      ;;
  esac
}

checked_claude_locations() {
  local locations="PATH"
  local homebrew_path=""

  if claude_locator_native_supported "${OSTYPE:-}"; then
    case "${HOME:-}" in
      /*)
        locations="$locations, $HOME/.local/bin/claude"
        ;;
    esac
  fi
  claude_locator_homebrew_paths "${OSTYPE:-}" "${MACHTYPE:-}"
  for homebrew_path in "${CLAUDE_LOCATOR_HOMEBREW_PATHS[@]}"; do
    locations="$locations, $homebrew_path"
  done
  printf '%s' "$locations"
}

try_selected_candidate() {
  local raw_path="$1"
  local source="$2"
  local description=""

  CLAUDE_FOUND_ANY="true"
  CLAUDE_DISCOVERY_SOURCE="$source"
  if ! claude_locator_validate_candidate "$raw_path" "$REPO_ROOT" "$CLAUDE_INVOCATION_CWD"; then
    record_invalid_claude_candidate \
      "$source" \
      "${CLAUDE_LOCATOR_LAUNCH_PATH:-$raw_path}" \
      "${CLAUDE_LOCATOR_VALIDATION_SCOPE:-launch}" \
      "${CLAUDE_LOCATOR_VALIDATION_STATUS:-missing}"
    return 1
  fi

  CLAUDE_BIN="$CLAUDE_LOCATOR_LAUNCH_PATH"
  CLAUDE_TARGET="$CLAUDE_LOCATOR_CANONICAL_TARGET"
  case "$source" in
    path)
      description="inherited PATH install"
      ;;
    native_user)
      description="official native user install"
      ;;
    homebrew_default)
      description="default Homebrew install"
      ;;
    *)
      description="Claude install"
      ;;
  esac
  probe_runner_usability "$CLAUDE_BIN" "$description"
}

resolve_claude_runner() {
  if claude_locator_path_candidate "$CLAUDE_INVOCATION_CWD"; then
    try_selected_candidate "$CLAUDE_LOCATOR_CANDIDATE_PATH" "path" && return 0
  elif claude_locator_first_present_fallback; then
    try_selected_candidate "$CLAUDE_LOCATOR_CANDIDATE_PATH" "$CLAUDE_LOCATOR_CANDIDATE_SOURCE" && return 0
  fi

  if [ "$CLAUDE_FOUND_ANY" != "true" ]; then
    record_failure \
      "missing_binary" \
      "Claude Code CLI was not found in PATH or any checked official/default install location." \
      "Checked $(checked_claude_locations). This does not prove Claude is uninstalled; custom Homebrew/npm prefixes remain PATH-only. Install the recommended native Claude or expose an existing launcher to Codex's inherited PATH, then retry."
  elif [ -z "$CLAUDE_FAILURE_CODE" ]; then
    record_failure \
      "ambiguous_auth" \
      "Claude Code was found, but no usable subscription-authenticated Claude runner could be selected." \
      "Check the selected Claude installation and the subscription session visible to Codex, then retry."
  fi

  return 1
}

classify_runtime_failure() {
  local exit_code="${1:-0}"
  local output="${2:-}"
  local configured_model="${MODEL:-default}"
  local configured_timeout="${REVIEW_TIMEOUT_SECONDS:-unknown}"
  local effective_timeout="${REVIEW_EFFECTIVE_TIMEOUT_SECONDS:-${REVIEW_TIMEOUT_SECONDS:-unknown}}"
  local timeout_attempts="${REVIEW_TIMEOUT_ATTEMPTS:-1}"
  local timeout_attempt_seconds="${REVIEW_TIMEOUT_ATTEMPT_SECONDS:-${effective_timeout}s}"

  if [ "${exit_code:-0}" -eq 124 ]; then
    record_failure \
      "review_timed_out" \
      "Claude review timed out after ${timeout_attempts} attempt(s) (${timeout_attempt_seconds}) before it could return a result." \
      "The configured timeout is ${configured_timeout}s; the effective timeout was ${effective_timeout}s based on artifact size, model=${configured_model}, and effort=${EFFORT}. Retry with a narrower scope or increase the timeout with `/claude-review set timeout <seconds>`."
    return
  fi

  if budget_exhausted_output "$output"; then
    record_failure \
      "review_budget_too_low" \
      "Claude review hit the configured budget cap ($${MAX_BUDGET_USD}) before it could return a result." \
      "Retry with a smaller artifact (current artifact=${artifact_bytes:-unknown} bytes), a cheaper model/effort pair, or increase the budget with `/claude-review set budget <usd>`."
    return
  fi

  if claude_state_write_denied_output "$output"; then
    record_claude_state_write_denied_failure "$output"
    return
  fi

  if auth_unavailable_output "$output"; then
    record_failure \
      "subscription_auth_unavailable" \
      "Claude review could not use Claude subscription auth from this environment." \
      "Run claude auth login --claudeai in the same environment Codex uses, then retry."
    return
  fi

  if printf '%s\n' "$output" | grep -Eqi 'api key|anthropic_api_key'; then
    record_failure \
      "invocation_failed" \
      "Claude review attempted an API-key-style auth path, but this bridge only supports Claude subscription auth." \
      "Remove Anthropic API credential env vars from the Codex environment and run claude auth login --claudeai, then retry."
    return
  fi

  record_failure \
    "invocation_failed" \
    "Claude Code invocation failed before a review result was returned." \
    "Inspect the Claude CLI output, shell PATH, and the Claude subscription session visible to Codex, then retry."
}

validate_readable_inputs
claude_config_load_file "$CONFIG_FILE"

if [ ! -s "$ARTIFACT_FILE" ]; then
  emit_json "needs_context" "The review artifact is empty." "Provide a plan, diff, or PR artifact and retry."
  exit 0
fi

artifact_bytes="$(wc -c < "$ARTIFACT_FILE" | tr -d '[:space:]')"
if [ "${artifact_bytes:-0}" -gt "$MAX_ARTIFACT_BYTES" ]; then
  if artifact_is_split_part; then
    emit_json "needs_context" "The split review artifact is too large for this runner cap (${artifact_bytes} bytes > ${MAX_ARTIFACT_BYTES} bytes), likely because it was built with a higher CLAUDE_REVIEW_MAX_ARTIFACT_BYTES than the review step." "Export the same CLAUDE_REVIEW_MAX_ARTIFACT_BYTES for build-review-artifact.sh and every run-review.sh split-part call, or rebuild with a lower cap."
  else
    emit_json "needs_context" "The review artifact is too large for one review pass (${artifact_bytes} bytes > ${MAX_ARTIFACT_BYTES} bytes)." "Split code or PR artifacts with build-review-artifact.sh --split-output-dir, or narrow the plan scope."
  fi
  exit 0
fi

REVIEW_EFFECTIVE_TIMEOUT_SECONDS="$(calculate_review_timeout_seconds "$REVIEW_TIMEOUT_SECONDS" "$artifact_bytes")"
REVIEW_RETRY_TIMEOUT_SECONDS="$(calculate_review_retry_timeout_seconds "$REVIEW_EFFECTIVE_TIMEOUT_SECONDS")"

if ! resolve_claude_runner; then
  emit_json "blocked" "$CLAUDE_FAILURE_SUMMARY" "$CLAUDE_FAILURE_QUESTION"
  exit 0
fi

system_prompt="$(cat "$BASE_PROMPT")"

if [ "${#APPEND_PROMPTS[@]}" -gt 0 ]; then
  for append_prompt in "${APPEND_PROMPTS[@]}"; do
    if [ -n "$append_prompt" ] && [ -f "$append_prompt" ] && [ -s "$append_prompt" ]; then
      system_prompt="${system_prompt}

Additional review instructions from ${append_prompt}:

$(cat "$append_prompt")"
    fi
  done
fi

artifact_body="$(cat "$ARTIFACT_FILE")"
schema_json="$(tr -d '\n' < "$SCHEMA_FILE")"

prompt_sections=()
prompt_sections+=("Review the provided artifact and return JSON matching the supplied schema.")
prompt_sections+=("")
prompt_sections+=("Mode: $MODE")
[ -n "$REPO_ROOT" ] && prompt_sections+=("Repo root: $REPO_ROOT")
[ -n "$BRANCH" ] && prompt_sections+=("Branch: $BRANCH")
[ -n "$BASE_BRANCH" ] && prompt_sections+=("Base branch: $BASE_BRANCH")
[ -n "$PR_NUMBER" ] && prompt_sections+=("PR number: $PR_NUMBER")
[ -n "$REVIEW_INSTRUCTIONS" ] && prompt_sections+=("Extra review instructions: $REVIEW_INSTRUCTIONS")
prompt_sections+=("")
prompt_sections+=("Artifact:")
prompt_sections+=('```text')
prompt_sections+=("$artifact_body")
prompt_sections+=('```')

user_prompt="$(printf '%s\n' "${prompt_sections[@]}")"

cmd_args=(
  -p
  "$user_prompt"
  --safe-mode
  --output-format
  json
  --json-schema
  "$schema_json"
  --tools
  ""
  --strict-mcp-config
  --setting-sources
  local
  --disable-slash-commands
  --no-session-persistence
  --permission-mode
  dontAsk
  --effort
  "$EFFORT"
  --max-budget-usd
  "$MAX_BUDGET_USD"
  --append-system-prompt
  "$system_prompt"
)

if [ -n "$MODEL" ]; then
  cmd_args+=(
    --model
    "$MODEL"
  )
fi

REVIEW_TIMEOUT_ATTEMPTS="1"
REVIEW_TIMEOUT_ATTEMPT_SECONDS="${REVIEW_EFFECTIVE_TIMEOUT_SECONDS}s"

set +e
output="$(run_selected_claude_with_timeout "$REVIEW_EFFECTIVE_TIMEOUT_SECONDS" "${cmd_args[@]}" 2>&1)"
run_status=$?
set -e

if [ "$run_status" -eq 124 ] && [ "$REVIEW_RETRY_TIMEOUT_SECONDS" -gt "$REVIEW_EFFECTIVE_TIMEOUT_SECONDS" ]; then
  REVIEW_TIMEOUT_ATTEMPTS="2"
  REVIEW_TIMEOUT_ATTEMPT_SECONDS="${REVIEW_EFFECTIVE_TIMEOUT_SECONDS}s, ${REVIEW_RETRY_TIMEOUT_SECONDS}s"

  set +e
  output="$(run_selected_claude_with_timeout "$REVIEW_RETRY_TIMEOUT_SECONDS" "${cmd_args[@]}" 2>&1)"
  run_status=$?
  set -e
fi

if [ "$run_status" -ne 0 ]; then
  printf '%s\n' "$output" >&2
  classify_runtime_failure "$run_status" "$output"
  emit_json "blocked" "$CLAUDE_FAILURE_SUMMARY" "$CLAUDE_FAILURE_QUESTION"
  exit 0
fi

if result_is_error "$output"; then
  printf '%s\n' "$output" >&2
  classify_runtime_failure 0 "$output"
  emit_json "blocked" "$CLAUDE_FAILURE_SUMMARY" "$CLAUDE_FAILURE_QUESTION"
  exit 0
fi

if ! stamped_output="$(stamp_review_output_mode "$output")"; then
  emit_json \
    "blocked" \
    "Claude review returned output, but the runner could not safely stamp the requested mode." \
    "Install jq or python3, or retry after ensuring Claude returns valid structured JSON."
  exit 0
fi

printf '%s\n' "$stamped_output"
