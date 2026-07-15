#!/usr/bin/env bash

# Shared Claude launcher discovery and trust validation. This file must remain
# source-pure: definitions and readonly contract constants only.

readonly CLAUDE_LOCATOR_CONTRACT="bounded_path_native_homebrew_v6"
readonly CLAUDE_LOCATOR_TRUSTED_STORE_ROOT="/nix/store"

claude_locator_native_supported() {
  case "${1:-}" in
    darwin*|linux*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

claude_locator_homebrew_paths() {
  local os_type="${1:-}"
  local machine_type="${2:-}"

  CLAUDE_LOCATOR_HOMEBREW_PATHS=()
  case "$os_type" in
    darwin*)
      CLAUDE_LOCATOR_HOMEBREW_PATHS=(
        "/opt/homebrew/bin/claude"
        "/usr/local/bin/claude"
      )
      ;;
    linux*)
      case "$machine_type" in
        x86_64-*)
          CLAUDE_LOCATOR_HOMEBREW_PATHS=(
            "/home/linuxbrew/.linuxbrew/bin/claude"
          )
          ;;
      esac
      ;;
  esac
}

claude_locator_exact_entry_exists() {
  local candidate="$1"
  local parent="${candidate%/*}"
  local basename_part="${candidate##*/}"
  local entry=""

  if [ "$parent" = "$candidate" ]; then
    parent="."
  elif [ -z "$parent" ]; then
    parent="/"
  fi
  for entry in "$parent"/*; do
    [ "${entry##*/}" = "$basename_part" ] || continue
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      return 0
    fi
  done
  return 1
}

claude_locator_materialize_windows_executable_path() {
  local candidate="$1"
  local os_type="${2:-${OSTYPE:-}}"

  case "$os_type" in
    msys*|mingw*|cygwin*)
      ;;
    *)
      printf '%s' "$candidate"
      return 0
      ;;
  esac
  case "$candidate" in
    *.[eE][xX][eE])
      printf '%s' "$candidate"
      return 0
      ;;
  esac
  if ! claude_locator_exact_entry_exists "$candidate" && claude_locator_exact_entry_exists "${candidate}.exe"; then
    printf '%s.exe' "$candidate"
  else
    printf '%s' "$candidate"
  fi
}

