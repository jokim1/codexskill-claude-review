# Plan: Claude Review Challenge Mode

Date: 2026-07-01

## Goal

Add first-class adversarial challenge review to this skill while avoiding command
confusion with GStack's Claude wrapper.

The result should let users run a reliable Claude adversarial review through this
repo's subscription-authenticated, timeout-bounded runner.

## What Already Exists

- `scripts/run-review.sh` already owns Claude CLI execution, subscription auth
  preflight, Anthropic API credential scrubbing, budget classification,
  timeout/retry behavior, and sandbox/auth-state diagnostics.
- `scripts/build-review-artifact.sh` already builds bounded code and PR artifacts.
- `prompts/code-review.base.md` and `prompts/plan-review.base.md` already define
  structured review behavior for normal code and plan review.
- `schemas/review-output.json` already provides the shared response contract.
- `SKILL.md` now uses the internal skill name `claude-review`, reducing collision
  risk with GStack's older `gstack-claude` skill, which declares `name: claude`.
- `README.md` documents the existing update feature and the GStack routing collision.

## Naming And Command Model

Use `/claude-review ...` as the canonical and supported command family.

Only `/claude-review ...` is supported by this skill. Do not support, document, or
test `/claude ...` aliases in this feature.

Canonical commands:

```text
/claude-review
/claude-review code
/claude-review code <focus>
/claude-review plan
/claude-review plan <path-to-plan.md>
/claude-review pr <number>
/claude-review iterate
/claude-review iterate code
/claude-review iterate plan
/claude-review challenge code
/claude-review challenge plan
/claude-review challenge plan <path-to-plan.md>
/claude-review update
/claude-review update --check
/claude-review show
/claude-review set effort <low|medium|high|xhigh|max>
/claude-review set model <alias-or-full-model>
/claude-review set budget <usd>
/claude-review set timeout <seconds>
```

Legacy aliases:

```text
/claude-review review code
/claude-review review plan
/claude-review review plan <path-to-plan.md>
/claude-review review pr <number>
```

Compatibility rules:

- `/claude-review` maps to normal code review.
- `/claude-review review ...` remains accepted as a legacy alias.
- `/claude-review challenge` maps to `/claude-review challenge code`.

Canonical routing table:

| User command | Resolved flow | Runner mode | Artifact source | Base prompt | Instructions |
| --- | --- | --- | --- | --- | --- |
| `/claude-review` | normal code review | `code` | current diff artifact | `prompts/code-review.base.md` | none |
| `/claude-review code [focus]` | normal code review | `code` | current diff artifact | `prompts/code-review.base.md` | optional focus text |
| `/claude-review plan [path]` | normal plan review | `plan` | path or visible `<proposed_plan>` | `prompts/plan-review.base.md` | none |
| `/claude-review pr <number>` | normal PR review | `pr` | PR diff artifact | `prompts/code-review.base.md` | none |
| `/claude-review review ...` | legacy normal review alias | varies | varies | varies | varies |
| `/claude-review challenge` | code challenge | `challenge_code` | current diff artifact | `prompts/challenge-code.base.md` | none |
| `/claude-review challenge [focus]` | code challenge | `challenge_code` | current diff artifact | `prompts/challenge-code.base.md` | focus text |
| `/claude-review challenge code [focus]` | code challenge | `challenge_code` | current diff artifact | `prompts/challenge-code.base.md` | optional focus text |
| `/claude-review challenge plan [path]` | plan challenge | `challenge_plan` | path or visible `<proposed_plan>` | `prompts/challenge-plan.base.md` | none |
| `/claude-review update` | admin update | n/a | none | none | no Claude invocation |
| `/claude-review update --check` | admin update check | n/a | none | none | no Claude invocation |
| `/claude-review show` | admin config show | n/a | none | none | no Claude invocation |
| `/claude-review set effort <value>` | admin config set | n/a | none | none | no Claude invocation |
| `/claude-review set model <value>` | admin config set | n/a | none | none | no Claude invocation |
| `/claude-review set budget <usd>` | admin config set | n/a | none | none | no Claude invocation |
| `/claude-review set timeout <seconds>` | admin config set | n/a | none | none | no Claude invocation |

Command flow:

```text
User command
    |
    v
scripts/claude-command-router.sh
    |
    +--> admin_* ---------------------> existing admin helper
    |                                      |
    |                                      v
    |                                  user-facing admin result
    |
    +--> review_code / challenge_code -> build-review-artifact.sh --mode code
    |                                      |
    |                                      v
    |                                  run-review.sh --mode <mode>
    |                                      |
    |                                      v
    |                                  stamped JSON -> render findings
    |
    +--> review_pr -------------------> build-review-artifact.sh --mode pr
    |                                      |
    |                                      v
    |                                  run-review.sh --mode pr
    |                                      |
    |                                      v
    |                                  stamped JSON -> render findings
    |
    +--> review_plan / challenge_plan -> plan file or visible <proposed_plan>
    |                                      |
    |                                      v
    |                                  run-review.sh --mode <mode>
    |                                      |
    |                                      v
    |                                  stamped JSON -> render findings
    |
    +--> needs_context / unsupported -> no Claude invocation
```

Challenge parse precedence:

- `/claude-review challenge` with no trailing text maps to code challenge with no
  focus.
- If the next token is `code`, run code challenge and treat all remaining text as
  focus.
- If the next token is `plan`, run plan challenge and treat the next token as an
  optional path. Plan challenge does not accept freeform focus text in this slice.
- If the next token is anything else, treat the full trailing text as code challenge
  focus. For example, `/claude-review challenge focus on retries` maps to
  code challenge with `focus on retries` as `--instructions`.

Output mode contract:

- `scripts/run-review.sh` is the source of truth for the returned JSON `mode`.
- Prompt files should tell Claude the expected mode, but the runner must stamp the
  final structured output's `mode` field from its `--mode` argument before returning
  output to Codex.
- This prevents a real challenge run from being mislabeled as `code` or `plan` just
  because Claude chose the older schema value.
- Stamping must support both Claude output shapes:
  - direct structured JSON, such as `{ "status": "...", "mode": "code", ... }`
  - wrapped JSON, such as `{ "structured_output": { "status": "...", "mode": "code", ... } }`
- Use `jq` when available and a Python fallback when `jq` is unavailable. If neither
  can safely rewrite valid JSON, return a classified `blocked` result instead of
  returning an unstamped mode.

## Review Versus Challenge

Normal review asks whether the artifact is correct enough to ship.

Challenge review asks how the artifact breaks under real production pressure.

Code challenge should prioritize:

- race conditions and concurrency interleavings
- retries, idempotency, and duplicate work
- stale state, terminal-state overwrites, and cancellation races
- data loss, silent corruption, and permission bypasses
- partial failure, resource leaks, and operational failure modes
- migrations, background jobs, queues, realtime, MCP tools, Durable Objects, auth,
  billing, and other high-risk stateful surfaces

Plan challenge should prioritize:

- hidden assumptions that make implementation fail
- sequencing that lets agents build the wrong thing first
- missing migration, rollback, or compatibility paths
- ambiguous ownership boundaries
- scope that is too large to review safely
- tests that pass while the real risk remains uncovered
- implementer ambiguity and places a coding agent is likely to misread the plan
- failure modes that the plan does not force the implementation to handle

## Not In Scope

- Do not let Claude edit files.
- Do not give nested Claude tools.
- Do not route challenge through GStack.
- Do not add iterate/fix loops for challenge mode in this slice.
- Do not change the existing review/code/plan/PR behavior except to support the new
  canonical `/claude-review ...` command family.
- Do not rewrite artifact generation unless required for challenge mode.

## Implementation Plan

### 1. Add Challenge Prompt Files

Add:

```text
prompts/challenge-code.base.md
prompts/challenge-plan.base.md
```

`challenge-code.base.md` should instruct Claude to:

- behave as an adversarial failure-mode reviewer
- return the same JSON schema
- emit `mode: "challenge_code"`; the runner still stamps the final mode value
- suppress style comments and generic maintainability advice
- give concrete failure modes and interleavings when applicable
- prefer a small number of high-signal findings over a checklist dump

`challenge-plan.base.md` should instruct Claude to:

- attack the plan before implementation starts
- focus on hidden assumptions, sequencing risk, migration risk, test blind spots,
  rollback gaps, scope control, and implementer ambiguity
- require recommendations that make the plan harder to misbuild
- return the same JSON schema
- emit `mode: "challenge_plan"`; the runner still stamps the final mode value

Add prompt behavior fixtures:

- `tests/fixtures/challenge-code-artifact.txt`: a small diff-like artifact containing
  retry, stale-state, and duplicate-work hazards.
