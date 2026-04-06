#!/bin/bash
set -euo pipefail

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

INSTALLED_BINARY=""
INSTALL_VERSION=""
TMP_DIR=""
CHECKOUT_DIR=""
PLUGIN_VERSION=""
INSTALL_DIR=""
CONFIG_SEEDED=0
CODEX_SHIM_INSTALLED=0
CODEX_PLUGIN_HOST_WARNING=""

CODEX_LOCAL_PLUGIN_VERSION="local"
CODEX_BUNDLED_BINARY="/Applications/Codex.app/Contents/Resources/codex"
CODEX_SHIM_PATH=""

get_codex_home() {
  printf '%s' "${CODEX_HOME:-$HOME/.codex}"
}

codex_supports_plugins() {
  local codex_bin="$1"
  [ -x "$codex_bin" ] || return 1
  "$codex_bin" --help 2>/dev/null | grep -q "app-server"
}

is_managed_codex_shim() {
  local path="$1"
  [ -f "$path" ] || return 1
  grep -Fq "Macroscope-managed Codex shim" "$path"
}

check_dependencies() {
  local missing_deps=()

  for cmd in curl git python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
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

  if [ -n "${MACROSCOPE_LOCAL_BACK_REPO:-}" ] && ! command -v go >/dev/null 2>&1; then
    error "Missing required dependency for local installs: go"
    echo ""
    echo "Install Go first, or unset MACROSCOPE_LOCAL_BACK_REPO to use a released binary."
    exit 1
  fi
}

detect_platform() {
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)

  case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
      error "Unsupported architecture: $ARCH"
      echo "Please file an issue at: https://github.com/prassoai/macroscope-local/issues"
      exit 1
      ;;
  esac

  if [[ "$OS" != "linux" && "$OS" != "darwin" ]]; then
    error "Unsupported OS: $OS"
    echo "Only Linux and macOS are currently supported."
    echo "Please file an issue at: https://github.com/prassoai/macroscope-local/issues"
    exit 1
  fi

  success "Detected platform: ${BOLD}${OS}-${ARCH}${RESET}"
}

determine_install_dir() {
  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "$INSTALL_DIR"
  info "Installation directory: ${BOLD}${INSTALL_DIR}${RESET}"
}

prepare_tmp_dir() {
  TMP_DIR=$(mktemp -d)
  chmod 700 "$TMP_DIR"
  trap 'rm -rf "$TMP_DIR"' EXIT
}

resolve_version() {
  INSTALL_VERSION="${MACROSCOPE_VERSION:-${1:-latest}}"
  info "Requested version: ${BOLD}${INSTALL_VERSION}${RESET}"
}

install_binary() {
  step "Downloading Macroscope CLI..."

  if [ -n "${MACROSCOPE_LOCAL_BINARY_SOURCE:-}" ]; then
    if [ ! -f "${MACROSCOPE_LOCAL_BINARY_SOURCE}" ]; then
      error "Local binary source not found: ${MACROSCOPE_LOCAL_BINARY_SOURCE}"
      exit 1
    fi

    step "Installing local Macroscope CLI..."
    cp "${MACROSCOPE_LOCAL_BINARY_SOURCE}" "$TMP_DIR/macroscope"
    chmod +x "$TMP_DIR/macroscope"
    mv "$TMP_DIR/macroscope" "$INSTALL_DIR/macroscope"
    INSTALLED_BINARY="${INSTALL_DIR}/macroscope"
    success "Installed local CLI from ${BOLD}${MACROSCOPE_LOCAL_BINARY_SOURCE}${RESET}"
    return
  fi

  if [ -n "${MACROSCOPE_LOCAL_BACK_REPO:-}" ]; then
    if [ ! -d "${MACROSCOPE_LOCAL_BACK_REPO}" ]; then
      error "Local back repo not found: ${MACROSCOPE_LOCAL_BACK_REPO}"
      exit 1
    fi

    step "Building local Macroscope CLI..."
    (
      cd "${MACROSCOPE_LOCAL_BACK_REPO}"
      go build -buildvcs=false -o "$TMP_DIR/macroscope" ./tools/cmd/macrodaemon
    )
    chmod +x "$TMP_DIR/macroscope"
    mv "$TMP_DIR/macroscope" "$INSTALL_DIR/macroscope"
    INSTALLED_BINARY="${INSTALL_DIR}/macroscope"
    success "Built and installed local CLI from ${BOLD}${MACROSCOPE_LOCAL_BACK_REPO}${RESET}"
    return
  fi

  local repo="prassoai/macroscope-local"
  local url=""

  if [ "$INSTALL_VERSION" = "latest" ]; then
    url="https://github.com/${repo}/releases/latest/download/macroscope-${OS}-${ARCH}"
  else
    url="https://github.com/${repo}/releases/download/${INSTALL_VERSION}/macroscope-${OS}-${ARCH}"
  fi

  info "Downloading from: ${DIM}${url}${RESET}"

  if ! curl -fL --progress-bar "$url" -o "$TMP_DIR/macroscope"; then
    error "Failed to download macroscope"
    echo ""
    echo "Possible reasons:"
    echo "  Release doesn't exist for ${OS}-${ARCH}"
    echo "  Network connectivity issues"
    echo "  Invalid version specified: ${INSTALL_VERSION}"
    echo ""
    echo "Check available releases at:"
    echo "  https://github.com/${repo}/releases"
    exit 1
  fi

  chmod +x "$TMP_DIR/macroscope"

  step "Installing binary..."
  mv "$TMP_DIR/macroscope" "$INSTALL_DIR/macroscope"
  INSTALLED_BINARY="${INSTALL_DIR}/macroscope"
  success "Installed CLI to ${BOLD}${INSTALLED_BINARY}${RESET}"
}

