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
  `/claude-review challenge [inline review instructions]`,
  `/claude-review challenge code [inline review instructions]`,
  `/claude-review challenge plan [path-to-markdown-plan]`,
  `/claude-review instructions [plan|code]`,
  `/claude-review instructions set [plan|code] <markdown>`,
  `/claude-review instructions clear [plan|code]`,
  `/claude-review instructions set global [plan|code] <markdown>`,
  `/claude-review instructions clear global [plan|code]`,
  `/claude-review show`, `/claude-review doctor`,
  `/claude-review set effort <low|medium|high|xhigh|max>`,
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
  - `prompts/challenge-code.base.md`
  - `prompts/challenge-plan.base.md`
- JSON schema: `schemas/review-output.json`
- Config helper: `scripts/claude-config.sh`
- Command router: `scripts/claude-command-router.sh`
- Doctor helper: `scripts/claude-doctor.sh`
- Native Claude helper: `scripts/run-review.sh`
- Claude locator helper: `scripts/claude-locator.sh`
- Claude runtime helper: `scripts/claude-runtime.sh`
- Artifact builder: `scripts/build-review-artifact.sh`
- Update helper: `scripts/claude-update.sh`
- Update check helper: `scripts/claude-update-check.sh`

The bundled files live adjacent to this `SKILL.md`. Resolve those paths relative to
the skill directory.

## Artifact Size And Split Reviews

Each single Claude review call receives at most `200000` bytes of artifact content.
This is a review-quality guardrail, not a model context-window limit. The artifact
builder must never silently truncate source, test, template, or diff content to fit
that guardrail. Code and PR review splitting is capped at 12 parts by default
(`CLAUDE_REVIEW_MAX_SPLIT_PARTS`) to avoid unbounded Claude-call fan-out on huge or
generated diffs.

`scripts/run-review.sh` assembles each bounded prompt in its private runtime
directory with mode `0600` and streams it to `claude -p` on stdin. Never move the
artifact body back into one argv element: the 200000-byte contract exceeds
per-argument limits on supported Linux and Windows hosts. Keep control flags and
other bounded values as discrete argv.

If `CLAUDE_REVIEW_MAX_ARTIFACT_BYTES` is overridden for artifact building, export
the same value for every corresponding `scripts/run-review.sh` call. The runner
does not trust or raise its byte guardrail from artifact content, including split
part headers.

For code and PR reviews, always pass `--split-output-dir <temp-split-dir>` to
`scripts/build-review-artifact.sh`. Use a freshly-created temp artifact file and a
fresh, single-use split directory under `/tmp`; the split directory basename must
start with `claude-review-`. Do not reuse a split directory after the builder exits,
because its manifest and part files may still be consumed by later review calls.
The split directory lock is a build-time guard for fresh temp directories, not a
durable lease for deterministic or reused paths.

The builder writes the full, untruncated artifact to `--output-file` in every case.
If that full artifact fits under `200000` bytes, no split manifest is written and
the normal single `scripts/run-review.sh` call should review `--output-file`.

If the full artifact exceeds `200000` bytes, the builder writes:

- `<temp-split-dir>/manifest.txt`
- one or more `/tmp/.../claude-review-part-NNN.txt` split artifacts

In that case, do not pass the full artifact to `scripts/run-review.sh`; the runner
will reject it as oversized. Instead, read `manifest.txt`, run the same
`scripts/run-review.sh` command once per listed `Part file:`, and render one merged
review result.

Split review preserves the full artifact across bounded parts, but it is not
identical to one whole-diff Claude call. Each Claude call sees the repeated scope
metadata plus only the files or diff chunks listed for that part, so cross-file
reasoning can be weaker when a defect depends on simultaneously reading code split
across different parts. When that fidelity matters, narrow the diff or split the
change into tighter, related review batches.

Merged split review rendering rules:

- First classify every listed part. If any part failed, returned unparseable
  output, or returned `blocked`/`needs_context`, surface those part-level
  blockers/questions even when other parts returned `issues_found`.
- If some parts completed and some parts did not, mark the merged result as
  partial coverage, including the completed-part count and total-part count.
- If every part completed and any part returns `issues_found`, merge all findings,
  annotate unclear evidence with the split part number, then order by severity and
  category as usual.
- If every part completed as `clean`, report that no significant issues were found
  across all split parts.
- Do not treat split parts as Claude edit/fix rounds. In iterate mode, one split
  review cycle may contain multiple Claude calls, but the 10-round iterate limit
  still counts fix-and-rereview cycles, not individual split parts.

If artifact building exits because a full artifact is too large and split artifacts
could not be produced, or because the split would exceed the configured max part
count, respond with `STATUS: BLOCKED`, explain the split-generation failure, and
recommend narrowing the diff.

