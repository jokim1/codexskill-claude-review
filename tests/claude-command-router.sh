#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTER="$REPO_ROOT/scripts/claude-command-router.sh"
TMP_ROOT="$(mktemp -d /tmp/claude-router-test-XXXXXX)"
SUPPORTED_ROOT="$(mktemp -d /tmp/claude-router-supported-XXXXXX)"
SUPPORTED_SKILL_ROOT="$(mktemp -d /tmp/claude-router-skill-supported-XXXXXX)"
UNSUPPORTED_SKILL_ROOT="$(mktemp -d /tmp/claude-router-skill-unsupported-XXXXXX)"
trap 'rm -rf "$TMP_ROOT" "$SUPPORTED_ROOT" "$SUPPORTED_SKILL_ROOT" "$UNSUPPORTED_SKILL_ROOT"' EXIT

mkdir -p "$TMP_ROOT/docs"
printf '# Test plan\n\nDo the thing.\n' > "$TMP_ROOT/docs/x.md"
printf '# Spaced test plan\n\nDo the thing.\n' > "$TMP_ROOT/docs/my plan.md"
: > "$TMP_ROOT/docs/empty.md"

mkdir -p "$SUPPORTED_ROOT/docs" "$SUPPORTED_SKILL_ROOT/prompts" "$SUPPORTED_SKILL_ROOT/schemas"
printf '# Supported test plan\n\nDo the thing.\n' > "$SUPPORTED_ROOT/docs/x.md"
printf 'challenge code prompt\n' > "$SUPPORTED_SKILL_ROOT/prompts/challenge-code.base.md"
printf 'challenge plan prompt\n' > "$SUPPORTED_SKILL_ROOT/prompts/challenge-plan.base.md"
cat > "$SUPPORTED_SKILL_ROOT/schemas/review-output.json" <<'JSON'
{
  "type": "object",
  "properties": {
    "mode": {
      "type": "string",
      "enum": ["plan", "code", "pr", "challenge_code", "challenge_plan"]
    }
  }
}
JSON

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

route_root() {
  local root="$1"
  local skill_root="$2"
  local visible_plan="$3"
  local command="$4"

  bash "$ROUTER" \
    --repo-root "$root" \
    --skill-root "$skill_root" \
    --has-visible-plan "$visible_plan" \
    --command "$command"
}

route() {
  local visible_plan="$1"
  local command="$2"

  route_root "$TMP_ROOT" "$UNSUPPORTED_SKILL_ROOT" "$visible_plan" "$command"
}

