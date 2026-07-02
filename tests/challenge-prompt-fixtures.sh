#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/claude-review-challenge-prompt-XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  local path="$1"

  [ -s "$path" ] || fail "expected non-empty file: $path"
}

assert_contains() {
  local path="$1"
  local needle="$2"

  if ! grep -Fq -- "$needle" "$path"; then
    fail "expected $path to contain: $needle"
  fi
}

assert_not_contains() {
  local path="$1"
  local needle="$2"

  if grep -Fq -- "$needle" "$path"; then
    fail "expected $path not to contain: $needle"
  fi
}

assert_distinct() {
  local left="$1"
  local right="$2"

  if cmp -s "$left" "$right"; then
    fail "expected files to differ: $left and $right"
  fi
}

make_temp_file() {
  mktemp "$TMP_DIR/rendered-prompt-XXXXXX"
}

render_prompt() {
  local mode="$1"
  local base_prompt="$2"
  local artifact="$3"
  local output="$4"

  {
    cat "$base_prompt"
    printf '\n\n'
    printf 'Review the provided artifact and return JSON matching the supplied schema.\n\n'
    printf 'Mode: %s\n\n' "$mode"
    printf 'Artifact:\n'
    printf '```text\n'
    cat "$artifact"
    printf '\n```\n'
  } > "$output"
}

code_prompt="$REPO_ROOT/prompts/challenge-code.base.md"
plan_prompt="$REPO_ROOT/prompts/challenge-plan.base.md"
normal_code_prompt="$REPO_ROOT/prompts/code-review.base.md"
normal_plan_prompt="$REPO_ROOT/prompts/plan-review.base.md"
schema_file="$REPO_ROOT/schemas/review-output.json"
code_fixture="$REPO_ROOT/tests/fixtures/challenge-code-artifact.txt"
plan_fixture="$REPO_ROOT/tests/fixtures/challenge-plan-artifact.md"

assert_file "$code_prompt"
assert_file "$plan_prompt"
assert_file "$schema_file"
assert_file "$code_fixture"
assert_file "$plan_fixture"
printf 'ok: challenge prompt and fixture files exist\n'

assert_distinct "$code_prompt" "$normal_code_prompt"
assert_distinct "$plan_prompt" "$normal_plan_prompt"
assert_contains "$code_prompt" 'adversarial failure-mode reviewer'
assert_contains "$code_prompt" 'set `mode` to `challenge_code`'
assert_contains "$plan_prompt" 'attack the plan before implementation starts'
assert_contains "$plan_prompt" 'set `mode` to `challenge_plan`'
assert_contains "$schema_file" '"challenge_code"'
assert_contains "$schema_file" '"challenge_plan"'
printf 'ok: challenge prompts declare distinct review modes\n'

assert_contains "$code_prompt" 'retries, stale state,'
assert_contains "$code_prompt" 'duplicate work'
assert_contains "$code_prompt" 'concrete failure mode'
assert_contains "$code_prompt" 'interleaving'
assert_contains "$code_prompt" 'suppress style comments and generic maintainability advice'
assert_contains "$code_prompt" 'return the smallest set of findings'
printf 'ok: code challenge prompt asks for adversarial failure modes\n'

assert_contains "$plan_prompt" 'hidden assumptions'
assert_contains "$plan_prompt" 'sequencing risk'
assert_contains "$plan_prompt" 'migration risk'
assert_contains "$plan_prompt" 'rollback gaps'
assert_contains "$plan_prompt" 'test blind spots'
assert_contains "$plan_prompt" 'implementer ambiguity'
assert_contains "$plan_prompt" 'harder to misbuild'
printf 'ok: plan challenge prompt attacks planning failure modes\n'

assert_not_contains "$normal_code_prompt" 'adversarial failure-mode reviewer'
assert_not_contains "$normal_code_prompt" 'set `mode` to `challenge_code`'
assert_not_contains "$normal_code_prompt" 'suppress style comments and generic maintainability advice'
assert_not_contains "$normal_plan_prompt" 'attack the plan before implementation starts'
assert_not_contains "$normal_plan_prompt" 'set `mode` to `challenge_plan`'
assert_not_contains "$normal_plan_prompt" 'harder to misbuild'
printf 'ok: normal review prompts do not contain challenge-only behavior\n'

assert_contains "$code_fixture" 'retry budget'
assert_contains "$code_fixture" 'stale state'
assert_contains "$code_fixture" 'duplicate work'
assert_contains "$plan_fixture" 'sequencing risk'
assert_contains "$plan_fixture" 'rollback gap'
assert_contains "$plan_fixture" 'migration assumption'
printf 'ok: fixture artifacts contain deterministic hazards\n'

rendered_code_prompt="$(make_temp_file)"
rendered_plan_prompt="$(make_temp_file)"
render_prompt "challenge_code" "$code_prompt" "$code_fixture" "$rendered_code_prompt"
render_prompt "challenge_plan" "$plan_prompt" "$plan_fixture" "$rendered_plan_prompt"

assert_contains "$rendered_code_prompt" 'Mode: challenge_code'
assert_contains "$rendered_code_prompt" 'retry budget can schedule a fourth attempt'
assert_contains "$rendered_code_prompt" 'duplicate work can happen'
assert_contains "$rendered_code_prompt" 'adversarial failure-mode reviewer'
assert_contains "$rendered_plan_prompt" 'Mode: challenge_plan'
assert_contains "$rendered_plan_prompt" 'live traffic starts before the migration source of truth exists'
assert_contains "$rendered_plan_prompt" 'disabling the flag does not undo already-queued duplicate work'
assert_contains "$rendered_plan_prompt" 'attack the plan before implementation starts'
printf 'ok: rendered challenge prompts preserve mode and fixture hazards\n'
