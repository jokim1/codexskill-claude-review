#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="$(command -v python3)"
REAL_JQ="$(command -v jq 2>/dev/null || true)"

make_fake_claude_root() {
  mkdir -p "$HOME/.codex"
  mktemp -d "$HOME/.codex/claude-test-bin-XXXXXX"
}

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

assert_result_mode() {
  local case_name="$1"
  local output="$2"
  local expected_status="$3"
  local expected_mode="$4"
  local expected_summary="${5:-ok}"

  OUTPUT_JSON="$output" CASE_NAME="$case_name" EXPECTED_STATUS="$expected_status" EXPECTED_MODE="$expected_mode" EXPECTED_SUMMARY="$expected_summary" "$PYTHON_BIN" - <<'PY'
import json
import os
import sys

case_name = os.environ["CASE_NAME"]
expected_status = os.environ["EXPECTED_STATUS"]
expected_mode = os.environ["EXPECTED_MODE"]
expected_summary = os.environ["EXPECTED_SUMMARY"]

try:
    data = json.loads(os.environ["OUTPUT_JSON"])
except Exception as exc:
    print(f"{case_name}: output was not JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if data.get("status") != expected_status:
    print(f"{case_name}: expected status {expected_status!r}, got {data.get('status')!r}", file=sys.stderr)
    sys.exit(1)
if data.get("mode") != expected_mode:
    print(f"{case_name}: expected mode {expected_mode!r}, got {data.get('mode')!r}", file=sys.stderr)
    sys.exit(1)
if data.get("summary") != expected_summary:
    print(f"{case_name}: expected summary {expected_summary!r}, got {data.get('summary')!r}", file=sys.stderr)
    sys.exit(1)
PY
}

assert_doctor_offer_state() {
  local case_name="$1"
  local output="$2"
  local expected="$3"

  CASE_NAME="$case_name" OUTPUT_JSON="$output" EXPECTED_OFFER="$expected" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["OUTPUT_JSON"])
question = "\n".join(data.get("open_questions", []))
offer = "Run /claude-review doctor now?\nReply Y to run diagnostics, or N to stop."
count = question.count(offer)
expected = os.environ["EXPECTED_OFFER"] == "true"
if expected and count != 1:
    print(f"{os.environ['CASE_NAME']}: expected one doctor offer, got {count}", file=sys.stderr)
    sys.exit(1)
if not expected and count:
    print(f"{os.environ['CASE_NAME']}: unexpected doctor offer", file=sys.stderr)
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
  local expected_doctor_offer="${11:-}"
  local fake_auth_status="${12:-}"
  local fake_hang_stage="${13:-}"
  local fake_root tmpdir output

  if [ -z "$fake_auth_status" ]; then
    fake_auth_status='{"loggedIn":true,"apiProvider":"firstParty"}'
  fi

  fake_root="$(make_fake_claude_root)"
  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  mkdir -p "$fake_root/bin"

  cat > "$fake_root/bin/claude" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
  if [ "${FAKE_CLAUDE_HANG_STAGE:-}" = "version" ]; then
    while :; do :; done
  fi
  printf 'Claude Code fake\n'
  exit 0
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  if [ "${FAKE_CLAUDE_HANG_STAGE:-}" = "auth" ]; then
    while :; do :; done
  fi
  printf '%s\n' "$FAKE_CLAUDE_AUTH_STATUS"
  exit 0
fi

if [ "${1:-}" = "-p" ]; then
  prompt="$(cat)"
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
      FAKE_CLAUDE_AUTH_STATUS="$fake_auth_status" \
      FAKE_CLAUDE_HANG_STAGE="$fake_hang_stage" \
      LIVE_PROBE_TIMEOUT_SECONDS=1 \
      CLAUDE_CONFIG_DIR="$claude_config_dir" \
      SHELL="$shell_path" \
      bash --noprofile --norc -p scripts/run-review.sh \
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
  if [ -n "$expected_doctor_offer" ]; then
    if ! assert_doctor_offer_state "$case_name" "$output" "$expected_doctor_offer"; then
      rm -rf "$fake_root" "$tmpdir"
      fail "$case_name doctor-offer assertion failed"
    fi
  fi

  rm -rf "$fake_root" "$tmpdir"
  printf 'ok: %s\n' "$case_name"
}