assert_subset() {
  local case_name="$1"
  local output="$2"
  local expected="$3"

  OUTPUT_JSON="$output" EXPECTED_JSON="$expected" CASE_NAME="$case_name" python3 - <<'PY'
import json
import os
import sys

case_name = os.environ["CASE_NAME"]
output_json = os.environ["OUTPUT_JSON"]
expected_json = os.environ["EXPECTED_JSON"]

try:
    data = json.loads(output_json)
except Exception as exc:
    print(f"{case_name}: output is not valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

expected = json.loads(expected_json)

status_values = {"ok", "needs_context", "unsupported", "error"}
required = {
    "status",
    "command_family",
    "flow",
    "mode",
    "artifact_source",
    "base_prompt",
    "instructions",
    "plan_path",
    "pr_number",
    "admin_action",
    "admin_args",
}

missing = sorted(required - data.keys())
if missing:
    print(f"{case_name}: missing required keys: {missing}", file=sys.stderr)
    sys.exit(1)

if data["status"] not in status_values:
    print(f"{case_name}: invalid status {data['status']!r}", file=sys.stderr)
    sys.exit(1)
if data["command_family"] != "claude-review":
    print(f"{case_name}: wrong command_family {data['command_family']!r}", file=sys.stderr)
    sys.exit(1)
if data["status"] == "ok" and not data["flow"]:
    print(f"{case_name}: ok result must include a flow", file=sys.stderr)
    sys.exit(1)
if data["status"] != "ok" and not data.get("message"):
    print(f"{case_name}: non-ok result must include a message", file=sys.stderr)
    sys.exit(1)

for key, value in expected.items():
    if data.get(key) != value:
        print(
            f"{case_name}: expected {key}={value!r}, got {data.get(key)!r}\nfull output: {data}",
            file=sys.stderr,
        )
        sys.exit(1)
PY
}

assert_downstream_supported() {
  local case_name="$1"
  local skill_root="$2"
  local output="$3"

  ROUTER_SKILL_ROOT="$skill_root" OUTPUT_JSON="$output" CASE_NAME="$case_name" python3 - <<'PY'
import json
import os
from pathlib import Path
import sys

case_name = os.environ["CASE_NAME"]
skill_root = Path(os.environ["ROUTER_SKILL_ROOT"])
data = json.loads(os.environ["OUTPUT_JSON"])

if data.get("status") != "ok":
    return_code = 0
else:
    return_code = 0
    prompt = data.get("base_prompt", "")
    if prompt and not (skill_root / prompt).is_file():
        print(f"{case_name}: ok result points at missing prompt {prompt!r}", file=sys.stderr)
        return_code = 1

    mode = data.get("mode", "")
    if mode:
        schema_path = skill_root / "schemas/review-output.json"
        try:
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"{case_name}: could not read schema: {exc}", file=sys.stderr)
            return_code = 1
        else:
            enum_values = schema.get("properties", {}).get("mode", {}).get("enum", [])
            if mode not in enum_values:
                print(f"{case_name}: schema does not allow mode {mode!r}", file=sys.stderr)
                return_code = 1

sys.exit(return_code)
PY
}

assert_case_root() {
  local case_name="$1"
  local root="$2"
  local skill_root="$3"
  local visible_plan="$4"
  local command="$5"
  local expected="$6"
  local validate_downstream="${7:-false}"
  local output

  output="$(route_root "$root" "$skill_root" "$visible_plan" "$command")" || fail "$case_name exited non-zero"
  assert_subset "$case_name" "$output" "$expected" || fail "$case_name assertion failed"
  if [ "$validate_downstream" = true ]; then
    assert_downstream_supported "$case_name" "$skill_root" "$output" || fail "$case_name downstream assertion failed"
  fi
  printf 'ok: %s\n' "$case_name"
}

assert_case() {
  local case_name="$1"
  local visible_plan="$2"
  local command="$3"
  local expected="$4"

  assert_case_root "$case_name" "$TMP_ROOT" "$UNSUPPORTED_SKILL_ROOT" "$visible_plan" "$command" "$expected"
}

assert_supported_case() {
  local case_name="$1"
  local visible_plan="$2"
  local command="$3"
  local expected="$4"

  assert_case_root "$case_name" "$SUPPORTED_ROOT" "$SUPPORTED_SKILL_ROOT" "$visible_plan" "$command" "$expected" true
}

PLAN_PATH="$(cd "$TMP_ROOT/docs" && pwd -P)/x.md"
SPACED_PLAN_PATH="$(cd "$TMP_ROOT/docs" && pwd -P)/my plan.md"
SUPPORTED_PLAN_PATH="$(cd "$SUPPORTED_ROOT/docs" && pwd -P)/x.md"

[ "$SUPPORTED_ROOT" != "$SUPPORTED_SKILL_ROOT" ] || fail "supported repo and skill roots must be distinct"

assert_case "bare command routes to code review" false \
  "/claude-review" \
  '{"status":"ok","flow":"review_code","mode":"code","artifact_source":"code_diff","base_prompt":"prompts/code-review.base.md","instructions":"","plan_path":"","pr_number":""}'

assert_case "canonical code keeps inline instructions" false \
  "/claude-review code focus on auth" \
  '{"status":"ok","flow":"review_code","mode":"code","artifact_source":"code_diff","instructions":"focus on auth"}'

assert_case "canonical code keeps apostrophe instructions" false \
  "/claude-review code don't miss auth" \
  "{\"status\":\"ok\",\"flow\":\"review_code\",\"mode\":\"code\",\"instructions\":\"don't miss auth\"}"

