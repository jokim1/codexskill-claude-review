#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

json_quote() {
  python3 - "$1" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1]))
PY
}

make_error_result() {
  local message="$1"
  printf '{"type":"result","is_error":true,"result":%s}' "$(json_quote "$message")"
}

assert_blocked_result() {
  local case_name="$1"
  local output="$2"
  local expect_summary="$3"
  local expect_question="$4"
  local reject_summary="$5"

  OUTPUT_JSON="$output" CASE_NAME="$case_name" EXPECT_SUMMARY="$expect_summary" EXPECT_QUESTION="$expect_question" REJECT_SUMMARY="$reject_summary" python3 - <<'PY'
import json
import os
import sys

case_name = os.environ["CASE_NAME"]
expect_summary = os.environ["EXPECT_SUMMARY"]
expect_question = os.environ["EXPECT_QUESTION"]
reject_summary = os.environ["REJECT_SUMMARY"]
output_json = os.environ["OUTPUT_JSON"]

try:
    data = json.loads(output_json)
except Exception as exc:
    print(f"{case_name}: output was not JSON: {exc}", file=sys.stderr)
    sys.exit(1)

summary = data.get("summary", "")
questions = " ".join(data.get("open_questions", []))

if data.get("status") != "blocked":
    print(f"{case_name}: expected blocked status, got {data.get('status')!r}", file=sys.stderr)
    sys.exit(1)
if expect_summary and expect_summary not in summary:
    print(f"{case_name}: expected summary to contain {expect_summary!r}, got {summary!r}", file=sys.stderr)
    sys.exit(1)
if expect_question and expect_question not in questions:
    print(f"{case_name}: expected open question to contain {expect_question!r}, got {questions!r}", file=sys.stderr)
    sys.exit(1)
if reject_summary and reject_summary in summary:
    print(f"{case_name}: summary should not contain {reject_summary!r}, got {summary!r}", file=sys.stderr)
    sys.exit(1)
PY
}

run_case() {
  local case_name="$1"
  local probe_output="$2"
  local probe_status="$3"
  local review_output="$4"
  local review_status="$5"
  local expect_summary="$6"
  local expect_question="$7"
  local reject_summary="${8:-}"
  local claude_config_dir="${9:-}"
  local shell_path="${10:-/bin/bash}"
  local fake_root tmpdir output

  mkdir -p "$HOME/.codex"
  fake_root="$(mktemp -d "$HOME/.codex/claude-test-bin-XXXXXX")"
  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  mkdir -p "$fake_root/bin"

  cat > "$fake_root/bin/claude" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
  printf 'Claude Code fake\n'
  exit 0
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf '{"loggedIn":true,"apiProvider":"firstParty"}\n'
  exit 0
fi

if [ "${1:-}" = "-p" ]; then
  prompt="${2:-}"
  if [[ "$prompt" == *"Codex Claude skill preflight probe"* ]]; then
    if [ -n "${FAKE_CLAUDE_PROBE_OUTPUT:-}" ]; then
      printf '%s\n' "$FAKE_CLAUDE_PROBE_OUTPUT"
    fi
    exit "${FAKE_CLAUDE_PROBE_STATUS:-0}"
  fi

  if [ -n "${FAKE_CLAUDE_REVIEW_OUTPUT:-}" ]; then
    printf '%s\n' "$FAKE_CLAUDE_REVIEW_OUTPUT"
  fi
  exit "${FAKE_CLAUDE_REVIEW_STATUS:-0}"
fi

printf 'unexpected fake claude args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/claude"
  printf 'review artifact\n' > "$tmpdir/claude-review-artifact.txt"

  output="$(
    cd "$REPO_ROOT"
    PATH="$fake_root/bin:$PATH" \
      FAKE_CLAUDE_PROBE_OUTPUT="$probe_output" \
      FAKE_CLAUDE_PROBE_STATUS="$probe_status" \
      FAKE_CLAUDE_REVIEW_OUTPUT="$review_output" \
      FAKE_CLAUDE_REVIEW_STATUS="$review_status" \
      CLAUDE_CONFIG_DIR="$claude_config_dir" \
      SHELL="$shell_path" \
      bash scripts/run-review.sh \
        --mode code \
        --artifact-file "$tmpdir/claude-review-artifact.txt" \
        --base-prompt prompts/code-review.base.md \
        --schema-file schemas/review-output.json \
        --repo-root "$REPO_ROOT" \
        --branch test \
        --base-branch main \
        2>"$tmpdir/run-review.stderr"
  )" || {
    rm -rf "$fake_root" "$tmpdir"
    fail "$case_name exited non-zero"
  }

  if ! assert_blocked_result "$case_name" "$output" "$expect_summary" "$expect_question" "$reject_summary"; then
    rm -rf "$fake_root" "$tmpdir"
    fail "$case_name assertion failed"
  fi

  rm -rf "$fake_root" "$tmpdir"
  printf 'ok: %s\n' "$case_name"
}

