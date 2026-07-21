#!/bin/bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

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
INSTALLED_VERSION=""
TMP_DIR=""
CHECKOUT_DIR=""
PLUGIN_VERSION=""
INSTALL_DIR=""
CONFIG_SEEDED=0
CODEX_SHIM_INSTALLED=0
CODEX_PLUGIN_HOST_WARNING=""

CODEX_LOCAL_PLUGIN_VERSION="local"
CODEX_BUNDLED_BINARY=""
CODEX_SHIM_PATH=""

DRY_RUN=0
ASSUME_YES=0
TOOLS_SPEC=""
SELECTED_TOOLS=""
HOST_PERMISSIONS="prompt"
SKIP_PATH=0
SHELL_CONFIG_OVERRIDE=""
WIZARD_MODE="default"
INSTALL_MODE=""
OUTPUT_FORMAT="text"
RESUME_COMMAND=0
STATE_FILE=""
STATE_LOADED=0
STATE_CONFIGURED=0
STATE_TOOLS=""
STATE_HOST_PERMISSIONS=""
STATE_PATH_FILE=""
STATE_PATH_POLICY=""
SAVED_AUTO_UPDATE=0
PATH_ACTION="skip"
PATH_TARGET=""
PATH_POLICY="auto"
APPLY_STARTED=0
APPLY_COMPLETE=0
ROLLBACK_LOG=""
SAVED_TTY_STATE=""

usage() {
  cat <<'EOF'
Usage: install.sh [version] [options]

Options:
  --dry-run                         Print the complete plan without changing files
  --tools claude,codex,cursor,opencode|all|none
                                    Select host integrations
  --host-permissions prompt|grant|skip
                                    Control optional coding-assistant command allow-rules
  --no-path                         Never edit shell configuration (remembered for updates)
  --shell-config PATH               Edit exactly this shell configuration file
  --wizard                          Launch setup after installation
  --no-wizard                       Do not launch setup
  --yes                             Apply the displayed plan without confirmation
  --format text|json                Select completion output format
  --mode initial|update             Set install lifecycle (normally auto-detected)
  -h, --help                        Show this help
EOF
}

parse_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --resume-command) RESUME_COMMAND=1 ;;
      --no-path) SKIP_PATH=1 ;;
      --wizard) WIZARD_MODE="yes" ;;
      --no-wizard) WIZARD_MODE="no" ;;
      --tools|--host-permissions|--shell-config|--format|--mode)
        if [ "$#" -lt 2 ]; then
          error "$1 requires a value"
          exit 2
        fi
        case "$1" in
          --tools) TOOLS_SPEC="$2" ;;
          --host-permissions) HOST_PERMISSIONS="$2" ;;
          --shell-config) SHELL_CONFIG_OVERRIDE="$2" ;;
          --format) OUTPUT_FORMAT="$2" ;;
          --mode) INSTALL_MODE="$2" ;;
        esac
        shift
        ;;
      --tools=*|--host-permissions=*|--shell-config=*|--format=*|--mode=*)
        case "$1" in
          --tools=*) TOOLS_SPEC="${1#*=}" ;;
          --host-permissions=*) HOST_PERMISSIONS="${1#*=}" ;;
          --shell-config=*) SHELL_CONFIG_OVERRIDE="${1#*=}" ;;
          --format=*) OUTPUT_FORMAT="${1#*=}" ;;
          --mode=*) INSTALL_MODE="${1#*=}" ;;
        esac
        ;;
      -h|--help) usage; exit 0 ;;
      --)
        shift
        if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ -n "$INSTALL_VERSION" ]; }; then
          error "Unexpected argument: ${2:-$1}"
          exit 2
        fi
        if [ "$#" -eq 1 ]; then
          INSTALL_VERSION="$1"
        fi
        break
        ;;
      -*) error "Unknown option: $1"; usage >&2; exit 2 ;;
      *)
        if [ -n "$INSTALL_VERSION" ]; then
          error "Unexpected argument: $1"
          exit 2
        fi
        INSTALL_VERSION="$1"
        ;;
    esac
    shift
  done

  case "$HOST_PERMISSIONS" in prompt|grant|skip) ;; *) error "--host-permissions must be prompt, grant, or skip"; exit 2 ;; esac
  case "$OUTPUT_FORMAT" in text|json) ;; *) error "--format must be text or json"; exit 2 ;; esac
  case "$INSTALL_MODE" in ""|initial|update) ;; *) error "--mode must be initial or update"; exit 2 ;; esac
  if [ -n "$SHELL_CONFIG_OVERRIDE" ] && [ "$SKIP_PATH" -eq 1 ]; then
    error "--shell-config and --no-path cannot be used together"
    exit 2
  fi
}

state_file_path() {
  if [ -n "${XDG_STATE_HOME:-}" ]; then
    printf '%s/macroscope/install.json' "$XDG_STATE_HOME"
  else
    printf '%s/.local/state/macroscope/install.json' "$HOME"
  fi
}

load_install_state() {
  STATE_FILE="$(state_file_path)"
  [ -f "$STATE_FILE" ] || return 0
  local values=""
  values="$(python3 - "$STATE_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise TypeError("state must be an object")
    tools = data.get("tools", [])
    host_permissions = data.get("hostPermissions", "")
    path_file = data.get("pathFile")
    path_policy = data.get("pathPolicy")
    configured = (
        "tools" in data
        and "hostPermissions" in data
        and "pathPolicy" in data
        and all(tool in ("claude", "codex", "cursor", "opencode") for tool in tools)
        and host_permissions in ("grant", "skip", "preserve")
        and path_policy in ("auto", "managed", "skip")
    )
    if not isinstance(tools, list) or not all(isinstance(tool, str) for tool in tools):
        raise TypeError("tools must be a string array")
    if not isinstance(host_permissions, str):
        raise TypeError("hostPermissions must be a string")
    if path_file is not None and not isinstance(path_file, str):
        raise TypeError("pathFile must be a string or null")
    if path_policy is None:
        # Preserve the behavior of legacy state. Only the new installer can
        # record an explicit, durable --no-path choice.
        path_policy = "managed" if path_file else "auto"
    if path_policy not in ("auto", "managed", "skip"):
        raise TypeError("pathPolicy must be auto, managed, or skip")
except Exception:
    print("")
    print("")
    print("")
    print("")
    print("invalid")
    print("incomplete")
    raise SystemExit
print(",".join(tools))
print(host_permissions)
print(path_file or "")
print(path_policy)
print("valid")
print("configured" if configured else "incomplete")
PY
)"
  STATE_TOOLS="$(printf '%s\n' "$values" | sed -n '1p')"
  STATE_HOST_PERMISSIONS="$(printf '%s\n' "$values" | sed -n '2p')"
  STATE_PATH_FILE="$(printf '%s\n' "$values" | sed -n '3p')"
  STATE_PATH_POLICY="$(printf '%s\n' "$values" | sed -n '4p')"
  [ "$(printf '%s\n' "$values" | sed -n '5p')" = "valid" ] && STATE_LOADED=1
  [ "$(printf '%s\n' "$values" | sed -n '6p')" = "configured" ] && STATE_CONFIGURED=1
  return 0
}

detect_installed_tools() {
  local detected=""
  [ -d "$(get_claude_config_dir)/plugins/cache/macroscope-local" ] && detected="claude"
  [ -d "$(get_codex_home)/plugins/cache/local-user-plugins/macroscope" ] || [ -d "$HOME/plugins/macroscope" ] && detected="${detected:+$detected,}codex"
  [ -d "$HOME/.cursor/plugins/local/macroscope" ] && detected="${detected:+$detected,}cursor"
  if [ -f "$(get_opencode_config_dir)/plugins/macroscope.js" ]; then
    detected="${detected:+$detected,}opencode"
  fi
  printf '%s' "$detected"
}

normalize_tools() {
  local value="${1// /}"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    all|'') printf 'claude,codex,cursor,opencode'; return ;;
    none) printf ''; return ;;
  esac
  python3 - "$value" <<'PY'
import sys
allowed = ["claude", "codex", "cursor", "opencode"]
requested = [x for x in sys.argv[1].split(",") if x]
unknown = sorted(set(requested) - set(allowed))
if unknown:
    print("invalid:" + ",".join(unknown))
else:
    print(",".join(x for x in allowed if x in requested))
PY
}

tool_selected() {
  case ",$SELECTED_TOOLS," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

tool_plan_path() {
  case "$1" in
    claude) printf '%s/plugins/cache/macroscope-local/ and plugin registration in %s/settings.json' "$(get_claude_config_dir)" "$(get_claude_config_dir)" ;;
    codex) printf '%s/plugins/macroscope, %s/plugins/cache/, and %s/config.toml' "$HOME" "$(get_codex_home)" "$(get_codex_home)" ;;
    cursor) printf '%s/.cursor/plugins/local/macroscope/' "$HOME" ;;
    opencode) printf '%s/' "$(get_opencode_config_dir)" ;;
  esac
}

tool_install_plan_path() {
  case "$1" in
    claude) printf '%s/plugins/cache/macroscope-local/ and %s/settings.json' "$(get_claude_config_dir)" "$(get_claude_config_dir)" ;;
    *) tool_plan_path "$1" ;;
  esac
}

selected_tools_plan_label() {
  local tools=()
  local tool=""
  local index=0
  local last=0
  for tool in claude codex cursor opencode; do
    tool_selected "$tool" && tools+=("$tool")
  done
  last=$((${#tools[@]} - 1))
  for index in "${!tools[@]}"; do
    if [ "$index" -eq 0 ]; then
      printf '%s' "${tools[$index]}"
    elif [ "$index" -eq "$last" ]; then
      printf ' and %s' "${tools[$index]}"
    else
      printf ', %s' "${tools[$index]}"
    fi
  done
}

selected_permission_tools_plan_label() {
  local tools=()
  local tool=""
  local index=0
  local last=0
  for tool in claude cursor opencode; do
    tool_selected "$tool" && tools+=("$tool")
  done
  last=$((${#tools[@]} - 1))
  for index in "${!tools[@]}"; do
    if [ "$index" -eq 0 ]; then
      printf '%s' "${tools[$index]}"
    elif [ "$index" -eq "$last" ]; then
      printf ' and %s' "${tools[$index]}"
    else
      printf ', %s' "${tools[$index]}"
    fi
  done
}

tool_permission_plan_path() {
  case "$1" in
    claude) printf '%s/settings.json and %s/hooks/macroscope-bash-autoallow.sh' "$(get_claude_config_dir)" "$(get_claude_config_dir)" ;;
    cursor) printf '%s/.cursor/cli-config.json' "$HOME" ;;
    opencode) printf '%s/opencode.json' "$(get_opencode_config_dir)" ;;
  esac
}

tool_installed() {
  case "$1" in
    claude) [ -d "$(get_claude_config_dir)/plugins/cache/macroscope-local" ] ;;
    codex) [ -d "$HOME/plugins/macroscope" ] || find "$(get_codex_home)/plugins/cache" -type d -path '*/macroscope/local' -print -quit 2>/dev/null | grep -q . ;;
    cursor) [ -d "$HOME/.cursor/plugins/local/macroscope" ] ;;
    opencode) [ -f "$(get_opencode_config_dir)/plugins/macroscope.js" ] ;;
    *) return 1 ;;
  esac
}

