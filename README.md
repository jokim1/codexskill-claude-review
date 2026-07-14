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

The Codex skill name and supported command family are both `claude-review`.
Use `/claude-review ...` for review, config, and update commands.

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
  Code and PR artifacts are never silently truncated; oversized artifacts are split
  into multiple bounded review parts. Split reviews preserve the content across
  parts, but each Claude call sees only one part plus repeated scope metadata, so
  cross-file reasoning can be weaker than a single whole-diff review.
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

`/claude ...` is intentionally not documented as a supported command for this
skill. If another installed skill owns `/claude`, usually GStack, that is fine. Use
`/claude-review ...` when you want this bridge.

## Command Reference

Supported commands:

### Code Review

| Command | What it does |
| --- | --- |
| `/claude-review` | Review the current code diff. Same as `/claude-review code`. |
| `/claude-review code [optional focus]` | Run the normal broad pre-merge review for correctness, regressions, security, tests, and maintainability. Optional focus text narrows the review, such as `focus on auth edge cases`. |
| `/claude-review challenge` | Run an adversarial failure-mode review of the current code diff. Same as `/claude-review challenge code`. |
| `/claude-review challenge code [optional focus]` | Run code challenge mode with optional one-off focus text, such as retries, stale state, auth, or concurrency. |
| `/claude-review iterate` | Let Codex fix actionable findings and rerun code review. Same as `/claude-review iterate code`. |
| `/claude-review iterate code` | Run the code fix-and-rereview loop until clean, blocked, repeated, or 10 rounds have been attempted. |

### Plan Review

| Command | What it does |
| --- | --- |
| `/claude-review plan` | Review the most recent visible `<proposed_plan>` block in the conversation. |
| `/claude-review plan [path to plan doc]` | Review a specific markdown plan file. |
| `/claude-review challenge plan [path to plan doc]` | Run an adversarial failure-mode review of a visible plan or plan file. |
| `/claude-review iterate plan [path to plan doc]` | Let Codex revise the visible plan or plan file and rerun plan review until clean, blocked, repeated, or 10 rounds have been attempted. |

### Pull Request Review

| Command | What it does |
| --- | --- |
| `/claude-review pr [PR number]` | Review a GitHub PR using `gh pr view` and `gh pr diff`. |

### Housekeeping

| Command | What it does |
| --- | --- |
| `/claude-review show` | Show the effective repo-local review configuration. |
| `/claude-review doctor` | Diagnose install, routing, Claude auth, sandbox, and runner issues. |
| `/claude-review set effort [effort level]` | Set Claude review effort for this repo. Choose `low`, `medium`, `high`, `xhigh`, or `max`. `extra-high` is accepted as an alias for `xhigh`. |
| `/claude-review set model [model alias or full model id]` | Set the Claude model for this repo. |
| `/claude-review set budget [budget in USD]` | Set the review budget guardrail. |
| `/claude-review set timeout [timeout in seconds]` | Set the review timeout floor. |
| `/claude-review update` | Update the installed skill checkout with a fast-forward-only merge from `origin/main`. |
| `/claude-review update --check` | Check whether an update is available without changing the installed skill checkout. |

Every `/claude-review ...` command except `/claude-review update` and
`/claude-review doctor` runs a low-noise update check first. If a new version is
available, Codex asks whether to update before continuing.

Out of scope:

No `/claude ...` commands are handled by this bridge. If `/claude challenge` works
on your machine, that is a separate installed skill, usually GStack's wrapper.

## How It Works

The bridge keeps a strict division of labor:

1. Codex builds a review artifact from the visible plan, current diff, or PR diff.
2. If a code or PR artifact exceeds 200000 bytes, Codex reviews split artifact
   parts instead of truncating the diff. For tightly coupled cross-file changes,
   narrow the diff when possible so related code lands in the same review call.
   Split directories are fresh and single-use so retries cannot clobber parts that
   a prior review call may still be consuming.
   If `CLAUDE_REVIEW_MAX_ARTIFACT_BYTES` is overridden, use the same value for the
   build step and every review call; the runner never raises its cap from artifact
   headers.
3. Codex calls `scripts/run-review.sh`.
4. The runner selects Claude from inherited PATH, the official native-user
   launcher, or the documented platform-default Homebrew launcher and validates
   both its launch path and canonical target.
5. The shared direct runtime preserves inherited PATH and configuration/network
   environment while scrubbing Anthropic API credentials plus `BASH_ENV`/`ENV`.