## Command Routing

Match only the explicit `/claude-review` command and `/claude-review ...` command family.

Canonical review forms:

- `/claude-review`
- `/claude-review code [inline review instructions]`
- `/claude-review plan [path]`
- `/claude-review pr <number>`
- `/claude-review challenge [inline review instructions]`
- `/claude-review challenge code [inline review instructions]`
- `/claude-review challenge plan [path]`
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
- `/claude-review doctor`
- `/claude-review set effort <low|medium|high|xhigh|max>`
- `/claude-review set model <alias-or-full-model>`
- `/claude-review set budget <usd>`
- `/claude-review set timeout <seconds>`
- `/claude-review update`
- `/claude-review update --check`

When these instructions refer to "inline review instructions," use the literal text
after `/claude-review code` or `/claude-review review code`. Treat those as one-off
appended instructions after bundled, user-level, and repo-level prompts.

Before executing a `/claude-review ...` command, route it through:

```bash
bash <skill-dir>/scripts/claude-command-router.sh \
  --repo-root <repo-root> \
  --skill-root <skill-dir> \
  --has-visible-plan <true|false> \
  -- /claude-review <tokens...>
```

Pass user-controlled command text as argv data after `--`; do not interpolate the
literal user command into a shell string. If a caller must use `--command`, pass it
as a tool argument value, not by constructing a shell command with user text inside
quotes.

Validate the router output before invoking Claude or any admin helper. If the router
output is invalid JSON, missing `status`, has an unknown `flow`, or returns
`needs_context` without a non-empty `message`, respond with `STATUS: BLOCKED`,
explain that command routing returned malformed output, and do not invoke Claude.

Do not run raw `claude -p` health checks directly from the Codex rendering layer.
Use `scripts/claude-doctor.sh` for diagnostics and `scripts/run-review.sh` for all
review probes and review invocations. Both helpers own the hardened Claude flags.

Runner and doctor must use only the exact `python3` accepted by
`claude_runtime_resolve_trusted_python`, and every bridge Python invocation must
retain isolated mode (`-I`). The resolver applies the Claude trust policy to the
Python launch path and rejects script-shaped Python launchers so `-I` cannot be
reinterpreted as a script argument. Do not fall back to a second PATH lookup.
Temporary trust boundaries include inherited absolute `TMPDIR`, `TEMP`, and `TMP`
roots plus the macOS `/var/folders` namespace.

The shared runtime driver owns bounded child-process lifetime. On Windows it creates
the child suspended, assigns it to a kill-on-close Job Object, and only then resumes
it so the complete descendant tree is owned from its first instruction; on POSIX it
uses a private process group. Do not replace either path with direct-process-only
`terminate()`/`kill()` or an unbounded final output drain.

### Claude State Writes And Codex Sandbox Boundary

Review flows may need to run `scripts/run-review.sh` outside the Codex filesystem
sandbox when the command tool supports that choice. The bridge eventually shells out
to `claude -p`, and Claude Code may need to create lock or refresh files under
`~/.claude` even for report-only review. A sandboxed parent Bash process causes the
child `claude` process to inherit the same write restrictions, which can fail with
`EPERM` on paths such as `~/.claude/.oauth_refresh.lock`.

Use the normal sandbox for artifact builders, config helpers, and update checks. If
Claude reports a denied write to `~/.claude` or `CLAUDE_CONFIG_DIR`, first determine
whether the review bridge itself was sandboxed. Only the review bridge may need this
boundary:

```text
approved prefix: ["<trusted-bash>", "--noprofile", "--norc", "-p", "<skill-dir>/scripts/run-review.sh"]
```

Every runner and doctor invocation must set `BASH_ENV=` and `ENV=` before starting
an exact trusted Bash with `--noprofile --norc -p`. Privileged mode prevents Bash
from importing exported functions before the bridge bootstrap. Use `/bin/bash` when present; on
NixOS use an absolute, non-symlink Bash whose physical path is inside `/nix/store`.
Never use a bare `bash` or a mutable custom PATH result. The bridge captures the
caller's PATH as data, then builds its utility PATH only from fixed `/usr/bin` and
`/bin`, fixed Git-for-Windows roots on Git Bash, plus physically resolved inherited
directories inside `/nix/store`. A Nix profile symlink is accepted only when its
final inode matches a regular executable target inside the immutable store. An FHS
`readlink` trust anchor must be a non-symlink executable or an inode-verified
immutable-store target and is never executed to validate itself. Other FHS utility
symlinks are accepted only through a bounded `/usr/bin`, `/bin`, or
`/etc/alternatives` chain ending at a regular executable in `/usr/bin` or `/bin`.
The validated Claude child still receives the original inherited PATH. Approving the prefix above grants
unsandboxed execution to the installed skill script, so only approve the exact
installed skill path you trust. Do not approve broad shell prefixes, and do not
approve repo-local or unreviewed copies of the helper.

