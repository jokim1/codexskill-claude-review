#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${CLAUDE_UPDATE_SKILL_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE_DIR="${CLAUDE_UPDATE_STATE_DIR:-$HOME/.codex/claude}"
REMOTE_NAME="${CLAUDE_UPDATE_REMOTE_NAME:-origin}"
REMOTE_BRANCH="${CLAUDE_UPDATE_REMOTE_BRANCH:-main}"
NETWORK_TIMEOUT_SECONDS="${CLAUDE_UPDATE_FETCH_TIMEOUT_SECONDS:-30}"
CHECK_ONLY="false"

usage() {
  cat <<'EOF'
Usage:
  claude-update.sh [--check] [--skill-dir <path>] [--state-dir <path>]

Updates the Claude Review skill from origin/main using a fast-forward-only merge.
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

git_network() {
  command -v python3 >/dev/null 2>&1 || {
    echo "/claude update requires python3 for bounded git operations." >&2
    return 1
  }

  python3 - "$NETWORK_TIMEOUT_SECONDS" "$@" <<'PY'
import os
import shlex
import subprocess
import sys

timeout_raw = sys.argv[1]
args = sys.argv[2:]
try:
    timeout = max(1, int(timeout_raw))
except ValueError:
    timeout = 30

env = os.environ.copy()
env["GIT_TERMINAL_PROMPT"] = "0"
ssh_command = env.get("GIT_SSH_COMMAND", "ssh")
if "BatchMode" not in ssh_command:
    ssh_command = f"{ssh_command} -o BatchMode=yes"
if "ConnectTimeout" not in ssh_command:
    ssh_command = f"{ssh_command} -o ConnectTimeout={timeout}"
env["GIT_SSH_COMMAND"] = ssh_command

try:
    completed = subprocess.run(args, timeout=timeout, env=env, check=False)
except subprocess.TimeoutExpired:
    quoted = " ".join(shlex.quote(arg) for arg in args)
    print(f"git command timed out after {timeout}s: {quoted}", file=sys.stderr)
    sys.exit(124)
except OSError as exc:
    print(f"git command failed: {exc}", file=sys.stderr)
    sys.exit(1)

sys.exit(completed.returncode)
PY
}

prepare_state_dir() {
  local test_file=""

  mkdir -p "$STATE_DIR" || return 1
  test_file="$(mktemp "$STATE_DIR/.write-test.XXXXXX")" || return 1
  printf 'ok\n' > "$test_file" || {
    rm -f "$test_file"
    return 1
  }
  rm -f "$test_file"
}

is_exact_tracked_path() {
  local candidate="$1"
  local tracked=""

  while IFS= read -r -d '' tracked; do
    [ "$tracked" = "$candidate" ] && return 0
  done < <(git -C "$SKILL_DIR" ls-files -z -- "$candidate")

  return 1
}

path_has_untracked_descendants() {
  local candidate="$1"
  local item="" rel=""

  while IFS= read -r -d '' item; do
    rel="${item#"$SKILL_DIR/"}"
    if ! is_exact_tracked_path "$rel"; then
      return 0
    fi
  done < <(find "$SKILL_DIR/$candidate" -mindepth 1 \( -type f -o -type l \) -print0 2>/dev/null)

  return 1
}

path_blocks_as_ancestor() {
  local candidate="$1"
  local full_path="$SKILL_DIR/$candidate"

  [ -e "$full_path" ] || [ -L "$full_path" ] || return 1
  is_exact_tracked_path "$candidate" && return 1
  [ -L "$full_path" ] && return 0
  [ -d "$full_path" ] && return 1
  return 0
}

path_blocks_as_exact_target() {
  local candidate="$1"
  local full_path="$SKILL_DIR/$candidate"

  [ -e "$full_path" ] || [ -L "$full_path" ] || return 1
  is_exact_tracked_path "$candidate" && return 1
  [ -L "$full_path" ] && return 0
  if [ -d "$full_path" ]; then
    path_has_untracked_descendants "$candidate"
    return $?
  fi
  return 0
}

add_collision() {
  local candidate="$1"

  collisions+=("$candidate")
}

check_path_for_collision() {
  local path="$1"
  local ancestor=""

  ancestor="${path%/*}"
  while [ "$ancestor" != "$path" ] && [ -n "$ancestor" ] && [ "$ancestor" != "." ]; do
    if path_blocks_as_ancestor "$ancestor"; then
      add_collision "$ancestor"
    fi
    [ "$ancestor" = "${ancestor%/*}" ] && break
    ancestor="${ancestor%/*}"
  done

  if path_blocks_as_exact_target "$path"; then
    add_collision "$path"
  fi
}

check_untracked_collisions() {
  local local_sha="$1"
  local remote_ref="$2"
  local path="" collisions=()

  while IFS= read -r -d '' path; do
    check_path_for_collision "$path"
  done < <(git -C "$SKILL_DIR" diff --name-only -z --diff-filter=ACMRT "$local_sha" "$remote_ref")

  if [ "${#collisions[@]}" -eq 0 ]; then
    return 0
  fi

  echo "/claude update is blocked because these untracked or ignored local files would be overwritten:" >&2
  printf '  %s\n' "${collisions[@]}" >&2
  echo "Move, remove, or commit those files, then rerun /claude update." >&2
  return 1
}

validate_update_ready() {
  if [ "$CURRENT_BRANCH_REF" != "refs/heads/$REMOTE_BRANCH" ]; then
    echo "/claude update is blocked because the skill checkout is not on ${REMOTE_BRANCH}." >&2
    if [ -n "$CURRENT_BRANCH_REF" ]; then
      echo "Current branch: ${CURRENT_BRANCH_REF#refs/heads/}" >&2
    else
      echo "Current checkout is detached." >&2
    fi
    echo "Check out ${REMOTE_BRANCH} in $SKILL_DIR, then rerun /claude update." >&2
    return 1
  fi

  DIRTY_TRACKED="$(git -C "$SKILL_DIR" status --porcelain --untracked-files=no)"
  if [ -n "$DIRTY_TRACKED" ]; then
    echo "/claude update is blocked because the skill checkout has tracked local changes:" >&2
    printf '%s\n' "$DIRTY_TRACKED" >&2
    echo "Commit, stash, or revert those changes, then rerun /claude update." >&2
    return 1
  fi

  if ! git -C "$SKILL_DIR" merge-base --is-ancestor "$LOCAL_SHA" "$REMOTE_SHA"; then
    echo "/claude update is blocked because ${REMOTE_NAME}/${REMOTE_BRANCH} is not a fast-forward from the installed checkout." >&2
    echo "Resolve the git history manually in $SKILL_DIR." >&2
    return 1
  fi

  if ! check_untracked_collisions "$LOCAL_SHA" "$REMOTE_REF"; then
    return 1
  fi

  if ! prepare_state_dir; then
    echo "/claude update is blocked because update state cannot be written to $STATE_DIR." >&2
    echo "Fix permissions or disk space, then rerun /claude update." >&2
    return 1
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      CHECK_ONLY="true"
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
    --yes|-y)
      # Backward-compatible no-op. Invoking /claude update is already consent.
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

if ! git -C "$SKILL_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "/claude update is only available for git-based installs." >&2
  echo "Reinstall with: git clone https://github.com/jokim1/codexskill-claude-review.git ~/.codex/skills/claude" >&2
  exit 1
fi

LOCAL_SHA="$(git -C "$SKILL_DIR" rev-parse HEAD)"
CURRENT_BRANCH_REF="$(git -C "$SKILL_DIR" symbolic-ref -q HEAD 2>/dev/null || true)"

REMOTE_REF="refs/remotes/${REMOTE_NAME}/${REMOTE_BRANCH}"
if ! git_network git -c core.hooksPath=/dev/null -C "$SKILL_DIR" fetch --quiet --no-tags "$REMOTE_NAME" "+refs/heads/${REMOTE_BRANCH}:${REMOTE_REF}"; then
  echo "/claude update could not fetch ${REMOTE_NAME}/${REMOTE_BRANCH}." >&2
  exit 1
fi
REMOTE_SHA="$(git -C "$SKILL_DIR" rev-parse "$REMOTE_REF")"

print_status() {
  if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
    printf '/claude is up to date (%s).\n' "$(short_sha "$LOCAL_SHA")"
    return 0
  fi

  printf '/claude update available.\n'
  printf '  Installed: %s\n' "$(short_sha "$LOCAL_SHA")"
  printf '  Latest %s/%s: %s\n' "$REMOTE_NAME" "$REMOTE_BRANCH" "$(short_sha "$REMOTE_SHA")"

  COMMITS="$(git -C "$SKILL_DIR" log --oneline --no-decorate "$LOCAL_SHA..$REMOTE_SHA" 2>/dev/null | head -n 20 || true)"
  if [ -n "$COMMITS" ]; then
    printf '\nCommits since install:\n'
    printf '%s\n' "$COMMITS" | sed 's/^/  /'
  fi
}

if [ "$CHECK_ONLY" = "true" ]; then
  print_status
  if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    validate_update_ready
  fi
  exit 0
fi

if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
  print_status
  exit 0
fi

if ! validate_update_ready; then
  exit 1
fi

if ! git_network git -c core.hooksPath=/dev/null -C "$SKILL_DIR" merge --ff-only "$REMOTE_REF"; then
  echo "/claude update could not fast-forward merge ${REMOTE_NAME}/${REMOTE_BRANCH}." >&2
  exit 1
fi

if ! atomic_write "$STATE_DIR/just-updated-from" "$LOCAL_SHA"; then
  echo "Warning: /claude updated, but could not write the just-updated marker at $STATE_DIR." >&2
fi
if ! rm -f "$STATE_DIR/last-update-check" "$STATE_DIR/update-snoozed"; then
  echo "Warning: /claude updated, but could not clear cached update state at $STATE_DIR." >&2
fi

printf '/claude updated from %s to %s.\n' "$(short_sha "$LOCAL_SHA")" "$(short_sha "$REMOTE_SHA")"
printf 'Restart Codex if skill discovery is already loaded.\n'
