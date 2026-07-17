#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"
PASS=0

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }

new_home() {
  TEST_ROOT="$(mktemp -d)"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
}

run_install() {
  env \
    HOME="$TEST_HOME" \
    SHELL="${TEST_SHELL:-/bin/zsh}" \
    PATH="${TEST_PATH:-/usr/bin:/bin}" \
    MACROSCOPE_LOCAL_BINARY_SOURCE="${TEST_BINARY:-/usr/bin/true}" \
    MACROSCOPE_PLUGIN_BUNDLE_SOURCE="$REPO_ROOT" \
    MACROSCOPE_TEST_NONINTERACTIVE=1 \
    bash "$INSTALLER" "$@"
}

tree_digest() {
  find "$1" -mindepth 1 -print | LC_ALL=C sort | shasum | awk '{print $1}'
}

test_dry_run_is_read_only() {
  new_home
  local before after
  before="$(tree_digest "$TEST_HOME")"
  run_install --dry-run --tools claude,codex --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  after="$(tree_digest "$TEST_HOME")"
  [ "$before" = "$after" ] || fail "dry-run changed HOME"
  [ -z "$(find "$TEST_HOME" -mindepth 1 -print -quit)" ] || fail "dry-run created files"
  pass "dry-run has zero persistent writes"
}

test_noninteractive_requires_consent() {
  new_home
  set +e
  run_install --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  local code=$?
  set -e
  [ "$code" -eq 3 ] || fail "unconfirmed noninteractive install exited $code, want 3"
  [ -z "$(find "$TEST_HOME" -mindepth 1 -print -quit)" ] || fail "cancelled install changed HOME"
  pass "noninteractive install requires explicit consent"
}

test_no_controlling_tty_requires_consent() {
  new_home
  set +e
  env \
    HOME="$TEST_HOME" \
    SHELL=/bin/zsh \
    PATH=/usr/bin:/bin \
    MACROSCOPE_LOCAL_BINARY_SOURCE=/usr/bin/true \
    MACROSCOPE_PLUGIN_BUNDLE_SOURCE="$REPO_ROOT" \
    bash "$INSTALLER" --tools none --host-permissions skip --no-wizard \
      >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  local code=$?
  set -e
  [ "$code" -eq 3 ] || fail "install without a controlling TTY exited $code, want 3"
  [ -z "$(find "$TEST_HOME" -mindepth 1 -print -quit)" ] || fail "install without a controlling TTY changed HOME"
  pass "missing controlling TTY cannot default confirmation to yes"
}

test_zsh_touches_one_profile_and_selected_tool_only() {
  new_home
  printf '# zsh\n' > "$TEST_HOME/.zshrc"
  printf '# bash\n' > "$TEST_HOME/.bashrc"
  run_install --yes --tools claude --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  grep -Fq '# Added by Macroscope installer' "$TEST_HOME/.zshrc" || fail "zshrc not updated"
  [ ! -e "$TEST_HOME/.zprofile" ] || fail "second zsh profile was created"
  [ "$(cat "$TEST_HOME/.bashrc")" = '# bash' ] || fail "bashrc was modified"
  [ ! -e "$TEST_HOME/.bash_profile" ] || fail "bash_profile was created"
  [ -d "$TEST_HOME/.claude/plugins/cache/macroscope-local" ] || fail "Claude plugin missing"
  [ ! -e "$TEST_HOME/plugins/macroscope" ] || fail "Codex plugin installed unexpectedly"
  [ ! -e "$TEST_HOME/.cursor" ] || fail "Cursor state created unexpectedly"
  [ ! -e "$TEST_HOME/.config/opencode" ] || fail "OpenCode state created unexpectedly"
  ! grep -q 'Bash(macroscope' "$TEST_HOME/.claude/settings.json" || fail "permission rule added while skipped"
  [ ! -e "$TEST_HOME/.claude/hooks/macroscope-bash-autoallow.sh" ] || fail "hook added while skipped"
  pass "zsh updates exactly one file and tool/permission selection is honored"
}

test_initial_install_does_not_modify_unselected_existing_tool() {
  new_home
  mkdir -p "$TEST_HOME/.cursor/plugins/local/macroscope"
  printf 'user-managed\n' > "$TEST_HOME/.cursor/plugins/local/macroscope/keep"
  run_install --yes --tools claude --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  [ "$(cat "$TEST_HOME/.cursor/plugins/local/macroscope/keep")" = "user-managed" ] || fail "initial install modified an unselected existing tool"
  pass "initial install leaves unselected existing tool state untouched"
}

