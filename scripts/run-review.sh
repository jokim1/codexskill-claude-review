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
MAX_ARTIFACT_BYTES=60000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_HELPER="$SCRIPT_DIR/claude-config.sh"
CLAUDE_SUBSCRIPTION_HELPER="$SCRIPT_DIR/claude-subscription-env.sh"
# shellcheck source=/dev/null
source "$CONFIG_HELPER"

LIVE_PROBE_BUDGET_USD="$CLAUDE_CONFIG_DEFAULT_LIVE_PROBE_BUDGET_USD"
LIVE_PROBE_MODEL="$CLAUDE_CONFIG_DEFAULT_LIVE_PROBE_MODEL"
EFFORT="$CLAUDE_CONFIG_DEFAULT_EFFORT"
MODEL="$CLAUDE_CONFIG_DEFAULT_MODEL"
MAX_BUDGET_USD="$CLAUDE_CONFIG_DEFAULT_MAX_BUDGET_USD"
REVIEW_TIMEOUT_SECONDS="$CLAUDE_CONFIG_DEFAULT_REVIEW_TIMEOUT_SECONDS"
CLAUDE_RUNTIME_CWD="$(mktemp -d /tmp/claude-review-runtime-XXXXXX)"
trap 'rm -rf "$CLAUDE_RUNTIME_CWD"' EXIT

CLAUDE_RUNNER_KIND=""
CLAUDE_RUNNER_SHELL=""
CLAUDE_BIN=""
CLAUDE_RUNNER_DESC=""
CLAUDE_PRECHECK_MODE=""

CLAUDE_FAILURE_CODE=""
CLAUDE_FAILURE_SUMMARY=""
CLAUDE_FAILURE_QUESTION=""
CLAUDE_FOUND_ANY="false"
TRIED_CANDIDATE_KEYS="|"
SELECTED_CLAUDE_CMD=()
REVIEW_EFFECTIVE_TIMEOUT_SECONDS=""
REVIEW_RETRY_TIMEOUT_SECONDS=""
REVIEW_TIMEOUT_ATTEMPTS="0"
REVIEW_TIMEOUT_ATTEMPT_SECONDS=""

usage() {
  cat <<'EOF'
Usage:
  run-review.sh --mode <plan|code|pr> --artifact-file <path> \
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

failure_priority() {
  case "${1:-}" in
    missing_binary)
      printf '1'
      ;;
    unusable_runner)
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
    review_budget_too_low)
      printf '6'
      ;;
    review_timed_out)
      printf '7'
      ;;
    invocation_failed)
      printf '8'
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

  if [ "$(failure_priority "$code")" -ge "$(failure_priority "$CLAUDE_FAILURE_CODE")" ]; then
    CLAUDE_FAILURE_CODE="$code"
    CLAUDE_FAILURE_SUMMARY="$summary"
    CLAUDE_FAILURE_QUESTION="$question"
  fi
}

