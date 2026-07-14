#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "$HOME/claude-runner-test-XXXXXX")"
ARTIFACT_ROOT="$(mktemp -d /tmp/claude-review-discovery-test-XXXXXX)"
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
trap 'rm -rf "$TEST_ROOT" "$ARTIFACT_ROOT"' EXIT
printf 'review artifact\n' > "$ARTIFACT_ROOT/claude-review-artifact.txt"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok: %s\n' "$1"
}

assert_json_status() {
  local output="$1"
  local expected_status="$2"
  local expected_summary="$3"
  local expected_question="${4:-}"

  OUTPUT_JSON="$output" EXPECTED_STATUS="$expected_status" EXPECTED_SUMMARY="$expected_summary" EXPECTED_QUESTION="$expected_question" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["OUTPUT_JSON"])
summary = data.get("summary", "")
question = " ".join(data.get("open_questions", []))
if data.get("status") != os.environ["EXPECTED_STATUS"]:
    print(f"status mismatch: {data!r}", file=sys.stderr)
    sys.exit(1)
if os.environ["EXPECTED_SUMMARY"] not in summary:
    print(f"summary mismatch: {summary!r}", file=sys.stderr)
    sys.exit(1)
if os.environ["EXPECTED_QUESTION"] and os.environ["EXPECTED_QUESTION"] not in question:
    print(f"question mismatch: {question!r}", file=sys.stderr)
    sys.exit(1)
PY
}

assert_doctor_offer() {
  local output="$1"
  local expected="$2"
  OUTPUT_JSON="$output" EXPECTED="$expected" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["OUTPUT_JSON"])
question = "\n".join(data.get("open_questions", []))
offer = "Run /claude-review doctor now?\nReply Y to run diagnostics, or N to stop."
count = question.count(offer)
expected = os.environ["EXPECTED"] == "true"
if expected and count != 1:
    print(f"expected exactly one doctor offer, got {count}: {question!r}", file=sys.stderr)
    sys.exit(1)
if not expected and count != 0:
    print(f"unexpected doctor offer: {question!r}", file=sys.stderr)
    sys.exit(1)
PY
}

write_success_claude() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<'SH'
#!/bin/bash
set -euo pipefail

{
  printf 'executable=%s\n' "$0"
  printf 'call=%s\n' "${1:-none}"
  printf 'cwd=%s\n' "$(pwd -P)"
  printf 'path=%s\n' "$PATH"
  for name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BEARER_TOKEN ANTHROPIC_CONSOLE_API_KEY ANTHROPIC_CONSOLE_AUTH_TOKEN BASH_ENV ENV; do
    if /usr/bin/env | /usr/bin/grep -q "^${name}="; then printf '%s=present\n' "$name"; else printf '%s=absent\n' "$name"; fi
  done
  printf 'preserved=%s\n' "${PRESERVED_SENTINEL:-missing}"
  for arg in "$@"; do printf 'arg=[%s]\n' "$arg"; done
} >> "${FAKE_CLAUDE_LOG:?}"

if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
  printf 'Claude Code fake\n'
  exit 0
fi
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf '{"loggedIn":true,"apiProvider":"firstParty"}\n'
  exit 0
fi
if [ "${1:-}" = "-p" ]; then
  if [[ "${2:-}" == *"Codex Claude skill preflight probe"* ]]; then
    printf '{"ok":true}\n'
  else
    printf '{"status":"clean","mode":"code","summary":"ok","findings":[],"open_questions":[]}\n'
  fi
  exit 0
fi
exit 2
SH
  chmod 755 "$target"
}

