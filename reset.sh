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

# ─── Step 2: Remove macroscope app data ──────────────────────────────────
step "Removing macroscope app data..."

MACROSCOPE_DIR="$HOME/.macroscope"
if [ -d "$MACROSCOPE_DIR" ]; then
  rm -rf "$MACROSCOPE_DIR"
  success "Removed $MACROSCOPE_DIR"
else
  info "No ~/.macroscope directory to remove"
fi

# ─── Step 3: Re-install from latest release ──────────────────────────────
step "Re-installing from latest release..."
echo ""

curl -sSL https://raw.githubusercontent.com/prassoai/macroscope-local/main/install.sh | bash

echo ""
printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
printf "${GREEN}${BOLD}Reset Complete!${RESET}\n"
printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
echo ""