fetch_plugin_bundle() {
  step "Fetching plugin bundle..."

  local repo_url="https://github.com/prassoai/macroscope-local.git"
  CHECKOUT_DIR="$TMP_DIR/macroscope-local"
  local bundle_url=""
  local bundle_archive="$TMP_DIR/macroscope-plugin-bundle.tar.gz"

  if [ -n "${MACROSCOPE_PLUGIN_BUNDLE_SOURCE:-}" ]; then
    if [ -d "${MACROSCOPE_PLUGIN_BUNDLE_SOURCE}" ]; then
      copy_tree "${MACROSCOPE_PLUGIN_BUNDLE_SOURCE}" "$CHECKOUT_DIR"
      success "Using local plugin bundle from ${BOLD}${MACROSCOPE_PLUGIN_BUNDLE_SOURCE}${RESET}"
    else
      git clone --depth 1 "${MACROSCOPE_PLUGIN_BUNDLE_SOURCE}" "$CHECKOUT_DIR" >/dev/null 2>&1
      success "Fetched plugin bundle from ${BOLD}${MACROSCOPE_PLUGIN_BUNDLE_SOURCE}${RESET}"
    fi
  else
    if [ "$INSTALL_VERSION" = "latest" ]; then
      bundle_url="https://github.com/prassoai/macroscope-local/releases/latest/download/macroscope-plugin-bundle.tar.gz"
    else
      bundle_url="https://github.com/prassoai/macroscope-local/releases/download/${INSTALL_VERSION}/macroscope-plugin-bundle.tar.gz"
    fi

    info "Downloading plugin bundle from: ${DIM}${bundle_url}${RESET}"

    mkdir -p "$CHECKOUT_DIR"
    if curl -fL --progress-bar "$bundle_url" -o "$bundle_archive"; then
      tar -xzf "$bundle_archive" -C "$CHECKOUT_DIR"
      success "Fetched plugin bundle from ${BOLD}${INSTALL_VERSION}${RESET}"
    elif [ "$INSTALL_VERSION" = "latest" ]; then
      warn "Could not download a released plugin bundle. Falling back to the default branch for plugin files."
      git clone --depth 1 "$repo_url" "$CHECKOUT_DIR" >/dev/null 2>&1
      success "Fetched fallback plugin bundle from ${BOLD}main${RESET}"
    else
      warn "Could not download a released plugin bundle for '${INSTALL_VERSION}'. Falling back to the repo ref for plugin files."
      if git clone --depth 1 --branch "$INSTALL_VERSION" "$repo_url" "$CHECKOUT_DIR" >/dev/null 2>&1; then
        success "Fetched fallback plugin bundle for ${BOLD}${INSTALL_VERSION}${RESET}"
      else
        warn "Could not fetch plugin bundle at ref '${INSTALL_VERSION}'. Falling back to the default branch for plugin files."
        git clone --depth 1 "$repo_url" "$CHECKOUT_DIR" >/dev/null 2>&1
        success "Fetched fallback plugin bundle from ${BOLD}main${RESET}"
      fi
    fi
  fi

  if [ ! -f "$CHECKOUT_DIR/plugins/macroscope/.claude-plugin/plugin.json" ] || [ ! -f "$CHECKOUT_DIR/plugins/macroscope/.codex-plugin/plugin.json" ]; then
    error "Fetched repo is missing the packaged macroscope plugin files."
    exit 1
  fi

  if [ -n "${MACROSCOPE_LOCAL_BACK_REPO:-}" ]; then
    local sync_script="$CHECKOUT_DIR/scripts/sync-back-skills.sh"
    if [ ! -f "$sync_script" ]; then
      error "Expected packaged skill sync script at $sync_script"
      exit 1
    fi
    if ! bash "$sync_script" "$MACROSCOPE_LOCAL_BACK_REPO" "$CHECKOUT_DIR" >/dev/null; then
      error "Failed to sync packaged skills from ${MACROSCOPE_LOCAL_BACK_REPO}"
      exit 1
    fi
    success "Synced packaged skills from ${BOLD}${MACROSCOPE_LOCAL_BACK_REPO}${RESET}"
  fi

  PLUGIN_VERSION="$(python3 - "$CHECKOUT_DIR/plugins/macroscope/.claude-plugin/plugin.json" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f).get("version", "unknown"))
PY
)"
}

