#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_FILE="$REPO_ROOT/SKILL.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -Fq "invalid JSON" "$SKILL_FILE" || fail "SKILL.md must block invalid router JSON"
grep -Fq 'missing `status`' "$SKILL_FILE" || fail "SKILL.md must block missing router status"
grep -Fq 'unknown `flow`' "$SKILL_FILE" || fail "SKILL.md must block unknown router flow"
grep -Fq 'needs_context` without a non-empty `message`' "$SKILL_FILE" || fail "SKILL.md must block needs_context without message"
grep -Fq "do not invoke Claude" "$SKILL_FILE" || fail "SKILL.md must forbid Claude invocation after malformed router output"

printf 'ok: malformed router output guard documented\n'