test_active_path_skips_profiles() {
  new_home
  TEST_PATH="$TEST_HOME/.local/bin:/usr/bin:/bin"
  run_install --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  [ ! -e "$TEST_HOME/.zshrc" ] && [ ! -e "$TEST_HOME/.zprofile" ] || fail "active PATH still changed profiles"
  pass "exact active PATH component skips shell edits"
  unset TEST_PATH
}

test_initial_defaults_to_all_tools() {
  new_home
  run_install --yes --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  [ -d "$TEST_HOME/.claude/plugins/cache/macroscope-local" ] || fail "default Claude plugin missing"
  [ -d "$TEST_HOME/plugins/macroscope" ] || fail "default Codex plugin missing"
  [ -d "$TEST_HOME/.cursor/plugins/local/macroscope" ] || fail "default Cursor plugin missing"
  [ -f "$TEST_HOME/.config/opencode/plugins/macroscope.js" ] || fail "default OpenCode plugin missing"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "initial tool defaults not recorded"
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
assert data["tools"] == ["claude", "codex", "cursor", "opencode"]
PY
  pass "initial install defaults to all host integrations"
}

test_shell_config_override_is_exact() {
  new_home
  TEST_SHELL=/bin/bash
  run_install --yes --tools none --host-permissions skip --shell-config "$TEST_HOME/dotfiles/shell.env" --no-wizard >"$TEST_ROOT/out"
  grep -Fq '# Added by Macroscope installer' "$TEST_HOME/dotfiles/shell.env" || fail "shell override was not updated"
  [ ! -e "$TEST_HOME/.bashrc" ] && [ ! -e "$TEST_HOME/.bash_profile" ] || fail "shell override also changed default profiles"
  pass "--shell-config touches exactly the requested file"
  unset TEST_SHELL
}

test_permissions_are_opt_in_and_owned() {
  new_home
  TEST_PATH="$TEST_HOME/.local/bin:/usr/bin:/bin"
  run_install --yes --tools claude,cursor,opencode --host-permissions grant --no-wizard >"$TEST_ROOT/out"
  grep -q 'Bash(macroscope \*)' "$TEST_HOME/.claude/settings.json" || fail "Claude rule missing"
  [ -x "$TEST_HOME/.claude/hooks/macroscope-bash-autoallow.sh" ] || fail "Claude hook missing"
  grep -q 'Shell(macroscope \*)' "$TEST_HOME/.cursor/cli-config.json" || fail "Cursor rule missing"
  grep -q '"macroscope \*": "allow"' "$TEST_HOME/.config/opencode/opencode.json" || fail "OpenCode rule missing"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "permission ownership not recorded"
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
assert data["hostPermissions"] == "grant"
assert data["permissionOwnership"]["claude"]["inserted"]
assert data["permissionOwnership"]["cursor"]["inserted"]
assert data["permissionOwnership"]["opencode"]["inserted"]
PY
  pass "host permission automation is explicit and ownership-tracked"
  unset TEST_PATH
}

test_permission_updates_preserve_managed_symlinks() {
  new_home
  mkdir -p "$TEST_ROOT/dotfiles" "$TEST_HOME/.claude"
  printf '{}\n' > "$TEST_ROOT/dotfiles/claude-settings.json"
  ln -s "$TEST_ROOT/dotfiles/claude-settings.json" "$TEST_HOME/.claude/settings.json"
  run_install --yes --tools claude --host-permissions grant --no-path --no-wizard >"$TEST_ROOT/out"
  [ -L "$TEST_HOME/.claude/settings.json" ] || fail "permission update replaced a managed settings symlink"
  grep -q 'Bash(macroscope \*)' "$TEST_ROOT/dotfiles/claude-settings.json" || fail "permission update did not modify the symlink target"
  pass "permission updates preserve managed settings symlinks"
}

