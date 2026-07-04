#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="$(command -v python3)"
TMP_ROOT="$(mktemp -d /tmp/claude-review-artifact-size-XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_json_status() {
  local case_name="$1"
  local output="$2"
  local expected_status="$3"
  local expected_summary="$4"

  OUTPUT_JSON="$output" CASE_NAME="$case_name" EXPECTED_STATUS="$expected_status" EXPECTED_SUMMARY="$expected_summary" "$PYTHON_BIN" - <<'PY'
import json
import os
import sys

case_name = os.environ["CASE_NAME"]
expected_status = os.environ["EXPECTED_STATUS"]
expected_summary = os.environ["EXPECTED_SUMMARY"]

try:
    data = json.loads(os.environ["OUTPUT_JSON"])
except Exception as exc:
    print(f"{case_name}: output was not JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if data.get("status") != expected_status:
    print(f"{case_name}: expected status {expected_status!r}, got {data.get('status')!r}", file=sys.stderr)
    sys.exit(1)

summary = data.get("summary", "")
if expected_summary not in summary:
    print(f"{case_name}: expected summary to contain {expected_summary!r}, got {summary!r}", file=sys.stderr)
    sys.exit(1)
PY
}

make_review_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "codex@example.test"
  git -C "$repo" config user.name "Codex Test"
  git -C "$repo" checkout -q -b main
  mkdir -p "$repo/src" "$repo/tests"
  printf 'base\n' > "$repo/src/base.txt"
  printf 'base test\n' > "$repo/tests/base.test.txt"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "base"
  git -C "$repo" checkout -q -b review

  "$PYTHON_BIN" - "$repo" <<'PY'
from pathlib import Path
import sys

repo = Path(sys.argv[1])
for index in range(6):
    path = repo / "src" / f"changed_{index}.txt"
    path.write_text(
        "".join(
            f"changed-file-{index:02d}-line-{line:04d} "
            f"{'x' * 72}\n"
            for line in range(520)
        ),
        encoding="utf-8",
    )

(repo / "tests" / "changed.test.txt").write_text(
    "".join(f"changed-test-line-{line:04d} {'t' * 72}\n" for line in range(80)),
    encoding="utf-8",
)
PY
  git -C "$repo" add .
}

make_small_review_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "codex@example.test"
  git -C "$repo" config user.name "Codex Test"
  git -C "$repo" checkout -q -b main
  mkdir -p "$repo/src"
  printf 'base\n' > "$repo/src/base.txt"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "base"
  git -C "$repo" checkout -q -b review
  printf 'small change\n' > "$repo/src/small.txt"
  git -C "$repo" add .
}

make_huge_single_file_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "codex@example.test"
  git -C "$repo" config user.name "Codex Test"
  git -C "$repo" checkout -q -b main
  mkdir -p "$repo/src"
  printf 'base\n' > "$repo/src/base.txt"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "base"
  git -C "$repo" checkout -q -b review

  "$PYTHON_BIN" - "$repo/src/huge.txt" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    "".join(f"huge-file-line-{line:04d} {'h' * 72}\n" for line in range(5200)),
    encoding="utf-8",
)
PY
  git -C "$repo" add .
}

make_huge_header_like_body_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "codex@example.test"
  git -C "$repo" config user.name "Codex Test"
  git -C "$repo" checkout -q -b main
  mkdir -p "$repo/src"

  "$PYTHON_BIN" - "$repo/src/sql.txt" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    "".join(f"-- removed-comment-{line:04d} {'r' * 72}\n" for line in range(5200)),
    encoding="utf-8",
)
PY
  git -C "$repo" add .
  git -C "$repo" commit -q -m "base"
  git -C "$repo" checkout -q -b review

  "$PYTHON_BIN" - "$repo/src/sql.txt" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    "".join(f"replacement-line-{line:04d} {'a' * 72}\n" for line in range(5200)),
    encoding="utf-8",
)
PY
  git -C "$repo" add .
}

make_wide_metadata_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "codex@example.test"
  git -C "$repo" config user.name "Codex Test"
  git -C "$repo" checkout -q -b main
  mkdir -p "$repo/src/wide"
  printf 'base\n' > "$repo/src/base.txt"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "base"
  git -C "$repo" checkout -q -b review

  "$PYTHON_BIN" - "$repo" <<'PY'
from pathlib import Path
import sys

repo = Path(sys.argv[1])
suffix = "x" * 120
for index in range(90):
    path = repo / "src" / "wide" / f"component_{index:04d}_{suffix}.txt"
    path.write_text(f"wide-file-{index:04d}\n", encoding="utf-8")
PY
  git -C "$repo" add .
}

make_mid_metadata_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "codex@example.test"
  git -C "$repo" config user.name "Codex Test"
  git -C "$repo" checkout -q -b main
  mkdir -p "$repo/src/mid"
  printf 'base\n' > "$repo/src/base.txt"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "base"
  git -C "$repo" checkout -q -b review

  "$PYTHON_BIN" - "$repo" <<'PY'
from pathlib import Path
import sys

repo = Path(sys.argv[1])
suffix = "m" * 90
for index in range(45):
    path = repo / "src" / "mid" / f"component_{index:04d}_{suffix}.txt"
    path.write_text(f"mid-file-{index:04d}\n", encoding="utf-8")
PY
  git -C "$repo" add .
}

make_rename_review_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "codex@example.test"
  git -C "$repo" config user.name "Codex Test"
  git -C "$repo" checkout -q -b main
  mkdir -p "$repo/src"

  "$PYTHON_BIN" - "$repo/src/old.txt" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    "".join(f"stable-line-{line:04d} {'s' * 64}\n" for line in range(260)),
    encoding="utf-8",
)
PY
  git -C "$repo" add .
  git -C "$repo" commit -q -m "base"
  git -C "$repo" checkout -q -b review
  git -C "$repo" mv src/old.txt src/new.txt

  "$PYTHON_BIN" - "$repo/src/new.txt" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
with path.open("a", encoding="utf-8") as handle:
    for line in range(90):
        handle.write(f"added-line-{line:04d} {'a' * 64}\n")
PY
  git -C "$repo" add .
}