- `tests/fixtures/challenge-plan-artifact.md`: a small plan with hidden sequencing,
  rollback, and migration assumptions.
- `tests/challenge-prompt-fixtures.sh`: verifies the rendered challenge prompts ask
  for adversarial failure modes and do not collapse into the normal review prompt.
  This should be a deterministic text assertion, not a live model call.

### 2. Extend The Schema

Update `schemas/review-output.json` so `mode` accepts:

```json
["plan", "code", "pr", "challenge_code", "challenge_plan"]
```

Use separate mode values instead of one generic `challenge` value so renderers,
tests, and future iterate support can distinguish code challenge from plan challenge.

### 3. Extend The Runner

Update `scripts/run-review.sh`:

- Usage text should accept `--mode <plan|code|pr|challenge_code|challenge_plan>`.
- Existing input validation should allow the two new modes.
- After extracting structured output, replace the returned JSON `mode` field with
  the runner's `--mode` value before printing the result.
- No execution model change should be needed. Challenge still uses:
  - `--tools ""`
  - `--disable-slash-commands`
  - `--no-session-persistence`
  - `--permission-mode dontAsk`
  - budget caps
  - timeout and one retry

### 4. Add Testable Command Routing

Add `scripts/claude-command-router.sh` so routing decisions are not trapped only in
agent-interpreted prose.

The router is the single executable source of truth for command classification.
`SKILL.md` should invoke this helper for `/claude-review ...` commands and act on
the emitted JSON. It should not duplicate the command parsing logic in prose.

The helper should accept a command string plus a small amount of context and emit
JSON such as:

```json
{
  "status": "ok",
  "command_family": "claude-review",
  "flow": "challenge_code",
  "mode": "challenge_code",
  "artifact_source": "code_diff",
  "base_prompt": "prompts/challenge-code.base.md",
  "instructions": "focus on retries",
  "plan_path": "",
  "pr_number": ""
}
```

Admin commands should emit JSON such as:

```json
{
  "status": "ok",
  "command_family": "claude-review",
  "flow": "admin_update",
  "mode": "",
  "artifact_source": "none",
  "base_prompt": "",
  "instructions": "",
  "plan_path": "",
  "admin_action": "update",
  "admin_args": []
}
```

Router output contract:

- Every router result must be valid JSON.
- `status` is required and must be one of `ok`, `needs_context`, `unsupported`, or
  `error`.
- `command_family` is required and must be `claude-review`.
- `flow` is required and must be one of:
  - `review_code`
  - `review_plan`
  - `review_pr`
  - `challenge_code`
  - `challenge_plan`
  - `admin_update`
  - `admin_update_check`
  - `admin_show`
  - `admin_set`
- Review and challenge `ok` results must include `mode`, `artifact_source`,
  `base_prompt`, `instructions`, `plan_path`, and `pr_number`. Empty strings are
  allowed only when a field does not apply.
- Admin `ok` results must include `admin_action` and `admin_args`; they must set
  `artifact_source` to `none`, `base_prompt` to an empty string, and `mode` to an
  empty string.
- `needs_context`, `unsupported`, and `error` results must include a non-empty
  `message` and must not cause `SKILL.md` to invoke Claude.
- `SKILL.md` must reject malformed router output with a clear blocked message rather
  than guessing.

Minimum helper behavior:

- Accept only `/claude-review ...`.
- Accept canonical `/claude-review update`, `/claude-review update --check`,
  `/claude-review show`, and `/claude-review set ...` admin commands.
- Treat non-`/claude-review` commands as out of scope. Do not route `/claude ...`
  commands in this feature.
- Implement the challenge parse precedence above.
- Support a context flag such as `--has-visible-plan true|false` so tests can verify
  that `/claude-review challenge plan` with no path and no visible plan returns
  `needs_context` before Claude is invoked.
- Use the same visible-plan guard for normal `/claude-review plan` and the legacy
  `/claude-review review plan` alias.
- Resolve supplied plan paths relative to the repo root unless they are absolute.
- Validate supplied plan paths before invoking Claude. The file must exist, be
  readable, and be non-empty; otherwise return `needs_context` with guidance to pass
  a valid plan file or paste a plan block.

### 5. Extend Skill Routing

Update `SKILL.md`:

- Frontmatter should describe `/claude-review ...` as canonical.
- The command routing section should run `scripts/claude-command-router.sh` for
  `/claude-review ...` and branch only from the helper's JSON result.