host_permission_automation_present() {
  { [ -f "$(get_claude_config_dir)/settings.json" ] && grep -Fq 'Bash(macroscope' "$(get_claude_config_dir)/settings.json"; } ||
    [ -e "$(get_claude_config_dir)/hooks/macroscope-bash-autoallow.sh" ] ||
    { [ -f "$HOME/.cursor/cli-config.json" ] && grep -Fq 'Shell(macroscope' "$HOME/.cursor/cli-config.json"; } ||
    { [ -f "$(get_opencode_config_dir)/opencode.json" ] && grep -Fq '"macroscope ' "$(get_opencode_config_dir)/opencode.json"; }
}

has_interactive_tty() {
  [ "${MACROSCOPE_TEST_NONINTERACTIVE:-0}" != "1" ] || return 1
  # /dev/tty can exist and appear readable/writable even when this process has
  # no controlling terminal. In that case reads fail and an empty answer would
  # otherwise be interpreted as the default "yes" confirmation.
  ( test -t 0 < /dev/tty ) 2>/dev/null
}

TUI_RESULT=""
TUI_KEY=""

tui_start() {
  SAVED_TTY_STATE="$(stty -g < /dev/tty 2>/dev/null)" || return 1
  stty -echo -icanon min 1 time 0 < /dev/tty
  printf '\033[?25l' > /dev/tty
}

tui_stop() {
  printf '\033[?25h' > /dev/tty
  if [ -n "$SAVED_TTY_STATE" ]; then
    stty "$SAVED_TTY_STATE" < /dev/tty 2>/dev/null || true
    SAVED_TTY_STATE=""
  fi
}

tui_read_key() {
  local key=""
  local prefix=""
  local direction=""

  TUI_KEY=""
  IFS= read -r -n 1 key < /dev/tty || return 1
  if [ "$key" = $'\033' ]; then
    stty min 0 time 1 < /dev/tty
    prefix="$(dd bs=1 count=1 < /dev/tty 2>/dev/null)"
    case "$prefix" in
      '['|'O')
        direction="$(dd bs=1 count=1 < /dev/tty 2>/dev/null)"
        case "$direction" in
          A) TUI_KEY="up" ;;
          B) TUI_KEY="down" ;;
        esac
        ;;
    esac
    stty min 1 time 0 < /dev/tty
    return 0
  fi

  case "$key" in
    '') TUI_KEY="enter" ;;
    ' ') TUI_KEY="space" ;;
    *) TUI_KEY="$key" ;;
  esac
}

prompt_yes_no() {
  local question="$1"
  local default_answer="$2"
  local selected=0
  local first_render=1
  local index=0
  local labels=("Yes" "No")

  [ "$default_answer" = "no" ] && selected=1
  tui_start
  printf '\n%s%s%s\n' "$BOLD" "$question" "$RESET" > /dev/tty
  printf '  Up/down or j/k to move; enter to choose.\n' > /dev/tty

  while true; do
    if [ "$first_render" -eq 0 ]; then
      printf '\033[2A' > /dev/tty
    fi
    first_render=0
    for index in 0 1; do
      printf '\r\033[2K' > /dev/tty
      if [ "$index" -eq "$selected" ]; then
        printf '%s%s>%s %s\n' "$CYAN" "$BOLD" "$RESET" "${labels[$index]}" > /dev/tty
      else
        printf '  %s\n' "${labels[$index]}" > /dev/tty
      fi
    done

    if ! tui_read_key; then
      tui_stop
      return 1
    fi
    case "$TUI_KEY" in
      up|k|K|down|j|J) selected=$((1 - selected)) ;;
      y|Y) selected=0; break ;;
      n|N) selected=1; break ;;
      enter) break ;;
    esac
  done

  tui_stop
  if [ "$selected" -eq 0 ]; then TUI_RESULT="yes"; else TUI_RESULT="no"; fi
}

# prompt_menu renders a single-select vertical menu of the given labels and
# sets TUI_RESULT to the zero-based index of the chosen entry. Mirrors
# prompt_yes_no's rendering for an arbitrary number of options.
prompt_menu() {
  local question="$1"; shift
  local labels=("$@")
  local count="${#labels[@]}"
  local selected=0
  local first_render=1
  local index=0

  tui_start
  printf '\n%s%s%s\n' "$BOLD" "$question" "$RESET" > /dev/tty
  printf '  Up/down or j/k to move; enter to choose.\n' > /dev/tty

  while true; do
    if [ "$first_render" -eq 0 ]; then
      printf '\033[%dA' "$count" > /dev/tty
    fi
    first_render=0
    index=0
    while [ "$index" -lt "$count" ]; do
      printf '\r\033[2K' > /dev/tty
      if [ "$index" -eq "$selected" ]; then
        printf '%s%s>%s %s\n' "$CYAN" "$BOLD" "$RESET" "${labels[$index]}" > /dev/tty
      else
        printf '  %s\n' "${labels[$index]}" > /dev/tty
      fi
      index=$((index + 1))
    done

    if ! tui_read_key; then
      tui_stop
      return 1
    fi
    case "$TUI_KEY" in
      up|k|K) selected=$(((selected + count - 1) % count)) ;;
      down|j|J) selected=$(((selected + 1) % count)) ;;
      enter) break ;;
    esac
  done

  tui_stop
  TUI_RESULT="$selected"
}

prompt_tools() {
  local default_tools="$1"
  local tools=(claude codex cursor opencode)
  local labels=("Claude Code" "Codex" "Cursor" "OpenCode")
  local checked=(0 0 0 0)
  local selected=0
  local first_render=1
  local index=0
  local result=""

  for index in 0 1 2 3; do
    case ",$default_tools," in
      *",${tools[$index]},"*) checked[$index]=1 ;;
    esac
  done

  tui_start
  printf '\n%sIntegrations%s\n' "$BOLD" "$RESET" > /dev/tty
  printf '  Up/down or j/k to move; space to toggle; enter to continue.\n' > /dev/tty

  while true; do
    if [ "$first_render" -eq 0 ]; then
      printf '\033[4A' > /dev/tty
    fi
    first_render=0
    for index in 0 1 2 3; do
      printf '\r\033[2K' > /dev/tty
      if [ "$index" -eq "$selected" ]; then
        printf '%s%s>%s [%s] %s\n' "$CYAN" "$BOLD" "$RESET" "$([ "${checked[$index]}" -eq 1 ] && printf x || printf ' ')" "${labels[$index]}" > /dev/tty
      else
        printf '  [%s] %s\n' "$([ "${checked[$index]}" -eq 1 ] && printf x || printf ' ')" "${labels[$index]}" > /dev/tty
      fi
    done

    if ! tui_read_key; then
      tui_stop
      return 1
    fi
    case "$TUI_KEY" in
      up|k|K) selected=$(((selected + 3) % 4)) ;;
      down|j|J) selected=$(((selected + 1) % 4)) ;;
      space) checked[$selected]=$((1 - checked[$selected])) ;;
      enter) break ;;
    esac
  done

  tui_stop
  for index in 0 1 2 3; do
    if [ "${checked[$index]}" -eq 1 ]; then
      result="${result:+$result,}${tools[$index]}"
    fi
  done
  TUI_RESULT="${result:-none}"
}

select_tools() {
  local default_tools=""
  local prompt_default=""
  local normalized=""
  if [ -n "$TOOLS_SPEC" ]; then
    normalized="$(normalize_tools "$TOOLS_SPEC")"
  elif [ "$INSTALL_MODE" = "update" ]; then
    if [ "$STATE_LOADED" -eq 1 ]; then
      default_tools="$STATE_TOOLS"
    else
      default_tools="$(detect_installed_tools)"
    fi
    prompt_default="$default_tools"
    if has_interactive_tty && [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$SAVED_AUTO_UPDATE" -eq 0 ]; then
      if [ -z "$prompt_default" ]; then
        printf '\n%sNo Macroscope host integrations are currently selected.%s\n' "$YELLOW" "$RESET" > /dev/tty
        printf 'Select integrations now so a CLI-only install is not preserved accidentally.\n' > /dev/tty
        prompt_default="claude,codex,cursor,opencode"
      else
        printf '\n%sCurrent integrations are selected below.%s\n' "$BOLD" "$RESET" > /dev/tty
      fi
      prompt_tools "$prompt_default"
      TOOLS_SPEC="$TUI_RESULT"
    fi
    normalized="$(normalize_tools "${TOOLS_SPEC:-${prompt_default:-none}}")"
  else
    default_tools="claude,codex,cursor,opencode"
    if has_interactive_tty && [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
      prompt_tools "$default_tools"
      TOOLS_SPEC="$TUI_RESULT"
    fi
    normalized="$(normalize_tools "${TOOLS_SPEC:-$default_tools}")"
  fi
  case "$normalized" in invalid:*) error "Unknown tool(s): ${normalized#invalid:}"; exit 2 ;; esac
  SELECTED_TOOLS="$normalized"
}

resolve_host_permissions() {
  [ -n "$SELECTED_TOOLS" ] || { HOST_PERMISSIONS="skip"; return; }
  if [ "$HOST_PERMISSIONS" != "prompt" ]; then
    return
  fi
  if [ "$INSTALL_MODE" = "update" ]; then
    case "$STATE_HOST_PERMISSIONS" in grant|skip|preserve) HOST_PERMISSIONS="$STATE_HOST_PERMISSIONS"; return ;; esac
    # Legacy installs predate ownership tracking. Preserve their existing
    # automation without adding or removing rules we cannot prove we own.
    if [ "$STATE_LOADED" -eq 0 ] && host_permission_automation_present; then
      HOST_PERMISSIONS="preserve"
      return
    fi
  fi
  if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ] || ! has_interactive_tty; then
    HOST_PERMISSIONS="skip"
    return
  fi
  # The final confirmation menu is the single decision point for optional
  # command auto-approval. It presents both the exact changes and an install-
  # without-auto-approval choice, so a separate yes/no prompt is redundant.
  HOST_PERMISSIONS="grant"
}

active_path_contains_install_dir() {
  case ":${PATH:-}:" in *":$HOME/.local/bin:"*) return 0 ;; *) return 1 ;; esac
}

