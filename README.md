# codexskill-claude-review

`/claude review` for Codex, packaged as a standalone skill repo.

This repo lets Codex call your local `claude` CLI for:

- code review
- plan review
- iterative review loops
- PR review

It is designed to be useful on day one. You do not need to write your own prompt to get started. The skill already ships with strong default review prompts for both code review and plan review. Custom prompts are optional.

## Who This Is For

- engineers who want a second review pass without leaving Codex
- PMs who want help reviewing implementation plans before coding starts
- new vibe coders who want plain-English feedback on whether a change is risky, sloppy, incomplete, or likely to break something
- teams who want a shareable Codex skill that works without Claude-side gstack

## What You Get Out Of The Box

After install, the skill already knows how to review for:

- correctness and regressions
- missing tests
- unsafe or incomplete changes
- maintainability and abstraction slop
- frontend state and UX gaps
- plan completeness, scope, failure modes, and rollout risk

The default prompts are intentionally opinionated:

- they prefer simple, maintainable code over clever abstractions
- they try to catch pile-on architecture and unnecessary indirection
- they avoid style-only nitpicks
- they do not enforce SOLID as dogma
- they try to preserve product and design intent instead of flattening everything into generic reusable mush

If you never customize a prompt, the skill should still be useful.

## How It Works

When you run a `/claude ...` command in Codex:

1. Codex gathers the relevant artifact.
2. Codex sends that artifact to your local `claude` CLI.
3. Claude reviews only that artifact and returns structured findings.
4. In report mode, Codex shows you the findings.
5. In iterate mode, Codex uses the findings to revise code or plans, re-checks them, and re-runs review until it is clean or blocked.

Important boundaries:

- Claude is the reviewer.
- Codex is the fixer.
- Claude does not edit your files in this workflow.
- This repo does not depend on Claude-side gstack skills.

## Requirements

You need:

- Codex
- `claude` CLI installed
- a Claude environment that can actually answer a tiny CLI request
- `jq`
- `git`
- `gh` if you want `/claude review pr <number>`

That usually means one of these:

- normal desktop login with `claude auth login`
- another usable Claude CLI auth context, such as an environment where the CLI can make requests successfully

## Install

Clone the repo into your Codex skills directory:

```bash
git clone https://github.com/jokim1/codexskill-claude-review.git ~/.codex/skills/claude
chmod +x ~/.codex/skills/claude/scripts/*.sh
```

Then restart Codex, or refresh skill discovery if your Codex setup supports it.

## First-Time Setup Check

Start with the normal check:

```bash
claude auth status
```

If needed:

```bash
claude auth login
```

Important: `claude auth status` is useful, but it is not the only thing this skill trusts.
The skill now does a hybrid preflight:

- first it tries to resolve one Claude runner and keep using that exact runner
- then it checks `claude auth status`
- if status is false or ambiguous, it runs one tiny real Claude probe

That means the skill can still work in some cases where `auth status` looks wrong, as long
as Claude can actually answer a small request from the same environment Codex is using.

## Five Good First Commands

If you are brand new, start here.

### 1. Review your current diff

```text
/claude review
```

What happens:

- if you recently posted a `<proposed_plan>` block, this reviews the plan
- otherwise it reviews your current code diff

### 2. Force a code review

```text
/claude review code
```

Use this when you want to review the actual code diff even if a plan is visible in the thread.

### 3. Review a plan before anyone codes it

```text
/claude review plan
```

Use this after sharing a plan in a `<proposed_plan>` block.

### 4. Let Codex fix review findings automatically

```text
/claude review iterate code
```

Use this when you want a review-fix-review loop with as little manual effort as possible.

### 5. Review a GitHub PR

```text
/claude review pr 123
```

Use this when you want review against a real PR instead of your local diff.

## Command Guide

This section includes an example for every supported command family.

### `/claude review`

Auto-mode. It chooses plan review or code review based on recent conversation context.

Example:

```text
/claude review
```

Example with extra one-off instructions:

```text
/claude review focus on migration risk and whether this adds unnecessary abstraction
```

Use when:

