---
name: claude
description: |
  Use when the user explicitly asks for `/claude ...` or wants to run Claude Code
  from Codex for an independent native-only plan review or code review without
  leaving Codex. Supports `/claude review`, `/claude review plan`,
  `/claude review code`, `/claude review iterate`, `/claude review iterate plan`,
  `/claude review iterate code`, `/claude review pr <number>`,
  `/claude review instructions [plan|code]`,
  `/claude review instructions set [plan|code] <markdown>`,
  `/claude review instructions clear [plan|code]`,
  `/claude review instructions set global [plan|code] <markdown>`,
  `/claude review instructions clear global [plan|code]`,
  `/claude show`, `/claude set effort <low|medium|high|xhigh|max>`,
  `/claude set model <alias-or-full-model>`,
  `/claude set budget <usd>`,
  and `/claude set timeout <seconds>`.
---

# Claude Review Bridge

This skill uses the local `claude` CLI with the user's existing Claude subscription
login. It intentionally ignores Anthropic API credential env vars and does not fall
back to Anthropic API keys. Keep the workflow narrow, deterministic, and native-only:

- Plan review uses the most recent visible `<proposed_plan>` block from the last 6 messages.
- Plain code review uses the current repo diff against the detected base branch.
- PR review uses `gh pr view` plus `gh pr diff`.
- Claude runs in prompt-only mode with `--tools ""`. Do not let it edit files.
- Claude is always report-only. Codex is always the fixer.
- Iterate mode runs Claude review, renders Claude findings in-thread, lets Codex
  address them, verifies the result, and re-runs Claude review up to 10 times.

## Paths

Resolve these relative to the current repo and this skill's directory:

- Repo root: `git rev-parse --show-toplevel 2>/dev/null || pwd`
- Repo config dir: `<repo>/.codex/claude`
- Repo config file: `<repo>/.codex/claude/config.env`
- Repo prompt overrides:
  - `<repo>/.codex/claude/code-review.append.md`
  - `<repo>/.codex/claude/plan-review.append.md`
- User prompt overrides:
  - `~/.codex/claude/code-review.append.md`
  - `~/.codex/claude/plan-review.append.md`
- Bundled base prompts:
  - `prompts/code-review.base.md`
  - `prompts/plan-review.base.md`
- JSON schema: `schemas/review-output.json`
- Config helper: `scripts/claude-config.sh`
- Native Claude helper: `scripts/run-review.sh`
- Artifact builder: `scripts/build-review-artifact.sh`

The bundled files live adjacent to this `SKILL.md`. Resolve those paths relative to
the skill directory.

## Command Routing

Match only the explicit `/claude ...` command family.

Use these config forms:

- `/claude show`
- `/claude set effort <low|medium|high|xhigh|max>`
- `/claude set model <alias-or-full-model>`
- `/claude set budget <usd>`
- `/claude set timeout <seconds>`

When these instructions refer to "inline review instructions," use the literal text
after `/claude review` or `/claude review code`. Treat those as one-off appended
instructions after bundled, user-level, and repo-level prompts.

### `/claude review`

1. Inspect the last 6 visible conversation messages, newest first.
2. If there is a recent assistant `<proposed_plan>` block, run `/claude review plan`.
3. Otherwise run `/claude review code`.

### `/claude review plan`

1. Extract the most recent visible assistant `<proposed_plan>` block from the last 6 messages.
2. If none is visible, respond:

```text
STATUS: NEEDS_CONTEXT
REASON: No recent <proposed_plan> block is visible in this conversation.
RECOMMENDATION: Create or paste a plan, then run /claude review plan again.
```

3. Write the extracted plan text to a temp file under `/tmp`.
4. Invoke:

```bash
bash <skill-dir>/scripts/run-review.sh \
  --mode plan \
  --artifact-file <temp-plan-file> \
  --base-prompt <skill-dir>/prompts/plan-review.base.md \
  --append-prompt ~/.codex/claude/plan-review.append.md \
  --append-prompt <repo>/.codex/claude/plan-review.append.md \
  --config-file <repo>/.codex/claude/config.env \
  --schema-file <skill-dir>/schemas/review-output.json
```

5. Parse the returned JSON and render findings first, ordered by severity and grouped by category.

### `/claude review code`

1. Resolve the repo root.
2. Detect the base branch in this order:
   - `gh pr view --json baseRefName -q .baseRefName`
   - `git symbolic-ref refs/remotes/origin/HEAD --short | sed 's@^origin/@@'`
   - `main`
   - `master`
3. Build the artifact with:

```bash
bash <skill-dir>/scripts/build-review-artifact.sh \
  --mode code \
  --repo-root <repo-root> \
  --base-branch <base-branch> \
  --output-file <temp-artifact-file>
```

4. If artifact building fails because merge base or base branch cannot be determined, respond:

```text
STATUS: BLOCKED
REASON: Could not determine a merge base for code review.
RECOMMENDATION: Ensure the repo has a reachable base branch or use /claude review pr <number>.
```

5. Invoke:

