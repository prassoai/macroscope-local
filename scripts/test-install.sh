#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"
PASS=0
TEST_SUITE_ROOT="$(mktemp -d)"
DECOY_PID=""
TEST_BINARY_DEFAULT="$TEST_SUITE_ROOT/macroscope"

printf '#!/bin/sh\nprintf "test-version\\n"\n' > "$TEST_BINARY_DEFAULT"
chmod +x "$TEST_BINARY_DEFAULT"

cleanup() {
  if [ -n "$DECOY_PID" ]; then
    kill "$DECOY_PID" 2>/dev/null || true
    wait "$DECOY_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_SUITE_ROOT"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }

new_home() {
  TEST_ROOT="$(mktemp -d "$TEST_SUITE_ROOT/test.XXXXXX")"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
}

run_install() {
  env \
    HOME="$TEST_HOME" \
    SHELL="${TEST_SHELL:-/bin/zsh}" \
    PATH="${TEST_PATH:-/usr/bin:/bin}" \
    CLAUDE_CONFIG_DIR="${TEST_CLAUDE_CONFIG_DIR:-}" \
    OPENCODE_CONFIG_DIR="${TEST_OPENCODE_CONFIG_DIR:-}" \
    XDG_CONFIG_HOME="${TEST_XDG_CONFIG_HOME:-}" \
    TEST_CLAUDE_LOG="${TEST_CLAUDE_LOG:-}" \
    MACROSCOPE_LOCAL_BINARY_SOURCE="${TEST_BINARY:-$TEST_BINARY_DEFAULT}" \
    MACROSCOPE_PLUGIN_BUNDLE_SOURCE="${TEST_PLUGIN_BUNDLE:-$REPO_ROOT}" \
    MACROSCOPE_CODEX_BUNDLED_BINARY="${TEST_CODEX_BUNDLED_BINARY:-}" \
    MACROSCOPE_TEST_NONINTERACTIVE=1 \
    bash "$INSTALLER" "$@"
}