login_shell_name() {
  local shell_path="${SHELL:-}"
  if [ -z "$shell_path" ] && command -v dscl >/dev/null 2>&1 && [ -n "${USER:-}" ]; then
    shell_path="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
  fi
  if [ -z "$shell_path" ] && command -v getent >/dev/null 2>&1 && [ -n "${USER:-}" ]; then
    shell_path="$(getent passwd "$USER" 2>/dev/null | awk -F: '{print $7}')"
  fi
  basename "${shell_path:-sh}"
}

resolve_path_action() {
  PATH_ACTION="skip"
  PATH_TARGET=""
  PATH_POLICY="auto"
  if [ "$SKIP_PATH" -eq 1 ]; then
    PATH_POLICY="skip"
    return 0
  fi
  if [ -n "$SHELL_CONFIG_OVERRIDE" ]; then
    PATH_POLICY="managed"
    PATH_TARGET="$SHELL_CONFIG_OVERRIDE"
    case "$PATH_TARGET" in /*) ;; *) PATH_TARGET="$PWD/$PATH_TARGET" ;; esac
    PATH_ACTION="modify"
    return
  fi
  if [ "$INSTALL_MODE" = "update" ] && [ "$STATE_LOADED" -eq 1 ]; then
    case "$STATE_PATH_POLICY" in
      skip)
        PATH_POLICY="skip"
        return
        ;;
      managed) PATH_POLICY="managed" ;;
      auto) PATH_POLICY="auto" ;;
    esac
  fi
  active_path_contains_install_dir && return
  if [ "$INSTALL_MODE" = "update" ] && [ "$STATE_LOADED" -eq 1 ] && [ "$STATE_PATH_POLICY" = "managed" ] && [ -n "$STATE_PATH_FILE" ]; then
    PATH_TARGET="$STATE_PATH_FILE"
    PATH_ACTION="modify"
    return
  fi
  PATH_POLICY="managed"
  case "$(login_shell_name)" in
    zsh)
      if [ -f "$HOME/.zprofile" ]; then PATH_TARGET="$HOME/.zprofile"
      elif [ -f "$HOME/.zshrc" ]; then PATH_TARGET="$HOME/.zshrc"
      else PATH_TARGET="$HOME/.zprofile"; fi
      ;;
    bash)
      if [ -f "$HOME/.bash_profile" ]; then PATH_TARGET="$HOME/.bash_profile"
      elif [ -f "$HOME/.bashrc" ]; then PATH_TARGET="$HOME/.bashrc"
      else PATH_TARGET="$HOME/.bash_profile"; fi
      ;;
    fish) PATH_TARGET="$HOME/.config/fish/config.fish" ;;
    *) PATH_TARGET="$HOME/.profile" ;;
  esac
  PATH_ACTION="modify"
}

resolve_lifecycle() {
  if [ -z "$INSTALL_MODE" ]; then
    if [ -x "$HOME/.local/bin/macroscope" ] || [ "$STATE_LOADED" -eq 1 ]; then INSTALL_MODE="update"; else INSTALL_MODE="initial"; fi
  fi
  if [ "$WIZARD_MODE" = "default" ]; then
    if [ "$INSTALL_MODE" = "initial" ]; then WIZARD_MODE="yes"; else WIZARD_MODE="no"; fi
  fi
}

# Mandatory updates that resume the original command reuse an explicit saved
# install configuration. They do not ask users to reconsider integration or
# permission choices that were already made during installation. Manual
# updates, dry runs, overrides, and incomplete legacy state keep the normal
# plan and confirmation flow.
resolve_saved_auto_update() {
  SAVED_AUTO_UPDATE=0
  [ "$INSTALL_MODE" = "update" ] || return 0
  [ "$RESUME_COMMAND" -eq 1 ] || return 0
  [ "$STATE_CONFIGURED" -eq 1 ] || return 0
  [ -z "$TOOLS_SPEC" ] || return 0
  [ "$HOST_PERMISSIONS" = "prompt" ] || return 0
  [ "$SKIP_PATH" -eq 0 ] || return 0
  [ -z "$SHELL_CONFIG_OVERRIDE" ] || return 0
  [ "$DRY_RUN" -eq 0 ] || return 0
  SAVED_AUTO_UPDATE=1
}

# host_permission_grant_applies is true only when the permission grant will
# actually modify a selected tool's config. Codex has no host-permission step,
# so `--tools codex --host-permissions grant` must not show the auto-approval
# grouped plan action or the "Show exact changes" confirmation option.
host_permission_grant_applies() {
  [ "$HOST_PERMISSIONS" = "grant" ] || return 1
  tool_selected claude || tool_selected cursor || tool_selected opencode
}

print_plan() {
  local index=1
  local verb="Install"
  local plan_label="installation"
  [ "$INSTALL_MODE" = "update" ] && verb="Replace"
  [ "$INSTALL_MODE" = "update" ] && plan_label="update"
  printf '\n%sMacroscope %s will:%s\n' "$BOLD" "$plan_label" "$RESET"
  printf '%d. %s %s/.local/bin/macroscope\n' "$index" "$verb" "$HOME"; index=$((index + 1))
  if [ "$PATH_ACTION" = "modify" ]; then
    printf '%d. Add %s/.local/bin to PATH in %s\n' "$index" "$HOME" "$PATH_TARGET"
  elif active_path_contains_install_dir; then
    printf '%d. Keep PATH unchanged (%s/.local/bin is already active)\n' "$index" "$HOME"
  elif [ "$PATH_POLICY" = "skip" ]; then
    if [ "$SKIP_PATH" -eq 1 ]; then
      printf '%d. Keep shell configuration unchanged (remember --no-path for future updates)\n' "$index"
    else
      printf '%d. Keep shell configuration unchanged (remembered --no-path; use --shell-config PATH to manage it)\n' "$index"
    fi
  else
    printf '%d. Keep shell configuration unchanged\n' "$index"
  fi
  index=$((index + 1))
  local tool=""
  if [ -n "$SELECTED_TOOLS" ]; then
    local plugin_noun="plugins"
    [ "${SELECTED_TOOLS#*,}" = "$SELECTED_TOOLS" ] && plugin_noun="plugin"
    printf '%d. Install or update the following %s for %s\n' "$index" "$plugin_noun" "$(selected_tools_plan_label)"
    for tool in claude codex cursor opencode; do
      tool_selected "$tool" && printf '   (%s)\n' "$(tool_install_plan_path "$tool")"
    done
    index=$((index + 1))
    if tool_selected codex && codex_shim_will_install; then
      printf '%d. Install or update the managed Codex CLI wrapper at %s/.local/bin/codex\n' "$index" "$HOME"
      index=$((index + 1))
    fi
  fi
  for tool in claude codex cursor opencode; do
    if ! tool_selected "$tool" && [ "$INSTALL_MODE" = "update" ] && tool_installed "$tool"; then
      printf '%d. Remove Macroscope-owned %s integration state at %s (deselected)\n' "$index" "$tool" "$(tool_plan_path "$tool")"
      index=$((index + 1))
    fi
  done
  if [ "$HOST_PERMISSIONS" = "grant" ]; then
    if host_permission_grant_applies; then
      printf '%d. Allow Macroscope and mktemp command auto-approval for %s\n' "$index" "$(selected_permission_tools_plan_label)"
      for tool in claude cursor opencode; do
        tool_selected "$tool" && printf '   (%s)\n' "$(tool_permission_plan_path "$tool")"
      done
      index=$((index + 1))
    fi
  elif [ "$HOST_PERMISSIONS" = "preserve" ]; then
    printf '%d. Preserve existing legacy host permission rules and hooks without adding new ones\n' "$index"; index=$((index + 1))
  elif [ "$INSTALL_MODE" = "update" ] && host_permission_automation_present; then
    printf '%d. Remove Macroscope-owned host permission rules and hooks while preserving pre-existing rules\n' "$index"; index=$((index + 1))
  fi
  if [ "$INSTALL_MODE" = "update" ]; then
    printf '%d. Clean legacy Macroscope MCP artifacts after the update is staged\n' "$index"; index=$((index + 1))
  fi
  if { [ -n "${MACROSCOPE_LOCAL_BACK_REPO:-}" ] || [ -n "${MACROSCOPE_LOCAL_BINARY_SOURCE:-}" ]; } && [ ! -f "$HOME/.macroscope/config.yaml" ]; then
    printf '%d. Seed local-build configuration at %s/.macroscope/config.yaml\n' "$index" "$HOME"; index=$((index + 1))
  fi
  if [ "$WIZARD_MODE" = "yes" ]; then
    printf '%d. Launch the setup wizard\n' "$index"
  fi
}

# print_change_details shows the literal configuration snippets the installer
# will merge, so the operator can verify the security-relevant permission
# grants (command auto-approve rules + PreToolUse hook) before consenting.
# Existing settings are preserved; only the keys shown below are added.
print_change_details() {
  local claude_config="$(get_claude_config_dir)"
  local opencode_config="$(get_opencode_config_dir)"
  # _ccd_file: bold cyan header for a config path being edited.
  _ccd_file() { printf '\n  %s%s%s%s\n' "$BOLD" "$CYAN" "$1" "$RESET"; }
  # _ccd_key: the JSON key the additions land under.
  _ccd_key() { printf '    %s:\n' "$1"; }
  # _ccd_add: a diff-style "+" line for a single added entry.
  _ccd_add() { printf '      %s+ %s%s\n' "$GREEN" "$1" "$RESET"; }
  # _ccd_note: dim explanatory text.
  _ccd_note() { printf '      %s%s%s\n' "$DIM" "$1" "$RESET"; }
  {
    printf '\n%sCommand auto-approval rules%s\n' "$BOLD" "$RESET"
    printf '  %sMacroscope ensures the entries below are allow-listed for the selected agents.%s\n' "$DIM" "$RESET"
    printf '  %sExisting rules are kept, entries already present are left unchanged, and nothing is removed.%s\n' "$DIM" "$RESET"
    if tool_selected claude; then
      _ccd_file "$claude_config/settings.json"
      _ccd_key 'permissions.allow'
      _ccd_add 'Bash(macroscope *)'
      _ccd_add 'Bash(macroscope:*)'
      _ccd_add 'Bash(mktemp *)'
      _ccd_add 'Bash(mktemp:*)'
      _ccd_key 'hooks.PreToolUse  (matcher: Bash)'
      _ccd_add "$claude_config/hooks/macroscope-bash-autoallow.sh"
      _ccd_note 'approves only a bare `macroscope` or `mktemp` command;'
      _ccd_note 'refuses pipes, redirects, substitution, or chaining.'
    fi
    if tool_selected cursor; then
      _ccd_file "$HOME/.cursor/cli-config.json"
      _ccd_key 'permissions.allow'
      _ccd_add 'Shell(macroscope)'
      _ccd_add 'Shell(macroscope *)'
      _ccd_add 'Shell(mktemp)'
      _ccd_add 'Shell(mktemp *)'
    fi
    if tool_selected opencode; then
      _ccd_file "$opencode_config/opencode.json"
      _ccd_key 'permission.bash'
      _ccd_add '"macroscope *": "allow"'
      _ccd_add '"macroscope": "allow"'
      _ccd_add '"mktemp *": "allow"'
      _ccd_add '"mktemp": "allow"'
      _ccd_note 'if "permission" or "permission.bash" is currently a plain string'
      _ccd_note '(e.g. "ask"), it is expanded to object form, preserving that value.'
    fi
    printf '\n  %sNothing else is auto-approved.%s\n' "$DIM" "$RESET"
  } > /dev/tty
  unset -f _ccd_file _ccd_key _ccd_add _ccd_note
}

confirm_plan() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  [ "$SAVED_AUTO_UPDATE" -eq 0 ] || return 0
  [ "$ASSUME_YES" -eq 0 ] || return 0
  if ! has_interactive_tty; then
    error "A terminal is required for confirmation. Re-run with --yes after reviewing --dry-run."
    return 3
  fi
  local prompt='Proceed?'
  [ "$INSTALL_MODE" = "update" ] && prompt='Update and continue?'
  [ "$RESUME_COMMAND" -eq 1 ] && prompt='Update and run the review?'

  # When the plan modifies security-relevant host permission config, offer
  # inline options to inspect the exact snippets, or to proceed without the
  # grant — so declining does not require Ctrl-C and re-running with a flag.
  if host_permission_grant_applies; then
    while true; do
      if ! prompt_menu "$prompt" "Yes" "Show exact changes" "Install without command auto-approval" "No"; then
        info "Cancelled before making changes."
        return 3
      fi
      case "$TUI_RESULT" in
        0) return 0 ;;
        1) print_change_details ;;
        2)
          HOST_PERMISSIONS="skip"
          info "Installing without command auto-approval."
          return 0
          ;;
        *) info "Cancelled before making changes."; return 3 ;;
      esac
    done
  fi

  prompt_yes_no "$prompt" "yes"
  if [ "$TUI_RESULT" = "no" ]; then
    info "Cancelled before making changes."
    return 3
  fi
  return 0
}

repair_only_requested() {
  [ "${MACROSCOPE_REPAIR_ONLY:-0}" = "1" ]
}

get_codex_home() {
  printf '%s' "${CODEX_HOME:-$HOME/.codex}"
}

get_claude_config_dir() {
  printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

get_claude_state_file() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s/.claude.json' "$CLAUDE_CONFIG_DIR"
  else
    printf '%s/.claude.json' "$HOME"
  fi
}

get_opencode_config_dir() {
  if [ -n "${OPENCODE_CONFIG_DIR:-}" ]; then
    printf '%s' "$OPENCODE_CONFIG_DIR"
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s/opencode' "$XDG_CONFIG_HOME"
  else
    printf '%s/.config/opencode' "$HOME"
  fi
}

get_codex_marketplace_name() {
  python3 - "$HOME/.agents/plugins/marketplace.json" <<'PY'
import json, os, sys
name = "local-user-plugins"
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        value = json.load(f).get("name")
    if isinstance(value, str) and value.strip(): name = value.strip()
except Exception: pass
print(name)
PY
}

codex_supports_plugins() {
  local codex_bin="$1"
  [ -x "$codex_bin" ] || return 1
  "$codex_bin" --help 2>/dev/null | grep -q "app-server"
}

resolve_codex_bundled_binary() {
  if [ -n "${MACROSCOPE_CODEX_BUNDLED_BINARY:-}" ]; then
    CODEX_BUNDLED_BINARY="$MACROSCOPE_CODEX_BUNDLED_BINARY"
    return
  fi

  local candidate=""
  local candidates=(
    "${MACROSCOPE_CODEX_APP_BINARY:-/Applications/Codex.app/Contents/Resources/codex}"
    "${MACROSCOPE_CHATGPT_APP_BINARY:-/Applications/ChatGPT.app/Contents/Resources/codex}"
  )
  CODEX_BUNDLED_BINARY="${candidates[0]}"
  for candidate in "${candidates[@]}"; do
    if codex_supports_plugins "$candidate"; then
      CODEX_BUNDLED_BINARY="$candidate"
      return
    fi
  done
}

codex_shim_will_install() {
  local current_codex=""
  current_codex="$(command -v codex || true)"
  if [ -n "$current_codex" ] && [ "$current_codex" = "$CODEX_BUNDLED_BINARY" ] && codex_supports_plugins "$current_codex"; then
    return 1
  fi
  [ -x "$CODEX_BUNDLED_BINARY" ] && codex_supports_plugins "$CODEX_BUNDLED_BINARY" || return 1
  [ ! -f "$HOME/.local/bin/codex" ] || is_managed_codex_shim "$HOME/.local/bin/codex"
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
  local claude_config=""
  local opencode_config=""
  local codex_plugin_cache_root=""
  local codex_marketplace_json=""
  local dir=""
  local file=""
  local marketplace_name=""

  codex_home="$(get_codex_home)"
  claude_config="$(get_claude_config_dir)"
  opencode_config="$(get_opencode_config_dir)"
  codex_plugin_cache_root="$codex_home/plugins/cache"
  codex_marketplace_json="$HOME/.agents/plugins/marketplace.json"

  for dir in \
    "$HOME/plugins/macroscope" \
    "$HOME/plugins/macroscope-codereview" \
    "$codex_home/plugins/macroscope" \
    "$codex_home/plugins/macroscope-codereview" \
    "$claude_config/plugins/marketplaces/macroscope-local" \
    "$claude_config/plugins/cache/macroscope-local" \
    "$HOME/.cursor/plugins/local/macroscope" \
    "$HOME/.cursor/plugins/local/macroscope-codereview" \
    "$opencode_config/skills/macroscope" \
    "$opencode_config/skills/codereview" \
    "$opencode_config/skills/autoloop" \
    "$opencode_config/skills/macroscope-local-review" \
    "$opencode_config/skills/macroscope-triage-pr-comments" \
    "$opencode_config/skills/macroscope-respond-to-pr-comments" \
    "$opencode_config/skills/macroscope-review-pr" \
    "$opencode_config/skills/local-review" \
    "$opencode_config/skills/triage-pr-comments" \
    "$opencode_config/skills/respond-to-pr-comments" \
    "$opencode_config/skills/review-pr"
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
    "$opencode_config/plugins/macroscope.js" \
    "$opencode_config/commands/macroscope.md" \
    "$opencode_config/commands/macroscope-codereview.md" \
    "$opencode_config/commands/macroscope-autoloop.md" \
    "$opencode_config/commands/macroscope-local-review.md" \
    "$opencode_config/commands/macroscope-triage-pr-comments.md" \
    "$opencode_config/commands/macroscope-respond-to-pr-comments.md" \
    "$opencode_config/commands/macroscope-review-pr.md" \
    "$opencode_config/commands/local-review.md" \
    "$opencode_config/commands/triage-pr-comments.md" \
    "$opencode_config/commands/respond-to-pr-comments.md" \
    "$opencode_config/commands/review-pr.md" \
    "$claude_config/hooks/macroscope-bash-autoallow.sh"
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
  local claude_config=""
  local opencode_config=""

  codex_home="$(get_codex_home)"
  claude_config="$(get_claude_config_dir)"
  opencode_config="$(get_opencode_config_dir)/opencode.json"

  python3 - \
    "$HOME/.agents/plugins/marketplace.json" \
    "$codex_home/config.toml" \
    "$(get_claude_state_file)" \
    "$claude_config/plugins/known_marketplaces.json" \
    "$claude_config/plugins/installed_plugins.json" \
    "$claude_config/settings.json" \
    "$claude_config/settings.local.json" \
    "$HOME/.cursor/mcp.json" \
    "$STATE_FILE" \
    "$opencode_config" <<'PY'
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
    install_state,
    opencode_config,
) = sys.argv[1:11]


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


install_state_data, _ = load_json(install_state)
if isinstance(install_state_data, dict) and "permissionOwnership" not in install_state_data:
    permission_ownership = None
elif isinstance(install_state_data, dict) and isinstance(install_state_data.get("permissionOwnership"), dict):
    permission_ownership = install_state_data["permissionOwnership"]
else:
    permission_ownership = {}


def owned_permission_rules(tool, legacy_rules):
    if permission_ownership is None:
        return set(legacy_rules)
    tool_state = permission_ownership.get(tool, {})
    inserted = tool_state.get("inserted", []) if isinstance(tool_state, dict) else []
    return {rule for rule in inserted if isinstance(rule, str)} if isinstance(inserted, list) else set()


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

    permissions = data.get("permissions") if path == claude_settings else None
    if isinstance(permissions, dict):
        allow = permissions.get("allow")
        _owned = owned_permission_rules("claude", {"Bash(macroscope)", "Bash(macroscope *)", "Bash(macroscope:*)", "Bash(mktemp)", "Bash(mktemp *)", "Bash(mktemp:*)"})
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
    _owned_shell = owned_permission_rules("cursor", {"Shell(macroscope)", "Shell(macroscope *)", "Shell(mktemp)", "Shell(mktemp *)"})
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


opencode_data, opencode_mode = load_json(opencode_config)
if isinstance(opencode_data, dict):
    changed = False
    permission = opencode_data.get("permission")
    if isinstance(permission, dict):
        bash = permission.get("bash")
        if isinstance(bash, dict):
            for key in owned_permission_rules("opencode", {"macroscope", "macroscope *", "mktemp", "mktemp *"}):
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
  info "Installation directory: ${BOLD}${INSTALL_DIR}${RESET}"
}

prepare_tmp_dir() {
  TMP_DIR=$(mktemp -d)
  chmod 700 "$TMP_DIR"
  trap 'handle_exit $?' EXIT
}

resolve_version() {
  INSTALL_VERSION="${MACROSCOPE_VERSION:-${INSTALL_VERSION:-latest}}"
  info "Requested version: ${BOLD}${INSTALL_VERSION}${RESET}"
}

stage_binary() {
  step "Downloading Macroscope CLI..."

  if [ -n "${MACROSCOPE_LOCAL_BINARY_SOURCE:-}" ]; then
    if [ ! -f "${MACROSCOPE_LOCAL_BINARY_SOURCE}" ]; then
      error "Local binary source not found: ${MACROSCOPE_LOCAL_BINARY_SOURCE}"
      exit 1
    fi

    cp "${MACROSCOPE_LOCAL_BINARY_SOURCE}" "$TMP_DIR/macroscope"
    chmod +x "$TMP_DIR/macroscope"
    success "Staged local CLI from ${BOLD}${MACROSCOPE_LOCAL_BINARY_SOURCE}${RESET}"
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
    success "Built and staged local CLI from ${BOLD}${MACROSCOPE_LOCAL_BACK_REPO}${RESET}"
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

  success "Downloaded and staged the CLI"
}

apply_binary() {
  step "Installing binary..."
  if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
  fi
  local target="$INSTALL_DIR/macroscope"
  local candidate="$TMP_DIR/macroscope"
  local next="$INSTALL_DIR/.macroscope.new.$$"
  cp "$candidate" "$next"
  chmod +x "$next"
  mv -f "$next" "$target"
  INSTALLED_BINARY="$target"
  success "Installed CLI to ${BOLD}${INSTALLED_BINARY}${RESET}"
}

validate_staged_artifacts() {
  step "Validating staged artifacts..."
  if [ ! -x "$TMP_DIR/macroscope" ]; then
    error "Staged Macroscope binary is not executable on this system"
    return 1
  fi
  if ! INSTALLED_VERSION="$("$TMP_DIR/macroscope" --version 2>/dev/null)" || [ -z "$INSTALLED_VERSION" ]; then
    error "Staged Macroscope binary is not executable on this system"
    return 1
  fi
  local plugin_root="$CHECKOUT_DIR/plugins/macroscope"
  local tool="" required=""
  for tool in claude codex cursor opencode; do
    tool_selected "$tool" || continue
    case "$tool" in
      claude) required=".claude-plugin/plugin.json commands/macroscope-codereview.md commands/macroscope-autoloop.md skills/codereview/SKILL.md skills/autoloop/SKILL.md" ;;
      codex) required=".codex-plugin/plugin.json commands/macroscope-codereview.md commands/macroscope-autoloop.md skills/codereview/SKILL.md skills/autoloop/SKILL.md" ;;
      cursor) required=".cursor-plugin/plugin.json commands/macroscope-codereview.md commands/macroscope-autoloop.md skills/codereview/SKILL.md skills/autoloop/SKILL.md" ;;
      opencode) required="opencode/macroscope.js commands/macroscope-codereview.md commands/macroscope-autoloop.md skills/codereview/SKILL.md skills/autoloop/SKILL.md" ;;
    esac
    for required in $required; do
      if [ -z "$CHECKOUT_DIR" ] || [ ! -f "$plugin_root/$required" ]; then
        error "Staged plugin bundle is missing $tool asset: $required"
        return 1
      fi
    done
  done
  success "Staged binary and plugin bundle are valid"
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
  [ "$PATH_ACTION" = "modify" ] || {
    active_path_contains_install_dir && info "PATH already contains $HOME/.local/bin" || info "Shell configuration left unchanged"
    export PATH="$HOME/.local/bin:$PATH"
    return
  }
  step "Updating shell configuration..."

  local install_bin="$HOME/.local/bin"
  local marker="# Added by Macroscope installer"
  local export_line="export PATH=\"$install_bin:\$PATH\""
  local line="$export_line"
  local target_shell=""
  case "$PATH_TARGET" in
    */config.fish) target_shell="fish" ;;
    *.zshrc|*.zprofile|*.bashrc|*.bash_profile|*/.profile) target_shell="posix" ;;
    *) target_shell="$(login_shell_name)" ;;
  esac
  [ "$target_shell" = "fish" ] && line="set -Ux fish_user_paths $install_bin \$fish_user_paths"
  mkdir -p "$(dirname "$PATH_TARGET")"
  touch "$PATH_TARGET"
  if ! grep -Fq "$line" "$PATH_TARGET" 2>/dev/null; then
    {
      echo ""
      echo "$marker"
      echo "$line"
    } >> "$PATH_TARGET"
    success "Updated $PATH_TARGET"
  else
    info "PATH already configured in $PATH_TARGET"
  fi
  export PATH="$HOME/.local/bin:$PATH"
}

