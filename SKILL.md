---
name: claude-review
description: |
  Authoritative handler for the `/claude-review ...` command family from this installed
  skill. Use this instead of any GStack-provided claude/gstack-claude skill when
  the user asks for `/claude-review`, `/claude-review plan`, `/claude-review code`,
  `/claude-review update`, or any command listed here. Runs Claude Code from Codex for
  independent native-only plan review or code review without leaving Codex.
  Supports `/claude-review`, `/claude-review plan [path-to-markdown-plan]`,
  `/claude-review code [focus]`, `/claude-review iterate`, `/claude-review iterate plan`,
  `/claude-review iterate code`, `/claude-review pr <number>`,
  `/claude-review instructions [plan|code]`,
  `/claude-review instructions set [plan|code] <markdown>`,
  `/claude-review instructions clear [plan|code]`,
  `/claude-review instructions set global [plan|code] <markdown>`,
  `/claude-review instructions clear global [plan|code]`,
  `/claude-review show`, `/claude-review set effort <low|medium|high|xhigh|max>`,
  `/claude-review set model <alias-or-full-model>`,
  `/claude-review set budget <usd>`,
  `/claude-review set timeout <seconds>`, `/claude-review update`,
  `/claude-review update --check`, plus legacy aliases under
  `/claude-review review ...`.
---

# Claude Review Bridge

This skill uses the local `claude` CLI with the user's existing Claude subscription
login. It intentionally ignores Anthropic API credential env vars and does not fall
back to Anthropic API keys. Keep the workflow narrow, deterministic, and native-only:

- Plan review uses an explicit plan file path when supplied, otherwise the most
  recent visible `<proposed_plan>` block from the last 6 messages.
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
- Update helper: `scripts/claude-update.sh`
- Update check helper: `scripts/claude-update-check.sh`

The bundled files live adjacent to this `SKILL.md`. Resolve those paths relative to
the skill directory.

## Command Routing

Match only the explicit `/claude-review` command and `/claude-review ...` command family.

Canonical review forms:

- `/claude-review`
- `/claude-review code [inline review instructions]`
- `/claude-review plan [path]`
- `/claude-review pr <number>`
- `/claude-review iterate`
- `/claude-review iterate code`
- `/claude-review iterate plan [path]`
- `/claude-review instructions [plan|code]`
- `/claude-review instructions set [plan|code] <markdown>`
- `/claude-review instructions clear [plan|code]`
- `/claude-review instructions set global [plan|code] <markdown>`
- `/claude-review instructions clear global [plan|code]`

Legacy aliases remain supported:

- `/claude-review review`
- `/claude-review review code [inline review instructions]`
- `/claude-review review plan [path]`
- `/claude-review review pr <number>`
- `/claude-review review iterate`
- `/claude-review review iterate code`
- `/claude-review review iterate plan [path]`
- `/claude-review review instructions ...`

Use these config forms:

- `/claude-review show`
- `/claude-review set effort <low|medium|high|xhigh|max>`
- `/claude-review set model <alias-or-full-model>`
- `/claude-review set budget <usd>`
- `/claude-review set timeout <seconds>`
- `/claude-review update`
- `/claude-review update --check`

When these instructions refer to "inline review instructions," use the literal text
after `/claude-review code` or `/claude-review review code`. Treat those as one-off
appended instructions after bundled, user-level, and repo-level prompts.

### Claude State Writes And Codex Sandbox Boundary

Review flows may need to run `scripts/run-review.sh` outside the Codex filesystem
sandbox when the command tool supports that choice. The bridge eventually shells out
to `claude -p`, and Claude Code may need to create lock or refresh files under
`~/.claude` even for report-only review. A sandboxed parent `bash` process causes the
child `claude` process to inherit the same write restrictions, which can fail with
`EPERM` on paths such as `~/.claude/.oauth_refresh.lock`.

Use the normal sandbox for artifact builders, config helpers, and update checks. If
Claude reports a denied write to `~/.claude` or `CLAUDE_CONFIG_DIR`, first determine
whether the review bridge itself was sandboxed. Only the review bridge may need this
boundary:

```text
approved prefix: ["bash", "<skill-dir>/scripts/run-review.sh"]
```

Approving that prefix grants unsandboxed execution to the installed skill script, so
only approve the exact installed skill path you trust. Do not approve broad prefixes
such as `["bash"]`, and do not approve repo-local or unreviewed copies of the helper.