copy_tree() {
  local src="$1"
  local dst="$2"

  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
}

copy_claude_plugin_tree() {
  local src="$1"
  local dst="$2"

  copy_tree "$src" "$dst"
  rm -rf "$dst/commands" "$dst/.codex-plugin" "$dst/.cursor-plugin" "$dst/opencode"
}

seed_local_build_config_if_needed() {
  if [ -z "${MACROSCOPE_LOCAL_BACK_REPO:-}" ] && [ -z "${MACROSCOPE_LOCAL_BINARY_SOURCE:-}" ]; then
    return
  fi

  local config_dir="$HOME/.macroscope"
  local config_path="$config_dir/config.yaml"
  local default_env="${MACROSCOPE_DEFAULT_ENV:-prod}"

  if [ -f "$config_path" ]; then
    info "Existing Macroscope config found at $config_path"
    return
  fi

  case "$default_env" in
    prod|nonprod|local) ;;
    *)
      warn "Unsupported MACROSCOPE_DEFAULT_ENV=$default_env; falling back to prod"
      default_env="prod"
      ;;
  esac

  mkdir -p "$config_dir"
  cat > "$config_path" <<EOF
env: $default_env
envs: {}
EOF
  chmod 600 "$config_path"
  CONFIG_SEEDED=1
  success "Seeded local-build config at ${BOLD}${config_path}${RESET} (${default_env})"
}

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

  if [ "$shell_name" = "fish" ] || [ -n "${FISH_VERSION:-}" ]; then
    local fish_cfg="$HOME/.config/fish/config.fish"
    local fish_line="set -Ux fish_user_paths $install_bin \$fish_user_paths"
    ensure_line_in_file "$fish_cfg" "$fish_line" "$marker"
  else
    if [ "$shell_name" = "zsh" ] || [ -n "${ZSH_VERSION:-}" ]; then
      ensure_line_in_file "$HOME/.zprofile" "$export_line" "$marker"
      ensure_line_in_file "$HOME/.zshrc" "$export_line" "$marker"
    fi

    if [ "$shell_name" = "bash" ] || [ -n "${BASH_VERSION:-}" ]; then
      ensure_line_in_file "$HOME/.bash_profile" "$export_line" "$marker"
      ensure_line_in_file "$HOME/.bashrc" "$export_line" "$marker"
    fi

    if [ "$shell_name" != "zsh" ] && [ "$shell_name" != "bash" ]; then
      ensure_line_in_file "$HOME/.profile" "$export_line" "$marker"
      ensure_line_in_file "$HOME/.bashrc" "$export_line" "$marker"
      ensure_line_in_file "$HOME/.zshrc" "$export_line" "$marker"
      ensure_line_in_file "$HOME/.zprofile" "$export_line" "$marker"
    fi
  fi

  export PATH="$HOME/.local/bin:$PATH"

  if [ $updated -eq 0 ]; then
    info "PATH already appears configured for $install_bin"
  fi
}

