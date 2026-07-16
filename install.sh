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

repair_only_requested() {
  [ "${MACROSCOPE_REPAIR_ONLY:-0}" = "1" ]
}

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

remove_file_if_present() {
  local path="$1"
  [ -f "$path" ] || return 1
  if rm -f "$path" 2>/dev/null; then
    success "Removed $path"
    return 0
  fi
  warn "Could not remove $path"
  return 1
}

remove_dir_if_present() {
  local path="$1"
  [ -d "$path" ] || return 1
  if rm -rf "$path" 2>/dev/null; then
    success "Removed $path"
    return 0
  fi
  warn "Could not remove $path"
  return 1
}

kill_running_processes() {
  local found=0
  local name=""
  local pids=""
  local pid=""
  local deadline=""

  if ! command -v pgrep >/dev/null 2>&1; then
    info "pgrep not available; skipping process cleanup"
    return
  fi

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
  done

  if [ "$found" -eq 0 ]; then
    info "No running Macroscope processes found"
  else
    success "Stopped running Macroscope processes"
  fi
}

cleanup_binaries() {
  local removed=0
  local path=""
  local shim_path="$HOME/.local/bin/codex"

  for path in \
    "$HOME/.local/bin/macroscope" \
    "$HOME/.local/bin/macroscope.old" \
    "$HOME/.local/bin/macroscope-mcp" \
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

  if is_managed_codex_shim "$shim_path"; then
    if remove_file_if_present "$shim_path"; then
      removed=1
    fi
  fi

  if [ "$removed" -eq 0 ]; then
    info "No stale Macroscope binaries found"
  fi
}

remove_plugin_directories() {
  local removed=0
  local codex_home=""
  local codex_plugin_cache_root=""
  local codex_marketplace_json=""
  local dir=""
  local file=""
  local marketplace_name=""

  codex_home="$(get_codex_home)"
  codex_plugin_cache_root="$codex_home/plugins/cache"
  codex_marketplace_json="$HOME/.agents/plugins/marketplace.json"

  for dir in \
    "$HOME/plugins/macroscope" \
    "$HOME/plugins/macroscope-codereview" \
    "$codex_home/plugins/macroscope" \
    "$codex_home/plugins/macroscope-codereview" \
    "$HOME/.claude/plugins/marketplaces/macroscope-local" \
    "$HOME/.claude/plugins/cache/macroscope-local" \
    "$HOME/.cursor/plugins/local/macroscope" \
    "$HOME/.cursor/plugins/local/macroscope-codereview" \
    "$HOME/.config/opencode/skills/macroscope" \
    "$HOME/.config/opencode/skills/codereview" \
    "$HOME/.config/opencode/skills/autoloop" \
    "$HOME/.config/opencode/skills/macroscope-local-review" \
    "$HOME/.config/opencode/skills/macroscope-triage-pr-comments" \
    "$HOME/.config/opencode/skills/macroscope-respond-to-pr-comments" \
    "$HOME/.config/opencode/skills/macroscope-review-pr" \
    "$HOME/.config/opencode/skills/local-review" \
    "$HOME/.config/opencode/skills/triage-pr-comments" \
    "$HOME/.config/opencode/skills/respond-to-pr-comments" \
    "$HOME/.config/opencode/skills/review-pr"
  do
    if remove_dir_if_present "$dir"; then
      removed=1
    fi
  done

  if [ -d "$codex_plugin_cache_root" ]; then
    while IFS= read -r marketplace_name; do
      [ -n "$marketplace_name" ] || continue
      for dir in \
        "$codex_plugin_cache_root/$marketplace_name/macroscope" \
        "$codex_plugin_cache_root/$marketplace_name/macroscope-codereview"
      do
        if remove_dir_if_present "$dir"; then
          removed=1
        fi
      done
    done < <(
      python3 - "$codex_marketplace_json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
names = {"local-user-plugins"}
owned_names = {"macroscope", "macroscope-codereview"}
owned_paths = {
    "./plugins/macroscope",
    "plugins/macroscope",
    "./plugins/macroscope-codereview",
    "plugins/macroscope-codereview",
}

if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = None
    if isinstance(data, dict):
        marketplace_name = data.get("name")
        plugins = data.get("plugins")
        if isinstance(marketplace_name, str) and isinstance(plugins, list):
            for item in plugins:
                if not isinstance(item, dict):
                    continue
                name = item.get("name")
                source = item.get("source")
                source_path = source.get("path") if isinstance(source, dict) else None
                if name in owned_names and source_path in owned_paths:
                    names.add(marketplace_name.strip())
                    break

for name in sorted(name for name in names if name):
    print(name)
PY
    )
  fi

  for file in \
    "$HOME/.config/opencode/plugins/macroscope.js" \
    "$HOME/.config/opencode/commands/macroscope.md" \
    "$HOME/.config/opencode/commands/macroscope-codereview.md" \
    "$HOME/.config/opencode/commands/macroscope-autoloop.md" \
    "$HOME/.config/opencode/commands/macroscope-local-review.md" \
    "$HOME/.config/opencode/commands/macroscope-triage-pr-comments.md" \
    "$HOME/.config/opencode/commands/macroscope-respond-to-pr-comments.md" \
    "$HOME/.config/opencode/commands/macroscope-review-pr.md" \
    "$HOME/.config/opencode/commands/local-review.md" \
    "$HOME/.config/opencode/commands/triage-pr-comments.md" \
    "$HOME/.config/opencode/commands/respond-to-pr-comments.md" \
    "$HOME/.config/opencode/commands/review-pr.md" \
    "$HOME/.claude/hooks/macroscope-bash-autoallow.sh"
  do
    if remove_file_if_present "$file"; then
      removed=1
    fi
  done

  if [ "$removed" -eq 0 ]; then
    info "No stale plugin directories or command files found"
  fi
}