run_runner() {
  local skill_root="$1"
  local repo_root="$2"
  local invocation_cwd="$3"
  local home_value="$4"
  local path_value="$5"
  local fake_log="$6"
  shift 6

  (
    cd "$invocation_cwd"
    HOME="$home_value" \
    PATH="$path_value" \
    FAKE_CLAUDE_LOG="$fake_log" \
    PRESERVED_SENTINEL="runner-preserved" \
    ANTHROPIC_API_KEY="api-secret" \
    ANTHROPIC_AUTH_TOKEN="auth-secret" \
    ANTHROPIC_BEARER_TOKEN="bearer-secret" \
    ANTHROPIC_CONSOLE_API_KEY="console-secret" \
    ANTHROPIC_CONSOLE_AUTH_TOKEN="console-auth-secret" \
    ENV="$TEST_ROOT/never-source-env" \
    /bin/bash "$skill_root/scripts/run-review.sh" \
      --mode code \
      --artifact-file "$ARTIFACT_ROOT/claude-review-artifact.txt" \
      --base-prompt "$skill_root/prompts/code-review.base.md" \
      --schema-file "$skill_root/schemas/review-output.json" \
      --repo-root "$repo_root" \
      --branch test \
      --base-branch main \
      "$@"
  )
}

run_runner_without_home() {
  local skill_root="$1"
  local repo_root="$2"
  local invocation_cwd="$3"
  local path_value="$4"
  local fake_log="$5"

  (
    cd "$invocation_cwd"
    /usr/bin/env -u HOME \
      PATH="$path_value" \
      FAKE_CLAUDE_LOG="$fake_log" \
      PRESERVED_SENTINEL="runner-preserved" \
      /bin/bash "$skill_root/scripts/run-review.sh" \
        --mode code \
        --artifact-file "$ARTIFACT_ROOT/claude-review-artifact.txt" \
        --base-prompt "$skill_root/prompts/code-review.base.md" \
        --schema-file "$skill_root/schemas/review-output.json" \
        --repo-root "$repo_root" \
        --branch test \
        --base-branch main
  )
}

copy_fixture_skill() {
  local destination="$1"
  mkdir -p "$destination/scripts" "$destination/prompts" "$destination/schemas"
  cp "$REPO_ROOT"/scripts/*.sh "$destination/scripts/"
  cp "$REPO_ROOT"/prompts/*.md "$destination/prompts/"
  cp "$REPO_ROOT"/schemas/*.json "$destination/schemas/"
  chmod 755 "$destination"/scripts/*.sh
}

patch_homebrew_path() {
  local skill_root="$1"
  local replacement="$2"
  local original=""

  case "${OSTYPE:-}" in
    darwin*) original="/opt/homebrew/bin/claude" ;;
    linux*)
      case "${MACHTYPE:-}" in
        x86_64-*) original="/home/linuxbrew/.linuxbrew/bin/claude" ;;
      esac
      ;;
  esac
  [ -n "$original" ] || return 1
  python3 - "$skill_root/scripts/claude-locator.sh" "$original" "$replacement" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace(sys.argv[2], sys.argv[3]))
PY
}

disable_homebrew_paths() {
  local skill_root="$1"
  local replacement="$2"

  python3 - "$skill_root/scripts/claude-locator.sh" "$replacement" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
for original in (
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    "/home/linuxbrew/.linuxbrew/bin/claude",
):
    text = text.replace(original, sys.argv[2])
path.write_text(text)
PY
}

# Official native fallback reaches preflight/review with restricted PATH.
native_home="$TEST_ROOT/native-home"
native_log="$TEST_ROOT/native.log"
write_success_claude "$native_home/.local/bin/claude"
native_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$native_home" "$SYSTEM_PATH" "$native_log")"
assert_json_status "$native_output" clean ok
grep -Fq "executable=$native_home/.local/bin/claude" "$native_log" || fail "native launch path not executed"
[ "$(grep '^call=' "$native_log" | wc -l | tr -d ' ')" = "4" ] || fail "runner did not execute version/auth/preflight/review"
grep -q '^ANTHROPIC_API_KEY=absent$' "$native_log" || fail "runner API credential scrub"
grep -q '^ENV=absent$' "$native_log" || fail "runner ENV scrub"
[ "$(grep '^path=' "$native_log" | sort -u)" = "path=$SYSTEM_PATH" ] || fail "runner PATH changed"
[ "$(grep '^cwd=' "$native_log" | sort -u | wc -l | tr -d ' ')" = "1" ] || fail "runner CWD drifted across call sites"
grep -Eq '^cwd=/(private/)?tmp/claude-review-runtime-' "$native_log" || fail "runner did not use isolated runtime CWD"
grep -q '^arg=\[\]$' "$native_log" || fail "runner lost empty --tools argv"
pass "runner native fallback and direct-runtime call-site parity"

# PATH remains authoritative over a healthy native fallback.
path_root="$TEST_ROOT/path-root"
path_log="$TEST_ROOT/path-precedence.log"
write_success_claude "$path_root/bin/claude"
path_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$native_home" "$path_root/bin:$SYSTEM_PATH" "$path_log")"
assert_json_status "$path_output" clean ok
grep -Fq "executable=$path_root/bin/claude" "$path_log" || fail "PATH candidate did not win"
if grep -Fq "executable=$native_home/.local/bin/claude" "$path_log"; then fail "native ran after PATH selection"; fi
pass "runner PATH precedence"

relative_parent="$TEST_ROOT/relative-parent"
relative_work="$relative_parent/work"
relative_bin="$relative_parent/bin"
relative_log="$TEST_ROOT/relative.log"
mkdir -p "$relative_work"
write_success_claude "$relative_bin/claude"
relative_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$relative_work" "$native_home" "../bin:$SYSTEM_PATH" "$relative_log")"
assert_json_status "$relative_output" clean ok
grep -Fq "executable=$relative_bin/claude" "$relative_log" || fail "relative PATH launch was not normalized to absolute"
pass "runner physically normalizes relative PATH before isolated CWD execution"

relative_dependency_home="$TEST_ROOT/relative-dependency-home"
relative_dependency_work="$TEST_ROOT/relative-dependency/work"
relative_dependency_tools="$TEST_ROOT/relative-dependency/runtime-node-tools-$PPID"
relative_dependency_log="$TEST_ROOT/relative-dependency.log"
mkdir -p "$relative_dependency_home/.local/bin" "$relative_dependency_work" "$relative_dependency_tools"
printf '#!/usr/bin/env runtime-node\nexit 0\n' > "$relative_dependency_home/.local/bin/claude"
cat > "$relative_dependency_tools/runtime-node" <<'SH'
#!/bin/bash
printf 'unexpected execution\n' > "${FAKE_CLAUDE_LOG:?}"
exec /bin/bash "$@"
SH
chmod 755 "$relative_dependency_home/.local/bin/claude" "$relative_dependency_tools/runtime-node"
relative_dependency_output="$(run_runner \
  "$REPO_ROOT" \
  "$REPO_ROOT" \
  "$relative_dependency_work" \
  "$relative_dependency_home" \
  "../${relative_dependency_tools##*/}:$SYSTEM_PATH" \
  "$relative_dependency_log")"
