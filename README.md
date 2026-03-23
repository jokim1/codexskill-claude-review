# codexskill-claude-review

Native-only `claude` review skill for Codex. This lets Codex call your local `claude` CLI for structured code review and plan review while keeping Claude report-only and Codex fix-only.

## What It Includes

- `SKILL.md`: command routing and iterate workflow
- `agents/openai.yaml`: skill metadata
- `prompts/`: bundled base prompts for code review and plan review
- `schemas/review-output.json`: structured output contract
- `scripts/run-review.sh`: Claude review runner
- `scripts/build-review-artifact.sh`: richer code/PR review artifact builder

## Requirements

- Codex
- `claude` CLI installed and authenticated
- `jq`
- `git`
- `gh` for `/claude review pr <number>`

## Install

Single-skill install:

```bash
git clone https://github.com/jokim1/codexskill-claude-review.git ~/.codex/skills/claude
chmod +x ~/.codex/skills/claude/scripts/*.sh
```

Then restart Codex or refresh skill discovery.

## Commands

- `/claude review`
- `/claude review code`
- `/claude review plan`
- `/claude review iterate`
- `/claude review iterate code`
- `/claude review iterate plan`
- `/claude review pr <number>`
- `/claude review instructions [plan|code]`
- `/claude review instructions set [plan|code] <markdown>`
- `/claude review instructions clear [plan|code]`
- `/claude review instructions set global [plan|code] <markdown>`
- `/claude review instructions clear global [plan|code]`
- `/claude config show`
- `/claude config set effort <low|medium|high|max>`
- `/claude config set model <alias-or-full-model>`

## Prompt Overrides

Global prompt append files:

- `~/.codex/claude/code-review.append.md`
- `~/.codex/claude/plan-review.append.md`

Repo-local prompt append files:

- `<repo>/.codex/claude/code-review.append.md`
- `<repo>/.codex/claude/plan-review.append.md`

Prompt merge order:

1. bundled base prompt
2. global append
3. repo append
4. inline one-off instructions

## Notes

- This repo is self-contained on the Codex side. It does not depend on Claude-side gstack skills.
- Claude runs tool-less for review with structured JSON output.
- Code review artifacts include changed-file contents, sibling test context, and targeted enum/status consumer snippets to improve review quality without giving Claude repo tools.
