# Claude Review Challenge Smoke Boundary

Date: 2026-07-02

This file records the smoke boundary for `docs/claude-review-challenge-plan.md`.
It is not a pass certificate for this isolated S8 checkout: the S8 worktree is
created from the base branch and does not contain the implementation files added
by the earlier orchestration slices.

## Local S8 Checks

- Bash syntax checks: `bash -n scripts/*.sh tests/*.sh`
- Runner sandbox baseline: `bash tests/run-review-sandbox-classification.sh`
- Schema baseline: JSON/JQ checks against `schemas/review-output.json`
- Whitespace check: `git diff --check`

These checks verify that the base runner and shell files still work in the S8
worktree. They do not prove challenge support by themselves.

## Required Integrated Checks

After the implementation slices are integrated into one checkout, rerun:

```bash
bash -n scripts/*.sh tests/*.sh
bash tests/run-review-sandbox-classification.sh
bash tests/challenge-prompt-fixtures.sh
bash tests/claude-command-router.sh
bash tests/claude-router-guard-docs.sh
bash tests/challenge-mode-consumers.sh
git diff --check
```

The integrated checks must cover the challenge prompt split, schema mode
additions, runner mode stamping, router parse precedence, missing-plan guards,
admin routing, consumer mode handling, and the explicit rule that challenge
results do not enter iterate/fix loops.

## Manual Smoke Boundary

The following smoke checks require restarting Codex so the installed skill and
command routing are reloaded. They are not executed inside the orchestration
worker:

```text
/claude-review challenge
/claude-review challenge code focus on retries and stale state
/claude-review challenge plan docs/claude-review-challenge-plan.md
/claude-review plan docs/claude-review-challenge-plan.md
```

Expected behavior:

- `/claude-review challenge` and `/claude-review challenge code ...` build the
  current diff artifact and invoke `scripts/run-review.sh --mode challenge_code`.
- `/claude-review challenge plan <path>` validates the path, reads that plan
  artifact, and invokes `scripts/run-review.sh --mode challenge_plan`.
- `/claude-review plan <path>` keeps normal plan-review behavior.
- `/claude ...` remains outside this bridge and is not documented as supported.

## Remaining Risk

The remaining boundary is integration, not more isolated S8 edits. The required
checks and restart-only smoke cases should run after the orchestrated slices are
combined in the installed skill checkout.