clean_json_and_toml_state() {
  local codex_home=""

  codex_home="$(get_codex_home)"

  python3 - \
    "$HOME/.agents/plugins/marketplace.json" \
    "$codex_home/config.toml" \
    "$HOME/.claude.json" \
    "$HOME/.claude/plugins/known_marketplaces.json" \
    "$HOME/.claude/plugins/installed_plugins.json" \
    "$HOME/.claude/settings.json" \
    "$HOME/.claude/settings.local.json" \
    "$HOME/.cursor/mcp.json" <<'PY'
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


OWNED_RELATIVE_PLUGIN_PATHS = {
    "./plugins/macroscope",
    "plugins/macroscope",
    "./plugins/macroscope-codereview",
    "plugins/macroscope-codereview",
}


def normalized_string(value):
    if not isinstance(value, str):
        return ""
    return value.strip().lower()


def is_owned_relative_plugin_path(value):
    value = normalized_string(value)
    return value in OWNED_RELATIVE_PLUGIN_PATHS


def get_owned_marketplace_names(data):
    names = {"local-user-plugins"}
    if not isinstance(data, dict):
        return names

    marketplace_name = normalized_string(data.get("name"))
    plugins = data.get("plugins")
    if not marketplace_name or not isinstance(plugins, list):
        return names

    for item in plugins:
        if not isinstance(item, dict):
            continue
        name = normalized_string(item.get("name"))
        source = item.get("source")
        source_path = source.get("path") if isinstance(source, dict) else None
        if name in {"macroscope", "macroscope-codereview"} and is_owned_relative_plugin_path(source_path):
            names.add(marketplace_name)
            break

    return names


def get_owned_plugin_keys(marketplace_names):
    keys = set()
    for marketplace_name in marketplace_names:
        if not marketplace_name:
            continue
        keys.add(f'macroscope@{marketplace_name}')
        keys.add(f'macroscope-codereview@{marketplace_name}')
    return keys


def drop_owned_marketplace_plugins(entries):
    if not isinstance(entries, list):
        return entries, False

    changed = False
    filtered = []
    for item in entries:
        if not isinstance(item, dict):
            filtered.append(item)
            continue

        name = normalized_string(item.get("name"))
        source = item.get("source")
        source_path = source.get("path") if isinstance(source, dict) else None
        if name in {"macroscope", "macroscope-codereview"} and is_owned_relative_plugin_path(source_path):
            changed = True
            continue

        filtered.append(item)

    return filtered, changed


def load_json(path):
    if not os.path.exists(path):
        return None, None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f), os.stat(path).st_mode
    except Exception:
        return None, None


