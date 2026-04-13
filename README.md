# codexskill-claude-review

`/claude review` for Codex, packaged as a standalone skill repo.

This repo lets Codex call your local `claude` CLI for code review, plan review,
iterative review loops, and PR review. It is opinionated on purpose.

The important part:

- this bridge prefers and enforces Claude subscription auth
- it does not fall back to Anthropic API keys
- it intentionally scrubs `ANTHROPIC_API_KEY` and related Anthropic API credential env vars before calling `claude`

If subscription auth is unavailable, the bridge blocks clearly.

## Purpose

Use this when you want a Claude review pass from inside Codex without leaving your
current workflow.

The bridge keeps the roles clear:

- Claude reviews
- Codex fixes
- Claude does not edit files in this workflow

## Auth Model

This bridge is subscription-first and subscription-only.

It expects Claude CLI to authenticate through your Claude subscription account, not
through Anthropic Console API billing.

That means:

- `claude auth login --claudeai` is the right login path
- `claude auth login --console` is not the right login path for this bridge
- `ANTHROPIC_API_KEY` is ignored on purpose
- `--bare` is incompatible with this workflow because `--bare` forces API-key-style auth

If you are using normal Claude desktop or CLI subscription login, that is the intended
path.

## Why Budgets Still Exist On Subscription Auth

You will still see `--max-budget-usd` in the bridge commands.

That does not mean the bridge is using API-key auth.

It means the Claude CLI itself supports request budget caps in `--print` mode, and the
bridge uses those caps as guardrails:

- `LIVE_PROBE_BUDGET_USD` limits the tiny preflight probe
- `MAX_BUDGET_USD` limits the actual review call

Same subscription auth path. Different guardrail.

## Install

### Standard install

Clone the repo directly into your Codex skills directory:

```bash
git clone https://github.com/jokim1/codexskill-claude-review.git ~/.codex/skills/claude
chmod +x ~/.codex/skills/claude/scripts/*.sh
```

Then restart Codex.

### Local source + installed artifact

If you want a normal source checkout and a separate installed skill:

```bash
git clone https://github.com/jokim1/codexskill-claude-review.git /Users/josephkim/dev/codexskill-claude-review
rm -rf ~/.codex/skills/claude
ln -s /Users/josephkim/dev/codexskill-claude-review ~/.codex/skills/claude
chmod +x /Users/josephkim/dev/codexskill-claude-review/scripts/*.sh
```

In that layout:

- source repo lives at `/Users/josephkim/dev/codexskill-claude-review`
- installed artifact lives at `~/.codex/skills/claude`

Then restart Codex.

## Requirements

You need:

- Codex
- `claude` CLI installed
- `git`
- `jq`
- `gh` if you want `/claude review pr <number>`

For auth, use Claude subscription login:

```bash
claude auth login --claudeai
```

`--claudeai` is the default, but it is worth being explicit when you are debugging auth.

## First-Time Setup Check

Start with:

```bash
claude auth status
```

If needed:

```bash
claude auth login --claudeai
```

Important: the bridge does not trust `claude auth status` by itself.

It does a real subscription-only preflight call after scrubbing Anthropic API
credential env vars. That matters because `auth status` can look wrong in some shell
contexts even when a real `claude -p` call still works.

The source of truth is: can scrubbed `claude -p` answer a tiny request from the same
environment Codex is using?

## Command Behavior

### `/claude review`

Auto-mode.

- if a recent assistant `<proposed_plan>` block is visible, review the plan
- otherwise review the current code diff

Example:

```text
/claude review
```

### `/claude review code`

Review the current repo diff against the detected base branch.

Example:

```text
/claude review code
```

With one-off focus:

```text
/claude review code focus on migration risk and dead abstractions
```

### `/claude review plan`

Review the most recent visible `<proposed_plan>` block.

Example:

```text
/claude review plan
```

### `/claude review iterate`

Auto-mode iterative review.

- if a recent plan is visible, iterate on the plan
- otherwise iterate on code

Example:

```text
/claude review iterate
```

### `/claude review iterate code`

Run review, let Codex fix clear issues, verify, and re-run review until clean or
blocked.

Example:

```text
/claude review iterate code
```

### `/claude review iterate plan`

Run plan review, tighten the plan, and re-run review until clean or blocked on a real
decision.

Example:

```text
/claude review iterate plan
```

### `/claude review pr <number>`

Review a GitHub pull request through `gh`.

Example:

```text
/claude review pr 123
```

## Config

The bridge reads repo-local config from:

```text
<repo>/.codex/claude/config.env
```

Supported values:

- `EFFORT`
- `MODEL`
- `MAX_BUDGET_USD`
- `LIVE_PROBE_BUDGET_USD`
- `LIVE_PROBE_MODEL`

Example:

```env
EFFORT=high
MODEL=claude-opus-4-6
MAX_BUDGET_USD=2.00
LIVE_PROBE_BUDGET_USD=0.15
LIVE_PROBE_MODEL=sonnet
```

What they mean:

- `EFFORT`: review thinking level for the real review call
- `MODEL`: review model for the real review call
- `MAX_BUDGET_USD`: budget cap for the real review call
- `LIVE_PROBE_BUDGET_USD`: budget cap for the tiny subscription-only preflight probe
- `LIVE_PROBE_MODEL`: model used for that tiny preflight probe

Default probe behavior:

- `LIVE_PROBE_BUDGET_USD=0.15`
- `LIVE_PROBE_MODEL=sonnet`

## Troubleshooting

### `claude auth status` says logged out, but review still works

This can happen.

The bridge treats `auth status` as advisory only. It always prefers a real scrubbed
`claude -p` probe over status text.

If the probe works, the bridge continues.

### Preflight says the budget is too low

That is a CLI budget cap issue, not proof of API-key auth.

Raise the probe budget in your repo config:

```env
LIVE_PROBE_BUDGET_USD=0.25
```

Or retry after the Claude model cache is warm.

### Subscription auth is unavailable

Use the subscription login path:

```bash
claude auth login --claudeai
```

If you previously authenticated with Anthropic Console billing, switch back to
subscription login.

### `/claude review` is not visible yet

Restart Codex after:

- first install
- replacing the installed skill
- changing a symlinked install path

Skill discovery may not refresh live inside an already running Codex session.

## Behavior Surprises

### Why is there a budget if I am using subscription?

Because Claude CLI supports budget caps on `--print` requests even on the subscription
path. The budget is just a guardrail.

### Why does the bridge ignore my API key?

Because the point of this bridge is predictable Claude subscription behavior from the
local Claude CLI. If it silently used `ANTHROPIC_API_KEY`, people would get API-billed
behavior when they thought they were using their subscription login.

That surprise is worse than blocking clearly.

### Why do I need to restart Codex after install?

Because the installed skill lives under `~/.codex/skills/claude`, and Codex may not
reload skill discovery live in an already running session.

## Repo Layout

Important files:

- `SKILL.md`
- `agents/openai.yaml`
- `scripts/run-review.sh`
- `scripts/claude-subscription-env.sh`
- `scripts/build-review-artifact.sh`
- `prompts/code-review.base.md`
- `prompts/plan-review.base.md`
- `schemas/review-output.json`

## Development Notes

If you change the bridge:

1. patch the source repo
2. sync or symlink it into `~/.codex/skills/claude`
3. restart Codex
4. re-run a real `/claude review` path

The installed copy is the deployed artifact. The source repo is where durable changes
should live.
