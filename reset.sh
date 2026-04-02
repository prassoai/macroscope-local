#!/bin/bash
set -euo pipefail

# Macroscope Reset Script
# Cleanly removes the macroscope binary and app data,
# then re-installs from the latest release. Safe to run multiple times.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/reset.sh | bash
#   # or locally:
#   bash reset.sh
#
# Optional:
#   MACROSCOPE_SKIP_REINSTALL=1 bash reset.sh
#     -> remove Macroscope state without re-installing it

# Color codes (disabled if NO_COLOR is set or not a tty)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  GREEN='\033[0;32m'
  MAGENTA='\033[0;35m'
  RESET='\033[0m'
else
  BOLD='' DIM='' GREEN='' MAGENTA='' RESET=''
fi

info()    { printf "i %s\n" "$1"; }
success() { printf "${GREEN}✓${RESET} %s\n" "$1"; }
step()    { printf "\n${BOLD}${MAGENTA}→${RESET} ${BOLD}%s${RESET}\n" "$1"; }

CLI_BINARY="$HOME/.local/bin/macroscope"
CODEX_CLI_SHIM="$HOME/.local/bin/codex"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_PLUGIN_SOURCE_DIR="$HOME/plugins/macroscope"
CODEX_PLUGIN_LEGACY_DIR="$CODEX_HOME_DIR/plugins/macroscope"
CODEX_PLUGIN_CACHE_ROOT="$CODEX_HOME_DIR/plugins/cache"
CODEX_MARKETPLACE="$HOME/.agents/plugins/marketplace.json"
CLAUDE_MARKETPLACE_DIR="$HOME/.claude/plugins/marketplaces/macroscope-local"
CLAUDE_CACHE_DIR="$HOME/.claude/plugins/cache/macroscope-local"
CLAUDE_KNOWN_MARKETPLACES="$HOME/.claude/plugins/known_marketplaces.json"
CLAUDE_INSTALLED_PLUGINS="$HOME/.claude/plugins/installed_plugins.json"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_SETTINGS_LOCAL="$HOME/.claude/settings.local.json"
CURSOR_PLUGIN_DIR="$HOME/.cursor/plugins/local/macroscope"
OPENCODE_COMMANDS_DIR="$HOME/.config/opencode/commands"
OPENCODE_SKILLS_DIR="$HOME/.config/opencode/skills"
OPENCODE_PLUGINS_DIR="$HOME/.config/opencode/plugins"

echo ""
printf "${BOLD}Macroscope Reset${RESET}\n"
printf "${DIM}Removes all macroscope state and re-installs from latest release.${RESET}\n"
echo ""

# ─── Step 1: Remove binary ────────────────────────────────────────────────
step "Removing binary..."

if [ -f "$CLI_BINARY" ]; then
  rm -f "$CLI_BINARY"
  success "Removed $CLI_BINARY"
else
  info "Not found: $CLI_BINARY (already clean)"
fi

if [ -f "$CODEX_CLI_SHIM" ] && grep -Fq "Macroscope-managed Codex shim" "$CODEX_CLI_SHIM"; then
  rm -f "$CODEX_CLI_SHIM"
  success "Removed $CODEX_CLI_SHIM"
else
  info "No managed Codex CLI shim to remove"
fi

# ─── Step 2: Remove macroscope app data ──────────────────────────────────
step "Removing macroscope app data..."

MACROSCOPE_DIR="$HOME/.macroscope"
if [ -d "$MACROSCOPE_DIR" ]; then
  rm -rf "$MACROSCOPE_DIR"
  success "Removed $MACROSCOPE_DIR"
else
  info "No ~/.macroscope directory to remove"
fi

# ─── Step 3: Remove Codex + Claude plugin state ──────────────────────────
step "Removing plugin state..."

if [ -d "$CODEX_PLUGIN_SOURCE_DIR" ]; then
  rm -rf "$CODEX_PLUGIN_SOURCE_DIR"
  success "Removed $CODEX_PLUGIN_SOURCE_DIR"
else
  info "No Codex plugin source directory to remove"
fi

if [ -d "$CODEX_PLUGIN_LEGACY_DIR" ]; then
  rm -rf "$CODEX_PLUGIN_LEGACY_DIR"
  success "Removed $CODEX_PLUGIN_LEGACY_DIR"
else
  info "No legacy Codex plugin directory to remove"
fi

if [ -d "$CODEX_PLUGIN_CACHE_ROOT" ]; then
  find "$CODEX_PLUGIN_CACHE_ROOT" -mindepth 2 -maxdepth 2 -type d -name macroscope -print0 2>/dev/null | while IFS= read -r -d '' dir; do
    rm -rf "$dir"
    success "Removed $dir"
  done