6. The runner performs a tiny subscription-auth preflight through the local
   `claude` CLI.
7. Claude receives only the artifact and bundled prompt, with no tools.
8. Claude returns structured JSON matching `schemas/review-output.json`.
9. Codex renders findings first, then decides what to fix.

The important consequence: Claude is an independent reviewer, not the implementer.

## Which Command Should I Use?

Use `/claude-review code` when you want a normal merge-readiness review of the
current diff. This is the default review mode. It asks Claude to look for concrete
issues that could change what ships, how the change is implemented, or what needs
to be tested before merge.

Use `/claude-review challenge` when you want an adversarial production-pressure
review of the current diff. It looks at the same code artifact as normal code
review, but uses a narrower prompt focused on ways the change can fail in real
systems: retries, stale state, duplicate work, partial failure, bad ordering,
concurrency, rollback, auth, and trust-boundary mistakes.

Use `/claude-review iterate` when you want Codex to run review, fix actionable
findings, verify locally, and ask Claude to review again. Claude stays
report-only. Codex performs the code or plan changes between rounds.

Quick rule of thumb:

| Command | What it reviews | Best for | What happens after findings |
| --- | --- | --- | --- |
| `/claude-review` or `/claude-review code` | Current diff | Default pre-merge review for correctness, regressions, security, tests, and maintainability | Report-only. Codex shows findings and waits for the next instruction. |
| `/claude-review challenge` | Current diff | Risky production changes involving auth, data writes, jobs, queues, migrations, payments, webhooks, retries, or concurrency | Report-only. Codex shows adversarial failure-mode findings and stops. |
| `/claude-review iterate` | Current diff | When you want Codex to fix Claude's actionable findings and rerun review until clean or stopped | Fix-and-rereview loop, up to 10 review rounds. |
| `/claude-review plan <path>` | Plan file or visible plan | Checking a plan before implementation | Report-only plan findings. |
| `/claude-review iterate plan <path>` | Plan file or visible plan | Improving a plan until it is decision-complete and testable | Codex revises the plan and reruns plan review, up to 10 rounds. |

For important or high-risk changes, a good sequence is:

```text
/claude-review code
/claude-review challenge
```

Run `code` first for broad review coverage, then `challenge` for adversarial
failure-mode pressure testing.

## Install

Clone this repo into your Codex skills directory:

```bash
git clone https://github.com/jokim1/codexskill-claude-review.git ~/.codex/skills/claude-review
chmod +x ~/.codex/skills/claude-review/scripts/*.sh
```

Then restart Codex and verify the installed bridge:

```text
/claude-review doctor
```

For local development, keep a source checkout and symlink the installed skill:

```bash
git clone https://github.com/jokim1/codexskill-claude-review.git /Users/josephkim/dev/codexskill-claude-review
rm -rf ~/.codex/skills/claude-review
ln -s /Users/josephkim/dev/codexskill-claude-review ~/.codex/skills/claude-review
chmod +x /Users/josephkim/dev/codexskill-claude-review/scripts/*.sh
```

Then restart Codex and run `/claude-review doctor`.

## Requirements

You need:

- Codex
- `claude` CLI installed
- `git`
- `python3`
- `jq`
- `gh` for `/claude-review pr <number>`

Use Claude subscription login:

```bash
claude auth login --claudeai
```

This bridge intentionally does not use Anthropic Console API billing. It scrubs
`ANTHROPIC_API_KEY` and related Anthropic API credential env vars before invoking
`claude`.

## First-Time Check

Start with the bridge's own post-install check so discovery, trust, direct runtime,
and subscription-only auth are tested under the same environment a review uses:

```text
/claude-review doctor
```