run_runner_limit_case() {
  local tmpdir output

  tmpdir="$TMP_ROOT/runner"
  mkdir -p "$tmpdir"
  "$PYTHON_BIN" - "$tmpdir/claude-review-large.txt" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text("x" * 200001, encoding="utf-8")
PY

  output="$(
    cd "$REPO_ROOT"
    bash scripts/run-review.sh \
      --mode code \
      --artifact-file "$tmpdir/claude-review-large.txt" \
      --base-prompt prompts/code-review.base.md \
      --schema-file schemas/review-output.json \
      --repo-root "$REPO_ROOT" \
      --branch test \
      --base-branch main
  )" || fail "runner limit exited non-zero"

  assert_json_status "runner limit" "$output" "needs_context" "200001 bytes > 200000 bytes"
  printf 'ok: runner rejects artifacts above 200000 bytes\n'
}

run_runner_invalid_limit_case() {
  local tmpdir output

  tmpdir="$TMP_ROOT/runner-invalid-limit"
  mkdir -p "$tmpdir"
  printf 'small artifact\n' > "$tmpdir/claude-review-small.txt"

  output="$(
    cd "$REPO_ROOT"
    CLAUDE_REVIEW_MAX_ARTIFACT_BYTES=00 bash scripts/run-review.sh \
      --mode code \
      --artifact-file "$tmpdir/claude-review-small.txt" \
      --base-prompt prompts/code-review.base.md \
      --schema-file schemas/review-output.json \
      --repo-root "$REPO_ROOT" \
      --branch test \
      --base-branch main
  )" || fail "runner invalid limit exited non-zero"

  assert_json_status "runner invalid limit" "$output" "blocked" "Invalid CLAUDE_REVIEW_MAX_ARTIFACT_BYTES: 00"
  printf 'ok: runner reports invalid artifact limit as JSON\n'
}

run_runner_split_header_limit_case() {
  local tmpdir artifact_file output

  tmpdir="$TMP_ROOT/runner-split-header-limit"
  mkdir -p "$tmpdir"
  artifact_file="$tmpdir/claude-review-split-part.txt"

  "$PYTHON_BIN" - "$artifact_file" <<'PY'
from pathlib import Path
import sys

header = """Review Artifact Split Part
==========================
Mode: code
Split part: 1
Full artifact bytes: 240000
Max bytes per review artifact: 250000

"""
target_size = 210000
Path(sys.argv[1]).write_text(header + ("x" * (target_size - len(header))), encoding="utf-8")
PY

  output="$(
    cd "$REPO_ROOT"
    bash scripts/run-review.sh \
      --mode code \
      --artifact-file "$artifact_file" \
      --base-prompt prompts/code-review.base.md \
      --schema-file schemas/review-output.json \
      --repo-root "$REPO_ROOT" \
      --branch test \
      --base-branch main
  )" || {
    fail "runner split header limit exited non-zero"
  }

  assert_json_status "runner split header limit" "$output" "needs_context" "higher CLAUDE_REVIEW_MAX_ARTIFACT_BYTES than the review step"
  printf 'ok: runner ignores split artifact header byte cap\n'
}

run_runner_split_header_cap_ceiling_case() {
  local tmpdir artifact_file output

  tmpdir="$TMP_ROOT/runner-split-header-cap-ceiling"
  mkdir -p "$tmpdir"
  artifact_file="$tmpdir/claude-review-oversized-split-part.txt"

  "$PYTHON_BIN" - "$artifact_file" <<'PY'
from pathlib import Path
import sys

header = """Review Artifact Split Part
==========================
Mode: code
Split part: 1
Full artifact bytes: 999999999
Max bytes per review artifact: 999999999

"""
target_size = 400001
Path(sys.argv[1]).write_text(header + ("x" * (target_size - len(header))), encoding="utf-8")
PY

  output="$(
    cd "$REPO_ROOT"
    bash scripts/run-review.sh \
      --mode code \
      --artifact-file "$artifact_file" \
      --base-prompt prompts/code-review.base.md \
      --schema-file schemas/review-output.json \
      --repo-root "$REPO_ROOT" \
      --branch test \
      --base-branch main
  )" || fail "runner split header cap ceiling exited non-zero"

  assert_json_status "runner split header cap ceiling" "$output" "needs_context" "higher CLAUDE_REVIEW_MAX_ARTIFACT_BYTES than the review step"
  printf 'ok: runner rejects absurd split artifact header byte caps\n'
}

run_artifact_limit_validation_case() {
  local stderr_file stdout_file split_parts_stderr split_parts_stdout

  stderr_file="$TMP_ROOT/invalid-limit.stderr"
  stdout_file="$TMP_ROOT/valid-leading-zero-limit.stdout"
  split_parts_stderr="$TMP_ROOT/invalid-split-parts.stderr"
  split_parts_stdout="$TMP_ROOT/valid-leading-zero-split-parts.stdout"

  if CLAUDE_REVIEW_MAX_ARTIFACT_BYTES=00 bash "$REPO_ROOT/scripts/build-review-artifact.sh" --help \
    > "$TMP_ROOT/invalid-limit.stdout" \
    2>"$stderr_file"; then
    fail "artifact limit accepted zero-valued leading-zero input"
  fi
  grep -Fq "Invalid CLAUDE_REVIEW_MAX_ARTIFACT_BYTES: 00" "$stderr_file" || fail "artifact limit did not report the original invalid value"

  CLAUDE_REVIEW_MAX_ARTIFACT_BYTES=0200000 bash "$REPO_ROOT/scripts/build-review-artifact.sh" --help > "$stdout_file"
  grep -Fq "Usage:" "$stdout_file" || fail "artifact limit rejected positive leading-zero input"

  if CLAUDE_REVIEW_MAX_SPLIT_PARTS=00 bash "$REPO_ROOT/scripts/build-review-artifact.sh" --help \
    > "$TMP_ROOT/invalid-split-parts.stdout" \
    2>"$split_parts_stderr"; then
    fail "artifact limit accepted zero-valued split part input"
  fi
  grep -Fq "Invalid CLAUDE_REVIEW_MAX_SPLIT_PARTS: 00" "$split_parts_stderr" || fail "artifact limit did not report invalid split part value"

  CLAUDE_REVIEW_MAX_SPLIT_PARTS=012 bash "$REPO_ROOT/scripts/build-review-artifact.sh" --help > "$split_parts_stdout"
  grep -Fq "Usage:" "$split_parts_stdout" || fail "artifact limit rejected positive leading-zero split part input"

  printf 'ok: artifact limit validates zero-valued inputs\n'
}

