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

EFFORT="high"
MODEL=""
MAX_BUDGET_USD="2.00"

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

get_auth_status() {
  local status=""

  if command -v zsh >/dev/null 2>&1; then
    status="$(zsh -lc 'claude auth status' 2>/dev/null || true)"
  fi

  if [ -z "$status" ]; then
    status="$(claude auth status 2>/dev/null || true)"
  fi

  printf '%s' "$status"
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

emit_json() {
  local status="$1"
  local summary="$2"
  local question="$3"

  printf '{\n'
  printf '  "status": "%s",\n' "$status"
  printf '  "mode": "%s",\n' "$MODE"
  printf '  "summary": "%s",\n' "$summary"
  printf '  "findings": [],\n'
  if [ -n "$question" ]; then
    printf '  "open_questions": ["%s"]\n' "$question"
  else
    printf '  "open_questions": []\n'
  fi
  printf '}\n'
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

auth_status="$(get_auth_status)"
auth_logged_in="false"

if [ -n "$auth_status" ]; then
  if command -v jq >/dev/null 2>&1; then
    if printf '%s\n' "$auth_status" | jq -e '.loggedIn == true' >/dev/null 2>&1; then
      auth_logged_in="true"
    fi
  elif printf '%s\n' "$auth_status" | grep -q '"loggedIn":[[:space:]]*true'; then
    auth_logged_in="true"
  fi
fi

if [ "$auth_logged_in" != "true" ]; then
  emit_json "blocked" "Claude Code is not logged in on this machine." "Run claude auth login or claude setup-token, then retry."
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

cmd=(
  claude
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
  cmd+=(
    --model
    "$MODEL"
  )
fi

if ! output="$("${cmd[@]}" 2>&1)"; then
  printf '%s\n' "$output" >&2
  if printf '%s\n' "$output" | grep -qi 'not logged in'; then
    emit_json "blocked" "Claude Code is not logged in on this machine." "Run claude auth login or claude setup-token, then retry."
  else
    emit_json "blocked" "Claude Code invocation failed before a review result was returned." "Inspect the command output and retry."
  fi
  exit 0
fi

printf '%s\n' "$output"
