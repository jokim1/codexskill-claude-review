#!/usr/bin/env bash

set -euo pipefail

MODE=""
REPO_ROOT=""
OUTPUT_FILE=""
BASE_BRANCH=""
PR_NUMBER=""

MAX_ARTIFACT_BYTES=110000
PER_FILE_BYTES=7000
MAX_CHANGED_FILES=12
MAX_SIBLING_TESTS=6
MAX_ENUM_CANDIDATES=6
CODE_FENCE='```'
NL=$'\n'

usage() {
  cat <<'EOF'
Usage:
  build-review-artifact.sh --mode <code|pr> --repo-root <path> --output-file <path> [options]

Options:
  --base-branch <name>   Required for --mode code
  --pr-number <number>   Required for --mode pr
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="${2:-}"
      shift 2
      ;;
    --output-file)
      OUTPUT_FILE="${2:-}"
      shift 2
      ;;
    --base-branch)
      BASE_BRANCH="${2:-}"
      shift 2
      ;;
    --pr-number)
      PR_NUMBER="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$MODE" ] || [ -z "$REPO_ROOT" ] || [ -z "$OUTPUT_FILE" ]; then
  usage >&2
  exit 2
fi

case "$MODE" in
  code)
    [ -n "$BASE_BRANCH" ] || { echo "Missing --base-branch for code mode." >&2; exit 2; }
    ;;
  pr)
    [ -n "$PR_NUMBER" ] || { echo "Missing --pr-number for pr mode." >&2; exit 2; }
    ;;
  *)
    echo "Unsupported mode: $MODE" >&2
    exit 2
    ;;
esac

cd "$REPO_ROOT"
: > "$OUTPUT_FILE"

artifact_truncated="false"

append_block() {
  local block="$1"
  local current_bytes remaining_bytes usable_bytes

  [ "$artifact_truncated" = "true" ] && return 1

  current_bytes="$(wc -c < "$OUTPUT_FILE" | tr -d '[:space:]')"
  remaining_bytes=$((MAX_ARTIFACT_BYTES - current_bytes))

  if [ "$remaining_bytes" -le 0 ]; then
    artifact_truncated="true"
    return 1
  fi

  if [ "${#block}" -le "$remaining_bytes" ]; then
    printf '%s' "$block" >> "$OUTPUT_FILE"
    return 0
  fi

  usable_bytes=$((remaining_bytes - 64))
  if [ "$usable_bytes" -gt 0 ]; then
    printf '%s' "${block:0:$usable_bytes}" >> "$OUTPUT_FILE"
  fi
  printf '\n[artifact truncated to stay within review budget]\n' >> "$OUTPUT_FILE"
  artifact_truncated="true"
  return 1
}

trim_file_content() {
  local path="$1"
  local bytes

  bytes="$(wc -c < "$path" | tr -d '[:space:]')"
  if [ "${bytes:-0}" -le "$PER_FILE_BYTES" ]; then
    cat "$path"
  else
    head -c "$PER_FILE_BYTES" "$path"
    printf '\n[truncated after %s bytes; full file omitted]\n' "$PER_FILE_BYTES"
  fi
}