If the command tool cannot request unsandboxed execution and this prefix is not
already approved, surface the blocked result from `run-review.sh` and tell the user
to approve that exact trusted prefix before retrying. If the same error persists
outside the Codex sandbox, tell the user to check ownership and permissions for
`~/.claude` or `CLAUDE_CONFIG_DIR`. Do not treat this as Claude login failure when
`auth status` is readable but the live probe reports `EPERM`, `.claude`, or
`oauth_refresh.lock`.

### Update Preflight

Before handling any `/claude-review ...` command except `/claude-review update` and
`/claude-review doctor` themselves, check for a newer skill version:

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
BASH_ENV= ENV= <trusted-bash> --noprofile --norc -p <skill-dir>/scripts/run-review.sh \
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
  --output-file <temp-artifact-file> \
  --split-output-dir <temp-split-dir>
```

Use a temp artifact path matching `/tmp/claude-review-*` and a fresh, single-use
temp split directory under `/tmp` matching `/tmp/claude-review-*`.

4. If artifact building fails because merge base or base branch cannot be determined, respond:

```text
STATUS: BLOCKED
REASON: Could not determine a merge base for code review.
RECOMMENDATION: Ensure the repo has a reachable base branch or use /claude-review pr <number>.
```

5. If `<temp-split-dir>/manifest.txt` exists, run the split review flow from
   "Artifact Size And Split Reviews" using the same mode, prompt, config, branch,
   base branch, and inline instructions for every listed part. Otherwise invoke:

```bash
BASH_ENV= ENV= <trusted-bash> --noprofile --norc -p <skill-dir>/scripts/run-review.sh \
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

6. Parse the returned JSON or merged split JSON and render findings first, ordered
   by severity and grouped by category.

### `/claude-review challenge [inline challenge focus]`

Equivalent to `/claude-review challenge code [inline challenge focus]`.

### `/claude-review challenge code [inline challenge focus]`

1. Resolve the repo root and detect the base branch with the same steps as
   `/claude-review code`.
2. Build the current-diff artifact with the same `scripts/build-review-artifact.sh
   --mode code --split-output-dir <temp-split-dir>` flow as `/claude-review code`.
   Challenge mode changes the Claude prompt and returned `mode`; it does not use a
   separate artifact-builder mode.
3. If `<temp-split-dir>/manifest.txt` exists, run the split review flow from
   "Artifact Size And Split Reviews" using `--mode challenge_code` for every listed
   part. Otherwise invoke:

```bash
BASH_ENV= ENV= <trusted-bash> --noprofile --norc -p <skill-dir>/scripts/run-review.sh \
  --mode challenge_code \
  --artifact-file <temp-artifact-file> \
  --base-prompt <skill-dir>/prompts/challenge-code.base.md \
  --append-prompt ~/.codex/claude/code-review.append.md \
  --append-prompt <repo>/.codex/claude/code-review.append.md \
  --config-file <repo>/.codex/claude/config.env \
  --schema-file <skill-dir>/schemas/review-output.json \
  --repo-root <repo-root> \
  --branch <current-branch> \
  --base-branch <base-branch> \
  --instructions "<inline challenge focus>"
```

4. Parse the returned JSON and render findings first, ordered by severity and
   grouped by category. Do not enter iterate/fix loops from a challenge result.

### `/claude-review challenge plan [path]`

1. Use the same plan source rules as `/claude-review plan [path]`: a readable,
   non-empty path from the router when present, otherwise the most recent visible
   `<proposed_plan>` block when available.
2. Write the plan text to a temp file matching `/tmp/claude-review-*`.
3. Invoke:

```bash
BASH_ENV= ENV= <trusted-bash> --noprofile --norc -p <skill-dir>/scripts/run-review.sh \
  --mode challenge_plan \
  --artifact-file <temp-plan-file> \
  --base-prompt <skill-dir>/prompts/challenge-plan.base.md \
  --append-prompt ~/.codex/claude/plan-review.append.md \
  --append-prompt <repo>/.codex/claude/plan-review.append.md \
  --config-file <repo>/.codex/claude/config.env \
  --schema-file <skill-dir>/schemas/review-output.json \
  --repo-root <repo-root> \
  --branch <current-branch>
```

4. Parse the returned JSON and render findings first, ordered by severity and
   grouped by category. Do not revise the plan automatically from a challenge
   result; stop after surfacing the adversarial findings.

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
  --output-file <temp-artifact-file> \
  --split-output-dir <temp-split-dir>