run_builder_requires_split_dir_case() {
  local repo output_file stderr_file

  repo="$TMP_ROOT/requires-split"
  make_review_repo "$repo"
  output_file="$TMP_ROOT/claude-review-full.txt"
  stderr_file="$TMP_ROOT/requires-split.stderr"

  if bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    2>"$stderr_file"; then
    fail "builder unexpectedly accepted oversized artifact without split dir"
  fi

  grep -Fq "200000" "$stderr_file" || fail "builder error did not mention 200000-byte cap"
  grep -Fq -- "--split-output-dir" "$stderr_file" || fail "builder error did not recommend split output dir"
  [ "$(wc -c < "$output_file" | tr -d '[:space:]')" -gt 200000 ] || fail "full artifact was not left untruncated"
  ! grep -Fq "artifact truncated" "$output_file" || fail "builder still wrote truncation marker"
  grep -Fq "changed-file-05-line-0519" "$output_file" || fail "full artifact is missing tail diff content"

  printf 'ok: builder refuses oversized artifact without truncating\n'
}

run_builder_rejects_reused_split_dir_case() {
  local repo output_file split_dir stderr_file

  repo="$TMP_ROOT/reused-split-dir"
  make_small_review_repo "$repo"
  output_file="$TMP_ROOT/claude-review-reused-split-dir.txt"
  split_dir="$TMP_ROOT/claude-review-reused-split"
  stderr_file="$TMP_ROOT/reused-split-dir.stderr"
  mkdir -p "$split_dir"
  printf 'prior manifest\n' > "$split_dir/manifest.txt"
  printf 'prior part\n' > "$split_dir/claude-review-part-001.txt"

  if bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/reused-split-dir.stdout" \
    2>"$stderr_file"; then
    fail "builder unexpectedly accepted a reused split output directory"
  fi

  grep -Fq "use a fresh --split-output-dir" "$stderr_file" || fail "builder did not explain reused split directory rejection"
  grep -Fq "prior manifest" "$split_dir/manifest.txt" || fail "builder clobbered reused split manifest"
  grep -Fq "prior part" "$split_dir/claude-review-part-001.txt" || fail "builder clobbered reused split part"
  [ ! -e "$split_dir/.claude-review-build.lock" ] || fail "builder left lock after rejecting reused split directory"

  printf 'ok: builder rejects reused split output dirs without clobbering parts\n'
}

run_builder_rejects_whitespace_split_dir_case() {
  local repo output_file split_dir stderr_file

  repo="$TMP_ROOT/whitespace-split-dir"
  make_small_review_repo "$repo"
  output_file="$TMP_ROOT/claude-review-whitespace-split-dir.txt"
  split_dir="$TMP_ROOT/claude-review-space dir"
  stderr_file="$TMP_ROOT/whitespace-split-dir.stderr"

  if bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/whitespace-split-dir.stdout" \
    2>"$stderr_file"; then
    fail "builder unexpectedly accepted whitespace in split output directory"
  fi

  grep -Fq "Split output directory must not contain whitespace" "$stderr_file" || fail "builder did not explain whitespace split directory rejection"

  printf 'ok: builder rejects whitespace split output dirs\n'
}

run_builder_rejects_locked_split_dir_case() {
  local repo output_file split_dir stderr_file

  repo="$TMP_ROOT/locked-split-dir"
  make_small_review_repo "$repo"
  output_file="$TMP_ROOT/claude-review-locked-split-dir.txt"
  split_dir="$TMP_ROOT/claude-review-locked-split"
  stderr_file="$TMP_ROOT/locked-split-dir.stderr"
  mkdir -p "$split_dir/.claude-review-build.lock"
  printf '%s\n' "$$" > "$split_dir/.claude-review-build.lock/pid"

  if bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/locked-split-dir.stdout" \
    2>"$stderr_file"; then
    fail "builder unexpectedly accepted an already-locked split output directory"
  fi

  grep -Fq "Split output directory is already in use" "$stderr_file" || fail "builder did not explain locked split output directory rejection"

  printf 'ok: builder rejects locked split output dirs\n'
}

run_builder_recovers_stale_split_lock_case() {
  local repo output_file split_dir output_bytes

  repo="$TMP_ROOT/stale-lock-split-dir"
  make_small_review_repo "$repo"
  output_file="$TMP_ROOT/claude-review-stale-lock-split-dir.txt"
  split_dir="$TMP_ROOT/claude-review-stale-lock-split"
  mkdir -p "$split_dir/.claude-review-build.lock"
  printf '999999\n' > "$split_dir/.claude-review-build.lock/pid"

  bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/stale-lock-split-dir.stdout"

  output_bytes="$(wc -c < "$output_file" | tr -d '[:space:]')"
  [ "$output_bytes" -le 200000 ] || fail "small artifact unexpectedly exceeded cap after stale lock recovery"
  [ ! -e "$split_dir/.claude-review-build.lock" ] || fail "builder left lock after stale lock recovery"
  ! grep -Fq "ARTIFACT_SPLIT true" "$TMP_ROOT/stale-lock-split-dir.stdout" || fail "small artifact incorrectly reported split output after stale lock recovery"

  printf 'ok: builder recovers stale split output locks\n'
}

run_builder_rejects_old_live_pid_lock_case() {
  local repo output_file split_dir stderr_file

  repo="$TMP_ROOT/old-live-pid-lock-split-dir"
  make_small_review_repo "$repo"
  output_file="$TMP_ROOT/claude-review-old-live-pid-lock-split-dir.txt"
  split_dir="$TMP_ROOT/claude-review-old-live-pid-lock-split"
  stderr_file="$TMP_ROOT/old-live-pid-lock-split-dir.stderr"
  mkdir -p "$split_dir/.claude-review-build.lock"
  printf '%s\n' "$$" > "$split_dir/.claude-review-build.lock/pid"
  touch -t 200001010000 "$split_dir/.claude-review-build.lock"
  touch -t 200001010000 "$split_dir/.claude-review-build.lock/pid"

  if CLAUDE_REVIEW_SPLIT_LOCK_STALE_SECONDS=1 bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/old-live-pid-lock-split-dir.stdout" \
    2>"$stderr_file"; then
    fail "builder unexpectedly stole an old lock from a live pid"
  fi

  grep -Fq "Split output directory is already in use" "$stderr_file" || fail "builder did not reject old live-pid lock as in use"
  [ -e "$split_dir/.claude-review-build.lock" ] || fail "builder removed a live-pid lock"

  printf 'ok: builder rejects old live-pid split output locks\n'
}