assert_json_status "$relative_dependency_output" blocked "launcher interpreter is unavailable from Codex's inherited PATH"
[ ! -e "$relative_dependency_log" ] || fail "relative interpreter resolved from invocation CWD instead of runtime CWD"
pass "runner resolves env shebang dependencies from the private runtime CWD"

# A stale non-resolvable PATH entry blocks fixed fallbacks, while type -P still
# selects a later executable under normal Bash semantics.
stale_path="$TEST_ROOT/stale-path"
mkdir -p "$stale_path"
printf '#!/bin/bash\nexit 99\n' > "$stale_path/claude"
chmod 644 "$stale_path/claude"
stale_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$native_home" "$stale_path:$SYSTEM_PATH" "$TEST_ROOT/stale-path.log")"
assert_json_status "$stale_output" blocked "not executable" "$stale_path/claude"
assert_doctor_offer "$stale_output" true
[ ! -e "$TEST_ROOT/stale-path.log" ] || fail "non-executable PATH entry or native fallback executed"

later_root="$TEST_ROOT/later-path"
later_log="$TEST_ROOT/later.log"
write_success_claude "$later_root/claude"
later_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$native_home" "$stale_path:$later_root:$SYSTEM_PATH" "$later_log")"
assert_json_status "$later_output" clean ok
grep -Fq "executable=$later_root/claude" "$later_log" || fail "type -P did not choose later executable"
pass "runner stale PATH classification and later-executable resolution"