install_codex_cli_shim() {
  step "Checking Codex CLI..."

  local current_codex=""
  local shim_path="$HOME/.local/bin/codex"

  CODEX_SHIM_PATH="$shim_path"
  current_codex="$(command -v codex || true)"

  if [ -n "$current_codex" ] && codex_supports_plugins "$current_codex"; then
    success "Codex CLI already supports plugins: ${BOLD}${current_codex}${RESET}"
    return
  fi

  if [ ! -x "$CODEX_BUNDLED_BINARY" ] || ! codex_supports_plugins "$CODEX_BUNDLED_BINARY"; then
    if [ -n "$current_codex" ]; then
      CODEX_PLUGIN_HOST_WARNING="Codex CLI at ${current_codex} does not support local plugins. Install or update Codex.app to use /macroscope:macroscope from the CLI."
      warn "$CODEX_PLUGIN_HOST_WARNING"
    else
      CODEX_PLUGIN_HOST_WARNING="Codex CLI is not installed. Install Codex.app to use /macroscope:macroscope from the CLI."
      warn "$CODEX_PLUGIN_HOST_WARNING"
    fi
    return
  fi

  if [ -f "$shim_path" ] && ! is_managed_codex_shim "$shim_path"; then
    CODEX_PLUGIN_HOST_WARNING="Existing ${shim_path} was left untouched, so the current Codex CLI may still be too old for plugins."
    warn "$CODEX_PLUGIN_HOST_WARNING"
    return
  fi

  cat > "$shim_path" <<EOF
#!/bin/bash
set -euo pipefail
# Macroscope-managed Codex shim
exec "${CODEX_BUNDLED_BINARY}" "\$@"
EOF
  chmod +x "$shim_path"
  CODEX_SHIM_INSTALLED=1

  if [ -n "$current_codex" ]; then
    success "Installed Codex CLI shim at ${BOLD}${shim_path}${RESET}"
    info "Your previous Codex CLI at ${current_codex} does not support local plugins; ${BOLD}codex${RESET} will now use the bundled Codex.app binary."
  else
    success "Installed Codex CLI shim at ${BOLD}${shim_path}${RESET}"
    info "${BOLD}codex${RESET} is now available via the bundled Codex.app binary."
  fi
}

install_codex_plugin() {
  step "Installing Codex plugin..."

  local plugin_src="$CHECKOUT_DIR/plugins/macroscope"
  local plugin_dst="$HOME/plugins/macroscope"
  local codex_home=""
  local codex_cache_root=""
  local codex_cache_dst=""
  local marketplace_dst="$HOME/.agents/plugins/marketplace.json"
  local codex_config=""
  local marketplace_name=""
  local plugin_key=""

  codex_home="$(get_codex_home)"
  codex_cache_root="$codex_home/plugins/cache"
  codex_config="$codex_home/config.toml"

  mkdir -p "$HOME/plugins" "$HOME/.agents/plugins" "$codex_cache_root"
  copy_tree "$plugin_src" "$plugin_dst"

  marketplace_name="$(python3 - "$marketplace_dst" <<'PY'
import json
import os
import sys

path = sys.argv[1]

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
else:
    data = {
        "name": "local-user-plugins",
        "interface": {"displayName": "Local Plugins"},
        "plugins": [],
    }

data.setdefault("name", "local-user-plugins")
data.setdefault("interface", {})
data["interface"].setdefault("displayName", "Local Plugins")
plugins = [p for p in data.get("plugins", []) if p.get("name") != "macroscope"]
plugins.append(
    {
        "name": "macroscope",
        "source": {"source": "local", "path": "./plugins/macroscope"},
        "policy": {
            "installation": "INSTALLED_BY_DEFAULT",
            "authentication": "ON_USE",
        },
        "category": "Development",
    }
)
data["plugins"] = plugins

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(data["name"])
PY
)"

  codex_cache_dst="$codex_cache_root/$marketplace_name/macroscope/$CODEX_LOCAL_PLUGIN_VERSION"
  plugin_key="macroscope@$marketplace_name"
  copy_tree "$plugin_src" "$codex_cache_dst"

  python3 - "$codex_config" "$plugin_key" <<'PY'
import os
import re
import sys

path, plugin_key = sys.argv[1:3]

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
else:
    text = ""

if text and not text.endswith("\n"):
    text += "\n"

