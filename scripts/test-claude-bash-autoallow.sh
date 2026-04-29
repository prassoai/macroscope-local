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

TMP_ROOT="$(mktemp -d /tmp/macroscope-hook-test.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

HOME_DIR="$TMP_ROOT/home"
BUNDLE_DIR="$TMP_ROOT/bundle"
RUN_DIR="$TMP_ROOT/run"
SHIM_DIR="$TMP_ROOT/shims"
FAKE_BIN="$TMP_ROOT/macroscope"
INSTALL_LOG="$TMP_ROOT/install.log"

mkdir -p "$HOME_DIR" "$BUNDLE_DIR" "$RUN_DIR" "$SHIM_DIR"
cp -R "$REPO_ROOT/.claude-plugin" "$BUNDLE_DIR/.claude-plugin"
cp -R "$REPO_ROOT/plugins" "$BUNDLE_DIR/plugins"

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

(
  cd "$RUN_DIR"
  env \
    HOME="$HOME_DIR" \
    CODEX_HOME="$HOME_DIR/.codex" \
    MACROSCOPE_SKIP_WIZARD=1 \
    MACROSCOPE_LOCAL_BINARY_SOURCE="$FAKE_BIN" \
    MACROSCOPE_PLUGIN_BUNDLE_SOURCE="$BUNDLE_DIR" \
    PATH="$SHIM_DIR:$PATH" \
    bash < "$REPO_ROOT/install.sh" > "$INSTALL_LOG" 2>&1
)

validate_hook "$HOME_DIR/.claude/hooks/macroscope-bash-autoallow.sh" "installer embedded hook"

if ! grep -q "Installed Claude Code plugin" "$INSTALL_LOG"; then
  echo "installer did not reach Claude Code plugin install" >&2
  tail -n 80 "$INSTALL_LOG" >&2
  exit 1
fi