broken_path="$TEST_ROOT/broken-path"
broken_log="$TEST_ROOT/broken.log"
mkdir -p "$broken_path"
cat > "$broken_path/claude" <<'SH'
#!/bin/bash
printf '%s\n' "$0" > "${FAKE_CLAUDE_LOG:?}"
exit 9
SH
chmod 755 "$broken_path/claude"
broken_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$native_home" "$broken_path:$SYSTEM_PATH" "$broken_log")"
assert_json_status "$broken_output" blocked "could not run with Codex's inherited environment" "runtime executable"
[ "$(cat "$broken_log")" = "$broken_path/claude" ] || fail "broken PATH candidate launch identity"
pass "runtime-broken PATH candidate remains authoritative over native fallback"

missing_home="$TEST_ROOT/missing-home"
mkdir -p "$missing_home"
missing_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$missing_home" "$SYSTEM_PATH" "$TEST_ROOT/missing.log")"
assert_json_status "$missing_output" blocked "not found in PATH or any checked official/default install location" "does not prove Claude is uninstalled"
assert_doctor_offer "$missing_output" true
pass "runner missing diagnosis includes the exact doctor opt-in once"

unset_home_skill="$TEST_ROOT/unset-home-skill"
copy_fixture_skill "$unset_home_skill"
disable_homebrew_paths "$unset_home_skill" "$TEST_ROOT/disabled-homebrew/claude"
unset_home_output="$(run_runner_without_home \
  "$unset_home_skill" \
  "$REPO_ROOT" \
  "$REPO_ROOT" \
  "$SYSTEM_PATH" \
  "$TEST_ROOT/unset-home.log")"
assert_json_status "$unset_home_output" blocked "not found in PATH or any checked official/default install location"
assert_doctor_offer "$unset_home_output" true
[ ! -e "$TEST_ROOT/unset-home.log" ] || fail "unset-HOME case executed Claude"
pass "runner returns structured recovery when HOME is unset"