- Admin router flows should call existing helpers directly:
  - `admin_update`: `scripts/claude-update.sh`
  - `admin_update_check`: `scripts/claude-update-check.sh`
  - `admin_show` and `admin_set`: `scripts/claude-config.sh`
- Do not run the update preflight before `admin_update` or `admin_update_check`; those
  commands are the preflight/update mechanism.
- Add `/claude-review challenge code [focus]`.
- Add `/claude-review challenge plan [path]`.
- Keep `/claude-review challenge` as shorthand for code challenge.
- Do not document `/claude ...` as functional support for this skill.

Challenge code flow:

1. Resolve repo root.
2. Detect base branch using the same order as normal code review.
3. Build the same code artifact with `scripts/build-review-artifact.sh --mode code`.
4. Invoke `scripts/run-review.sh --mode challenge_code`.
5. Use `prompts/challenge-code.base.md`.
6. Pass user focus text through `--instructions`.
7. Render findings first, same as normal review.

Challenge plan flow:

1. Accept an optional plan path.
2. If a path is supplied, validate that it exists, is readable, and is non-empty,
   then read that file as the plan artifact.
3. If no path is supplied, use the most recent visible `<proposed_plan>` block.
4. If neither a path nor a visible `<proposed_plan>` block exists, do not invoke
   Claude. Return a clear `needs_context` style message asking the user to pass a
   plan path or paste a plan block.
5. If a supplied path is invalid or empty, do not invoke Claude. Return the same
   `needs_context` style guidance.
6. Write the artifact to `/tmp/claude-review-*`.
7. Invoke `scripts/run-review.sh --mode challenge_plan`.
8. Use `prompts/challenge-plan.base.md`.
9. Render findings first, same as normal plan review.

### 6. Update Documentation

Update `README.md`:

- List `/claude-review ...` as the recommended command family.
- Remove `/claude ...` from user-facing command examples except a troubleshooting note
  that it is intentionally unsupported by this skill.
- Explain when to use normal review versus challenge.
- Explain that GStack users should prefer `/claude-review ...` to avoid routing
  collisions.
- Add examples for code challenge and plan challenge.

Update `agents/openai.yaml`:

- Recommend `/claude-review ...`.
- Stop recommending `$claude` or any ambiguous skill-name invocation.

### 7. Update Consumers

Search the repo for code, docs, schemas, or examples that switch on the output
`mode` field.

- Update every hardcoded mode list to include `challenge_code` and
  `challenge_plan`.
- Confirm the renderer is mode-agnostic or explicitly handles both challenge modes.
- Keep iterate/fix loops disabled for challenge in this slice, even after the new
  mode values exist.

### 8. Tests

Extend shell tests in `tests/run-review-sandbox-classification.sh`:

- Fake Claude returns `mode: "challenge_code"` and `status: "clean"`.
- Fake Claude returns `mode: "challenge_plan"` and `status: "clean"`.
- Fake Claude returns `mode: "code"` during a `--mode challenge_code` run, and the
  runner output is stamped to `mode: "challenge_code"`.
- Fake Claude returns direct JSON during a `--mode challenge_code` run, and the
  runner stamps the direct JSON `mode`.
- Fake Claude returns wrapped `structured_output` JSON during a `--mode challenge_plan`
  run, and the runner stamps the nested output before printing it.
- A no-`jq` path exercises the Python stamping fallback; if Python is unavailable too,
  the runner must return a classified `blocked` result rather than unstamped output.
- A fake Claude invocation records the received prompt, and a test verifies that
  `--instructions "focus on retries"` appears in the prompt as extra review
  instructions.
- Prompt fixture tests verify challenge code and challenge plan prompts contain the
  adversarial criteria listed above and differ from normal review prompts.
- Existing blocked/auth/sandbox cases still pass for challenge modes.
- Schema accepts both new mode values.

Add route-level acceptance coverage:

