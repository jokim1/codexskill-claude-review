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
MAX_ARTIFACT_BYTES=120000
LIVE_PROBE_BUDGET_USD="0.05"

EFFORT="high"
MODEL=""
MAX_BUDGET_USD="2.00"

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

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

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

load_config() {
  local file="$1"
  local line key value

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim "$line")"
    case "$line" in
      ''|\#*)
        continue
        ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"
    key="$(trim "$key")"
    value="$(trim "$value")"

    case "$key" in
      EFFORT)
        EFFORT="$value"
        ;;
      MODEL)
        MODEL="$value"
        ;;
      MAX_BUDGET_USD)
        MAX_BUDGET_USD="$value"
        ;;
    esac
  done < "$file"
}

failure_priority() {
  case "${1:-}" in
    missing_binary)
      printf '1'
      ;;
    unusable_runner)
      printf '2'
      ;;
    auth_unavailable)
      printf '3'
      ;;
    ambiguous_auth)
      printf '4'
      ;;
    invocation_failed)
      printf '5'
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

run_candidate_claude() {
  local kind="$1"
  local shell_bin="$2"
  local claude_bin="$3"
  shift 3

  if [ "$kind" = "direct" ]; then
    "$claude_bin" "$@"
    return
  fi

  "$shell_bin" -lc 'exec "$0" "$@"' "$claude_bin" "$@"
}

run_selected_claude() {
  run_candidate_claude "$CLAUDE_RUNNER_KIND" "$CLAUDE_RUNNER_SHELL" "$CLAUDE_BIN" "$@"
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

live_probe_ok() {
  local output="$1"

  [ -n "$output" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    if printf '%s\n' "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  printf '%s\n' "$output" | grep -q '"ok":[[:space:]]*true'
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

  if ! run_candidate_claude "$kind" "$shell_bin" "$claude_bin" -v >/dev/null 2>&1; then
    record_failure \
      "unusable_runner" \
      "Claude Code was found but could not run from one of the shell contexts this skill tried." \
      "Check PATH, shell startup files, and Claude CLI permissions, then retry."
    return 1
  fi

  auth_status="$(run_candidate_claude "$kind" "$shell_bin" "$claude_bin" auth status 2>/dev/null || true)"
  if logged_in_state "$auth_status"; then
    select_runner "$kind" "$shell_bin" "$claude_bin" "$description" "auth_status"
    return 0
  fi

  if probe_output="$(run_candidate_claude \
    "$kind" \
    "$shell_bin" \
    "$claude_bin" \
    -p \
    'Codex Claude skill preflight probe. Return {"ok": true} and nothing else.' \
    --output-format \
    json \
    --json-schema \
    "$probe_schema" \
    --tools \
    "" \
    --strict-mcp-config \
    --effort \
    low \
    --max-budget-usd \
    "$LIVE_PROBE_BUDGET_USD" 2>&1)"; then
    if live_probe_ok "$probe_output"; then
      select_runner "$kind" "$shell_bin" "$claude_bin" "$description" "live_probe"
      return 0
    fi

    record_failure \
      "ambiguous_auth" \
      "Claude Code was found, but a tiny preflight call returned an unexpected result." \
      "If Claude works in another terminal, restart Codex so it inherits the same shell environment, then retry."
    return 1
  fi

  if logged_out_state "$auth_status" || printf '%s\n' "$probe_output" | grep -Eqi 'not logged in|auth login|setup-token|authentication|api key|anthropic_api_key'; then
    record_failure \
      "auth_unavailable" \
      "Claude Code was found, but authentication is unavailable from the shell context this skill uses." \
      "Run claude auth login in the same environment, or expose the right auth environment such as ANTHROPIC_API_KEY to Codex, then retry."
  else
    record_failure \
      "ambiguous_auth" \
      "Claude Code was found, but a tiny preflight call failed before review could run." \
      "Check shell and environment differences between Codex and your other terminals, then retry."
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
      "Claude Code was found, but no usable Claude runner could be selected." \
      "Check shell startup files, PATH, and authentication state for the environment Codex inherits, then retry."
  fi

  return 1
}

classify_runtime_failure() {
  local output="$1"

  if printf '%s\n' "$output" | grep -Eqi 'not logged in|auth login|setup-token|authentication|api key|anthropic_api_key'; then
    record_failure \
      "auth_unavailable" \
      "Claude Code became unavailable before a review result was returned." \
      "Refresh the auth available to Codex, then retry."
    return
  fi

  record_failure \
    "invocation_failed" \
    "Claude Code invocation failed before a review result was returned." \
    "Inspect the Claude CLI output, shell PATH, and environment inherited by Codex, then retry."
}

load_config "$CONFIG_FILE"

if [ ! -s "$ARTIFACT_FILE" ]; then
  emit_json "needs_context" "The review artifact is empty." "Provide a plan, diff, or PR artifact and retry."
  exit 0
fi

artifact_bytes="$(wc -c < "$ARTIFACT_FILE" | tr -d '[:space:]')"
if [ "${artifact_bytes:-0}" -gt "$MAX_ARTIFACT_BYTES" ]; then
  emit_json "needs_context" "The review artifact is too large for a reliable single-shot review." "Narrow the scope or use /claude review pr <number>."
  exit 0
fi

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

if ! output="$(run_selected_claude "${cmd_args[@]}" 2>&1)"; then
  printf '%s\n' "$output" >&2
  classify_runtime_failure "$output"
  emit_json "blocked" "$CLAUDE_FAILURE_SUMMARY" "$CLAUDE_FAILURE_QUESTION"
  exit 0
fi

printf '%s\n' "$output"