def write_json(path, data, mode):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    if mode is not None:
        os.chmod(path, mode)


marketplace_data, marketplace_mode = load_json(codex_marketplace)
owned_marketplace_names = get_owned_marketplace_names(marketplace_data)
owned_plugin_keys = get_owned_plugin_keys(owned_marketplace_names)
if isinstance(marketplace_data, dict):
    plugins = marketplace_data.get("plugins")
    filtered, changed = drop_owned_marketplace_plugins(plugins)
    if changed:
        marketplace_data["plugins"] = filtered
        write_json(codex_marketplace, marketplace_data, marketplace_mode)


if os.path.exists(codex_config):
    mode = os.stat(codex_config).st_mode
    with open(codex_config, "r", encoding="utf-8") as f:
        text = f.read()

    new_text = text
    for plugin_key in sorted(owned_plugin_keys):
        new_text = re.sub(
            rf'(?ms)^\[plugins\."{re.escape(plugin_key)}"\]\n.*?(?=^\[|\Z)',
            "",
            new_text,
        )
    new_text = re.sub(r'(?ms)^\[mcp_servers\.macroscope-codereview\]\n.*?(?=^\[|\Z)', "", new_text)
    new_text = re.sub(r'(?m)^# Added by Macroscope installer\n?', "", new_text)
    new_text = re.sub(r'\n{3,}', '\n\n', new_text).strip()
    if new_text:
        new_text += "\n"

    if new_text != text:
        with open(codex_config, "w", encoding="utf-8") as f:
            f.write(new_text)
        os.chmod(codex_config, mode)


claude_data, claude_mode = load_json(claude_json)
if isinstance(claude_data, dict):
    changed = False

    servers = claude_data.get("mcpServers")
    if isinstance(servers, dict) and "macroscope-codereview" in servers:
        del servers["macroscope-codereview"]
        changed = True

    projects = claude_data.get("projects")
    if isinstance(projects, dict):
        for project in projects.values():
            if not isinstance(project, dict):
                continue
            project_servers = project.get("mcpServers")
            if isinstance(project_servers, dict) and "macroscope-codereview" in project_servers:
                del project_servers["macroscope-codereview"]
                changed = True

    if changed:
        write_json(claude_json, claude_data, claude_mode)


known_marketplaces_data, known_marketplaces_mode = load_json(claude_known_marketplaces)
if isinstance(known_marketplaces_data, dict) and "macroscope-local" in known_marketplaces_data:
    del known_marketplaces_data["macroscope-local"]
    write_json(claude_known_marketplaces, known_marketplaces_data, known_marketplaces_mode)


installed_plugins_data, installed_plugins_mode = load_json(claude_installed_plugins)
if isinstance(installed_plugins_data, dict):
    plugins = installed_plugins_data.get("plugins")
    if isinstance(plugins, dict) and "macroscope@macroscope-local" in plugins:
        del plugins["macroscope@macroscope-local"]
        write_json(claude_installed_plugins, installed_plugins_data, installed_plugins_mode)