def ensure_section_value(payload: str, section: str, key: str, value: str) -> str:
    header = f"[{section}]"
    pattern = re.compile(
        rf"(?ms)^(\[{re.escape(section)}\]\n)(.*?)(?=^\[|\Z)"
    )
    match = pattern.search(payload)
    desired_line = f'{key} = {value}'

    if match:
        body = match.group(2)
        key_pattern = re.compile(rf"(?m)^{re.escape(key)}\s*=")
        lines = body.splitlines()
        replaced = False
        for idx, line in enumerate(lines):
            if key_pattern.match(line):
                lines[idx] = desired_line
                replaced = True
                break
        if not replaced:
            if lines and lines[-1] != "":
                lines.append(desired_line)
            else:
                lines.insert(len(lines) - 1 if lines else 0, desired_line)
        new_body = "\n".join(lines)
        if new_body and not new_body.endswith("\n"):
            new_body += "\n"
        return payload[: match.start()] + match.group(1) + new_body + payload[match.end() :]

    if payload and not payload.endswith("\n\n"):
        payload = payload.rstrip("\n") + "\n\n"
    return payload + header + "\n" + desired_line + "\n"

text = ensure_section_value(text, "features", "plugins", "true")
text = ensure_section_value(text, f'plugins."{plugin_key}"', "enabled", "true")

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY

  success "Installed Codex plugin source to ${BOLD}${plugin_dst}${RESET}"
  success "Installed Codex plugin cache to ${BOLD}${codex_cache_dst}${RESET}"
}

install_claude_plugin() {
  step "Installing Claude Code plugin..."

  local plugin_src="$CHECKOUT_DIR/plugins/macroscope"
  local marketplace_src="$CHECKOUT_DIR/.claude-plugin"
  local marketplace_root="$HOME/.claude/plugins/marketplaces/macroscope-local"
  local cache_dst="$HOME/.claude/plugins/cache/macroscope-local/macroscope/$PLUGIN_VERSION"
  local known_marketplaces="$HOME/.claude/plugins/known_marketplaces.json"
  local installed_plugins="$HOME/.claude/plugins/installed_plugins.json"
  local claude_settings="$HOME/.claude/settings.json"
  local now=""

  mkdir -p "$HOME/.claude/plugins/marketplaces" "$HOME/.claude/plugins/cache/macroscope-local/macroscope"

  rm -rf "$marketplace_root"
  mkdir -p "$marketplace_root"
  copy_tree "$marketplace_src" "$marketplace_root/.claude-plugin"
  mkdir -p "$marketplace_root/plugins"
  copy_claude_plugin_tree "$plugin_src" "$marketplace_root/plugins/macroscope"
  copy_claude_plugin_tree "$plugin_src" "$cache_dst"

  now="$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"))
PY
)"

  python3 - "$known_marketplaces" "$marketplace_root" "$now" <<'PY'
import json
import os
import sys

path, marketplace_root, now = sys.argv[1:4]

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
else:
    data = {}

data["macroscope-local"] = {
    "source": {"source": "directory", "path": marketplace_root},
    "installLocation": marketplace_root,
    "lastUpdated": now,
}

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

  python3 - "$claude_settings" "$marketplace_root" <<'PY'
import json
import os
import sys

path, marketplace_root = sys.argv[1:3]

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
else:
    data = {}

extra = data.setdefault("extraKnownMarketplaces", {})
extra["macroscope-local"] = {
    "source": {"source": "directory", "path": marketplace_root}
}

enabled = data.setdefault("enabledPlugins", {})
enabled["macroscope@macroscope-local"] = True

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

  python3 - "$installed_plugins" "$cache_dst" "$PLUGIN_VERSION" "$now" <<'PY'
import json
import os
import sys

path, install_path, version, now = sys.argv[1:5]
key = "macroscope@macroscope-local"

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
else:
    data = {"version": 2, "plugins": {}}

data.setdefault("version", 2)
plugins = data.setdefault("plugins", {})
existing = plugins.get(key, [])
installed_at = existing[0].get("installedAt", now) if existing else now
plugins[key] = [
    {
        "scope": "user",
        "installPath": install_path,
        "version": version,
        "installedAt": installed_at,
        "lastUpdated": now,
    }
]

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

  success "Installed Claude Code plugin to ${BOLD}${cache_dst}${RESET}"
}

