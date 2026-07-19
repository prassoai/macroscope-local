#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"macroscope codereview --base review-in-place"}}'

validate_hook() {
  local hook_path="$1"
  local label="$2"
  local output=""

  output="$(printf '%s' "$PAYLOAD" | python3 "$hook_path")"
  python3 - "$label" "$output" <<'PY'
import json
import sys

label, output = sys.argv[1:3]
data = json.loads(output)
hook_output = data.get("hookSpecificOutput", {})

assert hook_output.get("hookEventName") == "PreToolUse", (
    f"{label}: missing hookSpecificOutput.hookEventName=PreToolUse"
)
assert hook_output.get("permissionDecision") == "allow", (
    f"{label}: missing permissionDecision=allow"
)

print(f"ok: {label} emits PreToolUse allow decision")
PY
}

assert_codex_codereview_wait_recipe() {
  local skill_path="$1"
  local label="$2"

  python3 - "$skill_path" "$label" <<'PY'
import re
import sys

skill_path, label = sys.argv[1:3]
with open(skill_path, "r", encoding="utf-8") as f:
    text = f.read()

launch_blocks = [
    block
    for block in re.findall(r"```bash\n(.*?)\n```", text, re.DOTALL)
    if "macroscope codereview" in block and '"$review_log"' in block
]

assert len(launch_blocks) == 3, (
    f"{label}: expected three Codex codereview launch recipes, "
    f"found {len(launch_blocks)}"
)

expected_tail = [
    "child_pid=$!",
    "printf '%s\\n' \"$child_pid\" > \"$pid_file\"",
    "wait \"$child_pid\"",
]
for block in launch_blocks:
    lines = block.splitlines()
    assert lines[0].endswith("&"), f"{label}: review is not backgrounded: {lines[0]}"
    assert lines[-3:] == expected_tail, (
        f"{label}: launch recipe does not retain its shell through child completion: {block}"
    )

assert '& echo $! > "$pid_file"' not in text, (
    f"{label}: vulnerable launch recipe still exits immediately after recording the PID"
)

print(f"ok: {label} keeps Codex review launch shells alive")
PY
}

TMP_ROOT="$(mktemp -d /tmp/macroscope-hook-test.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

HOME_DIR="$TMP_ROOT/home"
RUN_DIR="$TMP_ROOT/run"
SHIM_DIR="$TMP_ROOT/shims"
FAKE_BIN="$TMP_ROOT/macroscope"
INSTALL_LOG="$TMP_ROOT/install.log"
LOCAL_BACK_REPO="${MACROSCOPE_TEST_BACK_REPO:-}"

if [ -n "$LOCAL_BACK_REPO" ]; then
  BUNDLE_DIR="$LOCAL_BACK_REPO/tools/cmd/macrodaemon/public-plugin"
  PLUGIN_SOURCE_ENV=("MACROSCOPE_LOCAL_BACK_REPO=$LOCAL_BACK_REPO")
else
  BUNDLE_DIR="$TMP_ROOT/bundle"
  PLUGIN_SOURCE_ENV=("MACROSCOPE_PLUGIN_BUNDLE_SOURCE=$BUNDLE_DIR")
fi

mkdir -p "$HOME_DIR" "$BUNDLE_DIR" "$RUN_DIR" "$SHIM_DIR"
if [ -z "$LOCAL_BACK_REPO" ]; then
  cp -R "$REPO_ROOT/.claude-plugin" "$BUNDLE_DIR/.claude-plugin"
  cp -R "$REPO_ROOT/plugins" "$BUNDLE_DIR/plugins"
fi

cat > "$FAKE_BIN" <<'SH'
#!/usr/bin/env bash
echo "fake macroscope"
SH
chmod +x "$FAKE_BIN"

cat > "$SHIM_DIR/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$SHIM_DIR/pgrep"

cat > "$SHIM_DIR/pkill" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$SHIM_DIR/pkill"

