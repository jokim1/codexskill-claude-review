#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/claude-doctor-test-XXXXXX)"
FAKE_BIN="$TMP_DIR/bin"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$FAKE_BIN"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
  printf '2.test.0 (Claude Code fake)\n'
  exit 0
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf '{"loggedIn":true,"apiProvider":"firstParty","accessToken":"must-not-print"}\n'
  exit 0
fi

if [ "${1:-}" = "-p" ]; then
  if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_BEARER_TOKEN:-}" ]; then
    printf 'Anthropic credential env var leaked into fake claude\n' >&2
    exit 42
  fi
  printf '{"type":"result","subtype":"success","is_error":false,"result":"OK"}\n'
  exit 0
fi

printf 'unexpected fake claude args: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/claude"

output="$(
  cd "$REPO_ROOT"
  PATH="$FAKE_BIN:$PATH" \
  ANTHROPIC_API_KEY=secret \
  ANTHROPIC_AUTH_TOKEN=secret \
  bash scripts/claude-doctor.sh \
    --repo-root "$REPO_ROOT" \
    --skill-root "$REPO_ROOT" \
    --probe-timeout 5 \
    --skip-update-check
)"

printf '%s\n' "$output" | grep -q '^CLAUDE_REVIEW_DOCTOR$' || fail "missing doctor header"
printf '%s\n' "$output" | grep -q '^runner_safe_mode=ok$' || fail "runner safe-mode check missing"
printf '%s\n' "$output" | grep -q '^runner_strict_mcp_config=ok$' || fail "runner strict MCP check missing"
printf '%s\n' "$output" | grep -q '^router_present=ok$' || fail "router presence check missing"
printf '%s\n' "$output" | grep -q '^update_check=skipped$' || fail "update check skip not reported"
printf '%s\n' "$output" | grep -q '^claude_bin=.*claude$' || fail "fake claude path not reported"
printf '%s\n' "$output" | grep -q '^claude_version=2.test.0 (Claude Code fake)$' || fail "fake claude version not reported"
printf '%s\n' "$output" | grep -q '^claude_auth_logged_in=True$' || fail "auth logged-in summary missing"
printf '%s\n' "$output" | grep -q '^claude_auth_provider=firstParty$' || fail "auth provider summary missing"
printf '%s\n' "$output" | grep -q '^ANTHROPIC_API_KEY=set$' || fail "redacted env state missing"
printf '%s\n' "$output" | grep -q '^plain_print_probe_status=completed$' || fail "plain probe did not complete"
printf '%s\n' "$output" | grep -q '^safe_mode_print_probe_status=completed$' || fail "safe-mode probe did not complete"

if printf '%s\n' "$output" | grep -q 'must-not-print\|secret'; then
  fail "doctor output leaked secret-like auth data"
fi

printf 'ok: claude doctor diagnostics\n'