# Homebrew discovery, native precedence, and dangling-only deferral.
brew_skill="$TEST_ROOT/brew-skill"
brew_path="$TEST_ROOT/default brew=prefix/bin/claude"
copy_fixture_skill "$brew_skill"
if patch_homebrew_path "$brew_skill" "$brew_path"; then
  write_success_claude "$brew_path"
  brew_home="$TEST_ROOT/brew-home"
  mkdir -p "$brew_home"
  brew_log="$TEST_ROOT/brew.log"
  brew_output="$(run_runner "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$brew_home" "$SYSTEM_PATH" "$brew_log")"
  assert_json_status "$brew_output" clean ok
  grep -Fq "executable=$brew_path" "$brew_log" || fail "Homebrew fallback not executed"

  dangling_home="$TEST_ROOT/dangling-home"
  mkdir -p "$dangling_home/.local/bin"
  ln -s "$dangling_home/missing" "$dangling_home/.local/bin/claude"
  dangling_log="$TEST_ROOT/dangling-brew.log"
  dangling_output="$(run_runner "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$dangling_home" "$SYSTEM_PATH" "$dangling_log")"
  assert_json_status "$dangling_output" clean ok
  grep -Fq "executable=$brew_path" "$dangling_log" || fail "dangling native did not defer"

  loop_home="$TEST_ROOT/loop-native-home"
  loop_log="$TEST_ROOT/loop-native.log"
  mkdir -p "$loop_home/.local/bin"
  ln -s "$loop_home/.local/bin/claude-loop" "$loop_home/.local/bin/claude"
  ln -s "$loop_home/.local/bin/claude" "$loop_home/.local/bin/claude-loop"
  loop_output="$(run_runner "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$loop_home" "$SYSTEM_PATH" "$loop_log")"
  assert_json_status "$loop_output" blocked "unsafe path" "target:validation_unavailable"
  [ ! -e "$loop_log" ] || fail "symlink loop deferred to Homebrew"

  inaccessible_home="$TEST_ROOT/inaccessible-native-home"
  inaccessible_log="$TEST_ROOT/inaccessible-native.log"
  mkdir -p "$inaccessible_home/.local/bin" "$inaccessible_home/blocked"
  ln -s "$inaccessible_home/blocked/claude" "$inaccessible_home/.local/bin/claude"
  chmod 000 "$inaccessible_home/blocked"
  inaccessible_output="$(run_runner "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$inaccessible_home" "$SYSTEM_PATH" "$inaccessible_log")"
  chmod 700 "$inaccessible_home/blocked"
  assert_json_status "$inaccessible_output" blocked "unsafe path" "target:validation_unavailable"
  [ ! -e "$inaccessible_log" ] || fail "inaccessible symlink target deferred to Homebrew"

  invalid_home="$TEST_ROOT/invalid-native-home"
  write_success_claude "$invalid_home/.local/bin/claude"
  chmod 644 "$invalid_home/.local/bin/claude"
  invalid_log="$TEST_ROOT/invalid-native.log"
  invalid_output="$(run_runner "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$invalid_home" "$SYSTEM_PATH" "$invalid_log")"
  assert_json_status "$invalid_output" blocked "not executable" "$invalid_home/.local/bin/claude"
  [ ! -e "$invalid_log" ] || fail "invalid native or Homebrew candidate executed"

  unsafe_repo="$TEST_ROOT/brew-reviewed-repo"
  unsafe_home="$TEST_ROOT/unsafe-native-home"
  unsafe_brew_log="$TEST_ROOT/unsafe-native-brew.log"
  write_success_claude "$unsafe_repo/bin/claude-target"
  mkdir -p "$unsafe_home/.local/bin"
  ln -s "$unsafe_repo/bin/claude-target" "$unsafe_home/.local/bin/claude"
  unsafe_brew_output="$(run_runner "$brew_skill" "$unsafe_repo" "$REPO_ROOT" "$unsafe_home" "$SYSTEM_PATH" "$unsafe_brew_log")"
  assert_json_status "$unsafe_brew_output" blocked "unsafe path" "target:repository_path"
  [ ! -e "$unsafe_brew_log" ] || fail "unsafe native silently switched to Homebrew"

  all_dangling_home="$TEST_ROOT/all-dangling-home"
  mkdir -p "$all_dangling_home/.local/bin"
  ln -s "$all_dangling_home/missing-native" "$all_dangling_home/.local/bin/claude"
  rm -f "$brew_path"
  ln -s "$TEST_ROOT/missing-brew" "$brew_path"
  all_dangling_output="$(run_runner "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$all_dangling_home" "$SYSTEM_PATH" "$TEST_ROOT/all-dangling.log")"
  assert_json_status "$all_dangling_output" blocked "dangling symlink" "$all_dangling_home/.local/bin/claude"
  pass "runner Homebrew fallback and dangling-only deferral"
else
  pass "runner Homebrew integration skipped on unsupported test architecture"
fi

# Every moved trust rejection is fail-closed and candidate non-executing.
world_root="$TEST_ROOT/world-writable"
world_log="$TEST_ROOT/world.log"
write_success_claude "$world_root/bin/claude"
chmod 777 "$world_root"
world_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$native_home" "$world_root/bin:$SYSTEM_PATH" "$world_log")"
assert_json_status "$world_output" blocked "unsafe path" "launch:world_writable_parent"
[ ! -e "$world_log" ] || fail "world-writable candidate executed"

world_file_root="$TEST_ROOT/world-writable-file"
world_file_log="$TEST_ROOT/world-file.log"
write_success_claude "$world_file_root/bin/claude"
chmod 777 "$world_file_root/bin/claude"
world_file_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$native_home" "$world_file_root/bin:$SYSTEM_PATH" "$world_file_log")"
assert_json_status "$world_file_output" blocked "unsafe path" "target:world_writable_file"
[ ! -e "$world_file_log" ] || fail "world-writable executable file ran"

invocation_root="$TEST_ROOT/invocation"
invocation_log="$TEST_ROOT/invocation.log"
write_success_claude "$invocation_root/bin/claude"
invocation_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$invocation_root" "$native_home" "$invocation_root/bin:$SYSTEM_PATH" "$invocation_log")"
assert_json_status "$invocation_output" blocked "unsafe path" "launch:invocation_cwd_path"
[ ! -e "$invocation_log" ] || fail "invocation-CWD candidate executed"