for path in (claude_settings, claude_settings_local):
    data, mode = load_json(path)
    if not isinstance(data, dict):
        continue

    changed = False

    extra = data.get("extraKnownMarketplaces")
    if isinstance(extra, dict) and "macroscope-local" in extra:
        del extra["macroscope-local"]
        changed = True
        if not extra:
            data.pop("extraKnownMarketplaces", None)

    enabled = data.get("enabledPlugins")
    if isinstance(enabled, dict) and "macroscope@macroscope-local" in enabled:
        del enabled["macroscope@macroscope-local"]
        changed = True
        if not enabled:
            data.pop("enabledPlugins", None)

    permissions = data.get("permissions")
    if isinstance(permissions, dict):
        allow = permissions.get("allow")
        _owned = {"Bash(macroscope)", "Bash(macroscope *)", "Bash(macroscope:*)", "Bash(mktemp)", "Bash(mktemp *)", "Bash(mktemp:*)"}
        if isinstance(allow, list) and any(x in _owned for x in allow):
            permissions["allow"] = [x for x in allow if x not in _owned]
            changed = True
            if not permissions["allow"]:
                del permissions["allow"]
            if not permissions:
                data.pop("permissions", None)

    # Remove the PreToolUse Bash hook we installed, preserving any other
    # hooks the user configured. Only the macroscope-owned entry is dropped.
    hooks_cfg = data.get("hooks")
    if isinstance(hooks_cfg, dict):
        pre_tool_use = hooks_cfg.get("PreToolUse")
        if isinstance(pre_tool_use, list):
            filtered = []
            for entry in pre_tool_use:
                ours = False
                if isinstance(entry, dict):
                    for h in entry.get("hooks", []) or []:
                        if isinstance(h, dict):
                            cmd = h.get("command", "")
                            if "macroscope-bash-autoallow" in cmd or "macroscope-installer" in cmd:
                                ours = True
                                break
                if not ours:
                    filtered.append(entry)
            if filtered != pre_tool_use:
                changed = True
                if filtered:
                    hooks_cfg["PreToolUse"] = filtered
                else:
                    del hooks_cfg["PreToolUse"]
        if not hooks_cfg:
            data.pop("hooks", None)

    if changed:
        write_json(path, data, mode)


cursor_data, cursor_mode = load_json(cursor_mcp_json)
if isinstance(cursor_data, dict):
    servers = cursor_data.get("mcpServers")
    if isinstance(servers, dict) and "macroscope-codereview" in servers:
        del servers["macroscope-codereview"]
        write_json(cursor_mcp_json, cursor_data, cursor_mode)


cursor_cli_config = os.path.expanduser("~/.cursor/cli-config.json")
cursor_cli_data, cursor_cli_mode = load_json(cursor_cli_config)
if isinstance(cursor_cli_data, dict):
    changed = False
    _owned_shell = {"Shell(macroscope)", "Shell(macroscope *)", "Shell(mktemp)", "Shell(mktemp *)"}
    permissions = cursor_cli_data.get("permissions")
    if isinstance(permissions, dict):
        allow = permissions.get("allow")
        if isinstance(allow, list):
            filtered = [r for r in allow if r not in _owned_shell]
            if filtered != allow:
                permissions["allow"] = filtered
                changed = True
    if changed:
        write_json(cursor_cli_config, cursor_cli_data, cursor_cli_mode)


opencode_config = os.path.expanduser("~/.config/opencode/opencode.json")
opencode_data, opencode_mode = load_json(opencode_config)
if isinstance(opencode_data, dict):
    changed = False
    permission = opencode_data.get("permission")
    if isinstance(permission, dict):
        bash = permission.get("bash")
        if isinstance(bash, dict):
            for key in ("macroscope", "macroscope *", "mktemp", "mktemp *"):
                if key in bash:
                    del bash[key]
                    changed = True
            if not bash:
                del permission["bash"]
        if not permission:
            del opencode_data["permission"]
    if changed:
        write_json(opencode_config, opencode_data, opencode_mode)
PY
}