resolve_shell_bin() {
  local candidate="$1"
  local resolved=""

  [ -n "$candidate" ] || return 1

  if [ -x "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi

  resolved="$(command -v "$candidate" 2>/dev/null || true)"
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

candidate_key_seen() {
  local key="$1"
  case "$TRIED_CANDIDATE_KEYS" in
    *"|$key|"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

mark_candidate_key() {
  local key="$1"
  TRIED_CANDIDATE_KEYS="${TRIED_CANDIDATE_KEYS}${key}|"
}

build_candidate_claude_cmd() {
  local kind="$1"
  local shell_bin="$2"
  local claude_bin="$3"
  local runner_shell="bash"
  shift 3

  if [ "$kind" = "shell" ]; then
    runner_shell="$shell_bin"
  fi

  SELECTED_CLAUDE_CMD=()
  SELECTED_CLAUDE_CMD=(
    "$runner_shell"
    -lc
    'cd "$1" && shift && exec "$@"'
    bash
    "$CLAUDE_RUNTIME_CWD"
    bash
    "$CLAUDE_SUBSCRIPTION_HELPER"
    "$claude_bin"
  )

  while [ "$#" -gt 0 ]; do
    SELECTED_CLAUDE_CMD+=("$1")
    shift
  done
}

run_candidate_claude() {
  local kind="$1"
  local shell_bin="$2"
  local claude_bin="$3"
  shift 3

  build_candidate_claude_cmd "$kind" "$shell_bin" "$claude_bin" "$@"
  "${SELECTED_CLAUDE_CMD[@]}"
}

run_selected_claude() {
  run_candidate_claude "$CLAUDE_RUNNER_KIND" "$CLAUDE_RUNNER_SHELL" "$CLAUDE_BIN" "$@"
}

run_selected_claude_with_timeout() {
  local timeout_seconds="$1"
  shift

  if [ -z "$timeout_seconds" ] || [ "${timeout_seconds:-0}" -le 0 ] || ! command -v python3 >/dev/null 2>&1; then
    run_selected_claude "$@"
    return
  fi

  build_candidate_claude_cmd "$CLAUDE_RUNNER_KIND" "$CLAUDE_RUNNER_SHELL" "$CLAUDE_BIN" "$@"

  python3 - "$timeout_seconds" "${SELECTED_CLAUDE_CMD[@]}" <<'PY'
import subprocess
import sys

timeout = int(sys.argv[1])
cmd = sys.argv[2:]

try:
    completed = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
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

extract_structured_output() {
  local output="$1"

  if [ -z "$output" ]; then
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    if printf '%s\n' "$output" | jq -e '.structured_output != null' >/dev/null 2>&1; then
      printf '%s\n' "$output" | jq '.structured_output'
      return 0
    fi
  fi

  printf '%s\n' "$output"
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

select_runner() {
  CLAUDE_RUNNER_KIND="$1"
  CLAUDE_RUNNER_SHELL="$2"
  CLAUDE_BIN="$3"
  CLAUDE_RUNNER_DESC="$4"
  CLAUDE_PRECHECK_MODE="$5"
}

probe_runner_usability() {
  local kind="$1"
  local shell_bin="$2"
  local claude_bin="$3"
  local description="$4"
  local auth_status=""
  local probe_output=""
  local probe_schema='{"type":"object","properties":{"ok":{"const":true}},"required":["ok"],"additionalProperties":false}'
  local probe_args=()

  if ! run_candidate_claude "$kind" "$shell_bin" "$claude_bin" -v >/dev/null 2>&1; then
    record_failure \
      "unusable_runner" \
      "Claude Code was found but could not run from one of the shell contexts this skill tried." \
      "Check PATH, shell startup files, and Claude CLI permissions, then retry."
    return 1
  fi

  auth_status="$(run_candidate_claude "$kind" "$shell_bin" "$claude_bin" auth status 2>/dev/null || true)"
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

  if probe_output="$(run_candidate_claude "$kind" "$shell_bin" "$claude_bin" "${probe_args[@]}" 2>&1)"; then
    if result_is_error "$probe_output"; then
      if budget_exhausted_output "$probe_output"; then
        record_failure \
          "probe_budget_too_low" \
          "Claude subscription preflight hit the CLI budget cap before it could return." \
          "Increase LIVE_PROBE_BUDGET_USD or retry after the Claude model cache is warm."
      elif logged_out_state "$auth_status" || auth_unavailable_output "$probe_output"; then
        record_failure \
          "subscription_auth_unavailable" \
          "Claude Code was found, but Claude subscription auth is unavailable from the shell context this skill uses." \
          "Run claude auth login --claudeai in the same environment Codex uses, then retry."
      else
        record_failure \
          "ambiguous_auth" \
          "Claude Code was found, but a subscription-only preflight failed before review could run." \
          "Check shell startup files, PATH, and the Claude subscription session visible to Codex, then retry."
      fi
      return 1
    fi

    if live_probe_ok "$probe_output"; then
      select_runner "$kind" "$shell_bin" "$claude_bin" "$description" "live_probe"
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
  elif logged_out_state "$auth_status" || auth_unavailable_output "$probe_output"; then
    record_failure \
      "subscription_auth_unavailable" \
      "Claude Code was found, but Claude subscription auth is unavailable from the shell context this skill uses." \
      "Run claude auth login --claudeai in the same environment Codex uses, then retry."
  else
    record_failure \
      "ambiguous_auth" \
      "Claude Code was found, but a subscription-only preflight failed before review could run." \
      "Check shell startup files, PATH, and the Claude subscription session visible to Codex, then retry."
  fi

  return 1
}

try_direct_candidate() {
  local claude_path=""
  local candidate_key=""

  claude_path="$(command -v claude 2>/dev/null || true)"
  [ -n "$claude_path" ] || return 1

  candidate_key="direct::$claude_path"
  candidate_key_seen "$candidate_key" && return 1
  mark_candidate_key "$candidate_key"

  CLAUDE_FOUND_ANY="true"
  probe_runner_usability "direct" "" "$claude_path" "current shell"
}

try_shell_candidate() {
  local shell_ref="$1"
  local description="$2"
  local shell_bin=""
  local claude_path=""
  local candidate_key=""

  shell_bin="$(resolve_shell_bin "$shell_ref" 2>/dev/null || true)"
  [ -n "$shell_bin" ] || return 1

  claude_path="$("$shell_bin" -lc 'command -v claude' 2>/dev/null | head -n 1 | tr -d '\r')"
  [ -n "$claude_path" ] || return 1

  candidate_key="shell::$shell_bin::$claude_path"
  candidate_key_seen "$candidate_key" && return 1
  mark_candidate_key "$candidate_key"

  CLAUDE_FOUND_ANY="true"
  probe_runner_usability "shell" "$shell_bin" "$claude_path" "$description"
}

resolve_claude_runner() {
  try_direct_candidate && return 0

  if [ -n "${SHELL:-}" ]; then
    try_shell_candidate "$SHELL" "\$SHELL login shell" && return 0
  fi

  try_shell_candidate "zsh" "zsh login shell" && return 0
  try_shell_candidate "bash" "bash login shell" && return 0

  if [ "$CLAUDE_FOUND_ANY" != "true" ]; then
    record_failure \
      "missing_binary" \
      "Claude Code CLI was not found from this Codex environment." \
      "Install Claude Code and ensure claude is on PATH for Codex, then retry."
  elif [ -z "$CLAUDE_FAILURE_CODE" ]; then
    record_failure \
      "ambiguous_auth" \
      "Claude Code was found, but no usable subscription-authenticated Claude runner could be selected." \
      "Check shell startup files, PATH, and the Claude subscription session visible to Codex, then retry."
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
      "The configured timeout is ${configured_timeout}s; the effective timeout was ${effective_timeout}s based on artifact size, model=${configured_model}, and effort=${EFFORT}. Retry with a narrower scope or increase the timeout with `/claude set timeout <seconds>`."
    return
  fi

  if budget_exhausted_output "$output"; then
    record_failure \
      "review_budget_too_low" \
      "Claude review hit the configured budget cap ($${MAX_BUDGET_USD}) before it could return a result." \
      "Retry with a smaller artifact (current artifact=${artifact_bytes:-unknown} bytes), a cheaper model/effort pair, or increase the budget with `/claude set budget <usd>`."
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

claude_config_load_file "$CONFIG_FILE"

if [ ! -s "$ARTIFACT_FILE" ]; then
  emit_json "needs_context" "The review artifact is empty." "Provide a plan, diff, or PR artifact and retry."
  exit 0
fi

artifact_bytes="$(wc -c < "$ARTIFACT_FILE" | tr -d '[:space:]')"
if [ "${artifact_bytes:-0}" -gt "$MAX_ARTIFACT_BYTES" ]; then
  emit_json "needs_context" "The review artifact is too large for a reliable single-shot review (${artifact_bytes} bytes > ${MAX_ARTIFACT_BYTES} bytes)." "Narrow the scope or use /claude review pr <number>."
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

extract_structured_output "$output"
