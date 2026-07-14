#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "$HOME/claude-doctor-test-XXXXXX")"
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok: %s\n' "$1"
}

assert_line() {
  local output="$1"
  local expected="$2"
  local label="$3"
  printf '%s\n' "$output" | grep -Fqx "$expected" || fail "$label (missing: $expected)"
}

assert_contains() {
  local output="$1"
  local expected="$2"
  local label="$3"
  printf '%s\n' "$output" | grep -Fq "$expected" || fail "$label (missing: $expected)"
}

assert_not_contains() {
  local output="$1"
  local rejected="$2"
  local label="$3"
  if printf '%s\n' "$output" | grep -Fq "$rejected"; then
    fail "$label (unexpected: $rejected)"
  fi
}

write_fake_claude() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<'SH'
#!/bin/bash
set -euo pipefail

{
  printf 'call=%s\n' "${1:-none}"
  printf 'cwd=%s\n' "$(pwd -P)"
  printf 'path=%s\n' "$PATH"
  for name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BEARER_TOKEN ANTHROPIC_CONSOLE_API_KEY ANTHROPIC_CONSOLE_AUTH_TOKEN BASH_ENV ENV; do
    if /usr/bin/env | /usr/bin/grep -q "^${name}="; then printf '%s=present\n' "$name"; else printf '%s=absent\n' "$name"; fi
  done
  printf 'preserved=%s\n' "${PRESERVED_SENTINEL:-missing}"
  for arg in "$@"; do printf 'arg=[%s]\n' "$arg"; done
} >> "${FAKE_CLAUDE_LOG:?}"

if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
  if [ "${FAKE_CLAUDE_HANG_STAGE:-}" = "version" ]; then
    while :; do :; done
  fi
  printf '2.test.0 (Claude Code fake)\n'
  exit "${FAKE_CLAUDE_VERSION_EXIT:-0}"
fi
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  if [ "${FAKE_CLAUDE_HANG_STAGE:-}" = "auth" ]; then
    while :; do :; done
  fi
  printf '{"loggedIn":true,"apiProvider":"firstParty","accessToken":"doctor-auth-secret"}\n'
  exit 0
fi
if [ "${1:-}" = "-p" ]; then
  printf 'doctor-probe-secret-stdout\n'
  printf 'doctor-probe-secret-stderr\n' >&2
  exit 0
fi
exit 2
SH
  chmod 755 "$target"
}

run_doctor() {
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
    PRESERVED_SENTINEL="preserved-value" \
    ANTHROPIC_API_KEY="api-secret" \
    ANTHROPIC_AUTH_TOKEN="auth-secret" \
    ANTHROPIC_BEARER_TOKEN="bearer-secret" \
    ANTHROPIC_CONSOLE_API_KEY="console-secret" \
    ANTHROPIC_CONSOLE_AUTH_TOKEN="console-auth-secret" \
    BASH_ENV= \
    ENV= \
    /bin/bash --noprofile --norc "$skill_root/scripts/claude-doctor.sh" \
      --repo-root "$repo_root" \
      --skill-root "$skill_root" \
      --config-file "$repo_root/.codex/claude/config.env" \
      --probe-timeout 5 \
      "$@"
  )
}

run_doctor_without_home() {
  local skill_root="$1"
  local repo_root="$2"
  local invocation_cwd="$3"
  local path_value="$4"
  local fake_log="$5"
  shift 5

  (
    cd "$invocation_cwd"
    /usr/bin/env -u HOME \
      PATH="$path_value" \
      FAKE_CLAUDE_LOG="$fake_log" \
      PRESERVED_SENTINEL="preserved-value" \
      BASH_ENV= ENV= /bin/bash --noprofile --norc "$skill_root/scripts/claude-doctor.sh" \
        --repo-root "$repo_root" \
        --skill-root "$skill_root" \
        --config-file "$repo_root/.codex/claude/config.env" \
        --probe-timeout 5 \
        "$@"
  )
}