```

Use a temp artifact path matching `/tmp/claude-review-*` and a fresh, single-use
temp split directory under `/tmp` matching `/tmp/claude-review-*`.

4. If `<temp-split-dir>/manifest.txt` exists, run the split review flow from
   "Artifact Size And Split Reviews" using `--mode pr`, the code-review prompt,
   both append prompts, and `--pr-number <number>` for every listed part.
   Otherwise invoke `scripts/run-review.sh` once with `--mode pr`, the full
   artifact, the code-review prompt, both append prompts, and `--pr-number
   <number>`.
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

### `/claude-review doctor`

Run:

```bash
BASH_ENV= ENV= <trusted-bash> --noprofile --norc -p <skill-dir>/scripts/claude-doctor.sh \
  --repo-root <repo-root> \
  --skill-root <skill-dir> \
  --config-file <repo>/.codex/claude/config.env
```

`--skill-root` must physically match the root containing the invoked doctor. It is
an assertion only and must never redirect config, locator, or runtime helper loading.

Render the command output directly. Use this command to diagnose stale skill
checkouts, stale Codex thread routing, missing safe-mode runner flags, Claude CLI
discovery/trust/runtime/auth/config problems and inherited environment. Doctor
always skips the mutating update helper. It is diagnostic and report-only: it must
not install Claude, edit PATH
or shell configuration, create a symlink, refresh a Git index, execute a Git
fsmonitor hook, or otherwise mutate the user's system. Checkout diagnostics must
disable optional locks and ignore inherited Git repository/config routing overrides.
Treat `claude_trust_reason=validation_unavailable` as a fail-closed unsafe-candidate
diagnosis; do not recommend bypassing trust validation or using a mutable PATH
utility in order to continue.
Treat `claude_path_status=launcher_dependency_unsafe` the same way: the recognized
shebang interpreter failed the launcher's trust boundary and must not be executed.
Use the emitted `claude_launcher_dependency_path`, trust scope, and trust reason to
explain which inherited-PATH or absolute interpreter needs repair.
For `claude_path_status=launcher_dependency_missing`, use
`claude_launcher_dependency_resolution`: recommend an inherited-PATH change only
for `path`; for `absolute`, tell the user to repair or reinstall the exact reported
shebang path because PATH cannot fix it.
Treat `claude_path_status=launcher_dependency_unsupported` as fail-closed too; use
an argument-free absolute interpreter or exact `#!/usr/bin/env NAME` launcher
rather than trying to interpret or bypass unsupported `env -S` syntax in the
rendering layer.
Treat `claude_path_status=launcher_dependency_unreadable` as fail-closed; repair
read access to the reported launcher/interpreter chain or reinstall native Claude.
Treat symlink loops and inaccessible targets as fail-closed
`validation_unavailable` results, not dangling fallbacks. Only a bounded resolution
that proves an absent final target may be reported as `dangling_symlink` and defer
to a later fixed fallback.
Do not replace it with a hand-written `claude -p` probe.

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

## Blocked Review Recovery

When a rendered blocked result ends with this exact offer, preserve it verbatim:

```text
Run /claude-review doctor now?
Reply Y to run diagnostics, or N to stop.
```

The recognized immediate-response vocabulary is `Y`, `yes`, and `run doctor`.
If the immediately following user response is exactly one of those affirmatives,
run the canonical `/claude-review doctor` flow with the same repo root and config
file, render doctor output directly, and stop. Do not run the update preflight for
this doctor continuation. Do not retry the failed review automatically.

If the immediate response is `N` or otherwise declines, stop cleanly. A later or
unrelated `Y`, `yes`, or `run doctor` is not authorization: this convenience applies
only to the response immediately following the bridge's explicit doctor offer.
The full `/claude-review doctor` command remains the deterministic fallback if the
host does not interpret a short reply.

Doctor-eligible blockers are bounded to candidate-not-found, unusable or unsafe
Claude, launcher-dependency, subscription-auth, preflight timeout/failure, and
ambiguous invocation failures. Budget caps, review timeouts, artifacts, missing
context, command/config boundaries, helper-integrity failures, and Claude
state-write denial retain their direct remediation without this offer. Doctor is
diagnostic only: never modify PATH, install Claude, create symlinks, edit profiles,
or make other system changes in response to the offer.
Version, auth-status, and live-probe calls are bounded by the preflight timeout;
doctor renders timeout diagnostics rather than waiting indefinitely.

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
- Challenge modes (`challenge_code`, `challenge_plan`) are report-only. Render
  findings and stop; do not route challenge results into `/claude-review iterate`
  or any automatic fix-and-rereview loop.
- Never exceed 10 Claude review rounds in a single iterate invocation.