- you want the simplest entry point
- you do not want to think about whether to call `plan` or `code`

### `/claude review code`

Reviews your current repo diff against the detected base branch.

Example:

```text
/claude review code
```

Example with a specific lens:

```text
/claude review code focus on frontend state handling and regression risk
```

Use when:

- you want a code review no matter what else is in the chat

### `/claude review plan`

Reviews the most recent visible `<proposed_plan>` block.

Example:

```text
/claude review plan
```

Use when:

- you want to tighten scope before coding
- you want Claude to challenge complexity, coverage, and missing edge cases

### `/claude review iterate`

Auto-mode iterative review. If a recent plan is visible, it iterates on the plan. Otherwise it iterates on code.

Example:

```text
/claude review iterate
```

Use when:

- you want the fastest “review, fix, re-review” loop

### `/claude review iterate code`

Runs code review, lets Codex address clear findings, verifies, and re-runs review.

Example:

```text
/claude review iterate code
```

Use when:

- you want Codex to fix straightforward issues automatically
- you only want to be interrupted when product intent is actually unclear

### `/claude review iterate plan`

Runs plan review, tightens the plan, and re-runs review until it is clean or blocked on real decisions.

Example:

```text
/claude review iterate plan
```

Use when:

- you want a plan polished before implementation starts

### `/claude review pr <number>`

Reviews a GitHub pull request using `gh`.

Example:

```text
/claude review pr 123
```

Use when:

- you want feedback on a real PR
- your local branch is not the best source of truth

## Prompt And Instruction Commands

You do not need these on day one. The default prompts are already built in.

Use these only when you want to customize how the review behaves.

### `/claude review instructions code`

Shows the effective code review prompt:

- bundled base prompt
- global append prompt
- repo append prompt
- final merged prompt

Example:

```text
/claude review instructions code
```

### `/claude review instructions plan`

Shows the effective plan review prompt.

Example:

```text
/claude review instructions plan
```

### `/claude review instructions set code <markdown>`

Sets a repo-local code review prompt append file.

Example:

```text
/claude review instructions set code Always call out dead abstractions, pass-through wrappers, and test gaps first.
```

Use when:

- your team has repo-specific review rules

### `/claude review instructions set plan <markdown>`

Sets a repo-local plan review prompt append file.

Example:

```text
/claude review instructions set plan Prefer incremental migrations over big-bang rewrites and require rollback steps for risky changes.
```

### `/claude review instructions clear code`

Clears the repo-local code review prompt append file.

Example:

```text
/claude review instructions clear code
```

### `/claude review instructions clear plan`

Clears the repo-local plan review prompt append file.

Example:

```text
/claude review instructions clear plan
```

### `/claude review instructions set global code <markdown>`

Sets your personal global code review prompt append file.

Example:

```text
/claude review instructions set global code Explain findings in plain English first, then give the technical reason.
```

Use when:

- you want the same preference across every repo you work in

### `/claude review instructions set global plan <markdown>`

Sets your personal global plan review prompt append file.

Example:

```text
/claude review instructions set global plan Always make missing acceptance criteria explicit.
```

### `/claude review instructions clear global code`

Clears your personal global code review append prompt.

Example:

```text
/claude review instructions clear global code
```

### `/claude review instructions clear global plan`

Clears your personal global plan review append prompt.

Example:

```text
/claude review instructions clear global plan
```

## Config Commands

### `/claude config show`

Shows the current repo-local config.

Example:

```text
/claude config show
```

### `/claude config set effort <low|medium|high|max>`

Controls how much thinking Claude should spend on review.

Examples:

```text
/claude config set effort low
/claude config set effort medium
/claude config set effort high
/claude config set effort max
```

Rule of thumb:

- `low`: fastest, least thorough
- `medium`: good default
- `high`: more careful review
- `max`: slowest, deepest pass

### `/claude config set model <alias-or-full-model>`

Sets the Claude model used by the skill.

Example:

```text
/claude config set model sonnet
```

Example with a full model name:

```text
/claude config set model claude-sonnet-4-20250514
```

Use when:

- you want to standardize on a specific model for your team or repo

## Prompt Layers

Prompt customization is layered in this order:

1. bundled base prompt
2. global append prompt
3. repo append prompt
4. inline one-off instructions

Global append files:

- `~/.codex/claude/code-review.append.md`
- `~/.codex/claude/plan-review.append.md`

Repo append files:

- `<repo>/.codex/claude/code-review.append.md`
- `<repo>/.codex/claude/plan-review.append.md`

Practical way to think about this:

- base prompt: what the skill believes by default
- global append: how you personally like reviews phrased or prioritized
- repo append: how this specific project wants reviews done
- inline instructions: one-off focus for this exact run

## What The Default Prompts Already Optimize For

### Code Review Defaults

The built-in code review prompt already pushes for:

- real regressions over style comments
- missing tests over cosmetic nits
- maintainability over theoretical purity
- smaller fixes over architecture pile-on
- explicit boundaries over magic behavior
- design-intent preservation in frontend code

It also tries to suppress low-value review noise like:

- “make this more reusable” with no concrete reason
- generic SOLID lecturing
- speculative abstractions
- obvious comments
- style-only complaints

### Plan Review Defaults

The built-in plan review prompt already pushes for:

- minimal viable change
- reuse before rebuild
- test matrix and acceptance criteria
- failure modes and rollback thinking
- migration and compatibility clarity
- explicit `What Already Exists`
- explicit `Not In Scope`

## Example Workflows

### PM Workflow

You have a feature plan and want to know if engineering will get stuck later.

1. Paste a plan in a `<proposed_plan>` block.
2. Run:

```text
/claude review plan
```

3. If you want Codex to tighten the plan automatically:

```text
/claude review iterate plan
```

### New Vibe Coder Workflow

You built something and want a sanity check without learning a lot of process.

1. Make your code change.
2. Run:

```text
/claude review code
```

3. If you want Codex to handle easy fixes:

```text
/claude review iterate code
```

### Engineer Workflow

You want a higher-confidence pre-merge pass.

1. Run:

```text
/claude review code focus on trust boundaries, tests, and hidden compatibility issues
```

2. If the branch is already on GitHub:

```text
/claude review pr 123
```

## Troubleshooting

### “The skill is installed but `/claude ...` does nothing”

Restart Codex or refresh skill discovery.

### “Claude review says it is blocked”

Check Claude authentication:

```bash
claude auth status
```

Then check what Codex is probably seeing:

```bash
which claude
claude -v
claude auth status
```

If Claude works in one terminal window but the skill still says blocked, the most common
reason is environment mismatch:

- a different shell startup path
- Codex inherited older PATH or auth state
- one shell can see your Claude auth context and another cannot

The skill tries to handle this by resolving one Claude runner and reusing it for auth
checks and the real review call, but if Codex inherited stale environment state you may
still need to restart Codex.

If you use a non-login auth setup, make sure the same environment is visible to Codex,
not just to one terminal tab.

### “`claude auth status` says I am logged out, but Claude works elsewhere”

This can happen.

`claude auth status` is environment-sensitive. Different shells or launch contexts can
see different PATH entries, config, login state, or auth-related environment variables.

Useful debug commands:

```bash
which claude
claude -v
claude auth status
echo "$SHELL"
echo "$PATH"
```

If you rely on environment-based auth, also check whether the relevant variables are
available in the same environment Codex inherits.

### “PR review is blocked”

Check GitHub CLI authentication:

```bash
gh auth status
```

### “Do I need to write a custom prompt before this is useful?”

No. The built-in prompts are meant to be usable from the initial install.

### “Does this depend on gstack?”

No. This repo is self-contained on the Codex side.

## Repo Contents

- `SKILL.md`: command routing and behavior
- `agents/openai.yaml`: skill metadata
- `prompts/code-review.base.md`: built-in default code review prompt
- `prompts/plan-review.base.md`: built-in default plan review prompt
- `schemas/review-output.json`: review output contract
- `scripts/run-review.sh`: Claude review runner
- `scripts/build-review-artifact.sh`: code and PR artifact builder