run_artifact_boundary_case() {
  local tmpdir output

  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  printf 'review artifact\n' > "$tmpdir/not-review-artifact.txt"

  output="$(
    cd "$REPO_ROOT"
    bash scripts/run-review.sh \
      --mode code \
      --artifact-file "$tmpdir/not-review-artifact.txt" \
      --base-prompt prompts/code-review.base.md \
      --schema-file schemas/review-output.json \
      --repo-root "$REPO_ROOT" \
      --branch test \
      --base-branch main
  )" || {
    rm -rf "$tmpdir"
    fail "artifact boundary exited non-zero"
  }

  if ! assert_blocked_result "artifact boundary" "$output" "review artifact path is outside" "/tmp/claude-review-*" ""; then
    rm -rf "$tmpdir"
    fail "artifact boundary assertion failed"
  fi

  rm -rf "$tmpdir"
  printf 'ok: artifact boundary\n'
}

run_config_boundary_case() {
  local tmpdir output

  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  mkdir -p "$tmpdir/evil/.codex/claude"
  printf 'review artifact\n' > "$tmpdir/claude-review-artifact.txt"
  printf 'MODEL=sonnet\n' > "$tmpdir/evil/.codex/claude/config.env"

  output="$(
    cd "$REPO_ROOT"
    bash scripts/run-review.sh \
      --mode code \
      --artifact-file "$tmpdir/claude-review-artifact.txt" \
      --base-prompt prompts/code-review.base.md \
      --schema-file schemas/review-output.json \
      --config-file "$tmpdir/evil/.codex/claude/config.env" \
      --repo-root "$REPO_ROOT" \
      --branch test \
      --base-branch main
  )" || {
    rm -rf "$tmpdir"
    fail "config boundary exited non-zero"
  }

  if ! assert_blocked_result "config boundary" "$output" "outside the supplied repo root" "<repo>/.codex/claude/config.env" ""; then
    rm -rf "$tmpdir"
    fail "config boundary assertion failed"
  fi

  rm -rf "$tmpdir"
  printf 'ok: config boundary\n'
}

run_unsafe_claude_candidate_case() {
  local tmpdir output

  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  mkdir -p "$tmpdir/bin"
  mkdir -p "$tmpdir/home"
  printf 'review artifact\n' > "$tmpdir/claude-review-artifact.txt"
  cat > "$tmpdir/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'unsafe fake claude should not run\n' >&2
exit 99
EOF
  chmod +x "$tmpdir/bin/claude"

  output="$(
    cd "$REPO_ROOT"
    HOME="$tmpdir/home" \
    PATH="$tmpdir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      SHELL=/bin/bash \
      bash scripts/run-review.sh \
        --mode code \
        --artifact-file "$tmpdir/claude-review-artifact.txt" \
        --base-prompt prompts/code-review.base.md \
        --schema-file schemas/review-output.json \
        --repo-root "$REPO_ROOT" \
        --branch test \
        --base-branch main
  )" || {
    rm -rf "$tmpdir"
    fail "unsafe claude candidate exited non-zero"
  }

  if ! assert_blocked_result "unsafe claude candidate" "$output" "unsafe path" "$tmpdir/bin/claude" ""; then
    rm -rf "$tmpdir"
    fail "unsafe claude candidate assertion failed"
  fi

  rm -rf "$tmpdir"
  printf 'ok: unsafe claude candidate\n'
}

run_timeout_wrapper_closes_stdin_case() {
  local fake_root tmpdir output

  mkdir -p "$HOME/.codex"
  fake_root="$(mktemp -d "$HOME/.codex/claude-test-bin-XXXXXX")"
  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  mkdir -p "$fake_root/bin"
  printf 'review artifact\n' > "$tmpdir/claude-review-artifact.txt"

  cat > "$fake_root/bin/claude" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
  printf 'Claude Code fake\n'
  exit 0
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf '{"loggedIn":true,"apiProvider":"firstParty"}\n'
  exit 0
fi

if [ "${1:-}" = "-p" ]; then
  prompt="${2:-}"
  if [[ "$prompt" == *"Codex Claude skill preflight probe"* ]]; then
    printf '{"ok":true}\n'
    exit 0
  fi

  stdin_payload="$(cat || true)"
  if [ -n "$stdin_payload" ]; then
    printf 'fake claude received unexpected stdin: %s bytes\n' "${#stdin_payload}" >&2
    exit 42
  fi

  printf '{"status":"clean","mode":"code","summary":"ok","findings":[],"open_questions":[]}\n'
  exit 0
fi

printf 'unexpected fake claude args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/claude"

  output="$(
    cd "$REPO_ROOT"
    PATH="$fake_root/bin:$PATH" \
      bash scripts/run-review.sh \
        --mode code \
        --artifact-file "$tmpdir/claude-review-artifact.txt" \
        --base-prompt prompts/code-review.base.md \
        --schema-file schemas/review-output.json \
        --repo-root "$REPO_ROOT" \
        --branch test \
        --base-branch main
  )" || {
    rm -rf "$fake_root" "$tmpdir"
    fail "timeout wrapper stdin case exited non-zero"
  }

  OUTPUT_JSON="$output" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["OUTPUT_JSON"])