run_builder_recovers_stale_reaper_case() {
  local repo output_file split_dir output_bytes

  repo="$TMP_ROOT/stale-reaper-split-dir"
  make_small_review_repo "$repo"
  output_file="$TMP_ROOT/claude-review-stale-reaper-split-dir.txt"
  split_dir="$TMP_ROOT/claude-review-stale-reaper-split"
  mkdir -p "$split_dir/.claude-review-build.lock/reaper"
  printf '999999\n' > "$split_dir/.claude-review-build.lock/pid"
  touch -t 200001010000 "$split_dir/.claude-review-build.lock/reaper"

  bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/stale-reaper-split-dir.stdout"

  output_bytes="$(wc -c < "$output_file" | tr -d '[:space:]')"
  [ "$output_bytes" -le 200000 ] || fail "small artifact unexpectedly exceeded cap after stale reaper recovery"
  [ ! -e "$split_dir/.claude-review-build.lock" ] || fail "builder left lock after stale reaper recovery"
  ! grep -Fq "ARTIFACT_SPLIT true" "$TMP_ROOT/stale-reaper-split-dir.stdout" || fail "small artifact incorrectly reported split output after stale reaper recovery"

  printf 'ok: builder recovers stale split lock reapers\n'
}

run_builder_allows_one_stale_lock_recoverer_case() {
  local repo split_dir output_a output_b stderr_a stderr_b status_a status_b success_count failure_output part_count
  local pid_a pid_b

  repo="$TMP_ROOT/stale-lock-race"
  make_review_repo "$repo"
  split_dir="$TMP_ROOT/claude-review-stale-lock-race"
  output_a="$TMP_ROOT/claude-review-stale-lock-race-a.txt"
  output_b="$TMP_ROOT/claude-review-stale-lock-race-b.txt"
  stderr_a="$TMP_ROOT/stale-lock-race-a.stderr"
  stderr_b="$TMP_ROOT/stale-lock-race-b.stderr"
  mkdir -p "$split_dir/.claude-review-build.lock"
  printf '999999\n' > "$split_dir/.claude-review-build.lock/pid"

  set +e
  bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_a" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/stale-lock-race-a.stdout" \
    2>"$stderr_a" &
  pid_a=$!

  bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_b" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/stale-lock-race-b.stdout" \
    2>"$stderr_b" &
  pid_b=$!

  wait "$pid_a"
  status_a=$?
  wait "$pid_b"
  status_b=$?
  set -e

  success_count=0
  [ "$status_a" -eq 0 ] && success_count=$((success_count + 1))
  [ "$status_b" -eq 0 ] && success_count=$((success_count + 1))
  [ "$success_count" -eq 1 ] || fail "expected exactly one stale-lock recoverer to succeed, got $success_count (statuses $status_a/$status_b)"

  if [ "$status_a" -ne 0 ]; then
    failure_output="$(cat "$stderr_a")"
  else
    failure_output="$(cat "$stderr_b")"
  fi
  printf '%s' "$failure_output" | grep -Eq "Split output directory is already in use|use a fresh --split-output-dir" || fail "losing stale-lock recoverer did not explain the contention"

  [ -f "$split_dir/manifest.txt" ] || fail "winning stale-lock recoverer did not write a manifest"
  part_count="$(grep -c '^Part file:' "$split_dir/manifest.txt")"
  [ "$part_count" -ge 2 ] || fail "winning stale-lock recoverer wrote too few split parts: $part_count"
  [ ! -e "$split_dir/.claude-review-build.lock" ] || fail "winning stale-lock recoverer left a lock"

  printf 'ok: builder allows only one stale-lock recoverer\n'
}

run_builder_split_case() {
  local repo output_file split_dir manifest part_count part_file part_bytes combined_parts

  repo="$TMP_ROOT/split"
  make_review_repo "$repo"
  output_file="$TMP_ROOT/claude-review-full-split.txt"
  split_dir="$TMP_ROOT/claude-review-split"

  bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/split.stdout"

  manifest="$split_dir/manifest.txt"
  [ -f "$manifest" ] || fail "split manifest was not written"
  grep -Fq "Review Artifact Split Manifest" "$manifest" || fail "split manifest missing header"
  grep -Fq "Full artifact bytes:" "$manifest" || fail "split manifest missing full size"
  grep -Fq "Max bytes per review artifact: 200000" "$manifest" || fail "split manifest missing cap"
  grep -Fq "Max split parts: 12" "$manifest" || fail "split manifest missing max part count"
  grep -Fq "PART_FILE" "$TMP_ROOT/split.stdout" || fail "split stdout did not list part files"

  part_count="$(grep -c '^Part file:' "$manifest")"
  [ "$part_count" -ge 2 ] || fail "expected at least two split parts, got $part_count"

  combined_parts="$TMP_ROOT/combined-parts.txt"
  : > "$combined_parts"
  while IFS= read -r part_file; do
    part_bytes="$(wc -c < "$part_file" | tr -d '[:space:]')"
    [ "$part_bytes" -le 200000 ] || fail "split part exceeds 200000 bytes: $part_file"
    grep -Fq "Review Artifact Split Part" "$part_file" || fail "split part missing header: $part_file"
    grep -Fq "Repeated split scope metadata:" "$part_file" || fail "split part missing repeated scope metadata: $part_file"
    grep -Fq "Changed files:" "$part_file" || fail "split part missing repeated changed-files scope: $part_file"
    grep -Fq "Diff stat:" "$part_file" || fail "split part missing repeated diff stat: $part_file"
    ! grep -Fq "artifact truncated" "$part_file" || fail "split part contains truncation marker: $part_file"
    cat "$part_file" >> "$combined_parts"
  done < <(awk '/^Part file:/ { print $3 }' "$manifest")

  grep -Fq "changed-file-00-line-0000" "$combined_parts" || fail "split parts missing first diff content"
  grep -Fq "changed-file-05-line-0519" "$combined_parts" || fail "split parts missing tail diff content"
  grep -Fq "tests/changed.test.txt" "$combined_parts" || fail "split parts missing changed test file"

  printf 'ok: builder writes bounded split artifacts without truncation\n'
}