claude_locator_path_candidate() {
  local invocation_cwd="${1:-$PWD}"
  local inherited_path=""
  local resolved=""
  local remaining=""
  local entry=""
  local candidate=""

  if [ "$#" -ge 2 ]; then
    inherited_path="$2"
  elif [ "${CLAUDE_RUNTIME_INHERITED_PATH+x}" = "x" ]; then
    inherited_path="$CLAUDE_RUNTIME_INHERITED_PATH"
  else
    inherited_path="${PATH-}"
  fi

  CLAUDE_LOCATOR_CANDIDATE_PATH=""
  CLAUDE_LOCATOR_CANDIDATE_SOURCE="missing"

  resolved="$(PATH="$inherited_path" type -P claude 2>/dev/null || true)"
  if [ -n "$resolved" ]; then
    resolved="$(claude_locator_materialize_windows_executable_path "$resolved")"
    CLAUDE_LOCATOR_CANDIDATE_PATH="$resolved"
    CLAUDE_LOCATOR_CANDIDATE_SOURCE="path"
    return 0
  fi

  remaining="${inherited_path}:"
  while [ -n "$remaining" ]; do
    entry="${remaining%%:*}"
    remaining="${remaining#*:}"
    if [ -z "$entry" ]; then
      entry="$invocation_cwd"
    fi
    case "$entry" in
      /*)
        candidate="$entry/claude"
        ;;
      *)
        candidate="$invocation_cwd/$entry/claude"
        ;;
    esac
    candidate="$(claude_locator_materialize_windows_executable_path "$candidate")"
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      CLAUDE_LOCATOR_CANDIDATE_PATH="$candidate"
      CLAUDE_LOCATOR_CANDIDATE_SOURCE="path"
      return 0
    fi
  done

  return 1
}

claude_locator_native_path() {
  CLAUDE_LOCATOR_CANDIDATE_PATH=""
  CLAUDE_LOCATOR_CANDIDATE_SOURCE="missing"

  claude_locator_native_supported "${OSTYPE:-}" || return 1
  case "${HOME:-}" in
    /*)
      ;;
    *)
      return 1
      ;;
  esac

  if [ -e "$HOME/.local/bin/claude" ] || [ -L "$HOME/.local/bin/claude" ]; then
    CLAUDE_LOCATOR_CANDIDATE_PATH="$HOME/.local/bin/claude"
    CLAUDE_LOCATOR_CANDIDATE_SOURCE="native_user"
    return 0
  fi
  return 1
}

claude_locator_first_present_fallback() {
  local candidate=""
  local source=""

  CLAUDE_LOCATOR_CANDIDATE_PATH=""
  CLAUDE_LOCATOR_CANDIDATE_SOURCE="missing"
  CLAUDE_LOCATOR_DEFERRED_SOURCE="none"
  CLAUDE_LOCATOR_DEFERRED_PATH="none"
  CLAUDE_LOCATOR_DEFERRED_STATUS="none"

  if claude_locator_native_path; then
    candidate="$CLAUDE_LOCATOR_CANDIDATE_PATH"
    source="$CLAUDE_LOCATOR_CANDIDATE_SOURCE"
    if claude_locator_is_dangling_symlink "$candidate"; then
      CLAUDE_LOCATOR_DEFERRED_SOURCE="$source"
      CLAUDE_LOCATOR_DEFERRED_PATH="$candidate"
      CLAUDE_LOCATOR_DEFERRED_STATUS="dangling_symlink"
    else
      return 0
    fi
  fi

  claude_locator_homebrew_paths "${OSTYPE:-}" "${MACHTYPE:-}"
  for candidate in "${CLAUDE_LOCATOR_HOMEBREW_PATHS[@]+"${CLAUDE_LOCATOR_HOMEBREW_PATHS[@]}"}"; do
    if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
      continue
    fi
    source="homebrew_default"
    if claude_locator_is_dangling_symlink "$candidate"; then
      if [ "$CLAUDE_LOCATOR_DEFERRED_STATUS" = "none" ]; then
        CLAUDE_LOCATOR_DEFERRED_SOURCE="$source"
        CLAUDE_LOCATOR_DEFERRED_PATH="$candidate"
        CLAUDE_LOCATOR_DEFERRED_STATUS="dangling_symlink"
      fi
      continue
    fi
    CLAUDE_LOCATOR_CANDIDATE_PATH="$candidate"
    CLAUDE_LOCATOR_CANDIDATE_SOURCE="$source"
    return 0
  done

  if [ "$CLAUDE_LOCATOR_DEFERRED_STATUS" = "dangling_symlink" ]; then
    CLAUDE_LOCATOR_CANDIDATE_PATH="$CLAUDE_LOCATOR_DEFERRED_PATH"
    CLAUDE_LOCATOR_CANDIDATE_SOURCE="$CLAUDE_LOCATOR_DEFERRED_SOURCE"
    CLAUDE_LOCATOR_DEFERRED_SOURCE="none"
    CLAUDE_LOCATOR_DEFERRED_PATH="none"
    CLAUDE_LOCATOR_DEFERRED_STATUS="none"
    return 0
  fi

  CLAUDE_LOCATOR_CANDIDATE_PATH=""
  CLAUDE_LOCATOR_CANDIDATE_SOURCE="missing"
  return 1
}

claude_locator_physical_directory() {
  local directory="$1"
  local physical_output=""

  physical_output="$(CDPATH=; cd -P -- "$directory" 2>/dev/null && printf '%s\001' "$PWD")" || return 1
  case "$physical_output" in
    *$'\001') CLAUDE_LOCATOR_PHYSICAL_DIRECTORY="${physical_output%$'\001'}" ;;
    *) return 1 ;;
  esac
}

claude_locator_physical_launch_path() {
  local raw_path="$1"
  local invocation_cwd="$2"
  local joined=""
  local parent=""
  local basename_part=""
  local physical_parent=""

  case "$raw_path" in
    /*)
      joined="$raw_path"
      ;;
    *)
      joined="$invocation_cwd/$raw_path"
      ;;
  esac

  basename_part="${joined##*/}"
  parent="${joined%/*}"
  [ -n "$parent" ] || parent="/"
  claude_locator_physical_directory "$parent" || return 1
  physical_parent="$CLAUDE_LOCATOR_PHYSICAL_DIRECTORY"
  if [ "$physical_parent" = "/" ]; then
    printf '/%s' "$basename_part"
  else
    printf '%s/%s' "$physical_parent" "$basename_part"
  fi
}