If doctor reports that subscription auth is unavailable, run:

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
/claude-review plan docs/checkout-refactor-plan.md
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
/claude-review
```

Codex will:

- detect the base branch
- build an untruncated artifact from the current diff
- split the review into bounded 200000-byte parts when the artifact is too large,
  up to the configured split-part cap, using a fresh single-use split directory
- call Claude with `prompts/code-review.base.md`
- render structured findings with file and line references when available

This is the standard broad review path. Use it before merge when you want coverage
for correctness, regressions, security, data-safety, tests, user-visible edge
cases, and major maintainability problems.

You can add one-off focus text:

```text
/claude-review code focus on migration risk and dead abstractions
```

### 3. Let Codex Fix Findings

For a report-only pass, run `/claude-review` and then ask Codex to fix the
findings you accept.

For a bounded fix-and-rereview loop, run:

```text
/claude-review iterate
```

Codex will:

- run Claude review
- apply fixes for actionable findings
- run relevant local verification
- rerun Claude review
- stop when clean, blocked, repeated, or after 10 rounds

Claude remains report-only during the loop. Codex performs all edits. Iterate is
useful when you want review findings handled immediately instead of manually
choosing each next step.

### 4. Review a PR

If the repository is connected to GitHub and `gh` is authenticated:

```text
/claude-review pr 123
```

Codex will use `gh pr view` and `gh pr diff` to build the review artifact.

### 5. Tune the Bridge

Show current config:

```text
/claude-review show
```

Increase timeout for large diffs:

```text
/claude-review set timeout 600
```

Raise the review budget guardrail:

```text
/claude-review set budget 8
```

Set effort:

```text
/claude-review set effort xhigh
```

The config is stored per repo at:

```text
<repo>/.codex/claude/config.env
```

## End-To-End Journey: Claude Challenge

Challenge review means an adversarial pass: instead of asking "is this correct
enough to ship?", it asks "how does this break under production pressure?"

Use challenge after normal code review, or on its own when the diff touches a
failure-prone path such as auth, data mutation, queues, webhooks, payments,
migrations, retries, concurrency, rollback, or external side effects.

Typical challenge concerns include:

- race conditions and concurrency interleavings
- retries, idempotency, and duplicate work
- stale state and terminal-state overwrites
- partial failure, cancellation, and resource leaks
- data loss, silent corruption, and permission bypasses
- migration, rollback, compatibility, and operational failure modes

### Current Bridge Behavior

This repo implements first-class challenge commands through the same local runner,
schema validation, and no-tools Claude invocation as normal review:

```text
/claude-review challenge
/claude-review challenge code
/claude-review challenge plan
```

If `/claude challenge` works on your machine today, that is coming from another
installed skill, usually GStack's `gstack-claude` wrapper. This bridge's challenge
command family is `/claude-review challenge ...`.

### Challenge Usage

Use code challenge for the current diff:

```text
/claude-review challenge code focus on race conditions, retries, idempotency, stale state, partial failure, and data loss
```

For plans:

```text
/claude-review challenge plan docs/checkout-refactor-plan.md
```

Challenge behavior:

1. Codex routes through the `claude-review` skill, not GStack.
2. Code challenge uses the same untruncated, split-capable current-diff artifact
   flow as normal review.
3. Plan challenge uses a file path or visible `<proposed_plan>`.
4. Claude receives a dedicated challenge prompt.
5. The runner stamps the output mode as `challenge_code` or `challenge_plan`.
6. Codex renders findings first and does not enter an automatic fix loop.

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

## Claude Discovery And Direct Runtime

The bridge uses one bounded discovery order:

1. Bash executable-only PATH lookup (`type -P claude`). Aliases, functions, and
   keywords are ignored. If no executable resolves, the bridge scans PATH entries
   only to diagnose the first present stale `claude` file or symlink instead of
   silently masking it with a fallback.
2. On macOS, Linux, and WSL, absolute inherited
   `$HOME/.local/bin/claude`, the official native-user launcher location. A missing
   or relative HOME disables this slot; the bridge never guesses another user's
   home.
3. Documented default Homebrew locations: `/opt/homebrew/bin/claude` then
   `/usr/local/bin/claude` on macOS regardless of process architecture, or
   `/home/linuxbrew/.linuxbrew/bin/claude` on Linux x86_64.

Custom Homebrew/npm prefixes, WinGet, system package-manager installs, and other
trusted installations remain supported through inherited PATH. Native Windows Git
Bash stays PATH-only. Linux ARM does not guess a Linuxbrew default.

PATH is authoritative. A non-executable, non-regular, unsafe, or runtime-broken
selected entry blocks rather than silently switching Claude versions. Within the
fixed native/Homebrew fallback slots, only a dangling symlink is deferred; a later
healthy default may run, while doctor reports `stale_fallback_source`,
`stale_fallback_path`, and `stale_fallback_status=dangling_symlink` with cleanup
guidance. Deferral requires bounded resolution to prove that the final target is
absent through an accessible parent. Symlink loops and inaccessible targets are
not treated as dangling and remain authoritative fail-closed diagnoses.

Every selected launcher is normalized to an absolute path by physically resolving
its parent, while its final symlink name is preserved for execution. The canonical
target is recorded separately. Both launch and target chains must be regular,
executable, outside repo/invocation/temp boundaries, and free of world-writable
executable files and parents before Claude runs.

Trust validation prefers the fixed `/usr/bin` or `/bin` `stat` and `readlink`
utilities. On NixOS it may use PATH-resolved regular executables only when their
physical paths are inside the immutable `/nix/store` boundary. Every intermediate
launcher symlink hop receives the same boundary validation as the launch and final
target. If no trusted validation utility is available, the bridge fails closed with
`claude_path_status=unsafe_candidate` and
`claude_trust_reason=validation_unavailable`; it never substitutes an arbitrary
PATH utility or misreports the candidate as world-writable/dangling.

Runner and doctor then execute the validated launch path directly from a private
`/tmp/claude-review-runtime-*` directory. They preserve inherited PATH byte-for-byte
for Claude and its descendants; they do not prepend the launcher directory, start
a login shell, source profiles, or retry through an interactive shell. They unset
only `BASH_ENV`, `ENV`, and the five Anthropic API credential variables used to
enforce subscription-only review. `scripts/claude-subscription-env.sh` remains as a
compatible legacy entry point, but runner and doctor share `claude-runtime.sh`.
For Git Bash timeout/probe calls through native Python, that shared runtime converts
the validated launcher and validated executable paths in its shebang execution
chain with the fixed `/usr/bin/cygpath` utility. It passes the interpreter chain,
optional `env NAME` token, launcher, and unchanged remaining arguments as discrete
argv. The bridge disables automatic MSYS conversion only while entering native
Python, then restores the inherited setting for Claude; it does not build a shell
command string or depend on ambient MSYS argument-conversion settings.

This direct-runtime hardening intentionally removes the former implicit login-
profile fallback. A launcher whose shebang names an interpreter available only
after profile loading reports `launcher_dependency_missing`. A recognized
interpreter that resolves through inherited PATH, or an argument-free absolute
shebang interpreter, must pass the same path, symlink-chain, file-mode, and parent trust
validation as the Claude launcher. The bridge recursively inspects script
interpreters with an eight-hop depth bound and cycle detection, and trust-validates
every executable in the resulting chain. An unsafe interpreter reports
`launcher_dependency_unsafe`; an unreadable launcher or interpreter reports
`launcher_dependency_unreadable`. Shebangs other than an argument-free absolute
interpreter or exact `#!/usr/bin/env NAME` form fail closed as
`launcher_dependency_unsupported` rather than being executed without deterministic
dependency validation. For `env NAME`, PATH lookup is evaluated from the same
private runtime directory used for execution, so a relative PATH entry cannot be
validated against the invocation directory and then select a different executable
after the runtime changes directory. Expose a trusted interpreter to the environment
that launches Codex, or migrate to native Claude:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Then run `/claude-review doctor`. Claude-started child executables also receive only
Codex's inherited PATH. Unknown descendant failures stay generically classified
rather than being inferred from arbitrary stderr.