run_builder_max_split_parts_case() {
  local repo output_file split_dir stderr_file

  repo="$TMP_ROOT/max-split-parts"
  make_review_repo "$repo"
  output_file="$TMP_ROOT/claude-review-max-split-parts-full.txt"
  split_dir="$TMP_ROOT/claude-review-max-split-parts"
  stderr_file="$TMP_ROOT/max-split-parts.stderr"

  if CLAUDE_REVIEW_MAX_SPLIT_PARTS=1 bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/max-split-parts.stdout" \
    2>"$stderr_file"; then
    fail "builder unexpectedly exceeded the configured split part cap"
  fi

  grep -Fq "Review artifact split would create more than 1 parts" "$stderr_file" || fail "builder did not report max split part cap"
  grep -Fq "CLAUDE_REVIEW_MAX_SPLIT_PARTS" "$stderr_file" || fail "builder did not mention split part cap override"
  [ ! -e "$split_dir/manifest.txt" ] || fail "max split part abort left a manifest"
  [ -z "$(find "$split_dir" -maxdepth 1 -name 'claude-review-part-*.txt' -print)" ] || fail "max split part abort left orphaned part files"

  printf 'ok: builder caps split part fan-out\n'
}

run_builder_large_file_chunk_context_case() {
  local repo output_file split_dir manifest combined_parts part_file

  repo="$TMP_ROOT/huge-file"
  make_huge_single_file_repo "$repo"
  output_file="$TMP_ROOT/claude-review-huge-file-full.txt"
  split_dir="$TMP_ROOT/claude-review-huge-file-split"

  bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/huge-file.stdout"

  manifest="$split_dir/manifest.txt"
  [ -f "$manifest" ] || fail "huge file split manifest was not written"

  combined_parts="$TMP_ROOT/combined-huge-file-parts.txt"
  : > "$combined_parts"
  while IFS= read -r part_file; do
    cat "$part_file" >> "$combined_parts"
  done < <(awk '/^Part file:/ { print $3 }' "$manifest")

  grep -Fq "File diff: Working tree diff (HEAD): a/src/huge.txt b/src/huge.txt (chunk 2 of" "$combined_parts" || fail "huge file diff did not produce a second chunk"
  awk '
    BEGIN { found = 0; ok = 0 }
    /^File diff: Working tree diff \(HEAD\): a\/src\/huge\.txt b\/src\/huge\.txt \(chunk 2 of / { found = 1; next }
    found && /^File diff: / { found = 0 }
    found && /^@@ / { ok = 1 }
    END { exit (ok ? 0 : 1) }
  ' "$combined_parts" || fail "huge file continuation chunk is missing hunk context"

  "$PYTHON_BIN" - "$combined_parts" <<'PY' || fail "huge file continuation hunk header has the wrong line start"
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
lines = text.splitlines()
inside = False
header = None
body = None

for line in lines:
    if line.startswith("File diff: Working tree diff (HEAD): a/src/huge.txt b/src/huge.txt (chunk 2 of "):
        inside = True
        continue
    if inside and line.startswith("File diff: "):
        break
    if not inside:
        continue
    if header is None and line.startswith("@@ "):
        header = line
        continue
    if header is not None and line.startswith("+huge-file-line-"):
        body = line
        break

if header is None or body is None:
    raise SystemExit("missing continuation header or body line")

header_match = re.search(r" \+([0-9]+)(?:,|\s)", header)
body_match = re.search(r"huge-file-line-([0-9]+)", body)
if not header_match or not body_match:
    raise SystemExit(f"could not parse header/body: {header!r} {body!r}")

header_new_start = int(header_match.group(1))
body_new_line = int(body_match.group(1)) + 1
if header_new_start != body_new_line:
    raise SystemExit(f"expected new-line start {body_new_line}, got {header_new_start}: {header!r}")
PY

  printf 'ok: builder preserves hunk context in large-file continuation chunks\n'
}

run_builder_large_file_header_context_case() {
  local repo output_file split_dir manifest combined_parts part_file

  repo="$TMP_ROOT/header-like-body"
  make_huge_header_like_body_repo "$repo"
  output_file="$TMP_ROOT/claude-review-header-like-body-full.txt"
  split_dir="$TMP_ROOT/claude-review-header-like-body-split"

  bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/header-like-body.stdout"

  manifest="$split_dir/manifest.txt"
  [ -f "$manifest" ] || fail "header-like body split manifest was not written"

  combined_parts="$TMP_ROOT/combined-header-like-body-parts.txt"
  : > "$combined_parts"
  while IFS= read -r part_file; do
    cat "$part_file" >> "$combined_parts"
  done < <(awk '/^Part file:/ { print $3 }' "$manifest")

  grep -Fq "File diff: Working tree diff (HEAD): a/src/sql.txt b/src/sql.txt (chunk 2 of" "$combined_parts" || fail "header-like body diff did not produce a second chunk"
  awk '
    BEGIN { found = 0; before_hunk = 0; bad = 0 }
    /^File diff: Working tree diff \(HEAD\): a\/src\/sql\.txt b\/src\/sql\.txt \(chunk 2 of / { found = 1; before_hunk = 1; next }
    found && /^File diff: / { found = 0; before_hunk = 0 }
    found && /^@@ / { before_hunk = 0 }
    found && before_hunk && /^--- removed-comment-/ { bad = 1 }
    END { exit (bad ? 1 : 0) }
  ' "$combined_parts" || fail "header-like body line leaked into continuation file context"

  "$PYTHON_BIN" - "$combined_parts" <<'PY' || fail "header-like body continuation hunk header has the wrong old-line start"
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
lines = text.splitlines()
inside = False
header = None
body = None

for line in lines:
    if line.startswith("File diff: Working tree diff (HEAD): a/src/sql.txt b/src/sql.txt (chunk 2 of "):
        inside = True
        continue
    if inside and line.startswith("File diff: "):
        break
    if not inside:
        continue
    if header is None and line.startswith("@@ "):
        header = line
        continue
    if header is not None and line.startswith("--- removed-comment-"):
        body = line
        break

if header is None or body is None:
    raise SystemExit("missing continuation header or removed body line")

header_match = re.search(r"@@ -([0-9]+)(?:,|\s)", header)
body_match = re.search(r"removed-comment-([0-9]+)", body)
if not header_match or not body_match:
    raise SystemExit(f"could not parse header/body: {header!r} {body!r}")

header_old_start = int(header_match.group(1))
body_old_line = int(body_match.group(1)) + 1
if header_old_start != body_old_line:
    raise SystemExit(f"expected old-line start {body_old_line}, got {header_old_start}: {header!r}")
PY

  printf 'ok: builder keeps body lines out of continuation file context\n'
}

run_builder_wide_metadata_split_case() {
  local repo output_file split_dir manifest combined_parts part_file part_bytes last_path

  repo="$TMP_ROOT/wide-metadata"
  make_wide_metadata_repo "$repo"
  output_file="$TMP_ROOT/claude-review-wide-metadata-full.txt"
  split_dir="$TMP_ROOT/claude-review-wide-metadata-split"

  CLAUDE_REVIEW_MAX_ARTIFACT_BYTES=8000 CLAUDE_REVIEW_MAX_SPLIT_PARTS=40 bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/wide-metadata.stdout"

  manifest="$split_dir/manifest.txt"
  [ -f "$manifest" ] || fail "wide metadata split manifest was not written"

  combined_parts="$TMP_ROOT/combined-wide-metadata-parts.txt"
  : > "$combined_parts"
  while IFS= read -r part_file; do
    part_bytes="$(wc -c < "$part_file" | tr -d '[:space:]')"
    [ "$part_bytes" -le 8000 ] || fail "wide metadata split part exceeds 8000 bytes: $part_file"
    grep -Fq "Repeated split scope summary:" "$part_file" || fail "wide metadata split part missing repeated scope summary: $part_file"
    ! grep -Fq "artifact truncated" "$part_file" || fail "wide metadata split part contains truncation marker: $part_file"
    cat "$part_file" >> "$combined_parts"
  done < <(awk '/^Part file:/ { print $3 }' "$manifest")

  last_path="$("$PYTHON_BIN" - <<'PY'
suffix = "x" * 120
print(f"src/wide/component_0089_{suffix}.txt")
PY
)"

  grep -Fq "Changed files (chunk 2 of" "$combined_parts" || fail "wide changed-files metadata was not split into chunks"
  grep -Fq "$last_path" "$combined_parts" || fail "wide metadata split parts are missing the tail changed file"
  grep -Fq "wide-file-0089" "$combined_parts" || fail "wide metadata split parts are missing the tail diff content"

  printf 'ok: builder splits wide metadata without truncation\n'
}

run_builder_mid_metadata_low_cap_case() {
  local repo output_file split_dir manifest combined_parts part_file part_bytes last_path

  repo="$TMP_ROOT/mid-metadata"
  make_mid_metadata_repo "$repo"
  output_file="$TMP_ROOT/claude-review-mid-metadata-full.txt"
  split_dir="$TMP_ROOT/claude-review-mid-metadata-split"

  CLAUDE_REVIEW_MAX_ARTIFACT_BYTES=8000 CLAUDE_REVIEW_MAX_SPLIT_PARTS=30 bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/mid-metadata.stdout"

  manifest="$split_dir/manifest.txt"
  [ -f "$manifest" ] || fail "mid metadata split manifest was not written"

  combined_parts="$TMP_ROOT/combined-mid-metadata-parts.txt"
  : > "$combined_parts"
  while IFS= read -r part_file; do
    part_bytes="$(wc -c < "$part_file" | tr -d '[:space:]')"
    [ "$part_bytes" -le 8000 ] || fail "mid metadata split part exceeds 8000 bytes: $part_file"
    grep -Fq "Repeated split scope summary:" "$part_file" || fail "mid metadata split part missing repeated scope summary: $part_file"
    cat "$part_file" >> "$combined_parts"
  done < <(awk '/^Part file:/ { print $3 }' "$manifest")

  last_path="$("$PYTHON_BIN" - <<'PY'
suffix = "m" * 90
print(f"src/mid/component_0044_{suffix}.txt")
PY
)"

  grep -Fq "$last_path" "$combined_parts" || fail "mid metadata split parts are missing the tail changed file"
  grep -Fq "mid-file-0044" "$combined_parts" || fail "mid metadata split parts are missing the tail diff content"

  printf 'ok: builder summarizes mid-sized metadata under low caps\n'
}

