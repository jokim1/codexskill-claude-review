#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  claude-command-router.sh --command "/claude-review ..." [--repo-root <path>] [--skill-root <path>] [--has-visible-plan true|false]
  claude-command-router.sh [--repo-root <path>] [--skill-root <path>] [--has-visible-plan true|false] -- /claude-review ...

Emits JSON describing how the /claude-review command should be handled.
EOF
}

COMMAND=""
REPO_ROOT="$PWD"
SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HAS_VISIBLE_PLAN="false"
COMMAND_TOKENS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      COMMAND="${2:-}"
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="${2:-}"
      shift 2
      ;;
    --skill-root)
      SKILL_ROOT="${2:-}"
      shift 2
      ;;
    --has-visible-plan)
      HAS_VISIBLE_PLAN="${2:-}"
      shift 2
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        COMMAND_TOKENS+=("$1")
        shift
      done
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      COMMAND_TOKENS+=("$1")
      shift
      ;;
  esac
done

if [ -n "$COMMAND" ] && [ "${#COMMAND_TOKENS[@]}" -gt 0 ]; then
  echo "Pass either --command or command tokens, not both." >&2
  exit 2
fi

PY_ARGS=("$REPO_ROOT" "$SKILL_ROOT" "$HAS_VISIBLE_PLAN" "$COMMAND")
if [ "${#COMMAND_TOKENS[@]}" -gt 0 ]; then
  PY_ARGS+=("${COMMAND_TOKENS[@]}")
fi

python3 - "${PY_ARGS[@]}" <<'PY'
import json
import os
from pathlib import Path
import sys

repo_root = Path(sys.argv[1] or os.getcwd())
skill_root = Path(sys.argv[2] or os.getcwd())
has_visible_plan_raw = sys.argv[3]
command = sys.argv[4]
command_tokens = sys.argv[5:]

STATUS_VALUES = {"ok", "needs_context", "unsupported", "error"}
EXECUTABLE_FLOWS = {
    "review_code",
    "review_plan",
    "review_pr",
    "iterate_code",
    "iterate_plan",
    "challenge_code",
    "challenge_plan",
    "admin_update",
    "admin_update_check",
    "admin_show",
    "admin_set",
    "admin_instructions",
    "admin_doctor",
}

CODE_PROMPT = "prompts/code-review.base.md"
PLAN_PROMPT = "prompts/plan-review.base.md"
CHALLENGE_CODE_PROMPT = "prompts/challenge-code.base.md"
CHALLENGE_PLAN_PROMPT = "prompts/challenge-plan.base.md"
REVIEW_SCHEMA = "schemas/review-output.json"


def base_result(status, flow="", message=""):
    result = {
        "status": status,
        "command_family": "claude-review",
        "flow": flow,
        "mode": "",
        "artifact_source": "none",
        "base_prompt": "",
        "instructions": "",
        "plan_path": "",
        "pr_number": "",
        "admin_action": "",
        "admin_args": [],
    }
    if message:
        result["message"] = message
    return result


def emit(result):
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


def error(message):
    return base_result("error", message=message)


def unsupported(message):
    return base_result("unsupported", message=message)


def needs_context(message):
    return base_result("needs_context", message=message)


def review_result(
    flow,
    mode,
    artifact_source,
    base_prompt,
    instructions="",
    plan_path="",
    pr_number="",
    legacy_alias=False,
):
    result = base_result("ok", flow=flow)
    result.update(
        {
            "mode": mode,
            "artifact_source": artifact_source,
            "base_prompt": base_prompt,
            "instructions": instructions,
            "plan_path": plan_path,
            "pr_number": pr_number,
            "legacy_alias": legacy_alias,
        }
    )
    return result


def admin_result(flow, action, args=None, legacy_alias=False):
    result = base_result("ok", flow=flow)
    result.update(
        {
            "artifact_source": "none",
            "admin_action": action,
            "admin_args": list(args or []),
            "legacy_alias": legacy_alias,
        }
    )
    return result


def parse_bool(value):
    lowered = value.strip().lower()
    if lowered == "true":
        return True, None
    if lowered == "false":
        return False, None
    return False, f"--has-visible-plan must be true or false, got {value!r}."