Profile-only `CLAUDE_CONFIG_DIR`, proxy, custom-CA, certificate-store, and mTLS
exports are not imported either. Doctor reports only `present` or `absent` for the
supported inherited variables and prints `login_profile_loaded=false`; it never
prints their values or reads profile/settings contents. Put required values in the
environment that launches Codex or in Claude `settings.json` as appropriate.

Doctor's main discovery states are `available`, `installed_not_on_path`,
`not_executable`, `not_regular`, `dangling_symlink`, `unsafe_candidate`,
`launcher_dependency_missing`, `launcher_dependency_unsafe`,
`launcher_dependency_unsupported`, `launcher_dependency_unreadable`, and
`not_found`. `not_found` means only that PATH and the bounded official/default
locations did not contain a candidate; it does not prove Claude is uninstalled.
Doctor is report-only and will not edit PATH or shell files, install Claude, or
create symlinks. Its auth diagnostics explicitly use the same
`subscription_only_credentials_scrubbed` context as review, so an API-key-only
ordinary Claude setup may work even when bridge subscription auth is unavailable.

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
["bash", "/Users/<you>/.codex/skills/claude-review/scripts/run-review.sh"]
```

Do not approve broad prefixes such as `["bash"]`, and do not approve repo-local or
unreviewed copies of the helper.

Artifact builders, config helpers, and update checks do not need that approval.

## Troubleshooting

### `/claude-review` is not visible

Restart Codex after first install, replacing the installed skill, or changing a
symlinked install path.

### `/claude ...` routes to GStack

That is expected if GStack owns `/claude`. Use this bridge's canonical command
family instead:

```text
/claude-review update --check
```

Do not rely on `/claude ...` for this skill.

### `claude auth status` looks wrong

The bridge treats `claude auth status` as advisory. If the real scrubbed `claude -p`
probe works, review continues.

Doctor labels auth as `subscription_only_credentials_scrubbed`. An unavailable
bridge subscription session does not mean an ordinary API-key-authenticated Claude
CLI is broken; this bridge intentionally excludes API-key billing.

### Doctor reports `installed_not_on_path`

The launcher was found in the official native-user or documented default Homebrew
location even though Codex's inherited PATH omitted it. Runner and doctor invoke
that validated absolute launcher without editing PATH. No shell-file change or
symlink is required for this bridge.

If `stale_fallback_status=dangling_symlink` also appears, remove or reinstall the
named stale launcher. Only dangling fixed-slot links are deferred; other invalid
selected installations block so the bridge does not silently switch versions.

### Doctor reports `not_found`

This result is intentionally inconclusive: no launcher was found on inherited PATH
or in an applicable official/default fallback. Custom Homebrew/npm prefixes and
Windows package installs remain PATH-only. Verify the intended install is exposed
to the environment that launches Codex, or install native Claude and restart/retry
from Codex.

### Doctor reports `launcher_dependency_missing`

The selected launcher is a script whose deterministic shebang interpreter is not
available. Doctor reports `claude_launcher_dependency_resolution=path` for an
`env NAME` lookup; add that name to the environment that launches Codex or migrate
to native Claude. It reports `absolute` plus the exact path for a missing absolute
shebang; repair or reinstall that launcher because changing PATH cannot satisfy an
absolute shebang. The bridge will not source login profiles as a compatibility
fallback.

### Doctor reports `launcher_dependency_unsafe`

The selected launcher's recognized shebang interpreter resolved to an untrusted
file or path. Doctor reports the interpreter path and its independent trust scope
and reason without executing it. Remove the untrusted PATH entry or expose a
trusted interpreter outside repository, invocation-CWD, temp, world-writable file,
and world-writable parent boundaries. The bridge will not weaken launcher trust or
rewrite PATH to select a different interpreter.

### Doctor reports `launcher_dependency_unsupported`

The selected launcher uses shebang syntax the bridge cannot parse without
reimplementing platform-specific shebang argument or `env -S` tokenization. Use a
launcher with an argument-free absolute interpreter or exact
`#!/usr/bin/env NAME` shebang, or migrate to native Claude.
The bridge fails closed instead of executing an unvalidated interpreter.