copy_fixture_skill() {
  local destination="$1"
  mkdir -p "$destination/scripts"
  cp "$REPO_ROOT"/scripts/*.sh "$destination/scripts/"
  chmod 755 "$destination"/scripts/*.sh
}

patch_homebrew_path() {
  local skill_root="$1"
  local replacement="$2"
  local original=""

  case "${OSTYPE:-}" in
    darwin*)
      original="/opt/homebrew/bin/claude"
      ;;
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

# PATH discovery, direct-runtime parity, redaction, exact argv, and equals paths.
path_root="$TEST_ROOT/path install=one"
path_bin="$path_root/bin"
path_log="$TEST_ROOT/path.log"
passwd_home="$(python3 - <<'PY'
import os
import pwd

print(pwd.getpwuid(os.getuid()).pw_dir)
PY
)"
write_fake_claude "$path_bin/claude"
path_value="$path_bin:$SYSTEM_PATH"
basic_output="$({
  CLAUDE_CONFIG_DIR="doctor-config-secret" \
  HTTP_PROXY="http://doctor-proxy-secret" \
  HTTPS_PROXY="https://doctor-proxy-secret" \
  NO_PROXY="doctor-no-proxy-secret" \
  NODE_EXTRA_CA_CERTS="doctor-ca-secret" \
  CLAUDE_CODE_CERT_STORE="doctor-store-secret" \
  CLAUDE_CODE_CLIENT_CERT="doctor-cert-secret" \
  CLAUDE_CODE_CLIENT_KEY="doctor-key-secret" \
  CLAUDE_CODE_CLIENT_KEY_PASSPHRASE="doctor-passphrase-secret" \
  run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$passwd_home" "$path_value" "$path_log"
})"

assert_line "$basic_output" "CLAUDE_REVIEW_DOCTOR" "doctor header"
assert_line "$basic_output" "doctor_status=ok" "doctor status"
assert_line "$basic_output" "claude_discovery=path" "PATH discovery"
assert_line "$basic_output" "claude_path_status=available" "PATH status"
assert_line "$basic_output" "claude_bin=$path_bin/claude" "absolute launch path"
assert_line "$basic_output" "claude_target=$path_bin/claude" "canonical target"
assert_line "$basic_output" "claude_trust_scope=none" "safe trust scope"
assert_line "$basic_output" "claude_trust_reason=none" "safe trust reason"
assert_line "$basic_output" "claude_runtime_contract=direct_inherited_path_v1" "runtime contract"
assert_line "$basic_output" "claude_version=2.test.0 (Claude Code fake)" "version"
assert_line "$basic_output" "claude_auth_logged_in=True" "auth state"
assert_line "$basic_output" "claude_auth_provider=firstParty" "auth provider"
assert_line "$basic_output" "claude_auth_context=subscription_only_credentials_scrubbed" "auth context"
assert_line "$basic_output" "python_runtime_status=safe" "trusted Python status"
assert_line "$basic_output" "python_validation_scope=none" "trusted Python scope"
assert_line "$basic_output" "python_validation_reason=none" "trusted Python reason"
assert_line "$basic_output" "plain_print_probe_status=completed" "plain probe"
assert_line "$basic_output" "safe_mode_print_probe_status=completed" "safe probe"
assert_line "$basic_output" "runner_safe_mode=ok" "runner safe-mode contract"
assert_line "$basic_output" "runner_strict_mcp_config=ok" "runner strict-MCP contract"
assert_line "$basic_output" "router_present=ok" "router presence"
assert_line "$basic_output" "update_check=skipped" "update-check default"
assert_line "$basic_output" "inherited_home_status=matches_passwd" "matching HOME"
assert_line "$basic_output" "login_profile_loaded=false" "profile contract"
for inherited_name in CLAUDE_CONFIG_DIR HTTP_PROXY HTTPS_PROXY NO_PROXY NODE_EXTRA_CA_CERTS CLAUDE_CODE_CERT_STORE CLAUDE_CODE_CLIENT_CERT CLAUDE_CODE_CLIENT_KEY CLAUDE_CODE_CLIENT_KEY_PASSPHRASE; do
  assert_line "$basic_output" "inherited_env_${inherited_name}=present" "presence-only $inherited_name"
done
for secret in doctor-auth-secret doctor-probe-secret-stdout doctor-probe-secret-stderr doctor-config-secret doctor-proxy-secret doctor-ca-secret doctor-store-secret doctor-cert-secret doctor-key-secret doctor-passphrase-secret api-secret auth-secret bearer-secret console-secret; do
  assert_not_contains "$basic_output" "$secret" "redaction for $secret"
done
assert_not_contains "$basic_output" "stdout_head" "raw stdout excerpt removed"
assert_not_contains "$basic_output" "stderr_head" "raw stderr excerpt removed"
for scrubbed_name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BEARER_TOKEN ANTHROPIC_CONSOLE_API_KEY ANTHROPIC_CONSOLE_AUTH_TOKEN; do
  grep -q "^${scrubbed_name}=absent$" "$path_log" || fail "doctor version/auth/probes did not scrub $scrubbed_name"
done
grep -q '^BASH_ENV=absent$' "$path_log" || fail "doctor runtime scrubs BASH_ENV"
grep -q '^ENV=absent$' "$path_log" || fail "doctor runtime scrubs ENV"
[ "$(grep '^path=' "$path_log" | sort -u)" = "path=$path_value" ] || fail "doctor preserves PATH byte-for-byte"
[ "$(grep '^cwd=' "$path_log" | sort -u | wc -l | tr -d ' ')" = "1" ] || fail "doctor uses one isolated runtime CWD"
grep -Eq '^cwd=/(private/)?tmp/claude-review-runtime-' "$path_log" || fail "doctor CWD uses isolated runtime directory"
grep -q '^arg=\[\]$' "$path_log" || fail "doctor safe probe preserves empty --tools value"
pass "doctor PATH discovery, runtime parity, env presence, argv, and redaction"

report_only_skill="$TEST_ROOT/report-only-skill"
doctor_update_marker="$TEST_ROOT/doctor-update-helper-ran"
copy_fixture_skill "$report_only_skill"
cat > "$report_only_skill/scripts/claude-update-check.sh" <<SH
#!/bin/bash
printf ran > "$doctor_update_marker"
SH
chmod 755 "$report_only_skill/scripts/claude-update-check.sh"
report_only_output="$(run_doctor "$report_only_skill" "$REPO_ROOT" "$REPO_ROOT" "$passwd_home" "$path_value" "$TEST_ROOT/report-only.log" --skip-probes)"
assert_line "$report_only_output" "update_check=skipped" "report-only update status"
[ ! -e "$doctor_update_marker" ] || fail "doctor default executed the mutating update helper"
pass "doctor skips update mutation by default"

unsafe_python_root="$TEST_ROOT/unsafe-python"
unsafe_python_marker="$TEST_ROOT/unsafe-python-executed"
mkdir -p "$unsafe_python_root/bin"
cat > "$unsafe_python_root/bin/python3" <<SH
#!/bin/bash
printf executed > "$unsafe_python_marker"
exit 99
SH
chmod 755 "$unsafe_python_root/bin/python3"
unsafe_python_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$passwd_home" "$unsafe_python_root/bin:$path_value" "$TEST_ROOT/unsafe-python.log" --skip-probes)"
assert_line "$unsafe_python_output" "python_runtime_status=launcher_unsupported" "script-shaped Python rejection"
assert_line "$unsafe_python_output" "claude_runtime_status=unusable_runner" "untrusted Python blocks runtime probes"
[ ! -e "$unsafe_python_marker" ] || fail "untrusted Python executed during doctor bootstrap"
pass "doctor reports and never executes untrusted Python launchers"

version_timeout_output="$({
  FAKE_CLAUDE_HANG_STAGE="version" \
    run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$HOME" "$path_value" "$path_log" \
      --probe-timeout 1 \
      --skip-probes
})"
assert_line "$version_timeout_output" "claude_runtime_status=timeout" "bounded version timeout"

version_failure_output="$({
  FAKE_CLAUDE_VERSION_EXIT=7 \
    run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$HOME" "$path_value" "$path_log" \
      --skip-probes
})"
assert_line "$version_failure_output" "claude_version=unknown" "failed version output is discarded"
assert_line "$version_failure_output" "claude_runtime_status=unusable_runner" "failed version command is unusable"
pass "doctor requires a successful version command"

auth_timeout_output="$({
  FAKE_CLAUDE_HANG_STAGE="auth" \
    run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$HOME" "$path_value" "$path_log" \
      --probe-timeout 1 \
      --skip-probes
})"
assert_line "$auth_timeout_output" "claude_auth_status=timeout" "bounded auth-status timeout"
pass "doctor bounds version and auth-status preflight calls"

# Native discovery and inherited HOME diagnostics.
native_home="$TEST_ROOT/remapped-home"
native_log="$TEST_ROOT/native.log"
write_fake_claude "$native_home/.local/bin/claude"
native_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$native_home" "$SYSTEM_PATH" "$native_log" --skip-probes)"
assert_line "$native_output" "claude_discovery=native_user" "native source"
assert_line "$native_output" "claude_path_status=installed_not_on_path" "native PATH diagnosis"
assert_line "$native_output" "checked_native_path=$native_home/.local/bin/claude" "checked native path"
assert_line "$native_output" "inherited_home_status=differs_passwd" "remapped HOME status"
assert_contains "$native_output" "Passwd HOME is diagnostic only and is never executed" "remapped HOME guidance"
pass "native-user fallback and remapped HOME diagnostics"

relative_log="$TEST_ROOT/relative.log"
missing_skill="$TEST_ROOT/missing-skill"
copy_fixture_skill "$missing_skill"
disable_homebrew_paths "$missing_skill" "$TEST_ROOT/disabled-missing-homebrew/claude"
relative_output="$(run_doctor "$missing_skill" "$REPO_ROOT" "$REPO_ROOT" "relative-home" "$SYSTEM_PATH" "$relative_log" --skip-probes)"
assert_line "$relative_output" "checked_native_path=unavailable" "relative HOME native path"
assert_line "$relative_output" "inherited_home_status=missing_or_non_absolute" "relative HOME status"
assert_line "$relative_output" "claude_discovery=missing" "relative HOME no guessed fallback"
pass "missing or relative HOME disables only native-user discovery"

unset_home_skill="$TEST_ROOT/unset-home-skill"
copy_fixture_skill "$unset_home_skill"
disable_homebrew_paths "$unset_home_skill" "$TEST_ROOT/disabled-homebrew/claude"
unset_home_output="$(run_doctor_without_home \
  "$unset_home_skill" \
  "$REPO_ROOT" \
  "$REPO_ROOT" \
  "$SYSTEM_PATH" \
  "$TEST_ROOT/unset-home.log" \
  --skip-probes)"
assert_line "$unset_home_output" "checked_native_path=unavailable" "unset HOME native path"
assert_line "$unset_home_output" "inherited_home_status=missing_or_non_absolute" "unset HOME status"
assert_line "$unset_home_output" "claude_discovery=missing" "unset HOME discovery"
assert_line "$unset_home_output" "doctor_status=ok" "unset HOME structured doctor result"
[ ! -e "$TEST_ROOT/unset-home.log" ] || fail "unset-HOME doctor executed Claude"
pass "doctor returns structured diagnostics when HOME is unset"

missing_home="$TEST_ROOT/missing-home"
mkdir -p "$missing_home"
no_python_skill="$TEST_ROOT/no-python-skill"
no_python_tools="$TEST_ROOT/no-python-tools"
copy_fixture_skill "$no_python_skill"
disable_homebrew_paths "$no_python_skill" "$TEST_ROOT/disabled-no-python-homebrew/claude"
rm -f "$no_python_skill/scripts/claude-config.sh"
mkdir -p "$no_python_tools"
for tool_name in dirname mktemp chmod rm grep; do
  ln -s "$(command -v "$tool_name")" "$no_python_tools/$tool_name"
done
no_python_output="$(run_doctor "$no_python_skill" "$REPO_ROOT" "$REPO_ROOT" "$missing_home" "$no_python_tools" "$TEST_ROOT/no-python.log" --skip-probes 2>/dev/null)"
assert_line "$no_python_output" "inherited_home_status=passwd_unavailable" "passwd parser unavailable status"
assert_line "$no_python_output" "python_runtime_status=missing" "missing Python runtime status"
pass "passwd parser unavailability is diagnostic and non-blocking"

# Missing is explicitly inconclusive.
missing_output="$(run_doctor "$missing_skill" "$REPO_ROOT" "$REPO_ROOT" "$missing_home" "$SYSTEM_PATH" "$TEST_ROOT/missing.log" --skip-probes)"
assert_line "$missing_output" "claude_discovery=missing" "missing source"
assert_line "$missing_output" "claude_path_status=not_found" "missing status"
assert_contains "$missing_output" "inconclusive for custom prefixes" "inconclusive guidance"
assert_contains "$missing_output" "curl -fsSL https://claude.ai/install.sh | bash" "native install guidance"
[ ! -e "$TEST_ROOT/missing.log" ] || fail "missing-discovery doctor case executed Claude"
pass "not-found diagnosis is bounded and inconclusive"

# Default Homebrew mapping, precedence, and dangling-only deferral use a fixture
# copy whose documented absolute prefix is redirected to a trusted test path.
brew_skill="$TEST_ROOT/brew-skill"
brew_path="$TEST_ROOT/default brew=prefix/bin/claude"
brew_log="$TEST_ROOT/brew.log"
copy_fixture_skill "$brew_skill"
if patch_homebrew_path "$brew_skill" "$brew_path"; then
  write_fake_claude "$brew_path"
  brew_home="$TEST_ROOT/brew-home"
  mkdir -p "$brew_home"
  brew_output="$(run_doctor "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$brew_home" "$SYSTEM_PATH" "$brew_log" --skip-probes)"
  assert_line "$brew_output" "claude_discovery=homebrew_default" "Homebrew source"
  assert_line "$brew_output" "claude_path_status=installed_not_on_path" "Homebrew PATH diagnosis"

  precedence_home="$TEST_ROOT/precedence-home"
  write_fake_claude "$precedence_home/.local/bin/claude"
  precedence_output="$(run_doctor "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$precedence_home" "$SYSTEM_PATH" "$TEST_ROOT/precedence.log" --skip-probes)"
  assert_line "$precedence_output" "claude_discovery=native_user" "native precedes Homebrew"

  dangling_home="$TEST_ROOT/dangling-home"
  mkdir -p "$dangling_home/.local/bin"
  ln -s "$dangling_home/missing-claude" "$dangling_home/.local/bin/claude"
  stale_output="$(run_doctor "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$dangling_home" "$SYSTEM_PATH" "$TEST_ROOT/stale.log" --skip-probes)"
  assert_line "$stale_output" "claude_discovery=homebrew_default" "dangling native defers to Homebrew"
  assert_line "$stale_output" "stale_fallback_source=native_user" "stale source"
  assert_line "$stale_output" "stale_fallback_path=$dangling_home/.local/bin/claude" "stale path"
  assert_line "$stale_output" "stale_fallback_status=dangling_symlink" "stale status"

  loop_home="$TEST_ROOT/loop-native-home"
  mkdir -p "$loop_home/.local/bin"
  ln -s "$loop_home/.local/bin/claude-loop" "$loop_home/.local/bin/claude"
  ln -s "$loop_home/.local/bin/claude" "$loop_home/.local/bin/claude-loop"
  loop_output="$(run_doctor "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$loop_home" "$SYSTEM_PATH" "$TEST_ROOT/loop-native.log" --skip-probes)"
  assert_line "$loop_output" "claude_discovery=native_user" "symlink loop remains authoritative"
  assert_line "$loop_output" "claude_path_status=unsafe_candidate" "symlink loop fails closed"
  assert_line "$loop_output" "claude_trust_reason=validation_unavailable" "symlink loop is not dangling"
  assert_line "$loop_output" "stale_fallback_status=none" "symlink loop not deferred"

  # Root bypasses these DAC mode bits, so this fixture is meaningful only for
  # an identity whose filesystem access is actually constrained by them.
  if [ "${EUID:-1}" -ne 0 ]; then
    inaccessible_home="$TEST_ROOT/inaccessible-native-home"
    mkdir -p "$inaccessible_home/.local/bin" "$inaccessible_home/blocked"
    ln -s "$inaccessible_home/blocked/claude" "$inaccessible_home/.local/bin/claude"
    chmod 000 "$inaccessible_home/blocked"
    inaccessible_output="$(run_doctor "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$inaccessible_home" "$SYSTEM_PATH" "$TEST_ROOT/inaccessible-native.log" --skip-probes)"
    chmod 700 "$inaccessible_home/blocked"
    assert_line "$inaccessible_output" "claude_discovery=native_user" "inaccessible native remains authoritative"
    assert_line "$inaccessible_output" "claude_path_status=unsafe_candidate" "inaccessible target fails closed"
    assert_line "$inaccessible_output" "claude_trust_reason=validation_unavailable" "inaccessible target is not dangling"
    assert_line "$inaccessible_output" "stale_fallback_status=none" "inaccessible target not deferred"
  fi

  invalid_home="$TEST_ROOT/invalid-home"
  write_fake_claude "$invalid_home/.local/bin/claude"
  chmod 644 "$invalid_home/.local/bin/claude"
  invalid_output="$(run_doctor "$brew_skill" "$REPO_ROOT" "$REPO_ROOT" "$invalid_home" "$SYSTEM_PATH" "$TEST_ROOT/invalid.log" --skip-probes)"
  assert_line "$invalid_output" "claude_discovery=native_user" "invalid native remains authoritative"
  assert_line "$invalid_output" "claude_path_status=not_executable" "invalid native blocks Homebrew"
  pass "Homebrew fallback, native precedence, and dangling-only deferral"
else
  pass "Homebrew integration skipped on unsupported test architecture"
fi

# Independent path-status/scope/reason mappings and non-execution.
status_home="$TEST_ROOT/status-home"
mkdir -p "$status_home/.local/bin/claude"
not_regular_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$status_home" "$SYSTEM_PATH" "$TEST_ROOT/not-regular.log" --skip-probes)"
assert_line "$not_regular_output" "claude_path_status=not_regular" "not regular status"
assert_line "$not_regular_output" "claude_trust_scope=target" "not regular scope"
assert_line "$not_regular_output" "claude_trust_reason=not_regular" "not regular reason"

nonexec_home="$TEST_ROOT/nonexec-home"
mkdir -p "$nonexec_home/.local/bin"
printf '#!/bin/bash\nexit 99\n' > "$nonexec_home/.local/bin/claude"
chmod 644 "$nonexec_home/.local/bin/claude"
nonexec_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$nonexec_home" "$SYSTEM_PATH" "$TEST_ROOT/nonexec.log" --skip-probes)"
assert_line "$nonexec_output" "claude_path_status=not_executable" "not executable status"
assert_line "$nonexec_output" "claude_trust_scope=target" "not executable scope"
assert_line "$nonexec_output" "claude_trust_reason=not_executable" "not executable reason"

dangling_only_home="$TEST_ROOT/dangling-only-home"
dangling_only_skill="$TEST_ROOT/dangling-only-skill"
copy_fixture_skill "$dangling_only_skill"
disable_homebrew_paths "$dangling_only_skill" "$TEST_ROOT/disabled-dangling-homebrew/claude"
mkdir -p "$dangling_only_home/.local/bin"
ln -s "$dangling_only_home/missing" "$dangling_only_home/.local/bin/claude"
dangling_output="$(run_doctor "$dangling_only_skill" "$REPO_ROOT" "$REPO_ROOT" "$dangling_only_home" "$SYSTEM_PATH" "$TEST_ROOT/dangling.log" --skip-probes)"
assert_line "$dangling_output" "claude_path_status=dangling_symlink" "dangling status"
assert_line "$dangling_output" "claude_trust_scope=target" "dangling scope"
assert_line "$dangling_output" "claude_trust_reason=dangling_symlink" "dangling reason"

world_root="$TEST_ROOT/world-writable"
world_log="$TEST_ROOT/world.log"
write_fake_claude "$world_root/bin/claude"
chmod 777 "$world_root"
world_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$missing_home" "$world_root/bin:$SYSTEM_PATH" "$world_log" --skip-probes)"
assert_line "$world_output" "claude_path_status=unsafe_candidate" "world writable status"
assert_line "$world_output" "claude_trust_scope=launch" "world writable scope"
assert_line "$world_output" "claude_trust_reason=world_writable_parent" "world writable reason"
[ ! -e "$world_log" ] || fail "world-writable candidate executed"

world_file_root="$TEST_ROOT/world-writable-file"
world_file_log="$TEST_ROOT/world-file.log"
write_fake_claude "$world_file_root/bin/claude"
chmod 777 "$world_file_root/bin/claude"
world_file_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$missing_home" "$world_file_root/bin:$SYSTEM_PATH" "$world_file_log" --skip-probes)"
assert_line "$world_file_output" "claude_path_status=unsafe_candidate" "world-writable file status"
assert_line "$world_file_output" "claude_trust_scope=target" "world-writable file scope"
assert_line "$world_file_output" "claude_trust_reason=world_writable_file" "world-writable file reason"
[ ! -e "$world_file_log" ] || fail "world-writable executable file ran"

invocation_root="$TEST_ROOT/invocation-cwd"
invocation_log="$TEST_ROOT/invocation.log"
write_fake_claude "$invocation_root/bin/claude"
invocation_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$invocation_root" "$missing_home" "$invocation_root/bin:$SYSTEM_PATH" "$invocation_log" --skip-probes)"
assert_line "$invocation_output" "claude_trust_reason=invocation_cwd_path" "invocation CWD reason"
[ ! -e "$invocation_log" ] || fail "invocation-CWD candidate executed"

reviewed_repo="$TEST_ROOT/reviewed-repo"
unsafe_home="$TEST_ROOT/unsafe-home"
unsafe_log="$TEST_ROOT/unsafe.log"
write_fake_claude "$reviewed_repo/bin/claude-target"
mkdir -p "$unsafe_home/.local/bin"
ln -s "$reviewed_repo/bin/claude-target" "$unsafe_home/.local/bin/claude"
unsafe_output="$(run_doctor "$REPO_ROOT" "$reviewed_repo" "$REPO_ROOT" "$unsafe_home" "$SYSTEM_PATH" "$unsafe_log" --skip-probes)"
assert_line "$unsafe_output" "claude_path_status=unsafe_candidate" "unsafe target status"
assert_line "$unsafe_output" "claude_target=$reviewed_repo/bin/claude-target" "unsafe target remains diagnostic"
assert_line "$unsafe_output" "claude_trust_scope=target" "unsafe target scope"
assert_line "$unsafe_output" "claude_trust_reason=repository_path" "unsafe target reason"
[ ! -e "$unsafe_log" ] || fail "unsafe target candidate executed"

chain_home="$TEST_ROOT/chain-home"
chain_world="$TEST_ROOT/chain-world"
chain_log="$TEST_ROOT/chain.log"
write_fake_claude "$TEST_ROOT/chain-target/claude"
mkdir -p "$chain_home/.local/bin" "$chain_world"
ln -s "$TEST_ROOT/chain-target/claude" "$chain_world/claude-hop"
ln -s "$chain_world/claude-hop" "$chain_home/.local/bin/claude"
chmod 777 "$chain_world"
chain_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$chain_home" "$SYSTEM_PATH" "$chain_log" --skip-probes)"
assert_line "$chain_output" "claude_path_status=unsafe_candidate" "intermediate chain status"
assert_line "$chain_output" "claude_trust_scope=target" "intermediate chain scope"
assert_line "$chain_output" "claude_trust_reason=world_writable_parent" "intermediate chain reason"
[ ! -e "$chain_log" ] || fail "intermediate-chain candidate executed"

validation_skill="$TEST_ROOT/validation-skill"
validation_bin="$TEST_ROOT/validation-bin"
validation_log="$TEST_ROOT/validation.log"
copy_fixture_skill "$validation_skill"
write_fake_claude "$validation_bin/claude"
python3 - "$validation_skill/scripts/claude-locator.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
marker = "# claude-review-helper-complete: locator_v1"
replacement = "claude_locator_resolve_trusted_utility() { return 1; }\n\n" + marker
path.write_text(path.read_text().replace(marker, replacement))
PY
validation_output="$(run_doctor "$validation_skill" "$REPO_ROOT" "$REPO_ROOT" "$missing_home" "$validation_bin:$SYSTEM_PATH" "$validation_log" --skip-probes)"
assert_line "$validation_output" "claude_path_status=unsafe_candidate" "validation unavailable status"
assert_line "$validation_output" "claude_trust_scope=launch" "validation unavailable scope"
assert_line "$validation_output" "claude_trust_reason=validation_unavailable" "validation unavailable reason"
[ ! -e "$validation_log" ] || fail "unvalidated candidate executed"

if printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$not_regular_output" "$nonexec_output" "$dangling_output" "$world_output" "$invocation_output" "$unsafe_output" "$chain_output" "$validation_output" | grep -E '^claude_path_status=.*:' >/dev/null; then
  fail "doctor emitted a compound path status"
fi
pass "doctor emits independent trust enums, validates symlink chains, and fails closed without validators"

# Deterministic launcher dependency classification.
dependency_home="$TEST_ROOT/dependency-home"
mkdir -p "$dependency_home/.local/bin"
cat > "$dependency_home/.local/bin/claude" <<'SH'
#!/usr/bin/env definitely-missing-claude-interpreter
SH
chmod 755 "$dependency_home/.local/bin/claude"
dependency_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$dependency_home" "$SYSTEM_PATH" "$TEST_ROOT/dependency.log" --skip-probes)"
assert_line "$dependency_output" "claude_path_status=launcher_dependency_missing" "dependency status"
assert_line "$dependency_output" "claude_launcher_dependency=definitely-missing-claude-interpreter" "dependency token"
assert_line "$dependency_output" "claude_trust_scope=none" "dependency trust scope"
assert_line "$dependency_output" "claude_trust_reason=none" "dependency trust reason"
[ ! -e "$TEST_ROOT/dependency.log" ] || fail "missing dependency launcher executed"

absolute_home="$TEST_ROOT/absolute-dependency-home"
mkdir -p "$absolute_home/.local/bin"
cat > "$absolute_home/.local/bin/claude" <<'SH'
#!/definitely/missing/claude-interpreter
SH
chmod 755 "$absolute_home/.local/bin/claude"
absolute_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$absolute_home" "$SYSTEM_PATH" "$TEST_ROOT/absolute.log" --skip-probes)"
assert_line "$absolute_output" "claude_path_status=launcher_dependency_missing" "absolute dependency status"
assert_line "$absolute_output" "claude_launcher_dependency_path=/definitely/missing/claude-interpreter" "absolute dependency path"
assert_line "$absolute_output" "claude_launcher_dependency_resolution=absolute" "absolute dependency resolution"
assert_contains "$absolute_output" "PATH changes cannot repair an absolute shebang" "absolute dependency guidance"
[ ! -e "$TEST_ROOT/absolute.log" ] || fail "absolute missing dependency launcher executed"

unsupported_home="$TEST_ROOT/unsupported-dependency-home"
unsupported_log="$TEST_ROOT/unsupported-dependency.log"
mkdir -p "$unsupported_home/.local/bin"
cat > "$unsupported_home/.local/bin/claude" <<'SH'
#!/usr/bin/env -S fake-node --unsafe-flag
exit 99
SH
chmod 755 "$unsupported_home/.local/bin/claude"
unsupported_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$unsupported_home" "$SYSTEM_PATH" "$unsupported_log" --skip-probes)"
assert_line "$unsupported_output" "claude_path_status=launcher_dependency_unsupported" "unsupported dependency status"
assert_line "$unsupported_output" "claude_launcher_dependency=env" "unsupported dependency classifier"
assert_contains "$unsupported_output" "exact '#!/usr/bin/env NAME'" "unsupported dependency guidance"
[ ! -e "$unsupported_log" ] || fail "unsupported dependency launcher executed"

unsafe_dependency_home="$TEST_ROOT/unsafe-dependency-home"
unsafe_dependency_invocation="$TEST_ROOT/unsafe-dependency-invocation"
unsafe_dependency_log="$TEST_ROOT/unsafe-dependency.log"
mkdir -p "$unsafe_dependency_invocation/bin"
write_fake_claude "$unsafe_dependency_home/.local/bin/claude"
python3 - "$unsafe_dependency_home/.local/bin/claude" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace("#!/bin/bash", "#!/usr/bin/env fake-node", 1))
PY
ln -s /bin/bash "$unsafe_dependency_invocation/bin/fake-node"
unsafe_dependency_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$unsafe_dependency_invocation" "$unsafe_dependency_home" "$unsafe_dependency_invocation/bin:$SYSTEM_PATH" "$unsafe_dependency_log" --skip-probes)"
assert_line "$unsafe_dependency_output" "claude_path_status=launcher_dependency_unsafe" "unsafe dependency status"
assert_line "$unsafe_dependency_output" "claude_launcher_dependency=fake-node" "unsafe dependency name"
assert_line "$unsafe_dependency_output" "claude_launcher_dependency_path=$unsafe_dependency_invocation/bin/fake-node" "unsafe dependency path"
assert_line "$unsafe_dependency_output" "claude_launcher_dependency_trust_scope=launch" "unsafe dependency trust scope"
assert_line "$unsafe_dependency_output" "claude_launcher_dependency_trust_reason=invocation_cwd_path" "unsafe dependency trust reason"
[ ! -e "$unsafe_dependency_log" ] || fail "unsafe dependency launcher executed"

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
nested_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$nested_invocation" "$nested_home" "$nested_tools:$SYSTEM_PATH" "$TEST_ROOT/nested-claude.log" --skip-probes)"
assert_line "$nested_output" "claude_path_status=launcher_dependency_unsafe" "nested dependency status"
assert_line "$nested_output" "claude_launcher_dependency=fake-python" "nested dependency name"
assert_line "$nested_output" "claude_launcher_dependency_trust_reason=invocation_cwd_path" "nested dependency trust reason"
[ ! -e "$nested_log" ] || fail "nested unsafe dependency executed"

# Root bypasses these DAC mode bits, so this fixture is meaningful only for an
# identity whose read access is actually constrained by them.
if [ "${EUID:-1}" -ne 0 ]; then
  unreadable_home="$TEST_ROOT/unreadable-home"
  unreadable_log="$TEST_ROOT/unreadable.log"
  write_fake_claude "$unreadable_home/.local/bin/claude"
  chmod 111 "$unreadable_home/.local/bin/claude"
  unreadable_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$unreadable_home" "$SYSTEM_PATH" "$unreadable_log" --skip-probes)"
  assert_line "$unreadable_output" "claude_path_status=launcher_dependency_unreadable" "unreadable dependency status"
  assert_line "$unreadable_output" "claude_launcher_dependency_path=$unreadable_home/.local/bin/claude" "unreadable dependency path"
  [ ! -e "$unreadable_log" ] || fail "unreadable launcher executed"
fi
pass "doctor launcher-dependency classification"

# Profile-only values are not imported; directly inherited values are presence-only.
profile_home="$TEST_ROOT/profile-home"
profile_marker="$TEST_ROOT/profile-loaded"
profile_log="$TEST_ROOT/profile.log"
write_fake_claude "$profile_home/.local/bin/claude"
cat > "$profile_home/.bash_profile" <<SH
printf loaded > "$profile_marker"
export HTTPS_PROXY=profile-proxy-secret
export NODE_EXTRA_CA_CERTS=profile-ca-secret
export CLAUDE_CONFIG_DIR=profile-config-secret
SH
profile_output="$(run_doctor "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$profile_home" "$SYSTEM_PATH" "$profile_log" --skip-probes)"
assert_line "$profile_output" "inherited_env_HTTPS_PROXY=absent" "profile-only proxy absent"
assert_line "$profile_output" "inherited_env_NODE_EXTRA_CA_CERTS=absent" "profile-only CA absent"
assert_line "$profile_output" "inherited_env_CLAUDE_CONFIG_DIR=absent" "profile-only config absent"
assert_contains "$profile_output" "Codex's launch environment or Claude settings.json" "profile recovery guidance"
[ ! -e "$profile_marker" ] || fail "doctor sourced a login profile"
assert_not_contains "$profile_output" "profile-proxy-secret" "profile value redaction"
pass "doctor never sources login profiles for config or network variables"

# Partial/corrupt helper bootstrap never reaches Claude and never leaks source errors.
run_bootstrap_case() {
  local case_name="$1"
  local tamper="$2"
  local expected_component="$3"
  local skill="$TEST_ROOT/bootstrap-$case_name"
  local output=""
  local candidate_log="$TEST_ROOT/bootstrap-$case_name-candidate.log"

  copy_fixture_skill "$skill"
  case "$tamper" in
    missing_locator) rm -f "$skill/scripts/claude-locator.sh" ;;
    missing_runtime) rm -f "$skill/scripts/claude-runtime.sh" ;;
    invalid_locator) printf 'if then\n# claude-review-helper-complete: locator_v1\n' > "$skill/scripts/claude-locator.sh" ;;
    empty_runtime) : > "$skill/scripts/claude-runtime.sh" ;;
    no_marker_runtime) printf 'claude_runtime_build_command() { :; }\nclaude_runtime_check_launcher_dependency() { :; }\n' > "$skill/scripts/claude-runtime.sh" ;;
    missing_symbol_locator) sed 's/^claude_locator_validate_candidate()/claude_locator_validate_candidate_missing()/' "$REPO_ROOT/scripts/claude-locator.sh" > "$skill/scripts/claude-locator.sh" ;;
  esac
  output="$(run_doctor "$skill" "$REPO_ROOT" "$REPO_ROOT" "$HOME" "$path_value" "$candidate_log" --skip-probes 2>&1)"
  assert_line "$output" "doctor_status=bridge_installation_incomplete" "$case_name status"
  assert_line "$output" "bridge_component=$expected_component" "$case_name component"
  assert_not_contains "$output" "syntax error" "$case_name source error redaction"
  assert_not_contains "$output" "unexpected token" "$case_name source error redaction"
  [ ! -e "$candidate_log" ] || fail "$case_name executed Claude"
  pass "doctor bootstrap $case_name"
}

run_bootstrap_case missing-locator missing_locator claude-locator.sh
run_bootstrap_case missing-runtime missing_runtime claude-runtime.sh
run_bootstrap_case invalid-locator invalid_locator claude-locator.sh
run_bootstrap_case empty-runtime empty_runtime claude-runtime.sh
run_bootstrap_case no-marker-runtime no_marker_runtime claude-runtime.sh
run_bootstrap_case missing-symbol-locator missing_symbol_locator claude-locator.sh

pass "claude doctor diagnostics"