def tokenize():
    if command:
        return split_command(command), None
    return command_tokens, None


def split_command(value):
    tokens = []
    token = []
    quote = ""

    for char in value.strip():
        if quote:
            token.append(char)
            if char == quote:
                quote = ""
            continue

        if char in {"'", '"'}:
            quote = char
            token.append(char)
            continue

        if char.isspace():
            if token:
                tokens.append("".join(token))
                token = []
            continue

        token.append(char)

    if token:
        tokens.append("".join(token))
    return tokens


def join_text(tokens):
    return " ".join(tokens).strip()


def resolve_plan_path(raw_path):
    candidate = Path(strip_balanced_quotes(raw_path))
    if not candidate.is_absolute():
        candidate = repo_root / candidate
    return candidate.resolve(strict=False)


def strip_balanced_quotes(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def validate_plan_path(raw_path):
    if not raw_path:
        return "", "Plan path is empty."
    resolved = resolve_plan_path(raw_path)
    try:
        if not resolved.is_file():
            return "", "The requested plan file could not be read. Pass a readable, non-empty plan file or paste a visible <proposed_plan> block."
        if not os.access(resolved, os.R_OK):
            return "", "The requested plan file could not be read. Pass a readable, non-empty plan file or paste a visible <proposed_plan> block."
        if resolved.stat().st_size <= 0:
            return "", "The requested plan file is empty. Pass a readable, non-empty plan file or paste a visible <proposed_plan> block."
    except OSError:
        return "", "The requested plan file could not be read. Pass a readable, non-empty plan file or paste a visible <proposed_plan> block."
    return str(resolved), ""


def schema_supports_mode(mode):
    schema_path = skill_root / REVIEW_SCHEMA
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return False

    enum_values = (
        schema.get("properties", {})
        .get("mode", {})
        .get("enum", [])
    )
    return mode in enum_values


def challenge_support_error(mode, prompt):
    missing = []
    if not (skill_root / prompt).is_file():
        missing.append(prompt)
    if not schema_supports_mode(mode):
        missing.append(f"{REVIEW_SCHEMA} mode enum")
    if not missing:
        return None
    return unsupported(
        "Challenge review is not enabled in this checkout. Missing downstream support: "
        + ", ".join(missing)
        + "."
    )


def route_plan(tokens, *, flow, mode, prompt, visible_plan, legacy_alias):
    if len(tokens) > 1:
        return unsupported("Plan review accepts at most one path argument. Quote paths that contain spaces.")
    if tokens:
        plan_path, message = validate_plan_path(tokens[0])
        if message:
            return needs_context(message)
        return review_result(
            flow,
            mode,
            "plan_file",
            prompt,
            plan_path=plan_path,
            legacy_alias=legacy_alias,
        )
    if not visible_plan:
        return needs_context(
            "No recent <proposed_plan> block is visible. Pass /claude-review plan <path-to-plan.md> or paste a visible plan block."
        )
    return review_result(
        flow,
        mode,
        "visible_plan",
        prompt,
        legacy_alias=legacy_alias,
    )


def route_pr(tokens, *, legacy_alias):
    if len(tokens) != 1 or not tokens[0]:
        return needs_context("A PR number is required. Use /claude-review pr <number>.")
    if not tokens[0].isdigit() or int(tokens[0]) < 1:
        return needs_context("The PR number must be a positive integer.")
    return review_result(
        "review_pr",
        "pr",
        "pr_diff",
        CODE_PROMPT,
        pr_number=tokens[0],
        legacy_alias=legacy_alias,
    )


def route_admin(tokens, *, legacy_alias):
    if not tokens:
        return unsupported("Missing admin command.")

    head = tokens[0]
    tail = tokens[1:]

    if legacy_alias and head not in {"instructions"}:
        return unsupported("The legacy /claude-review review alias only applies to review and instructions commands.")

    if head == "update":
        if tail == ["--check"]:
            return admin_result("admin_update_check", "update_check", ["--check"], legacy_alias=legacy_alias)
        if tail == ["--backup-conflicts"]:
            return admin_result("admin_update", "update", ["--backup-conflicts"], legacy_alias=legacy_alias)
        if not tail:
            return admin_result("admin_update", "update", [], legacy_alias=legacy_alias)
        return unsupported("/claude-review update only accepts --check or --backup-conflicts.")

    if head == "show":
        if tail:
            return unsupported("/claude-review show does not accept arguments.")
        return admin_result("admin_show", "show", [], legacy_alias=legacy_alias)

    if head == "doctor":
        if tail:
            return unsupported("/claude-review doctor does not accept arguments.")
        return admin_result("admin_doctor", "doctor", [], legacy_alias=legacy_alias)

    if head == "set":
        if len(tail) != 2:
            return needs_context("Use /claude-review set <effort|model|budget|timeout> <value>.")
        key, value = tail
        if key not in {"effort", "model", "budget", "timeout"}:
            return unsupported("Supported settings are effort, model, budget, and timeout.")
        return admin_result("admin_set", "set", [key, value], legacy_alias=legacy_alias)

    if head == "instructions":
        return route_instructions(tail, legacy_alias=legacy_alias)

    return unsupported(f"Unsupported admin command: {head}")


def route_instructions(tokens, *, legacy_alias):
    if not tokens:
        return admin_result("admin_instructions", "instructions_show", ["code"], legacy_alias=legacy_alias)

    head = tokens[0]
    if head in {"plan", "code"}:
        if len(tokens) != 1:
            return unsupported("/claude-review instructions [plan|code] does not accept extra arguments.")
        return admin_result("admin_instructions", "instructions_show", [head], legacy_alias=legacy_alias)

    if head == "set":
        tail = tokens[1:]
        scope = "repo"
        if tail and tail[0] == "global":
            scope = "global"
            tail = tail[1:]
        if len(tail) < 2 or tail[0] not in {"plan", "code"}:
            return needs_context("Use /claude-review instructions set [global] <plan|code> <markdown>.")
        mode = tail[0]
        markdown = join_text(tail[1:])
        if not markdown:
            return needs_context("Instruction markdown cannot be empty.")
        return admin_result(
            "admin_instructions",
            "instructions_set",
            [scope, mode, markdown],
            legacy_alias=legacy_alias,
        )

    if head == "clear":
        tail = tokens[1:]
        scope = "repo"
        if tail and tail[0] == "global":
            scope = "global"
            tail = tail[1:]
        if len(tail) != 1 or tail[0] not in {"plan", "code"}:
            return needs_context("Use /claude-review instructions clear [global] <plan|code>.")
        return admin_result(
            "admin_instructions",
            "instructions_clear",
            [scope, tail[0]],
            legacy_alias=legacy_alias,
        )

    return unsupported("Unsupported instructions command.")


def route_challenge(tokens, *, visible_plan):
    if not tokens:
        support_error = challenge_support_error("challenge_code", CHALLENGE_CODE_PROMPT)
        if support_error:
            return support_error
        return review_result(
            "challenge_code",
            "challenge_code",
            "code_diff",
            CHALLENGE_CODE_PROMPT,
        )

    head = tokens[0]
    tail = tokens[1:]
    if head == "code":
        support_error = challenge_support_error("challenge_code", CHALLENGE_CODE_PROMPT)
        if support_error:
            return support_error
        return review_result(
            "challenge_code",
            "challenge_code",
            "code_diff",
            CHALLENGE_CODE_PROMPT,
            instructions=join_text(tail),
        )
    if head == "plan":
        support_error = challenge_support_error("challenge_plan", CHALLENGE_PLAN_PROMPT)
        if support_error:
            return support_error
        return route_plan(
            tail,
            flow="challenge_plan",
            mode="challenge_plan",
            prompt=CHALLENGE_PLAN_PROMPT,
            visible_plan=visible_plan,
            legacy_alias=False,
        )

    support_error = challenge_support_error("challenge_code", CHALLENGE_CODE_PROMPT)
    if support_error:
        return support_error
    return review_result(
        "challenge_code",
        "challenge_code",
        "code_diff",
        CHALLENGE_CODE_PROMPT,
        instructions=join_text(tokens),
    )


def route_iterate(tokens, *, visible_plan, legacy_alias):
    if not tokens:
        if legacy_alias and visible_plan:
            return route_plan(
                [],
                flow="iterate_plan",
                mode="plan",
                prompt=PLAN_PROMPT,
                visible_plan=True,
                legacy_alias=True,
            )
        return review_result(
            "iterate_code",
            "code",
            "code_diff",
            CODE_PROMPT,
            legacy_alias=legacy_alias,
        )

    head = tokens[0]
    tail = tokens[1:]
    if head == "code":
        return review_result(
            "iterate_code",
            "code",
            "code_diff",
            CODE_PROMPT,
            instructions=join_text(tail),
            legacy_alias=legacy_alias,
        )
    if head == "plan":
        return route_plan(
            tail,
            flow="iterate_plan",
            mode="plan",
            prompt=PLAN_PROMPT,
            visible_plan=visible_plan,
            legacy_alias=legacy_alias,
        )
    if head == "pr":
        return needs_context(
            "Iteration requires a checked-out branch or a visible plan, not just a remote PR diff. Check out the PR branch locally and run /claude-review iterate code, or use /claude-review pr <number> for report-only review."
        )
    return unsupported("Unsupported iterate command. Use /claude-review iterate [code|plan].")


def route_review_command(tokens, *, visible_plan, legacy_alias):
    if not tokens:
        if legacy_alias and visible_plan:
            return route_plan(
                [],
                flow="review_plan",
                mode="plan",
                prompt=PLAN_PROMPT,
                visible_plan=True,
                legacy_alias=True,
            )
        return review_result(
            "review_code",
            "code",
            "code_diff",
            CODE_PROMPT,
            legacy_alias=legacy_alias,
        )

    head = tokens[0]
    tail = tokens[1:]

    if head == "code":
        return review_result(
            "review_code",
            "code",
            "code_diff",
            CODE_PROMPT,
            instructions=join_text(tail),
            legacy_alias=legacy_alias,
        )
    if head == "plan":
        return route_plan(
            tail,
            flow="review_plan",
            mode="plan",
            prompt=PLAN_PROMPT,
            visible_plan=visible_plan,
            legacy_alias=legacy_alias,
        )
    if head == "pr":
        return route_pr(tail, legacy_alias=legacy_alias)
    if head == "iterate":
        return route_iterate(tail, visible_plan=visible_plan, legacy_alias=legacy_alias)
    if head == "instructions":
        return route_instructions(tail, legacy_alias=legacy_alias)

    if legacy_alias:
        return unsupported("Unsupported /claude-review review alias. Use code, plan, pr, iterate, or instructions.")
    return unsupported("Unsupported /claude-review command. Use code, plan, pr, iterate, challenge, instructions, show, set, doctor, or update.")


visible_plan, bool_error = parse_bool(has_visible_plan_raw)
if bool_error:
    emit(error(bool_error))
    sys.exit(0)

tokens, token_error = tokenize()
if token_error:
    emit(error(token_error))
    sys.exit(0)

if not tokens:
    emit(error("No command was provided."))
    sys.exit(0)

if tokens[0] != "/claude-review":
    emit(unsupported("Only the /claude-review command family is handled by this router."))
    sys.exit(0)

args = tokens[1:]
if not args:
    emit(route_review_command([], visible_plan=visible_plan, legacy_alias=False))
    sys.exit(0)

if args[0] == "review":
    legacy_args = args[1:]
    if legacy_args and legacy_args[0] in {"challenge", "update", "show", "set"}:
        emit(unsupported("The legacy /claude-review review alias does not apply to challenge or admin commands."))
    else:
        emit(route_review_command(legacy_args, visible_plan=visible_plan, legacy_alias=True))
    sys.exit(0)

if args[0] in {"update", "show", "set", "instructions", "doctor"}:
    emit(route_admin(args, legacy_alias=False))
    sys.exit(0)

if args[0] == "challenge":
    emit(route_challenge(args[1:], visible_plan=visible_plan))
    sys.exit(0)

emit(route_review_command(args, visible_plan=visible_plan, legacy_alias=False))
PY
