#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

python3 - "$REPO_ROOT/schemas/review-output.json" <<'PY'
import json
import sys

schema = json.load(open(sys.argv[1], encoding="utf-8"))
modes = set(schema["properties"]["mode"]["enum"])
missing = {"challenge_code", "challenge_plan"} - modes
if missing:
    print(f"schema missing challenge modes: {sorted(missing)}", file=sys.stderr)
    sys.exit(1)
PY
printf 'ok: schema accepts challenge modes\n'

if ! grep -q 'challenge_code|challenge_plan' "$REPO_ROOT/scripts/run-review.sh"; then
  fail "run-review.sh does not allow challenge modes"
fi
printf 'ok: runner allows challenge modes\n'

tmpdir="$(mktemp -d /tmp/claude-review-mode-consumers-XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

for mode in challenge_code challenge_plan; do
  if bash "$REPO_ROOT/scripts/build-review-artifact.sh" \
    --mode "$mode" \
    --repo-root "$REPO_ROOT" \
    --output-file "$tmpdir/claude-review-artifact.txt" \
    --base-branch main \
    2>"$tmpdir/$mode.stderr"; then
    fail "build-review-artifact.sh unexpectedly accepted $mode"
  fi
  if ! grep -q "Unsupported mode: $mode" "$tmpdir/$mode.stderr"; then
    fail "build-review-artifact.sh did not clearly reject $mode"
  fi
  printf 'ok: artifact builder rejects %s directly\n' "$mode"
done

if ! grep -q 'Challenge modes (`challenge_code`, `challenge_plan`) are report-only' "$REPO_ROOT/SKILL.md"; then
  fail "SKILL.md does not explicitly exclude challenge modes from iterate loops"
fi
printf 'ok: skill excludes challenge modes from iterate loops\n'
