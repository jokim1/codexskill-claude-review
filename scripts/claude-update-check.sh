#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${CLAUDE_UPDATE_SKILL_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE_DIR="${CLAUDE_UPDATE_STATE_DIR:-$HOME/.codex/claude}"
REMOTE_NAME="${CLAUDE_UPDATE_REMOTE_NAME:-origin}"
REMOTE_BRANCH="${CLAUDE_UPDATE_REMOTE_BRANCH:-main}"
NETWORK_TIMEOUT_SECONDS="${CLAUDE_UPDATE_CHECK_TIMEOUT_SECONDS:-5}"
SHOW_UP_TO_DATE="false"
FORCE="false"
SNOOZE_SHA=""

usage() {
  cat <<'EOF'
Usage:
  claude-update-check.sh [--force] [--show-up-to-date] [--skill-dir <path>] [--state-dir <path>]
  claude-update-check.sh --snooze <remote-sha-or-version> [--state-dir <path>]

Output:
  JUST_UPDATED <old> <new>
  UPDATE_AVAILABLE <old> <new> <new-full-sha>
  UPDATE_SUMMARY <one-line user-facing summary>
  UP_TO_DATE <current>        Only with --show-up-to-date
  SNOOZED <version> <duration>
EOF
}

short_sha() {
  local value="$1"
  if [ "${#value}" -gt 12 ]; then
    printf '%s' "${value:0:7}"
  else
    printf '%s' "$value"
  fi
}

sanitize_update_summary() {
  LC_ALL=C awk '
    {
      gsub(/[^[:print:]]/, "")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if (length($0) > 0) {
        summary = substr($0, 1, 240)
        sub(/[.!?]+$/, "", summary)
        print summary
        exit
      }
    }
  '
}

read_remote_update_summary() {
  local local_sha="$1"
  local remote_sha="$2"
  local summary=""

  summary="$(git -C "$SKILL_DIR" show "${remote_sha}:UPDATE_SUMMARY" 2>/dev/null | sanitize_update_summary || true)"
  if [ -z "$summary" ]; then
    summary="$(git -C "$SKILL_DIR" log --format=%s --no-merges "$local_sha..$remote_sha" 2>/dev/null | sanitize_update_summary || true)"
  fi
  if [ -z "$summary" ]; then
    summary="improvements and fixes are ready"
  fi
  printf '%s' "$summary"
}

read_cached_update_summary() {
  local remote_sha="$1"
  local cached="" cached_remote="" summary=""

  [ -f "$SUMMARY_CACHE_FILE" ] || return 0
  cached="$(cat "$SUMMARY_CACHE_FILE" 2>/dev/null || true)"
  cached_remote="${cached%% *}"
  [ "$cached_remote" = "$remote_sha" ] || return 0
  summary="${cached#"$cached_remote"}"
  summary="${summary# }"
  printf '%s' "$summary" | sanitize_update_summary
}

print_update_available() {
  local local_sha="$1"
  local remote_sha="$2"
  local summary="$3"

  printf 'UPDATE_AVAILABLE %s %s %s\n' "$(short_sha "$local_sha")" "$(short_sha "$remote_sha")" "$remote_sha"
  printf 'UPDATE_SUMMARY %s\n' "$summary"
}