install_cursor_plugin() {
  step "Installing Cursor plugin..."

  local plugin_src="$CHECKOUT_DIR/plugins/macroscope"
  local cursor_dst="$HOME/.cursor/plugins/local/macroscope"

  if [ ! -f "$plugin_src/.cursor-plugin/plugin.json" ]; then
    warn "Cursor manifest not found in the plugin bundle; skipping Cursor installation."
    return
  fi

  mkdir -p "$HOME/.cursor/plugins/local"
  copy_tree "$plugin_src" "$cursor_dst"

  success "Installed Cursor plugin to ${BOLD}${cursor_dst}${RESET}"
}

install_opencode_support() {
  step "Installing OpenCode plugin, commands, and skills..."

  local plugin_src="$CHECKOUT_DIR/plugins/macroscope"
  local commands_src="$plugin_src/commands"
  local skills_src="$plugin_src/skills"
  local plugin_file="$plugin_src/opencode/macroscope.js"
  local opencode_root="$HOME/.config/opencode"
  local opencode_commands="$opencode_root/commands"
  local opencode_skills="$opencode_root/skills"
  local opencode_plugins="$opencode_root/plugins"
  local command_name=""
  local skill_name=""

  if [ ! -d "$commands_src" ] || [ ! -d "$skills_src" ] || [ ! -f "$plugin_file" ]; then
    warn "OpenCode plugin, command, or skill files were not found in the plugin bundle; skipping OpenCode installation."
    return
  fi

  mkdir -p "$opencode_commands" "$opencode_skills" "$opencode_plugins"

  cp "$plugin_file" "$opencode_plugins/macroscope.js"

  cp "$commands_src/macroscope.md" "$opencode_commands/macroscope.md"
  copy_tree "$skills_src/macroscope" "$opencode_skills/macroscope"

  success "Installed OpenCode plugin to ${BOLD}${opencode_plugins}/macroscope.js${RESET}"
  success "Installed OpenCode commands to ${BOLD}${opencode_commands}${RESET}"
  success "Installed OpenCode skills to ${BOLD}${opencode_skills}${RESET}"
}

verify_install() {
  step "Verifying installation..."

  if [ -n "$INSTALLED_BINARY" ] && [ -x "$INSTALLED_BINARY" ]; then
    success "Binary exists at: ${BOLD}${INSTALLED_BINARY}${RESET}"
  else
    warn "Installed binary path not found/executable: ${INSTALLED_BINARY}"
  fi

  if command -v macroscope >/dev/null 2>&1; then
    success "macroscope is on PATH: ${BOLD}$(command -v macroscope)${RESET}"
  else
    warn "macroscope is not currently on PATH in this shell."
    echo "Open a new terminal or run:"
    printf "  ${CYAN}source ~/.zprofile${RESET}   (zsh)\n"
    printf "  ${CYAN}source ~/.bash_profile${RESET} (bash)\n"
    printf "  ${CYAN}exec fish${RESET}           (fish)\n"
  fi

  local codex_home=""
  local codex_source=""
  local codex_cache=""
  local codex_marketplace_name=""
  local codex_cli=""

  codex_home="$(get_codex_home)"
  codex_source="$HOME/plugins/macroscope"
  codex_marketplace_name="$(python3 - <<'PY'
import json
import os

path = os.path.expanduser("~/.agents/plugins/marketplace.json")
name = "local-user-plugins"

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    name = data.get("name", name)

print(name)
PY
)"
  codex_cache="$codex_home/plugins/cache/$codex_marketplace_name/macroscope/$CODEX_LOCAL_PLUGIN_VERSION"

  if [ -f "$codex_source/.codex-plugin/plugin.json" ]; then
    success "Codex plugin installed"
  else
    warn "Codex plugin install did not produce ~/plugins/macroscope"
  fi

  if [ -f "$codex_cache/.codex-plugin/plugin.json" ]; then
    success "Codex plugin cache installed"
  else
    warn "Codex plugin cache install did not produce the expected cache entry"
  fi

  if [ -f "$HOME/.claude/plugins/cache/macroscope-local/macroscope/$PLUGIN_VERSION/.claude-plugin/plugin.json" ]; then
    success "Claude Code plugin installed"
  else
    warn "Claude Code plugin install did not produce the expected cache entry"
  fi

  if [ -f "$HOME/.cursor/plugins/local/macroscope/.cursor-plugin/plugin.json" ]; then
    success "Cursor plugin installed"
  else
    warn "Cursor plugin install did not produce the expected local plugin entry"
  fi

  if [ -f "$HOME/.config/opencode/plugins/macroscope.js" ] && [ -f "$HOME/.config/opencode/commands/macroscope.md" ] && [ -f "$HOME/.config/opencode/skills/macroscope/SKILL.md" ]; then
    success "OpenCode plugin, commands, and skills installed"
  else
    warn "OpenCode install did not produce the expected plugin, command, and skill files"
  fi

  codex_cli="$(command -v codex || true)"
  if [ -n "$codex_cli" ] && codex_supports_plugins "$codex_cli"; then
    success "Codex CLI supports plugins: ${BOLD}${codex_cli}${RESET}"
  elif [ -n "$CODEX_PLUGIN_HOST_WARNING" ]; then
    warn "$CODEX_PLUGIN_HOST_WARNING"
  else
    warn "Codex CLI is not available for plugin verification in this shell"
  fi
}