not_regular_root="$TEST_ROOT/not-regular"
mkdir -p "$not_regular_root/claude"
not_regular_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$native_home" "$not_regular_root:$SYSTEM_PATH" "$TEST_ROOT/not-regular.log")"
assert_json_status "$not_regular_output" blocked "not a regular file" "$not_regular_root/claude"
[ ! -e "$TEST_ROOT/not-regular.log" ] || fail "non-regular candidate executed"

reviewed_repo="$TEST_ROOT/reviewed-repo"
target_log="$TEST_ROOT/target.log"
write_success_claude "$reviewed_repo/bin/claude-target"
safe_link_root="$TEST_ROOT/safe-link"
mkdir -p "$safe_link_root/bin"
ln -s "$reviewed_repo/bin/claude-target" "$safe_link_root/bin/claude"
target_output="$(run_runner "$REPO_ROOT" "$reviewed_repo" "$REPO_ROOT" "$native_home" "$safe_link_root/bin:$SYSTEM_PATH" "$target_log")"
assert_json_status "$target_output" blocked "unsafe path" "target:repository_path"
[ ! -e "$target_log" ] || fail "repository-target candidate executed"

chain_root="$TEST_ROOT/chain-root"
chain_world="$TEST_ROOT/chain-world"
chain_log="$TEST_ROOT/chain.log"
write_success_claude "$chain_root/target/claude"
mkdir -p "$chain_root/bin" "$chain_world"
ln -s "$chain_root/target/claude" "$chain_world/claude-hop"
ln -s "$chain_world/claude-hop" "$chain_root/bin/claude"
chmod 777 "$chain_world"
chain_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$native_home" "$chain_root/bin:$SYSTEM_PATH" "$chain_log")"
assert_json_status "$chain_output" blocked "unsafe path" "target:world_writable_parent"
[ ! -e "$chain_log" ] || fail "intermediate-chain candidate executed"

validation_skill="$TEST_ROOT/validation-skill"
validation_bin="$TEST_ROOT/validation-bin"
validation_log="$TEST_ROOT/validation.log"
copy_fixture_skill "$validation_skill"
write_success_claude "$validation_bin/claude"
python3 - "$validation_skill/scripts/claude-locator.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
marker = "# claude-review-helper-complete: locator_v1"
replacement = "claude_locator_resolve_trusted_utility() { return 1; }\n\n" + marker
path.write_text(path.read_text().replace(marker, replacement))
PY
validation_output="$(run_runner "$validation_skill" "$REPO_ROOT" "$REPO_ROOT" "$native_home" "$validation_bin:$SYSTEM_PATH" "$validation_log")"
assert_json_status "$validation_output" blocked "unsafe path" "launch:validation_unavailable"
[ ! -e "$validation_log" ] || fail "unvalidated runner candidate executed"
pass "runner shared trust rejection, symlink-chain, and validator-unavailable fixtures under set -e"

# Deterministic launcher dependencies: exact env/absolute forms classify, while
# native/script exit 127 remains generic.
dependency_home="$TEST_ROOT/dependency-home"
mkdir -p "$dependency_home/.local/bin"
cat > "$dependency_home/.local/bin/claude" <<'SH'
#!/usr/bin/env definitely-missing-claude-interpreter
SH
chmod 755 "$dependency_home/.local/bin/claude"
dependency_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$dependency_home" "$SYSTEM_PATH" "$TEST_ROOT/dependency.log")"
assert_json_status "$dependency_output" blocked "launcher interpreter is unavailable" "definitely-missing-claude-interpreter"
assert_doctor_offer "$dependency_output" true
[ ! -e "$TEST_ROOT/dependency.log" ] || fail "missing-dependency launcher executed"

unsupported_home="$TEST_ROOT/unsupported-dependency-home"
unsupported_log="$TEST_ROOT/unsupported-dependency.log"
mkdir -p "$unsupported_home/.local/bin"
cat > "$unsupported_home/.local/bin/claude" <<'SH'
#!/usr/bin/env -S fake-node --unsafe-flag
exit 99
SH
chmod 755 "$unsupported_home/.local/bin/claude"
unsupported_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$unsupported_home" "$SYSTEM_PATH" "$unsupported_log")"
assert_json_status "$unsupported_output" blocked "unsupported shebang interpreter syntax" "exact '#!/usr/bin/env NAME'"
assert_doctor_offer "$unsupported_output" true
[ ! -e "$unsupported_log" ] || fail "unsupported-shebang launcher executed"

