#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATER="$REPO_ROOT/scripts/claude-update.sh"
UPDATE_CHECK="$REPO_ROOT/scripts/claude-update-check.sh"
TMP_ROOT="$(mktemp -d /tmp/claude-update-test-XXXXXX)"
REMOTE="$TMP_ROOT/remote.git"
SOURCE="$TMP_ROOT/source"
SKILL_CHECKOUT="$TMP_ROOT/skill"
CHECK_ONLY_SKILL="$TMP_ROOT/check-only-skill"
CALLER_REPO="$TMP_ROOT/caller"
STATE_DIR="$TMP_ROOT/state"
CHECK_STATE_DIR="$TMP_ROOT/check-state"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local case_name="$1"
  local output="$2"
  local expected="$3"

  case "$output" in
    *"$expected"*) ;;
    *) fail "$case_name: expected output to contain: $expected\n$output" ;;
  esac
}

assert_file_contents() {
  local case_name="$1"
  local file="$2"
  local expected="$3"
  local actual=""

  [ -f "$file" ] || fail "$case_name: missing file $file"
  actual="$(cat "$file")"
  [ "$actual" = "$expected" ] || fail "$case_name: expected $file to contain '$expected', got '$actual'"
}

git init -q --bare "$REMOTE"
git init -q "$SOURCE"
git -C "$SOURCE" checkout -q -b main
git -C "$SOURCE" config user.email test@example.com
git -C "$SOURCE" config user.name "Claude Update Test"
printf 'base\n' > "$SOURCE/SKILL.md"
git -C "$SOURCE" add SKILL.md
git -C "$SOURCE" commit -qm "base"
git -C "$SOURCE" remote add origin "$REMOTE"
git -C "$SOURCE" push -qu origin main
BASE_SHA="$(git -C "$SOURCE" rev-parse HEAD)"

git clone -q --branch main "$REMOTE" "$SKILL_CHECKOUT"
git clone -q --branch main "$REMOTE" "$CHECK_ONLY_SKILL"
SKILL_CHECKOUT="$(cd "$SKILL_CHECKOUT" && pwd -P)"
CHECK_ONLY_SKILL="$(cd "$CHECK_ONLY_SKILL" && pwd -P)"
git -C "$SKILL_CHECKOUT" config user.email test@example.com
git -C "$SKILL_CHECKOUT" config user.name "Claude Update Test"
git -C "$CHECK_ONLY_SKILL" config user.email test@example.com
git -C "$CHECK_ONLY_SKILL" config user.name "Claude Update Test"

printf '/docs/local-plans/\n' > "$SOURCE/.gitignore"
git -C "$SOURCE" add .gitignore
git -C "$SOURCE" commit -qm "add incoming ignore rule"
git -C "$SOURCE" push -qu origin main
REMOTE_SHA="$(git -C "$SOURCE" rev-parse HEAD)"

for checkout in "$SKILL_CHECKOUT" "$CHECK_ONLY_SKILL"; do
  printf 'docs/local-plans/\n' > "$checkout/.gitignore"
  mkdir -p "$checkout/docs/local-plans"
  printf 'keep me\n' > "$checkout/docs/local-plans/private-plan.md"
done

set +e
BLOCKED_OUTPUT="$(bash "$UPDATER" \
  --skill-dir "$SKILL_CHECKOUT" \
  --state-dir "$STATE_DIR" \
  --caller-repo "$SKILL_CHECKOUT" 2>&1)"
BLOCKED_STATUS=$?
set -e

[ "$BLOCKED_STATUS" -ne 0 ] || fail "collision preflight should stop without explicit backup consent"
assert_contains "same-checkout scope" "$BLOCKED_OUTPUT" "Skill checkout: $SKILL_CHECKOUT"
assert_contains "same-checkout scope" "$BLOCKED_OUTPUT" "Command repo:    $SKILL_CHECKOUT"
assert_contains "same-checkout scope" "$BLOCKED_OUTPUT" "Scope: same checkout; this update changes the command repo."
assert_contains "collision detail" "$BLOCKED_OUTPUT" "Local path:      $SKILL_CHECKOUT/.gitignore"
assert_contains "collision detail" "$BLOCKED_OUTPUT" "Incoming write:  $SKILL_CHECKOUT/.gitignore"
assert_contains "non-destructive stop" "$BLOCKED_OUTPUT" "No checkout files were changed."
assert_contains "continuation command" "$BLOCKED_OUTPUT" "/claude-review update --backup-conflicts"
assert_contains "continuation marker" "$BLOCKED_OUTPUT" "ACTION_REQUIRED: BACKUP_CONFLICTS"
[ "$(git -C "$SKILL_CHECKOUT" rev-parse HEAD)" = "$BASE_SHA" ] || fail "blocked update changed HEAD"
assert_file_contents "blocked local file" "$SKILL_CHECKOUT/.gitignore" "docs/local-plans/"
assert_file_contents "blocked ignored content" "$SKILL_CHECKOUT/docs/local-plans/private-plan.md" "keep me"

CHECK_OUTPUT="$(bash "$UPDATE_CHECK" \
  --force \
  --skill-dir "$CHECK_ONLY_SKILL" \
  --state-dir "$CHECK_STATE_DIR" 2>&1)"
assert_contains "automatic update check remains actionable" "$CHECK_OUTPUT" "UPDATE_AVAILABLE"

BACKUP_OUTPUT="$(bash "$UPDATER" \
  --backup-conflicts \
  --skill-dir "$SKILL_CHECKOUT" \
  --state-dir "$STATE_DIR" \
  --caller-repo "$SKILL_CHECKOUT" 2>&1)"

[ "$(git -C "$SKILL_CHECKOUT" rev-parse HEAD)" = "$REMOTE_SHA" ] || fail "backup continuation did not complete the update"
assert_file_contents "incoming tracked file" "$SKILL_CHECKOUT/.gitignore" "/docs/local-plans/"
assert_file_contents "ignored content survives" "$SKILL_CHECKOUT/docs/local-plans/private-plan.md" "keep me"
BACKED_UP_IGNORE="$(find "$STATE_DIR/update-backups" -type f -name .gitignore -print -quit)"
[ -n "$BACKED_UP_IGNORE" ] || fail "backup continuation did not preserve the local .gitignore"
assert_file_contents "preserved local file" "$BACKED_UP_IGNORE" "docs/local-plans/"
assert_contains "backup result" "$BACKUP_OUTPUT" "Conflicting local paths were preserved at:"
assert_contains "update result" "$BACKUP_OUTPUT" "/claude-review updated from"

git init -q "$CALLER_REPO"
git -C "$CALLER_REPO" checkout -q -b main
CALLER_REPO="$(cd "$CALLER_REPO" && pwd -P)"
SEPARATE_OUTPUT="$(bash "$UPDATER" \
  --check \
  --skill-dir "$SKILL_CHECKOUT" \
  --state-dir "$STATE_DIR" \
  --caller-repo "$CALLER_REPO" 2>&1)"
assert_contains "separate-checkout scope" "$SEPARATE_OUTPUT" "Command repo:    $CALLER_REPO"
assert_contains "separate-checkout scope" "$SEPARATE_OUTPUT" "Scope: separate checkout; the command repo will not be changed."

printf 'ok: claude update scope and conflict backup flow\n'