run_builder_rename_split_preserves_aggregate_diff_case() {
  local repo output_file split_dir manifest combined_parts part_file part_bytes

  repo="$TMP_ROOT/rename-split"
  make_rename_review_repo "$repo"
  output_file="$TMP_ROOT/claude-review-rename-full.txt"
  split_dir="$TMP_ROOT/claude-review-rename-split"

  CLAUDE_REVIEW_MAX_ARTIFACT_BYTES=8000 bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/rename.stdout"

  manifest="$split_dir/manifest.txt"
  [ -f "$manifest" ] || fail "rename split manifest was not written"

  combined_parts="$TMP_ROOT/combined-rename-parts.txt"
  : > "$combined_parts"
  while IFS= read -r part_file; do
    part_bytes="$(wc -c < "$part_file" | tr -d '[:space:]')"
    [ "$part_bytes" -le 8000 ] || fail "rename split part exceeds 8000 bytes: $part_file"
    cat "$part_file" >> "$combined_parts"
  done < <(awk '/^Part file:/ { print $3 }' "$manifest")

  grep -Fq "rename from src/old.txt" "$output_file" || fail "full artifact missing aggregate rename metadata"
  grep -Fq "rename to src/new.txt" "$output_file" || fail "full artifact missing aggregate rename target"
  grep -Fq "rename from src/old.txt" "$combined_parts" || fail "split parts missing aggregate rename metadata"
  grep -Fq "rename to src/new.txt" "$combined_parts" || fail "split parts missing aggregate rename target"

  printf 'ok: builder preserves aggregate rename diffs in split artifacts\n'
}

run_builder_split_error_cleanup_case() {
  local repo output_file split_dir before_file after_file leaked stderr_file scratch_root

  repo="$TMP_ROOT/error-cleanup"
  make_review_repo "$repo"
  output_file="$TMP_ROOT/claude-review-error-cleanup-full.txt"
  split_dir="$TMP_ROOT/claude-review-error-cleanup-split"
  before_file="$TMP_ROOT/scratch-before.txt"
  after_file="$TMP_ROOT/scratch-after.txt"
  stderr_file="$TMP_ROOT/error-cleanup.stderr"
  scratch_root="$TMP_ROOT/error-cleanup-scratch"
  mkdir -p "$scratch_root"

  find "$scratch_root" -maxdepth 1 \( \
    -type d -name 'claude-review-code-blocks-*' -o \
    -type d -name 'claude-review-code-raw-*' -o \
    -type f -name 'claude-review-part-body-*' \
  \) -print | sort > "$before_file"

  if TMPDIR="$scratch_root" CLAUDE_REVIEW_MAX_ARTIFACT_BYTES=5000 bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode code \
    --repo-root "$repo" \
    --base-branch main \
    --output-file "$output_file" \
    --split-output-dir "$split_dir" \
    > "$TMP_ROOT/error-cleanup.stdout" \
    2>"$stderr_file"; then
    fail "builder unexpectedly succeeded with too-small split cap"
  fi

  find "$scratch_root" -maxdepth 1 \( \
    -type d -name 'claude-review-code-blocks-*' -o \
    -type d -name 'claude-review-code-raw-*' -o \
    -type f -name 'claude-review-part-body-*' \
  \) -print | sort > "$after_file"

  leaked="$(comm -13 "$before_file" "$after_file" || true)"
  [ -z "$leaked" ] || fail "split scratch leaked on error: $leaked"
  grep -Fq "shared context is too large" "$stderr_file" || fail "cleanup case did not hit the expected split error"

  printf 'ok: builder cleans split scratch on error\n'
}