absolute_home="$TEST_ROOT/absolute-dependency-home"
mkdir -p "$absolute_home/.local/bin"
cat > "$absolute_home/.local/bin/claude" <<'SH'
#!/definitely/missing/claude-interpreter
SH
chmod 755 "$absolute_home/.local/bin/claude"
absolute_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$absolute_home" "$SYSTEM_PATH" "$TEST_ROOT/absolute.log")"
assert_json_status "$absolute_output" blocked "launcher interpreter is unavailable" "claude-interpreter"

unsafe_dependency_home="$TEST_ROOT/unsafe-dependency-home"
unsafe_dependency_invocation="$TEST_ROOT/unsafe-dependency-invocation"
unsafe_dependency_log="$TEST_ROOT/unsafe-dependency.log"
alternate_env_root="$TEST_ROOT/alternate-env"
mkdir -p "$unsafe_dependency_home/.local/bin" "$unsafe_dependency_invocation/bin" "$alternate_env_root"
ln -s /usr/bin/env "$alternate_env_root/env"
cp "$native_home/.local/bin/claude" "$unsafe_dependency_home/.local/bin/claude"
python3 - "$unsafe_dependency_home/.local/bin/claude" "$alternate_env_root/env" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace("#!/bin/bash", f"#!{sys.argv[2]} fake-node", 1))
PY
ln -s /bin/bash "$unsafe_dependency_invocation/bin/fake-node"
unsafe_dependency_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$unsafe_dependency_invocation" "$unsafe_dependency_home" "$unsafe_dependency_invocation/bin:$SYSTEM_PATH" "$unsafe_dependency_log")"
assert_json_status "$unsafe_dependency_output" blocked "launcher interpreter resolves to an unsafe path" "launch:invocation_cwd_path"
assert_doctor_offer "$unsafe_dependency_output" true
[ ! -e "$unsafe_dependency_log" ] || fail "unsafe launcher interpreter executed"

nested_home="$TEST_ROOT/nested-dependency-home"
nested_tools="$TEST_ROOT/nested-tools"
nested_invocation="$TEST_ROOT/nested-invocation"
nested_log="$TEST_ROOT/nested-executed.log"
mkdir -p "$nested_home/.local/bin" "$nested_tools" "$nested_invocation/bin"
cat > "$nested_invocation/bin/fake-python" <<SH
#!/bin/bash
printf executed > "$nested_log"
SH
cat > "$nested_tools/fake-node" <<SH
#!$nested_invocation/bin/fake-python
exit 0
SH
cat > "$nested_home/.local/bin/claude" <<'SH'
#!/usr/bin/env fake-node
exit 0
SH
chmod 755 "$nested_invocation/bin/fake-python" "$nested_tools/fake-node" "$nested_home/.local/bin/claude"
nested_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$nested_invocation" "$nested_home" "$nested_tools:$SYSTEM_PATH" "$TEST_ROOT/nested-claude.log")"
assert_json_status "$nested_output" blocked "launcher interpreter resolves to an unsafe path" "fake-python"
[ ! -e "$nested_log" ] || fail "nested unsafe interpreter executed"

unreadable_home="$TEST_ROOT/unreadable-home"
unreadable_log="$TEST_ROOT/unreadable.log"
write_success_claude "$unreadable_home/.local/bin/claude"
chmod 111 "$unreadable_home/.local/bin/claude"
unreadable_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$unreadable_home" "$SYSTEM_PATH" "$unreadable_log")"
assert_json_status "$unreadable_output" blocked "cannot be read safely" "$unreadable_home/.local/bin/claude"
assert_doctor_offer "$unreadable_output" true
[ ! -e "$unreadable_log" ] || fail "unreadable launcher executed"