If the command tool cannot request unsandboxed execution and this prefix is not
already approved, surface the blocked result from `run-review.sh` and tell the user
to approve that exact trusted prefix before retrying. If the same error persists
outside the Codex sandbox, tell the user to check ownership and permissions for
`~/.claude` or `CLAUDE_CONFIG_DIR`. Do not treat this as Claude login failure when
`auth status` is readable but the live probe reports `EPERM`, `.claude`, or
`oauth_refresh.lock`.

### Update Preflight

Before handling any `/claude-review ...` command except `/claude-review update` itself, check for a
newer skill version:

```bash
bash <skill-dir>/scripts/claude-update-check.sh
```

If the output includes `JUST_UPDATED <old> <new>`, tell the user:

```text
Running /claude-review at <new> (just updated from <old>).
```

Then continue the requested command.

If the output includes `UPDATE_AVAILABLE <old> <new> <new-full-sha>`, ask the user
exactly:

```text
There is a new /claude-review update available (<old> -> <new>). Reply Y to update now, or N to skip for now.
```

Do not continue the requested command until the user answers. If the user answers
`Y` or `yes`, run:

```bash
bash <skill-dir>/scripts/claude-update.sh
```

Then tell the user the update result. If the update succeeded, stop and ask the user
to rerun the originally requested `/claude-review ...` command so Codex reloads the updated
skill instructions. Do not continue the original command in the same invocation.
If the user declines, run:

```bash
bash <skill-dir>/scripts/claude-update-check.sh --snooze <new-full-sha>
```

Then continue the originally requested command. If the update check fails or returns
no output, ignore it and continue. Never run the update preflight more than once per
user `/claude-review ...` invocation.

### `/claude-review`

Run `/claude-review code`. Bare `/claude-review` always reviews the current code
diff; it does not auto-select plan review from recent context. Use
`/claude-review plan` for plan review.

### `/claude-review review`

Legacy alias. Preserve the historical auto-select behavior:

1. Inspect the last 6 visible conversation messages, newest first.
2. If there is a recent assistant `<proposed_plan>` block, run `/claude-review plan`.
3. Otherwise run `/claude-review code`.

### `/claude-review plan [path]`

Legacy alias: `/claude-review review plan [path]`.

1. Parse an optional plan path after `/claude-review plan` or `/claude-review review plan`.
2. If a path is supplied:
   - Resolve it relative to the repo root unless it is absolute.
   - Require it to be a readable regular file.
   - Treat the full file contents as the plan artifact. Do not ask for a
     `<proposed_plan>` block.
   - If the file cannot be read, respond:

```text
STATUS: NEEDS_CONTEXT
REASON: The requested plan file could not be read.
RECOMMENDATION: Check the path, then run /claude-review plan <path> again.
```

3. If no path is supplied, extract the most recent visible assistant
   `<proposed_plan>` block from the last 6 messages.
4. If no path is supplied and no visible plan block exists, respond:

```text
STATUS: NEEDS_CONTEXT
REASON: No recent <proposed_plan> block is visible in this conversation.
RECOMMENDATION: Create or paste a plan, or run /claude-review plan <path-to-plan.md>.
```

5. Write the plan text to a temp file matching `/tmp/claude-review-*`.
6. Invoke:

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

7. Parse the returned JSON and render findings first, ordered by severity and grouped by category.

### `/claude-review code [inline review instructions]`

Legacy alias: `/claude-review review code [inline review instructions]`.

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

Use a temp artifact path matching `/tmp/claude-review-*`.

4. If artifact building fails because merge base or base branch cannot be determined, respond:

```text
STATUS: BLOCKED
REASON: Could not determine a merge base for code review.
RECOMMENDATION: Ensure the repo has a reachable base branch or use /claude-review pr <number>.
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

### `/claude-review pr <number>`

Legacy alias: `/claude-review review pr <number>`.

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

Use a temp artifact path matching `/tmp/claude-review-*`.

4. Invoke `scripts/run-review.sh` with `--mode pr`, the code-review prompt, both append prompts, and `--pr-number <number>`.
5. Parse the returned JSON and render findings first, ordered by severity and grouped by category.

### `/claude-review iterate`

Run `/claude-review iterate code`. Canonical iterate defaults to the current code
diff. Use `/claude-review iterate plan` for plan iteration.

### `/claude-review review iterate`

Legacy alias. Preserve the historical auto-select behavior:

1. Inspect the last 6 visible conversation messages, newest first.
2. If there is a recent assistant `<proposed_plan>` block, run `/claude-review iterate plan`.
3. Otherwise run `/claude-review iterate code`.

### `/claude-review iterate plan [path]`

Legacy alias: `/claude-review review iterate plan [path]`.

1. Run the same artifact-building and `scripts/run-review.sh --mode plan` flow as `/claude-review plan [path]`.
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

### `/claude-review iterate code`

Legacy alias: `/claude-review review iterate code`.

1. Run the same base-branch detection, artifact-building, and `scripts/run-review.sh --mode code` flow as `/claude-review code`.
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

### `/claude-review iterate pr <number>`

Legacy alias: `/claude-review review iterate pr <number>`.

Do not run an automatic fix loop from a PR number alone.

Respond:

```text
STATUS: NEEDS_CONTEXT
REASON: Iteration requires a checked-out branch or a visible plan, not just a remote PR diff.
RECOMMENDATION: Check out the PR branch locally and run /claude-review iterate code, or use /claude-review pr <number> for report-only review.
```

### `/claude-review instructions [plan|code]`

Legacy alias: `/claude-review review instructions [plan|code]`.

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

### `/claude-review instructions set [plan|code] <markdown>`

Legacy alias: `/claude-review review instructions set [plan|code] <markdown>`.

1. Determine the target mode from the command.
2. Treat everything after the mode token as literal markdown.
3. Create `<repo>/.codex/claude` if needed.
4. Replace the repo-level append file for that mode with exactly that markdown.
5. Confirm the path written, then show the effective instructions for that mode.

### `/claude-review instructions clear [plan|code]`

Legacy alias: `/claude-review review instructions clear [plan|code]`.

1. Determine the target mode from the command.
2. Remove the repo-level append file for that mode if it exists.
3. Confirm the clear action, then show the effective instructions for that mode.

### `/claude-review instructions set global [plan|code] <markdown>`

Legacy alias: `/claude-review review instructions set global [plan|code] <markdown>`.

1. Determine the target mode from the command.
2. Treat everything after the mode token as literal markdown.
3. Create `~/.codex/claude` if needed.
4. Replace the user-level append file for that mode with exactly that markdown.
5. Confirm the path written, then show the effective instructions for that mode.

### `/claude-review instructions clear global [plan|code]`

Legacy alias: `/claude-review review instructions clear global [plan|code]`.

1. Determine the target mode from the command.
2. Remove the user-level append file for that mode if it exists.
3. Confirm the clear action, then show the effective instructions for that mode.

### `/claude-review show`

Run:

```bash
bash <skill-dir>/scripts/claude-config.sh show \
  --config-file <repo>/.codex/claude/config.env
```

Print the returned effective values.

### `/claude-review update`

If the user passes `--check`, run:

```bash
bash <skill-dir>/scripts/claude-update.sh --check
```

Otherwise run:

```bash
bash <skill-dir>/scripts/claude-update.sh
```

Render the command output directly. If the update is blocked by a dirty checkout,
detached checkout, missing git install, or non-fast-forward history, surface the
blocker and do not try to repair it automatically.

### `/claude-review set effort <low|medium|high|xhigh|max>`

Run:

```bash
bash <skill-dir>/scripts/claude-config.sh set effort <value> \
  --config-file <repo>/.codex/claude/config.env
```

Print the returned effective values and confirm the updated effort. Treat
`extra-high` as a user-facing alias for `xhigh` when setting effort.

### `/claude-review set model <alias-or-full-model>`

Run:

```bash
bash <skill-dir>/scripts/claude-config.sh set model <value> \
  --config-file <repo>/.codex/claude/config.env
```

Print the returned effective values and confirm the updated model.

### `/claude-review set budget <usd>`

Run:

```bash
bash <skill-dir>/scripts/claude-config.sh set budget <value> \
  --config-file <repo>/.codex/claude/config.env
```

Print the returned effective values and confirm the updated budget.

### `/claude-review set timeout <seconds>`

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
  - budget: `/claude-review set budget <usd>`
  - timeout: `/claude-review set timeout <seconds>`
- keep the hint short and concrete

`scripts/run-review.sh` treats `REVIEW_TIMEOUT_SECONDS` as the configured floor for
the real review call. It may raise the effective timeout based on artifact size,
model, and effort, and it retries exactly once when the first real review call times
out. Do not retry additional times in the Codex rendering layer.

Do not include budget or timeout on every successful review result. Show them only when:

- the user asks for config with `/claude-review show`
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
- Update checks are allowed to use `git ls-remote`/`git fetch` against this skill's origin, but review flows remain native-only and report-only.
- Improve review quality by strengthening prompts and artifacts, not by letting Claude inspect the repo directly.
- Keep plain `/claude-review` report-only.
- In iterate mode, Claude remains report-only; Codex performs the plan or code changes between rounds.
- Never exceed 10 Claude review rounds in a single iterate invocation.