is_git_repo() {
  git -C "$SKILL_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

current_sha() {
  git -C "$SKILL_DIR" rev-parse HEAD 2>/dev/null || true
}

remote_sha() {
  command -v python3 >/dev/null 2>&1 || return 0

  python3 - "$SKILL_DIR" "$REMOTE_NAME" "$REMOTE_BRANCH" "$NETWORK_TIMEOUT_SECONDS" <<'PY'
import os
import subprocess
import sys

skill_dir, remote_name, remote_branch, timeout_raw = sys.argv[1:5]
try:
    timeout = max(1, int(timeout_raw))
except ValueError:
    timeout = 5

env = os.environ.copy()
env["GIT_TERMINAL_PROMPT"] = "0"
ssh_command = env.get("GIT_SSH_COMMAND", "ssh")
if "BatchMode" not in ssh_command:
    ssh_command = f"{ssh_command} -o BatchMode=yes"
if "ConnectTimeout" not in ssh_command:
    ssh_command = f"{ssh_command} -o ConnectTimeout={timeout}"
env["GIT_SSH_COMMAND"] = ssh_command

try:
    completed = subprocess.run(
        ["git", "-C", skill_dir, "ls-remote", remote_name, f"refs/heads/{remote_branch}"],
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
        check=False,
    )
except (OSError, subprocess.TimeoutExpired):
    sys.exit(0)

if completed.returncode != 0:
    sys.exit(0)

expected_ref = f"refs/heads/{remote_branch}"
for line in completed.stdout.splitlines():
    parts = line.split()
    if len(parts) >= 2 and parts[1] == expected_ref:
        print(parts[0])
        break
PY
}

fetch_remote_ref() {
  command -v python3 >/dev/null 2>&1 || return 1

  python3 - "$SKILL_DIR" "$REMOTE_NAME" "$REMOTE_BRANCH" "$NETWORK_TIMEOUT_SECONDS" <<'PY'
import os
import subprocess
import sys

skill_dir, remote_name, remote_branch, timeout_raw = sys.argv[1:5]
try:
    timeout = max(1, int(timeout_raw))
except ValueError:
    timeout = 5

env = os.environ.copy()
env["GIT_TERMINAL_PROMPT"] = "0"
ssh_command = env.get("GIT_SSH_COMMAND", "ssh")
if "BatchMode" not in ssh_command:
    ssh_command = f"{ssh_command} -o BatchMode=yes"
if "ConnectTimeout" not in ssh_command:
    ssh_command = f"{ssh_command} -o ConnectTimeout={timeout}"
env["GIT_SSH_COMMAND"] = ssh_command

remote_ref = f"refs/remotes/{remote_name}/{remote_branch}"
try:
    completed = subprocess.run(
        ["git", "-c", "core.hooksPath=/dev/null", "-C", skill_dir, "fetch", "--quiet", "--no-tags", remote_name, f"+refs/heads/{remote_branch}:{remote_ref}"],
        timeout=timeout,
        env=env,
        check=False,
    )
except (OSError, subprocess.TimeoutExpired):
    sys.exit(1)

sys.exit(completed.returncode)
PY
}

atomic_write() {
  local file="$1"
  local content="$2"
  local dir="" tmp=""

  dir="$(dirname "$file")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.tmp.XXXXXX")" || return 1
  printf '%s\n' "$content" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$file"
}

cache_is_fresh() {
  local file="$1"
  local ttl_minutes="$2"

  [ -f "$file" ] || return 1
  [ "$ttl_minutes" -gt 0 ] || return 1
  [ -z "$(find "$file" -mmin +"$ttl_minutes" 2>/dev/null || true)" ]
}

check_snooze() {
  local remote="$1"
  local snooze_file="$STATE_DIR/update-snoozed"
  local snoozed_remote="" snoozed_level="" snoozed_epoch="" duration="" now="" expires=""

  [ -f "$snooze_file" ] || return 1

  snoozed_remote="$(awk '{print $1}' "$snooze_file" 2>/dev/null || true)"
  snoozed_level="$(awk '{print $2}' "$snooze_file" 2>/dev/null || true)"
  snoozed_epoch="$(awk '{print $3}' "$snooze_file" 2>/dev/null || true)"

  [ -n "$snoozed_remote" ] && [ -n "$snoozed_level" ] && [ -n "$snoozed_epoch" ] || return 1
  case "$snoozed_level" in *[!0-9]*) return 1 ;; esac
  case "$snoozed_epoch" in *[!0-9]*) return 1 ;; esac
  [ "$snoozed_remote" = "$remote" ] || return 1

  case "$snoozed_level" in
    1) duration=86400 ;;
    2) duration=172800 ;;
    *) duration=604800 ;;
  esac

  now="$(date +%s)"
  expires=$((snoozed_epoch + duration))
  [ "$now" -lt "$expires" ]
}