if data.get("status") != "clean" or data.get("summary") != "ok":
    print(f"expected clean ok result, got {data!r}", file=sys.stderr)
    sys.exit(1)
PY

  rm -rf "$fake_root" "$tmpdir"
  printf 'ok: timeout wrapper closes stdin\n'
}

run_probe_timeout_case() {
  local fake_root tmpdir output

  mkdir -p "$HOME/.codex"
  fake_root="$(mktemp -d "$HOME/.codex/claude-test-bin-XXXXXX")"
  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  mkdir -p "$fake_root/bin"
  printf 'review artifact\n' > "$tmpdir/claude-review-artifact.txt"

  cat > "$fake_root/bin/claude" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
  printf 'Claude Code fake\n'
  exit 0
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf '{"loggedIn":true,"apiProvider":"firstParty"}\n'
  exit 0
fi

if [ "${1:-}" = "-p" ]; then
  prompt="${2:-}"
  if [[ "$prompt" == *"Codex Claude skill preflight probe"* ]]; then
    sleep 5
    printf '{"ok":true}\n'
    exit 0
  fi

  printf '{"status":"clean","mode":"code","summary":"ok","findings":[],"open_questions":[]}\n'
  exit 0
fi

printf 'unexpected fake claude args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/claude"

  output="$(
    cd "$REPO_ROOT"
    PATH="$fake_root/bin:$PATH" \
      LIVE_PROBE_TIMEOUT_SECONDS=1 \
      bash scripts/run-review.sh \
        --mode code \
        --artifact-file "$tmpdir/claude-review-artifact.txt" \
        --base-prompt prompts/code-review.base.md \
        --schema-file schemas/review-output.json \
        --repo-root "$REPO_ROOT" \
        --branch test \
        --base-branch main
  )" || {
    rm -rf "$fake_root" "$tmpdir"
    fail "probe timeout case exited non-zero"
  }

  if ! assert_blocked_result "probe timeout" "$output" "preflight timed out after 1s" "LIVE_PROBE_TIMEOUT_SECONDS" "Claude Code invocation failed"; then
    rm -rf "$fake_root" "$tmpdir"
    fail "probe timeout assertion failed"
  fi

  rm -rf "$fake_root" "$tmpdir"
  printf 'ok: probe timeout\n'
}

run_safe_mode_args_case() {
  local fake_root tmpdir output arg_log

  mkdir -p "$HOME/.codex"
  fake_root="$(mktemp -d "$HOME/.codex/claude-test-bin-XXXXXX")"
  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  mkdir -p "$fake_root/bin"
  printf 'review artifact\n' > "$tmpdir/claude-review-artifact.txt"
  arg_log="$tmpdir/claude-args.log"

  cat > "$fake_root/bin/claude" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
  printf 'Claude Code fake\n'
  exit 0
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf '{"loggedIn":true,"apiProvider":"firstParty"}\n'
  exit 0
fi

if [ "${1:-}" = "-p" ]; then
  prompt="${2:-}"
  has_safe_mode="false"
  for arg in "$@"; do
    if [ "$arg" = "--safe-mode" ]; then
      has_safe_mode="true"
    fi
  done
  if [[ "$prompt" == *"Codex Claude skill preflight probe"* ]]; then
    printf 'probe_safe_mode=%s\n' "$has_safe_mode" >> "$FAKE_CLAUDE_ARG_LOG"
    printf '{"ok":true}\n'
    exit 0
  fi

  printf 'review_safe_mode=%s\n' "$has_safe_mode" >> "$FAKE_CLAUDE_ARG_LOG"
  printf '{"status":"clean","mode":"code","summary":"ok","findings":[],"open_questions":[]}\n'
  exit 0
fi

printf 'unexpected fake claude args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/claude"

  output="$(
    cd "$REPO_ROOT"
    PATH="$fake_root/bin:$PATH" \
      FAKE_CLAUDE_ARG_LOG="$arg_log" \
      bash scripts/run-review.sh \
        --mode code \
        --artifact-file "$tmpdir/claude-review-artifact.txt" \
        --base-prompt prompts/code-review.base.md \
        --schema-file schemas/review-output.json \
        --repo-root "$REPO_ROOT" \
        --branch test \
        --base-branch main
  )" || {
    rm -rf "$fake_root" "$tmpdir"
    fail "safe mode args case exited non-zero"
  }

  OUTPUT_JSON="$output" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["OUTPUT_JSON"])
