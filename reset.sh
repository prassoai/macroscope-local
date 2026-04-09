#!/bin/bash
set -euo pipefail

# Macroscope Reset Script
# Cleanly removes Macroscope binaries, config, credentials, plugin state,
# and legacy MCP registrations, then optionally re-installs from the latest
# release. Safe to run multiple times.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/reset.sh | bash
#   # or locally:
#   bash reset.sh
#
# Optional:
#   MACROSCOPE_SKIP_REINSTALL=1 bash reset.sh
#     -> remove Macroscope state without re-installing it

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  MAGENTA='\033[0;35m'
  RESET='\033[0m'
else
  BOLD='' DIM='' GREEN='' YELLOW='' MAGENTA='' RESET=''
fi

info()    { printf "i %s\n" "$1"; }
success() { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn()    { printf "${YELLOW}!${RESET} %s\n" "$1"; }
step()    { printf "\n${BOLD}${MAGENTA}->${RESET} ${BOLD}%s${RESET}\n" "$1"; }

CLI_BINARY="$HOME/.local/bin/macroscope"
CLI_OLD_BINARY="$HOME/.local/bin/macroscope.old"
MCP_BINARY="$HOME/.local/bin/macroscope-mcp"
CODEX_CLI_SHIM="$HOME/.local/bin/codex"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_PLUGIN_SOURCE_DIR="$HOME/plugins/macroscope"
CODEX_PLUGIN_SOURCE_LEGACY_DIR="$HOME/plugins/macroscope-codereview"
CODEX_PLUGIN_LEGACY_DIR="$CODEX_HOME_DIR/plugins/macroscope"
CODEX_PLUGIN_LEGACY_MCP_DIR="$CODEX_HOME_DIR/plugins/macroscope-codereview"
CODEX_PLUGIN_CACHE_ROOT="$CODEX_HOME_DIR/plugins/cache"
CODEX_CONFIG="$CODEX_HOME_DIR/config.toml"
CODEX_MARKETPLACE="$HOME/.agents/plugins/marketplace.json"
CLAUDE_JSON="$HOME/.claude.json"
CLAUDE_PLUGIN_ROOT="$HOME/.claude/plugins"
CLAUDE_MARKETPLACE_DIR="$CLAUDE_PLUGIN_ROOT/marketplaces/macroscope-local"
CLAUDE_CACHE_DIR="$CLAUDE_PLUGIN_ROOT/cache/macroscope-local"
CLAUDE_KNOWN_MARKETPLACES="$CLAUDE_PLUGIN_ROOT/known_marketplaces.json"
CLAUDE_INSTALLED_PLUGINS="$CLAUDE_PLUGIN_ROOT/installed_plugins.json"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_SETTINGS_LOCAL="$HOME/.claude/settings.local.json"
CURSOR_PLUGIN_DIR="$HOME/.cursor/plugins/local/macroscope"
CURSOR_PLUGIN_LEGACY_DIR="$HOME/.cursor/plugins/local/macroscope-codereview"
CURSOR_MCP_JSON="$HOME/.cursor/mcp.json"
OPENCODE_ROOT="$HOME/.config/opencode"
OPENCODE_COMMANDS_DIR="$OPENCODE_ROOT/commands"
OPENCODE_SKILLS_DIR="$OPENCODE_ROOT/skills"
OPENCODE_PLUGINS_DIR="$OPENCODE_ROOT/plugins"
MACROSCOPE_DIR="$HOME/.macroscope"
LEGACY_LOG="$HOME/.macroscope.log"

remove_file_if_present() {
  local path="$1"
  if [ -f "$path" ]; then
    rm -f "$path"
    success "Removed $path"
    return 0
  fi
  return 1
}

remove_dir_if_present() {
  local path="$1"
  if [ -d "$path" ]; then
    rm -rf "$path"
    success "Removed $path"
    return 0
  fi
  return 1
}

kill_running_processes() {
  step "Stopping running Macroscope processes..."

  local found=0
  local name=""
  local pids=""
  local pid=""
  local deadline=""

  for name in macroscope macroscope-mcp; do
    pids="$(pgrep -x "$name" 2>/dev/null || true)"
    [ -n "$pids" ] || continue
    found=1

    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill "$pid" 2>/dev/null || true
    done <<< "$pids"

    deadline=$((SECONDS + 3))
    while pgrep -x "$name" >/dev/null 2>&1 && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.1
    done

    if pgrep -x "$name" >/dev/null 2>&1; then
      pkill -9 -x "$name" 2>/dev/null || true
      sleep 0.2
    fi

    if pgrep -x "$name" >/dev/null 2>&1; then
      warn "$name is still running"
    else
      success "Stopped $name"
    fi
  done

  if [ "$found" -eq 0 ]; then
    info "No running macroscope processes found"
  fi
}

remove_binaries() {
  step "Removing binaries..."

  local removed=0
  local path=""

  for path in \
    "$CLI_BINARY" \
    "$CLI_OLD_BINARY" \
    "$MCP_BINARY" \
    "$HOME/go/bin/macroscope" \
    "$HOME/go/bin/macroscope.old" \
    "$HOME/go/bin/macroscope-mcp" \
    "/usr/local/bin/macroscope" \
    "/usr/local/bin/macroscope-mcp" \
    "/opt/homebrew/bin/macroscope" \
    "/opt/homebrew/bin/macroscope-mcp"
  do
    if remove_file_if_present "$path"; then
      removed=1
    fi
  done

  for pattern in \
    "$HOME/.local/bin/macroscope-"* \
    "$HOME/.local/bin/macroscope-update-"* \
    "$HOME/go/bin/macroscope-"* \
    "$HOME/go/bin/macroscope-update-"*
  do
    [ -e "$pattern" ] || continue
    rm -f "$pattern"
    success "Removed $pattern"
    removed=1
  done

  if [ -f "$CODEX_CLI_SHIM" ] && grep -Fq "Macroscope-managed Codex shim" "$CODEX_CLI_SHIM"; then
    rm -f "$CODEX_CLI_SHIM"
    success "Removed $CODEX_CLI_SHIM"
    removed=1
  else
    info "No managed Codex CLI shim to remove"
  fi

  if [ "$removed" -eq 0 ]; then
    info "No Macroscope binaries found"
  fi
}

remove_config_and_logs() {
  step "Removing Macroscope config and logs..."

  local removed=0
  local cfg=""
  local current=""
  local parent=""
  local search_root=""

  if remove_dir_if_present "$MACROSCOPE_DIR"; then
    removed=1
  else
    info "No ~/.macroscope directory to remove"
  fi

  if remove_file_if_present "$LEGACY_LOG"; then
    removed=1
  fi

  cfg="$HOME/.macroscope.yaml"
  if remove_file_if_present "$cfg"; then
    removed=1
  fi

  cfg="$HOME/Documents/.macroscope.yaml"
  if remove_file_if_present "$cfg"; then
    removed=1
  fi

  current="$PWD"
  while :; do
    cfg="$current/.macroscope.yaml"
    if [ -f "$cfg" ]; then
      rm -f "$cfg"
      success "Removed $cfg"
      removed=1
    fi

    parent="$(dirname "$current")"
    if [ "$parent" = "$current" ]; then
      break
    fi
    current="$parent"
  done

  for search_root in "$HOME/Documents/GitHub" "$CODEX_HOME_DIR"; do
    [ -d "$search_root" ] || continue
    while IFS= read -r -d '' cfg; do
      rm -f "$cfg"
      success "Removed $cfg"
      removed=1
    done < <(
      find "$search_root" -maxdepth 6 -name ".macroscope.yaml" \
        -not -path "*/node_modules/*" \
        -not -path "*/.git/*" \
        -print0 2>/dev/null || true
    )
  done

  if [ "$removed" -eq 0 ]; then
    info "No Macroscope config or log files found"
  fi
}

clean_shell_config() {
  local path="$1"
  [ -f "$path" ] || return 1

  if python3 - "$path" <<'PY'
import os
import sys

path = os.path.expanduser(sys.argv[1])
with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

out = []
modified = False
i = 0
while i < len(lines):
    if lines[i].strip() == "# Added by Macroscope installer":
        modified = True
        if out and out[-1].strip() == "":
            out.pop()
        i += 1
        if i < len(lines):
            i += 1
        continue
    out.append(lines[i])
    i += 1

while out and out[-1].strip() == "":
    out.pop()

if not modified:
    raise SystemExit(1)

payload = "\n".join(out)
if payload:
    payload += "\n"

st = os.stat(path)
with open(path, "w", encoding="utf-8") as f:
    f.write(payload)
os.chmod(path, st.st_mode)
PY
  then
    success "Cleaned PATH from $path"
    return 0
  fi

  return 1
}

clean_shell_configs() {
  step "Cleaning shell PATH entries..."

  local cleaned=0
  local path=""

  for path in \
    "$HOME/.bashrc" \
    "$HOME/.bash_profile" \
    "$HOME/.profile" \
    "$HOME/.zshrc" \
    "$HOME/.zprofile" \
    "$HOME/.config/fish/config.fish"
  do
    if clean_shell_config "$path"; then
      cleaned=1
    fi
  done

  if [ "$cleaned" -eq 0 ]; then
    info "No Macroscope PATH entries found"
  fi
}

wipe_keychain_credentials() {
  step "Removing saved credentials..."

  if ! command -v security >/dev/null 2>&1; then
    info "macOS keychain CLI not available; skipping"
    return
  fi

  local removed=0
  local service=""

  for service in "macroscope.com" "macroscope.com/prod" "macroscope.com/nonprod" "macroscope.com/local"; do
    while security delete-generic-password -s "$service" >/dev/null 2>&1; do
      success "Removed keychain entry: $service"
      removed=1
    done
  done

  if [ "$removed" -eq 0 ]; then
    info "No saved Macroscope credentials found"
  fi
}

remove_plugin_directories() {
  local removed=0
  local dir=""
  local file=""

  for dir in \
    "$CODEX_PLUGIN_SOURCE_DIR" \
    "$CODEX_PLUGIN_SOURCE_LEGACY_DIR" \
    "$CODEX_PLUGIN_LEGACY_DIR" \
    "$CODEX_PLUGIN_LEGACY_MCP_DIR" \
    "$CLAUDE_MARKETPLACE_DIR" \
    "$CLAUDE_CACHE_DIR" \
    "$CURSOR_PLUGIN_DIR" \
    "$CURSOR_PLUGIN_LEGACY_DIR" \
    "$OPENCODE_SKILLS_DIR/macroscope" \
    "$OPENCODE_SKILLS_DIR/macroscope-local-review" \
    "$OPENCODE_SKILLS_DIR/macroscope-triage-pr-comments" \
    "$OPENCODE_SKILLS_DIR/macroscope-respond-to-pr-comments" \
    "$OPENCODE_SKILLS_DIR/macroscope-review-pr" \
    "$OPENCODE_SKILLS_DIR/local-review" \
    "$OPENCODE_SKILLS_DIR/triage-pr-comments" \
    "$OPENCODE_SKILLS_DIR/respond-to-pr-comments" \
    "$OPENCODE_SKILLS_DIR/review-pr"
  do
    if remove_dir_if_present "$dir"; then
      removed=1
    fi
  done

  if [ -d "$CODEX_PLUGIN_CACHE_ROOT" ]; then
    while IFS= read -r -d '' dir; do
      rm -rf "$dir"
      success "Removed $dir"
      removed=1
    done < <(
      find "$CODEX_PLUGIN_CACHE_ROOT" -mindepth 2 -maxdepth 4 \
        \( -type d -o -type f \) \
        \( -iname "macroscope" -o -iname "macroscope-*" -o -iname "*macroscope*" \) \
        -print0 2>/dev/null || true
    )
  fi

  if [ -d "$CLAUDE_PLUGIN_ROOT" ]; then
    while IFS= read -r -d '' dir; do
      rm -rf "$dir"
      success "Removed $dir"
      removed=1
    done < <(
      find "$CLAUDE_PLUGIN_ROOT" -mindepth 1 -maxdepth 4 -type d -iname "*macroscope*" \
        -print0 2>/dev/null || true
    )
  fi

  for file in \
    "$OPENCODE_PLUGINS_DIR/macroscope.js" \
    "$OPENCODE_COMMANDS_DIR/macroscope.md" \
    "$OPENCODE_COMMANDS_DIR/macroscope-local-review.md" \
    "$OPENCODE_COMMANDS_DIR/macroscope-triage-pr-comments.md" \
    "$OPENCODE_COMMANDS_DIR/macroscope-respond-to-pr-comments.md" \
    "$OPENCODE_COMMANDS_DIR/macroscope-review-pr.md" \
    "$OPENCODE_COMMANDS_DIR/local-review.md" \
    "$OPENCODE_COMMANDS_DIR/triage-pr-comments.md" \
    "$OPENCODE_COMMANDS_DIR/respond-to-pr-comments.md" \
    "$OPENCODE_COMMANDS_DIR/review-pr.md"
  do
    if remove_file_if_present "$file"; then
      removed=1
    fi
  done

  if [ "$removed" -eq 0 ]; then
    info "No plugin directories or command files found"
  fi
}

clean_json_and_toml_state() {
  python3 - \
    "$CODEX_MARKETPLACE" \
    "$CODEX_CONFIG" \
    "$CLAUDE_JSON" \
    "$CLAUDE_KNOWN_MARKETPLACES" \
    "$CLAUDE_INSTALLED_PLUGINS" \
    "$CLAUDE_SETTINGS" \
    "$CLAUDE_SETTINGS_LOCAL" \
    "$CURSOR_MCP_JSON" <<'PY'
import json
import os
import re
import sys

(
    codex_marketplace,
    codex_config,
    claude_json,
    claude_known_marketplaces,
    claude_installed_plugins,
    claude_settings,
    claude_settings_local,
    cursor_mcp_json,
) = sys.argv[1:9]


def contains_macroscope(value):
    return isinstance(value, str) and "macroscope" in value.lower()


def scrub_macroscope(value):
    if isinstance(value, dict):
        changed = False
        result = {}
        for key, item in value.items():
            if contains_macroscope(key):
                changed = True
                continue
            new_item, item_changed = scrub_macroscope(item)
            if item_changed:
                changed = True
            result[key] = new_item
        return result, changed

    if isinstance(value, list):
        changed = False
        result = []
        for item in value:
            if contains_macroscope(item):
                changed = True
                continue
            new_item, item_changed = scrub_macroscope(item)
            if item_changed:
                changed = True
            result.append(new_item)
        return result, changed

    return value, False


def load_json(path, default):
    if not os.path.exists(path):
        return None, None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f), os.stat(path).st_mode
    except Exception:
        return None, None


def write_json(path, data, mode):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    if mode is not None:
        os.chmod(path, mode)


marketplace_data, marketplace_mode = load_json(codex_marketplace, None)
if isinstance(marketplace_data, dict):
    plugins = marketplace_data.get("plugins")
    if isinstance(plugins, list):
        filtered = []
        for item in plugins:
            if not isinstance(item, dict):
                filtered.append(item)
                continue
            name = item.get("name")
            source = item.get("source")
            source_path = source.get("path") if isinstance(source, dict) else None
            if contains_macroscope(name) or contains_macroscope(source_path):
                continue
            filtered.append(item)
        if filtered != plugins:
            marketplace_data["plugins"] = filtered
            write_json(codex_marketplace, marketplace_data, marketplace_mode)


if os.path.exists(codex_config):
    mode = os.stat(codex_config).st_mode
    with open(codex_config, "r", encoding="utf-8") as f:
        text = f.read()

    new_text = re.sub(r'(?ms)^\[plugins\."[^"]*macroscope[^"]*"\]\n.*?(?=^\[|\Z)', "", text)
    new_text = re.sub(r'(?ms)^\[mcp_servers\.macroscope-codereview\]\n.*?(?=^\[|\Z)', "", new_text)
    new_text = re.sub(r'(?m)^# Added by Macroscope installer\n?', "", new_text)
    new_text = re.sub(r'\n{3,}', '\n\n', new_text).strip()
    if new_text:
        new_text += "\n"

    if new_text != text:
        with open(codex_config, "w", encoding="utf-8") as f:
            f.write(new_text)
        os.chmod(codex_config, mode)


claude_data, claude_mode = load_json(claude_json, None)
if isinstance(claude_data, dict):
    changed = False

    servers = claude_data.get("mcpServers")
    if isinstance(servers, dict):
      to_delete = [key for key in servers if contains_macroscope(key)]
      for key in to_delete:
          del servers[key]
          changed = True

    projects = claude_data.get("projects")
    if isinstance(projects, dict):
        for project in projects.values():
            if not isinstance(project, dict):
                continue
            project_servers = project.get("mcpServers")
            if isinstance(project_servers, dict):
                to_delete = [key for key in project_servers if contains_macroscope(key)]
                for key in to_delete:
                    del project_servers[key]
                    changed = True

    claude_data, scrubbed = scrub_macroscope(claude_data)
    if scrubbed:
        changed = True

    if changed:
        write_json(claude_json, claude_data, claude_mode)


known_marketplaces_data, known_marketplaces_mode = load_json(claude_known_marketplaces, None)
if isinstance(known_marketplaces_data, dict):
    to_delete = [key for key in known_marketplaces_data if contains_macroscope(key)]
    if to_delete:
        for key in to_delete:
            del known_marketplaces_data[key]
        write_json(claude_known_marketplaces, known_marketplaces_data, known_marketplaces_mode)


installed_plugins_data, installed_plugins_mode = load_json(claude_installed_plugins, None)
if isinstance(installed_plugins_data, dict):
    plugins = installed_plugins_data.get("plugins")
    if isinstance(plugins, dict):
        to_delete = [key for key in plugins if contains_macroscope(key)]
        if to_delete:
            for key in to_delete:
                del plugins[key]
            write_json(claude_installed_plugins, installed_plugins_data, installed_plugins_mode)


for path in (claude_settings, claude_settings_local):
    data, mode = load_json(path, None)
    if not isinstance(data, dict):
        continue

    changed = False

    extra = data.get("extraKnownMarketplaces")
    if isinstance(extra, dict):
        to_delete = [key for key in extra if contains_macroscope(key)]
        for key in to_delete:
            del extra[key]
            changed = True
        if not extra:
            data.pop("extraKnownMarketplaces", None)

    enabled = data.get("enabledPlugins")
    if isinstance(enabled, dict):
        to_delete = [key for key in enabled if contains_macroscope(key)]
        for key in to_delete:
            del enabled[key]
            changed = True
        if not enabled:
            data.pop("enabledPlugins", None)

    data, scrubbed = scrub_macroscope(data)
    if scrubbed:
        changed = True

    if changed:
        write_json(path, data, mode)


cursor_data, cursor_mode = load_json(cursor_mcp_json, None)
if isinstance(cursor_data, dict):
    servers = cursor_data.get("mcpServers")
    if isinstance(servers, dict):
        to_delete = [key for key in servers if contains_macroscope(key)]
        if to_delete:
            for key in to_delete:
                del servers[key]
            write_json(cursor_mcp_json, cursor_data, cursor_mode)
PY
}

