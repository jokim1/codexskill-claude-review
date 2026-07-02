# codexskill-claude-review

Claude Review Bridge is a Codex skill that lets Codex ask your local `claude`
CLI for an independent review pass without leaving the Codex workflow.

It is intentionally narrow:

- Claude reviews plans, code diffs, and PRs.
- Codex renders the findings and performs any fixes.
- Claude does not edit files.
- Claude runs without tools via `claude -p --tools ""`.
- The bridge uses Claude subscription auth, not Anthropic API-key billing.
- Review artifacts are bounded, schema-checked, and routed through local shell
  helpers so failures are diagnosable.

The internal Codex skill name is `claude-review`. The user-facing command family
is still `/claude ...` for review, config, and update commands.

## Why This Exists

Adversarial code review is one of the highest-leverage decorrelated reviews you can
add to an AI coding workflow. If Codex writes or plans the change, a separate Claude
pass is useful precisely because it is a different model, a different prompt, and a
different failure surface.

[GStack](https://github.com/garrytan/gstack) is Garry Tan's excellent open-source
skill stack for Claude Code and other AI coding agents. It includes review,
planning, QA, release, and challenge workflows, and it is usually the right answer
when you want Claude Code to ask Codex for an adversarial second opinion.

This repo exists for the opposite direction: Codex asking Claude for an adversarial
review.

When we tried to use GStack for Codex -> Claude review, the mismatch was not that
GStack was bad. The mismatch was direction and contract. We wanted Codex to remain
the primary operator while Claude acted as a narrow, independent reviewer.

That required guarantees the GStack workflow was not designed to be responsible for
in this direction:

- Codex stays the implementer and fixer; Claude only reports findings.
- Claude receives a bounded artifact that Codex builds from a plan, diff, or PR.
- Claude does not inspect the repo directly and does not get editing tools.
- Claude returns structured JSON that Codex can render, sort, and iterate on.
- Auth is predictably Claude subscription auth, with Anthropic API env vars scrubbed.
- Budget, timeout, sandbox, auth-state, and artifact-boundary failures are classified
  locally instead of becoming ambiguous nested-agent failures.

So the recommendation is simple and directional:

- For Claude Code asking Codex to review something, use
  [GStack](https://github.com/garrytan/gstack). That direction works well.
- For Codex asking Claude to review something, use this skill. It is a small bridge
  built specifically for that direction.

This is not a replacement for GStack. It is the small adapter for the other side of
the cross-model review loop.

## Current Status

Supported now:

- `/claude review`
- `/claude review code`
- `/claude review plan`
- `/claude review plan <path-to-plan.md>`
- `/claude review pr <number>`
- `/claude review iterate`
- `/claude review iterate code`
- `/claude review iterate plan`
- `/claude show`
- `/claude set effort <low|medium|high|xhigh|max>`
- `/claude set model <alias-or-full-model>`
- `/claude set budget <usd>`
- `/claude set timeout <seconds>`
- `/claude update`
- `/claude update --check`

Not supported in this bridge yet:

- `/claude challenge`
- `/claude-review challenge`

Challenge mode is planned in [docs/claude-review-challenge-plan.md](docs/claude-review-challenge-plan.md).
Until that work lands, do not document or rely on `/claude challenge` as a command
handled by this skill. If you intentionally run GStack's challenge flow, that is a
GStack command path, not this bridge.

## How It Works

The bridge keeps a strict division of labor:

1. Codex builds a review artifact from the visible plan, current diff, or PR diff.
2. Codex calls `scripts/run-review.sh`.
3. The runner scrubs Anthropic API credential env vars.
4. The runner performs a tiny subscription-auth preflight through the local
   `claude` CLI.
5. Claude receives only the artifact and bundled prompt, with no tools.
6. Claude returns structured JSON matching `schemas/review-output.json`.
7. Codex renders findings first, then decides what to fix.

The important consequence: Claude is an independent reviewer, not the implementer.

## Install

Clone this repo into your Codex skills directory:

```bash
git clone https://github.com/jokim1/codexskill-claude-review.git ~/.codex/skills/claude
chmod +x ~/.codex/skills/claude/scripts/*.sh
```

Then restart Codex.

For local development, keep a source checkout and symlink the installed skill:

```bash
git clone https://github.com/jokim1/codexskill-claude-review.git /Users/josephkim/dev/codexskill-claude-review
rm -rf ~/.codex/skills/claude
ln -s /Users/josephkim/dev/codexskill-claude-review ~/.codex/skills/claude
chmod +x /Users/josephkim/dev/codexskill-claude-review/scripts/*.sh
```

Then restart Codex.

## Requirements

You need:

- Codex
- `claude` CLI installed
- `git`
- `python3`
- `jq`
- `gh` for `/claude review pr <number>`

Use Claude subscription login:

```bash
claude auth login --claudeai
```

This bridge intentionally does not use Anthropic Console API billing. It scrubs
`ANTHROPIC_API_KEY` and related Anthropic API credential env vars before invoking
`claude`.

## First-Time Check

Start with:

```bash
claude auth status
```

If needed:

```bash
claude auth login --claudeai
```

The bridge treats `claude auth status` as advisory. The real source of truth is
whether a scrubbed `claude -p` call works from the same environment Codex uses.

## End-To-End Journey: Claude Review

This is the normal supported flow.

### 1. Review a Plan

Write a plan in a markdown file:

```text
docs/checkout-refactor-plan.md
```

Run:

```text
/claude review plan docs/checkout-refactor-plan.md
```

Codex will:

- read the plan file
- write it to a bounded `/tmp/claude-review-*` artifact
- call Claude with `prompts/plan-review.base.md`
- render findings ordered by severity

Use plan review when you want Claude to catch missing scope, weak test coverage,
bad sequencing, unclear rollback paths, or implementation ambiguity before Codex
writes code.

### 2. Review the Current Diff

Make code changes in your repo, then run:

```text
/claude review code
```

Codex will:

- detect the base branch
- build a bounded artifact from the current diff
- call Claude with `prompts/code-review.base.md`
- render structured findings with file and line references when available

You can add one-off focus text:

```text
/claude review code focus on migration risk and dead abstractions
```

### 3. Let Codex Fix Findings

For a report-only pass, run `/claude review code` and then ask Codex to fix the
findings you accept.

For a bounded fix-and-rereview loop, run:

```text
/claude review iterate code
```

Codex will:

- run Claude review
- apply fixes for actionable findings
- run relevant local verification
- rerun Claude review
- stop when clean, blocked, repeated, or after 10 rounds

Claude remains report-only during the loop. Codex performs all edits.

### 4. Review a PR

If the repository is connected to GitHub and `gh` is authenticated:

```text
/claude review pr 123
```

Codex will use `gh pr view` and `gh pr diff` to build the review artifact.

### 5. Tune the Bridge

Show current config:

```text
/claude show
```

Increase timeout for large diffs:

```text
/claude set timeout 600
```

Raise the review budget guardrail:

```text
/claude set budget 8
```

Set effort:

```text
/claude set effort xhigh
```

The config is stored per repo at:

```text
<repo>/.codex/claude/config.env
```

## End-To-End Journey: Claude Challenge

Challenge review means an adversarial pass: instead of asking "is this correct
enough to ship?", it asks "how does this break under production pressure?"

Typical challenge concerns include:

- race conditions and concurrency interleavings
- retries, idempotency, and duplicate work
- stale state and terminal-state overwrites
- partial failure, cancellation, and resource leaks
- data loss, silent corruption, and permission bypasses
- migration, rollback, compatibility, and operational failure modes

### Current Bridge Behavior

This repo does not currently implement first-class challenge commands. These are
not supported by the current `SKILL.md`, runner, or JSON schema:

```text
/claude challenge
/claude challenge code
/claude challenge plan
/claude-review challenge
```

If those commands work on your machine today, they are coming from another installed
skill, usually GStack's `gstack-claude` wrapper.

### Current Workaround In This Bridge

Use normal review with explicit adversarial focus text:

```text
/claude review code focus on race conditions, retries, idempotency, stale state, partial failure, and data loss
```

For plans:

```text
/claude review plan docs/checkout-refactor-plan.md
```

Then add the adversarial criteria to the plan itself or to your repo-level plan
review append prompt:

```text
<repo>/.codex/claude/plan-review.append.md
```

This is not identical to a dedicated challenge prompt, but it keeps the work inside
this bridge's subscription-authenticated, report-only runner.

### Planned First-Class Challenge Journey

The planned command family is documented in
[docs/claude-review-challenge-plan.md](docs/claude-review-challenge-plan.md).

The intended future journey is:

```text
/claude-review challenge
/claude-review challenge code focus on retries and stale state
/claude-review challenge plan docs/checkout-refactor-plan.md
```

Expected behavior after implementation:

1. Codex routes through the `claude-review` skill, not GStack.
2. Code challenge builds the same bounded current-diff artifact as normal review.
3. Plan challenge uses a file path or visible `<proposed_plan>`.
4. Claude receives a dedicated challenge prompt.
5. The runner stamps the output mode as `challenge_code` or `challenge_plan`.
6. Codex renders findings first and does not enter an automatic fix loop.

Until that implementation lands, treat challenge support as roadmap, not shipped
README surface.

## Command Reference

### Review

```text
/claude review
/claude review code
/claude review code focus on auth edge cases
/claude review plan
/claude review plan docs/plan.md
/claude review pr 123
```

`/claude review` auto-selects plan review when a recent visible
`<proposed_plan>` block exists; otherwise it reviews the current diff.

### Iterate

```text
/claude review iterate
/claude review iterate code
/claude review iterate plan
```

Iterate mode lets Codex fix and verify between Claude review rounds. It never lets
Claude edit files.

### Config

```text
/claude show
/claude set effort <low|medium|high|xhigh|max>
/claude set model <alias-or-full-model>
/claude set budget <usd>
/claude set timeout <seconds>
```

`extra-high` is accepted as a user-facing alias for `xhigh`.

### Update

```text
/claude update --check
/claude update
```

The updater fetches `origin/main` for the installed skill checkout and performs a
fast-forward-only merge. It blocks on tracked local changes, detached checkouts,
non-fast-forward history, and untracked files that would be overwritten.

Every `/claude ...` command except `/claude update` runs a low-noise update check
first. If a new version is available, Codex asks whether to update before continuing.

## Config File

The bridge reads repo-local config from:

```text
<repo>/.codex/claude/config.env
```

Supported values:

```env
EFFORT=xhigh
MODEL=opus
MAX_BUDGET_USD=5.00
REVIEW_TIMEOUT_SECONDS=300
LIVE_PROBE_BUDGET_USD=0.15
LIVE_PROBE_MODEL=sonnet
```

Defaults:

- `EFFORT=xhigh`
- `MODEL=opus`
- `MAX_BUDGET_USD=5.00`
- `REVIEW_TIMEOUT_SECONDS=300`
- `LIVE_PROBE_BUDGET_USD=0.15`
- `LIVE_PROBE_MODEL=sonnet`

The budget values are Claude CLI guardrails for `--print` requests. They do not
mean this bridge is using Anthropic API-key auth.

## Sandbox And Claude State

Review flows may need Claude Code to write lock or refresh files under `~/.claude`
or `CLAUDE_CONFIG_DIR`. If Codex runs the parent `bash run-review.sh` process inside
a filesystem sandbox, the child `claude` process inherits that sandbox and can fail
with paths like:

```text
~/.claude/.oauth_refresh.lock
```

If that happens, approve only the exact installed helper path:

```text
["bash", "/Users/<you>/.codex/skills/claude/scripts/run-review.sh"]
```

Do not approve broad prefixes such as `["bash"]`, and do not approve repo-local or
unreviewed copies of the helper.

Artifact builders, config helpers, and update checks do not need that approval.

## Troubleshooting

### `/claude review` is not visible

Restart Codex after first install, replacing the installed skill, or changing a
symlinked install path.

### `/claude update` routes to GStack

This means another installed skill is still winning the `/claude` prompt. Use:

```text
$claude-review /claude update --check
```

Then disable the duplicate GStack Claude skill or restart Codex after updating this
skill.

### `claude auth status` looks wrong

The bridge treats `claude auth status` as advisory. If the real scrubbed `claude -p`
probe works, review continues.

### Preflight says the budget is too low

Raise the live probe budget:

```env
LIVE_PROBE_BUDGET_USD=0.25
```

### Review times out

Large artifacts can take several minutes, especially with Opus and `xhigh` effort.
Raise the timeout or narrow the diff:

```text
/claude set timeout 600
```

### Subscription auth is unavailable

Use:

```bash
claude auth login --claudeai
```

If you previously authenticated through Anthropic Console billing, switch back to
Claude subscription login.

## Repo Layout

Important files:

- `SKILL.md`
- `agents/openai.yaml`
- `scripts/run-review.sh`
- `scripts/claude-subscription-env.sh`
- `scripts/build-review-artifact.sh`
- `scripts/claude-config.sh`
- `scripts/claude-update-check.sh`
- `scripts/claude-update.sh`
- `prompts/code-review.base.md`
- `prompts/plan-review.base.md`
- `schemas/review-output.json`
- `docs/claude-review-challenge-plan.md`

## Development

The installed copy is the deployed artifact. The source repo is where durable
changes should live.

For the symlinked development layout:

1. Patch this source repo.
2. Keep `~/.codex/skills/claude` pointed at this checkout.
3. Restart Codex when skill metadata or routing changes.
4. Re-run a real `/claude review` path.

Useful checks:

```bash
bash -n scripts/*.sh tests/*.sh
bash tests/run-review-sandbox-classification.sh
```