install_codex_cli_shim() {
  step "Checking Codex CLI..."

  local current_codex="" quoted_bundled_binary=""
  local shim_path="$HOME/.local/bin/codex"

  CODEX_SHIM_PATH="$shim_path"
  current_codex="$(command -v codex || true)"

  if [ -n "$current_codex" ] && [ "$current_codex" = "$CODEX_BUNDLED_BINARY" ] && codex_supports_plugins "$current_codex"; then
    success "Codex CLI already uses the bundled Codex desktop binary: ${BOLD}${current_codex}${RESET}"
    return
  fi

  if [ ! -x "$CODEX_BUNDLED_BINARY" ] || ! codex_supports_plugins "$CODEX_BUNDLED_BINARY"; then
    if [ -n "$current_codex" ]; then
      CODEX_PLUGIN_HOST_WARNING="Codex CLI at ${current_codex} does not support local plugins. Install or update the Codex desktop app to use /macroscope:codereview from the CLI."
      warn "$CODEX_PLUGIN_HOST_WARNING"
    else
      CODEX_PLUGIN_HOST_WARNING="Codex CLI is not installed. Install the Codex desktop app to use /macroscope:codereview from the CLI."
      warn "$CODEX_PLUGIN_HOST_WARNING"
    fi
    return
  fi

  if [ -f "$shim_path" ] && ! is_managed_codex_shim "$shim_path"; then
    CODEX_PLUGIN_HOST_WARNING="Existing ${shim_path} was left untouched, so the current Codex CLI may still be too old for plugins."
    warn "$CODEX_PLUGIN_HOST_WARNING"
    return
  fi

  quoted_bundled_binary="$(python3 - "$CODEX_BUNDLED_BINARY" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"
  cat > "$shim_path" <<EOF
#!/bin/bash
set -euo pipefail
# Macroscope-managed Codex shim
exec ${quoted_bundled_binary} "\$@"
EOF
  chmod +x "$shim_path"
  CODEX_SHIM_INSTALLED=1

  if [ -n "$current_codex" ] && [ "$current_codex" != "$shim_path" ]; then
    success "Installed Codex CLI shim at ${BOLD}${shim_path}${RESET}"
    info "${BOLD}codex${RESET} will now use the bundled Codex desktop binary instead of ${current_codex}."
  else
    success "Installed Codex CLI shim at ${BOLD}${shim_path}${RESET}"
    info "${BOLD}codex${RESET} is now available via the bundled Codex desktop binary."
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
  local claude_config="$(get_claude_config_dir)"
  local marketplace_root="$claude_config/plugins/marketplaces/macroscope-local"
  local cache_dst="$claude_config/plugins/cache/macroscope-local/macroscope/$PLUGIN_VERSION"
  local known_marketplaces="$claude_config/plugins/known_marketplaces.json"
  local installed_plugins="$claude_config/plugins/installed_plugins.json"
  local claude_settings="$claude_config/settings.json"
  local now=""

  mkdir -p "$claude_config/plugins/marketplaces" "$claude_config/plugins/cache/macroscope-local"
  rm -rf "$claude_config/plugins/cache/macroscope-local/macroscope"
  mkdir -p "$claude_config/plugins/cache/macroscope-local/macroscope"

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

# register_claude_bash_autoallow_hook installs the PreToolUse hook script
# and registers it in Claude Code's settings.json. This closes a gap in the
# plain allow-list patterns: Claude Code's Bash matcher tokenizes on
# shell operators, so `Bash(macroscope *)` stops matching as soon as the
# command contains a background operator. The hook inspects the raw command
# string and approves only a single macroscope/mktemp command without redirects.
register_claude_bash_autoallow_hook() {
  local script_src="$(dirname "$0")/scripts/claude-bash-autoallow.sh"
  if [ ! -f "$script_src" ]; then
    script_src="$CHECKOUT_DIR/scripts/claude-bash-autoallow.sh"
  fi
  # When installed via `curl | bash`, the installer has no $0 path to
  # resolve a sibling script from — in that case we embed the script
  # via a HEREDOC below instead of copying from disk.
  local claude_config="$(get_claude_config_dir)"
  local hook_dst="$claude_config/hooks/macroscope-bash-autoallow.sh"
  mkdir -p "$claude_config/hooks"

  if [ -f "$script_src" ]; then
    cp "$script_src" "$hook_dst"
  else
    cat > "$hook_dst" <<'EMBED'
#!/usr/bin/env python3
"""PreToolUse hook that auto-approves single macroscope or mktemp commands."""
import json, re, sys

def safe_simple_command(command, names):
    candidate = command.strip()
    if candidate.endswith("&"):
        candidate = candidate[:-1].rstrip()
    if not candidate or re.search(r"[\n\r;|`()<>]|[$][(]", candidate):
        return None
    if "&" in candidate:
        return None
    match = re.match(r"^([A-Za-z0-9_.-]+)(?:\s|$)", candidate)
    return match.group(1) if match and match.group(1) in names else None

def approved_command(command):
    assignment = re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=[$][(](.*)[)]", command.strip())
    if assignment:
        return safe_simple_command(assignment.group(1), ("mktemp",))
    return safe_simple_command(command, ("macroscope", "mktemp"))

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
    name = approved_command(command)
    if name:
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

  python3 - "$claude_config/settings.json" "$hook_dst" <<'PY'
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

apply_host_permissions() {
  [ "$HOST_PERMISSIONS" = "grant" ] || return 0
  step "Granting announced host shell permissions..."

  tool_selected claude && python3 - "$(get_claude_config_dir)/settings.json" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
if os.path.islink(path): path = os.path.realpath(path)
mode = os.stat(path).st_mode if os.path.exists(path) else None
if os.path.exists(path):
    with open(path, encoding="utf-8") as f: data = json.load(f)
else: data = {}
permissions = data.setdefault("permissions", {})
allow = permissions.setdefault("allow", [])
for rule in ("Bash(macroscope *)", "Bash(macroscope:*)", "Bash(mktemp *)", "Bash(mktemp:*)"):
    if rule not in allow:
        allow.append(rule)
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-settings-")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2); f.write("\n")
    if mode is not None: os.chmod(tmp, mode)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
  tool_selected claude && register_claude_bash_autoallow_hook

  tool_selected cursor && python3 - "$HOME/.cursor/cli-config.json" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
if os.path.islink(path): path = os.path.realpath(path)
mode = os.stat(path).st_mode if os.path.exists(path) else None
if os.path.exists(path):
    with open(path, encoding="utf-8") as f: data = json.load(f)
else: data = {}
permissions = data.setdefault("permissions", {})
allow = permissions.setdefault("allow", [])
permissions.setdefault("deny", [])
for rule in ("Shell(macroscope)", "Shell(macroscope *)", "Shell(mktemp)", "Shell(mktemp *)"):
    if rule not in allow: allow.append(rule)
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-config-")
with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(data, f, indent=2); f.write("\n")
if mode is not None: os.chmod(tmp, mode)
os.replace(tmp, path)
PY

  tool_selected opencode && python3 - "$(get_opencode_config_dir)/opencode.json" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
if os.path.islink(path): path = os.path.realpath(path)
mode = os.stat(path).st_mode if os.path.exists(path) else None
if os.path.exists(path):
    with open(path, encoding="utf-8") as f: data = json.load(f)
else: data = {}
permission = data.get("permission")
if isinstance(permission, str):
    if permission == "allow":
        bash = None
    else:
        permission = {"*": permission}
        data["permission"] = permission
        bash = {}
        permission["bash"] = bash
elif isinstance(permission, dict):
    bash = permission.get("bash")
    if isinstance(bash, str):
        if bash == "allow":
            bash = None
        else:
            bash = {"*": bash}
            permission["bash"] = bash
    elif not isinstance(bash, dict):
        bash = {}
        permission["bash"] = bash
else:
    permission = {}
    data["permission"] = permission
    bash = {}
    permission["bash"] = bash
if isinstance(bash, dict):
    for rule in ("macroscope *", "macroscope", "mktemp *", "mktemp"):
        bash.setdefault(rule, "allow")
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-config-")
with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(data, f, indent=2); f.write("\n")
if mode is not None: os.chmod(tmp, mode)
os.replace(tmp, path)
PY
  success "Applied only the explicitly approved host permission automation"
}

clean_tool_state() {
  local tool="$1"
  local remove_plugin="$2"
  local remove_permissions="$3"
  local codex_home="$(get_codex_home)"
  local claude_config="$(get_claude_config_dir)"
  local opencode_config="$(get_opencode_config_dir)"
  python3 - "$tool" "$remove_plugin" "$remove_permissions" "$STATE_FILE" "$HOME" "$codex_home" "$claude_config" "$opencode_config" <<'PY'
import json, os, re, sys, tempfile
tool, remove_plugin, remove_permissions, state_path, home, codex_home, claude_config, opencode_config = sys.argv[1:9]
remove_plugin = remove_plugin == "1"
remove_permissions = remove_permissions == "1"

def load(path):
    if not os.path.exists(path): return None, None
    try:
        with open(path, encoding="utf-8") as f: return json.load(f), os.stat(path).st_mode
    except Exception: return None, None

def save(path, data, mode):
    if os.path.islink(path): path = os.path.realpath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-clean-")
    with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(data, f, indent=2); f.write("\n")
    if mode is not None: os.chmod(tmp, mode)
    os.replace(tmp, path)

state, _ = load(state_path)
ownership = state.get("permissionOwnership", {}) if isinstance(state, dict) else {}
legacy = not isinstance(state, dict)

if tool == "claude":
    if remove_plugin:
        for path, key in [
            (os.path.join(claude_config, "plugins/known_marketplaces.json"), "macroscope-local"),
        ]:
            data, mode = load(path)
            if isinstance(data, dict) and key in data: del data[key]; save(path, data, mode)
        path = os.path.join(claude_config, "plugins/installed_plugins.json")
        data, mode = load(path)
        if isinstance(data, dict) and isinstance(data.get("plugins"), dict):
            if data["plugins"].pop("macroscope@macroscope-local", None) is not None: save(path, data, mode)
    path = os.path.join(claude_config, "settings.json")
    data, mode = load(path)
    if isinstance(data, dict):
        changed = False
        if remove_plugin:
            for section, key in (("extraKnownMarketplaces", "macroscope-local"), ("enabledPlugins", "macroscope@macroscope-local")):
                obj = data.get(section)
                if isinstance(obj, dict) and key in obj:
                    del obj[key]; changed = True
                    if not obj: data.pop(section, None)
        if remove_permissions:
            known = {"Bash(macroscope)", "Bash(macroscope *)", "Bash(macroscope:*)", "Bash(mktemp)", "Bash(mktemp *)", "Bash(mktemp:*)"}
            # A legacy install has no ownership manifest, so generic allow
            # rules are indistinguishable from user-managed dotfile state.
            # Only remove rules we can prove this installer recorded.
            owned = set(ownership.get("claude", {}).get("inserted", [])) if not legacy else set()
            permissions = data.get("permissions")
            if isinstance(permissions, dict) and isinstance(permissions.get("allow"), list):
                old = permissions["allow"]
                permissions["allow"] = [x for x in old if x not in owned]
                changed |= permissions["allow"] != old
                if not permissions["allow"]: permissions.pop("allow", None)
                if not permissions: data.pop("permissions", None)
            hooks = data.get("hooks")
            if isinstance(hooks, dict) and isinstance(hooks.get("PreToolUse"), list):
                old = hooks["PreToolUse"]
                hooks["PreToolUse"] = [e for e in old if not any("macroscope-bash-autoallow" in str(h.get("command", "")) or "macroscope-installer" in str(h.get("command", "")) for h in (e.get("hooks", []) if isinstance(e, dict) else []))]
                changed |= hooks["PreToolUse"] != old
                if not hooks["PreToolUse"]: hooks.pop("PreToolUse", None)
                if not hooks: data.pop("hooks", None)
        if changed: save(path, data, mode)

elif tool == "codex" and remove_plugin:
    marketplace = os.path.join(home, ".agents/plugins/marketplace.json")
    data, mode = load(marketplace)
    names = {"local-user-plugins"}
    if isinstance(data, dict):
        names.add(str(data.get("name", "local-user-plugins")))
        plugins = data.get("plugins")
        if isinstance(plugins, list):
            filtered = [p for p in plugins if not (isinstance(p, dict) and p.get("name") in ("macroscope", "macroscope-codereview"))]
            if filtered != plugins: data["plugins"] = filtered; save(marketplace, data, mode)
    config = os.path.join(codex_home, "config.toml")
    if os.path.exists(config):
        mode = os.stat(config).st_mode
        with open(config, encoding="utf-8") as f: text = f.read()
        old = text
        for name in names:
            for plugin in ("macroscope", "macroscope-codereview"):
                text = re.sub(rf'(?ms)^\[plugins\."{re.escape(plugin + "@" + name)}"\]\n.*?(?=^\[|\Z)', '', text)
        if text != old:
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(config), prefix=".macroscope-config-")
            with os.fdopen(fd, "w", encoding="utf-8") as f: f.write(text)
            os.chmod(tmp, mode); os.replace(tmp, config)

elif tool == "cursor" and remove_permissions:
    path = os.path.join(home, ".cursor/cli-config.json")
    data, mode = load(path)
    if isinstance(data, dict):
        known = {"Shell(macroscope)", "Shell(macroscope *)", "Shell(mktemp)", "Shell(mktemp *)"}
        owned = set(ownership.get("cursor", {}).get("inserted", [])) if not legacy else set()
        permissions = data.get("permissions")
        if isinstance(permissions, dict) and isinstance(permissions.get("allow"), list):
            old = permissions["allow"]; permissions["allow"] = [x for x in old if x not in owned]
            if permissions["allow"] != old: save(path, data, mode)

elif tool == "opencode" and remove_permissions:
    path = os.path.join(opencode_config, "opencode.json")
    data, mode = load(path)
    if isinstance(data, dict):
        known = {"macroscope", "macroscope *", "mktemp", "mktemp *"}
        owned = set(ownership.get("opencode", {}).get("inserted", [])) if not legacy else set()
        permission = data.get("permission"); bash = permission.get("bash") if isinstance(permission, dict) else None
        changed = False
        if isinstance(bash, dict):
            for key in owned: changed |= bash.pop(key, None) is not None
            if not bash: permission.pop("bash", None)
            if not permission: data.pop("permission", None)
        if changed: save(path, data, mode)
PY
}

clean_legacy_mcp_state() {
  [ "$INSTALL_MODE" = "update" ] || return 0
  step "Cleaning legacy MCP artifacts..."
  local legacy_mcp="$HOME/.local/bin/macroscope-mcp"
  if command -v pgrep >/dev/null 2>&1; then
    local legacy_pattern="" legacy_pids=""
    legacy_pattern="$(python3 - "$legacy_mcp" <<'PY'
import re, sys
print("^" + re.escape(sys.argv[1]) + r"([[:space:]]|$)")
PY
)"
    legacy_pids="$(pgrep -f "$legacy_pattern" 2>/dev/null || true)"
    if [ -n "$legacy_pids" ]; then
      while IFS= read -r pid; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
      done <<< "$legacy_pids"
    fi
  fi
  rm -f "$legacy_mcp"
  local codex_home="$(get_codex_home)"
  python3 - "$(get_claude_state_file)" "$HOME/.cursor/mcp.json" "$codex_home/config.toml" <<'PY'
import json, os, re, sys, tempfile
for path in sys.argv[1:3]:
    if not os.path.exists(path): continue
    if os.path.islink(path): path = os.path.realpath(path)
    try:
        with open(path, encoding="utf-8") as f: data = json.load(f)
    except Exception: continue
    mode = os.stat(path).st_mode; changed = False
    servers = data.get("mcpServers")
    if isinstance(servers, dict) and servers.pop("macroscope-codereview", None) is not None: changed = True
    projects = data.get("projects")
    if isinstance(projects, dict):
        for project in projects.values():
            servers = project.get("mcpServers") if isinstance(project, dict) else None
            if isinstance(servers, dict) and servers.pop("macroscope-codereview", None) is not None: changed = True
    if changed:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-mcp-")
        with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(data, f, indent=2); f.write("\n")
        os.chmod(tmp, mode); os.replace(tmp, path)
path = sys.argv[3]
if os.path.exists(path):
    if os.path.islink(path): path = os.path.realpath(path)
    mode = os.stat(path).st_mode
    with open(path, encoding="utf-8") as f: text = f.read()
    cleaned = re.sub(r'(?ms)^\[mcp_servers\.macroscope-codereview\]\n.*?(?=^\[|\Z)', '', text)
    if cleaned != text:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-mcp-")
        with os.fdopen(fd, "w", encoding="utf-8") as f: f.write(cleaned)
        os.chmod(tmp, mode); os.replace(tmp, path)
PY
  success "Legacy MCP artifacts cleaned"
}

