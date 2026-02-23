#!/bin/bash
set -e

# Color codes (disabled if NO_COLOR is set or not a tty)
# NOTE: use ANSI-C quoting so the variables contain real ESC bytes (not literal "\033")
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  CYAN=$'\033[0;36m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  RED=$'\033[0;31m'
  BLUE=$'\033[0;34m'
  MAGENTA=$'\033[0;35m'
  RESET=$'\033[0m'
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

EOF
}

# Status printing functions
info() {
  printf "${CYAN}ℹ${RESET} %s\n" "$1"
}

success() {
  printf "${GREEN}✓${RESET} %s\n" "$1"
}

error() {
  printf "${RED}✗${RESET} %s\n" "$1"
}

warn() {
  printf "${YELLOW}⚠${RESET} %s\n" "$1"
}

step() {
  printf "\n${BOLD}${MAGENTA}→${RESET} ${BOLD}%s${RESET}\n" "$1"
}

# Path of the installed binary (set by install_binary, read by verify_install/launch_wizard)
INSTALLED_BINARY=""

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
    echo "  macOS: brew install ${missing_deps[*]}"
    echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
    echo "  RHEL/CentOS: sudo yum install ${missing_deps[*]}"
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
    echo "  Release doesn't exist for ${OS}-${ARCH}"
    echo "  Network connectivity issues"
    echo "  Invalid version specified: ${VERSION}"
    echo ""
    echo "Check available releases at:"
    echo "  https://github.com/${REPO}/releases"
    exit 1
  fi

  success "Downloaded successfully"

  # Make executable
  chmod +x "$TMP_DIR/macroscope"

  # Install binary (always to ~/.local/bin, no sudo needed)
  step "Installing binary..."
  mv "$TMP_DIR/macroscope" "$INSTALL_DIR/macroscope"
  INSTALLED_BINARY="${INSTALL_DIR}/macroscope"
  success "Installed CLI to ${BOLD}${INSTALLED_BINARY}${RESET}"
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
    printf "  ${CYAN}source ~/.zprofile${RESET}   (zsh)\n"
    printf "  ${CYAN}source ~/.bash_profile${RESET} (bash)\n"
    printf "  ${CYAN}exec fish${RESET}           (fish)\n"
  fi
}

# Print completion message
print_installation_completion() {
  echo ""
  printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
  printf "${GREEN}${BOLD}Installation Complete!${RESET}\n"
  printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
  echo ""
  printf "${BOLD}Verify installation:${RESET}\n"
  printf "  ${CYAN}macroscope version${RESET}\n"
  echo ""
  printf "${BOLD}Quick start:${RESET}\n"
  printf "  ${CYAN}macroscope review${RESET}          ${DIM}# Review your code changes${RESET}\n"
  printf "  ${CYAN}macroscope review --help${RESET}   ${DIM}# See all options${RESET}\n"
  echo ""
  printf "${BOLD}Need help?${RESET}\n"
  printf "  Documentation: ${BLUE}https://github.com/prassoai/macroscope-local${RESET}\n"
  printf "  Report issues: ${BLUE}https://github.com/prassoai/macroscope-local/issues${RESET}\n"
  echo ""
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
  print_installation_completion
  launch_wizard
}

# Run installation
main "$@"