for name in claude cursor gemini codex; do
  cat > "$SHIM_DIR/$name" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$SHIM_DIR/$name"
done

cat > "$SHIM_DIR/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    /usr/local/bin/macroscope*|/opt/homebrew/bin/macroscope*)
      echo "blocked test rm of $arg" >&2
      exit 1
      ;;
  esac
done
exec /bin/rm "$@"
SH
chmod +x "$SHIM_DIR/rm"

validate_hook "$REPO_ROOT/scripts/claude-bash-autoallow.sh" "standalone hook"
assert_codex_codereview_wait_recipe \
  "$REPO_ROOT/plugins/macroscope/host-overlays/codex/skills/codereview/SKILL.md" \
  "release snapshot"

(
  cd "$RUN_DIR"
  env \
    HOME="$HOME_DIR" \
    CODEX_HOME="$HOME_DIR/.codex" \
    MACROSCOPE_SKIP_WIZARD=1 \
    MACROSCOPE_LOCAL_BINARY_SOURCE="$FAKE_BIN" \
    "${PLUGIN_SOURCE_ENV[@]}" \
    PATH="$SHIM_DIR:$PATH" \
    bash -s -- --yes --host-permissions grant < "$REPO_ROOT/install.sh" > "$INSTALL_LOG" 2>&1
)

validate_hook "$HOME_DIR/.claude/hooks/macroscope-bash-autoallow.sh" "installer embedded hook"

if ! grep -q "Installed Claude Code plugin" "$INSTALL_LOG"; then
  echo "installer did not reach Claude Code plugin install" >&2
  tail -n 80 "$INSTALL_LOG" >&2
  exit 1
fi

if ! grep -q "Claude Code plugin installed with skills" "$INSTALL_LOG"; then
  echo "installer did not verify the Claude Code plugin skills" >&2
  tail -n 80 "$INSTALL_LOG" >&2
  exit 1
fi

PLUGIN_VERSION="$(python3 - "$BUNDLE_DIR/plugins/macroscope/.claude-plugin/plugin.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f)["version"])
PY
)"

CLAUDE_SOURCE="$HOME_DIR/.claude/plugins/marketplaces/macroscope-local/plugins/macroscope"
CLAUDE_CACHE="$HOME_DIR/.claude/plugins/cache/macroscope-local/macroscope/$PLUGIN_VERSION"
CODEX_SOURCE="$HOME_DIR/plugins/macroscope"
CODEX_CACHE="$HOME_DIR/.codex/plugins/cache/local-user-plugins/macroscope/local"

for dst in "$CLAUDE_SOURCE" "$CLAUDE_CACHE"; do
  cmp "$BUNDLE_DIR/plugins/macroscope/host-overlays/claude/skills/codereview/SKILL.md" "$dst/skills/codereview/SKILL.md"
  cmp "$BUNDLE_DIR/plugins/macroscope/host-overlays/claude/skills/autoloop/SKILL.md" "$dst/skills/autoloop/SKILL.md"
  if [ -d "$dst/host-overlays" ]; then
    echo "Claude Code install retained host overlays in $dst" >&2
    exit 1
  fi
done

for dst in "$CODEX_SOURCE" "$CODEX_CACHE"; do
  cmp "$BUNDLE_DIR/plugins/macroscope/host-overlays/codex/skills/codereview/SKILL.md" "$dst/skills/codereview/SKILL.md"
  cmp "$BUNDLE_DIR/plugins/macroscope/host-overlays/codex/skills/autoloop/SKILL.md" "$dst/skills/autoloop/SKILL.md"
  assert_codex_codereview_wait_recipe "$dst/skills/codereview/SKILL.md" "installed overlay at $dst"
  if [ -d "$dst/host-overlays" ]; then
    echo "Codex install retained host overlays in $dst" >&2
    exit 1
  fi
done

echo "ok: installer applies Claude and Codex host overlays"