else
  info "No Codex plugin cache directory to clean"
fi

if [ -d "$CLAUDE_MARKETPLACE_DIR" ]; then
  rm -rf "$CLAUDE_MARKETPLACE_DIR"
  success "Removed $CLAUDE_MARKETPLACE_DIR"
else
  info "No Claude marketplace directory to remove"
fi

if [ -d "$CLAUDE_CACHE_DIR" ]; then
  rm -rf "$CLAUDE_CACHE_DIR"
  success "Removed $CLAUDE_CACHE_DIR"
else
  info "No Claude cache directory to remove"
fi

if [ -d "$CURSOR_PLUGIN_DIR" ]; then
  rm -rf "$CURSOR_PLUGIN_DIR"
  success "Removed $CURSOR_PLUGIN_DIR"
else
  info "No Cursor plugin directory to remove"
fi

for file in \
  "$OPENCODE_PLUGINS_DIR/macroscope.js" \
  "$OPENCODE_COMMANDS_DIR/macroscope.md" \
  "$OPENCODE_COMMANDS_DIR/local-review.md" \
  "$OPENCODE_COMMANDS_DIR/triage-pr-comments.md" \
  "$OPENCODE_COMMANDS_DIR/respond-to-pr-comments.md" \
  "$OPENCODE_COMMANDS_DIR/review-pr.md"
do
  if [ -f "$file" ]; then
    rm -f "$file"
    success "Removed $file"
  fi
done

for dir in \
  "$OPENCODE_SKILLS_DIR/macroscope" \
  "$OPENCODE_SKILLS_DIR/local-review" \
  "$OPENCODE_SKILLS_DIR/triage-pr-comments" \
  "$OPENCODE_SKILLS_DIR/respond-to-pr-comments" \
  "$OPENCODE_SKILLS_DIR/review-pr"
do
  if [ -d "$dir" ]; then
    rm -rf "$dir"
    success "Removed $dir"
  fi
done

python3 - <<'PY'
import json
import os

targets = [
    (os.path.expanduser("~/.agents/plugins/marketplace.json"), "plugins", "macroscope", "name"),
    (os.path.expanduser("~/.claude/plugins/known_marketplaces.json"), None, "macroscope-local", None),
]

for path, list_key, target, key_name in targets:
    if not os.path.exists(path):
        continue
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    changed = False
    if list_key is None:
        if target in data:
            del data[target]
            changed = True
    else:
        items = data.get(list_key, [])
        filtered = [item for item in items if item.get(key_name) != target]
        if len(filtered) != len(items):
            data[list_key] = filtered
            changed = True
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
PY

python3 - <<'PY'
import os
import re

path = os.path.expanduser(os.environ.get("CODEX_HOME", "~/.codex") + "/config.toml")
if not os.path.exists(path):
    raise SystemExit(0)

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

new_text = re.sub(
    r'(?ms)^\[plugins\."macroscope@[^"]+"\]\n.*?(?=^\[|\Z)',
    '',
    text,
)

if new_text != text:
    new_text = re.sub(r'\n{3,}', '\n\n', new_text).rstrip() + '\n'
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)
PY

python3 - <<'PY'
import json
import os

path = os.path.expanduser("~/.claude/plugins/installed_plugins.json")
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    plugins = data.get("plugins", {})
    if "macroscope@macroscope-local" in plugins:
        del plugins["macroscope@macroscope-local"]
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
PY

python3 - <<'PY'
import json
import os

for path in (
    os.path.expanduser("~/.claude/settings.json"),
    os.path.expanduser("~/.claude/settings.local.json"),
):
    if not os.path.exists(path):
        continue

    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    changed = False

    extra = data.get("extraKnownMarketplaces")
    if isinstance(extra, dict) and "macroscope-local" in extra:
        del extra["macroscope-local"]
        changed = True
        if not extra:
            del data["extraKnownMarketplaces"]

    enabled = data.get("enabledPlugins")
    if isinstance(enabled, dict) and "macroscope@macroscope-local" in enabled:
        del enabled["macroscope@macroscope-local"]
        changed = True
        if not enabled:
            del data["enabledPlugins"]

    if changed:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
PY

if [ "${MACROSCOPE_SKIP_REINSTALL:-0}" = "1" ]; then
  step "Skipping re-install..."
  info "Removal complete. Reinstall manually when you're ready."
else
  # ─── Step 4: Re-install from latest release ────────────────────────────
  step "Re-installing from latest release..."
  echo ""

  curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
fi

echo ""
printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
printf "${GREEN}${BOLD}Reset Complete!${RESET}\n"
printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
echo ""