cleanup_cli_registrations() {
  if command -v claude >/dev/null 2>&1; then
    if claude mcp remove macroscope-codereview -s user >/dev/null 2>&1; then
      success "Removed legacy Claude Code MCP registration"
    fi
    # Claude Code maintains internal plugin state beyond the JSON config files
    # on disk — disable + uninstall via CLI to reach that internal state.
    # No timeout wrapper: macOS lacks `timeout` in base install; the Go
    # uninstaller (primary path) already uses 10s timeouts per call.
    local _plugin_removed=0
    for plugin_id in macroscope@macroscope-local macroscope-codereview@macroscope-local; do
      claude plugins disable "$plugin_id" >/dev/null 2>&1 || true
      if claude plugins uninstall "$plugin_id" >/dev/null 2>&1; then
        _plugin_removed=1
      fi
    done
    if claude plugins marketplace remove macroscope-local >/dev/null 2>&1; then
      _plugin_removed=1
    fi
    [ "$_plugin_removed" -eq 1 ] && success "Removed plugin from Claude Code CLI"
  fi

  if command -v gemini >/dev/null 2>&1; then
    if gemini mcp remove macroscope-codereview >/dev/null 2>&1; then
      success "Removed legacy Gemini MCP registration"
    fi
  fi
}

repair_existing_install() {
  step "Repairing install-owned Macroscope state..."

  kill_running_processes
  cleanup_binaries
  remove_plugin_directories
  clean_json_and_toml_state
  cleanup_cli_registrations
  kill_running_processes
}

