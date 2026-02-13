#!/bin/bash
set -euo pipefail

# Macroscope Reset Script
# Cleanly removes macroscope binaries, MCP registrations, and plugin state,
# then re-installs from the latest release. Safe to run multiple times.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/macroscope-local/reset.sh | bash
#   # or locally:
#   bash reset.sh

# Color codes (disabled if NO_COLOR is set or not a tty)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  CYAN='\033[0;36m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  MAGENTA='\033[0;35m'
  RESET='\033[0m'
else
  BOLD='' DIM='' CYAN='' GREEN='' YELLOW='' RED='' MAGENTA='' RESET=''
fi

info()    { printf "${CYAN}i${RESET} %s\n" "$1"; }
success() { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn()    { printf "${YELLOW}⚠${RESET} %s\n" "$1"; }
error()   { printf "${RED}✗${RESET} %s\n" "$1"; }
step()    { printf "\n${BOLD}${MAGENTA}→${RESET} ${BOLD}%s${RESET}\n" "$1"; }

PLUGIN_NAME="macroscope-codereview"
MARKETPLACE_NAME="macroscope-local"
MARKETPLACE_SOURCE="prassoai/macroscope-local"
MCP_BINARY="$HOME/.local/bin/macroscope-mcp"
CLI_BINARY="$HOME/.local/bin/macroscope"

echo ""
printf "${BOLD}Macroscope Reset${RESET}\n"
printf "${DIM}Removes all macroscope state and re-installs from latest release.${RESET}\n"
echo ""

# ─── Step 1: Kill any running macroscope-mcp processes ───────────────────────
step "Stopping running macroscope-mcp processes..."

if pgrep -f macroscope-mcp >/dev/null 2>&1; then
  pkill -f macroscope-mcp 2>/dev/null && success "Killed macroscope-mcp processes" || warn "Could not kill macroscope-mcp (may need manual restart of Claude Code)"
else
  info "No macroscope-mcp processes running"
fi

# ─── Step 2: Remove binaries ────────────────────────────────────────────────
step "Removing binaries..."

for bin in "$MCP_BINARY" "$CLI_BINARY"; do
  if [ -f "$bin" ]; then
    rm -f "$bin"
    success "Removed $bin"
  else
    info "Not found: $bin (already clean)"
  fi
done

# ─── Step 3: Remove Claude Code MCP registration ────────────────────────────
step "Removing Claude Code MCP registration..."

# Direct MCP registration in ~/.claude.json
if [ -f "$HOME/.claude.json" ] && command -v python3 &>/dev/null; then
  if python3 -c "
import json, sys
p = '$HOME/.claude.json'
with open(p) as f:
    cfg = json.load(f)
removed = False
# Remove from mcpServers at top level
if 'mcpServers' in cfg and '$PLUGIN_NAME' in cfg['mcpServers']:
    del cfg['mcpServers']['$PLUGIN_NAME']
    removed = True
# Remove from projects.*.mcpServers
for proj in cfg.get('projects', {}).values():
    if isinstance(proj, dict) and 'mcpServers' in proj and '$PLUGIN_NAME' in proj['mcpServers']:
        del proj['mcpServers']['$PLUGIN_NAME']
        removed = True
if removed:
    with open(p, 'w') as f:
        json.dump(cfg, f, indent=4)
    print('removed')
else:
    print('not_found')
" 2>/dev/null | grep -q "removed"; then
    success "Removed macroscope-codereview from ~/.claude.json"
  else
    info "macroscope-codereview not found in ~/.claude.json"
  fi
else
  info "Skipping ~/.claude.json cleanup (python3 not available or file missing)"
fi

# ─── Step 4: Remove Claude plugin state ──────────────────────────────────────
step "Removing Claude plugin state..."

# Remove from installed_plugins.json
INSTALLED_PLUGINS="$HOME/.claude/plugins/installed_plugins.json"
if [ -f "$INSTALLED_PLUGINS" ] && command -v python3 &>/dev/null; then
  if python3 -c "
import json
p = '$INSTALLED_PLUGINS'
with open(p) as f:
    cfg = json.load(f)
plugins = cfg.get('plugins', {})
keys_to_remove = [k for k in plugins if k.startswith('$PLUGIN_NAME@')]
if keys_to_remove:
    for k in keys_to_remove:
        del plugins[k]
    with open(p, 'w') as f:
        json.dump(cfg, f, indent=2)
    print('removed')
else:
    print('not_found')
" 2>/dev/null | grep -q "removed"; then
    success "Removed from installed_plugins.json"
  else
    info "macroscope plugin not found in installed_plugins.json"
  fi
fi

# Remove marketplace registration
KNOWN_MARKETPLACES="$HOME/.claude/plugins/known_marketplaces.json"
if [ -f "$KNOWN_MARKETPLACES" ] && command -v python3 &>/dev/null; then
  if python3 -c "
import json
p = '$KNOWN_MARKETPLACES'
with open(p) as f:
    cfg = json.load(f)
if '$MARKETPLACE_NAME' in cfg:
    del cfg['$MARKETPLACE_NAME']
    with open(p, 'w') as f:
        json.dump(cfg, f, indent=2)
    print('removed')
else:
    print('not_found')
" 2>/dev/null | grep -q "removed"; then
    success "Removed macroscope-local marketplace from known_marketplaces.json"
  else
    info "macroscope-local marketplace not in known_marketplaces.json"
  fi
fi

# Remove cached plugin files
PLUGIN_CACHE="$HOME/.claude/plugins/cache/$MARKETPLACE_NAME"
if [ -d "$PLUGIN_CACHE" ]; then
  rm -rf "$PLUGIN_CACHE"
  success "Removed plugin cache: $PLUGIN_CACHE"
else
  info "No plugin cache to remove"
fi

MARKETPLACE_DIR="$HOME/.claude/plugins/marketplaces/$MARKETPLACE_NAME"
if [ -d "$MARKETPLACE_DIR" ]; then
  rm -rf "$MARKETPLACE_DIR"
  success "Removed marketplace dir: $MARKETPLACE_DIR"
else
  info "No marketplace dir to remove"
fi

# ─── Step 5: Remove Codex MCP config ────────────────────────────────────────
CODEX_CONFIG="$HOME/.codex/config.toml"
if [ -f "$CODEX_CONFIG" ] && grep -q "macroscope-codereview" "$CODEX_CONFIG" 2>/dev/null; then
  step "Removing Codex MCP config..."
  # Remove the macroscope block from TOML (marker comment + 3 lines)
  if command -v python3 &>/dev/null; then
    python3 -c "
import re
with open('$CODEX_CONFIG') as f:
    content = f.read()
# Remove the macroscope block
content = re.sub(r'\n?# Added by Macroscope installer\n\[mcp_servers\.macroscope-codereview\]\ncommand = .*\nargs = \[\]\n?', '', content)
with open('$CODEX_CONFIG', 'w') as f:
    f.write(content)
" 2>/dev/null && success "Removed from Codex config" || warn "Could not clean Codex config"
  fi
fi

# ─── Step 6: Remove Cursor MCP config ───────────────────────────────────────
CURSOR_MCP="$HOME/.cursor/mcp.json"
if [ -f "$CURSOR_MCP" ] && grep -q "macroscope-codereview" "$CURSOR_MCP" 2>/dev/null; then
  step "Removing Cursor MCP config..."
  if command -v python3 &>/dev/null; then
    python3 -c "
import json
with open('$CURSOR_MCP') as f:
    cfg = json.load(f)
if 'mcpServers' in cfg and 'macroscope-codereview' in cfg['mcpServers']:
    del cfg['mcpServers']['macroscope-codereview']
    with open('$CURSOR_MCP', 'w') as f:
        json.dump(cfg, f, indent=2)
" 2>/dev/null && success "Removed from Cursor config" || warn "Could not clean Cursor config"
  fi
fi

# ─── Step 7: Remove Gemini MCP config ───────────────────────────────────────
GEMINI_SETTINGS="$HOME/.gemini/settings.json"
if [ -f "$GEMINI_SETTINGS" ] && grep -q "macroscope-codereview" "$GEMINI_SETTINGS" 2>/dev/null; then
  step "Removing Gemini MCP config..."
  if command -v python3 &>/dev/null; then
    python3 -c "
import json
with open('$GEMINI_SETTINGS') as f:
    cfg = json.load(f)
if 'mcpServers' in cfg and 'macroscope-codereview' in cfg['mcpServers']:
    del cfg['mcpServers']['macroscope-codereview']
    with open('$GEMINI_SETTINGS', 'w') as f:
        json.dump(cfg, f, indent=2)
" 2>/dev/null && success "Removed from Gemini config" || warn "Could not clean Gemini config"
  fi
fi

# ─── Step 8: Remove macroscope app data ──────────────────────────────────────
step "Removing macroscope app data..."

MACROSCOPE_DIR="$HOME/.macroscope"
if [ -d "$MACROSCOPE_DIR" ]; then
  rm -rf "$MACROSCOPE_DIR"
  success "Removed $MACROSCOPE_DIR"
else
  info "No ~/.macroscope directory to remove"
fi

# ─── Step 9: Re-install from latest release ──────────────────────────────────
step "Re-installing from latest release..."
echo ""

curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/macroscope-local/install.sh | bash

echo ""
printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
printf "${GREEN}${BOLD}Reset Complete!${RESET}\n"
printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
echo ""
printf "${YELLOW}${BOLD}IMPORTANT:${RESET} Restart Claude Code (and any other AI tools) to pick up the new MCP server.\n"
echo ""