claude_locator_directory_symlink_hops_safe() {
  local raw_parent="$1"
  local repo_root="$2"
  local invocation_cwd="$3"
  local remaining=""
  local component=""
  local prefix="/"

  case "$raw_parent" in
    /*) remaining="${raw_parent#/}" ;;
    *) CLAUDE_LOCATOR_BOUNDARY_STATUS="validation_unavailable"; return 1 ;;
  esac
  while [ -n "$remaining" ]; do
    component="${remaining%%/*}"
    if [ "$remaining" = "$component" ]; then
      remaining=""
    else
      remaining="${remaining#*/}"
    fi
    case "$component" in
      ''|.) continue ;;
      ..)
        claude_locator_physical_directory "$prefix/.." || {
          CLAUDE_LOCATOR_BOUNDARY_STATUS="validation_unavailable"
          return 1
        }
        prefix="$CLAUDE_LOCATOR_PHYSICAL_DIRECTORY"
        continue
        ;;
    esac
    if [ "$prefix" = "/" ]; then
      prefix="/$component"
    else
      prefix="$prefix/$component"
    fi
    if [ -L "$prefix" ] && ! claude_locator_boundary_status "$prefix" "$repo_root" "$invocation_cwd"; then
      return 1
    fi
  done
  return 0
}