if data.get("status") != "clean" or data.get("summary") != "ok":
    print(f"expected clean ok result, got {data!r}", file=sys.stderr)
    sys.exit(1)
PY

  if ! grep -q '^probe_safe_mode=true$' "$arg_log"; then
    rm -rf "$fake_root" "$tmpdir"
    fail "preflight probe did not include --safe-mode"
  fi
  if ! grep -q '^review_safe_mode=true$' "$arg_log"; then
    rm -rf "$fake_root" "$tmpdir"
    fail "review call did not include --safe-mode"
  fi

  rm -rf "$fake_root" "$tmpdir"
  printf 'ok: safe mode args\n'
}

sandbox_summary="Claude could not write its first-party auth/config state"
generic_runtime_summary="Claude Code invocation failed"
custom_config_dir="$HOME/.codex/claude-test-config-dir"
evil_shell="$(mktemp /tmp/claude-review-evil-shell-XXXXXX)"
trap 'rm -f "$evil_shell"' EXIT
cat > "$evil_shell" <<'EOF'
#!/usr/bin/env bash
printf 'evil shell should not run\n' >&2
exit 99
EOF
chmod +x "$evil_shell"
multiline_state_error="$(make_error_result "Error: EACCES: permission denied
open '$HOME/.claude/settings.json'")"

run_case \
  "probe oauth refresh EPERM" \
  "$(make_error_result "Error: EPERM: operation not permitted, mkdir '/Users/josephkim/.claude/.oauth_refresh.lock'")" \
  0 \
  "" \
  0 \
  "$sandbox_summary" \
  "oauth_refresh.lock"

run_case \
  "probe claude dir EACCES" \
  "$(make_error_result "Error: EACCES: permission denied, open '$HOME/.claude/settings.json'")" \
  0 \
  "" \
  0 \
  "$sandbox_summary" \
  ".claude/settings.json"

run_case \
  "probe multiline claude dir EACCES" \
  "$multiline_state_error" \
  0 \
  "" \
  0 \
  "$sandbox_summary" \
  ".claude/settings.json"

run_case \
  "probe unrelated permission error" \
  "$(make_error_result "Error: EPERM: operation not permitted, mkdir '/tmp/not-claude'")" \
  0 \
  "" \
  0 \
  "Claude Code was found" \
  "" \
  "$sandbox_summary"

run_case \
  "probe repo local claude permission error" \
  "$(make_error_result "Error: EACCES: permission denied, open '.claude/settings.json'")" \
  0 \
  "" \
  0 \
  "Claude Code was found" \
  "" \
  "$sandbox_summary"

run_case \
  "probe custom config dir EACCES" \
  "$(make_error_result "Error: EACCES: permission denied, open '$custom_config_dir/settings.json'")" \
  0 \
  "" \
  0 \
  "$sandbox_summary" \
  "$custom_config_dir/settings.json" \
  "" \
  "$custom_config_dir"

run_case \
  "probe ignores unsafe shell env" \
  "$(make_error_result "Error: EPERM: operation not permitted, mkdir '/Users/josephkim/.claude/.oauth_refresh.lock'")" \
  0 \
  "" \
  0 \
  "$sandbox_summary" \
  "oauth_refresh.lock" \
  "" \
  "" \
  "$evil_shell"

run_case \
  "probe empty failure" \
  "" \
  1 \
  "" \
  0 \
  "Claude Code was found" \
  "" \
  "$sandbox_summary"

run_case \
  "runtime claude dir EPERM" \
  '{"ok":true}' \
  0 \
  "$(make_error_result "Error: EPERM: operation not permitted, mkdir '$HOME/.claude/.oauth_refresh.lock'")" \
  0 \
  "$sandbox_summary" \
  "oauth_refresh.lock" \
  "$generic_runtime_summary"

run_artifact_boundary_case
run_config_boundary_case
run_unsafe_claude_candidate_case
run_timeout_wrapper_closes_stdin_case
run_probe_timeout_case
run_safe_mode_args_case
rm -f "$evil_shell"