run_builder_oversized_diff_header_guard_case() {
  local repo output_file split_dir fake_root long_path stderr_file

  repo="$TMP_ROOT/oversized-block"
  mkdir -p "$repo"
  output_file="$TMP_ROOT/claude-review-oversized-block-full.txt"
  split_dir="$TMP_ROOT/claude-review-oversized-block-split"
  fake_root="$TMP_ROOT/fake-gh-oversized-block"
  stderr_file="$TMP_ROOT/oversized-block.stderr"
  mkdir -p "$fake_root/bin"

  long_path="$("$PYTHON_BIN" - <<'PY'
print("src/" + ("x" * 9000) + ".txt")
PY
)"

  cat > "$fake_root/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *"--json files"*)
      printf '%s\n' "$FAKE_LONG_PR_PATH"
      exit 0
      ;;
    *)
      printf '{"number":42,"state":"OPEN","baseRefName":"main","headRefName":"review","title":"Test PR","url":"https://example.test/pr/42"}\n'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "diff" ]; then
  printf 'diff --git a/%s b/%s\n' "$FAKE_LONG_PR_PATH" "$FAKE_LONG_PR_PATH"
  printf 'new file mode 100644\n'
  printf 'index 0000000..1111111\n'
  printf -- '--- /dev/null\n'
  printf '+++ b/%s\n' "$FAKE_LONG_PR_PATH"
  printf '@@ -0,0 +1 @@\n'
  printf '+oversized label guard\n'
  exit 0
fi

printf 'unexpected gh args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/gh"

  if PATH="$fake_root/bin:$PATH" FAKE_LONG_PR_PATH="$long_path" CLAUDE_REVIEW_MAX_ARTIFACT_BYTES=12000 \
    bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
      --mode pr \
      --repo-root "$repo" \
      --pr-number 42 \
      --output-file "$output_file" \
      --split-output-dir "$split_dir" \
      > "$TMP_ROOT/oversized-block.stdout" \
      2>"$stderr_file"; then
    fail "builder unexpectedly accepted an oversized diff header line"
  fi

  grep -Fq "A single diff line is too large for one split artifact chunk" "$stderr_file" || fail "oversized diff header guard did not report the expected error"

  printf 'ok: builder rejects oversized diff header lines\n'
}

run_builder_oversized_diff_line_guard_case() {
  local repo output_file split_dir fake_root stderr_file long_line_file

  repo="$TMP_ROOT/oversized-diff-line"
  mkdir -p "$repo"
  output_file="$TMP_ROOT/claude-review-oversized-diff-line-full.txt"
  split_dir="$TMP_ROOT/claude-review-oversized-diff-line-split"
  fake_root="$TMP_ROOT/fake-gh-oversized-diff-line"
  stderr_file="$TMP_ROOT/oversized-diff-line.stderr"
  long_line_file="$TMP_ROOT/oversized-diff-line.txt"
  mkdir -p "$fake_root/bin"

  "$PYTHON_BIN" - "$long_line_file" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text("x" * 16000, encoding="utf-8")
PY

  cat > "$fake_root/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *"--json files"*)
      printf 'src/long-line.txt\n'
      exit 0
      ;;
    *)
      printf '{"number":42,"state":"OPEN","baseRefName":"main","headRefName":"review","title":"Test PR","url":"https://example.test/pr/42"}\n'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "diff" ]; then
  printf 'diff --git a/src/long-line.txt b/src/long-line.txt\n'
  printf 'new file mode 100644\n'
  printf 'index 0000000..1111111\n'
  printf -- '--- /dev/null\n'
  printf '+++ b/src/long-line.txt\n'
  printf '@@ -0,0 +1 @@\n'
  printf '+'
  cat "$FAKE_LONG_LINE_FILE"
  printf '\n'
  exit 0
fi

printf 'unexpected gh args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/gh"

  if PATH="$fake_root/bin:$PATH" FAKE_LONG_LINE_FILE="$long_line_file" CLAUDE_REVIEW_MAX_ARTIFACT_BYTES=12000 \
    bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
      --mode pr \
      --repo-root "$repo" \
      --pr-number 42 \
      --output-file "$output_file" \
      --split-output-dir "$split_dir" \
      > "$TMP_ROOT/oversized-diff-line.stdout" \
      2>"$stderr_file"; then
    fail "builder unexpectedly split an oversized logical diff line"
  fi

  grep -Fq "A single diff line is too large for one split artifact chunk" "$stderr_file" || fail "oversized diff line guard did not report the expected error"

  printf 'ok: builder rejects oversized logical diff lines\n'
}

run_builder_long_label_split_case() {
  local repo output_file split_dir fake_root pr_diff_file manifest part_file part_bytes long_path

  repo="$TMP_ROOT/long-label-split"
  mkdir -p "$repo"
  output_file="$TMP_ROOT/claude-review-long-label-full.txt"
  split_dir="$TMP_ROOT/claude-review-long-label-split"
  fake_root="$TMP_ROOT/fake-gh-long-label"
  pr_diff_file="$TMP_ROOT/fake-long-label-pr.diff"
  mkdir -p "$fake_root/bin"

  long_path="$("$PYTHON_BIN" - <<'PY'
print("src/" + ("x" * 1000) + ".txt")
PY
)"

  "$PYTHON_BIN" - "$pr_diff_file" "$long_path" <<'PY'
from pathlib import Path
import sys

path = sys.argv[2]
lines = [
    f"diff --git a/{path} b/{path}\n",
    "new file mode 100644\n",
    "index 0000000..1111111\n",
    "--- /dev/null\n",
    f"+++ b/{path}\n",
    "@@ -0,0 +2300 @@\n",
]
for index in range(2300):
    lines.append(f"+long-label-line-{index:04d} {'x' * 72}\n")