remove_tool_integration() {
  local tool="$1"
  step "Removing deselected $tool integration..."
  case "$tool" in
    claude)
      rm -rf "$(get_claude_config_dir)/plugins/marketplaces/macroscope-local" "$(get_claude_config_dir)/plugins/cache/macroscope-local"
      rm -f "$(get_claude_config_dir)/hooks/macroscope-bash-autoallow.sh"
      ;;
    codex)
      rm -rf "$HOME/plugins/macroscope"
      find "$(get_codex_home)/plugins/cache" -type d -path '*/macroscope/local' -prune -exec rm -rf {} + 2>/dev/null || true
      if is_managed_codex_shim "$HOME/.local/bin/codex"; then rm -f "$HOME/.local/bin/codex"; fi
      ;;
    cursor) rm -rf "$HOME/.cursor/plugins/local/macroscope" ;;
    opencode)
      rm -f "$(get_opencode_config_dir)/plugins/macroscope.js" "$(get_opencode_config_dir)/commands/macroscope-codereview.md" "$(get_opencode_config_dir)/commands/macroscope-autoloop.md"
      rm -rf "$(get_opencode_config_dir)/skills/codereview" "$(get_opencode_config_dir)/skills/autoloop"
      ;;
  esac
  clean_tool_state "$tool" 1 1
  success "Removed Macroscope-owned $tool integration state"
}