run_schema_challenge_modes_case() {
  "$PYTHON_BIN" - "$REPO_ROOT/schemas/review-output.json" <<'PY'
import json
from pathlib import Path
import sys

schema = json.loads(Path(sys.argv[1]).read_text())
modes = set(schema["properties"]["mode"]["enum"])
missing = {"challenge_code", "challenge_plan"} - modes
if missing:
    print(f"schema is missing challenge modes: {sorted(missing)}", file=sys.stderr)
    sys.exit(1)
PY
  printf 'ok: schema challenge modes\n'
}

write_fake_jq_stamp_failure() {
  local fake_root="$1"

  cat > "$fake_root/bin/jq" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

for arg in "$@"; do
  if [[ "$arg" == *"structured_output.mode"* ]]; then
    exit 127
  fi
done

exec "$REAL_JQ_BIN" "$@"
EOF
  chmod +x "$fake_root/bin/jq"
}

run_mode_stamping_case() {
  local case_name="$1"
  local runner_mode="$2"
  local review_output="$3"
  local expected_mode="$4"
  local fail_jq_stamp="${5:-false}"
  local fake_root tmpdir output

  fake_root="$(make_fake_claude_root)"
  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  mkdir -p "$fake_root/bin"
  printf 'review artifact\n' > "$tmpdir/claude-review-artifact.txt"

  if [ "$fail_jq_stamp" = "true" ] && [ -n "$REAL_JQ" ]; then
    write_fake_jq_stamp_failure "$fake_root"
  fi
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
  prompt="$(cat)"
  if [[ "$prompt" == *"Codex Claude skill preflight probe"* ]]; then
    printf '{"ok":true}\n'
    exit 0
  fi

  printf '%s\n' "$FAKE_CLAUDE_REVIEW_OUTPUT"
  exit 0
fi

printf 'unexpected fake claude args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/claude"

  output="$(
    cd "$REPO_ROOT"
    PATH="$fake_root/bin:$PATH" \
      REAL_JQ_BIN="$REAL_JQ" \
      REAL_PYTHON_BIN="$PYTHON_BIN" \
      FAKE_CLAUDE_REVIEW_OUTPUT="$review_output" \
      bash --noprofile --norc -p scripts/run-review.sh \
        --mode "$runner_mode" \
        --artifact-file "$tmpdir/claude-review-artifact.txt" \
        --base-prompt prompts/code-review.base.md \
        --schema-file schemas/review-output.json \
        --repo-root "$REPO_ROOT" \
        --branch test \
        --base-branch main
  )" || {
    rm -rf "$fake_root" "$tmpdir"
    fail "$case_name exited non-zero"
  }

  assert_result_mode "$case_name" "$output" "clean" "$expected_mode"

  rm -rf "$fake_root" "$tmpdir"
  printf 'ok: %s\n' "$case_name"
}

run_mode_stamping_blocked_case() {
  local fake_root tmpdir output

  fake_root="$(make_fake_claude_root)"
  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  mkdir -p "$fake_root/bin"
  printf 'review artifact\n' > "$tmpdir/claude-review-artifact.txt"

  if [ -n "$REAL_JQ" ]; then
    write_fake_jq_stamp_failure "$fake_root"
  fi
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
  prompt="$(cat)"
  if [[ "$prompt" == *"Codex Claude skill preflight probe"* ]]; then
    printf '{"ok":true}\n'
    exit 0
  fi

  printf 'not-json\n'
  exit 0
fi

printf 'unexpected fake claude args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/claude"

  output="$(
    cd "$REPO_ROOT"
    PATH="$fake_root/bin:$PATH" \
      REAL_JQ_BIN="$REAL_JQ" \
      REAL_PYTHON_BIN="$PYTHON_BIN" \
      bash --noprofile --norc -p scripts/run-review.sh \
        --mode challenge_code \
        --artifact-file "$tmpdir/claude-review-artifact.txt" \
        --base-prompt prompts/code-review.base.md \
        --schema-file schemas/review-output.json \
        --repo-root "$REPO_ROOT" \
        --branch test \
        --base-branch main
  )" || {
    rm -rf "$fake_root" "$tmpdir"
    fail "mode stamping blocked fallback exited non-zero"
  }

  if ! assert_blocked_result "mode stamping blocked fallback" "$output" "could not safely stamp" "Install jq or a trusted python3" ""; then
    rm -rf "$fake_root" "$tmpdir"
    fail "mode stamping blocked fallback assertion failed"
  fi

  rm -rf "$fake_root" "$tmpdir"
  printf 'ok: mode stamping blocked fallback\n'
}