```bash
bash <skill-dir>/scripts/run-review.sh \
  --mode code \
  --artifact-file <temp-artifact-file> \
  --base-prompt <skill-dir>/prompts/code-review.base.md \
  --append-prompt ~/.codex/claude/code-review.append.md \
  --append-prompt <repo>/.codex/claude/code-review.append.md \
  --config-file <repo>/.codex/claude/config.env \
  --schema-file <skill-dir>/schemas/review-output.json \
  --repo-root <repo-root> \
  --branch <current-branch> \
  --base-branch <base-branch> \
  --instructions "<inline review instructions>"
```

6. Parse the returned JSON and render findings first, ordered by severity and grouped by category.

### `/claude review pr <number>`

1. Validate the PR with:

```bash
gh pr view <number> --json number,state,baseRefName,headRefName,title,url
```

2. If validation fails, respond:

```text
STATUS: BLOCKED
REASON: The PR could not be loaded with gh.
RECOMMENDATION: Check gh auth and the PR number, then retry.
```

3. Build the artifact with:

```bash
bash <skill-dir>/scripts/build-review-artifact.sh \
  --mode pr \
  --repo-root <repo-root> \
  --pr-number <number> \
  --output-file <temp-artifact-file>
```

4. Invoke `scripts/run-review.sh` with `--mode pr`, the code-review prompt, both append prompts, and `--pr-number <number>`.
5. Parse the returned JSON and render findings first, ordered by severity and grouped by category.

### `/claude review iterate`

1. Inspect the last 6 visible conversation messages, newest first.
2. If there is a recent assistant `<proposed_plan>` block, run `/claude review iterate plan`.
3. Otherwise run `/claude review iterate code`.

### `/claude review iterate plan`

1. Run the same artifact-building and `scripts/run-review.sh --mode plan` flow as `/claude review plan`.
2. If Claude returns `clean`, stop and report success.
3. If Claude returns `needs_context` or `blocked`, stop and surface that result.
4. If Claude returns `issues_found`, follow this sequence in every round:
   - render Claude's findings first, ordered by severity and grouped by category
   - revise the plan yourself; Claude remains report-only
   - auto-resolve findings with `action=fix_directly` or `action=add_or_update_test`
   - collect all remaining `action=ask_user_first` findings into one compact unresolved-decision list
   - if unresolved decisions remain, stop and present them together
   - re-run Claude plan review after the revised plan is ready
5. Before declaring the plan clean, ensure the plan includes:
   - `What Already Exists`
   - `Not In Scope`
   - a test matrix or equivalent explicit coverage section
   - a failure-mode section
6. Repeat until one of these stop conditions is reached:
   - the review is `clean`
   - unresolved user-decision findings remain
   - two consecutive rounds return the same `critical` or `important` `finding_key` set
   - you cannot make a confident improvement
   - 10 total review rounds have been attempted
7. Render the final result with:
   - final status
   - number of rounds used
   - unresolved decisions, if any
   - the final improved `<proposed_plan>` block when you changed the plan

### `/claude review iterate code`

1. Run the same base-branch detection, artifact-building, and `scripts/run-review.sh --mode code` flow as `/claude review code`.
2. If Claude returns `clean`, stop and report success.
3. If Claude returns `needs_context` or `blocked`, stop and surface that result.
4. If Claude returns `issues_found`, follow this sequence in every round:
   - render Claude's findings first, ordered by severity and grouped by category
   - treat Claude's findings as an independent review pass and address them yourself in the current repo
   - auto-resolve findings with `action=fix_directly` or `action=add_or_update_test`
   - collect all remaining `action=ask_user_first` findings into one compact unresolved-decision list
   - if unresolved decisions remain, stop and present them together
   - never present Claude as if Claude made the code changes; Claude only reports and Codex only fixes
5. After each fix round:
   - run the narrowest relevant local verification first
   - also run `npm run typecheck` and `npm run build` before re-review unless those commands do not exist or are already known to be unavailable
6. Regression rule:
   - if the review indicates changed existing behavior and a viable test harness exists, add or update a regression test before finishing the iteration clean
7. Rebuild the review artifact from the new repo state and run Claude review again.
8. Repeat until one of these stop conditions is reached:
   - the review is `clean`
   - unresolved user-decision findings remain
   - two consecutive rounds return the same `critical` or `important` `finding_key` set
   - there were no meaningful code changes in the last fix round
   - only low-signal informational or `nitpick` findings remain
   - a required verification step or manual dependency blocks progress
   - 10 total review rounds have been attempted
9. Render the final result with:
   - final status
   - number of rounds used
   - what you fixed
   - what remains, if anything

### `/claude review iterate pr <number>`

Do not run an automatic fix loop from a PR number alone.

Respond:

```text
STATUS: NEEDS_CONTEXT
REASON: Iteration requires a checked-out branch or a visible plan, not just a remote PR diff.
RECOMMENDATION: Check out the PR branch locally and run /claude review iterate code, or use /claude review pr <number> for report-only review.
```

### `/claude review instructions [plan|code]`

