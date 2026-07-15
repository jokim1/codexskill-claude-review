#!/usr/bin/env bash

set -euo pipefail

MODE=""
REPO_ROOT=""
OUTPUT_FILE=""
BASE_BRANCH=""
PR_NUMBER=""
SPLIT_OUTPUT_DIR=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/artifact-limits.sh"

MAX_ARTIFACT_BYTES="$CLAUDE_REVIEW_MAX_ARTIFACT_BYTES"
MAX_SPLIT_PARTS="$CLAUDE_REVIEW_MAX_SPLIT_PARTS"
MAX_REPEATED_SCOPE_BYTES=$((MAX_ARTIFACT_BYTES / 4))
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
  --split-output-dir <path>
                         Optional directory for split artifacts when the full
                         artifact exceeds the per-review byte cap
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
    --split-output-dir)
      SPLIT_OUTPUT_DIR="${2:-}"
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

artifact_was_split="false"
SPLIT_PART_FILES=()
SPLIT_SCRATCH_PATHS=()
SPLIT_OUTPUT_DIR_READY="false"

register_split_scratch() {
  SPLIT_SCRATCH_PATHS+=("$1")
}

cleanup_split_scratch() {
  local scratch_path

  if [ "$artifact_was_split" != "true" ] && [ "$SPLIT_OUTPUT_DIR_READY" = "true" ]; then
    rm -f "$SPLIT_OUTPUT_DIR"/claude-review-part-*.txt "$SPLIT_OUTPUT_DIR"/manifest.txt
  fi

  for scratch_path in "${SPLIT_SCRATCH_PATHS[@]:-}"; do
    [ -n "$scratch_path" ] || continue
    rm -rf "$scratch_path"
  done
}

trap cleanup_split_scratch EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

append_block() {
  local block="$1"

  printf '%s' "$block" >> "$OUTPUT_FILE"
}

byte_count_string() {
  local value="$1"

  LC_ALL=C printf '%s' "$value" | wc -c | tr -d '[:space:]'
}

split_part_header_byte_count() {
  split_part_header "$@" | wc -c | tr -d '[:space:]'
}

file_bytes() {
  wc -c < "$1" | tr -d '[:space:]'
}

TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
[ -n "$TEMP_ROOT" ] || TEMP_ROOT="/tmp"
SPLIT_LOCK_STALE_SECONDS="${CLAUDE_REVIEW_SPLIT_LOCK_STALE_SECONDS:-3600}"
if ! [[ "$SPLIT_LOCK_STALE_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  SPLIT_LOCK_STALE_SECONDS=3600
fi

make_temp_file() {
  mktemp "$TEMP_ROOT/$1"
}

make_temp_dir() {
  mktemp -d "$TEMP_ROOT/$1"
}

file_mtime_epoch() {
  local path="$1"
  local mtime=""

  mtime="$(stat -f %m "$path" 2>/dev/null || true)"
  if [[ "$mtime" =~ ^[0-9]+$ ]]; then
    printf '%s' "$mtime"
    return 0
  fi

  mtime="$(stat -c %Y "$path" 2>/dev/null || true)"
  if [[ "$mtime" =~ ^[0-9]+$ ]]; then
    printf '%s' "$mtime"
    return 0
  fi

  printf '0'
}

path_age_is_stale() {
  local path="$1"
  local path_mtime now

  path_mtime="$(file_mtime_epoch "$path")"
  now="$(date +%s)"
  [[ "$path_mtime" =~ ^[0-9]+$ ]] && [ $((now - path_mtime)) -ge "$SPLIT_LOCK_STALE_SECONDS" ]
}

split_lock_is_stale() {
  local lock_file="$1"
  local lock_pid age_path

  [ -e "$lock_file" ] || return 0
  age_path="$lock_file"
  if [ -d "$lock_file" ]; then
    lock_pid="$(awk 'NR == 1 { print; exit }' "$lock_file/pid" 2>/dev/null || true)"
    [ ! -e "$lock_file/pid" ] || age_path="$lock_file/pid"
  else
    lock_pid="$(awk 'NR == 1 { print; exit }' "$lock_file" 2>/dev/null || true)"
  fi

  if [[ "$lock_pid" =~ ^[0-9]+$ ]]; then
    kill -0 "$lock_pid" 2>/dev/null && return 1
    return 0
  fi

  path_age_is_stale "$age_path"
}

acquire_split_output_lock() {
  local lock_file="$1"
  local reaper_dir reaper_mtime now

  if mkdir "$lock_file" 2>/dev/null; then
    if printf '%s\n' "$$" > "$lock_file/pid"; then
      return 0
    fi
    rm -rf "$lock_file"
    return 1
  fi

  [ -d "$lock_file" ] || return 1
  reaper_dir="$lock_file/reaper"
  if ! mkdir "$reaper_dir" 2>/dev/null; then
    if ! split_lock_is_stale "$lock_file"; then
      return 1
    fi

    reaper_mtime="$(file_mtime_epoch "$reaper_dir")"
    now="$(date +%s)"
    if ! [[ "$reaper_mtime" =~ ^[0-9]+$ ]] || [ $((now - reaper_mtime)) -lt "$SPLIT_LOCK_STALE_SECONDS" ]; then
      return 1
    fi

    rm -rf "$reaper_dir"
    mkdir "$reaper_dir" 2>/dev/null || return 1
  fi

  if ! split_lock_is_stale "$lock_file"; then
    rmdir "$reaper_dir" 2>/dev/null || true
    return 1
  fi

  rm -rf "$lock_file"
  if mkdir "$lock_file" 2>/dev/null; then
    if printf '%s\n' "$$" > "$lock_file/pid"; then
      return 0
    fi
    rm -rf "$lock_file"
  fi

  return 1
}

split_output_dir_has_review_outputs() {
  local output_path

  [ -e "$SPLIT_OUTPUT_DIR/manifest.txt" ] && return 0
  for output_path in "$SPLIT_OUTPUT_DIR"/claude-review-part-*.txt; do
    [ -e "$output_path" ] && return 0
  done

  return 1
}

ensure_split_output_dir() {
  local split_base split_lock_file

  [ -n "$SPLIT_OUTPUT_DIR" ] || return 1
  [ "$SPLIT_OUTPUT_DIR_READY" = "false" ] || return 0
  case "$SPLIT_OUTPUT_DIR" in
    *[[:space:]]*)
      printf 'Split output directory must not contain whitespace: %s\n' "$SPLIT_OUTPUT_DIR" >&2
      exit 2
      ;;
  esac
  split_base="$(basename "$SPLIT_OUTPUT_DIR")"
  if [[ "$split_base" != claude-review-* ]]; then
    printf 'Split output directory basename must start with claude-review-: %s\n' "$SPLIT_OUTPUT_DIR" >&2
    exit 2
  fi

  mkdir -p "$SPLIT_OUTPUT_DIR"
  split_lock_file="$SPLIT_OUTPUT_DIR/.claude-review-build.lock"
  if ! acquire_split_output_lock "$split_lock_file"; then
    printf 'Split output directory is already in use: %s\n' "$SPLIT_OUTPUT_DIR" >&2
    exit 2
  fi
  register_split_scratch "$split_lock_file"
  if split_output_dir_has_review_outputs; then
    printf 'Split output directory already contains review outputs; use a fresh --split-output-dir: %s\n' "$SPLIT_OUTPUT_DIR" >&2
    exit 2
  fi
  SPLIT_OUTPUT_DIR_READY="true"
}

split_part_header() {
  local split_mode="$1"
  local part_number="$2"
  local original_bytes="$3"
  local common_context="$4"
  local included_labels="$5"

  printf 'Review Artifact Split Part%s==========================%s' "$NL" "$NL"
  printf 'Mode: %s%s' "$split_mode" "$NL"
  printf 'Split part: %s%s' "$part_number" "$NL"
  printf 'Full artifact bytes: %s%s' "$original_bytes" "$NL"
  printf 'Max bytes per review artifact: %s%s%s' "$MAX_ARTIFACT_BYTES" "$NL" "$NL"
  printf '%s' "$common_context"
  printf '%sFiles or diff chunks included in this part:%s%s%s%s%s%s%s' \
    "$NL" "$NL" "$CODE_FENCE" "text" "$NL" "$included_labels" "$NL" "$CODE_FENCE"
  printf '%s%s' "$NL" "$NL"
}

write_split_part_file() {
  local split_mode="$1"
  local part_number="$2"
  local original_bytes="$3"
  local common_context="$4"
  local included_labels="$5"
  local body_file="$6"
  local part_file part_bytes

  if [ "$part_number" -gt "$MAX_SPLIT_PARTS" ]; then
    printf 'Review artifact split would create more than %s parts. Narrow the diff or raise CLAUDE_REVIEW_MAX_SPLIT_PARTS.\n' "$MAX_SPLIT_PARTS" >&2
    exit 4
  fi

  part_file="$SPLIT_OUTPUT_DIR/claude-review-part-$(printf '%03d' "$part_number").txt"
  {
    split_part_header "$split_mode" "$part_number" "$original_bytes" "$common_context" "$included_labels"
    cat "$body_file"
  } > "$part_file"

  part_bytes="$(file_bytes "$part_file")"
  if [ "$part_bytes" -gt "$MAX_ARTIFACT_BYTES" ]; then
    printf 'Split artifact part %s is too large (%s bytes > %s bytes).\n' "$part_file" "$part_bytes" "$MAX_ARTIFACT_BYTES" >&2
    exit 4
  fi

  SPLIT_PART_FILES+=("$part_file")
}

write_split_manifest() {
  local split_mode="$1"
  local original_bytes="$2"
  local manifest_file="$SPLIT_OUTPUT_DIR/manifest.txt"
  local part_file part_bytes

  {
    printf 'Review Artifact Split Manifest%s' "$NL"
    printf '==============================%s' "$NL"
    printf 'Mode: %s%s' "$split_mode" "$NL"
    printf 'Full artifact: %s%s' "$OUTPUT_FILE" "$NL"
    printf 'Full artifact bytes: %s%s' "$original_bytes" "$NL"
    printf 'Max bytes per review artifact: %s%s' "$MAX_ARTIFACT_BYTES" "$NL"
    printf 'Max split parts: %s%s' "$MAX_SPLIT_PARTS" "$NL"
    printf 'Part count: %s%s%s' "${#SPLIT_PART_FILES[@]}" "$NL" "$NL"
    for part_file in "${SPLIT_PART_FILES[@]}"; do
      part_bytes="$(file_bytes "$part_file")"
      printf 'Part file: %s (%s bytes)%s' "$part_file" "$part_bytes" "$NL"
    done
  } > "$manifest_file"

  printf 'ARTIFACT_SPLIT true%s' "$NL"
  printf 'MANIFEST_FILE %s%s' "$manifest_file" "$NL"
  printf 'PART_COUNT %s%s' "${#SPLIT_PART_FILES[@]}" "$NL"
  for part_file in "${SPLIT_PART_FILES[@]}"; do
    printf 'PART_FILE %s%s' "$part_file" "$NL"
  done
}

calculate_max_raw_diff_bytes() {
  local split_mode="$1"
  local original_bytes="$2"
  local common_context="$3"
  local header_bytes label_reserve_bytes max_raw_bytes

  header_bytes="$(split_part_header_byte_count "$split_mode" 1 "$original_bytes" "$common_context" "sample")"
  label_reserve_bytes=$((MAX_ARTIFACT_BYTES / 10))
  [ "$label_reserve_bytes" -ge 2048 ] || label_reserve_bytes=2048
  max_raw_bytes=$((MAX_ARTIFACT_BYTES - header_bytes - label_reserve_bytes))

  if [ "$max_raw_bytes" -lt 4096 ]; then
    printf 'Split artifact shared context is too large (%s bytes available for diff content).\n' "$max_raw_bytes" >&2
    exit 4
  fi

  printf '%s' "$max_raw_bytes"
}

wrap_raw_diff_block() {
  local label="$1"
  local raw_file="$2"
  local block_file="$3"

  {
    printf 'File diff: %s%s' "$label" "$NL"
    printf '%s%s' "${CODE_FENCE}diff" "$NL"
    cat "$raw_file"
    printf '%s%s%s' "$NL" "$CODE_FENCE" "$NL"
    printf '%s' "$NL"
  } > "$block_file"
}

add_split_block() {
  local block_file="$1"
  local label="$2"

  SPLIT_BLOCK_FILES+=("$block_file")
  SPLIT_BLOCK_LABELS+=("$label")
}

wrap_text_block() {
  local label="$1"
  local language="$2"
  local content_file="$3"
  local block_file="$4"

  {
    printf '%s:%s' "$label" "$NL"
    printf '%s%s' "${CODE_FENCE}${language}" "$NL"
    cat "$content_file"
    printf '%s%s%s' "$NL" "$CODE_FENCE" "$NL"
    printf '%s' "$NL"
  } > "$block_file"
}

split_text_file_into_blocks() {
  local label="$1"
  local language="$2"
  local content_file="$3"
  local block_dir="$4"
  local max_content_bytes="$5"
  local content_bytes chunk_dir chunk_count chunk_index chunk_file block_file safe_name

  content_bytes="$(file_bytes "$content_file")"
  safe_name="$(printf '%s' "$label" | tr '/[:space:]' '___' | tr -cd 'A-Za-z0-9._-' | cut -c 1-80)"
  [ -n "$safe_name" ] || safe_name="metadata"

  if [ "$content_bytes" -le "$max_content_bytes" ]; then
    block_file="$block_dir/block-$(printf '%06d' "${#SPLIT_BLOCK_FILES[@]}").txt"
    wrap_text_block "$label" "$language" "$content_file" "$block_file"
    add_split_block "$block_file" "$label"
    return 0
  fi

  chunk_dir="$block_dir/text-chunks-$safe_name"
  mkdir -p "$chunk_dir"
  chunk_count="$(
    LC_ALL=C awk -v max="$max_content_bytes" -v dir="$chunk_dir" '
      BEGIN {
        part = 1
        bytes = 0
        out = sprintf("%s/chunk-%03d.txt", dir, part)
      }
      function next_chunk() {
        close(out)
        part += 1
        bytes = 0
        out = sprintf("%s/chunk-%03d.txt", dir, part)
      }
      {
        line = $0 ORS
        while (length(line) > 0) {
          remaining = max - bytes
          if (remaining <= 0) {
            next_chunk()
            remaining = max - bytes
          }
          if (length(line) > remaining) {
            printf "%s", substr(line, 1, remaining) >> out
            line = substr(line, remaining + 1)
            next_chunk()
          } else {
            printf "%s", line >> out
            bytes += length(line)
            line = ""
          }
        }
      }
      END {
        print part
      }
    ' "$content_file"
  )"

  chunk_index=1
  while [ "$chunk_index" -le "$chunk_count" ]; do
    chunk_file="$chunk_dir/chunk-$(printf '%03d' "$chunk_index").txt"
    block_file="$block_dir/block-$(printf '%06d' "${#SPLIT_BLOCK_FILES[@]}").txt"
    wrap_text_block "$label (chunk $chunk_index of $chunk_count)" "$language" "$chunk_file" "$block_file"
    add_split_block "$block_file" "$label (chunk $chunk_index of $chunk_count)"
    chunk_index=$((chunk_index + 1))
  done
}

split_raw_diff_into_blocks() {
  local label="$1"
  local raw_file="$2"
  local block_dir="$3"
  local max_raw_bytes="$4"
  local raw_bytes chunk_dir chunk_count chunk_index chunk_file block_file safe_name

  raw_bytes="$(file_bytes "$raw_file")"
  safe_name="$(printf '%s' "$label" | tr '/[:space:]' '___' | tr -cd 'A-Za-z0-9._-' | cut -c 1-80)"
  [ -n "$safe_name" ] || safe_name="diff"

  if [ "$raw_bytes" -le "$max_raw_bytes" ]; then
    block_file="$block_dir/block-$(printf '%06d' "${#SPLIT_BLOCK_FILES[@]}").txt"
    wrap_raw_diff_block "$label" "$raw_file" "$block_file"
    add_split_block "$block_file" "$label"
    return 0
  fi

  chunk_dir="$block_dir/chunks-$safe_name"
  mkdir -p "$chunk_dir"
  chunk_count="$(
    LC_ALL=C awk -v max="$max_raw_bytes" -v dir="$chunk_dir" '
      BEGIN {
        part = 1
        bytes = 0
        prefix_bytes = 0
        section_context = ""
        file_context = ""
        in_file_header = 0
        in_hunk = 0
        hunk_old_line = 0
        hunk_new_line = 0
        out = sprintf("%s/chunk-%03d.diff", dir, part)
      }
      function hunk_range(line_number) {
        if (line_number <= 0) {
          return "0,0"
        }
        return line_number
      }
      function continuation_hunk_header() {
        return sprintf("@@ -%s +%s @@ split artifact continuation", hunk_range(hunk_old_line), hunk_range(hunk_new_line))
      }
      function current_prefix() {
        prefix = file_context
        if (in_hunk) {
          prefix = prefix continuation_hunk_header() ORS
        }
        return prefix
      }
      function current_prefix_byte_count() {
        prefix = current_prefix()
        if (length(prefix) > 0 && length(prefix) < max) {
          return length(prefix)
        }
        return 0
      }
      function parse_hunk_header(text, parts, old_range, new_range, old_parts, new_parts) {
        split(text, parts, " ")
        old_range = parts[2]
        new_range = parts[3]
        sub(/^-/, "", old_range)
        sub(/^\+/, "", new_range)
        split(old_range, old_parts, ",")
        split(new_range, new_parts, ",")
        hunk_old_line = old_parts[1] + 0
        hunk_new_line = new_parts[1] + 0
        in_hunk = 1
      }
      function advance_hunk(text) {
        if (!in_hunk) {
          return
        }
        if (text ~ /^ /) {
          hunk_old_line += 1
          hunk_new_line += 1
        } else if (text ~ /^-/) {
          hunk_old_line += 1
        } else if (text ~ /^\+/) {
          hunk_new_line += 1
        }
      }
      function next_chunk() {
        close(out)
        part += 1
        bytes = 0
        prefix_bytes = 0
        out = sprintf("%s/chunk-%03d.diff", dir, part)
        prefix = current_prefix()
        if (length(prefix) > 0 && length(prefix) < max) {
          printf "%s", prefix >> out
          bytes = length(prefix)
          prefix_bytes = bytes
        }
      }
      {
        line = $0 ORS
        if ($0 ~ /^(Committed diff for|Working tree diff for)/) {
          section_context = line
          file_context = section_context
          in_hunk = 0
          in_file_header = 1
        } else if ($0 ~ /^diff --git /) {
          file_context = section_context line
          in_hunk = 0
          in_file_header = 1
        } else if (in_file_header && $0 ~ /^(index |new file mode |deleted file mode |old mode |new mode |similarity index |rename from |rename to |--- |\+\+\+ )/) {
          file_context = file_context line
        } else if ($0 ~ /^@@ /) {
          parse_hunk_header($0)
          in_file_header = 0
        } else if (in_file_header) {
          in_file_header = 0
        }
        if (length(line) > max) {
          printf "A single diff line is too large for one split artifact chunk (%d bytes > %d bytes).\n", length(line), max > "/dev/stderr"
          exit 4
        }
        if (in_hunk && $0 !~ /^@@ / && length(line) > max - current_prefix_byte_count()) {
          printf "A single diff line is too large for one split artifact chunk (%d bytes > %d bytes).\n", length(line), max - current_prefix_byte_count() > "/dev/stderr"
          exit 4
        }
        while (length(line) > 0) {
          remaining = max - bytes
          if (remaining <= 0) {
            next_chunk()
            remaining = max - bytes
          }
          if (length(line) > remaining && bytes > prefix_bytes) {
            next_chunk()
            remaining = max - bytes
          }
          if (length(line) > remaining) {
            printf "%s", substr(line, 1, remaining) >> out
            line = substr(line, remaining + 1)
            next_chunk()
          } else {
            printf "%s", line >> out
            bytes += length(line)
            line = ""
          }
        }
        advance_hunk($0)
      }
      END {
        print part
      }
    ' "$raw_file"
  )"

  chunk_index=1
  while [ "$chunk_index" -le "$chunk_count" ]; do
    chunk_file="$chunk_dir/chunk-$(printf '%03d' "$chunk_index").diff"
    block_file="$block_dir/block-$(printf '%06d' "${#SPLIT_BLOCK_FILES[@]}").txt"
    wrap_raw_diff_block "$label (chunk $chunk_index of $chunk_count)" "$chunk_file" "$block_file"
    add_split_block "$block_file" "$label (chunk $chunk_index of $chunk_count)"
    chunk_index=$((chunk_index + 1))
  done
}

pack_split_blocks() {
  local split_mode="$1"
  local original_bytes="$2"
  local common_context="$3"
  local body_file part_number current_body_bytes current_labels index block_file block_label block_bytes
  local candidate_labels candidate_header_bytes candidate_bytes

  ensure_split_output_dir || {
    printf 'Artifact is %s bytes, which exceeds the %s-byte cap. Re-run with --split-output-dir to split it.\n' "$original_bytes" "$MAX_ARTIFACT_BYTES" >&2
    exit 4
  }

  if [ "${#SPLIT_BLOCK_FILES[@]}" -eq 0 ]; then
    printf 'Artifact exceeded the cap, but no diff blocks were available to split.\n' >&2
    exit 4
  fi

  body_file="$(make_temp_file "claude-review-part-body-XXXXXX")"
  register_split_scratch "$body_file"
  part_number=1
  current_body_bytes=0
  current_labels=""

  for index in "${!SPLIT_BLOCK_FILES[@]}"; do
    block_file="${SPLIT_BLOCK_FILES[$index]}"
    block_label="${SPLIT_BLOCK_LABELS[$index]}"
    block_bytes="$(file_bytes "$block_file")"

    candidate_labels="$current_labels"
    if [ -n "$candidate_labels" ]; then
      candidate_labels="${candidate_labels}${NL}${block_label}"
    else
      candidate_labels="$block_label"
    fi

    candidate_header_bytes="$(split_part_header_byte_count "$split_mode" "$part_number" "$original_bytes" "$common_context" "$candidate_labels")"
    candidate_bytes=$((candidate_header_bytes + current_body_bytes + block_bytes))

    if [ "$current_body_bytes" -gt 0 ] && [ "$candidate_bytes" -gt "$MAX_ARTIFACT_BYTES" ]; then
      write_split_part_file "$split_mode" "$part_number" "$original_bytes" "$common_context" "$current_labels" "$body_file"
      : > "$body_file"
      part_number=$((part_number + 1))
      current_body_bytes=0
      current_labels="$block_label"
      candidate_header_bytes="$(split_part_header_byte_count "$split_mode" "$part_number" "$original_bytes" "$common_context" "$current_labels")"
      candidate_bytes=$((candidate_header_bytes + block_bytes))
    else
      current_labels="$candidate_labels"
    fi

    if [ "$candidate_bytes" -gt "$MAX_ARTIFACT_BYTES" ]; then
      printf 'A split diff block is too large for one review part (%s bytes > %s bytes): %s\n' "$candidate_bytes" "$MAX_ARTIFACT_BYTES" "$block_label" >&2
      exit 4
    fi

    cat "$block_file" >> "$body_file"
    current_body_bytes=$((current_body_bytes + block_bytes))
  done

  if [ "$current_body_bytes" -gt 0 ]; then
    write_split_part_file "$split_mode" "$part_number" "$original_bytes" "$common_context" "$current_labels" "$body_file"
  fi

  rm -f "$body_file"
  write_split_manifest "$split_mode" "$original_bytes"
  artifact_was_split="true"
}

finalize_artifact_size() {
  local artifact_bytes

  artifact_bytes="$(file_bytes "$OUTPUT_FILE")"
  if [ "$artifact_bytes" -gt "$MAX_ARTIFACT_BYTES" ] && [ "$artifact_was_split" != "true" ]; then
    printf 'Review artifact is too large for one review pass (%s bytes > %s bytes). Re-run with --split-output-dir to create split artifacts.\n' "$artifact_bytes" "$MAX_ARTIFACT_BYTES" >&2
    exit 4
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

collect_changed_files() {
  local merge_base="$1"
  {
    git diff --name-only "$merge_base...HEAD"
    git diff --name-only HEAD
    git ls-files --others --exclude-standard
  } | awk 'NF && !seen[$0]++'
}

collect_untracked_files() {
  git ls-files --others --exclude-standard | awk 'NF && !seen[$0]++'
}

render_untracked_file_diff() {
  local path="$1"
  local diff_output=""

  diff_output="$(git diff --no-index --text -- /dev/null "$path" 2>/dev/null || true)"
  if [ -n "$diff_output" ]; then
    printf '%s' "$diff_output"
    return 0
  fi

  printf 'diff --git a/%s b/%s\n' "$path" "$path"
  printf 'new file mode 100644\n'
  printf '--- /dev/null\n'
  printf '+++ b/%s\n' "$path"
  printf '@@ -0,0 +0,0 @@\n'
}

extract_enum_candidates() {
  grep -E '^\+' \
    | grep -vE '^\+\+\+' \
    | grep -Ei '(status|state|type|kind|mode|tier|variant|role|phase|view|tab)' \
    | grep -oE "\"[A-Za-z][A-Za-z0-9_-]{1,31}\"|'[A-Za-z][A-Za-z0-9_-]{1,31}'" \
    | tr -d "\"'" \
    | awk '!seen[$0]++'
}

write_code_split_artifacts() {
  local original_bytes="$1"
  local common_context="$2"
  local changed_files_file="$3"
  local untracked_files_file="$4"
  local merge_base="$5"
  local status_display="$6"
  local changed_tests_display="$7"
  local enum_context="$8"
  local diff_stat="$9"
  local diff_output="${10}"
  local worktree_diff="${11}"
  local metadata_repeated_in_common="${12}"
  local block_dir raw_dir max_raw_bytes changed_file raw_file block_index metadata_file aggregate_diff_file

  [ "$original_bytes" -gt "$MAX_ARTIFACT_BYTES" ] || return 0
  [ -n "$SPLIT_OUTPUT_DIR" ] || return 0

  SPLIT_BLOCK_FILES=()
  SPLIT_BLOCK_LABELS=()
  SPLIT_PART_FILES=()
  block_dir="$(make_temp_dir "claude-review-code-blocks-XXXXXX")"
  raw_dir="$(make_temp_dir "claude-review-code-raw-XXXXXX")"
  register_split_scratch "$block_dir"
  register_split_scratch "$raw_dir"
  max_raw_bytes="$(calculate_max_raw_diff_bytes "code" "$original_bytes" "$common_context")"
  block_index=0

  if [ "$metadata_repeated_in_common" != "true" ]; then
    metadata_file="$block_dir/metadata-status.txt"
    printf '%s\n' "${status_display:-<clean>}" > "$metadata_file"
    split_text_file_into_blocks "Git status --short" "text" "$metadata_file" "$block_dir" "$max_raw_bytes"

    metadata_file="$block_dir/metadata-changed-files.txt"
    if [ -s "$changed_files_file" ]; then
      cp "$changed_files_file" "$metadata_file"
    else
      printf '<none>\n' > "$metadata_file"
    fi
    split_text_file_into_blocks "Changed files" "text" "$metadata_file" "$block_dir" "$max_raw_bytes"

    if [ -n "$changed_tests_display" ]; then
      metadata_file="$block_dir/metadata-changed-tests.txt"
      printf '%s\n' "$changed_tests_display" > "$metadata_file"
      split_text_file_into_blocks "Changed test files" "text" "$metadata_file" "$block_dir" "$max_raw_bytes"
    fi

    metadata_file="$block_dir/metadata-diff-stat.txt"
    printf '%s\n' "${diff_stat:-<no committed diff>}" > "$metadata_file"
    split_text_file_into_blocks "Diff stat" "text" "$metadata_file" "$block_dir" "$max_raw_bytes"
  fi

  if [ -n "$enum_context" ]; then
    metadata_file="$block_dir/metadata-enum-context.txt"
    printf '%s\n' "$enum_context" > "$metadata_file"
    split_text_file_into_blocks "Targeted consumer context for newly added enum/status-like values" "text" "$metadata_file" "$block_dir" "$max_raw_bytes"
  fi

  if [ -s "$untracked_files_file" ]; then
    while IFS= read -r changed_file; do
      [ -n "$changed_file" ] || continue
      [ -f "$changed_file" ] || continue
      raw_file="$raw_dir/untracked-$(printf '%06d' "$block_index").diff"
      render_untracked_file_diff "$changed_file" > "$raw_file"
      split_raw_diff_into_blocks "Untracked file diff: $changed_file" "$raw_file" "$block_dir" "$max_raw_bytes"
      block_index=$((block_index + 1))
    done < "$untracked_files_file"
  fi

  if [ -n "$diff_output" ]; then
    aggregate_diff_file="$raw_dir/committed.diff"
    printf '%s\n' "$diff_output" > "$aggregate_diff_file"
    add_aggregate_diff_blocks "Committed diff (${merge_base}...HEAD)" "$aggregate_diff_file" "$raw_dir" "$block_dir" "$max_raw_bytes"
  fi

  if [ -n "$worktree_diff" ]; then
    aggregate_diff_file="$raw_dir/worktree.diff"
    printf '%s\n' "$worktree_diff" > "$aggregate_diff_file"
    add_aggregate_diff_blocks "Working tree diff (HEAD)" "$aggregate_diff_file" "$raw_dir" "$block_dir" "$max_raw_bytes"
  fi

  pack_split_blocks "code" "$original_bytes" "$common_context"
  rm -rf "$block_dir" "$raw_dir"
}

split_diff_to_raw_blocks() {
  local pr_diff_file="$1"
  local raw_dir="$2"
  local labels_file="$3"
  local count_file="$4"

  awk -v dir="$raw_dir" -v labels="$labels_file" -v count_file="$count_file" '
    BEGIN {
      part = 0
      out = ""
    }
    /^diff --git / {
      if (out != "") {
        close(out)
      }
      part += 1
      out = sprintf("%s/raw-%06d.diff", dir, part)
      label = $0
      sub(/^diff --git /, "", label)
      print label >> labels
    }
    {
      if (out == "") {
        part = 1
        out = sprintf("%s/raw-%06d.diff", dir, part)
        print "PR diff preamble" >> labels
      }
      print $0 >> out
    }
    END {
      print part > count_file
    }
  ' "$pr_diff_file"
}

add_aggregate_diff_blocks() {
  local section_label="$1"
  local diff_file="$2"
  local raw_dir="$3"
  local block_dir="$4"
  local max_raw_bytes="$5"
  local safe_name section_raw_dir labels_file count_file count index raw_file label

  [ -s "$diff_file" ] || return 0

  safe_name="$(printf '%s' "$section_label" | tr '/[:space:]' '___' | tr -cd 'A-Za-z0-9._-' | cut -c 1-80)"
  [ -n "$safe_name" ] || safe_name="diff-section"
  section_raw_dir="$raw_dir/$safe_name"
  mkdir -p "$section_raw_dir"
  labels_file="$section_raw_dir/labels.txt"
  count_file="$section_raw_dir/count.txt"

  split_diff_to_raw_blocks "$diff_file" "$section_raw_dir" "$labels_file" "$count_file"
  count="$(cat "$count_file")"

  index=1
  while [ "$index" -le "$count" ]; do
    raw_file="$section_raw_dir/raw-$(printf '%06d' "$index").diff"
    label="$(awk -v line="$index" 'NR == line { print; exit }' "$labels_file")"
    [ -n "$label" ] || label="diff block $index"
    split_raw_diff_into_blocks "$section_label: $label" "$raw_file" "$block_dir" "$max_raw_bytes"
    index=$((index + 1))
  done
}

write_pr_split_artifacts() {
  local original_bytes="$1"
  local common_context="$2"
  local pr_diff="$3"
  local pr_metadata="$4"
  local pr_files="$5"
  local block_dir raw_dir pr_diff_file labels_file count_file max_raw_bytes count index raw_file label metadata_file

  [ "$original_bytes" -gt "$MAX_ARTIFACT_BYTES" ] || return 0
  [ -n "$SPLIT_OUTPUT_DIR" ] || return 0

  SPLIT_BLOCK_FILES=()
  SPLIT_BLOCK_LABELS=()
  SPLIT_PART_FILES=()
  block_dir="$(make_temp_dir "claude-review-pr-blocks-XXXXXX")"
  raw_dir="$(make_temp_dir "claude-review-pr-raw-XXXXXX")"
  register_split_scratch "$block_dir"
  register_split_scratch "$raw_dir"
  pr_diff_file="$raw_dir/pr.diff"
  labels_file="$raw_dir/labels.txt"
  count_file="$raw_dir/count.txt"
  printf '%s\n' "${pr_diff:-<no diff available>}" > "$pr_diff_file"

  max_raw_bytes="$(calculate_max_raw_diff_bytes "pr" "$original_bytes" "$common_context")"
  metadata_file="$block_dir/metadata-pr.json"
  printf '%s\n' "$pr_metadata" > "$metadata_file"
  split_text_file_into_blocks "PR metadata" "json" "$metadata_file" "$block_dir" "$max_raw_bytes"

  metadata_file="$block_dir/metadata-pr-files.txt"
  printf '%s\n' "${pr_files:-<unknown>}" > "$metadata_file"
  split_text_file_into_blocks "PR files" "text" "$metadata_file" "$block_dir" "$max_raw_bytes"

  split_diff_to_raw_blocks "$pr_diff_file" "$raw_dir" "$labels_file" "$count_file"
  count="$(cat "$count_file")"

  index=1
  while [ "$index" -le "$count" ]; do
    raw_file="$raw_dir/raw-$(printf '%06d' "$index").diff"
    label="$(awk -v line="$index" 'NR == line { print; exit }' "$labels_file")"
    [ -n "$label" ] || label="PR diff block $index"
    split_raw_diff_into_blocks "$label" "$raw_file" "$block_dir" "$max_raw_bytes"
    index=$((index + 1))
  done

  pack_split_blocks "pr" "$original_bytes" "$common_context"
  rm -rf "$block_dir" "$raw_dir"
}

write_code_artifact() {
  local compare_ref merge_base current_branch status_output status_display diff_stat diff_output worktree_diff
  local changed_files_file changed_files_display changed_file frontend_touched changed_tests_display untracked_files_file
  local diff_for_candidates enum_context enum_section candidates artifact_header split_common_context artifact_bytes
  local changed_file_count changed_test_count diff_stat_line_count repeated_scope_full repeated_scope_context metadata_repeated_in_common

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
  status_display="${status_output:-<clean>}"
  diff_stat="$(git diff --stat "$merge_base...HEAD")"
  diff_output="$(git diff "$merge_base...HEAD")"
  worktree_diff="$(git diff HEAD)"
  changed_files_file="$(make_temp_file "codex-changed-files-XXXXXX")"
  register_split_scratch "$changed_files_file"

  collect_changed_files "$merge_base" > "$changed_files_file"

  frontend_touched="false"
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    if is_frontend_file "$changed_file"; then
      frontend_touched="true"
      break
    fi
  done < "$changed_files_file"

  changed_files_display="$(cat "$changed_files_file")"
  changed_file_count="$(awk 'NF { count++ } END { print count + 0 }' "$changed_files_file")"

  untracked_files_file="$(make_temp_file "codex-untracked-files-XXXXXX")"
  register_split_scratch "$untracked_files_file"
  collect_untracked_files > "$untracked_files_file"

  changed_tests_display="$(
    awk 'NF' "$changed_files_file" \
      | while IFS= read -r changed_file; do
          is_test_file "$changed_file" || continue
          printf '%s\n' "$changed_file"
        done \
      | awk '!seen[$0]++'
  )"
  changed_test_count="$(printf '%s\n' "$changed_tests_display" | awk 'NF { count++ } END { print count + 0 }')"
  diff_stat_line_count="$(printf '%s\n' "$diff_stat" | awk 'NF { count++ } END { print count + 0 }')"

  diff_for_candidates="$(printf '%s\n%s\n' "$diff_output" "$worktree_diff")"
  enum_context=""
  enum_section=""
  candidates="$(printf '%s' "$diff_for_candidates" | extract_enum_candidates | head -n "$MAX_ENUM_CANDIDATES" || true)"
  if [ -n "$candidates" ]; then
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      enum_context="${enum_context}Candidate value: ${candidate}${NL}"
      enum_context="${enum_context}$(rg -n -C 2 --fixed-strings --glob '!node_modules/**' --glob '!dist/**' --glob '!build/**' --glob '!coverage/**' "$candidate" "$REPO_ROOT" | head -n 20 || true)${NL}${NL}"
    done <<EOF
$candidates
EOF
    enum_section="Targeted consumer context for newly added enum/status-like values:${NL}${CODE_FENCE}text${NL}${enum_context}${NL}${CODE_FENCE}${NL}${NL}"
  fi

  artifact_header="Review Artifact (code)${NL}======================${NL}Repo root: $REPO_ROOT${NL}Current branch: $current_branch${NL}Base branch: $BASE_BRANCH${NL}Compare ref: $compare_ref${NL}Merge base: $merge_base${NL}Frontend files touched: $frontend_touched${NL}${NL}"
  repeated_scope_full="Repeated split scope metadata:${NL}"
  repeated_scope_full="${repeated_scope_full}Git status --short:${NL}${CODE_FENCE}text${NL}${status_display:-<clean>}${NL}${CODE_FENCE}${NL}${NL}"
  repeated_scope_full="${repeated_scope_full}Changed files:${NL}${CODE_FENCE}text${NL}${changed_files_display:-<none>}${NL}${CODE_FENCE}${NL}${NL}"
  if [ -n "$changed_tests_display" ]; then
    repeated_scope_full="${repeated_scope_full}Changed test files:${NL}${CODE_FENCE}text${NL}${changed_tests_display}${NL}${CODE_FENCE}${NL}${NL}"
  fi
  repeated_scope_full="${repeated_scope_full}Diff stat:${NL}${CODE_FENCE}text${NL}${diff_stat:-<no committed diff>}${NL}${CODE_FENCE}${NL}${NL}"

  if [ "$(byte_count_string "$repeated_scope_full")" -le "$MAX_REPEATED_SCOPE_BYTES" ]; then
    metadata_repeated_in_common="true"
    repeated_scope_context="$repeated_scope_full"
  else
    metadata_repeated_in_common="false"
    repeated_scope_context="Repeated split scope summary:${NL}${CODE_FENCE}text${NL}"
    repeated_scope_context="${repeated_scope_context}Changed files: $changed_file_count${NL}"
    repeated_scope_context="${repeated_scope_context}Changed test files: $changed_test_count${NL}"
    repeated_scope_context="${repeated_scope_context}Diff stat lines: $diff_stat_line_count${NL}"
    repeated_scope_context="${repeated_scope_context}Full git status, changed-files, changed-tests, and diff-stat metadata are included as split blocks in the manifest.${NL}"
    repeated_scope_context="${repeated_scope_context}${CODE_FENCE}${NL}${NL}"
  fi

  split_common_context="${artifact_header}${repeated_scope_context}Split review note: this is one bounded part of the full artifact. Review every part listed in the manifest before producing the merged result; compact scope metadata is repeated in every part and oversized metadata/diffs are partitioned across parts.${NL}${NL}"

  append_block "$artifact_header"
  append_block "Git status --short:${NL}${CODE_FENCE}text${NL}${status_display:-<clean>}${NL}${CODE_FENCE}${NL}${NL}"
  append_block "Changed files:${NL}${CODE_FENCE}text${NL}${changed_files_display:-<none>}${NL}${CODE_FENCE}${NL}${NL}"
  if [ -n "$changed_tests_display" ]; then
    append_block "Changed test files:${NL}${CODE_FENCE}text${NL}${changed_tests_display}${NL}${CODE_FENCE}${NL}${NL}"
  fi
  append_block "$enum_section"
  append_block "Diff stat:${NL}${CODE_FENCE}text${NL}${diff_stat:-<no committed diff>}${NL}${CODE_FENCE}${NL}${NL}"

  if [ -s "$untracked_files_file" ]; then
    while IFS= read -r changed_file; do
      [ -n "$changed_file" ] || continue
      [ -f "$changed_file" ] || continue
      append_block "Untracked file diff: $changed_file${NL}${CODE_FENCE}diff${NL}$(render_untracked_file_diff "$changed_file")${NL}${CODE_FENCE}${NL}${NL}"
    done < "$untracked_files_file"
  fi

  append_block "Committed diff (${merge_base}...HEAD):${NL}${CODE_FENCE}diff${NL}${diff_output:-<no committed diff>}${NL}${CODE_FENCE}${NL}${NL}" || true

  if [ -n "$worktree_diff" ]; then
    append_block "Working tree diff (HEAD):${NL}${CODE_FENCE}diff${NL}${worktree_diff}${NL}${CODE_FENCE}${NL}${NL}" || true
  fi

  artifact_bytes="$(file_bytes "$OUTPUT_FILE")"
  write_code_split_artifacts "$artifact_bytes" "$split_common_context" "$changed_files_file" "$untracked_files_file" "$merge_base" "$status_display" "$changed_tests_display" "$enum_context" "$diff_stat" "$diff_output" "$worktree_diff" "$metadata_repeated_in_common"

  rm -f "$changed_files_file" "$untracked_files_file"
}

write_pr_artifact() {
  local pr_metadata pr_files pr_diff frontend_touched artifact_header split_common_context artifact_bytes changed_file

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

  artifact_header="Review Artifact (pr)${NL}====================${NL}Repo root: $REPO_ROOT${NL}PR number: $PR_NUMBER${NL}Frontend files touched: $frontend_touched${NL}${NL}"
  split_common_context="${artifact_header}Split review note: this is one bounded part of the full artifact. Review every part listed in the manifest before producing the merged result; metadata and diffs are partitioned across parts rather than repeated in each header.${NL}${NL}"

  append_block "$artifact_header"
  append_block "PR metadata:${NL}${CODE_FENCE}json${NL}$pr_metadata${NL}${CODE_FENCE}${NL}${NL}"
  append_block "PR files:${NL}${CODE_FENCE}text${NL}${pr_files:-<unknown>}${NL}${CODE_FENCE}${NL}${NL}"
  append_block "PR diff:${NL}${CODE_FENCE}diff${NL}${pr_diff:-<no diff available>}${NL}${CODE_FENCE}${NL}${NL}" || true

  artifact_bytes="$(file_bytes "$OUTPUT_FILE")"
  write_pr_split_artifacts "$artifact_bytes" "$split_common_context" "$pr_diff" "$pr_metadata" "$pr_files"
}

if [ -n "$SPLIT_OUTPUT_DIR" ]; then
  ensure_split_output_dir
fi

case "$MODE" in
  code)
    write_code_artifact
    ;;
  pr)
    write_pr_artifact
    ;;
esac

finalize_artifact_size