assert_case "canonical code keeps literal quote instructions" false \
  '/claude-review code keep "quoted" text' \
  '{"status":"ok","flow":"review_code","mode":"code","instructions":"keep \"quoted\" text"}'

command_substitution_marker="$TMP_ROOT/command-substitution-marker"
assert_case "canonical code keeps command substitution text literal" false \
  "/claude-review code inspect \$(touch $command_substitution_marker)" \
  "{\"status\":\"ok\",\"flow\":\"review_code\",\"mode\":\"code\",\"instructions\":\"inspect \$(touch $command_substitution_marker)\"}"
[ ! -e "$command_substitution_marker" ] || fail "command substitution text was evaluated"

assert_case "canonical plan validates relative path" false \
  "/claude-review plan docs/x.md" \
  "{\"status\":\"ok\",\"flow\":\"review_plan\",\"mode\":\"plan\",\"artifact_source\":\"plan_file\",\"base_prompt\":\"prompts/plan-review.base.md\",\"plan_path\":\"$PLAN_PATH\"}"

positional_plan_output="$(
  bash "$ROUTER" \
    --repo-root "$TMP_ROOT" \
    --skill-root "$UNSUPPORTED_SKILL_ROOT" \
    --has-visible-plan false \
    -- /claude-review plan "docs/my plan.md"
)"
assert_subset "positional plan path preserves spaces" "$positional_plan_output" \
  "{\"status\":\"ok\",\"flow\":\"review_plan\",\"mode\":\"plan\",\"artifact_source\":\"plan_file\",\"base_prompt\":\"prompts/plan-review.base.md\",\"plan_path\":\"$SPACED_PLAN_PATH\"}"
printf 'ok: positional plan path preserves spaces\n'

assert_case "canonical plan without visible plan needs context" false \
  "/claude-review plan" \
  '{"status":"needs_context"}'

assert_case "canonical plan uses visible plan when present" true \
  "/claude-review plan" \
  '{"status":"ok","flow":"review_plan","mode":"plan","artifact_source":"visible_plan","plan_path":""}'

assert_case "canonical pr routes with number" false \
  "/claude-review pr 123" \
  '{"status":"ok","flow":"review_pr","mode":"pr","artifact_source":"pr_diff","pr_number":"123"}'

assert_case "canonical pr rejects zero" false \
  "/claude-review pr 0" \
  '{"status":"needs_context"}'

assert_case "legacy review auto-selects code without visible plan" false \
  "/claude-review review" \
  '{"status":"ok","flow":"review_code","mode":"code","artifact_source":"code_diff","legacy_alias":true}'

assert_case "legacy review auto-selects plan with visible plan" true \
  "/claude-review review" \
  '{"status":"ok","flow":"review_plan","mode":"plan","artifact_source":"visible_plan","legacy_alias":true}'

assert_case "legacy review code routes to normal code review" false \
  "/claude-review review code" \
  '{"status":"ok","flow":"review_code","mode":"code","legacy_alias":true}'

assert_case "legacy review plan validates relative path" false \
  "/claude-review review plan docs/x.md" \
  "{\"status\":\"ok\",\"flow\":\"review_plan\",\"mode\":\"plan\",\"artifact_source\":\"plan_file\",\"plan_path\":\"$PLAN_PATH\",\"legacy_alias\":true}"

assert_case "canonical iterate defaults to code" false \
  "/claude-review iterate" \
  '{"status":"ok","flow":"iterate_code","mode":"code","artifact_source":"code_diff"}'

assert_case "legacy iterate auto-selects plan with visible plan" true \
  "/claude-review review iterate" \
  '{"status":"ok","flow":"iterate_plan","mode":"plan","artifact_source":"visible_plan","legacy_alias":true}'

assert_case "canonical update routes to admin update" false \
  "/claude-review update" \
  '{"status":"ok","flow":"admin_update","mode":"","artifact_source":"none","admin_action":"update","admin_args":[]}'

assert_case "canonical update check routes to admin update check" false \
  "/claude-review update --check" \
  '{"status":"ok","flow":"admin_update_check","admin_action":"update_check","admin_args":["--check"]}'