snapshot_permission_state() {
  python3 - "$STATE_FILE" "$TMP_DIR/permission-before.json" "$HOME" "$(get_claude_config_dir)" "$(get_opencode_config_dir)" <<'PY'
import json, os, sys
state_path, output, home, claude_config, opencode_config = sys.argv[1:6]
try:
    with open(state_path, encoding="utf-8") as f: state = json.load(f)
except Exception: state = {}
prior = state.get("permissionOwnership", {})
rules = {
  "claude": (os.path.join(claude_config, "settings.json"), ("permissions", "allow"), ["Bash(macroscope *)", "Bash(macroscope:*)", "Bash(mktemp *)", "Bash(mktemp:*)"]),
  "cursor": (os.path.join(home, ".cursor/cli-config.json"), ("permissions", "allow"), ["Shell(macroscope)", "Shell(macroscope *)", "Shell(mktemp)", "Shell(mktemp *)"]),
  "opencode": (os.path.join(opencode_config, "opencode.json"), ("permission", "bash"), ["macroscope *", "macroscope", "mktemp *", "mktemp"]),
}
result = {}
for tool, (path, keys, known) in rules.items():
    try:
        with open(path, encoding="utf-8") as f: value = json.load(f)
        for key in keys: value = value.get(key, {}) if isinstance(value, dict) else {}
        present = set(value if isinstance(value, list) else value.keys() if isinstance(value, dict) else [])
    except Exception: present = set()
    owned = set(prior.get(tool, {}).get("inserted", []))
    known_present = present & set(known)
    result[tool] = {
        "presentBefore": sorted(known_present),
        "preexisting": sorted(known_present - owned),
        "ownedBefore": sorted(owned & present),
    }
with open(output, "w", encoding="utf-8") as f: json.dump(result, f)
PY
}