claude_locator_trusted_store_utility_target() {
  local utility="$1"
  local candidate_path="$2"
  local trusted_store_root="$3"
  local store_entry=""
  local store_target=""

  case "$candidate_path" in
    "$trusted_store_root"/*)
      [ -L "$candidate_path" ] || return 1
      ;;
    *)
      return 1
      ;;
  esac

  for store_entry in \
    "$trusted_store_root"/*/bin/"$utility" \
    "$trusted_store_root"/*/sbin/"$utility"; do
    [ -e "$store_entry" ] || continue
    [ "$candidate_path" -ef "$store_entry" ] || continue
    if [ -f "$store_entry" ] && [ -x "$store_entry" ] && [ ! -L "$store_entry" ]; then
      printf '%s' "$store_entry"
      return 0
    fi
    for store_target in "${store_entry%/*}"/*; do
      [ -f "$store_target" ] && [ -x "$store_target" ] && [ ! -L "$store_target" ] || continue
      if [ "$candidate_path" -ef "$store_target" ]; then
        printf '%s' "$store_target"
        return 0
      fi
    done
  done
  return 1
}

claude_locator_resolve_trusted_utility() {
  local utility="${1:-}"
  local trusted_store_root="$CLAUDE_LOCATOR_TRUSTED_STORE_ROOT"
  local candidate=""
  local physical_candidate=""
  local physical_store_root=""
  local store_parent=""
  local inherited_path=""
  local trusted_target=""

  [ -n "$utility" ] || return 1
  shift
  if [ "$#" -gt 0 ]; then
    trusted_store_root="$1"
    shift
  fi
  if [ "$#" -eq 0 ]; then
    set -- "/usr/bin/$utility" "/bin/$utility"
  fi

  for candidate in "$@"; do
    physical_candidate="$(claude_locator_physical_launch_path "$candidate" "${PWD:-/}" 2>/dev/null || true)"
    if [ -n "$physical_candidate" ] && [ -f "$physical_candidate" ] && [ -x "$physical_candidate" ] && [ ! -L "$physical_candidate" ]; then
      printf '%s' "$physical_candidate"
      return 0
    fi
  done

  if [ "${CLAUDE_RUNTIME_INHERITED_PATH+x}" = "x" ]; then
    inherited_path="$CLAUDE_RUNTIME_INHERITED_PATH"
  else
    inherited_path="${PATH-}"
  fi
  candidate="$(PATH="$inherited_path" type -P "$utility" 2>/dev/null || true)"
  [ -n "$candidate" ] || return 1
  physical_candidate="$(claude_locator_physical_launch_path "$candidate" "${PWD:-/}" 2>/dev/null || true)"
  [ -n "$physical_candidate" ] || return 1

  physical_store_root="$(claude_locator_physical_launch_path "$trusted_store_root/.claude-review-store-root" "/" 2>/dev/null || true)"
  physical_store_root="${physical_store_root%/.claude-review-store-root}"
  [ -n "$physical_store_root" ] || return 1
  case "$physical_candidate" in
    "$physical_store_root"/*)
      ;;
    *)
      return 1
      ;;
  esac
  if [ -f "$physical_candidate" ] && [ -x "$physical_candidate" ] && [ ! -L "$physical_candidate" ]; then
    trusted_target="$physical_candidate"
  else
    trusted_target="$(
      claude_locator_trusted_store_utility_target \
        "$utility" \
        "$physical_candidate" \
        "$physical_store_root" \
        2>/dev/null
    )" || return 1
  fi
  [ -f "$trusted_target" ] && [ -x "$trusted_target" ] && [ ! -L "$trusted_target" ] || return 1
  case "$trusted_target" in
    "$physical_store_root"/*) ;;
    *) return 1 ;;
  esac
  # Effective-access tests always report writable for root. Physical store
  # containment remains mandatory; apply the writability proof when it is
  # meaningful for the invoking identity.
  if [ "${EUID:-1}" -ne 0 ]; then
    [ ! -w "$trusted_target" ] || return 1
    store_parent="${trusted_target%/*}"
    while :; do
      [ ! -w "$store_parent" ] || return 1
      [ "$store_parent" = "$physical_store_root" ] && break
      case "$store_parent" in
        "$physical_store_root"/*)
          ;;
        *)
          return 1
          ;;
      esac
      store_parent="${store_parent%/*}"
      [ -n "$store_parent" ] || return 1
    done
  fi
  printf '%s' "$trusted_target"
  return 0
}

claude_locator_canonical_target() {
  local current="$1"
  local repo_root="${2:-}"
  local invocation_cwd="${3:-}"
  local link_target=""
  local link_output=""
  local readlink_bin=""
  local parent=""
  local physical_parent=""
  local basename_part=""
  local depth=0

  while [ -L "$current" ]; do
    depth=$((depth + 1))
    [ "$depth" -le 40 ] || return 2
    if [ -z "$readlink_bin" ]; then
      readlink_bin="$(claude_locator_resolve_trusted_utility readlink 2>/dev/null)" || return 2
    fi
    link_output="$("$readlink_bin" -n "$current" 2>/dev/null && printf '\001')" || return 2
    case "$link_output" in
      *$'\001') ;;
      *) return 2 ;;
    esac
    link_target="${link_output%$'\001'}"
    case "$link_target" in
      /*)
        current="$link_target"
        ;;
      *)
        current="${current%/*}/$link_target"
        ;;
    esac
    basename_part="${current##*/}"
    parent="${current%/*}"
    [ -n "$parent" ] || parent="/"
    if ! claude_locator_directory_symlink_hops_safe "$parent" "$repo_root" "$invocation_cwd"; then
      case "$CLAUDE_LOCATOR_BOUNDARY_STATUS" in
        temporary_path) return 20 ;;
        repository_path) return 21 ;;
        invocation_cwd_path) return 22 ;;
        world_writable_parent) return 23 ;;
        *) return 24 ;;
      esac
    fi
    claude_locator_physical_directory "$parent" || return 3
    physical_parent="$CLAUDE_LOCATOR_PHYSICAL_DIRECTORY"
    if [ "$physical_parent" = "/" ]; then
      current="/$basename_part"
    else
      current="$physical_parent/$basename_part"
    fi

    if [ -L "$current" ] && ! claude_locator_boundary_status "$current" "$repo_root" "$invocation_cwd"; then
      case "$CLAUDE_LOCATOR_BOUNDARY_STATUS" in
        temporary_path)
          return 20
          ;;
        repository_path)
          return 21
          ;;
        invocation_cwd_path)
          return 22
          ;;
        world_writable_parent)
          return 23
          ;;
        validation_unavailable)
          return 24
          ;;
        *)
          return 2
          ;;
      esac
    fi
  done

  basename_part="${current##*/}"
  parent="${current%/*}"
  [ -n "$parent" ] || parent="/"
  claude_locator_physical_directory "$parent" || return 3
  physical_parent="$CLAUDE_LOCATOR_PHYSICAL_DIRECTORY"
  if [ ! -e "$current" ] && [ ! -L "$current" ]; then
    [ -r "$physical_parent" ] && [ -x "$physical_parent" ] || return 3
    return 4
  fi
  if [ "$physical_parent" = "/" ]; then
    printf '/%s' "$basename_part"
  else
    printf '%s/%s' "$physical_parent" "$basename_part"
  fi
}