- Add shell tests for `scripts/claude-command-router.sh`:
  - every router fixture validates against the required fields and allowed enum values
    in the router output contract.
  - `/claude-review` resolves to normal code review.
  - `/claude-review code focus on auth` resolves to normal code review and forwards
    `focus on auth`.
  - `/claude-review plan docs/x.md` resolves to normal plan review and path
    `docs/x.md`.
  - `/claude-review plan` with `--has-visible-plan false` returns `needs_context`.
  - `/claude-review pr 123` resolves to normal PR review and PR number `123`.
  - `/claude-review review code` resolves to normal code review as a legacy alias.
  - `/claude-review review plan docs/x.md` resolves to normal plan review as a
    legacy alias.
  - `/claude-review update` resolves to `admin_update`.
  - `/claude-review update --check` resolves to `admin_update_check`.
  - `/claude-review show` resolves to `admin_show`.
  - `/claude-review set timeout 900` resolves to `admin_set` with key `timeout` and
    value `900`.
  - `/claude-review challenge` resolves to `challenge_code` with empty instructions.
  - `/claude-review challenge focus on retries` resolves to `challenge_code` and
    forwards `focus on retries`.
  - `/claude-review challenge code focus on retries` resolves to `challenge_code`
    and forwards `focus on retries`.
  - `/claude-review challenge plan docs/x.md` resolves to `challenge_plan` and path
    `docs/x.md`.
  - `/claude-review challenge plan` with `--has-visible-plan false` returns
    `needs_context`.
  - `/claude-review challenge plan missing.md` returns `needs_context` when the file
    does not exist.
- Add a `SKILL.md` routing guard test or documented smoke check for malformed router
  output: invalid JSON, missing `status`, unknown `flow`, and missing `message` on
  `needs_context` must be blocked without invoking Claude.
- Treat the routing table above as the design reference; the helper and its tests are
  the executable contract.

Run:

```bash
bash -n scripts/*.sh tests/*.sh
bash tests/run-review-sandbox-classification.sh
git diff --check
```

Manual smoke tests after restarting Codex:

```text
/claude-review challenge
/claude-review challenge code focus on retries and stale state
/claude-review challenge plan docs/claude-review-challenge-plan.md
/claude-review plan docs/claude-review-challenge-plan.md
```

## Failure Modes

- If the schema is not updated, Claude may produce valid-looking challenge output
  that fails validation.
- If challenge code reuses the normal review prompt, it will be too soft and not
  meaningfully different from `/claude-review code`.
- If plan challenge reuses the normal plan prompt, it will overfocus on structure and
  underfocus on implementation failure.
- If docs still list `/claude ...` as a supported command, users with GStack installed
  can hit routing ambiguity again.
- If `/claude-review update` is documented but not routed, users cannot reliably
  update the canonical command family.
- If `/claude-review challenge [focus]` accepts a focus string but drops it before invoking
  `scripts/run-review.sh`, users will think their focus was honored when it was not.
- If `/claude-review challenge plan` runs without a path and without a visible
  `<proposed_plan>` block, it can review an empty or stale artifact and produce
  misleading findings.
- If `/claude-review challenge plan <path>` accepts a missing, unreadable, or empty
  path, it can review the wrong artifact or hide a typo behind generic findings.
- If the runner trusts Claude's returned `mode`, challenge output can be mislabeled
  as normal review output.
- If any renderer or future iterate code switches on the older mode set, stamped
  challenge output may fail to render or may be routed into the wrong workflow.

## Acceptance Criteria

- `/claude-review challenge` reviews the current diff adversarially through this
  repo's runner.
- `/claude-review challenge plan <path>` reviews a markdown plan adversarially through
  this repo's runner.
- `/claude-review ...` is documented as canonical and collision-safe.
- `/claude ...` is not documented or supported as a command for this skill.
- `/claude-review update`, `/claude-review update --check`, `/claude-review show`,
  and `/claude-review set ...` resolve through the router and call the existing admin
  helper scripts without invoking Claude.
- Challenge parse precedence is documented and tested.
- Routing and missing-plan guards are covered by helper tests.
- Supplied plan paths are validated before Claude is invoked.
- Runner output mode is stamped from `--mode`, including challenge modes.
- Any mode consumers support `challenge_code` and `challenge_plan`, or are confirmed
  mode-agnostic.
- Focus text passed to challenge code appears in the Claude prompt.
- Missing plan input returns a clear context request instead of invoking Claude.
- Claude remains report-only and tool-less.
- Existing normal review, plan review, PR review, config, and update behavior still
  work.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | - | - |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | - | - |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 3 | ISSUES_ADDRESSED | 7 verified findings fixed in plan, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | - | - |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | - | - |

**UNRESOLVED:** 0 blocking decisions.  
**VERDICT:** ENG REVIEW FINDINGS ADDRESSED IN PLAN - ready to implement.