run_artifact_boundary_case() {
  local tmpdir output

  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  printf 'review artifact\n' > "$tmpdir/not-review-artifact.txt"

  output="$(
    cd "$REPO_ROOT"
    bash --noprofile --norc -p scripts/run-review.sh \
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
  if ! assert_doctor_offer_state "artifact boundary" "$output" "false"; then
    rm -rf "$tmpdir"
    fail "artifact boundary doctor-offer assertion failed"
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
    bash --noprofile --norc -p scripts/run-review.sh \
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
  if ! assert_doctor_offer_state "config boundary" "$output" "false"; then
    rm -rf "$tmpdir"
    fail "config boundary doctor-offer assertion failed"
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
      bash --noprofile --norc -p scripts/run-review.sh \
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

  fake_root="$(make_fake_claude_root)"
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
  prompt="$(cat)"
  if [[ "$prompt" == *"Codex Claude skill preflight probe"* ]]; then
    printf '{"ok":true}\n'
    exit 0
  fi

  if [[ "$prompt" != *"review artifact"* ]]; then
    printf 'fake claude did not receive the artifact on stdin\n' >&2
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
      bash --noprofile --norc -p scripts/run-review.sh \
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
  printf 'ok: timeout wrapper streams prompt on stdin\n'
}

run_probe_timeout_case() {
  local fake_root tmpdir output

  fake_root="$(make_fake_claude_root)"
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
  prompt="$(cat)"
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
      bash --noprofile --norc -p scripts/run-review.sh \
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
  if ! assert_doctor_offer_state "probe timeout" "$output" "true"; then
    rm -rf "$fake_root" "$tmpdir"
    fail "probe timeout doctor-offer assertion failed"
  fi

  rm -rf "$fake_root" "$tmpdir"
  printf 'ok: probe timeout\n'
}

run_timeout_process_group_case() {
  case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*)
      printf 'ok: timeout process group skipped on Windows\n'
      return 0
      ;;
  esac

  local fake_root tmpdir output child_pid attempt

  fake_root="$(make_fake_claude_root)"
  tmpdir="$(mktemp -d /tmp/claude-review-test-XXXXXX)"
  mkdir -p "$fake_root/bin"
  printf 'review artifact\n' > "$tmpdir/claude-review-artifact.txt"

  cat > "$fake_root/bin/claude" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
  (
    trap '' TERM
    while :; do sleep 1; done
  ) &
  child_pid="$!"
  printf '%s\n' "$child_pid" > "${FAKE_CLAUDE_CHILD_PID_FILE:?}"
  wait "$child_pid"
fi

printf 'unexpected fake claude args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/claude"

  output="$(
    cd "$REPO_ROOT"
    PATH="$fake_root/bin:$PATH" \
      LIVE_PROBE_TIMEOUT_SECONDS=1 \
      FAKE_CLAUDE_CHILD_PID_FILE="$tmpdir/child.pid" \
      bash --noprofile --norc -p scripts/run-review.sh \
        --mode code \
        --artifact-file "$tmpdir/claude-review-artifact.txt" \
        --base-prompt prompts/code-review.base.md \
        --schema-file schemas/review-output.json \
        --repo-root "$REPO_ROOT" \
        --branch test \
        --base-branch main
  )" || {
    rm -rf "$fake_root" "$tmpdir"
    fail "timeout process group case exited non-zero"
  }

  if ! assert_blocked_result "timeout process group" "$output" "version check timed out after 1s" "LIVE_PROBE_TIMEOUT_SECONDS" ""; then
    rm -rf "$fake_root" "$tmpdir"
    fail "timeout process group assertion failed"
  fi
  [ -s "$tmpdir/child.pid" ] || {
    rm -rf "$fake_root" "$tmpdir"
    fail "timeout process group child PID was not recorded"
  }
  child_pid="$(cat "$tmpdir/child.pid")"
  for ((attempt = 0; attempt < 50; attempt++)); do
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
    rm -rf "$fake_root" "$tmpdir"
    fail "timeout left descendant process $child_pid running"
  fi

  rm -rf "$fake_root" "$tmpdir"
  printf 'ok: timeout terminates the Claude process group\n'
}

run_review_cancellation_case() {
  case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*)
      printf 'ok: review cancellation propagation skipped on Windows\n'
      return 0
      ;;
  esac

  local fake_root tmpdir runner_pid driver_pid child_pid runner_status attempt

  fake_root="$(make_fake_claude_root)"
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
  prompt="$(cat)"
  if [[ "$prompt" == *"Codex Claude skill preflight probe"* ]]; then
    printf '{"ok":true}\n'
    exit 0
  fi
  printf '%s\n' "$PPID" > "${FAKE_CLAUDE_DRIVER_PID_FILE:?}"
  printf '%s\n' "$$" > "${FAKE_CLAUDE_CHILD_PID_FILE:?}"
  while :; do sleep 1; done