test_update_preserves_footprint_and_removes_deselected() {
  new_home
  TEST_PATH="$TEST_HOME/.local/bin:/usr/bin:/bin"
  run_install --yes --tools claude --host-permissions grant --no-wizard >"$TEST_ROOT/initial"
  TEST_BINARY=/usr/bin/true run_install --mode update --yes >"$TEST_ROOT/update"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "update expanded integration footprint"
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
assert data["tools"] == ["claude"]
assert data["hostPermissions"] == "grant"
PY
  [ ! -e "$TEST_HOME/.cursor" ] && [ ! -e "$TEST_HOME/.config/opencode" ] || fail "update installed new tools"
  TEST_BINARY=/usr/bin/true run_install --mode update --yes --tools none --host-permissions skip >"$TEST_ROOT/remove"
  [ ! -e "$TEST_HOME/.claude/plugins/cache/macroscope-local" ] || fail "deselected Claude plugin remains"
  [ ! -e "$TEST_HOME/.claude/hooks/macroscope-bash-autoallow.sh" ] || fail "deselected Claude hook remains"
  pass "update preserves prior footprint and explicitly removes deselected state"
  unset TEST_PATH TEST_BINARY
}

test_legacy_update_preserves_unowned_permissions() {
  new_home
  mkdir -p "$TEST_HOME/.claude/plugins/cache/macroscope-local" "$TEST_HOME/.claude/hooks"
  cat > "$TEST_HOME/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(macroscope *)"]
  }
}
JSON
  printf '#!/bin/sh\n' > "$TEST_HOME/.claude/hooks/macroscope-bash-autoallow.sh"
  chmod +x "$TEST_HOME/.claude/hooks/macroscope-bash-autoallow.sh"
  run_install --mode update --yes --no-path --no-wizard >"$TEST_ROOT/update"
  python3 - "$TEST_HOME/.claude/settings.json" "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "legacy permission state was not preserved"
import json, sys
with open(sys.argv[1]) as f: settings = json.load(f)
with open(sys.argv[2]) as f: state = json.load(f)
assert settings["permissions"]["allow"] == ["Bash(macroscope *)"]
assert state["hostPermissions"] == "preserve"
assert state["permissionOwnership"]["claude"]["inserted"] == []
PY
  [ -x "$TEST_HOME/.claude/hooks/macroscope-bash-autoallow.sh" ] || fail "legacy hook was removed"
  pass "legacy update preserves permission automation it cannot prove it owns"
}

test_legacy_explicit_skip_preserves_unowned_rules() {
  new_home
  mkdir -p "$TEST_HOME/.claude/plugins/cache/macroscope-local" "$TEST_HOME/.claude/hooks"
  cat > "$TEST_HOME/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(macroscope *)", "Bash(mktemp *)"]
  }
}
JSON
  printf '#!/bin/sh\n' > "$TEST_HOME/.claude/hooks/macroscope-bash-autoallow.sh"
  chmod +x "$TEST_HOME/.claude/hooks/macroscope-bash-autoallow.sh"
  run_install --mode update --yes --tools claude --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/update"
  python3 - "$TEST_HOME/.claude/settings.json" <<'PY' || fail "explicit skip removed unowned legacy rules"
import json, sys
with open(sys.argv[1]) as f: settings = json.load(f)
assert settings["permissions"]["allow"] == ["Bash(macroscope *)", "Bash(mktemp *)"]
PY
  [ ! -e "$TEST_HOME/.claude/hooks/macroscope-bash-autoallow.sh" ] || fail "explicit skip retained the installer-owned legacy hook"
  pass "legacy explicit skip preserves unowned allow-rules"
}

test_empty_recorded_footprint_does_not_expand_from_stale_files() {
  new_home
  TEST_PATH="$TEST_HOME/.local/bin:/usr/bin:/bin"
  run_install --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/initial"
  mkdir -p "$TEST_HOME/.cursor/plugins/local/macroscope"
  cp "$REPO_ROOT/plugins/macroscope/.cursor-plugin/plugin.json" "$TEST_HOME/.cursor/plugins/local/macroscope/plugin.json"
  run_install --mode update --yes >"$TEST_ROOT/update"
  [ ! -e "$TEST_HOME/.cursor/plugins/local/macroscope" ] || fail "update expanded an explicitly empty integration footprint"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "empty integration footprint was not retained"
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
assert data["tools"] == []
PY
  pass "recorded empty footprint remains authoritative on update"
  unset TEST_PATH
}