1. Default to `code` unless the user explicitly requested `plan`.
2. Read the bundled base prompt for that mode.
3. Read the user-level append override if present.
4. Read the repo-level append override if present.
5. Read the effective config values with:

```bash
bash <skill-dir>/scripts/claude-config.sh show \
  --config-file <repo>/.codex/claude/config.env
```

6. Print, in order:
   - bundled base prompt
   - user-level append override or a note that none exists
   - repo-level append override or a note that none exists
   - effective merged prompt in base -> user -> repo order
   - current config values

### `/claude review instructions set [plan|code] <markdown>`

1. Determine the target mode from the command.
2. Treat everything after the mode token as literal markdown.
3. Create `<repo>/.codex/claude` if needed.
4. Replace the repo-level append file for that mode with exactly that markdown.
5. Confirm the path written, then show the effective instructions for that mode.

### `/claude review instructions clear [plan|code]`

1. Determine the target mode from the command.
2. Remove the repo-level append file for that mode if it exists.
3. Confirm the clear action, then show the effective instructions for that mode.

### `/claude review instructions set global [plan|code] <markdown>`

1. Determine the target mode from the command.
2. Treat everything after the mode token as literal markdown.
3. Create `~/.codex/claude` if needed.
4. Replace the user-level append file for that mode with exactly that markdown.
5. Confirm the path written, then show the effective instructions for that mode.

### `/claude review instructions clear global [plan|code]`

1. Determine the target mode from the command.
2. Remove the user-level append file for that mode if it exists.
3. Confirm the clear action, then show the effective instructions for that mode.

### `/claude show`

Run:

```bash
bash <skill-dir>/scripts/claude-config.sh show \
  --config-file <repo>/.codex/claude/config.env
```

Print the returned effective values.

### `/claude set effort <low|medium|high|xhigh|max>`

Run:

```bash
bash <skill-dir>/scripts/claude-config.sh set effort <value> \
  --config-file <repo>/.codex/claude/config.env
```

Print the returned effective values and confirm the updated effort. Treat
`extra-high` as a user-facing alias for `xhigh` when setting effort.

### `/claude set model <alias-or-full-model>`

Run:

```bash
bash <skill-dir>/scripts/claude-config.sh set model <value> \
  --config-file <repo>/.codex/claude/config.env
```

Print the returned effective values and confirm the updated model.

### `/claude set budget <usd>`

Run:

```bash
bash <skill-dir>/scripts/claude-config.sh set budget <value> \
  --config-file <repo>/.codex/claude/config.env
```

Print the returned effective values and confirm the updated budget.

### `/claude set timeout <seconds>`

Run:

```bash
bash <skill-dir>/scripts/claude-config.sh set timeout <value> \
  --config-file <repo>/.codex/claude/config.env
```

Print the returned effective values and confirm the updated timeout.

## Rendering Claude Output

`scripts/run-review.sh` always returns JSON that matches `schemas/review-output.json`
when it completes normally, including local `blocked` and `needs_context` results.

Render responses this way:

- If `status` is `issues_found`: list findings first, ordered `critical`, `important`, `nitpick`, and grouped by `category`
- If `status` is `clean`: say `No significant issues found`, then mention any open questions
- If `status` is `needs_context` or `blocked`: show the summary first, then the open questions

For `blocked` results caused by budget or timeout:

- explicitly call out the configured/effective limit that was hit
- include the corresponding command hint:
  - budget: `/claude set budget <usd>`
  - timeout: `/claude set timeout <seconds>`
- keep the hint short and concrete

`scripts/run-review.sh` treats `REVIEW_TIMEOUT_SECONDS` as the configured floor for
the real review call. It may raise the effective timeout based on artifact size,
model, and effort, and it retries exactly once when the first real review call times
out. Do not retry additional times in the Codex rendering layer.

Do not include budget or timeout on every successful review result. Show them only when:

- the user asks for config with `/claude show`
- the bridge blocks on budget or timeout
- the user explicitly asks for diagnostics

Each finding should include:

- `finding_key`
- `category`
- `action`
- `severity`
- `title`
- `evidence`
- `recommendation`
- optional file and line when present

For iterate mode, also include:

- rounds attempted
- final disposition: `clean`, `clean_with_nits`, `stopped_repeated_findings`, `blocked`, or `max_rounds_reached`
- a compact unresolved-decision list when any `ask_user_first` findings remain
- the highest-severity unresolved finding, if any

Do not emit inline code-comment directives in this skill. Keep the response in normal
Codex review style.

## Constraints

- Native-only. Do not route any review flow through Claude-side gstack.
- Do not use `--bare`; this workflow depends on first-party Claude subscription auth.
- Do not fall back to Anthropic API keys. The bridge intentionally scrubs Anthropic API credential env vars before calling Claude.
- Do not give Claude tools. Keep `--tools ""`.
- Improve review quality by strengthening prompts and artifacts, not by letting Claude inspect the repo directly.
- Keep plain `/claude review` report-only.
- In iterate mode, Claude remains report-only; Codex performs the plan or code changes between rounds.
- Never exceed 10 Claude review rounds in a single iterate invocation.