exit_home="$TEST_ROOT/exit-127-home"
mkdir -p "$exit_home/.local/bin"
cat > "$exit_home/.local/bin/claude" <<'SH'
#!/bin/bash
exit 127
SH
chmod 755 "$exit_home/.local/bin/claude"
exit_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$exit_home" "$SYSTEM_PATH" "$TEST_ROOT/exit.log")"
assert_json_status "$exit_output" blocked "could not run with Codex's inherited environment" "runtime executable"
if printf '%s' "$exit_output" | grep -q 'launcher interpreter'; then fail "exit 127 misclassified as dependency"; fi
pass "runner deterministic launcher-dependency boundary"

# A launcher interpreter present in inherited PATH works without PATH rewriting.
present_home="$TEST_ROOT/present-dependency-home"
tool_root="$TEST_ROOT/interpreter-tools"
mkdir -p "$present_home/.local/bin" "$tool_root"
cp "$native_home/.local/bin/claude" "$present_home/.local/bin/claude"
python3 - "$present_home/.local/bin/claude" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace("#!/bin/bash", "#!/usr/bin/env fake-node", 1))
PY
ln -s /bin/bash "$tool_root/fake-node"
present_log="$TEST_ROOT/present.log"
present_output="$(run_runner "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$present_home" "$tool_root:$SYSTEM_PATH" "$present_log")"
assert_json_status "$present_output" clean ok
[ "$(grep '^path=' "$present_log" | sort -u)" = "path=$tool_root:$SYSTEM_PATH" ] || fail "interpreter case mutated PATH"
pass "runner inherited interpreter succeeds"

# Helper-integrity bootstrap classifications are schema-valid and never offer a
# doctor that may be broken by the same partial install.
run_bootstrap_case() {
  local case_name="$1"
  local tamper="$2"
  local component="$3"
  local skill="$TEST_ROOT/bootstrap-$case_name"
  local output=""
  local candidate_log="$TEST_ROOT/bootstrap-$case_name.log"

  copy_fixture_skill "$skill"
  case "$tamper" in
    missing_locator) rm -f "$skill/scripts/claude-locator.sh" ;;
    missing_runtime) rm -f "$skill/scripts/claude-runtime.sh" ;;
    invalid_locator) printf 'if then\n# claude-review-helper-complete: locator_v1\n' > "$skill/scripts/claude-locator.sh" ;;
    empty_runtime) : > "$skill/scripts/claude-runtime.sh" ;;
    no_marker_runtime) printf 'claude_runtime_build_command() { :; }\nclaude_runtime_check_launcher_dependency() { :; }\nclaude_runtime_scrub_environment() { :; }\n' > "$skill/scripts/claude-runtime.sh" ;;
    missing_symbol_locator) sed 's/^claude_locator_validate_candidate()/claude_locator_validate_candidate_missing()/' "$REPO_ROOT/scripts/claude-locator.sh" > "$skill/scripts/claude-locator.sh" ;;
  esac
  output="$(run_runner "$skill" "$REPO_ROOT" "$REPO_ROOT" "$HOME" "$path_root/bin:$SYSTEM_PATH" "$candidate_log" 2>&1)"
  assert_json_status "$output" blocked "installation is incomplete"
  printf '%s' "$output" | grep -Fq "$component" || fail "$case_name omitted safe helper basename"
  assert_doctor_offer "$output" false
  if printf '%s' "$output" | grep -Eq 'syntax error|unexpected token|Run /claude-review doctor'; then
    fail "$case_name leaked source output or offered broken doctor"
  fi
  [ ! -e "$candidate_log" ] || fail "$case_name executed Claude"
  pass "runner bootstrap $case_name"
}

run_bootstrap_case missing-locator missing_locator claude-locator.sh
run_bootstrap_case missing-runtime missing_runtime claude-runtime.sh
run_bootstrap_case invalid-locator invalid_locator claude-locator.sh
run_bootstrap_case empty-runtime empty_runtime claude-runtime.sh
run_bootstrap_case no-marker-runtime no_marker_runtime claude-runtime.sh
run_bootstrap_case missing-symbol-locator missing_symbol_locator claude-locator.sh

pass "runner discovery and runtime diagnostics"