claude_locator_is_dangling_symlink() {
  local candidate="${1:-}"
  local canonical_status=0

  [ -L "$candidate" ] || return 1
  if claude_locator_canonical_target "$candidate" "" "${PWD:-/}" >/dev/null 2>&1; then
    return 1
  else
    canonical_status=$?
  fi
  [ "$canonical_status" -eq 4 ]
}

claude_locator_path_within() {
  local path="$1"
  local boundary="$2"
  local boundary_physical=""
  local path_physical=""

  [ -n "$boundary" ] || return 1
  boundary_physical="$(claude_locator_physical_launch_path "$boundary/.claude-review-boundary" "/" 2>/dev/null && printf '\001')" || return 1
  case "$boundary_physical" in
    *$'\001') boundary_physical="${boundary_physical%$'\001'}" ;;
    *) return 1 ;;
  esac
  boundary_physical="${boundary_physical%/.claude-review-boundary}"
  [ -n "$boundary_physical" ] || boundary_physical="/"
  path_physical="$(claude_locator_physical_launch_path "$path" "/" 2>/dev/null && printf '\001')" || return 1
  case "$path_physical" in
    *$'\001') path_physical="${path_physical%$'\001'}" ;;
    *) return 1 ;;
  esac
  if [ "$boundary_physical" = "/" ]; then
    case "$path_physical" in
      /*) return 0 ;;
    esac
  fi
  case "$path_physical" in
    "$boundary_physical"|"$boundary_physical"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

claude_locator_parent_world_writable() {
  local path="$1"
  local parent="${path%/*}"
  local stat_bin=""
  local mode=""
  local last_digit=""

  [ -n "$parent" ] || parent="/"
  stat_bin="$(claude_locator_resolve_trusted_utility stat 2>/dev/null)" || return 2
  while :; do
    mode="$("$stat_bin" -f '%Lp' "$parent" 2>/dev/null)" || mode=""
    case "$mode" in
      ''|*[!0-7]*)
        mode="$("$stat_bin" -c '%a' "$parent" 2>/dev/null)" || return 2
        ;;
    esac
    case "$mode" in
      ''|*[!0-7]*) return 2 ;;
    esac
    last_digit="${mode#${mode%?}}"
    case "$last_digit" in
      2|3|6|7)
        return 0
        ;;
    esac
    [ "$parent" = "/" ] && break
    parent="${parent%/*}"
    [ -n "$parent" ] || parent="/"
  done
  return 1
}

claude_locator_file_world_writable() {
  local path="$1"
  local stat_bin=""
  local mode=""
  local last_digit=""

  stat_bin="$(claude_locator_resolve_trusted_utility stat 2>/dev/null)" || return 2
  mode="$("$stat_bin" -f '%Lp' "$path" 2>/dev/null)" || mode=""
  case "$mode" in
    ''|*[!0-7]*)
      mode="$("$stat_bin" -c '%a' "$path" 2>/dev/null)" || return 2
      ;;
  esac
  case "$mode" in
    ''|*[!0-7]*) return 2 ;;
  esac
  last_digit="${mode#${mode%?}}"
  case "$last_digit" in
    2|3|6|7)
      return 0
      ;;
  esac
  return 1
}

claude_locator_boundary_status() {
  local path="$1"
  local repo_root="$2"
  local invocation_cwd="$3"
  local writable_status=0
  local temporary_root=""
  local temporary_roots=("/tmp" "/private/tmp")

  [ -n "${TMPDIR:-}" ] && temporary_roots+=("$TMPDIR")
  [ -n "${TEMP:-}" ] && temporary_roots+=("$TEMP")
  [ -n "${TMP:-}" ] && temporary_roots+=("$TMP")
  case "${OSTYPE:-}" in
    darwin*)
      # macOS per-user temporary roots live below this namespace even when
      # TMPDIR was stripped by a parent process.
      temporary_roots+=("/var/folders" "/private/var/folders")
      ;;
  esac
  for temporary_root in "${temporary_roots[@]}"; do
    case "${OSTYPE:-}:$temporary_root" in
      msys*:[A-Za-z]:[\\/]*|mingw*:[A-Za-z]:[\\/]*|cygwin*:[A-Za-z]:[\\/]*)
        if [ ! -x "${CLAUDE_RUNTIME_CYGPATH_BIN:-}" ]; then
          CLAUDE_LOCATOR_BOUNDARY_STATUS="validation_unavailable"
          return 1
        fi
        temporary_root="$("$CLAUDE_RUNTIME_CYGPATH_BIN" -au "$temporary_root" 2>/dev/null || true)"
        ;;
    esac
    case "$temporary_root" in
      /*)
        ;;
      *)
        continue
        ;;
    esac
    if claude_locator_path_within "$path" "$temporary_root"; then
      CLAUDE_LOCATOR_BOUNDARY_STATUS="temporary_path"
      return 1
    fi
  done
  if [ -n "$repo_root" ] && claude_locator_path_within "$path" "$repo_root"; then
    CLAUDE_LOCATOR_BOUNDARY_STATUS="repository_path"
    return 1
  fi
  if [ -n "$invocation_cwd" ] && [ "$invocation_cwd" != "/" ] && claude_locator_path_within "$path" "$invocation_cwd"; then
    CLAUDE_LOCATOR_BOUNDARY_STATUS="invocation_cwd_path"
    return 1
  fi
  if claude_locator_parent_world_writable "$path"; then
    CLAUDE_LOCATOR_BOUNDARY_STATUS="world_writable_parent"
    return 1
  else
    writable_status=$?
    if [ "$writable_status" -eq 2 ]; then
      CLAUDE_LOCATOR_BOUNDARY_STATUS="validation_unavailable"
      return 1
    fi
  fi
  CLAUDE_LOCATOR_BOUNDARY_STATUS="safe"
  return 0
}

claude_locator_validate_candidate() {
  local raw_path="${1:-}"
  local repo_root="${2:-}"
  local invocation_cwd="${3:-}"
  local launch_path=""
  local canonical_target=""
  local canonical_status=0
  local writable_status=0

  CLAUDE_LOCATOR_LAUNCH_PATH=""
  CLAUDE_LOCATOR_CANONICAL_TARGET=""
  CLAUDE_LOCATOR_VALIDATION_SCOPE="launch"
  CLAUDE_LOCATOR_VALIDATION_STATUS="missing"

  [ -n "$raw_path" ] || return 1
  launch_path="$(claude_locator_physical_launch_path "$raw_path" "$invocation_cwd" 2>/dev/null && printf '\001')" || return 1
  case "$launch_path" in
    *$'\001') launch_path="${launch_path%$'\001'}" ;;
    *) return 1 ;;
  esac
  CLAUDE_LOCATOR_LAUNCH_PATH="$launch_path"

  if [ ! -e "$launch_path" ] && [ ! -L "$launch_path" ]; then
    CLAUDE_LOCATOR_VALIDATION_STATUS="missing"
    return 1
  fi

  if ! claude_locator_boundary_status "$launch_path" "$repo_root" "$invocation_cwd"; then
    CLAUDE_LOCATOR_VALIDATION_SCOPE="launch"
    CLAUDE_LOCATOR_VALIDATION_STATUS="$CLAUDE_LOCATOR_BOUNDARY_STATUS"
    return 1
  fi

  if canonical_target="$(claude_locator_canonical_target "$launch_path" "$repo_root" "$invocation_cwd" 2>/dev/null && printf '\001')"; then
    case "$canonical_target" in
      *$'\001') canonical_target="${canonical_target%$'\001'}" ;;
      *) return 1 ;;
    esac
  else
    canonical_status=$?
    CLAUDE_LOCATOR_VALIDATION_SCOPE="target"
    case "$canonical_status" in
      4)
        CLAUDE_LOCATOR_VALIDATION_STATUS="dangling_symlink"
        ;;
      20)
        CLAUDE_LOCATOR_VALIDATION_STATUS="temporary_path"
        ;;
      21)
        CLAUDE_LOCATOR_VALIDATION_STATUS="repository_path"
        ;;
      22)
        CLAUDE_LOCATOR_VALIDATION_STATUS="invocation_cwd_path"
        ;;
      23)
        CLAUDE_LOCATOR_VALIDATION_STATUS="world_writable_parent"
        ;;
      24|*)
        CLAUDE_LOCATOR_VALIDATION_STATUS="validation_unavailable"
        ;;
    esac
    return 1
  fi
  CLAUDE_LOCATOR_CANONICAL_TARGET="$canonical_target"

  if [ ! -f "$canonical_target" ]; then
    CLAUDE_LOCATOR_VALIDATION_SCOPE="target"
    CLAUDE_LOCATOR_VALIDATION_STATUS="not_regular"
    return 1
  fi
  if [ ! -x "$canonical_target" ]; then
    CLAUDE_LOCATOR_VALIDATION_SCOPE="target"
    CLAUDE_LOCATOR_VALIDATION_STATUS="not_executable"
    return 1
  fi
  if ! claude_locator_boundary_status "$canonical_target" "$repo_root" "$invocation_cwd"; then
    CLAUDE_LOCATOR_VALIDATION_SCOPE="target"
    CLAUDE_LOCATOR_VALIDATION_STATUS="$CLAUDE_LOCATOR_BOUNDARY_STATUS"
    return 1
  fi
  if claude_locator_file_world_writable "$canonical_target"; then
    CLAUDE_LOCATOR_VALIDATION_SCOPE="target"
    CLAUDE_LOCATOR_VALIDATION_STATUS="world_writable_file"
    return 1
  else
    writable_status=$?
    if [ "$writable_status" -eq 2 ]; then
      CLAUDE_LOCATOR_VALIDATION_SCOPE="target"
      CLAUDE_LOCATOR_VALIDATION_STATUS="validation_unavailable"
      return 1
    fi
  fi

  CLAUDE_LOCATOR_VALIDATION_SCOPE=""
  CLAUDE_LOCATOR_VALIDATION_STATUS="safe"
  return 0
}

claude_locator_validate_launcher_dependency() {
  local dependency_path="${1:-}"
  local repo_root="${2:-}"
  local invocation_cwd="${3:-}"
  local saved_launch_path="${CLAUDE_LOCATOR_LAUNCH_PATH-}"
  local saved_canonical_target="${CLAUDE_LOCATOR_CANONICAL_TARGET-}"
  local saved_validation_scope="${CLAUDE_LOCATOR_VALIDATION_SCOPE-}"
  local saved_validation_status="${CLAUDE_LOCATOR_VALIDATION_STATUS-}"
  local dependency_valid=false

  CLAUDE_LOCATOR_DEPENDENCY_LAUNCH_PATH=""
  CLAUDE_LOCATOR_DEPENDENCY_CANONICAL_TARGET=""
  CLAUDE_LOCATOR_DEPENDENCY_VALIDATION_SCOPE="launch"
  CLAUDE_LOCATOR_DEPENDENCY_VALIDATION_STATUS="missing"

  if claude_locator_validate_candidate "$dependency_path" "$repo_root" "$invocation_cwd"; then
    dependency_valid=true
  fi
  CLAUDE_LOCATOR_DEPENDENCY_LAUNCH_PATH="$CLAUDE_LOCATOR_LAUNCH_PATH"
  CLAUDE_LOCATOR_DEPENDENCY_CANONICAL_TARGET="$CLAUDE_LOCATOR_CANONICAL_TARGET"
  CLAUDE_LOCATOR_DEPENDENCY_VALIDATION_SCOPE="$CLAUDE_LOCATOR_VALIDATION_SCOPE"
  CLAUDE_LOCATOR_DEPENDENCY_VALIDATION_STATUS="$CLAUDE_LOCATOR_VALIDATION_STATUS"

  CLAUDE_LOCATOR_LAUNCH_PATH="$saved_launch_path"
  CLAUDE_LOCATOR_CANONICAL_TARGET="$saved_canonical_target"
  CLAUDE_LOCATOR_VALIDATION_SCOPE="$saved_validation_scope"
  CLAUDE_LOCATOR_VALIDATION_STATUS="$saved_validation_status"

  [ "$dependency_valid" = true ]
}

# claude-review-helper-complete: locator_v6