remove_legacy_mcp_registrations() {
  step "Removing plugin and MCP registrations..."

  remove_plugin_directories

  clean_json_and_toml_state
  success "Cleaned Codex, Claude Code, and Cursor registration files"

  if command -v claude >/dev/null 2>&1; then
    if claude mcp remove macroscope-codereview -s user >/dev/null 2>&1; then
      success "Removed legacy Claude Code MCP registration"
    fi
  fi

  if command -v gemini >/dev/null 2>&1; then
    if gemini mcp remove macroscope-codereview >/dev/null 2>&1; then
      success "Removed legacy Gemini MCP registration"
    fi
  fi
}

print_verification_summary() {
  step "Verification"

  if [ -d "$MACROSCOPE_DIR" ]; then
    warn "Config directory still exists: $MACROSCOPE_DIR"
  else
    success "No ~/.macroscope directory remains"
  fi

  if command -v macroscope >/dev/null 2>&1; then
    warn "macroscope is still on PATH at $(command -v macroscope)"
  else
    success "macroscope is no longer on PATH"
  fi

  if pgrep -x 'macroscope' >/dev/null 2>&1 || pgrep -x 'macroscope-mcp' >/dev/null 2>&1; then
    warn "Some Macroscope processes are still running"
  else
    success "No Macroscope processes remain"
  fi
}

echo ""
printf "${BOLD}Macroscope Reset${RESET}\n"
printf "${DIM}Removes all Macroscope state and re-installs from the latest release.${RESET}\n"
echo ""

kill_running_processes
remove_binaries
remove_config_and_logs
clean_shell_configs
wipe_keychain_credentials
remove_legacy_mcp_registrations
kill_running_processes
print_verification_summary

if [ "${MACROSCOPE_SKIP_REINSTALL:-0}" = "1" ]; then
  step "Skipping re-install..."
  info "Removal complete. Reinstall manually when you're ready."
else
  step "Re-installing from latest release..."
  echo ""
  curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash
fi

echo ""
printf "${GREEN}${BOLD}========================================${RESET}\n"
printf "${GREEN}${BOLD}Reset Complete!${RESET}\n"
printf "${GREEN}${BOLD}========================================${RESET}\n"
echo ""
