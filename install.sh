#!/bin/bash
set -e

# Color codes (disabled if NO_COLOR is set or not a tty)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  CYAN='\033[0;36m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'
  RESET='\033[0m'
else
  BOLD='' DIM='' CYAN='' GREEN='' YELLOW='' RED='' BLUE='' MAGENTA='' RESET=''
fi

# Print ASCII art banner
print_banner() {
  cat << "EOF"

  ███╗   ███╗ █████╗  ██████╗██████╗  ██████╗ ███████╗ ██████╗ ██████╗ ██████╗ ███████╗
  ████╗ ████║██╔══██╗██╔════╝██╔══██╗██╔═══██╗██╔════╝██╔════╝██╔═══██╗██╔══██╗██╔════╝
  ██╔████╔██║███████║██║     ██████╔╝██║   ██║███████╗██║     ██║   ██║██████╔╝█████╗
  ██║╚██╔╝██║██╔══██║██║     ██╔══██╗██║   ██║╚════██║██║     ██║   ██║██╔═══╝ ██╔══╝
  ██║ ╚═╝ ██║██║  ██║╚██████╗██║  ██║╚██████╔╝███████║╚██████╗╚██████╔╝██║     ███████╗
  ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝ ╚═════╝ ╚═════╝ ╚═╝     ╚══════╝

                        🔬 AI-Powered Code Intelligence

EOF
}

# Status printing functions
info() {
  echo -e "${CYAN}ℹ${RESET} $1"
}

success() {
  echo -e "${GREEN}✓${RESET} $1"
}

# Optional variables to hold the paths of the installed binaries
INSTALLED_BINARY=""
INSTALLED_MCP_BINARY=""

error() {
  echo -e "${RED}✗${RESET} $1"
}

warn() {
  echo -e "${YELLOW}⚠${RESET} $1"
}

step() {
  echo -e "\n${BOLD}${MAGENTA}→${RESET} ${BOLD}$1${RESET}"
}