check_dependencies() {
  local missing_deps=()
  local deps=(python3)

  if ! repair_only_requested; then
    deps=(curl git python3)
  fi

  for cmd in "${deps[@]}"; do
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

  CHECKOUT_DIR="$TMP_DIR/macroscope-local"
  local bundle_url=""
  local bundle_archive="$TMP_DIR/macroscope-plugin-bundle.tar.gz"
  local local_back_plugin_root=""

  is_plugin_bundle_root() {
    local root="$1"
    [ -f "$root/.claude-plugin/marketplace.json" ] && \
      [ -f "$root/plugins/macroscope/.claude-plugin/plugin.json" ] && \
      [ -f "$root/plugins/macroscope/.codex-plugin/plugin.json" ] && \
      [ -f "$root/plugins/macroscope/.cursor-plugin/plugin.json" ]
  }

  if [ -n "${MACROSCOPE_LOCAL_BACK_REPO:-}" ]; then
    local_back_plugin_root="${MACROSCOPE_LOCAL_BACK_REPO}/tools/cmd/macrodaemon/public-plugin"
    if ! is_plugin_bundle_root "$local_back_plugin_root"; then
      error "Back repo is missing the public plugin bundle at ${local_back_plugin_root}"
      exit 1
    fi
    copy_tree "$local_back_plugin_root" "$CHECKOUT_DIR"
    success "Using public plugin bundle from ${BOLD}${MACROSCOPE_LOCAL_BACK_REPO}${RESET}"
  elif [ -n "${MACROSCOPE_PLUGIN_BUNDLE_SOURCE:-}" ]; then
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
    else
      error "Failed to download the released plugin bundle."
      echo ""
      echo "Try again in a minute, or set MACROSCOPE_LOCAL_BACK_REPO for a local branch install."
      exit 1
    fi
  fi

  if ! is_plugin_bundle_root "$CHECKOUT_DIR"; then
    error "Fetched plugin bundle is missing the required Macroscope plugin files."
    exit 1
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

strip_host_overlays() {
  local dst="$1"
  rm -rf "$dst/host-overlays"
}

apply_claude_overlay() {
  local src="$1"
  local dst="$2"
  local overlay_src="$src/host-overlays/claude"

  if [ -d "$overlay_src" ]; then
    cp -R "$overlay_src/." "$dst/"
  fi

  strip_host_overlays "$dst"
}

apply_codex_overlay() {
  local src="$1"
  local dst="$2"
  local overlay_src="$src/host-overlays/codex"

  if [ -d "$overlay_src" ]; then
    cp -R "$overlay_src/." "$dst/"
  fi

  strip_host_overlays "$dst"
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

  if [ -n "$current_codex" ] && [ "$current_codex" = "$CODEX_BUNDLED_BINARY" ] && codex_supports_plugins "$current_codex"; then
    success "Codex CLI already uses the bundled Codex.app binary: ${BOLD}${current_codex}${RESET}"
    return
  fi

  if [ ! -x "$CODEX_BUNDLED_BINARY" ] || ! codex_supports_plugins "$CODEX_BUNDLED_BINARY"; then
    if [ -n "$current_codex" ]; then
      CODEX_PLUGIN_HOST_WARNING="Codex CLI at ${current_codex} does not support local plugins. Install or update Codex.app to use /macroscope:codereview from the CLI."
      warn "$CODEX_PLUGIN_HOST_WARNING"
    else
      CODEX_PLUGIN_HOST_WARNING="Codex CLI is not installed. Install Codex.app to use /macroscope:codereview from the CLI."
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

  if [ -n "$current_codex" ] && [ "$current_codex" != "$shim_path" ]; then
    success "Installed Codex CLI shim at ${BOLD}${shim_path}${RESET}"
    info "${BOLD}codex${RESET} will now use the bundled Codex.app binary instead of ${current_codex}."
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
  apply_codex_overlay "$plugin_src" "$plugin_dst"
  apply_codex_overlay "$plugin_src" "$codex_cache_dst"

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
  apply_claude_overlay "$plugin_src" "$marketplace_root/plugins/macroscope"
  apply_claude_overlay "$plugin_src" "$cache_dst"

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

# Auto-allow the macroscope CLI + mktemp. The plain allow rules cover
# bare invocations (`macroscope codereview --base staging`). Claude Code's
# allow-list pattern matcher tokenizes on shell operators, so commands
# like `macroscope codereview > /tmp/foo 2>&1` or `review_log="$(mktemp
# ...)"` do not match glob rules. For those cases the installer also
# registers a PreToolUse hook (see register_claude_bash_autoallow_hook)
# that inspects the raw tool_input and auto-approves any Bash command
# whose first token is `macroscope` or `mktemp`, regardless of shell
# operators that follow.
permissions = data.setdefault("permissions", {})
allow = permissions.setdefault("allow", [])
for rule in (
    "Bash(macroscope *)",
    "Bash(macroscope:*)",
    "Bash(mktemp *)",
    "Bash(mktemp:*)",
):
    if rule not in allow:
        allow.append(rule)

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

  register_claude_bash_autoallow_hook
  success "Installed Claude Code plugin to ${BOLD}${cache_dst}${RESET}"
}

# register_claude_bash_autoallow_hook installs the PreToolUse hook script
# and registers it in ~/.claude/settings.json. This closes a gap in the
# plain allow-list patterns: Claude Code's Bash matcher tokenizes on
# shell operators, so `Bash(macroscope *)` stops matching as soon as the
# command contains `|`, `>`, `$(...)`, or `&&`. The hook inspects the
# raw command string and approves any macroscope/mktemp invocation,
# regardless of shell operators around it.
register_claude_bash_autoallow_hook() {
  local script_src="$(dirname "$0")/scripts/claude-bash-autoallow.sh"
  if [ ! -f "$script_src" ]; then
    script_src="$CHECKOUT_DIR/scripts/claude-bash-autoallow.sh"
  fi
  # When installed via `curl | bash`, the installer has no $0 path to
  # resolve a sibling script from — in that case we embed the script
  # via a HEREDOC below instead of copying from disk.
  local hook_dst="$HOME/.claude/hooks/macroscope-bash-autoallow.sh"
  mkdir -p "$HOME/.claude/hooks"

  if [ -f "$script_src" ]; then
    cp "$script_src" "$hook_dst"
  else
    cat > "$hook_dst" <<'EMBED'
#!/usr/bin/env python3
"""PreToolUse hook that auto-approves Bash calls whose effective command
word is macroscope or mktemp, regardless of shell operators around it."""
import json, re, sys

def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    if payload.get("tool_name") != "Bash":
        return 0
    command = str(payload.get("tool_input", {}).get("command", "")).strip()
    if not command:
        return 0
    for name in ("macroscope", "mktemp"):
        pattern = r"(?:^|[\s;|&=(]|[$]\()" + re.escape(name) + r"(?:\s|$|;|\||&|>|<)"
        if re.search(pattern, command):
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": f"macroscope-installer: auto-approve {name}",
                },
            }))
            return 0
    return 0