write_snooze() {
  local remote="$1"
  local snooze_file="$STATE_DIR/update-snoozed"
  local current_remote="" current_level="" new_level="" duration_label=""

  current_level=0
  if [ -f "$snooze_file" ]; then
    current_remote="$(awk '{print $1}' "$snooze_file" 2>/dev/null || true)"
    if [ "$current_remote" = "$remote" ]; then
      current_level="$(awk '{print $2}' "$snooze_file" 2>/dev/null || true)"
      case "$current_level" in *[!0-9]*) current_level=0 ;; esac
    fi
  fi

  new_level=$((current_level + 1))
  [ "$new_level" -gt 3 ] && new_level=3
  atomic_write "$snooze_file" "$remote $new_level $(date +%s)" || return 0

  case "$new_level" in
    1) duration_label="24h" ;;
    2) duration_label="48h" ;;
    *) duration_label="1w" ;;
  esac

  printf 'SNOOZED %s %s\n' "$(short_sha "$remote")" "$duration_label"
}

state_dir_ready() {
  local test_file=""

  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  [ -d "$STATE_DIR" ] || return 1
  test_file="$(mktemp "$STATE_DIR/.write-test.XXXXXX" 2>/dev/null)" || return 1
  printf 'ok\n' > "$test_file" 2>/dev/null || {
    rm -f "$test_file" 2>/dev/null || true
    return 1
  }
  rm -f "$test_file" 2>/dev/null || true
}

update_is_actionable() {
  local local_sha="$1"
  local remote_sha="$2"
  local current_branch_ref="" dirty_tracked="" remote_ref="" fetched_sha=""

  current_branch_ref="$(git -C "$SKILL_DIR" symbolic-ref -q HEAD 2>/dev/null || true)"
  [ "$current_branch_ref" = "refs/heads/$REMOTE_BRANCH" ] || return 1

  dirty_tracked="$(git -C "$SKILL_DIR" status --porcelain --untracked-files=no 2>/dev/null || true)"
  [ -z "$dirty_tracked" ] || return 1

  fetch_remote_ref || return 1
  remote_ref="refs/remotes/${REMOTE_NAME}/${REMOTE_BRANCH}"
  fetched_sha="$(git -C "$SKILL_DIR" rev-parse "$remote_ref" 2>/dev/null || true)"
  [ "$fetched_sha" = "$remote_sha" ] || return 1
  git -C "$SKILL_DIR" merge-base --is-ancestor "$local_sha" "$remote_ref" || return 1
  # Untracked or ignored collisions are still actionable: the explicit update
  # flow can preserve them with /claude-review update --backup-conflicts.
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE="true"
      shift
      ;;
    --show-up-to-date)
      SHOW_UP_TO_DATE="true"
      shift
      ;;
    --skill-dir)
      SKILL_DIR="${2:-}"
      shift 2
      ;;
    --state-dir)
      STATE_DIR="${2:-}"
      shift 2
      ;;
    --snooze)
      SNOOZE_SHA="${2:-}"
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

CACHE_FILE="$STATE_DIR/last-update-check"
SUMMARY_CACHE_FILE="$STATE_DIR/last-update-summary"
MARKER_FILE="$STATE_DIR/just-updated-from"
SNOOZE_FILE="$STATE_DIR/update-snoozed"

if ! state_dir_ready; then
  exit 0
fi

if [ -n "$SNOOZE_SHA" ]; then
  write_snooze "$SNOOZE_SHA"
  exit 0
fi

if [ "$FORCE" = "true" ]; then
  rm -f "$CACHE_FILE" "$SUMMARY_CACHE_FILE" "$SNOOZE_FILE" 2>/dev/null || true
fi

is_git_repo || exit 0