fi

printf 'unexpected fake claude args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/claude"

  (
    cd "$REPO_ROOT"
    exec /usr/bin/env \
      PATH="$fake_root/bin:$PATH" \
      FAKE_CLAUDE_DRIVER_PID_FILE="$tmpdir/driver.pid" \
      FAKE_CLAUDE_CHILD_PID_FILE="$tmpdir/child.pid" \
      REVIEW_TIMEOUT_SECONDS=30 \
      BASH_ENV= \
      ENV= \
      LD_PRELOAD= \
      LD_AUDIT= \
      LD_LIBRARY_PATH= \
      GCONV_PATH= \
      DYLD_INSERT_LIBRARIES= \
      DYLD_LIBRARY_PATH= \
      DYLD_FRAMEWORK_PATH= \
      DYLD_FALLBACK_LIBRARY_PATH= \
      DYLD_FALLBACK_FRAMEWORK_PATH= \
      DYLD_FORCE_FLAT_NAMESPACE= \
      DYLD_IMAGE_SUFFIX= \
      DYLD_ROOT_PATH= \
      /bin/bash --noprofile --norc -p scripts/run-review.sh \
        --mode code \
        --artifact-file "$tmpdir/claude-review-artifact.txt" \
        --base-prompt prompts/code-review.base.md \
        --schema-file schemas/review-output.json \
        --repo-root "$REPO_ROOT" \
        --branch test \
        --base-branch main
  ) >"$tmpdir/output" 2>"$tmpdir/error" &
  runner_pid=$!

  for ((attempt = 0; attempt < 100; attempt++)); do
    [ -s "$tmpdir/driver.pid" ] && [ -s "$tmpdir/child.pid" ] && break
    sleep 0.05
  done
  if [ ! -s "$tmpdir/driver.pid" ] || [ ! -s "$tmpdir/child.pid" ]; then
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    rm -rf "$fake_root" "$tmpdir"
    fail "review cancellation process IDs were not recorded"
  fi

  driver_pid="$(cat "$tmpdir/driver.pid")"
  child_pid="$(cat "$tmpdir/child.pid")"
  kill -TERM "$runner_pid"
  set +e
  wait "$runner_pid"
  runner_status=$?
  set -e

  if [ "$runner_status" -ne 143 ]; then
    rm -rf "$fake_root" "$tmpdir"
    fail "run-review did not propagate cancellation (status=$runner_status)"
  fi
  if grep -Fq 'Run /claude-review doctor now?' "$tmpdir/output" || \
    grep -Fq '"status":"blocked"' "$tmpdir/output"; then
    rm -rf "$fake_root" "$tmpdir"
    fail "run-review converted cancellation into blocked recovery UX"
  fi
  if kill -0 "$driver_pid" 2>/dev/null; then
    kill -KILL "$driver_pid" 2>/dev/null || true
    rm -rf "$fake_root" "$tmpdir"
    fail "top-level review cancellation left runtime driver $driver_pid running"
  fi
  for ((attempt = 0; attempt < 50; attempt++)); do
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
    rm -rf "$fake_root" "$tmpdir"
    fail "review cancellation left Claude child $child_pid running"
  fi

  rm -rf "$fake_root" "$tmpdir"
  printf 'ok: top-level review cancellation cleans the process tree without recovery UX\n'
}