if __name__ == "__main__":
    sys.exit(main())
EMBED
  fi
  chmod +x "$hook_dst"

  python3 - "$HOME/.claude/settings.json" "$hook_dst" <<'PY'
import json, os, sys

settings_path, hook_path = sys.argv[1:3]

if os.path.exists(settings_path):
    with open(settings_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    mode = os.stat(settings_path).st_mode
else:
    data = {}
    mode = None

hooks = data.setdefault("hooks", {})
pre_tool_use = hooks.setdefault("PreToolUse", [])

marker = "macroscope-installer: auto-approve"
# Replace any prior entry we installed, preserve entries the user added.
def is_ours(entry):
    if not isinstance(entry, dict):
        return False
    for h in entry.get("hooks", []):
        if not isinstance(h, dict):
            continue
        cmd = h.get("command", "")
        if "macroscope-bash-autoallow" in cmd or marker in cmd:
            return True
    return False

pre_tool_use[:] = [e for e in pre_tool_use if not is_ours(e)]
pre_tool_use.append({
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": hook_path}],
})

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
if mode is not None:
    os.chmod(settings_path, mode)
PY
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
  strip_host_overlays "$cursor_dst"

  # Auto-allow the macroscope CLI in Cursor's CLI agent so the skill does not
  # stall on per-argv approval prompts. Cursor's allowlist pattern is
  # `Shell(<command>)`; we add the wildcard form matching any arguments and
  # preserve any existing user rules.
  python3 - "$HOME/.cursor/cli-config.json" <<'PY'
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    mode = os.stat(path).st_mode
else:
    data = {}
    mode = None

permissions = data.setdefault("permissions", {})
allow = permissions.setdefault("allow", [])
permissions.setdefault("deny", [])

for rule in (
    "Shell(macroscope)",
    "Shell(macroscope *)",
    "Shell(mktemp)",
    "Shell(mktemp *)",
):
    if rule not in allow:
        allow.append(rule)

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
if mode is not None:
    os.chmod(path, mode)
PY

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

  # OpenCode uses flat namespaces for both skills and commands. We avoid
  # the earlier `review`/`loop` collision risk by naming the skills
  # `codereview` and `autoloop` at the source — distinctive enough that
  # no rewrite or per-host prefix is needed. Commands live as
  # `macroscope-codereview` and `macroscope-autoloop` so typing `/macro`
  # surfaces both in the OpenCode command palette.
  cp "$commands_src/macroscope-codereview.md" "$opencode_commands/macroscope-codereview.md"
  if [ -f "$commands_src/macroscope-autoloop.md" ]; then
    cp "$commands_src/macroscope-autoloop.md" "$opencode_commands/macroscope-autoloop.md"
  fi
  copy_tree "$skills_src/codereview" "$opencode_skills/codereview"
  copy_tree "$skills_src/autoloop" "$opencode_skills/autoloop"

  # Auto-allow the macroscope CLI in OpenCode so the skill does not stall on
  # per-argv approval prompts. OpenCode reads `~/.config/opencode/opencode.json`
  # and matches bash rules by pattern with last-match-wins semantics. We only
  # set the macroscope key, leaving any catch-all or existing rules untouched.
  python3 - "$opencode_root/opencode.json" <<'PY'
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    mode = os.stat(path).st_mode
else:
    data = {}
    mode = None

permission = data.setdefault("permission", {})
bash = permission.setdefault("bash", {})
bash.setdefault("macroscope *", "allow")
bash.setdefault("macroscope", "allow")
bash.setdefault("mktemp *", "allow")
bash.setdefault("mktemp", "allow")

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
if mode is not None:
    os.chmod(path, mode)
PY

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

  if [ -f "$HOME/.claude/plugins/cache/macroscope-local/macroscope/$PLUGIN_VERSION/.claude-plugin/plugin.json" ] && \
     [ -f "$HOME/.claude/plugins/cache/macroscope-local/macroscope/$PLUGIN_VERSION/skills/codereview/SKILL.md" ] && \
     [ -f "$HOME/.claude/plugins/cache/macroscope-local/macroscope/$PLUGIN_VERSION/skills/autoloop/SKILL.md" ]; then
    success "Claude Code plugin installed with skills"
  else
    warn "Claude Code plugin install did not produce the expected cache entry"
  fi

  if [ -f "$HOME/.cursor/plugins/local/macroscope/.cursor-plugin/plugin.json" ]; then
    success "Cursor plugin installed"
  else
    warn "Cursor plugin install did not produce the expected local plugin entry"
  fi

  if [ -f "$HOME/.config/opencode/plugins/macroscope.js" ] && [ -f "$HOME/.config/opencode/commands/macroscope-codereview.md" ] && [ -f "$HOME/.config/opencode/skills/codereview/SKILL.md" ]; then
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
  printf "  ${CYAN}macroscope codereview --base <base_branch>${RESET} ${DIM}# Run the CLI directly${RESET}\n"
  printf "  ${CYAN}/macroscope:codereview${RESET}           ${DIM}# Local review${RESET}\n"
  printf "  ${CYAN}/macroscope:autoloop${RESET}             ${DIM}# Autopilot review-fix-push cycle${RESET}\n"
  echo ""
  printf "${BOLD}Notes:${RESET}\n"
  printf "  Restart Codex, Claude Code, Cursor, or OpenCode if they were already open.\n"
  printf "  /macroscope:codereview runs a local streaming CLI review.\n"
  printf "  /macroscope:autoloop runs the full review-fix-push-re-review autopilot cycle.\n"
  printf "  Claude Code launches reviews in a background worker.\n"
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

  # Suppress terminal echo before running the binary so escape sequence
  # responses (OSC 11, DSR) from the terminal emulator aren't echoed to
  # the screen. The binary writes directly to /dev/tty so its own output
  # is unaffected. Bubbletea manages its own terminal modes internally.
  local _old_tty=""
  _old_tty=$(stty -g < /dev/tty 2>/dev/null) || true
  if [ -n "$_old_tty" ]; then
    stty -echo < /dev/tty 2>/dev/null
    # Pre-drain: terminal escape responses (OSC 11 / DSR) queued during the
    # banner / clear-screen phase can land in stdin before the wizard reads.
    # If Bubbletea ingests them, it can fail with "program was killed" or
    # "error reading input" on first keystroke.
    stty -icanon min 0 time 2 < /dev/tty 2>/dev/null
    dd bs=1024 count=1 < /dev/tty >/dev/null 2>&1 || true
    stty "$_old_tty" < /dev/tty 2>/dev/null
    stty -echo < /dev/tty 2>/dev/null
  fi

  if ! "$bin_path" setup < /dev/tty > /dev/tty 2>&1; then
    warn "Wizard exited with a non-zero status. You can rerun it anytime with: macroscope setup"
  fi

  # Drain any remaining escape responses from the input buffer, then
  # restore original terminal settings (including echo).
  sleep 0.1
  if [ -n "$_old_tty" ]; then
    stty -icanon min 0 time 2 < /dev/tty 2>/dev/null
    dd bs=1024 count=1 < /dev/tty >/dev/null 2>&1 || true
    stty "$_old_tty" < /dev/tty 2>/dev/null
  fi
}

main() {
  if ! repair_only_requested && [ -t 1 ]; then
    printf '\033[H\033[2J'
  fi
  if ! repair_only_requested; then
    print_banner
  fi

  step "Checking system requirements..."
  check_dependencies

  if repair_only_requested; then
    repair_existing_install
    info "Repair cleanup complete (MACROSCOPE_REPAIR_ONLY=1). Preserved ~/.macroscope and saved credentials."
    return
  fi

  detect_platform
  determine_install_dir
  prepare_tmp_dir
  resolve_version "$@"
  repair_existing_install

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
