#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_FILE="$REPO_ROOT/SKILL.md"
RUNNER_FILE="$REPO_ROOT/scripts/run-review.sh"
GUIDANCE_HOME="$(mktemp -d "$HOME/claude-review-guidance-test-XXXXXX")"
trap 'rm -rf "$GUIDANCE_HOME"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -Fq "invalid JSON" "$SKILL_FILE" || fail "SKILL.md must block invalid router JSON"
grep -Fq 'missing `status`' "$SKILL_FILE" || fail "SKILL.md must block missing router status"
grep -Fq 'unknown `flow`' "$SKILL_FILE" || fail "SKILL.md must block unknown router flow"
grep -Fq 'needs_context` without a non-empty `message`' "$SKILL_FILE" || fail "SKILL.md must block needs_context without message"
grep -Fq "do not invoke Claude" "$SKILL_FILE" || fail "SKILL.md must forbid Claude invocation after malformed router output"
grep -Fq 'surface those part-level' "$SKILL_FILE" || fail "SKILL.md must surface split part blockers"
grep -Fq 'even when other parts returned `issues_found`' "$SKILL_FILE" || fail "SKILL.md must not hide blocked split parts behind findings"
grep -Fq 'partial coverage' "$SKILL_FILE" || fail "SKILL.md must mark incomplete split reviews as partial coverage"
grep -Fq 'cross-file' "$SKILL_FILE" || fail "SKILL.md must document split review cross-file limits"
grep -Fq 'reasoning can be weaker' "$SKILL_FILE" || fail "SKILL.md must document split review fidelity limits"

grep -Fq 'Run /claude-review doctor now?' "$RUNNER_FILE" || fail "runner doctor offer prompt missing"
grep -Fq 'Reply Y to run diagnostics, or N to stop.' "$RUNNER_FILE" || fail "runner doctor reply prompt missing"
grep -Fq 'Run /claude-review doctor now?' "$SKILL_FILE" || fail "SKILL.md doctor offer prompt missing"
grep -Fq 'Reply Y to run diagnostics, or N to stop.' "$SKILL_FILE" || fail "SKILL.md doctor reply prompt missing"
grep -Fq 'immediately following user response' "$SKILL_FILE" || fail "SKILL.md immediate response boundary missing"
grep -Fq 'same repo root and config' "$SKILL_FILE" || fail "SKILL.md same-repo doctor continuation missing"
grep -Fq 'Do not run the update preflight' "$SKILL_FILE" || fail "SKILL.md doctor update-preflight exclusion missing"
grep -Fq 'Do not retry the failed review automatically' "$SKILL_FILE" || fail "SKILL.md automatic retry prohibition missing"
grep -Fq 'A later or' "$SKILL_FILE" || fail "SKILL.md stale affirmative guard missing"
grep -Fq 'diagnostic only: never modify PATH' "$SKILL_FILE" || fail "SKILL.md doctor mutation prohibition missing"
grep -Fq 'Budget caps, review timeouts, artifacts, missing' "$SKILL_FILE" || fail "SKILL.md direct-remediation exclusions missing"
grep -Fq 'state-write denial retain their direct remediation' "$SKILL_FILE" || fail "SKILL.md state-write exclusion missing"
grep -Fq 'BASH_ENV= ENV= <trusted-bash> --noprofile --norc <skill-dir>/scripts/run-review.sh' "$SKILL_FILE" || fail "SKILL.md trusted-shell runner invocation missing"
grep -Fq 'BASH_ENV= ENV= <trusted-bash> --noprofile --norc <skill-dir>/scripts/claude-doctor.sh' "$SKILL_FILE" || fail "SKILL.md trusted-shell doctor invocation missing"
grep -Fq 'claude_build_trusted_bootstrap_path' "$RUNNER_FILE" || fail "runner trusted bootstrap PATH missing"

mkdir -p "$GUIDANCE_HOME/.codex/skills/claude-review/scripts"
touch "$GUIDANCE_HOME/.codex/skills/claude-review/scripts/run-review.sh"
installed_guidance="$({
  HOME="$GUIDANCE_HOME" RUNNER_FILE="$RUNNER_FILE" \
    BASH_ENV= ENV= /bin/bash --noprofile --norc <<'BASH'
eval "$(sed -n '/^trusted_review_bridge_guidance() {$/,/^}$/p' "$RUNNER_FILE")"
trusted_review_bridge_guidance
BASH
})"
printf '%s\n' "$installed_guidance" | grep -Fq '["/bin/bash", "--noprofile", "--norc",' || fail "installed-runner guidance lacks exact trusted Bash prefix"
printf '%s\n' "$installed_guidance" | grep -Fq 'start it with BASH_ENV= and ENV= empty' || fail "installed-runner guidance lacks startup-environment safeguard"
if printf '%s\n' "$installed_guidance" | grep -Fq '["bash",'; then
  fail "installed-runner guidance retains bare Bash prefix"
fi

python3 - "$RUNNER_FILE" "$SKILL_FILE" <<'PY'
from pathlib import Path
import re
import sys

runner = Path(sys.argv[1]).read_text()
skill = Path(sys.argv[2]).read_text()

advertised = set(re.findall(r"Reply ([A-Za-z][A-Za-z ]*?) to run diagnostics", runner))
match = re.search(r"recognized immediate-response vocabulary is (.+?)\.\n", skill)
if not match:
    raise SystemExit("could not parse SKILL.md immediate-response vocabulary")
recognized = set(re.findall(r"`([^`]+)`", match.group(1)))
if not advertised:
    raise SystemExit("runner advertises no affirmative token")
if not advertised <= recognized:
    raise SystemExit(f"runner advertises unrecognized affirmative(s): {sorted(advertised - recognized)}")
if recognized != {"Y", "yes", "run doctor"}:
    raise SystemExit(f"unexpected immediate-response vocabulary: {sorted(recognized)}")

eligible = {
    "missing_binary",
    "unusable_runner",
    "launcher_dependency_missing",
    "launcher_dependency_unsafe",
    "launcher_dependency_unsupported",
    "launcher_dependency_unreadable",
    "subscription_auth_unavailable",
    "ambiguous_auth",
    "probe_timed_out",
    "invocation_failed",
}
case_match = re.search(r"failure_offers_doctor\(\).*?case .*? in\n\s*([^\n]+)\)", runner, re.S)
if not case_match:
    raise SystemExit("could not parse runner doctor-eligible failure set")
actual = set(case_match.group(1).strip().split("|"))
if actual != eligible:
    raise SystemExit(f"doctor-eligible set drifted: expected={sorted(eligible)} actual={sorted(actual)}")
PY

printf 'ok: malformed router and blocked-review recovery contracts documented\n'