test_failure_rolls_back_binary() {
  new_home
  mkdir -p "$TEST_HOME/.local/bin"
  printf 'old-binary\n' > "$TEST_HOME/.local/bin/macroscope"
  chmod +x "$TEST_HOME/.local/bin/macroscope"
  TEST_PATH="$TEST_HOME/.local/bin:/usr/bin:/bin"
  set +e
  MACROSCOPE_TEST_FAIL_AFTER_BINARY=1 run_install --mode update --yes --tools none --host-permissions skip >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  local code=$?
  set -e
  [ "$code" -eq 70 ] || fail "injected failure exited $code"
  [ "$(cat "$TEST_HOME/.local/bin/macroscope")" = 'old-binary' ] || fail "old binary was not restored"
  pass "failed apply rolls back binary replacement"
  unset TEST_PATH
}

test_plugin_failure_rolls_back_all_touched_state() {
  new_home
  mkdir -p "$TEST_HOME/.local/bin" "$TEST_HOME/.claude" "$TEST_ROOT/dotfiles"
  printf 'old-binary\n' > "$TEST_HOME/.local/bin/macroscope"
  chmod +x "$TEST_HOME/.local/bin/macroscope"
  printf '{' > "$TEST_HOME/.claude/settings.json"
  printf 'managed-zsh\n' > "$TEST_ROOT/dotfiles/zshrc"
  ln -s "$TEST_ROOT/dotfiles/zshrc" "$TEST_HOME/.zshrc"
  set +e
  run_install --mode update --yes --tools claude --host-permissions skip --no-wizard >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  local code=$?
  set -e
  [ "$code" -ne 0 ] || fail "invalid host settings did not fail the update"
  [ "$(cat "$TEST_HOME/.local/bin/macroscope")" = "old-binary" ] || fail "plugin failure did not restore the binary"
  [ "$(cat "$TEST_HOME/.claude/settings.json")" = "{" ] || fail "plugin failure did not restore host settings"
  [ -L "$TEST_HOME/.zshrc" ] || fail "plugin failure replaced a managed shell symlink"
  [ "$(cat "$TEST_ROOT/dotfiles/zshrc")" = "managed-zsh" ] || fail "plugin failure did not restore the managed shell target"
  [ ! -e "$TEST_HOME/.claude/plugins/cache/macroscope-local" ] || fail "plugin failure left a partial plugin cache"
  pass "plugin failure restores binary, settings, and plugin state"
}

test_legacy_cleanup_failure_restores_claude_mcp_state() {
  new_home
  cat > "$TEST_HOME/.claude.json" <<'JSON'
{"mcpServers":{"macroscope-codereview":{"command":"macroscope"},"keep":{"command":"keep"}}}
JSON
  local before
  before="$(cat "$TEST_HOME/.claude.json")"
  set +e
  MACROSCOPE_TEST_FAIL_AFTER_LEGACY_CLEANUP=1 run_install --mode update --yes --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  local code=$?
  set -e
  [ "$code" -eq 71 ] || fail "injected legacy cleanup failure exited $code"
  [ "$(cat "$TEST_HOME/.claude.json")" = "$before" ] || fail "legacy Claude MCP state was not restored"
  pass "failure after legacy cleanup restores Claude MCP state"
}

test_wizard_lifecycle_plan() {
  new_home
  run_install --dry-run --tools none --host-permissions skip >"$TEST_ROOT/initial"
  grep -q 'Launch the setup wizard' "$TEST_ROOT/initial" || fail "initial plan does not launch wizard"
  mkdir -p "$TEST_HOME/.local/bin"
  cp /bin/echo "$TEST_HOME/.local/bin/macroscope"
  run_install --mode update --dry-run --tools none --host-permissions skip >"$TEST_ROOT/update"
  grep -q 'Do not launch the setup wizard' "$TEST_ROOT/update" || fail "update plan launches wizard"
  pass "wizard defaults to initial-only"
}

test_dry_run_is_read_only
test_noninteractive_requires_consent
test_no_controlling_tty_requires_consent
test_zsh_touches_one_profile_and_selected_tool_only
test_initial_install_does_not_modify_unselected_existing_tool
test_active_path_skips_profiles
test_initial_defaults_to_all_tools
test_shell_config_override_is_exact
test_permissions_are_opt_in_and_owned
test_permission_updates_preserve_managed_symlinks
test_update_preserves_footprint_and_removes_deselected
test_legacy_update_preserves_unowned_permissions
test_legacy_explicit_skip_preserves_unowned_rules
test_empty_recorded_footprint_does_not_expand_from_stale_files
test_failure_rolls_back_binary
test_plugin_failure_rolls_back_all_touched_state
test_legacy_cleanup_failure_restores_claude_mcp_state
test_wizard_lifecycle_plan

echo "All $PASS installer tests passed."
