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

# Optional variable to hold the path of the installed binary
INSTALLED_BINARY=""

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

# Determine installation directory (most common behavior:
# prefer /usr/local/bin if writable; else fall back to ~/.local/bin and update PATH)
determine_install_dir() {
  if [ "${MACROSCOPE_USER_INSTALL:-0}" = "1" ]; then
    INSTALL_DIR="${HOME}/.local/bin"
    mkdir -p "$INSTALL_DIR"
    NEEDS_PATH_UPDATE=1
  else
    # Prefer /usr/local/bin if it exists and is writable OR can be written with sudo.
    if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
      INSTALL_DIR="/usr/local/bin"
      NEEDS_PATH_UPDATE=0
    else
      # Fall back to user install if /usr/local/bin isn't writable
      INSTALL_DIR="${HOME}/.local/bin"
      mkdir -p "$INSTALL_DIR"
      NEEDS_PATH_UPDATE=1
    fi
  fi

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

  # Install binary
  step "Installing binary..."

  if [ "$INSTALL_DIR" = "/usr/local/bin" ] && [ ! -w "$INSTALL_DIR" ]; then
    info "Requesting sudo access for installation to ${INSTALL_DIR}..."
    sudo mv "$TMP_DIR/macroscope" "$INSTALL_DIR/macroscope"
  else
    mv "$TMP_DIR/macroscope" "$INSTALL_DIR/macroscope"
  fi

  INSTALLED_BINARY="${INSTALL_DIR}/macroscope"
  success "Installed to ${BOLD}${INSTALLED_BINARY}${RESET}"
}

# Update shell configuration so ~/.local/bin is on PATH.
# This is the most common cross-shell approach.
update_shell_config() {
  if [ "$NEEDS_PATH_UPDATE" -eq 0 ]; then
    return
  fi

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

  if [ $updated -eq 1 ]; then
    warn "PATH was updated for future shells. Apply it now with ONE of these:"
    echo "  • zsh:  source ~/.zprofile"
    echo "  • bash: source ~/.bash_profile"
    echo "  • fish: exec fish"
  else
    info "PATH already appears configured for $install_bin"
  fi
}

# Verify installation (best-effort; can't reliably mutate parent shell PATH here)
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
    if [ "$NEEDS_PATH_UPDATE" -eq 1 ]; then
      echo "In most cases, open a new terminal or run:"
      echo "  ${CYAN}source ~/.zprofile${RESET}   (zsh)"
      echo "  ${CYAN}source ~/.bash_profile${RESET} (bash)"
      echo "  ${CYAN}exec fish${RESET}           (fish)"
      echo ""
      echo "Or for this session only:"
      echo "  ${CYAN}export PATH=\"$HOME/.local/bin:\$PATH\"${RESET}"
    fi
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
  echo -e "${BOLD}Need help?${RESET}"
  echo -e "  📖 Documentation: ${BLUE}https://github.com/prassoai/macroscope-local${RESET}"
  echo -e "  🐛 Report issues: ${BLUE}https://github.com/prassoai/macroscope-local/issues${RESET}"
  echo ""
}

launch_wizard() {
  # Allow CI/automated installs to skip the wizard
  if [ "${MACROSCOPE_SKIP_WIZARD:-0}" = "1" ]; then
    info "Skipping wizard launch (MACROSCOPE_SKIP_WIZARD=1)."
    return
  fi

  # Require an interactive TTY so we don't hang in non-interactive shells
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    info "Non-interactive shell detected; run 'macroscope' later to start the setup wizard."
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
  # Running without args triggers the default review wizard; on first run it
  # automatically falls into the setup flow (env + auth) before review.
  if ! "$bin_path"; then
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
  launch_wizard
  print_completion
}

# Run installation
main "$@"