run_interactive_install() {
  local output="$1"
  local expected_status="$2"
  shift 2
  python3 - "$INSTALLER" "$TEST_HOME" "$TEST_BINARY_DEFAULT" "$REPO_ROOT" "$output" "$expected_status" "$@" <<'PY'
import errno
import os
import pty
import select
import signal
import sys
import termios
import time

installer, home, binary, bundle, output, expected_status, *args = sys.argv[1:]
try:
    event_separator = args.index("--events")
except ValueError:
    raise SystemExit("missing --events separator")
installer_args = args[:event_separator]
events = []
for event in args[event_separator + 1:]:
    if "=" not in event:
        raise SystemExit(f"invalid PTY event: {event!r}")
    prompt, keys = event.split("=", 1)
    events.append((prompt.encode(), keys.encode()))

env = os.environ.copy()
env.update({
    "HOME": home,
    "SHELL": "/bin/zsh",
    "PATH": "/usr/bin:/bin",
    "MACROSCOPE_LOCAL_BINARY_SOURCE": binary,
    "MACROSCOPE_PLUGIN_BUNDLE_SOURCE": bundle,
})
for name in (
    "MACROSCOPE_TEST_NONINTERACTIVE",
    "CLAUDE_CONFIG_DIR",
    "OPENCODE_CONFIG_DIR",
    "XDG_CONFIG_HOME",
):
    env.pop(name, None)

pid, fd = pty.fork()
if pid == 0:
    os.execve("/bin/bash", ["bash", installer, *installer_args], env)

initial_tty = termios.tcgetattr(fd)
captured = bytearray()
next_event = 0
deadline = time.monotonic() + 30
status = None
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                _, status = os.waitpid(pid, 0)
                break
            if not chunk:
                _, status = os.waitpid(pid, 0)
                break
            captured.extend(chunk)
            while next_event < len(events) and events[next_event][0] in captured:
                os.write(fd, events[next_event][1])
                next_event += 1
        done, child_status = os.waitpid(pid, os.WNOHANG)
        if done:
            status = child_status
            break
    if status is None:
        os.kill(pid, signal.SIGTERM)
        _, status = os.waitpid(pid, 0)
finally:
    final_tty = termios.tcgetattr(fd)
    os.close(fd)
    with open(output, "wb") as f:
        f.write(captured)

actual_status = os.WEXITSTATUS(status) if os.WIFEXITED(status) else None
interrupted = (
    (os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGINT)
    or actual_status == 128 + signal.SIGINT
)
expected_exit = interrupted if expected_status == "interrupt" else actual_status == int(expected_status)
tty_mask = termios.ECHO | termios.ICANON
tty_restored = initial_tty[3] & tty_mask == final_tty[3] & tty_mask
if next_event != len(events) or not expected_exit or not tty_restored:
    sys.stderr.buffer.write(captured)
    print(
        f"PTY events {next_event}/{len(events)}, exit {actual_status}, "
        f"expected {expected_status}, tty restored: {tty_restored}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
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

test_empty_version_binary_is_rejected_before_apply() {
  new_home
  set +e
  TEST_BINARY=/usr/bin/true run_install --yes --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  local code=$?
  set -e
  [ "$code" -ne 0 ] || fail "empty-version binary passed validation"
  [ ! -e "$TEST_HOME/.local/bin/macroscope" ] || fail "invalid binary was applied"
  pass "empty-version binary is rejected before apply"
}

test_selected_tool_assets_are_validated_before_apply() {
  new_home
  local broken_bundle="$TEST_ROOT/bundle"
  cp -R "$REPO_ROOT" "$broken_bundle"
  rm -f "$broken_bundle/plugins/macroscope/skills/autoloop/SKILL.md"
  set +e
  TEST_PLUGIN_BUNDLE="$broken_bundle" run_install --yes --tools opencode --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  local code=$?
  set -e
  [ "$code" -ne 0 ] || fail "incomplete selected-tool assets passed validation"
  [ ! -e "$TEST_HOME/.local/bin/macroscope" ] || fail "binary applied before plugin validation"
  pass "selected-tool assets are validated before apply"
}

test_existing_install_directory_mode_is_preserved() {
  new_home
  mkdir -p "$TEST_HOME/.local/bin"
  chmod 700 "$TEST_HOME/.local/bin"
  run_install --yes --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  local mode=""
  mode="$(stat -f '%Lp' "$TEST_HOME/.local/bin" 2>/dev/null || stat -c '%a' "$TEST_HOME/.local/bin")"
  [ "$mode" = "700" ] || fail "existing install directory mode changed to $mode"
  pass "existing install directory mode is preserved"
}

test_codex_wrapper_is_announced_in_plan() {
  new_home
  local bundled_codex="$TEST_ROOT/codex'quoted"
  printf '#!/bin/sh\n[ "${1:-}" != "--help" ] || printf "app-server\\n"\n' > "$bundled_codex"
  chmod +x "$bundled_codex"
  TEST_CODEX_BUNDLED_BINARY="$bundled_codex" run_install --dry-run --tools codex --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  grep -Fq "Install or update the managed Codex CLI wrapper at $TEST_HOME/.local/bin/codex" "$TEST_ROOT/out" || fail "Codex wrapper missing from plan"
  TEST_CODEX_BUNDLED_BINARY="$bundled_codex" run_install --yes --tools codex --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  "$TEST_HOME/.local/bin/codex" --help | grep -Fq 'app-server' || fail "Codex wrapper did not preserve a quoted binary path"
  pass "Codex wrapper is announced and safely quoted"
}

test_option_terminator_allows_dash_prefixed_version() {
  new_home
  run_install --dry-run --tools none --host-permissions skip --no-wizard -- -beta >"$TEST_ROOT/out"
  grep -Fq 'Requested version: -beta' "$TEST_ROOT/out" || fail "-- did not preserve a dash-prefixed version"
  pass "option terminator preserves a dash-prefixed version"
}

test_invalid_state_falls_back_to_detected_tools() {
  new_home
  mkdir -p "$TEST_HOME/.local/state/macroscope" "$TEST_HOME/.cursor/plugins/local/macroscope"
  printf '{' > "$TEST_HOME/.local/state/macroscope/install.json"
  run_install --mode update --dry-run --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  grep -Fq 'Install or update the following plugin for cursor' "$TEST_ROOT/out" || fail "invalid state did not fall back to detected integrations"
  printf '{"tools":null}\n' > "$TEST_HOME/.local/state/macroscope/install.json"
  run_install --mode update --dry-run --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  grep -Fq 'Install or update the following plugin for cursor' "$TEST_ROOT/out" || fail "invalid state schema did not fall back to detected integrations"
  pass "invalid state falls back to detected integrations"
}

test_repair_cleans_claude_local_settings() {
  new_home
  mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.local/state/macroscope"
  printf '{"schemaVersion":1,"tools":["claude"]}\n' > "$TEST_HOME/.local/state/macroscope/install.json"
  printf '{"permissions":{"allow":["Bash(macroscope *)"]}}\n' > "$TEST_HOME/.claude/settings.json"
  printf '{"enabledPlugins":{"macroscope@macroscope-local":true,"keep":true},"permissions":{"allow":["Bash(macroscope *)","Bash(user-command *)"]}}\n' > "$TEST_HOME/.claude/settings.local.json"
  MACROSCOPE_REPAIR_ONLY=1 run_install >"$TEST_ROOT/out"
  python3 - "$TEST_HOME/.claude/settings.local.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
assert data["enabledPlugins"] == {"keep": True}
assert data["permissions"]["allow"] == ["Bash(macroscope *)", "Bash(user-command *)"]
PY
  ! grep -Fq 'Bash(macroscope *)' "$TEST_HOME/.claude/settings.json" || fail "repair left an owned rule in settings.json"
  pass "repair scopes Claude permission cleanup to settings.json"
}

test_repair_fails_closed_on_invalid_permission_ownership() {
  new_home
  mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.local/state/macroscope"
  printf '{"schemaVersion":1,"tools":[],"hostPermissions":"skip","permissionOwnership":[]}\n' > "$TEST_HOME/.local/state/macroscope/install.json"
  printf '{"permissions":{"allow":["Bash(macroscope *)"]}}\n' > "$TEST_HOME/.claude/settings.json"
  MACROSCOPE_REPAIR_ONLY=1 run_install >"$TEST_ROOT/out"
  grep -Fq 'Bash(macroscope *)' "$TEST_HOME/.claude/settings.json" || fail "invalid ownership metadata removed an unproven rule"
  pass "repair fails closed on invalid permission ownership"
}

test_legacy_cleanup_does_not_kill_regex_near_process() {
  new_home
  local legacy_path="$TEST_HOME/.local/bin/macroscope-mcp"
  local decoy_path="${legacy_path//./x}"
  mkdir -p "$(dirname "$decoy_path")"
  ln -s /bin/sleep "$decoy_path"
  "$decoy_path" 86400 &
  DECOY_PID=$!
  run_install --mode update --yes --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  if ! kill -0 "$DECOY_PID" 2>/dev/null; then
    fail "legacy cleanup killed a regex-near process"
  fi
  kill "$DECOY_PID" 2>/dev/null || true
  wait "$DECOY_PID" 2>/dev/null || true
  DECOY_PID=""
  pass "legacy cleanup only kills the literal executable path"
}

test_opencode_scalar_permissions_are_preserved() {
  new_home
  mkdir -p "$TEST_HOME/.config/opencode"
  printf '{"permission":"allow"}\n' > "$TEST_HOME/.config/opencode/opencode.json"
  run_install --yes --tools opencode --host-permissions grant --no-path --no-wizard >"$TEST_ROOT/out"
  python3 - "$TEST_HOME/.config/opencode/opencode.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
assert data["permission"] == "allow"
PY
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
assert state["permissionOwnership"]["opencode"]["inserted"] == []
PY

  new_home
  mkdir -p "$TEST_HOME/.config/opencode"
  printf '{"permission":{"bash":"allow","edit":"deny"}}\n' > "$TEST_HOME/.config/opencode/opencode.json"
  run_install --yes --tools opencode --host-permissions grant --no-path --no-wizard >"$TEST_ROOT/out"
  python3 - "$TEST_HOME/.config/opencode/opencode.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
assert data["permission"] == {"bash": "allow", "edit": "deny"}
PY

  new_home
  mkdir -p "$TEST_HOME/.config/opencode"
  printf '{"permission":{"bash":"ask"}}\n' > "$TEST_HOME/.config/opencode/opencode.json"
  run_install --yes --tools opencode --host-permissions grant --no-path --no-wizard >"$TEST_ROOT/out"
  python3 - "$TEST_HOME/.config/opencode/opencode.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
bash = data["permission"]["bash"]
assert bash["*"] == "ask"
assert bash["macroscope *"] == "allow"
PY
  pass "OpenCode scalar permissions are preserved"
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
  python3 -c 'import subprocess, sys; raise SystemExit(subprocess.run(sys.argv[1:], start_new_session=True).returncode)' \
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
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "active PATH was treated as an explicit opt-out"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data = json.load(f)
assert data["pathPolicy"] == "auto"
assert data["pathFile"] is None
PY
  run_install --mode update --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  [ ! -e "$TEST_HOME/.zshrc" ] && [ ! -e "$TEST_HOME/.zprofile" ] || fail "still-active PATH changed profiles"
  unset TEST_PATH
  run_install --mode update --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  grep -Fq '# Added by Macroscope installer' "$TEST_HOME/.zprofile" || fail "missing ambient PATH was not repaired"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "repaired PATH was not recorded as managed"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data = json.load(f)
assert data["pathPolicy"] == "managed"
assert data["pathFile"].endswith("/.zprofile")
PY
  pass "ambient PATH is rechecked before becoming installer-managed"
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
  run_install --yes --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  run_install --mode update --yes --tools none --host-permissions skip --shell-config "$TEST_HOME/dotfiles/shell.env" --no-wizard >"$TEST_ROOT/out"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" "$TEST_HOME/dotfiles/shell.env" <<'PY' || fail "shell override did not restore managed policy"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data = json.load(f)
assert data["pathPolicy"] == "managed"
assert data["pathFile"] == sys.argv[2]
PY
  printf '# user shell config\n' > "$TEST_HOME/dotfiles/shell.env"
  run_install --mode update --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  grep -Fq '# Added by Macroscope installer' "$TEST_HOME/dotfiles/shell.env" || fail "shell override was not updated"
  [ ! -e "$TEST_HOME/.bashrc" ] && [ ! -e "$TEST_HOME/.bash_profile" ] || fail "shell override also changed default profiles"
  [ "$(grep -Fc '# Added by Macroscope installer' "$TEST_HOME/dotfiles/shell.env")" -eq 1 ] || fail "recorded shell target was duplicated"
  pass "--shell-config overrides skip and remains the only managed target"
  unset TEST_SHELL
}

test_no_path_policy_survives_update() {
  new_home
  run_install --yes --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  grep -Fq 'remember --no-path for future updates' "$TEST_ROOT/out" || fail "explicit --no-path persistence was not disclosed"
  printf '# user zsh config\n' > "$TEST_HOME/.zshrc"
  run_install --mode update --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  grep -Fq 'remembered --no-path; use --shell-config PATH to manage it' "$TEST_ROOT/out" || fail "remembered --no-path was not explained"
  [ "$(cat "$TEST_HOME/.zshrc")" = '# user zsh config' ] || fail "stored --no-path policy did not protect zshrc"
  [ ! -e "$TEST_HOME/.zprofile" ] || fail "stored --no-path policy created zprofile"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "--no-path policy was not persisted"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data = json.load(f)
assert data["schemaVersion"] == 2
assert data["pathPolicy"] == "skip"
assert data["pathFile"] is None
PY

  new_home
  local prior_target="$TEST_HOME/dotfiles/prior.env"
  run_install --yes --tools none --host-permissions skip --shell-config "$prior_target" --no-wizard >"$TEST_ROOT/out"
  run_install --mode update --yes --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  printf '# user now owns PATH\n' > "$prior_target"
  run_install --mode update --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  [ "$(cat "$prior_target")" = '# user now owns PATH' ] || fail "retained pathFile overrode skip policy"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" "$prior_target" <<'PY' || fail "--no-path discarded prior target history"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data = json.load(f)
assert data["pathPolicy"] == "skip"
assert data["pathFile"] == sys.argv[2]
PY
  pass "--no-path remains durable while retaining prior target history"
}

test_legacy_path_policy_preserves_behavior() {
  new_home
  mkdir -p "$TEST_HOME/.local/state/macroscope"
  local legacy_target="$TEST_HOME/dotfiles/legacy.env"
  printf '{"schemaVersion":1,"tools":[],"hostPermissions":"skip","pathFile":"%s","permissionOwnership":{}}\n' "$legacy_target" > "$TEST_HOME/.local/state/macroscope/install.json"
  run_install --mode update --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  grep -Fq '# Added by Macroscope installer' "$legacy_target" || fail "legacy managed path target was not repaired"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" "$legacy_target" <<'PY' || fail "legacy managed path policy was not preserved"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data = json.load(f)
assert data["schemaVersion"] == 2
assert data["pathPolicy"] == "managed"
assert data["pathFile"] == sys.argv[2]
PY

  new_home
  mkdir -p "$TEST_HOME/.local/state/macroscope"
  printf '{"schemaVersion":1,"tools":[],"hostPermissions":"skip","pathFile":null,"permissionOwnership":{}}\n' > "$TEST_HOME/.local/state/macroscope/install.json"
  TEST_PATH="$TEST_HOME/.local/bin:/usr/bin:/bin"
  run_install --mode update --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  [ ! -e "$TEST_HOME/.zshrc" ] && [ ! -e "$TEST_HOME/.zprofile" ] || fail "active legacy PATH changed a shell profile"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "legacy active PATH was not migrated to auto"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data = json.load(f)
assert data["schemaVersion"] == 2
assert data["pathPolicy"] == "auto"
PY
  unset TEST_PATH
  run_install --mode update --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  grep -Fq '# Added by Macroscope installer' "$TEST_HOME/.zprofile" || fail "legacy automatic PATH behavior was not preserved"
  pass "legacy state preserves managed and automatic PATH behavior"
}

test_recorded_shell_target_preserves_its_syntax() {
  new_home
  TEST_SHELL=/bin/fish
  run_install --yes --tools none --host-permissions skip --shell-config "$TEST_HOME/.config/fish/config.fish" --no-wizard >"$TEST_ROOT/out"
  printf '' > "$TEST_HOME/.config/fish/config.fish"
  TEST_SHELL=/bin/zsh run_install --mode update --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  grep -Fq 'set -Ux fish_user_paths' "$TEST_HOME/.config/fish/config.fish" || fail "saved fish target received non-fish syntax"

  new_home
  TEST_SHELL=/bin/zsh
  run_install --yes --tools none --host-permissions skip --shell-config "$TEST_HOME/.zprofile" --no-wizard >"$TEST_ROOT/out"
  printf '' > "$TEST_HOME/.zprofile"
  TEST_SHELL=/bin/fish run_install --mode update --yes --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  grep -Fq 'export PATH=' "$TEST_HOME/.zprofile" || fail "saved zsh target received fish syntax"
  pass "recorded shell targets preserve their syntax"
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
  python3 - "$TEST_HOME/.claude/hooks/macroscope-bash-autoallow.sh" <<'PY' || fail "Claude hook command validation failed"
import json, subprocess, sys
hook = sys.argv[1]

def decision(command):
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    return subprocess.run([hook], input=payload, text=True, capture_output=True, check=True).stdout.strip()

assert decision('macroscope codereview --raw &')
assert decision('review_log=$(mktemp "${TMPDIR:-/tmp}/review.XXXXXX")')
assert not decision('macroscope --help > ~/.zshrc')
assert not decision('mktemp >> ~/.bash_profile')
assert not decision('macroscope codereview &>review.log')
assert not decision('macroscope --help; rm -rf "$HOME/data"')
assert not decision('macroscope codereview | sh')
assert not decision('macroscope "$(rm -rf "$HOME/data")"')
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
  run_install --mode update --yes >"$TEST_ROOT/update"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "update expanded integration footprint"
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
assert data["tools"] == ["claude"]
assert data["hostPermissions"] == "grant"
PY
  [ ! -e "$TEST_HOME/.cursor" ] && [ ! -e "$TEST_HOME/.config/opencode" ] || fail "update installed new tools"
  run_install --mode update --yes --tools none --host-permissions skip >"$TEST_ROOT/remove"
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

test_rollback_handles_tabbed_home_without_truncation() {
  new_home
  local truncated_home="$TEST_ROOT/home"
  printf 'keep\n' > "$truncated_home/sentinel"
  TEST_HOME="$truncated_home"$'\t''managed'
  mkdir -p "$TEST_HOME/.local/bin"
  printf 'old-binary\n' > "$TEST_HOME/.local/bin/macroscope"
  chmod +x "$TEST_HOME/.local/bin/macroscope"
  set +e
  MACROSCOPE_TEST_FAIL_AFTER_BINARY=1 run_install --mode update --yes --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  local code=$?
  set -e
  [ "$code" -eq 70 ] || fail "tabbed-HOME injected failure exited $code"
  [ "$(cat "$TEST_HOME/.local/bin/macroscope")" = "old-binary" ] || fail "tabbed-HOME rollback did not restore binary"
  [ "$(cat "$truncated_home/sentinel")" = "keep" ] || fail "rollback touched a truncated path"
  pass "rollback handles tabbed HOME paths without truncation"
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

test_claude_config_dir_is_honored() {
  new_home
  local claude_config="$TEST_HOME/team-claude"
  TEST_CLAUDE_CONFIG_DIR="$claude_config"
  run_install --yes --tools claude --host-permissions grant --no-path --no-wizard >"$TEST_ROOT/install"
  find "$claude_config/plugins/cache/macroscope-local/macroscope" -type f -path '*/.claude-plugin/plugin.json' -print -quit | grep -q . || fail "custom Claude cache was not populated"
  [ -f "$claude_config/settings.json" ] || fail "custom Claude settings were not populated"
  [ -x "$claude_config/hooks/macroscope-bash-autoallow.sh" ] || fail "custom Claude hook was not populated"
  [ ! -e "$TEST_HOME/.claude" ] || fail "default Claude config was modified"

  cat > "$claude_config/.claude.json" <<'JSON'
{"mcpServers":{"macroscope-codereview":{"command":"macroscope"},"keep":{"command":"keep"}}}
JSON
  run_install --mode update --yes --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/remove"
  [ ! -e "$claude_config/plugins/cache/macroscope-local" ] || fail "custom Claude cache was not removed"
  [ ! -e "$claude_config/hooks/macroscope-bash-autoallow.sh" ] || fail "custom Claude hook was not removed"
  python3 - "$claude_config/.claude.json" <<'PY' || fail "custom Claude MCP state was not cleaned"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data = json.load(f)
assert data["mcpServers"] == {"keep": {"command": "keep"}}
PY
  unset TEST_CLAUDE_CONFIG_DIR
  pass "CLAUDE_CONFIG_DIR controls Claude install, cleanup, permissions, and hooks"
}

test_claude_cli_verifies_plugin_discovery() {
  new_home
  local claude_config="$TEST_HOME/team-claude"
  local fake_bin="$TEST_ROOT/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'SH'
#!/bin/sh
printf '%s|%s\n' "${CLAUDE_CONFIG_DIR:-}" "$*" >> "$TEST_CLAUDE_LOG"
if [ "${1:-} ${2:-} ${3:-}" = "plugin list --json" ]; then
  printf '[{"id":"macroscope@macroscope-local","enabled":true,"errors":[]}]\n'
  exit 0
fi
if [ "${1:-} ${2:-}" = "plugin details" ] && [ "${3:-}" = "macroscope@macroscope-local" ]; then
  printf 'Skills (2)\n'
  exit 0
fi
exit 2
SH
  chmod +x "$fake_bin/claude"
  TEST_CLAUDE_CONFIG_DIR="$claude_config"
  TEST_CLAUDE_LOG="$TEST_ROOT/claude.log"
  TEST_PATH="$fake_bin:/usr/bin:/bin"
  run_install --yes --tools claude --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  grep -Fq 'Claude Code CLI recognizes the enabled plugin and its components' "$TEST_ROOT/out" || fail "Claude plugin discovery was not verified"
  [ "$(grep -Fc "$claude_config|" "$TEST_CLAUDE_LOG")" -eq 2 ] || fail "Claude verification did not inherit CLAUDE_CONFIG_DIR"
  grep -Fq '|plugin list --json' "$TEST_CLAUDE_LOG" || fail "Claude plugin list was not called"
  grep -Fq '|plugin details macroscope@macroscope-local' "$TEST_CLAUDE_LOG" || fail "Claude plugin details was not called"
  unset TEST_CLAUDE_CONFIG_DIR TEST_CLAUDE_LOG TEST_PATH
  pass "Claude CLI verifies plugin discovery through the configured root"
}

test_opencode_config_dirs_are_honored() {
  new_home
  local opencode_config="$TEST_HOME/team-opencode"
  TEST_OPENCODE_CONFIG_DIR="$opencode_config"
  TEST_XDG_CONFIG_HOME="$TEST_HOME/ignored-xdg"
  run_install --yes --tools opencode --host-permissions grant --no-path --no-wizard >"$TEST_ROOT/install"
  [ -f "$opencode_config/plugins/macroscope.js" ] || fail "custom OpenCode plugin was not populated"
  [ -f "$opencode_config/commands/macroscope-codereview.md" ] || fail "custom OpenCode commands were not populated"
  grep -Fq '"macroscope *": "allow"' "$opencode_config/opencode.json" || fail "custom OpenCode permissions were not populated"
  [ ! -e "$TEST_HOME/.config/opencode" ] || fail "default OpenCode config was modified"
  [ ! -e "$TEST_HOME/ignored-xdg/opencode" ] || fail "XDG config overrode OPENCODE_CONFIG_DIR"
  run_install --mode update --yes --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/remove"
  [ ! -e "$opencode_config/plugins/macroscope.js" ] || fail "custom OpenCode plugin was not removed"
  [ ! -e "$opencode_config/skills/codereview" ] || fail "custom OpenCode skills were not removed"
  unset TEST_OPENCODE_CONFIG_DIR TEST_XDG_CONFIG_HOME

  new_home
  local xdg_config="$TEST_HOME/xdg"
  TEST_XDG_CONFIG_HOME="$xdg_config"
  run_install --yes --tools opencode --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/xdg-install"
  [ -f "$xdg_config/opencode/plugins/macroscope.js" ] || fail "XDG OpenCode plugin was not populated"
  [ ! -e "$TEST_HOME/.config/opencode" ] || fail "default OpenCode config was modified with XDG_CONFIG_HOME set"
  unset TEST_XDG_CONFIG_HOME
  pass "OpenCode honors OPENCODE_CONFIG_DIR and XDG_CONFIG_HOME"
}

test_interactive_update_repairs_empty_tool_selection() {
  new_home
  run_install --yes --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/initial"
  run_interactive_install "$TEST_ROOT/update" 0 \
    --no-path --no-wizard --events \
    "space to toggle="$'\n' \
    "Update and continue?="$'\n' || fail "interactive update did not complete"
  grep -Fq 'No Macroscope host integrations are currently selected.' "$TEST_ROOT/update" || fail "empty-selection warning was not shown"
  grep -Fq 'Up/down or j/k to move; space to toggle; enter to continue.' "$TEST_ROOT/update" || fail "integration multiselect instructions were not shown"
  ! grep -Fq 'comma-separated' "$TEST_ROOT/update" || fail "interactive update still requested free-text integrations"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "interactive update preserved an empty tool selection"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data = json.load(f)
assert data["tools"] == ["claude", "codex", "cursor", "opencode"]
PY
  pass "interactive updates reselect integrations instead of preserving a CLI-only trap"
}

test_interactive_lists_select_only_claude_and_permissions() {
  new_home
  run_interactive_install "$TEST_ROOT/install" 0 \
    --no-path --no-wizard --events \
    "space to toggle="$'\e[B \e[B \e[B \n' \
    "Grant these permissions?="$'\e[A\n' \
    "Proceed?="$'\n' || fail "interactive list selections did not complete"
  python3 - "$TEST_HOME/.local/state/macroscope/install.json" <<'PY' || fail "interactive choices were not persisted"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: data = json.load(f)
assert data["tools"] == ["claude"]
assert data["hostPermissions"] == "grant"
PY
  [ -d "$TEST_HOME/.claude/plugins/cache/macroscope-local" ] || fail "selected Claude integration was not installed"
  grep -Fq 'Bash(macroscope *)' "$TEST_HOME/.claude/settings.json" || fail "selected permission grant was not installed"
  [ -x "$TEST_HOME/.claude/hooks/macroscope-bash-autoallow.sh" ] || fail "selected Claude permission hook was not installed"
  [ ! -e "$TEST_HOME/plugins/macroscope" ] || fail "deselected Codex integration was installed"
  [ ! -e "$TEST_HOME/.cursor/plugins/local/macroscope" ] || fail "deselected Cursor integration was installed"
  [ ! -e "$TEST_HOME/.config/opencode/plugins/macroscope.js" ] || fail "deselected OpenCode integration was installed"
  pass "interactive lists select only Claude and grant host permissions with arrow keys"
}

test_interactive_confirmation_list_can_cancel() {
  new_home
  run_interactive_install "$TEST_ROOT/cancel" 3 \
    --tools none --host-permissions skip --no-path --no-wizard --events \
    "Proceed?="$'\e[B\n' || fail "interactive confirmation did not cancel"
  grep -Fq 'Up/down or j/k to move; enter to choose.' "$TEST_ROOT/cancel" || fail "confirmation list instructions were not shown"
  grep -Fq 'Cancelled before making changes.' "$TEST_ROOT/cancel" || fail "confirmation cancellation was not reported"
  [ ! -e "$TEST_HOME/.local/bin/macroscope" ] || fail "cancelled confirmation changed the install"
  pass "interactive confirmation uses a cancellable yes/no list"
}

test_interactive_interrupt_restores_terminal() {
  new_home
  run_interactive_install "$TEST_ROOT/interrupt" interrupt \
    --no-path --no-wizard --events \
    "space to toggle="$'\003' || fail "interactive interrupt did not exit cleanly"
  grep -Fq $'\033[?25h' "$TEST_ROOT/interrupt" || fail "interactive interrupt did not restore the cursor"
  [ ! -e "$TEST_HOME/.local/bin/macroscope" ] || fail "interrupted selection changed the install"
  pass "interactive interrupt restores the terminal before exiting"
}

test_interactive_confirmation_interrupt_restores_terminal() {
  new_home
  run_interactive_install "$TEST_ROOT/confirm-interrupt" interrupt \
    --tools none --host-permissions skip --no-path --no-wizard --events \
    "Proceed?"=$'\003' || fail "confirmation interrupt did not restore the terminal"
  grep -Fq $'\033[?25h' "$TEST_ROOT/confirm-interrupt" || fail "confirmation interrupt did not restore the cursor"
  [ ! -e "$TEST_HOME/.local/bin/macroscope" ] || fail "confirmation interrupt changed the install"
  pass "confirmation interrupt restores the terminal before exiting"
}

test_interactive_escape_does_not_block() {
  new_home
  run_interactive_install "$TEST_ROOT/escape" 0 \
    --no-path --no-wizard --events \
    "space to toggle="$'\e' \
    $'\e[4A'=$'\n' \
    "Grant these permissions?"=$'\n' \
    "Proceed?"=$'\n' || fail "standalone escape blocked the integration list"
  pass "standalone escape leaves the integration list responsive"
}

test_update_plan_omits_negative_actions() {
  new_home
  mkdir -p "$TEST_HOME/.local/bin" "$TEST_HOME/.macroscope"
  cp "$TEST_BINARY_DEFAULT" "$TEST_HOME/.local/bin/macroscope"
  printf 'api_url: test\n' > "$TEST_HOME/.macroscope/config.yaml"
  TEST_PATH="$TEST_HOME/.local/bin:/usr/bin:/bin"
  run_install --mode update --dry-run --tools none --host-permissions skip --no-wizard >"$TEST_ROOT/out"
  grep -Fq "1. Replace $TEST_HOME/.local/bin/macroscope" "$TEST_ROOT/out" || fail "update plan replacement is not first"
  grep -Fq "2. Keep PATH unchanged ($TEST_HOME/.local/bin is already active)" "$TEST_ROOT/out" || fail "update plan PATH action is not second"
  grep -Fq '3. Clean legacy Macroscope MCP artifacts after the update is staged' "$TEST_ROOT/out" || fail "update plan cleanup is not third"
  [ "$(grep -Ec '^[0-9]+\.' "$TEST_ROOT/out")" -eq 3 ] || fail "update plan did not collapse to three actions"
  ! grep -Fq 'Do not add host shell permission rules or hooks' "$TEST_ROOT/out" || fail "update plan still lists skipped permission automation"
  ! grep -Fq 'Do not launch the setup wizard' "$TEST_ROOT/out" || fail "update plan still lists skipped wizard launch"
  unset TEST_PATH
  pass "update plan lists only the three actions it performs"
}

test_plan_groups_selected_integration_installs() {
  new_home
  run_install --mode initial --dry-run --tools all --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/out"
  grep -Fq '3. Install or update the following plugins for claude, codex, cursor and opencode' "$TEST_ROOT/out" || fail "integration installs were not grouped into one numbered action"
  grep -Fq "   ($TEST_HOME/.claude/plugins/cache/macroscope-local/ and $TEST_HOME/.claude/settings.json)" "$TEST_ROOT/out" || fail "grouped Claude paths are incorrect"
  grep -Fq "   ($TEST_HOME/plugins/macroscope, $TEST_HOME/.codex/plugins/cache/, and $TEST_HOME/.codex/config.toml)" "$TEST_ROOT/out" || fail "grouped Codex paths are incorrect"
  grep -Fq "   ($TEST_HOME/.cursor/plugins/local/macroscope/)" "$TEST_ROOT/out" || fail "grouped Cursor path is incorrect"
  grep -Fq "   ($TEST_HOME/.config/opencode/)" "$TEST_ROOT/out" || fail "grouped OpenCode path is incorrect"
  grep -Fq "4. Seed local-build configuration at $TEST_HOME/.macroscope/config.yaml" "$TEST_ROOT/out" || fail "action after grouped integrations was not renumbered"
  [ "$(grep -Ec '^[0-9]+\. Install or update the .* plugin' "$TEST_ROOT/out")" -eq 1 ] || fail "integration installs still occupy multiple numbered actions"
  pass "plan groups selected integration installs into one action"
}

test_plan_uses_natural_lifecycle_labels() {
  new_home
  run_install --mode initial --dry-run --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/initial"
  grep -Fq 'Macroscope installation will:' "$TEST_ROOT/initial" || fail "initial plan uses an unnatural lifecycle label"
  ! grep -Fq 'Macroscope initial will:' "$TEST_ROOT/initial" || fail "initial plan still prints the old lifecycle label"
  run_install --mode update --dry-run --tools none --host-permissions skip --no-path --no-wizard >"$TEST_ROOT/update"
  grep -Fq 'Macroscope update will:' "$TEST_ROOT/update" || fail "update plan lifecycle label changed"
  pass "plan uses natural lifecycle labels"
}

test_wizard_lifecycle_plan() {
  new_home
  run_install --dry-run --tools none --host-permissions skip >"$TEST_ROOT/initial"
  grep -q 'Launch the setup wizard' "$TEST_ROOT/initial" || fail "initial plan does not launch wizard"
  mkdir -p "$TEST_HOME/.local/bin"
  cp /bin/echo "$TEST_HOME/.local/bin/macroscope"
  run_install --mode update --dry-run --tools none --host-permissions skip >"$TEST_ROOT/update"
  ! grep -q 'Launch the setup wizard' "$TEST_ROOT/update" || fail "update plan launches wizard"
  pass "wizard defaults to initial-only"
}

test_dry_run_is_read_only
test_empty_version_binary_is_rejected_before_apply
test_selected_tool_assets_are_validated_before_apply
test_existing_install_directory_mode_is_preserved
test_codex_wrapper_is_announced_in_plan
test_option_terminator_allows_dash_prefixed_version
test_invalid_state_falls_back_to_detected_tools
test_repair_cleans_claude_local_settings
test_repair_fails_closed_on_invalid_permission_ownership
test_legacy_cleanup_does_not_kill_regex_near_process
test_opencode_scalar_permissions_are_preserved
test_noninteractive_requires_consent
test_no_controlling_tty_requires_consent
test_zsh_touches_one_profile_and_selected_tool_only
test_initial_install_does_not_modify_unselected_existing_tool
test_active_path_skips_profiles
test_initial_defaults_to_all_tools
test_no_path_policy_survives_update
test_shell_config_override_is_exact
test_recorded_shell_target_preserves_its_syntax
test_legacy_path_policy_preserves_behavior
test_permissions_are_opt_in_and_owned
test_permission_updates_preserve_managed_symlinks
test_update_preserves_footprint_and_removes_deselected
test_legacy_update_preserves_unowned_permissions
test_legacy_explicit_skip_preserves_unowned_rules
test_empty_recorded_footprint_does_not_expand_from_stale_files
test_failure_rolls_back_binary
test_rollback_handles_tabbed_home_without_truncation
test_plugin_failure_rolls_back_all_touched_state
test_legacy_cleanup_failure_restores_claude_mcp_state
test_claude_config_dir_is_honored
test_claude_cli_verifies_plugin_discovery
test_opencode_config_dirs_are_honored
test_interactive_update_repairs_empty_tool_selection
test_interactive_lists_select_only_claude_and_permissions
test_interactive_confirmation_list_can_cancel
test_interactive_interrupt_restores_terminal
test_interactive_confirmation_interrupt_restores_terminal
test_interactive_escape_does_not_block
test_update_plan_omits_negative_actions
test_plan_groups_selected_integration_installs
test_plan_uses_natural_lifecycle_labels
test_wizard_lifecycle_plan

echo "All $PASS installer tests passed."