run_safe_mode_args_case() {
  local fake_root tmpdir output arg_log

  fake_root="$(make_fake_claude_root)"
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
  prompt="$(cat)"
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
      bash --noprofile --norc -p scripts/run-review.sh \
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

run_schema_challenge_modes_case
run_mode_stamping_case \
  "challenge_code accepted and stamped" \
  "challenge_code" \
  '{"status":"clean","mode":"challenge_code","summary":"ok","findings":[],"open_questions":[]}' \
  "challenge_code"
run_mode_stamping_case \
  "challenge_plan accepted and stamped" \
  "challenge_plan" \
  '{"status":"clean","mode":"challenge_plan","summary":"ok","findings":[],"open_questions":[]}' \
  "challenge_plan"
run_mode_stamping_case \
  "direct json mode stamping" \
  "challenge_code" \
  '{"status":"clean","mode":"code","summary":"ok","findings":[],"open_questions":[]}' \
  "challenge_code"
run_mode_stamping_case \
  "wrapped json mode stamping" \
  "challenge_plan" \
  '{"type":"result","structured_output":{"status":"clean","mode":"plan","summary":"ok","findings":[],"open_questions":[]}}' \
  "challenge_plan"
run_mode_stamping_case \
  "python mode stamping fallback" \
  "challenge_code" \
  '{"status":"clean","mode":"code","summary":"ok","findings":[],"open_questions":[]}' \
  "challenge_code" \
  "true"
run_mode_stamping_blocked_case

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
  "oauth_refresh.lock" \
  "" \
  "" \
  "" \
  "false"

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
  "$sandbox_summary" \
  "" \
  "" \
  "true"

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
  "$sandbox_summary" \
  "" \
  "" \
  "true"

run_case \
  "probe budget remains direct remediation" \
  "$(make_error_result "Error: reached maximum budget")" \
  0 \
  "" \
  0 \
  "preflight hit the CLI budget cap" \
  "Increase LIVE_PROBE_BUDGET_USD" \
  "" \
  "" \
  "" \
  "false"

run_case \
  "probe subscription auth offers doctor" \
  "$(make_error_result "Error: not logged in; run auth login")" \
  0 \
  "" \
  0 \
  "subscription auth is unavailable" \
  "claude auth login --claudeai" \
  "" \
  "" \
  "" \
  "true"

run_case \
  "probe timeout outranks partial auth output" \
  "$(make_error_result "Error: not logged in; run auth login")" \
  124 \
  "" \
  0 \
  "preflight timed out" \
  "increasing LIVE_PROBE_TIMEOUT_SECONDS" \
  "subscription auth is unavailable" \
  "" \
  "" \
  "true"

run_case \
  "non-first-party auth is rejected" \
  "" \
  0 \
  "" \
  0 \
  "authenticated through Anthropic Console" \
  "claude auth login --claudeai" \
  "" \
  "" \
  "" \
  "true" \
  '{"loggedIn":true,"apiProvider":"console"}'

run_case \
  "version preflight timeout is bounded" \
  "" \
  0 \
  "" \
  0 \
  "version check timed out after 1s" \
  "increasing LIVE_PROBE_TIMEOUT_SECONDS" \
  "" \
  "" \
  "" \
  "true" \
  "" \
  "version"

run_case \
  "auth status timeout is bounded" \
  "" \
  0 \
  "" \
  0 \
  "auth status timed out after 1s" \
  "increasing LIVE_PROBE_TIMEOUT_SECONDS" \
  "" \
  "" \
  "" \
  "true" \
  "" \
  "auth"

run_case \
  "review timeout preserves remediation" \
  '{"ok":true}' \
  0 \
  "" \
  124 \
  "after 2 attempt(s)" \
  "/claude-review set timeout <seconds>" \
  "" \
  "" \
  "" \
  "false"

run_case \
  "review budget preserves cap and remediation" \
  '{"ok":true}' \
  0 \
  "Error: reached maximum budget" \
  1 \
  'budget cap ($5.00)' \
  "/claude-review set budget <usd>" \
  "" \
  "" \
  "" \
  "false"

run_case \
  "runtime API-key auth path is rejected" \
  '{"ok":true}' \
  0 \
  "ANTHROPIC_API_KEY is set" \
  1 \
  "API-key-style auth path" \
  "Remove Anthropic API credential env vars" \
  "" \
  "" \
  "" \
  "true"

run_case \
  "generic invocation offers doctor" \
  '{"ok":true}' \
  0 \
  "unclassified runtime child failure" \
  9 \
  "invocation failed" \
  "Inspect the Claude CLI output" \
  "" \
  "" \
  "" \
  "true"

run_case \
  "runtime claude dir EPERM" \
  '{"ok":true}' \
  0 \
  "$(make_error_result "Error: EPERM: operation not permitted, mkdir '$HOME/.claude/.oauth_refresh.lock'")" \
  0 \
  "$sandbox_summary" \
  "oauth_refresh.lock" \
  "$generic_runtime_summary" \
  "" \
  "" \
  "false"

run_artifact_boundary_case
run_config_boundary_case
run_unsafe_claude_candidate_case
run_timeout_wrapper_closes_stdin_case
run_probe_timeout_case
run_timeout_process_group_case
run_review_cancellation_case
run_safe_mode_args_case
rm -f "$evil_shell"