### Doctor reports `launcher_dependency_unreadable`

The selected launcher or one of its recursive shebang interpreters could not be
opened for bounded inspection. Make the reported path readable to the Codex
process or reinstall native Claude. The bridge does not assume an unreadable file
is a native binary.

### Doctor reports `validation_unavailable`

The bridge could not find trusted `stat` or `readlink` support for the selected
launcher. Restore the platform coreutils under `/usr/bin` or `/bin`, or on NixOS
expose the immutable `/nix/store` coreutils through Codex's inherited PATH. The
bridge will not run a validator from a mutable custom PATH location.

### A review still uses raw `claude -p`

Run:

```text
/claude-review doctor
```

The doctor reports the installed skill SHA, router and runner paths, whether the
runner contains the hardened `--safe-mode` flags, and bounded plain vs safe-mode
Claude probes. If the runner is current but another thread still runs raw
`claude -p`, restart Codex or open a new thread so the skill instructions reload.

### Preflight says the budget is too low

Raise the live probe budget:

```env
LIVE_PROBE_BUDGET_USD=0.25
```

### Review times out

Large artifacts can take several minutes, especially with Opus and `xhigh` effort.
Raise the timeout or narrow the diff:

```text
/claude-review set timeout 600
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
- `scripts/claude-doctor.sh`
- `scripts/claude-locator.sh`
- `scripts/claude-runtime.sh`
- `scripts/claude-command-router.sh`
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
2. Keep `~/.codex/skills/claude-review` pointed at this checkout.
3. Restart Codex when skill metadata or routing changes.
4. Re-run a real `/claude-review` path.

Useful checks:

```bash
bash -n scripts/*.sh tests/*.sh
bash tests/claude-command-router.sh
bash tests/claude-doctor.sh
bash tests/claude-locator-runtime.sh
bash tests/run-review-sandbox-classification.sh
bash tests/claude-router-guard-docs.sh
bash tests/install-completeness.sh
```