write_install_state() {
  local path_file="$STATE_PATH_FILE"
  [ "$PATH_ACTION" = "modify" ] && path_file="$PATH_TARGET"
  python3 - "$STATE_FILE" "$TMP_DIR/permission-before.json" "$SELECTED_TOOLS" "$HOST_PERMISSIONS" "$path_file" "$PATH_POLICY" "$INSTALLED_VERSION" "$HOME" "$(get_claude_config_dir)" "$(get_opencode_config_dir)" <<'PY'
import json, os, sys, tempfile
path, before_path, tools_csv, host_permissions, path_file, path_policy, version, home, claude_config, opencode_config = sys.argv[1:11]
try:
    with open(before_path, encoding="utf-8") as f: before = json.load(f)
except Exception: before = {}
rules_by_tool = {
 "claude": (os.path.join(claude_config, "settings.json"), ("permissions", "allow"), ["Bash(macroscope *)", "Bash(macroscope:*)", "Bash(mktemp *)", "Bash(mktemp:*)"]),
 "cursor": (os.path.join(home, ".cursor/cli-config.json"), ("permissions", "allow"), ["Shell(macroscope)", "Shell(macroscope *)", "Shell(mktemp)", "Shell(mktemp *)"]),
 "opencode": (os.path.join(opencode_config, "opencode.json"), ("permission", "bash"), ["macroscope *", "macroscope", "mktemp *", "mktemp"]),
}
selected = [x for x in tools_csv.split(",") if x]
ownership = {}
for tool, (config_path, keys, rules) in rules_by_tool.items():
    old = before.get(tool, {})
    if host_permissions == "grant" and tool in selected:
        try:
            with open(config_path, encoding="utf-8") as f: value = json.load(f)
            for key in keys: value = value.get(key, {}) if isinstance(value, dict) else {}
            present_after = set(value if isinstance(value, list) else value.keys() if isinstance(value, dict) else []) & set(rules)
        except Exception: present_after = set()
        present_before = set(old.get("presentBefore", []))
        carried = set(old.get("ownedBefore", [])) & present_after
        inserted = carried | (present_after - present_before)
        preexisting = (set(old.get("preexisting", [])) | (present_before - carried)) & present_after
    else:
        inserted = set()
        preexisting = set(old.get("preexisting", []))
    ownership[tool] = {"inserted": sorted(inserted), "preexisting": sorted(preexisting)}
data = {"schemaVersion": 2, "version": version, "tools": selected, "hostPermissions": host_permissions,
        "pathFile": path_file or None, "pathPolicy": path_policy, "permissionOwnership": ownership}
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-state-")
with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(data, f, indent=2); f.write("\n")
os.chmod(tmp, 0o600); os.replace(tmp, path)
PY
}

rollback_targets() {
  local codex_home="$(get_codex_home)"
  local codex_marketplace="$(get_codex_marketplace_name)"
  local claude_config="$(get_claude_config_dir)"
  local claude_state="$(get_claude_state_file)"
  local opencode_config="$(get_opencode_config_dir)"
  printf '%s\0' \
    "$HOME/.local/bin/macroscope" \
    "$HOME/.local/bin/macroscope-mcp" \
    "$HOME/.local/bin/codex" \
    "$HOME/plugins/macroscope" \
    "$HOME/.agents/plugins/marketplace.json" \
    "$codex_home/plugins/cache/$codex_marketplace/macroscope" \
    "$codex_home/config.toml" \
    "$claude_config/plugins/marketplaces/macroscope-local" \
    "$claude_config/plugins/cache/macroscope-local" \
    "$claude_config/plugins/known_marketplaces.json" \
    "$claude_config/plugins/installed_plugins.json" \
    "$claude_state" \
    "$claude_config/settings.json" \
    "$claude_config/hooks/macroscope-bash-autoallow.sh" \
    "$HOME/.cursor/plugins/local/macroscope" \
    "$HOME/.cursor/cli-config.json" \
    "$HOME/.cursor/mcp.json" \
    "$opencode_config/plugins/macroscope.js" \
    "$opencode_config/commands/macroscope-codereview.md" \
    "$opencode_config/commands/macroscope-autoloop.md" \
    "$opencode_config/skills/codereview" \
    "$opencode_config/skills/autoloop" \
    "$opencode_config/opencode.json" \
    "$HOME/.macroscope/config.yaml" \
    "$STATE_FILE"
  [ -z "$PATH_TARGET" ] || printf '%s\0' "$PATH_TARGET"
}

snapshot_for_rollback() {
  local backup_root="$TMP_DIR/rollback"
  ROLLBACK_LOG="$TMP_DIR/rollback.log"
  mkdir -p "$backup_root"
  : > "$ROLLBACK_LOG"
  local path="" index=0 backup=""
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    index=$((index + 1))
    backup="$backup_root/$index"
    if [ -e "$path" ] || [ -L "$path" ]; then
      cp -a "$path" "$backup"
      printf 'present\0%s\0%s\0' "$path" "$backup" >> "$ROLLBACK_LOG"
      if [ -L "$path" ]; then
        local resolved_path="" resolved_backup=""
        resolved_path="$(python3 - "$path" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
        if [ "$resolved_path" != "$path" ]; then
          resolved_backup="$backup.resolved"
          if [ -e "$resolved_path" ] || [ -L "$resolved_path" ]; then
            cp -a "$resolved_path" "$resolved_backup"
            printf 'present\0%s\0%s\0' "$resolved_path" "$resolved_backup" >> "$ROLLBACK_LOG"
          else
            printf 'absent\0%s\0-\0' "$resolved_path" >> "$ROLLBACK_LOG"
          fi
        fi
      fi
    else
      printf 'absent\0%s\0-\0' "$path" >> "$ROLLBACK_LOG"
    fi
  done < <(rollback_targets)
}

rollback_install() {
  [ -f "$ROLLBACK_LOG" ] || return 0
  warn "Installation failed; restoring the previous install-owned state"
  local status="" path="" backup=""
  while IFS= read -r -d '' status &&
        IFS= read -r -d '' path &&
        IFS= read -r -d '' backup; do
    [ -n "$path" ] || continue
    rm -rf "$path"
    if [ "$status" = "present" ]; then
      mkdir -p "$(dirname "$path")"
      cp -a "$backup" "$path"
    fi
  done < "$ROLLBACK_LOG"
}

handle_exit() {
  local status="$1"
  if [ -n "$SAVED_TTY_STATE" ]; then
    printf '\033[?25h' > /dev/tty 2>/dev/null || true
    stty "$SAVED_TTY_STATE" < /dev/tty 2>/dev/null || true
    SAVED_TTY_STATE=""
  fi
  if [ "$status" -ne 0 ] && [ "$APPLY_STARTED" -eq 1 ] && [ "$APPLY_COMPLETE" -eq 0 ]; then
    rollback_install || true
  fi
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
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

  success "Installed Cursor plugin to ${BOLD}${cursor_dst}${RESET}"
}

install_opencode_support() {
  step "Installing OpenCode plugin, commands, and skills..."

  local plugin_src="$CHECKOUT_DIR/plugins/macroscope"
  local commands_src="$plugin_src/commands"
  local skills_src="$plugin_src/skills"
  local plugin_file="$plugin_src/opencode/macroscope.js"
  local opencode_root="$(get_opencode_config_dir)"
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

  success "Installed OpenCode plugin to ${BOLD}${opencode_plugins}/macroscope.js${RESET}"
  success "Installed OpenCode commands to ${BOLD}${opencode_commands}${RESET}"
  success "Installed OpenCode skills to ${BOLD}${opencode_skills}${RESET}"
}