Path(sys.argv[1]).write_text("".join(lines), encoding="utf-8")
PY

  cat > "$fake_root/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *"--json files"*)
      printf '%s\n' "$FAKE_LONG_LABEL_PATH"
      exit 0
      ;;
    *)
      printf '{"number":42,"state":"OPEN","baseRefName":"main","headRefName":"review","title":"Test PR","url":"https://example.test/pr/42"}\n'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "diff" ]; then
  cat "$FAKE_LONG_LABEL_DIFF"
  exit 0
fi

printf 'unexpected gh args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/gh"

  PATH="$fake_root/bin:$PATH" FAKE_LONG_LABEL_PATH="$long_path" FAKE_LONG_LABEL_DIFF="$pr_diff_file" \
    bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
      --mode pr \
      --repo-root "$repo" \
      --pr-number 42 \
      --output-file "$output_file" \
      --split-output-dir "$split_dir" \
      > "$TMP_ROOT/long-label.stdout"

  manifest="$split_dir/manifest.txt"
  [ -f "$manifest" ] || fail "long-label split manifest was not written"
  while IFS= read -r part_file; do
    part_bytes="$(wc -c < "$part_file" | tr -d '[:space:]')"
    [ "$part_bytes" -le 200000 ] || fail "long-label split part exceeds 200000 bytes: $part_file"
  done < <(awk '/^Part file:/ { print $3 }' "$manifest")

  grep -Fq "long-label-line-2299" "$output_file" || fail "long-label full artifact missing tail content"

  printf 'ok: builder splits long-label diffs without overflowing part headers\n'
}

run_builder_pr_split_case() {
  local repo output_file split_dir fake_root pr_diff_file manifest part_count part_file part_bytes combined_parts

  repo="$TMP_ROOT/pr"
  mkdir -p "$repo"
  output_file="$TMP_ROOT/claude-review-pr-full.txt"
  split_dir="$TMP_ROOT/claude-review-pr-split"
  fake_root="$TMP_ROOT/fake-gh"
  pr_diff_file="$TMP_ROOT/fake-pr.diff"
  mkdir -p "$fake_root/bin"

  "$PYTHON_BIN" - "$pr_diff_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
parts = ["Fake PR diff preamble before first diff --git line\n"]
for index in range(6):
    parts.append(f"diff --git a/src/pr_changed_{index}.txt b/src/pr_changed_{index}.txt\n")
    parts.append("new file mode 100644\n")
    parts.append("index 0000000..1111111\n")
    parts.append("--- /dev/null\n")
    parts.append(f"+++ b/src/pr_changed_{index}.txt\n")
    parts.append("@@ -0,0 +1,520 @@\n")
    for line in range(520):
        parts.append(f"+pr-file-{index:02d}-line-{line:04d} {'p' * 72}\n")
path.write_text("".join(parts), encoding="utf-8")
PY

  cat > "$fake_root/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *"--json files"*)
      printf 'src/pr_changed_0.txt\nsrc/pr_changed_5.txt\n'
      exit 0
      ;;
    *)
      printf '{"number":42,"state":"OPEN","baseRefName":"main","headRefName":"review","title":"Test PR","url":"https://example.test/pr/42"}\n'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "diff" ]; then
  cat "$FAKE_PR_DIFF_FILE"
  exit 0
fi

printf 'unexpected gh args: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$fake_root/bin/gh"

  PATH="$fake_root/bin:$PATH" FAKE_PR_DIFF_FILE="$pr_diff_file" \
    bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
      --mode pr \
      --repo-root "$repo" \
      --pr-number 42 \
      --output-file "$output_file" \
      --split-output-dir "$split_dir" \
      > "$TMP_ROOT/pr.stdout"

  manifest="$split_dir/manifest.txt"
  [ -f "$manifest" ] || fail "PR split manifest was not written"
  grep -Fq "Review Artifact Split Manifest" "$manifest" || fail "PR split manifest missing header"
  grep -Fq "Max bytes per review artifact: 200000" "$manifest" || fail "PR split manifest missing cap"
  grep -Fq "PART_FILE" "$TMP_ROOT/pr.stdout" || fail "PR split stdout did not list part files"

  part_count="$(grep -c '^Part file:' "$manifest")"
  [ "$part_count" -ge 2 ] || fail "expected at least two PR split parts, got $part_count"

  combined_parts="$TMP_ROOT/combined-pr-parts.txt"
  : > "$combined_parts"
  while IFS= read -r part_file; do
    part_bytes="$(wc -c < "$part_file" | tr -d '[:space:]')"
    [ "$part_bytes" -le 200000 ] || fail "PR split part exceeds 200000 bytes: $part_file"
    grep -Fq "Review Artifact Split Part" "$part_file" || fail "PR split part missing header: $part_file"
    ! grep -Fq "artifact truncated" "$part_file" || fail "PR split part contains truncation marker: $part_file"
    cat "$part_file" >> "$combined_parts"
  done < <(awk '/^Part file:/ { print $3 }' "$manifest")

  grep -Fq "Fake PR diff preamble before first diff --git line" "$combined_parts" || fail "PR split parts missing preamble"
  grep -Fq "pr-file-00-line-0000" "$combined_parts" || fail "PR split parts missing first diff content"
  grep -Fq "pr-file-05-line-0519" "$combined_parts" || fail "PR split parts missing tail diff content"

  printf 'ok: builder writes bounded PR split artifacts without truncation\n'
}

run_runner_limit_case
run_runner_invalid_limit_case
run_runner_split_header_limit_case
run_runner_split_header_cap_ceiling_case
run_artifact_limit_validation_case
run_builder_requires_split_dir_case
run_builder_rejects_reused_split_dir_case
run_builder_rejects_whitespace_split_dir_case
run_builder_rejects_locked_split_dir_case
run_builder_recovers_stale_split_lock_case
run_builder_rejects_old_live_pid_lock_case
run_builder_recovers_stale_reaper_case
run_builder_allows_one_stale_lock_recoverer_case
run_builder_split_case
run_builder_max_split_parts_case
run_builder_large_file_chunk_context_case
run_builder_large_file_header_context_case
run_builder_wide_metadata_split_case
run_builder_mid_metadata_low_cap_case
run_builder_rename_split_preserves_aggregate_diff_case
run_builder_split_error_cleanup_case
run_builder_oversized_diff_header_guard_case
run_builder_oversized_diff_line_guard_case
run_builder_long_label_split_case
run_builder_pr_split_case
