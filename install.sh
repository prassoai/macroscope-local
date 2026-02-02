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

    ╔════════════════════════════════════════════════════════════════════════════════════════════╗
    ║                                                                                            ║
    ║  ███╗   ███╗ █████╗  ██████╗██████╗  ██████╗ ███████╗ ██████╗ ██████╗ ██████╗ ███████╗  ║
    ║  ████╗ ████║██╔══██╗██╔════╝██╔══██╗██╔═══██╗██╔════╝██╔════╝██╔═══██╗██╔══██╗██╔════╝  ║
    ║  ██╔████╔██║███████║██║     ██████╔╝██║   ██║███████╗██║     ██║   ██║██████╔╝█████╗    ║
    ║  ██║╚██╔╝██║██╔══██║██║     ██╔══██╗██║   ██║╚════██║██║     ██║   ██║██╔═══╝ ██╔══╝    ║
    ║  ██║ ╚═╝ ██║██║  ██║╚██████╗██║  ██║╚██████╔╝███████║╚██████╗╚██████╔╝██║     ███████╗  ║
    ║  ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝ ╚═════╝ ╚═════╝ ╚═╝     ╚══════╝  ║
    ║                                                                                            ║
    ║                            🔬 AI-Powered Code Intelligence                                ║
    ║                                                                                            ║
    ╚════════════════════════════════════════════════════════════════════════════════════════════╝

EOF
}

# Status printing functions
info() {
  echo -e "${CYAN}ℹ${RESET} $1"
}

success() {
  echo -e "${GREEN}✓${RESET} $1"
}

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

# Determine installation directory
determine_install_dir() {
  # Check if user wants to install to home directory
  if [ "${MACROSCOPE_USER_INSTALL:-0}" = "1" ] || [ ! -w "/usr/local/bin" ]; then
    INSTALL_DIR="${HOME}/.local/bin"
    mkdir -p "$INSTALL_DIR"
    NEEDS_PATH_UPDATE=1
  else
    INSTALL_DIR="/usr/local/bin"
    NEEDS_PATH_UPDATE=0
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

  success "Installed to ${BOLD}${INSTALL_DIR}/macroscope${RESET}"
}

# Update shell configuration
update_shell_config() {
  if [ "$NEEDS_PATH_UPDATE" -eq 0 ]; then
    return
  fi

  step "Updating shell configuration..."

  local updated=0
  local shell_configs=()

  # Detect active shells
  [ -f "${HOME}/.bashrc" ] && shell_configs+=("${HOME}/.bashrc")
  [ -f "${HOME}/.bash_profile" ] && shell_configs+=("${HOME}/.bash_profile")
  [ -f "${HOME}/.zshrc" ] && shell_configs+=("${HOME}/.zshrc")
  [ -f "${HOME}/.config/fish/config.fish" ] && shell_configs+=("${HOME}/.config/fish/config.fish")

  local export_line='export PATH="$HOME/.local/bin:$PATH"'

  for config in "${shell_configs[@]}"; do
    if ! grep -q ".local/bin" "$config" 2>/dev/null; then
      echo "" >> "$config"
      echo "# Added by Macroscope installer" >> "$config"
      echo "$export_line" >> "$config"
      success "Updated ${config}"
      updated=1
    fi
  done

  if [ $updated -eq 1 ]; then
    warn "Please restart your shell or run: ${BOLD}source ~/.bashrc${RESET} (or ~/.zshrc)"
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
  print_completion
}

# Run installation
main "$@"
