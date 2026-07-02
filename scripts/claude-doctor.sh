#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$PWD"
CONFIG_FILE=""
PROBE_TIMEOUT_SECONDS="${CLAUDE_DOCTOR_PROBE_TIMEOUT_SECONDS:-12}"
SKIP_PROBES="false"
SKIP_UPDATE_CHECK="${CLAUDE_DOCTOR_SKIP_UPDATE_CHECK:-false}"
SUBSCRIPTION_HELPER="$SCRIPT_DIR/claude-subscription-env.sh"
CONFIG_HELPER="$SCRIPT_DIR/claude-config.sh"

usage() {
  cat <<'EOF'
Usage:
  claude-doctor.sh [--repo-root <path>] [--skill-root <path>] [--config-file <path>] [--probe-timeout <seconds>] [--skip-probes] [--skip-update-check]

Diagnoses the installed /claude-review bridge. It prints paths, git state,
runner/router hardening checks, effective config, and bounded Claude CLI probes.
EOF
}

normalize_path() {
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
    --repo-root)
      REPO_ROOT="$(normalize_path "${2:-}")"
      shift 2
      ;;
    --skill-root)
      SKILL_ROOT="$(normalize_path "${2:-}")"
      SCRIPT_DIR="$SKILL_ROOT/scripts"
      SUBSCRIPTION_HELPER="$SCRIPT_DIR/claude-subscription-env.sh"
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

flag_state() {
  local file="$1"
  local pattern="$2"

  if [ -f "$file" ] && grep -q -- "$pattern" "$file"; then
    printf 'ok'
  else
    printf 'missing'
  fi
}

redacted_env_state() {
  local name="$1"
  if [ -n "${!name:-}" ]; then
    printf 'set'
  else
    printf 'unset'
  fi
}

run_probe() {
  local label="$1"
  shift

  if ! command -v python3 >/dev/null 2>&1; then
    print_kv "${label}_status" "skipped_no_python3"
    return 0
  fi

  python3 - "$label" "$PROBE_TIMEOUT_SECONDS" "$@" <<'PY'
import os
import signal
import subprocess
import sys
import time

label = sys.argv[1]
timeout = int(sys.argv[2])
cmd = sys.argv[3:]

started = time.time()
try:
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
except OSError as exc:
    print(f"{label}_status=spawn_failed")
    print(f"{label}_error={type(exc).__name__}: {exc}")
    sys.exit(0)

try:
    out, err = proc.communicate("OK\n", timeout=timeout)
    status = "completed"
except subprocess.TimeoutExpired:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        out, err = proc.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        out, err = proc.communicate()
    status = "timeout"

elapsed = time.time() - started
print(f"{label}_status={status}")
print(f"{label}_returncode={proc.returncode}")
print(f"{label}_elapsed_seconds={elapsed:.2f}")
print(f"{label}_stdout_bytes={len(out or '')}")
print(f"{label}_stderr_bytes={len(err or '')}")
if out:
    head = (out or "")[:240].replace("\n", "\\n")
    print(f"{label}_stdout_head={head}")
if err:
    head = (err or "")[:240].replace("\n", "\\n")
    print(f"{label}_stderr_head={head}")
PY
}

printf 'CLAUDE_REVIEW_DOCTOR\n'
print_kv "repo_root" "$REPO_ROOT"
print_kv "skill_root" "$SKILL_ROOT"
print_kv "config_file" "$CONFIG_FILE"
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

print_kv "ANTHROPIC_API_KEY" "$(redacted_env_state ANTHROPIC_API_KEY)"
print_kv "ANTHROPIC_AUTH_TOKEN" "$(redacted_env_state ANTHROPIC_AUTH_TOKEN)"
print_kv "ANTHROPIC_BEARER_TOKEN" "$(redacted_env_state ANTHROPIC_BEARER_TOKEN)"
print_kv "CLAUDE_CONFIG_DIR" "${CLAUDE_CONFIG_DIR:-}"

claude_bin="$(command -v claude 2>/dev/null || true)"
if [ -z "$claude_bin" ]; then
  print_kv "claude_bin" "missing"
  exit 0
fi

print_kv "claude_bin" "$claude_bin"
print_kv "claude_version" "$("$claude_bin" --version 2>/dev/null || "$claude_bin" -v 2>/dev/null || printf 'unknown')"
auth_status="$("$claude_bin" auth status 2>/dev/null || true)"
if [ -n "$auth_status" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    print_kv "claude_auth_status" "present_unparsed"
  else
    AUTH_STATUS="$auth_status" python3 - <<'PY' || true
import json
import os

raw = os.environ.get("AUTH_STATUS", "")
try:
    data = json.loads(raw)
except Exception:
    print("claude_auth_status=present_unparsed")
else:
    print(f"claude_auth_logged_in={data.get('loggedIn', 'unknown')}")
    print(f"claude_auth_provider={data.get('apiProvider', 'unknown')}")
PY
  fi
else
  print_kv "claude_auth_status" "empty"
fi

if [ "$SKIP_PROBES" = "true" ]; then
  print_kv "probes" "skipped"
  exit 0
fi

print_kv "probe_timeout_seconds" "$PROBE_TIMEOUT_SECONDS"

run_probe \
  "plain_print_probe" \
  "$SUBSCRIPTION_HELPER" "$claude_bin" \
  -p \
  "Return OK only." \
  --output-format json \
  --disable-slash-commands

run_probe \
  "safe_mode_print_probe" \
  "$SUBSCRIPTION_HELPER" "$claude_bin" \
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