LOCAL_SHA="$(current_sha)"
case "$LOCAL_SHA" in
  [a-fA-F0-9][a-fA-F0-9]*)
    ;;
  *)
    exit 0
    ;;
esac

if [ -f "$MARKER_FILE" ]; then
  OLD_SHA="$(cat "$MARKER_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
  rm -f "$MARKER_FILE" "$SNOOZE_FILE" 2>/dev/null || true
  if [ -n "$OLD_SHA" ]; then
    printf 'JUST_UPDATED %s %s\n' "$(short_sha "$OLD_SHA")" "$(short_sha "$LOCAL_SHA")"
  fi
fi

if [ -f "$CACHE_FILE" ]; then
  CACHED="$(cat "$CACHE_FILE" 2>/dev/null || true)"
  case "$CACHED" in
    UP_TO_DATE*) CACHE_TTL=60 ;;
    UPDATE_AVAILABLE*) CACHE_TTL=720 ;;
    *) CACHE_TTL=0 ;;
  esac

  if cache_is_fresh "$CACHE_FILE" "$CACHE_TTL"; then
    CACHED_STATUS="$(printf '%s\n' "$CACHED" | awk '{print $1}')"
    CACHED_LOCAL="$(printf '%s\n' "$CACHED" | awk '{print $2}')"
    CACHED_REMOTE="$(printf '%s\n' "$CACHED" | awk '{print $3}')"

    if [ "$CACHED_STATUS" = "UP_TO_DATE" ] && [ "$CACHED_LOCAL" = "$LOCAL_SHA" ]; then
      if [ "$SHOW_UP_TO_DATE" = "true" ]; then
        printf 'UP_TO_DATE %s\n' "$(short_sha "$LOCAL_SHA")"
      fi
      exit 0
    fi

    if [ "$CACHED_STATUS" = "UPDATE_AVAILABLE" ] && [ "$CACHED_LOCAL" = "$LOCAL_SHA" ] && [ -n "$CACHED_REMOTE" ]; then
      if check_snooze "$CACHED_REMOTE"; then
        :
      elif update_is_actionable "$LOCAL_SHA" "$CACHED_REMOTE"; then
        CACHED_SUMMARY="$(read_cached_update_summary "$CACHED_REMOTE")"
        if [ -z "$CACHED_SUMMARY" ]; then
          CACHED_SUMMARY="$(read_remote_update_summary "$LOCAL_SHA" "$CACHED_REMOTE")"
        fi
        print_update_available "$LOCAL_SHA" "$CACHED_REMOTE" "$CACHED_SUMMARY"
        exit 0
      fi
    fi
  fi
fi

REMOTE_SHA="$(remote_sha)"
case "$REMOTE_SHA" in
  [a-fA-F0-9][a-fA-F0-9]*)
    ;;
  *)
    exit 0
    ;;
esac

if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
  atomic_write "$CACHE_FILE" "UP_TO_DATE $LOCAL_SHA $REMOTE_SHA" || true
  rm -f "$SUMMARY_CACHE_FILE" 2>/dev/null || true
  if [ "$SHOW_UP_TO_DATE" = "true" ]; then
    printf 'UP_TO_DATE %s\n' "$(short_sha "$LOCAL_SHA")"
  fi
  exit 0
fi

if ! update_is_actionable "$LOCAL_SHA" "$REMOTE_SHA"; then
  exit 0
fi

UPDATE_SUMMARY="$(read_remote_update_summary "$LOCAL_SHA" "$REMOTE_SHA")"
atomic_write "$CACHE_FILE" "UPDATE_AVAILABLE $LOCAL_SHA $REMOTE_SHA" || true
atomic_write "$SUMMARY_CACHE_FILE" "$REMOTE_SHA $UPDATE_SUMMARY" || true
if check_snooze "$REMOTE_SHA"; then
  exit 0
fi

print_update_available "$LOCAL_SHA" "$REMOTE_SHA" "$UPDATE_SUMMARY"