print_installation_completion() {
  echo ""
  printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
  printf "${GREEN}${BOLD}Installation Complete!${RESET}\n"
  printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
  echo ""
  printf "${BOLD}Verify installation:${RESET}\n"
  printf "  ${CYAN}macroscope --help${RESET}\n"
  echo ""
  printf "${BOLD}Quick start:${RESET}\n"
  printf "  ${CYAN}macroscope${RESET}                     ${DIM}# Launch the interactive wizard${RESET}\n"
  printf "  ${CYAN}macroscope codereview --base staging${RESET} ${DIM}# Run the CLI directly${RESET}\n"
  printf "  ${CYAN}/macroscope${RESET}                  ${DIM}# Local review in Claude Code or OpenCode${RESET}\n"
  printf "  ${CYAN}/macroscope loop${RESET}             ${DIM}# Autopilot loop in Claude Code or OpenCode${RESET}\n"
  printf "  ${CYAN}/macroscope:macroscope${RESET}      ${DIM}# Local review in Codex or Cursor${RESET}\n"
  printf "  ${CYAN}/macroscope:macroscope loop${RESET} ${DIM}# Autopilot loop in Codex or Cursor${RESET}\n"
  echo ""
  printf "${BOLD}Notes:${RESET}\n"
  printf "  Restart Codex, Claude Code, Cursor, or OpenCode if they were already open.\n"
  printf "  /macroscope now defaults to the local streaming CLI review path.\n"
  printf "  /macroscope loop runs the full review-fix-push-re-review autopilot cycle.\n"
  printf "  Local review validates each issue before acting and keeps poll sleeps capped at 60 seconds.\n"
  if [ "$CODEX_SHIM_INSTALLED" = "1" ]; then
    printf "  ${BOLD}codex${RESET} now points at the bundled Codex.app CLI so plugins work from the terminal.\n"
  elif [ -n "$CODEX_PLUGIN_HOST_WARNING" ]; then
    printf "  ${YELLOW}%s${RESET}\n" "$CODEX_PLUGIN_HOST_WARNING"
  fi
  echo ""
  printf "${BOLD}Need help?${RESET}\n"
  printf "  Documentation: ${BLUE}https://github.com/prassoai/macroscope-local${RESET}\n"
  printf "  Report issues: ${BLUE}https://github.com/prassoai/macroscope-local/issues${RESET}\n"
  echo ""
}

launch_wizard() {
  if [ "${MACROSCOPE_SKIP_WIZARD:-0}" = "1" ]; then
    info "Skipping wizard launch (MACROSCOPE_SKIP_WIZARD=1)."
    return
  fi

  if [ ! -e /dev/tty ] || [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    info "No TTY available; run 'macroscope' later to start the setup wizard."
    return
  fi

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
  if ! "$bin_path" < /dev/tty > /dev/tty 2>&1; then
    warn "Wizard exited with a non-zero status. You can rerun it anytime with: macroscope"
  fi
}

main() {
  if command -v clear >/dev/null 2>&1 && [ -t 1 ]; then
    clear || true
  fi
  print_banner

  step "Checking system requirements..."
  check_dependencies
  detect_platform
  determine_install_dir
  prepare_tmp_dir
  resolve_version "$@"

  install_binary
  fetch_plugin_bundle
  update_shell_config
  install_codex_cli_shim
  install_codex_plugin
  install_claude_plugin
  install_cursor_plugin
  install_opencode_support
  seed_local_build_config_if_needed
  verify_install
  print_installation_completion
  launch_wizard
}

main "$@"