is_frontend_file() {
  case "$1" in
    *.tsx|*.jsx|*.css|*.scss|*.sass|*.less|*.html|*.vue|*.svelte|*.astro|*.mdx)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_test_file() {
  case "$1" in
    *.test.*|*.spec.*|*_test.*|*/__tests__/*|*/test/*|*/tests/*|*/spec/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_summary_only_file() {
  case "$1" in
    package-lock.json|pnpm-lock.yaml|yarn.lock|bun.lock|bun.lockb|Cargo.lock|Gemfile.lock|go.sum|poetry.lock|Pipfile.lock)
      return 0
      ;;
    *.min.js|*.map|*.snap|*.generated.*|*.pb.go|*.pb.ts|*.pb.rb)
      return 0
      ;;
    dist/*|build/*|coverage/*|vendor/*|.next/*|out/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_probably_source_file() {
  case "$1" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py|*.rb|*.go|*.rs|*.java|*.kt|*.swift|*.php|*.c|*.cc|*.cpp|*.h|*.hpp|*.cs|*.scala|*.sql|*.sh|*.zsh|*.html|*.css|*.scss|*.sass|*.vue|*.svelte|*.astro|*.mdx|*.json|*.yaml|*.yml|*.toml|*.graphql|*.gql)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

escape_regex() {
  printf '%s' "$1" | sed 's/[][(){}.^$+*?|\\/]/\\&/g'
}

collect_changed_files() {
  local merge_base="$1"
  {
    git diff --name-only "$merge_base...HEAD"
    git diff --name-only
    git ls-files --others --exclude-standard
  } | awk 'NF && !seen[$0]++'
}

collect_sibling_tests() {
  local path="$1"
  local stem escaped_stem

  stem="$(basename "$path")"
  stem="${stem%.*}"
  escaped_stem="$(escape_regex "$stem")"

  rg --files "$REPO_ROOT" \
    | grep -E "(^|/)${escaped_stem}(\\.(test|spec)\\.[^/]+|_test\\.[^/]+|Test\\.[^/]+)$|(^|/)(__tests__|tests|test|spec)/.*${escaped_stem}.*\\.[^/]+$" \
    | awk '!seen[$0]++'
}

extract_enum_candidates() {
  grep -E '^\+' \
    | grep -vE '^\+\+\+' \
    | grep -Ei '(status|state|type|kind|mode|tier|variant|role|phase|view|tab)' \
    | grep -oE "\"[A-Za-z][A-Za-z0-9_-]{1,31}\"|'[A-Za-z][A-Za-z0-9_-]{1,31}'" \
    | tr -d "\"'" \
    | awk '!seen[$0]++'
}

write_code_artifact() {
  local compare_ref merge_base current_branch status_output status_display diff_stat diff_output worktree_diff
  local changed_files_file changed_files_display changed_file frontend_touched changed_count included_files sibling_tests_file sibling_test
  local diff_for_candidates enum_context candidates

  if git rev-parse --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    compare_ref="origin/$BASE_BRANCH"
  elif git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
    compare_ref="$BASE_BRANCH"
  else
    echo "Could not resolve base branch reference for $BASE_BRANCH." >&2
    exit 3
  fi

  merge_base="$(git merge-base HEAD "$compare_ref" 2>/dev/null || true)"
  if [ -z "$merge_base" ]; then
    echo "Could not determine merge base for $compare_ref." >&2
    exit 3
  fi

  current_branch="$(git branch --show-current 2>/dev/null || echo "unknown")"
  status_output="$(git status --short --untracked-files=all)"
  status_display="$(printf '%s\n' "${status_output:-<clean>}" | awk 'NR<=40 {print} NR==41 {print "[truncated after 40 lines]"; exit}')"
  diff_stat="$(git diff --stat "$merge_base...HEAD")"
  diff_output="$(git diff "$merge_base...HEAD")"
  worktree_diff="$(git diff)"
  changed_files_file="$(mktemp /tmp/codex-changed-files-XXXXXX.txt)"

  collect_changed_files "$merge_base" > "$changed_files_file"

  frontend_touched="false"
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    if is_frontend_file "$changed_file"; then
      frontend_touched="true"
      break
    fi
  done < "$changed_files_file"

  changed_files_display="$(awk 'NR<=60 {print} NR==61 {print "[truncated after 60 lines]"; exit}' "$changed_files_file")"

  append_block "Review Artifact (code)${NL}======================${NL}Repo root: $REPO_ROOT${NL}Current branch: $current_branch${NL}Base branch: $BASE_BRANCH${NL}Compare ref: $compare_ref${NL}Merge base: $merge_base${NL}Frontend files touched: $frontend_touched${NL}${NL}" || true

  append_block "Git status --short:${NL}${CODE_FENCE}text${NL}${status_display:-<clean>}${NL}${CODE_FENCE}${NL}${NL}" || true

  append_block "Changed files:${NL}${CODE_FENCE}text${NL}${changed_files_display}${NL}${CODE_FENCE}${NL}${NL}" || true

  included_files=0
  changed_count=0
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    changed_count=$((changed_count + 1))
    [ "$included_files" -lt "$MAX_CHANGED_FILES" ] || continue
    [ -f "$changed_file" ] || continue

    if is_summary_only_file "$changed_file"; then
      append_block "Changed file summary: $changed_file ($(wc -c < "$changed_file" | tr -d '[:space:]') bytes) [summary only]\n\n" || true
      continue
    fi

    if is_probably_source_file "$changed_file"; then
      append_block "Changed file content: $changed_file${NL}${CODE_FENCE}text${NL}$(trim_file_content "$changed_file")${NL}${CODE_FENCE}${NL}${NL}" || true
      included_files=$((included_files + 1))
    fi
  done < "$changed_files_file"

  if [ "$changed_count" -gt "$MAX_CHANGED_FILES" ]; then
    append_block "Additional changed files omitted after the first $MAX_CHANGED_FILES entries to preserve artifact budget.${NL}${NL}" || true
  fi

  sibling_tests_file="$(mktemp /tmp/codex-sibling-tests-XXXXXX.txt)"
  : > "$sibling_tests_file"
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    [ -f "$changed_file" ] || continue
    is_test_file "$changed_file" && continue
    is_probably_source_file "$changed_file" || continue
    collect_sibling_tests "$changed_file" >> "$sibling_tests_file" || true
  done < "$changed_files_file"

  awk '!seen[$0]++' "$sibling_tests_file" \
    | while IFS= read -r sibling_test; do
        [ -n "$sibling_test" ] || continue
        [ "$MAX_SIBLING_TESTS" -gt 0 ] || break
        [ -f "$sibling_test" ] || continue
        append_block "Sibling test context: $sibling_test${NL}${CODE_FENCE}text${NL}$(trim_file_content "$sibling_test")${NL}${CODE_FENCE}${NL}${NL}" || true
        MAX_SIBLING_TESTS=$((MAX_SIBLING_TESTS - 1))
      done

  diff_for_candidates="$(printf '%s\n%s\n' "$diff_output" "$worktree_diff")"
  candidates="$(printf '%s' "$diff_for_candidates" | extract_enum_candidates | head -n "$MAX_ENUM_CANDIDATES" || true)"
  if [ -n "$candidates" ]; then
    enum_context=""
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      enum_context="${enum_context}Candidate value: ${candidate}${NL}"
      enum_context="${enum_context}$(rg -n -C 2 --fixed-strings --glob '!node_modules/**' --glob '!dist/**' --glob '!build/**' --glob '!coverage/**' "$candidate" "$REPO_ROOT" | head -n 20 || true)${NL}${NL}"
    done <<EOF
$candidates
EOF
    append_block "Targeted consumer context for newly added enum/status-like values:${NL}${CODE_FENCE}text${NL}${enum_context}${NL}${CODE_FENCE}${NL}${NL}" || true
  fi

  append_block "Diff stat:${NL}${CODE_FENCE}text${NL}${diff_stat:-<no committed diff>}${NL}${CODE_FENCE}${NL}${NL}" || true
  append_block "Committed diff (${merge_base}...HEAD):${NL}${CODE_FENCE}diff${NL}${diff_output:-<no committed diff>}${NL}${CODE_FENCE}${NL}${NL}" || true

  if [ -n "$worktree_diff" ]; then
    append_block "Working tree diff:${NL}${CODE_FENCE}diff${NL}${worktree_diff}${NL}${CODE_FENCE}${NL}${NL}" || true
  fi

  rm -f "$changed_files_file" "$sibling_tests_file"
}

write_pr_artifact() {
  local pr_metadata pr_files pr_diff frontend_touched

  pr_metadata="$(gh pr view "$PR_NUMBER" --json number,state,baseRefName,headRefName,title,url 2>/dev/null || true)"
  if [ -z "$pr_metadata" ]; then
    echo "Could not load PR metadata for $PR_NUMBER." >&2
    exit 3
  fi

  pr_files="$(gh pr view "$PR_NUMBER" --json files --jq '.files[].path' 2>/dev/null || true)"
  pr_diff="$(gh pr diff "$PR_NUMBER" 2>/dev/null || true)"
  frontend_touched="false"
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    if is_frontend_file "$changed_file"; then
      frontend_touched="true"
      break
    fi
  done <<EOF
$pr_files
EOF

  append_block "Review Artifact (pr)${NL}====================${NL}Repo root: $REPO_ROOT${NL}PR number: $PR_NUMBER${NL}Frontend files touched: $frontend_touched${NL}${NL}" || true
  append_block "PR metadata:${NL}${CODE_FENCE}json${NL}$pr_metadata${NL}${CODE_FENCE}${NL}${NL}" || true
  append_block "PR files:${NL}${CODE_FENCE}text${NL}${pr_files:-<unknown>}${NL}${CODE_FENCE}${NL}${NL}" || true
  append_block "PR diff:${NL}${CODE_FENCE}diff${NL}${pr_diff:-<no diff available>}${NL}${CODE_FENCE}${NL}${NL}" || true
}

case "$MODE" in
  code)
    write_code_artifact
    ;;
  pr)
    write_pr_artifact
    ;;
esac