assert_case "canonical show routes to admin show" false \
  "/claude-review show" \
  '{"status":"ok","flow":"admin_show","admin_action":"show","admin_args":[]}'

assert_case "canonical doctor routes to admin doctor" false \
  "/claude-review doctor" \
  '{"status":"ok","flow":"admin_doctor","admin_action":"doctor","admin_args":[]}'

assert_case "canonical doctor rejects arguments" false \
  "/claude-review doctor now" \
  '{"status":"unsupported"}'

assert_case "canonical set routes key and value" false \
  "/claude-review set timeout 900" \
  '{"status":"ok","flow":"admin_set","admin_action":"set","admin_args":["timeout","900"]}'

assert_case "canonical instructions routes as admin flow" false \
  "/claude-review instructions plan" \
  '{"status":"ok","flow":"admin_instructions","admin_action":"instructions_show","admin_args":["plan"]}'

assert_case "legacy instructions routes as admin flow" false \
  "/claude-review review instructions set code tighten feedback" \
  '{"status":"ok","flow":"admin_instructions","admin_action":"instructions_set","admin_args":["repo","code","tighten feedback"],"legacy_alias":true}'

assert_case "instructions set keeps apostrophe markdown" false \
  "/claude-review instructions set code don't miss auth" \
  "{\"status\":\"ok\",\"flow\":\"admin_instructions\",\"admin_action\":\"instructions_set\",\"admin_args\":[\"repo\",\"code\",\"don't miss auth\"]}"

assert_case "instructions set keeps literal quote markdown" false \
  '/claude-review instructions set code keep "quoted" text' \
  '{"status":"ok","flow":"admin_instructions","admin_action":"instructions_set","admin_args":["repo","code","keep \"quoted\" text"]}'

assert_case "challenge disabled when downstream support is missing" false \
  "/claude-review challenge" \
  '{"status":"unsupported"}'

assert_supported_case "challenge defaults to code challenge" false \
  "/claude-review challenge" \
  '{"status":"ok","flow":"challenge_code","mode":"challenge_code","artifact_source":"code_diff","base_prompt":"prompts/challenge-code.base.md","instructions":""}'

assert_supported_case "challenge freeform text becomes code focus" false \
  "/claude-review challenge focus on retries" \
  '{"status":"ok","flow":"challenge_code","mode":"challenge_code","instructions":"focus on retries"}'

assert_supported_case "challenge code keeps focus" false \
  "/claude-review challenge code focus on retries" \
  '{"status":"ok","flow":"challenge_code","mode":"challenge_code","instructions":"focus on retries"}'

assert_supported_case "challenge plan validates relative path" false \
  "/claude-review challenge plan docs/x.md" \
  "{\"status\":\"ok\",\"flow\":\"challenge_plan\",\"mode\":\"challenge_plan\",\"artifact_source\":\"plan_file\",\"base_prompt\":\"prompts/challenge-plan.base.md\",\"plan_path\":\"$SUPPORTED_PLAN_PATH\"}"

assert_supported_case "challenge plan without visible plan needs context" false \
  "/claude-review challenge plan" \
  '{"status":"needs_context"}'

assert_supported_case "challenge plan uses visible plan when present" true \
  "/claude-review challenge plan" \
  '{"status":"ok","flow":"challenge_plan","mode":"challenge_plan","artifact_source":"visible_plan"}'

assert_supported_case "challenge missing plan path needs context" false \
  "/claude-review challenge plan missing.md" \
  '{"status":"needs_context"}'

assert_case "empty plan path target needs context" false \
  "/claude-review plan docs/empty.md" \
  '{"status":"needs_context"}'

assert_case "non claude-review command is unsupported" false \
  "/claude code" \
  '{"status":"unsupported"}'

assert_case "legacy review challenge is unsupported" false \
  "/claude-review review challenge" \
  '{"status":"unsupported"}'

assert_case "challenge plan rejects extra path tokens" false \
  "/claude-review challenge plan docs/x.md extra" \
  '{"status":"unsupported"}'