# Check for required dependencies
check_dependencies() {
  local missing_deps=()

  for cmd in curl git; do
    if ! command -v "$cmd" &> /dev/null; then
      missing_deps+=("$cmd")
    fi
  done

  if [ ${#missing_deps[@]} -ne 0 ]; then
    error "Missing required dependencies: ${missing_deps[*]}"
    echo ""
    echo "Please install them first:"
    echo "  • macOS: brew install ${missing_deps[*]}"
    echo "  • Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
    echo "  • RHEL/CentOS: sudo yum install ${missing_deps[*]}"
    exit 1
  fi
}

# Detect OS and architecture
detect_platform() {
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)

  # Normalize architecture
  case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
      error "Unsupported architecture: $ARCH"
      echo "Please file an issue at: https://github.com/prassoai/macroscope-local/issues"
      exit 1
      ;;
  esac

  # Validate OS
  if [[ "$OS" != "linux" && "$OS" != "darwin" ]]; then
    error "Unsupported OS: $OS"
    echo "Only Linux and macOS are currently supported."
    echo "Please file an issue at: https://github.com/prassoai/macroscope-local/issues"
    exit 1
  fi

  success "Detected platform: ${BOLD}${OS}-${ARCH}${RESET}"
}

# Determine installation directory — always use ~/.local/bin (like Claude CLI).
# No sudo required; no /usr/local/bin fallback.
determine_install_dir() {
  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "$INSTALL_DIR"
  info "Installation directory: ${BOLD}${INSTALL_DIR}${RESET}"
}

# Download and install binary
install_binary() {
  step "Downloading Macroscope CLI..."

  # GitHub repo info
  REPO="prassoai/macroscope-local"
  VERSION="${MACROSCOPE_VERSION:-${1:-latest}}"

  # Construct download URL
  if [ "$VERSION" = "latest" ]; then
    URL="https://github.com/${REPO}/releases/latest/download/macroscope-${OS}-${ARCH}"
  else
    URL="https://github.com/${REPO}/releases/download/${VERSION}/macroscope-${OS}-${ARCH}"
  fi

  # Create secure temporary directory
  TMP_DIR=$(mktemp -d)
  chmod 700 "$TMP_DIR"
  trap "rm -rf $TMP_DIR" EXIT

  info "Downloading from: ${DIM}${URL}${RESET}"

  # Download with progress bar
  if ! curl -fL --progress-bar "$URL" -o "$TMP_DIR/macroscope"; then
    error "Failed to download macroscope"
    echo ""
    echo "Possible reasons:"
    echo "  • Release doesn't exist for ${OS}-${ARCH}"
    echo "  • Network connectivity issues"
    echo "  • Invalid version specified: ${VERSION}"
    echo ""
    echo "Check available releases at:"
    echo "  https://github.com/${REPO}/releases"
    exit 1
  fi

  success "Downloaded successfully"

  # Make executable
  chmod +x "$TMP_DIR/macroscope"

  # Download MCP server binary
  if [ "$VERSION" = "latest" ]; then
    MCP_URL="https://github.com/${REPO}/releases/latest/download/macroscope-mcp-${OS}-${ARCH}"
  else
    MCP_URL="https://github.com/${REPO}/releases/download/${VERSION}/macroscope-mcp-${OS}-${ARCH}"
  fi

  info "Downloading MCP server from: ${DIM}${MCP_URL}${RESET}"

  if ! curl -fL --progress-bar "$MCP_URL" -o "$TMP_DIR/macroscope-mcp"; then
    warn "Failed to download macroscope-mcp (MCP server)"
    echo "  The CLI will still work, but Claude Code integration won't be auto-configured."
    echo "  You can set it up manually later: https://github.com/${REPO}#mcp-setup"
  else
    success "Downloaded MCP server"
    chmod +x "$TMP_DIR/macroscope-mcp"
  fi

  # Install binaries (always to ~/.local/bin, no sudo needed)
  step "Installing binaries..."
  mv "$TMP_DIR/macroscope" "$INSTALL_DIR/macroscope"
  INSTALLED_BINARY="${INSTALL_DIR}/macroscope"
  success "Installed CLI to ${BOLD}${INSTALLED_BINARY}${RESET}"

  if [ -f "$TMP_DIR/macroscope-mcp" ]; then
    mv "$TMP_DIR/macroscope-mcp" "$INSTALL_DIR/macroscope-mcp"
    INSTALLED_MCP_BINARY="${INSTALL_DIR}/macroscope-mcp"
    success "Installed MCP server to ${BOLD}${INSTALLED_MCP_BINARY}${RESET}"
  fi
}

# Update shell configuration so ~/.local/bin is on PATH.
# Always runs (not gated by NEEDS_PATH_UPDATE) since we always install to ~/.local/bin.
update_shell_config() {
  step "Updating shell configuration..."

  local updated=0
  local install_bin="$HOME/.local/bin"
  local shell_name=""
  shell_name="$(basename "${SHELL:-}")"

  local marker="# Added by Macroscope installer"
  local export_line="export PATH=\"$install_bin:\$PATH\""

  ensure_line_in_file() {
    local file="$1"
    local line="$2"
    local marker_line="$3"

    mkdir -p "$(dirname "$file")"
    touch "$file"

    if ! grep -Fq "$line" "$file" 2>/dev/null; then
      {
        echo ""
        echo "$marker_line"
        echo "$line"
      } >> "$file"
      success "Updated $file"
      updated=1
    else
      info "PATH already configured in $file"
    fi
  }

  # fish uses different syntax; do NOT write bash export lines there.
  if [ "$shell_name" = "fish" ] || [ -n "${FISH_VERSION:-}" ]; then
    local fish_cfg="$HOME/.config/fish/config.fish"
    local fish_line="set -Ux fish_user_paths $install_bin \$fish_user_paths"
    ensure_line_in_file "$fish_cfg" "$fish_line" "$marker"
  else
    # zsh (macOS default): PATH belongs in ~/.zprofile for login shells; ~/.zshrc as fallback
    if [ "$shell_name" = "zsh" ] || [ -n "${ZSH_VERSION:-}" ]; then
      ensure_line_in_file "$HOME/.zprofile" "$export_line" "$marker"
      ensure_line_in_file "$HOME/.zshrc" "$export_line" "$marker"
    fi

    # bash: login shell reads ~/.bash_profile; interactive shells often read ~/.bashrc
    if [ "$shell_name" = "bash" ] || [ -n "${BASH_VERSION:-}" ]; then
      ensure_line_in_file "$HOME/.bash_profile" "$export_line" "$marker"
      ensure_line_in_file "$HOME/.bashrc" "$export_line" "$marker"
    fi

    # unknown shell: safe defaults
    if [ "$shell_name" != "zsh" ] && [ "$shell_name" != "bash" ]; then
      ensure_line_in_file "$HOME/.profile" "$export_line" "$marker"
      ensure_line_in_file "$HOME/.bashrc" "$export_line" "$marker"
      ensure_line_in_file "$HOME/.zshrc" "$export_line" "$marker"
      ensure_line_in_file "$HOME/.zprofile" "$export_line" "$marker"
    fi
  fi

  # Add to current session so the binary is immediately usable
  export PATH="$HOME/.local/bin:$PATH"

  if [ $updated -eq 0 ]; then
    info "PATH already appears configured for $install_bin"
  fi
}

# Verify installation
verify_install() {
  step "Verifying installation..."

  if [ -n "$INSTALLED_BINARY" ] && [ -x "$INSTALLED_BINARY" ]; then
    success "Binary exists at: ${BOLD}${INSTALLED_BINARY}${RESET}"
  else
    warn "Installed binary path not found/executable: ${INSTALLED_BINARY}"
  fi

  # Check whether it's currently discoverable in this shell
  if command -v macroscope >/dev/null 2>&1; then
    success "macroscope is on PATH: ${BOLD}$(command -v macroscope)${RESET}"
  else
    warn "macroscope is not currently on PATH in this shell."
    echo "Open a new terminal or run:"
    echo -e "  ${CYAN}source ~/.zprofile${RESET}   (zsh)"
    echo -e "  ${CYAN}source ~/.bash_profile${RESET} (bash)"
    echo -e "  ${CYAN}exec fish${RESET}           (fish)"
  fi
}

# Print completion message
print_completion() {
  echo ""
  echo -e "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}"
  echo -e "${GREEN}${BOLD}   Installation Complete! 🎉${RESET}"
  echo -e "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}"
  echo ""
  echo -e "${BOLD}Verify installation:${RESET}"
  echo -e "  ${CYAN}macroscope version${RESET}"
  echo ""
  echo -e "${BOLD}Quick start:${RESET}"
  echo -e "  ${CYAN}macroscope review${RESET}          ${DIM}# Review your code changes${RESET}"
  echo -e "  ${CYAN}macroscope review --help${RESET}   ${DIM}# See all options${RESET}"
  echo ""
  if [ -n "$INSTALLED_MCP_BINARY" ]; then
    echo -e "${BOLD}AI tool integration:${RESET}"
    echo -e "  ${DIM}MCP server installed for detected tools. Restart them, then ask:${RESET}"
    echo -e "  ${CYAN}\"Review my code changes\"${RESET}"
  fi
  echo ""
  echo -e "${BOLD}Need help?${RESET}"
  echo -e "  📖 Documentation: ${BLUE}https://github.com/prassoai/macroscope-local${RESET}"
  echo -e "  🐛 Report issues: ${BLUE}https://github.com/prassoai/macroscope-local/issues${RESET}"
  echo ""
}

# Configure MCP server for AI coding tools
setup_mcp() {
  # Skip if MCP binary wasn't installed
  if [ -z "$INSTALLED_MCP_BINARY" ] || [ ! -x "$INSTALLED_MCP_BINARY" ]; then
    return
  fi

  step "Configuring MCP integrations..."

  local configured=0

  # Claude Code
  if command -v claude &> /dev/null; then
    if claude mcp add macroscope-codereview -s user -- "$INSTALLED_MCP_BINARY" 2>/dev/null; then
      success "Claude Code: MCP server registered"
      configured=1
    else
      warn "Claude Code: auto-configure failed. Manual setup:"
      echo -e "  ${CYAN}claude mcp add macroscope-codereview -s user -- ${INSTALLED_MCP_BINARY}${RESET}"
    fi
  fi

  # Codex (OpenAI) — no CLI command; write TOML config at ~/.codex/config.toml
  if command -v codex &> /dev/null; then
    setup_codex_mcp
    configured=1
  fi

  # Gemini CLI — uses `gemini mcp add` with settings.json at ~/.gemini/settings.json
  if command -v gemini &> /dev/null; then
    if gemini mcp add -s user macroscope-codereview "$INSTALLED_MCP_BINARY" 2>/dev/null; then
      success "Gemini CLI: MCP server registered"
      configured=1
    else
      warn "Gemini CLI: auto-configure failed. Manual setup:"
      echo -e "  ${CYAN}gemini mcp add -s user macroscope-codereview ${INSTALLED_MCP_BINARY}${RESET}"
    fi
  fi

  # Cursor — uses JSON config at ~/.cursor/mcp.json (no CLI command; write JSON directly)
  if [ -d "$HOME/.cursor" ]; then
    setup_cursor_mcp
    configured=1
  fi

  if [ $configured -eq 0 ]; then
    info "No supported AI coding tools detected (Claude Code, Codex, Gemini CLI, Cursor)."
    echo -e "  ${DIM}Install one and rerun, or configure MCP manually.${RESET}"
  else
    info "Restart your AI coding tools to enable the integration"
  fi
}

# Write MCP config into Codex's ~/.codex/config.toml
setup_codex_mcp() {
  local codex_config="$HOME/.codex/config.toml"

  if [ -f "$codex_config" ] && grep -q 'mcp_servers.macroscope-codereview' "$codex_config" 2>/dev/null; then
    info "Codex: MCP server already configured"
    return
  fi

  mkdir -p "$HOME/.codex"
  # Append the MCP server block to the TOML config
  {
    echo ""
    echo "# Added by Macroscope installer"
    echo "[mcp_servers.macroscope-codereview]"
    echo "command = \"$INSTALLED_MCP_BINARY\""
    echo "args = []"
  } >> "$codex_config"
  success "Codex: MCP server registered"
}

# Write MCP config into Cursor's ~/.cursor/mcp.json
setup_cursor_mcp() {
  local cursor_mcp="$HOME/.cursor/mcp.json"

  # If file exists, merge our server in (if not already present)
  if [ -f "$cursor_mcp" ]; then
    if grep -q '"macroscope-codereview"' "$cursor_mcp" 2>/dev/null; then
      info "Cursor: MCP server already configured"
      return
    fi

    # Use python/node to safely merge JSON if available, otherwise fall back to simple check
    if command -v python3 &> /dev/null; then
      python3 -c "
import json, sys
try:
    with open('$cursor_mcp', 'r') as f:
        cfg = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    cfg = {}
cfg.setdefault('mcpServers', {})
cfg['mcpServers']['macroscope-codereview'] = {
    'command': '$INSTALLED_MCP_BINARY',
    'args': []
}
with open('$cursor_mcp', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null && success "Cursor: MCP server registered" && return
    fi

    warn "Cursor: could not auto-merge config. Add manually to ${BOLD}${cursor_mcp}${RESET}:"
    echo -e "  ${CYAN}\"macroscope-codereview\": { \"command\": \"${INSTALLED_MCP_BINARY}\", \"args\": [] }${RESET}"
    return
  fi

  # No existing file — create it
  mkdir -p "$HOME/.cursor"
  cat > "$cursor_mcp" << CURSOREOF
{
  "mcpServers": {
    "macroscope-codereview": {
      "command": "$INSTALLED_MCP_BINARY",
      "args": []
    }
  }
}
CURSOREOF
  success "Cursor: MCP server registered"
}

launch_wizard() {
  # Allow CI/automated installs to skip the wizard
  if [ "${MACROSCOPE_SKIP_WIZARD:-0}" = "1" ]; then
    info "Skipping wizard launch (MACROSCOPE_SKIP_WIZARD=1)."
    return
  fi

  # When piped (curl | bash), stdin is the pipe — not a TTY. We use /dev/tty
  # to reconnect to the user's terminal for interactive input.
  if [ ! -e /dev/tty ]; then
    info "No TTY available; run 'macroscope' later to start the setup wizard."
    return
  fi

  # Prefer the binary we just installed, otherwise fall back to PATH
  local bin_path="${INSTALLED_BINARY}"
  if [ -z "$bin_path" ] || [ ! -x "$bin_path" ]; then
    bin_path="$(command -v macroscope || true)"
  fi

  if [ -z "$bin_path" ]; then
    warn "Could not find installed macroscope binary; skipping wizard launch."
    return
  fi

  echo ""
  step "Launching Macroscope setup wizard..."
  # Redirect stdin from /dev/tty so the wizard can accept interactive input
  # even when the install script itself was piped (curl | bash).
  if ! "$bin_path" < /dev/tty; then
    warn "Wizard exited with a non-zero status. You can rerun it anytime with: macroscope"
  fi
}

# Main installation flow
main() {
  clear
  print_banner

  step "Checking system requirements..."
  check_dependencies
  detect_platform
  determine_install_dir

  install_binary "$@"
  update_shell_config
  verify_install
  setup_mcp
  print_completion
  launch_wizard
}

# Run installation
main "$@"