verify_claude_plugin_registration() {
  local claude_cli=""
  local status=""

  claude_cli="$(command -v claude || true)"
  if [ -z "$claude_cli" ]; then
    info "Claude Code CLI is not available; verified its plugin files only"
    return 0
  fi

  status="$(python3 - "$claude_cli" <<'PY'
import json
import subprocess
import sys

claude = sys.argv[1]
plugin_id = "macroscope@macroscope-local"


def run(args):
    try:
        return subprocess.run(
            [claude, *args],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired:
        print("timeout")
        raise SystemExit(0)


listed = run(["plugin", "list", "--json"])
if listed.returncode != 0:
    print("list-failed")
    raise SystemExit(0)

try:
    data = json.loads(listed.stdout)
except Exception:
    print("list-invalid")
    raise SystemExit(0)

entries = data if isinstance(data, list) else data.get("plugins", []) if isinstance(data, dict) else []
plugin = next((item for item in entries if isinstance(item, dict) and item.get("id") == plugin_id), None)
if plugin is None:
    print("missing")
elif plugin.get("enabled") is not True:
    print("disabled")
elif plugin.get("errors"):
    print("errors")
else:
    details = run(["plugin", "details", plugin_id])
    print("ok" if details.returncode == 0 else "details-failed")
PY
)" || status="list-failed"

  case "$status" in
    ok) success "Claude Code CLI recognizes the enabled plugin and its components" ;;
    missing) warn "Claude Code CLI did not discover macroscope@macroscope-local; run 'claude plugin list --json' to diagnose" ;;
    disabled) warn "Claude Code CLI found macroscope@macroscope-local, but it is disabled" ;;
    errors) warn "Claude Code CLI found macroscope@macroscope-local with load errors; run 'claude plugin details macroscope@macroscope-local'" ;;
    details-failed) warn "Claude Code CLI found the enabled plugin, but could not inspect its components" ;;
    timeout) warn "Claude Code CLI plugin verification timed out after 10 seconds" ;;
    *) warn "Claude Code CLI could not return a valid plugin list; plugin files were installed" ;;
  esac
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

  if tool_selected codex && [ -f "$codex_source/.codex-plugin/plugin.json" ]; then
    success "Codex plugin installed"
  elif tool_selected codex; then
    warn "Codex plugin install did not produce ~/plugins/macroscope"
  fi

  if tool_selected codex && [ -f "$codex_cache/.codex-plugin/plugin.json" ]; then
    success "Codex plugin cache installed"
  elif tool_selected codex; then
    warn "Codex plugin cache install did not produce the expected cache entry"
  fi

  local claude_cache="$(get_claude_config_dir)/plugins/cache/macroscope-local/macroscope/$PLUGIN_VERSION"
  if tool_selected claude && [ -f "$claude_cache/.claude-plugin/plugin.json" ] && \
     [ -f "$claude_cache/skills/codereview/SKILL.md" ] && \
     [ -f "$claude_cache/skills/autoloop/SKILL.md" ]; then
    success "Claude Code plugin installed with skills"
  elif tool_selected claude; then
    warn "Claude Code plugin install did not produce the expected cache entry"
  fi
  if tool_selected claude; then
    verify_claude_plugin_registration
  fi

  if tool_selected cursor && [ -f "$HOME/.cursor/plugins/local/macroscope/.cursor-plugin/plugin.json" ]; then
    success "Cursor plugin installed"
  elif tool_selected cursor; then
    warn "Cursor plugin install did not produce the expected local plugin entry"
  fi

  local opencode_root="$(get_opencode_config_dir)"
  if tool_selected opencode && [ -f "$opencode_root/plugins/macroscope.js" ] && [ -f "$opencode_root/commands/macroscope-codereview.md" ] && [ -f "$opencode_root/skills/codereview/SKILL.md" ]; then
    success "OpenCode plugin, commands, and skills installed"
  elif tool_selected opencode; then
    warn "OpenCode install did not produce the expected plugin, command, and skill files"
  fi

  codex_cli="$(command -v codex || true)"
  if tool_selected codex && [ -n "$codex_cli" ] && codex_supports_plugins "$codex_cli"; then
    success "Codex CLI supports plugins: ${BOLD}${codex_cli}${RESET}"
  elif tool_selected codex && [ -n "$CODEX_PLUGIN_HOST_WARNING" ]; then
    warn "$CODEX_PLUGIN_HOST_WARNING"
  elif tool_selected codex; then
    warn "Codex CLI is not available for plugin verification in this shell"
  fi
}

print_installation_completion() {
  echo ""
  printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
  printf "${GREEN}${BOLD}Installation Complete!${RESET}\n"
  printf "${GREEN}${BOLD}════════════════════════════════════════════════${RESET}\n"
  echo ""
  printf "${BOLD}Quick start:${RESET}\n"
  printf "  ${CYAN}macroscope setup${RESET}               ${DIM}# Sign in and select a workspace${RESET}\n"
  printf "  ${CYAN}macroscope${RESET}                     ${DIM}# Open the interactive wizard${RESET}\n"
  printf "  ${CYAN}macroscope codereview --base <base_branch>${RESET} ${DIM}# Review changes against a branch${RESET}\n"
  printf "  ${CYAN}macroscope --help${RESET}              ${DIM}# Show all supported commands${RESET}\n"
  echo ""
  printf "${BOLD}Coding agent commands:${RESET}\n"
  printf "  ${DIM}Agent        Review                    Autopilot${RESET}\n"
  printf "  Claude Code  ${CYAN}/macroscope:codereview${RESET}   ${CYAN}/macroscope:autoloop${RESET}\n"
  printf "  Codex        ${CYAN}/macroscope:codereview${RESET}   ${CYAN}/macroscope:autoloop${RESET}\n"
  printf "  Cursor       ${CYAN}/codereview${RESET}              ${CYAN}/autoloop${RESET}\n"
  printf "  OpenCode     ${CYAN}/macroscope-codereview${RESET}   ${CYAN}/macroscope-autoloop${RESET}\n"
  echo ""
  printf "${BOLD}Notes:${RESET}\n"
  printf "  Restart Codex, Claude Code, Cursor, or OpenCode if they were already open.\n"
  printf "  Claude Code launches reviews in a background worker.\n"
  if [ "$CODEX_SHIM_INSTALLED" = "1" ]; then
    printf "  ${BOLD}codex${RESET} now points at the bundled Codex desktop CLI so plugins work from the terminal.\n"
  elif [ -n "$CODEX_PLUGIN_HOST_WARNING" ]; then
    printf "  ${YELLOW}%s${RESET}\n" "$CODEX_PLUGIN_HOST_WARNING"
  fi
  echo ""
  printf "${BOLD}Need help?${RESET}\n"
  printf "  Documentation: ${BLUE}https://docs.macroscope.com/cli${RESET}\n"
  printf "  Report issues: ${BLUE}https://github.com/prassoai/macroscope-local/issues${RESET}\n"
  echo ""
}

launch_wizard() {
  if [ "$WIZARD_MODE" != "yes" ] || [ "${MACROSCOPE_SKIP_WIZARD:-0}" = "1" ]; then
    return
  fi

  if ! has_interactive_tty; then
    info "No TTY available; run 'macroscope' later to start the setup wizard."
    return
  fi

  local bin_path="${INSTALLED_BINARY}"
  if [ -z "$bin_path" ] || [ ! -x "$bin_path" ]; then
    bin_path="$(command -v macroscope || true)"
  fi

  if [ -z "$bin_path" ]; then
    error "Could not find the installed macroscope binary. Run 'macroscope setup' after repairing the installation."
    return 1
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
    SAVED_TTY_STATE="$_old_tty"
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

  local wizard_status=0
  if "$bin_path" setup < /dev/tty > /dev/tty 2>&1; then
    wizard_status=0
  else
    wizard_status=$?
  fi

  # Drain any remaining escape responses from the input buffer, then
  # restore original terminal settings (including echo).
  sleep 0.1
  if [ -n "$_old_tty" ]; then
    stty -icanon min 0 time 2 < /dev/tty 2>/dev/null
    dd bs=1024 count=1 < /dev/tty >/dev/null 2>&1 || true
    stty "$_old_tty" < /dev/tty 2>/dev/null
    SAVED_TTY_STATE=""
  fi

  if [ "$wizard_status" -ne 0 ]; then
    error "Setup did not complete. The CLI is installed; rerun setup with: macroscope setup"
    return "$wizard_status"
  fi
}

main() {
  trap 'handle_exit $?' EXIT
  parse_options "$@"
  if [ "$OUTPUT_FORMAT" = "json" ]; then
    exec 3>&1
    exec 1>&2
  fi

  if ! repair_only_requested && [ -t 1 ]; then
    printf '\033[H\033[2J'
  fi
  if ! repair_only_requested; then
    print_banner
  fi

  step "Checking system requirements..."
  check_dependencies

  if repair_only_requested; then
    STATE_FILE="$(state_file_path)"
    repair_existing_install
    rm -f "$STATE_FILE"
    info "Repair cleanup complete (MACROSCOPE_REPAIR_ONLY=1). Preserved ~/.macroscope and saved credentials."
    return
  fi

  detect_platform
  resolve_codex_bundled_binary
  load_install_state
  resolve_lifecycle
  resolve_saved_auto_update
  select_tools
  resolve_host_permissions
  resolve_path_action
  resolve_version
  if [ "$SAVED_AUTO_UPDATE" -eq 0 ]; then
    print_plan
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run complete; no persistent files were changed."
    if [ "$OUTPUT_FORMAT" = "json" ]; then
      printf '{"success":true,"dryRun":true,"mode":"%s","tools":"%s"}\n' "$INSTALL_MODE" "$SELECTED_TOOLS" >&3
    fi
    return 0
  fi

  confirm_plan || return $?

  determine_install_dir
  prepare_tmp_dir
  stage_binary
  if [ -n "$SELECTED_TOOLS" ]; then fetch_plugin_bundle; fi
  validate_staged_artifacts
  snapshot_permission_state
  snapshot_for_rollback
  APPLY_STARTED=1

  apply_binary
  if [ "${MACROSCOPE_TEST_FAIL_AFTER_BINARY:-0}" = "1" ]; then
    error "Injected failure after binary replacement"
    return 70
  fi
  update_shell_config
  local tool=""
  for tool in claude codex cursor opencode; do
    if tool_selected "$tool"; then
      if [ "$HOST_PERMISSIONS" = "skip" ] && [ "$INSTALL_MODE" = "update" ]; then
        clean_tool_state "$tool" 0 1
        [ "$tool" != "claude" ] || rm -f "$(get_claude_config_dir)/hooks/macroscope-bash-autoallow.sh"
      fi
      case "$tool" in
        claude) install_claude_plugin ;;
        codex) install_codex_cli_shim; install_codex_plugin ;;
        cursor) install_cursor_plugin ;;
        opencode) install_opencode_support ;;
      esac
    elif [ "$INSTALL_MODE" = "update" ] && tool_installed "$tool"; then
      remove_tool_integration "$tool"
    fi
  done
  apply_host_permissions
  clean_legacy_mcp_state
  if [ "${MACROSCOPE_TEST_FAIL_AFTER_LEGACY_CLEANUP:-0}" = "1" ]; then
    error "Injected failure after legacy MCP cleanup"
    return 71
  fi
  seed_local_build_config_if_needed
  write_install_state
  APPLY_COMPLETE=1
  verify_install
  launch_wizard
  print_installation_completion
  if [ "$OUTPUT_FORMAT" = "json" ]; then
    printf '{"success":true,"dryRun":false,"mode":"%s","tools":"%s"}\n' "$INSTALL_MODE" "$SELECTED_TOOLS" >&3
  fi
}

main "$@"
