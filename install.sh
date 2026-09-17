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
  printf "${YELLOW}!${RESET} %s\n" "$1"
}

step() {
  printf "  ${CYAN}•${RESET} %s\n" "$1"
}

print_flow_title() {
  local command="macroscope install"
  if [ "$INSTALL_MODE" = "update" ]; then
    command="macroscope update"
  fi

  printf "\n${BOLD}%s${RESET}\n" "$command"
}

flow_section() {
  local index="$1"
  local title="$2"
  local description="$3"
  local header="── [${index}/2] ${title} "
  local fill=$((60 - ${#header}))
  local rule=""

  [ "$fill" -ge 2 ] || fill=2
  while [ "${#rule}" -lt "$fill" ]; do
    rule="${rule}─"
  done

  printf "\n${CYAN}${BOLD}%s%s${RESET}\n" "$header" "$rule"
  printf "${DIM}   %s.${RESET}\n" "$description"
}

render_download_progress_frame() {
  local percent="$1"
  local label="$2"
  local width=20
  local filled_count=0
  local empty_count=0
  local filled=""
  local empty=""
  local index=0

  [ "$percent" -ge 0 ] || percent=0
  [ "$percent" -le 100 ] || percent=100
  filled_count=$((percent * width / 100))
  empty_count=$((width - filled_count))

  while [ "$index" -lt "$filled_count" ]; do
    filled="${filled}█"
    index=$((index + 1))
  done
  index=0
  while [ "$index" -lt "$empty_count" ]; do
    empty="${empty}░"
    index=$((index + 1))
  done

  printf "\r\033[2K    ${CYAN}%s${RESET}${DIM}%s${RESET} ${BOLD}%3d%%${RESET}  %s" \
    "$filled" "$empty" "$percent" "$label" >&2
}

# render_download_progress LABEL
# Translates curl's live --progress-bar percentages into the installer's compact
# visual language. Curl remains the source of truth: this renderer never
# advances or completes the bar without receiving a percentage from curl.
render_download_progress() {
  local label="$1"
  local frame=""
  local before_percent=""
  local percent_token=""
  local percent=""
  local progress_visible=1

  render_download_progress_frame 0 "$label"
  while IFS= read -r -d $'\r' frame || [ -n "$frame" ]; do
    frame="${frame//$'\n'/}"
    case "$frame" in
      *curl:\ *)
        printf "\r\033[2Kcurl: %s\n" "${frame#*curl: }" >&2
        progress_visible=0
        ;;
      *%*)
        before_percent="${frame%\%*}"
        percent_token="${before_percent##* }"
        percent="${percent_token%%.*}"
        case "$percent" in
          ""|*[!0-9]*) continue ;;
        esac
        render_download_progress_frame "$percent" "$label"
        progress_visible=1
        ;;
    esac
    frame=""
  done
  if [ "$progress_visible" -eq 1 ]; then
    printf "\n" >&2
  fi
}

# Every network call is bounded: a black-holed or half-open connection must
# fail the install rather than wedge it forever. 15s to connect, 10 minutes
# for the whole transfer (the plugin bundle is the largest asset).
# The overrides exist so a stalled transfer can be exercised without waiting
# ten minutes for it; the defaults are what every real run uses.
CURL_TIMEOUT_ARGS=(
  --connect-timeout "${MACROSCOPE_CURL_CONNECT_TIMEOUT:-15}"
  --max-time "${MACROSCOPE_CURL_MAX_TIME:-600}"
)

# download_with_progress URL DESTINATION LABEL
# Uses curl's native meter outside a terminal. In a terminal, a FIFO lets the
# renderer consume curl's real-time percentages without hiding curl failures or
# changing curl's exit status.
download_with_progress() {
  local url="$1"
  local destination="$2"
  local label="$3"
  local progress_fifo=""
  local renderer_pid=""
  local curl_status=0

  if [ ! -t 2 ]; then
    curl -fL --proto '=https' --proto-redir '=https' "${CURL_TIMEOUT_ARGS[@]}" --progress-bar "$url" -o "$destination"
    return
  fi

  progress_fifo="${TMP_DIR}/curl-progress-$$"
  if ! mkfifo "$progress_fifo"; then
    curl -fL --proto '=https' --proto-redir '=https' "${CURL_TIMEOUT_ARGS[@]}" --progress-bar "$url" -o "$destination"
    return
  fi

  render_download_progress "$label" < "$progress_fifo" &
  renderer_pid=$!
  if curl -fL --proto '=https' --proto-redir '=https' "${CURL_TIMEOUT_ARGS[@]}" --progress-bar "$url" -o "$destination" 2> "$progress_fifo"; then
    curl_status=0
  else
    curl_status=$?
  fi
  wait "$renderer_pid" || true
  rm -f "$progress_fifo"
  return "$curl_status"
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
ADOPTED_TOOLS=""
HOST_INSTALL_FAILURES=""
INTERRUPT_SIGNAL=""
CREATED_DIRS_LOG=""

# Integrity verification of downloaded release artifacts against the SHA-256
# GitHub reports for each release asset.
#   REQUIRE_CHECKSUM=1 fails closed when GitHub reports no SHA-256 for an asset.
#   Default (0) applies a loud, transitional grace in that case; a reported
#   SHA-256 that does NOT match is always fatal regardless of this setting.
REQUIRE_CHECKSUM="${MACROSCOPE_REQUIRE_CHECKSUM:-0}"
RELEASE_METADATA=""
RELEASE_METADATA_STATE=""

usage() {
  cat <<'EOF'
Usage: install.sh [version] [options]

Options:
  --dry-run                         Print the complete plan without changing files
  --tools claude,codex,cursor,opencode|all|none
                                    Select host integrations
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
          # Accepted as a no-op so older CLI binaries can still hand off to
          # this installer during their mandatory update.
          --host-permissions) ;;
          --shell-config) SHELL_CONFIG_OVERRIDE="$2" ;;
          --format) OUTPUT_FORMAT="$2" ;;
          --mode) INSTALL_MODE="$2" ;;
        esac
        shift
        ;;
      --tools=*|--host-permissions=*|--shell-config=*|--format=*|--mode=*)
        case "$1" in
          --tools=*) TOOLS_SPEC="${1#*=}" ;;
          --host-permissions=*) ;;
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

  case "$OUTPUT_FORMAT" in text|json) ;; *) error "--format must be text or json"; exit 2 ;; esac
  case "$INSTALL_MODE" in ""|initial|update) ;; *) error "--mode must be initial or update"; exit 2 ;; esac
  if [ -n "$SHELL_CONFIG_OVERRIDE" ] && [ "$SKIP_PATH" -eq 1 ]; then
    error "--shell-config and --no-path cannot be used together"
    exit 2
  fi
  # A directory can never be a shell configuration file: appending to it fails,
  # and accepting one would hand a whole tree (up to $HOME) to the rollback
  # snapshot as an install-owned target. Refuse it here, before anything runs.
  if [ -n "$SHELL_CONFIG_OVERRIDE" ] && [ -d "$SHELL_CONFIG_OVERRIDE" ]; then
    error "--shell-config must name a shell configuration file, not a directory: $SHELL_CONFIG_OVERRIDE"
    exit 2
  fi
  # Neither can a FIFO, a socket or a device node. Reading one to check for the
  # PATH line blocks until somebody writes to it, which on a FIFO with no writer
  # is forever — after the binary is already installed, with no way out but a
  # signal.
  if [ -n "$SHELL_CONFIG_OVERRIDE" ] && [ -e "$SHELL_CONFIG_OVERRIDE" ] && [ ! -f "$SHELL_CONFIG_OVERRIDE" ]; then
    error "--shell-config must name a regular file: $SHELL_CONFIG_OVERRIDE"
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
    path_file = data.get("pathFile")
    path_policy = data.get("pathPolicy")
    configured = (
        "tools" in data
        and "pathPolicy" in data
        and all(tool in ("claude", "codex", "cursor", "opencode") for tool in tools)
        and path_policy in ("auto", "managed", "skip")
    )
    if not isinstance(tools, list) or not all(isinstance(tool, str) for tool in tools):
        raise TypeError("tools must be a string array")
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
    print("invalid")
    print("incomplete")
    raise SystemExit
print(",".join(tools))
print(path_file or "")
print(path_policy)
print("valid")
print("configured" if configured else "incomplete")
PY
)"
  STATE_TOOLS="$(printf '%s\n' "$values" | sed -n '1p')"
  STATE_PATH_FILE="$(printf '%s\n' "$values" | sed -n '2p')"
  STATE_PATH_POLICY="$(printf '%s\n' "$values" | sed -n '3p')"
  [ "$(printf '%s\n' "$values" | sed -n '4p')" = "valid" ] && STATE_LOADED=1
  [ "$(printf '%s\n' "$values" | sed -n '5p')" = "configured" ] && STATE_CONFIGURED=1
  return 0
}

detect_installed_tools() {
  local detected=""
  local tool=""
  for tool in claude codex cursor opencode; do
    tool_installed "$tool" && detected="${detected:+$detected,}$tool"
  done
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

tool_installed() {
  case "$1" in
    claude) install_state_records_tool claude || has_ownership_marker "$(get_claude_config_dir)/plugins/cache/macroscope-local" ;;
    codex) install_state_records_tool codex || has_ownership_marker "$HOME/plugins/macroscope" || find "$(get_codex_home)/plugins/cache" -type f -name "$OWNERSHIP_MARKER_FILE" -path '*/macroscope/*/.macroscope-installed' -print -quit 2>/dev/null | grep -q . ;;
    cursor) install_state_records_tool cursor || has_ownership_marker "$HOME/.cursor/plugins/local/macroscope" ;;
    opencode) install_state_records_tool opencode || has_ownership_marker "$(get_opencode_config_dir)/skills/macroscope-codereview" ;;
    *) return 1 ;;
  esac
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

# prompt_menu renders a single-select vertical menu and sets TUI_RESULT to the
# zero-based index of the selected entry.
prompt_menu() {
  local question="$1"; shift
  local labels=("$@")
  local count="${#labels[@]}"
  local selected=0
  local first_render=1
  local index=0
  local label_color=""

  tui_start
  printf '\n%s%s?%s %s%s%s\n' "$GREEN" "$BOLD" "$RESET" "$BOLD" "$question" "$RESET" > /dev/tty
  printf '  %sUp/down or j/k to move; enter to choose.%s\n' "$DIM" "$RESET" > /dev/tty

  while true; do
    if [ "$first_render" -eq 0 ]; then
      printf '\033[%dA' "$count" > /dev/tty
    fi
    first_render=0
    index=0
    while [ "$index" -lt "$count" ]; do
      printf '\r\033[2K' > /dev/tty
      case "${labels[$index]}" in
        Yes) label_color="$GREEN" ;;
        "Show exact changes") label_color="$YELLOW" ;;
        *) label_color="$DIM" ;;
      esac
      if [ "$index" -eq "$selected" ]; then
        printf '%s%s>%s %s%s%s%s\n' "$CYAN" "$BOLD" "$RESET" "$label_color" "$BOLD" "${labels[$index]}" "$RESET" > /dev/tty
      else
        printf '  %s%s%s\n' "$label_color" "${labels[$index]}" "$RESET" > /dev/tty
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
  local mark=""

  for index in 0 1 2 3; do
    case ",$default_tools," in
      *",${tools[$index]},"*) checked[$index]=1 ;;
    esac
  done

  tui_start
  printf '\n%s%s?%s %sCoding agents%s\n' "$GREEN" "$BOLD" "$RESET" "$BOLD" "$RESET" > /dev/tty
  printf '  %sUp/down or j/k to move; space to toggle; enter to continue.%s\n' "$DIM" "$RESET" > /dev/tty

  while true; do
    if [ "$first_render" -eq 0 ]; then
      printf '\033[4A' > /dev/tty
    fi
    first_render=0
    for index in 0 1 2 3; do
      printf '\r\033[2K' > /dev/tty
      mark=' '
      [ "${checked[$index]}" -eq 0 ] || mark='x'
      if [ "$index" -eq "$selected" ]; then
        if [ "${checked[$index]}" -eq 1 ]; then
          printf '%s%s>%s %s%s[%s] %s%s\n' "$CYAN" "$BOLD" "$RESET" "$GREEN" "$BOLD" "$mark" "${labels[$index]}" "$RESET" > /dev/tty
        else
          printf '%s%s>%s %s[%s] %s%s\n' "$CYAN" "$BOLD" "$RESET" "$BOLD" "$mark" "${labels[$index]}" "$RESET" > /dev/tty
        fi
      elif [ "${checked[$index]}" -eq 1 ]; then
        printf '  %s[%s] %s%s\n' "$GREEN" "$mark" "${labels[$index]}" "$RESET" > /dev/tty
      else
        printf '  %s[%s] %s%s\n' "$DIM" "$mark" "${labels[$index]}" "$RESET" > /dev/tty
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
    local detected_tools=""
    detected_tools="$(detect_installed_tools)"
    if [ "$STATE_LOADED" -eq 1 ]; then
      default_tools="$STATE_TOOLS"
      if [ -n "$default_tools" ] && [ -n "$detected_tools" ]; then
        default_tools="$(normalize_tools "${default_tools}${default_tools:+,}${detected_tools}")"
      fi
    else
      default_tools="$detected_tools"
    fi
    prompt_default="$default_tools"
    if has_interactive_tty && [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$SAVED_AUTO_UPDATE" -eq 0 ]; then
      if [ -z "$prompt_default" ]; then
        printf '\n%s!%s %sNo Macroscope host integrations are currently selected.%s\n' "$YELLOW" "$RESET" "$BOLD" "$RESET" > /dev/tty
        printf '%s  Select integrations now so a CLI-only install is not preserved accidentally.%s\n' "$DIM" "$RESET" > /dev/tty
        prompt_default="claude,codex,cursor,opencode"
      else
        printf '\n%s•%s Current integrations are selected below.\n' "$CYAN" "$RESET" > /dev/tty
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

# Explicitly approved unattended updates that resume the original command reuse
# saved integration and PATH configuration without rendering the update TUI.
# Human invocations, dry runs, overrides, and incomplete legacy state keep the
# existing plan and confirmation flow.
resolve_saved_auto_update() {
  SAVED_AUTO_UPDATE=0
  [ "$INSTALL_MODE" = "update" ] || return 0
  [ "$RESUME_COMMAND" -eq 1 ] || return 0
  [ "$ASSUME_YES" -eq 1 ] || return 0
  [ "$STATE_CONFIGURED" -eq 1 ] || return 0
  [ -z "$TOOLS_SPEC" ] || return 0
  [ "$SKIP_PATH" -eq 0 ] || return 0
  [ -z "$SHELL_CONFIG_OVERRIDE" ] || return 0
  [ "$DRY_RUN" -eq 0 ] || return 0
  SAVED_AUTO_UPDATE=1
}

shell_config_line() {
  local install_bin="$HOME/.local/bin"
  local target_shell=""
  case "$PATH_TARGET" in
    */config.fish) target_shell="fish" ;;
    *.zshrc|*.zprofile|*.bashrc|*.bash_profile|*/.profile) target_shell="posix" ;;
    *) target_shell="$(login_shell_name)" ;;
  esac
  if [ "$target_shell" = "fish" ]; then
    printf 'set -Ux fish_user_paths %s $fish_user_paths' "$install_bin"
  else
    printf 'export PATH="%s:$PATH"' "$install_bin"
  fi
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

print_change_details() {
  local binary_action="Install"
  local tool=""
  local claude_config=""
  local codex_home=""
  local codex_marketplace=""
  local codex_plugin_key=""
  local opencode_config=""
  local quoted_codex_binary=""
  local default_env="${MACROSCOPE_DEFAULT_ENV:-prod}"
  [ "$INSTALL_MODE" = "update" ] && binary_action="Replace"
  claude_config="$(get_claude_config_dir)"
  codex_home="$(get_codex_home)"
  codex_marketplace="$(get_codex_marketplace_name)"
  codex_plugin_key="macroscope@$codex_marketplace"
  opencode_config="$(get_opencode_config_dir)"
  case "$default_env" in prod|nonprod|local) ;; *) default_env="prod" ;; esac

  if tool_selected codex && codex_shim_will_install; then
    quoted_codex_binary="$(python3 - "$CODEX_BUNDLED_BINARY" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
)"
  fi

  _ccd_file() { printf '\n  %s%s%s%s\n' "$BOLD" "$CYAN" "$1" "$RESET"; }
  _ccd_key() { printf '    %s:\n' "$1"; }
  _ccd_add() { printf '      %s+ %s%s\n' "$GREEN" "$1" "$RESET"; }
  _ccd_remove() { printf '      %s- %s%s\n' "$RED" "$1" "$RESET"; }

  {
    printf '\n%sExact changes%s\n' "$BOLD" "$RESET"
    printf '  %sExisting settings are preserved; the snippets below are merged, refreshed, or removed.%s\n' "$DIM" "$RESET"

    _ccd_file "$HOME/.local/bin/macroscope"
    if [ -n "${MACROSCOPE_LOCAL_BACK_REPO:-}" ]; then
      _ccd_add "$binary_action with a binary built from $MACROSCOPE_LOCAL_BACK_REPO"
    elif [ -n "${MACROSCOPE_LOCAL_BINARY_SOURCE:-}" ]; then
      _ccd_add "$binary_action from $MACROSCOPE_LOCAL_BINARY_SOURCE"
    else
      _ccd_add "$binary_action the $INSTALL_VERSION release for $OS-$ARCH"
    fi

    if [ "$PATH_ACTION" = "modify" ]; then
      _ccd_file "$PATH_TARGET"
      _ccd_add '# Added by Macroscope installer'
      _ccd_add "$(shell_config_line)"
    fi

    for tool in claude codex cursor opencode; do
      if tool_selected "$tool"; then
        case "$tool" in
          claude)
            _ccd_file "$claude_config/settings.json"
            _ccd_key 'extraKnownMarketplaces.macroscope-local'
            _ccd_add '{'
            _ccd_add '  "source": {'
            _ccd_add '    "source": "directory",'
            _ccd_add "    \"path\": \"$claude_config/plugins/marketplaces/macroscope-local\""
            _ccd_add '  }'
            _ccd_add '}'
            _ccd_key 'enabledPlugins'
            _ccd_add '"macroscope@macroscope-local": true'
            _ccd_file "$claude_config/plugins/marketplaces/macroscope-local/"
            _ccd_add 'Macroscope marketplace and plugin bundle'
            _ccd_file "$claude_config/plugins/cache/macroscope-local/"
            _ccd_add 'Macroscope plugin cache'
            ;;
          codex)
            _ccd_file "$HOME/.agents/plugins/marketplace.json"
            _ccd_key 'plugins[]'
            _ccd_add '{'
            _ccd_add '  "name": "macroscope",'
            _ccd_add '  "source": {"source": "local", "path": "./plugins/macroscope"},'
            _ccd_add '  "policy": {'
            _ccd_add '    "installation": "INSTALLED_BY_DEFAULT",'
            _ccd_add '    "authentication": "ON_USE"'
            _ccd_add '  },'
            _ccd_add '  "category": "Development"'
            _ccd_add '}'
            _ccd_file "$codex_home/config.toml"
            _ccd_add '[features]'
            _ccd_add 'plugins = true'
            _ccd_add "[plugins.\"$codex_plugin_key\"]"
            _ccd_add 'enabled = true'
            _ccd_file "$HOME/plugins/macroscope/"
            _ccd_add 'Macroscope plugin source'
            _ccd_file "$codex_home/plugins/cache/$codex_marketplace/macroscope/$CODEX_LOCAL_PLUGIN_VERSION/"
            _ccd_add 'Macroscope plugin cache'
            if [ -n "$quoted_codex_binary" ]; then
              _ccd_file "$HOME/.local/bin/codex"
              _ccd_add '#!/bin/bash'
              _ccd_add 'set -euo pipefail'
              _ccd_add '# Macroscope-managed Codex shim'
              _ccd_add "exec $quoted_codex_binary \"\$@\""
            fi
            ;;
          cursor)
            _ccd_file "$HOME/.cursor/plugins/local/macroscope/"
            _ccd_add 'Macroscope plugin bundle'
            ;;
          opencode)
            _ccd_file "$opencode_config"
            _ccd_add 'plugins/macroscope.js'
            _ccd_add 'commands/macroscope-codereview.md'
            _ccd_add 'commands/macroscope-autoloop.md'
            _ccd_add 'skills/macroscope-codereview/'
            _ccd_add 'skills/macroscope-autoloop/'
            ;;
        esac
      elif [ "$INSTALL_MODE" = "update" ] && tool_installed "$tool"; then
        case "$tool" in
          claude)
            _ccd_file "$claude_config/settings.json"
            _ccd_key 'extraKnownMarketplaces'
            _ccd_remove '"macroscope-local"'
            _ccd_key 'enabledPlugins'
            _ccd_remove '"macroscope@macroscope-local"'
            _ccd_file "$claude_config/plugins/"
            _ccd_remove 'marketplaces/macroscope-local/'
            _ccd_remove 'cache/macroscope-local/'
            ;;
          codex)
            _ccd_file "$HOME/.agents/plugins/marketplace.json"
            _ccd_key 'plugins[]'
            _ccd_remove 'entry with "name": "macroscope"'
            _ccd_file "$codex_home/config.toml"
            _ccd_remove "[plugins.\"$codex_plugin_key\"]"
            _ccd_file "$HOME/plugins/"
            _ccd_remove 'macroscope/'
            _ccd_file "$codex_home/plugins/cache/"
            _ccd_remove "$codex_marketplace/macroscope/$CODEX_LOCAL_PLUGIN_VERSION/"
            ;;
          cursor)
            _ccd_file "$HOME/.cursor/plugins/local/"
            _ccd_remove 'macroscope/'
            ;;
          opencode)
            _ccd_file "$opencode_config"
            _ccd_remove 'plugins/macroscope.js'
            _ccd_remove 'commands/macroscope-codereview.md'
            _ccd_remove 'commands/macroscope-autoloop.md'
            _ccd_remove 'skills/macroscope-codereview/'
            _ccd_remove 'skills/macroscope-autoloop/'
            ;;
        esac
      fi
    done

    if [ "$INSTALL_MODE" = "update" ]; then
      _ccd_file 'Legacy MCP integration (when present)'
      _ccd_remove "$HOME/.local/bin/macroscope-mcp"
      _ccd_key "$(get_claude_state_file): mcpServers / projects.*.mcpServers"
      _ccd_remove '"macroscope-codereview"'
      _ccd_key "$HOME/.cursor/mcp.json: mcpServers"
      _ccd_remove '"macroscope-codereview"'
      _ccd_key "$codex_home/config.toml"
      _ccd_remove '[mcp_servers.macroscope-codereview]'
    fi

    if { [ -n "${MACROSCOPE_LOCAL_BACK_REPO:-}" ] || [ -n "${MACROSCOPE_LOCAL_BINARY_SOURCE:-}" ]; } && [ ! -f "$HOME/.macroscope/config.yaml" ]; then
      _ccd_file "$HOME/.macroscope/config.yaml"
      _ccd_add "env: $default_env"
      _ccd_add 'envs: {}'
    fi

    if [ "$WIZARD_MODE" = "yes" ]; then
      _ccd_file 'After installation'
      _ccd_add 'Launch the setup wizard after verification'
    fi
  } > /dev/tty

  unset -f _ccd_file _ccd_key _ccd_add _ccd_remove
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

  while true; do
    if ! prompt_menu "$prompt" "Yes" "Show exact changes" "No"; then
      info "Cancelled before making changes."
      return 3
    fi
    case "$TUI_RESULT" in
      0) return 0 ;;
      1) print_change_details ;;
      *) info "Cancelled before making changes."; return 3 ;;
    esac
  done
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

# Shell-side mirror of is_safe_marketplace_name: a single, ordinary path
# component. Every marketplace name that reaches a filesystem path passes
# through here before it is used, including names python already vetted.
is_safe_marketplace_name() {
  case "${1:-}" in
    "" | "." | "..") return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# The Codex marketplace name as a path component. An unusable name degrades to
# the default the installer itself creates rather than propagating into a path.
get_codex_marketplace_name() {
  local name=""
  name="$(python3 - "$HOME/.agents/plugins/marketplace.json" <<'PY'
import json, os, sys
name = "local-user-plugins"
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    value = data.get("name") if isinstance(data, dict) else None
    if isinstance(value, str) and value.strip(): name = value.strip()
except Exception: pass
print(name)
PY
)"
  is_safe_marketplace_name "$name" || name="local-user-plugins"
  printf '%s' "$name"
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

# Shared python: which Codex marketplace entries this installer owns. It is
# prepended to every python snippet that adds or removes marketplace entries so
# install and cleanup cannot drift apart. Ownership is name AND source path: a
# plugin named `macroscope` that another marketplace registered from its own
# source belongs to that marketplace, and unregistering it by name alone would
# silently break an unrelated install.
PY_PLUGIN_OWNERSHIP='
import re as _marketplace_re

OWNED_PLUGIN_NAMES = {"macroscope", "macroscope-codereview"}
# A marketplace name out of marketplace.json becomes a directory component of
# the Codex plugin cache path, and that path is handed to routines that `rm
# -rf` it. `../../victim` there would escape the cache root, so a name is only
# usable as a path when it is a single, ordinary path component.
SAFE_MARKETPLACE_NAME = _marketplace_re.compile(r"^[A-Za-z0-9._-]+$")


def is_safe_marketplace_name(value):
    if not isinstance(value, str):
        return False
    name = value.strip()
    if not name or name in (".", ".."):
        return False
    return bool(SAFE_MARKETPLACE_NAME.match(name))
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
    return normalized_string(value) in OWNED_RELATIVE_PLUGIN_PATHS


def is_owned_marketplace_entry(item):
    if not isinstance(item, dict):
        return False
    if normalized_string(item.get("name")) not in OWNED_PLUGIN_NAMES:
        return False
    source = item.get("source")
    source_path = source.get("path") if isinstance(source, dict) else None
    return is_owned_relative_plugin_path(source_path)
'

# Shared python: whether an install-state record is one this installer's
# lineage wrote before it began recording `binaryPath`. Such a record is the
# only evidence that the managed directory's `macroscope` (and the legacy
# `macroscope-mcp` beside it) belongs to us when nothing names the path.
#
# Schema 1 and 2 predate `binaryPath` outright. Schema 3 was also shipped by a
# release that recorded no `binaryPath`, so the schema number alone cannot
# decide it; what proves the record is ours there is its shape — the complete
# key set write_install_state has always emitted. A hand-written fragment
# carrying only a schema number and a tool list proves nothing about a binary
# sitting in the shared ~/.local/bin, and neither does a missing state file.
PY_STATE_OWNERSHIP='
def state_predates_binary_path(data):
    if not isinstance(data, dict):
        return False
    recorded = data.get("binaryPath")
    if isinstance(recorded, str) and recorded.strip():
        return False
    if not isinstance(data.get("tools"), list):
        return False
    try:
        schema_version = int(data.get("schemaVersion"))
    except (TypeError, ValueError):
        schema_version = 0
    if schema_version in (1, 2):
        return True
    return (
        isinstance(data.get("version"), str)
        and "pathFile" in data
        and ("pathPolicy" in data or "permissionOwnership" in data)
    )
'

# Shared python: which `macroscope-codereview` MCP registrations this installer
# owns. The name alone is not ownership — a user is free to register a server
# under it pointing at their own binary — so a registration is ours only when
# its command (or one of its args) is a binary this installer wrote: the one in
# the managed install directory, the path install state recorded, or the legacy
# `macroscope-mcp` binary older releases registered. A bare command name with no
# directory in it can only resolve through PATH to one of ours.
PY_MCP_OWNERSHIP="$PY_STATE_OWNERSHIP"'
import ast as _mcp_ast
import json as _mcp_json
import os as _mcp_os
import re as _mcp_re
import shutil as _mcp_shutil

MACROSCOPE_MCP_SERVER_NAME = "macroscope-codereview"
OWNED_MCP_COMMAND_NAMES = {"macroscope", "macroscope-mcp"}


def _mcp_normalize(value):
    return _mcp_os.path.normpath(_mcp_os.path.expanduser(value.strip()))


def owned_mcp_binary_paths(home, managed_dir, install_state):
    paths = set()
    try:
        with open(install_state, encoding="utf-8") as f:
            state = _mcp_json.load(f)
    except Exception:
        state = None
    if isinstance(state, dict):
        recorded = state.get("binaryPath")
        if isinstance(recorded, str) and recorded.strip():
            paths.add(_mcp_normalize(recorded))
        elif state_predates_binary_path(state):
            for name in OWNED_MCP_COMMAND_NAMES:
                paths.add(_mcp_normalize(_mcp_os.path.join(managed_dir, name)))
                paths.add(_mcp_normalize(_mcp_os.path.join(home, ".local", "bin", name)))
    return paths


def is_owned_mcp_server(entry, owned_paths):
    if not isinstance(entry, dict):
        return False
    values = []
    command = entry.get("command")
    if isinstance(command, str):
        values.append(command)
    args = entry.get("args")
    if isinstance(args, list):
        values.extend(item for item in args if isinstance(item, str))
    for value in values:
        candidate = value.strip()
        if not candidate:
            continue
        if "/" not in candidate:
            resolved = _mcp_shutil.which(candidate)
            if candidate in OWNED_MCP_COMMAND_NAMES and resolved and _mcp_normalize(resolved) in owned_paths:
                return True
            continue
        if _mcp_normalize(candidate) in owned_paths:
            return True
    return False


def drop_owned_mcp_server(servers, owned_paths, where):
    if not isinstance(servers, dict) or MACROSCOPE_MCP_SERVER_NAME not in servers:
        return False
    if not is_owned_mcp_server(servers[MACROSCOPE_MCP_SERVER_NAME], owned_paths):
        print(
            "Left the user-defined %s MCP server in %s (its command is not a Macroscope-installed binary)"
            % (MACROSCOPE_MCP_SERVER_NAME, where)
        )
        return False
    del servers[MACROSCOPE_MCP_SERVER_NAME]
    return True


def drop_owned_mcp_servers_in_projects(projects, owned_paths, where):
    if not isinstance(projects, dict):
        return False
    changed = False
    for project in projects.values():
        if not isinstance(project, dict):
            continue
        if drop_owned_mcp_server(project.get("mcpServers"), owned_paths, where):
            changed = True
    return changed


def drop_owned_codex_mcp_server(text, owned_paths, where):
    table = _mcp_re.search(
        r"""(?ms)^[ \t]*\[mcp_servers\.(?:macroscope-codereview|"macroscope-codereview")\][^\r\n]*(?:\r?\n|\Z).*?(?=^[ \t]*\[[^\]\r\n]+\][ \t]*(?:#.*)?\r?$|\Z)""",
        text,
    )
    if table is None:
        return text, False

    entry = {}
    for key in ("command", "args"):
        match = _mcp_re.search(rf"""(?m)^[ \t]*{key}[ \t]*=[ \t]*(.+)$""", table.group(0))
        if match is None:
            continue
        try:
            entry[key] = _mcp_ast.literal_eval(match.group(1).strip())
        except (SyntaxError, ValueError):
            print("Left the user-defined %s MCP server in %s (its TOML could not be proven installer-owned)" % (MACROSCOPE_MCP_SERVER_NAME, where))
            return text, False

    if not is_owned_mcp_server(entry, owned_paths):
        print("Left the user-defined %s MCP server in %s (its command is not a Macroscope-installed binary)" % (MACROSCOPE_MCP_SERVER_NAME, where))
        return text, False
    return text[: table.start()] + text[table.end() :], True
'

remove_file_if_present() {
  local path="$1"
  [ -f "$path" ] || return 1
  if ! rm -f "$path" 2>/dev/null; then
    warn "Could not remove $path"
    return 1
  fi
  success "Removed $path"
}

remove_dir_if_present() {
  local path="$1"
  [ -d "$path" ] || return 1
  if ! rm -rf "$path" 2>/dev/null; then
    warn "Could not remove $path"
    return 1
  fi
  success "Removed $path"
}

# Explicit ownership marker. Every skill and plugin directory this installer
# writes gets one, and its presence — not a guess about the directory's
# contents — is what authorizes removing or overwriting that directory later.
# Contents: the release that wrote it and when.
OWNERSHIP_MARKER_FILE=".macroscope-installed"

write_ownership_marker() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  {
    printf 'version=%s\n' "${INSTALLED_VERSION:-unknown}"
    printf 'installedAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$dir/$OWNERSHIP_MARKER_FILE" 2>/dev/null || {
    warn "Could not write the Macroscope ownership marker in $dir"
    return 1
  }
  return 0
}

# The marker authorizes `rm -rf` of the directory holding it, so its content
# is read, not merely its name: a file another tool happened to call
# `.macroscope-installed`, or one restored from an unrelated backup, proves
# nothing. Only the two lines write_ownership_marker emits count.
has_ownership_marker() {
  local marker="$1/$OWNERSHIP_MARKER_FILE"
  [ -f "$marker" ] || return 1
  grep -Eq '^version=.+$' "$marker" || return 1
  ! grep -Evq '^([[:space:]]*|(version|installedAt)=.*)$' "$marker"
}

# Codex caches a plugin one level deeper than the rest — `<marketplace>/
# <plugin>/<version>` — and the marker is written in the version directory. A
# cache entry is ours when the entry itself or any version under it carries one.
remove_owned_codex_cache_versions() {
  local dir="$1"
  local legacy_owned="$2"
  local child=""
  local removed=0
  [ -d "$dir" ] || return 1
  for child in "$dir"/*; do
    [ -d "$child" ] || continue
    if has_ownership_marker "$child" || { [ "$legacy_owned" -eq 1 ] && [ "$(basename "$child")" = local ]; }; then
      remove_dir_if_present "$child" || true
      removed=1
    fi
  done
  [ "$removed" -eq 1 ] || info "Left $dir in place (no Macroscope ownership marker)"
  rmdir "$dir" 2>/dev/null || true
}

# True when our own install state records that we installed the named tool.
# The state file is the only durable record an older release left behind, so
# it is the evidence legacy (pre-marker) cleanup relies on.
install_state_records_tool() {
  local tool="$1"
  case ",$ADOPTED_TOOLS," in *",$tool,"*) return 0 ;; esac
  local state_file="${STATE_FILE:-$(state_file_path)}"
  [ -f "$state_file" ] || return 1
  python3 - "$state_file" "$tool" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    raise SystemExit(1)
tools = data.get("tools") if isinstance(data, dict) else None
raise SystemExit(0 if isinstance(tools, list) and sys.argv[2] in tools else 1)
PY
}

# Install state is the durable record of what an earlier release installed, and
# an install whose state file went missing or was truncated mid-write has lost
# it. Without a replacement the update refuses its own artifacts as unowned and
# strands the user on the old release.
#
# Recovery is by shape, never by name: a host integration is adopted only when
# the artifacts on disk are the exact ones a Macroscope installer wrote — the
# registration pointing at the installer's own directory, alongside the plugin
# manifest that directory is supposed to contain. Anything that fails the shape
# check stays unowned, and an install state that still parses is authoritative,
# so adoption never overrides a real record.
detect_adoptable_legacy_tools() {
  {
    printf '%s\n' "$PY_PLUGIN_OWNERSHIP"
    cat <<'PY'
import json
import os
import sys

home, claude_config, opencode_config = sys.argv[1:4]
adopted = []


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def manifest_named_macroscope(path):
    data = load(path)
    return isinstance(data, dict) and data.get("name") == "macroscope"


def has_ownership_marker(path):
    try:
        with open(os.path.join(path, ".macroscope-installed"), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except Exception:
        return False
    return any(line.startswith("version=") and len(line) > 8 for line in lines) and all(
        not line.strip() or line.startswith(("version=", "installedAt=")) for line in lines
    )


def registers_marketplace_directory(data, root):
    if not isinstance(data, dict):
        return False
    entry = data.get("macroscope-local")
    if not isinstance(entry, dict):
        return False
    source = entry.get("source")
    if not isinstance(source, dict):
        return False
    return source.get("source") == "directory" and source.get("path") == root


marketplace_root = os.path.join(claude_config, "plugins", "marketplaces", "macroscope-local")
claude_settings = load(os.path.join(claude_config, "settings.json"))
registered = registers_marketplace_directory(
    load(os.path.join(claude_config, "plugins", "known_marketplaces.json")), marketplace_root
) or registers_marketplace_directory(
    claude_settings.get("extraKnownMarketplaces") if isinstance(claude_settings, dict) else None,
    marketplace_root,
)
if registered and manifest_named_macroscope(
    os.path.join(marketplace_root, "plugins", "macroscope", ".claude-plugin", "plugin.json")
):
    adopted.append("claude")

codex_marketplace = load(os.path.join(home, ".agents", "plugins", "marketplace.json"))
codex_plugins = codex_marketplace.get("plugins") if isinstance(codex_marketplace, dict) else None
if isinstance(codex_plugins, list) and any(is_owned_marketplace_entry(item) for item in codex_plugins):
    if manifest_named_macroscope(
        os.path.join(home, "plugins", "macroscope", ".codex-plugin", "plugin.json")
    ):
        adopted.append("codex")

if manifest_named_macroscope(
    os.path.join(home, ".cursor", "plugins", "local", "macroscope", ".cursor-plugin", "plugin.json")
):
    adopted.append("cursor")

if os.path.isfile(os.path.join(opencode_config, "plugins", "macroscope.js")) and all(
    os.path.isfile(os.path.join(opencode_config, "commands", name))
    for name in ("macroscope-codereview.md", "macroscope-autoloop.md")
) and all(
    has_ownership_marker(os.path.join(opencode_config, "skills", name))
    for name in ("macroscope-codereview", "macroscope-autoloop")
):
    adopted.append("opencode")

print(",".join(adopted))
PY
  } | python3 - "$HOME" "$(get_claude_config_dir)" "$(get_opencode_config_dir)"
}

adopt_legacy_install() {
  ADOPTED_TOOLS=""
  [ "$STATE_LOADED" -eq 0 ] || return 0
  ADOPTED_TOOLS="$(detect_adoptable_legacy_tools)"
  [ -n "$ADOPTED_TOOLS" ] || return 0
  warn "No usable Macroscope install state was found at $STATE_FILE."
  info "Adopting the existing Macroscope $ADOPTED_TOOLS integration(s) found on disk and recording fresh state."
}

# Pre-marker heuristic, kept only as the second half of the legacy test below:
# every skill the installer copied out of the plugin bundle both names
# Macroscope and drives the `macroscope` CLI directly. It is not sufficient on
# its own — a user's own notes on Macroscope can satisfy it.
is_macroscope_owned_skill_dir() {
  local path="$1"
  [ -d "$path" ] || return 1
  [ -f "$path/SKILL.md" ] || return 1
  grep -qi 'macroscope' "$path/SKILL.md" || return 1
  grep -Eq '(^|[^[:alnum:]_.-])macroscope +[a-z][a-z-]+' "$path/SKILL.md"
}

# What the bundle ships for a skill, one relative path per line. The bundle is
# only staged during an install, so repair and uninstall fall back to the shape
# every release has shipped: a lone SKILL.md.
bundled_skill_entries() {
  local skill="$1"
  local src=""
  [ -z "$CHECKOUT_DIR" ] || src="$CHECKOUT_DIR/plugins/macroscope/skills/$skill"
  if [ -n "$src" ] && [ -d "$src" ]; then
    ( cd "$src" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort )
    return 0
  fi
  printf 'SKILL.md\n'
}

# True when the directory holds nothing the bundle does not ship for that
# skill. A `scripts/` or `references/` tree is a shape no release ever wrote,
# so the directory is the user's however much its SKILL.md talks about
# Macroscope — text alone is the weakest possible evidence, and it is exactly
# what a user's own notes on Macroscope satisfy.
skill_dir_matches_bundle_shape() {
  local path="$1"
  local skill="$2"
  local shipped=""
  local entry=""
  shipped="$(bundled_skill_entries "$skill")"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    printf '%s\n' "$shipped" | grep -qxF -- "$entry" || return 1
  done <<< "$( cd "$path" && find . -mindepth 1 ! -name "$OWNERSHIP_MARKER_FILE" | sed 's|^\./||' | LC_ALL=C sort )"
  return 0
}

# The same evidence bar as a legacy skill directory, applied to the command
# files beside it. Every command file any release has written is a two-line
# body that hands off to the skill directory next to it, so that handoff — plus
# naming Macroscope — is the shape. Prose about Macroscope is not: a user's own
# `review-pr.md` describing how they run `macroscope codereview` satisfies a
# text search and is still theirs.
is_macroscope_owned_command_file() {
  local path="$1"
  [ -f "$path" ] || return 1
  grep -qi 'macroscope' "$path" || return 1
  grep -Eq '\.\./skills/[A-Za-z0-9._-]+/SKILL\.md' "$path"
}

# A directory at one of our prefixed paths is ours only when it carries the
# marker. Anything else there was put there by the user.
remove_marked_skill_dir() {
  local path="$1"
  [ -d "$path" ] || return 1
  if ! has_ownership_marker "$path"; then
    info "Left $path in place (no Macroscope ownership marker)"
    return 1
  fi
  remove_dir_if_present "$path"
}

# OpenCode's skill namespace is flat, so the unprefixed directory names this
# installer shipped before the `macroscope-` prefix (`codereview`, `autoloop`,
# and the older `local-review`, `triage-pr-comments`,
# `respond-to-pr-comments`, `review-pr`) are names an unrelated user skill can
# legitimately own, and those releases wrote no marker. Removing one therefore
# needs both halves of the circumstantial evidence: our install state must
# record that we installed the OpenCode integration, and the directory must
# still match the pre-marker heuristic. Either one missing and it stays.
# REPORT_ONLY=1 runs every check and prints every explanation without touching
# the directory, so the reasons can be reported when the OpenCode integration
# is withdrawn before anything is written.
remove_legacy_skill_dir() {
  local path="$1"
  local report_only="${2:-0}"
  [ -d "$path" ] || return 1
  if has_ownership_marker "$path"; then
    [ "$report_only" -eq 0 ] || return 1
    remove_dir_if_present "$path"
    return
  fi
  if ! install_state_records_tool opencode; then
    info "Left $path in place (no recorded Macroscope OpenCode install)"
    return 1
  fi
  if ! is_macroscope_owned_skill_dir "$path"; then
    info "Left $path in place (not a Macroscope skill)"
    return 1
  fi
  if ! skill_dir_matches_bundle_shape "$path" "$(basename "$path")"; then
    info "Left $path in place (it holds files the Macroscope skill bundle never ships)"
    return 1
  fi
  [ "$report_only" -eq 0 ] || return 1
  remove_dir_if_present "$path"
}

# Installs before the `macroscope-` skill prefix dropped these directories into
# OpenCode's flat, user-wide skill namespace. Migrate ours away; a same-named
# directory we cannot prove is ours belongs to the user and stays put.
migrate_legacy_opencode_skills() {
  local opencode_skills="$1"
  local report_only="${2:-0}"
  local legacy=""
  for legacy in codereview autoloop local-review triage-pr-comments respond-to-pr-comments review-pr; do
    [ -d "$opencode_skills/$legacy" ] || continue
    if remove_legacy_skill_dir "$opencode_skills/$legacy" "$report_only"; then
      info "Migrated the legacy OpenCode skill directory $legacy to a macroscope- prefixed name"
    fi
  done
  return 0
}

# Pids of this script and every one of its ancestors, newline separated.
# The Macroscope CLI spawns this script for `macroscope uninstall` and for
# CLI-driven updates, so the invoking `macroscope` process is itself an
# ancestor: killing it by name would abort the cleanup that is running.
# POSIX `ps -o ppid=` only; no pstree, no GNU-only flags.
process_ancestor_pids() {
  local pid="$$"
  local hops=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt 64 ]; do
    printf '%s\n' "$pid"
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    hops=$((hops + 1))
  done
  return 0
}

# Filter a newline-separated pid list on stdin, dropping any pid present in
# the newline-separated list passed as $1.
exclude_pids() {
  local excluded="$1"
  local pid=""
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if ! printf '%s\n' "$excluded" | grep -qx -- "$pid"; then
      printf '%s\n' "$pid"
    fi
  done
  return 0
}

# Echo the still-running pids from the newline-separated list on stdin.
# Filter pids on stdin to those STILL reported by `pgrep -x NAME` right now.
# A pid alone is not an identity: between the TERM and the forced kill the
# original process can exit and the kernel can hand its number to something
# unrelated, so every later signal re-checks that the pid is still a process
# of the name we matched. `kill -0` alone would pass the reused pid.
process_is_owned() {
  local pid="$1"
  local owned="$2"
  python3 - "$pid" "$owned" <<'PY'
import ctypes
import os
import platform
import sys

pid = int(sys.argv[1])
paths = {os.path.realpath(path) for path in sys.argv[2].splitlines() if path}

try:
    if platform.system() == "Linux":
        executable = os.readlink(f"/proc/{pid}/exe")
    elif platform.system() == "Darwin":
        buffer = ctypes.create_string_buffer(4096)
        if ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath(pid, buffer, len(buffer)) <= 0:
            raise OSError
        executable = os.fsdecode(buffer.value)
    else:
        raise OSError
except OSError:
    raise SystemExit(1)

raise SystemExit(0 if os.path.realpath(executable) in paths else 1)
PY
}

owned_process_pids() {
  local owned="$1"
  local pid=""
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    process_is_owned "$pid" "$owned" && printf '%s\n' "$pid"
  done
  return 0
}

still_owned_named_pids() {
  local name="$1"
  local owned="$2"
  local pid=""
  local current=""
  current="$(pgrep -x "$name" 2>/dev/null || true)"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if printf '%s\n' "$current" | grep -qx -- "$pid" && process_is_owned "$pid" "$owned"; then
      printf '%s\n' "$pid"
    fi
  done
  return 0
}

kill_running_processes() {
  local found=0
  local name=""
  local pids=""
  local pid=""
  local remaining=""
  local ancestors=""
  local deadline=""
  local owned=""

  if ! command -v pgrep >/dev/null 2>&1; then
    info "pgrep not available; skipping process cleanup"
    return
  fi

  ancestors="$(process_ancestor_pids)"
  owned="$(recorded_binary_paths)"
  if install_state_predates_binary_path; then
    owned="${owned}${owned:+$'\n'}${INSTALL_DIR:-$HOME/.local/bin}/macroscope"
    owned="${owned}"$'\n'"${INSTALL_DIR:-$HOME/.local/bin}/macroscope-mcp"
  fi

  for name in macroscope macroscope-mcp; do
    pids="$(pgrep -x "$name" 2>/dev/null | exclude_pids "$ancestors" | owned_process_pids "$owned" || true)"
    [ -n "$pids" ] || continue
    found=1

    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      pid="$(still_owned_named_pids "$name" "$owned" <<< "$pid")"
      [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done <<< "$pids"

    deadline=$((SECONDS + 3))
    remaining="$(still_owned_named_pids "$name" "$owned" <<< "$pids")"
    while [ -n "$remaining" ] && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.1
      remaining="$(still_owned_named_pids "$name" "$owned" <<< "$pids")"
    done

    if [ -n "$remaining" ]; then
      # Re-validate once more immediately before the forced kill: the wait
      # loop's last read may be up to 100ms stale.
      remaining="$(still_owned_named_pids "$name" "$owned" <<< "$remaining")"
      while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        kill -9 "$pid" 2>/dev/null || true
      done <<< "$remaining"
      sleep 0.2
    fi
  done

  if [ "$found" -eq 0 ]; then
    info "No running Macroscope processes found"
  else
    success "Stopped running Macroscope processes"
  fi
}

# Binary paths the install state records, plus the `.old` rollback copy the
# CLI writes beside each one during a self-update. One path per line; empty
# when nothing was recorded (legacy install). Nothing else is derived: a
# sibling name is a guess, not a record.
recorded_binary_paths() {
  local state_file="${STATE_FILE:-$(state_file_path)}"
  [ -f "$state_file" ] || return 0
  python3 - "$state_file" "$HOME" "${INSTALL_DIR:-$HOME/.local/bin}" "$(system_bin_dirs)" <<'PY'
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)
if not isinstance(data, dict):
    raise SystemExit(0)
value = data.get("binaryPath")
if isinstance(value, str) and value.strip():
    path = os.path.normpath(os.path.expanduser(value.strip()))
    allowed_dirs = {os.path.normpath(sys.argv[3]), os.path.join(os.path.normpath(sys.argv[2]), ".local", "bin")}
    allowed_dirs.update(os.path.normpath(path) for path in sys.argv[4].split(os.pathsep) if path)
    if os.path.basename(path) not in ("macroscope", "macroscope-mcp") or os.path.dirname(path) not in allowed_dirs:
        raise SystemExit(0)
    print(path)
    print(path + ".old")
PY
}

# True when install state exists but records no binary path: an install this
# installer wrote before it began recording `binaryPath`. That is the only
# circumstance in which the managed directory's binary is ours without the
# state naming it. No state file at all proves nothing and returns false.
install_state_predates_binary_path() {
  local state_file="${STATE_FILE:-$(state_file_path)}"
  [ -f "$state_file" ] || return 1
  {
    printf '%s\n' "$PY_STATE_OWNERSHIP"
    cat <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if state_predates_binary_path(data) else 1)
PY
  } | python3 - "$state_file"
}

remove_owned_plugin_dir() {
  local dir="$1"
  local tool="$2"
  [ -d "$dir" ] || return 1
  if ! has_ownership_marker "$dir" && ! install_state_records_tool "$tool"; then
    info "Left $dir in place (no Macroscope ownership marker or install record)"
    return 1
  fi
  remove_dir_if_present "$dir"
}

# Prefixes a `macroscope` binary can occupy without this installer having put
# it there: Homebrew, a manual `go install`, a distro package. Colon separated,
# overridable so tests can point the candidates inside their sandbox HOME
# instead of probing the real host.
system_bin_dirs() {
  printf '%s' "${MACROSCOPE_SYSTEM_BIN_DIRS:-/usr/local/bin:/opt/homebrew/bin:$HOME/go/bin}"
}

cleanup_binaries() {
  local removed=0
  local path=""
  local dir=""
  local recorded=""
  local managed_dir="${INSTALL_DIR:-$HOME/.local/bin}"
  local shim_path="$HOME/.local/bin/codex"

  recorded="$(recorded_binary_paths)"

  # ~/.local/bin is a shared user directory, not a directory this installer
  # owns: a `macroscope` binary there can equally be a manual build somebody
  # dropped in. Deleting one needs evidence. The state file recording the path
  # is the strongest; a state file that records no binaryPath at all is a
  # legacy install of ours, written before the path was recorded, and it is
  # evidence that the managed directory's copy is the one we put there. With no
  # install state, nothing proves the file is ours and it stays.
  for path in \
    "$managed_dir/macroscope" \
    "$managed_dir/macroscope.old" \
    "$managed_dir/macroscope-mcp"
  do
    [ -e "$path" ] || continue
    if printf '%s\n' "$recorded" | grep -qxF -- "$path" || install_state_predates_binary_path; then
      if remove_file_if_present "$path"; then
        removed=1
      fi
    else
      info "Left $path in place (not recorded as installed by Macroscope)"
    fi
  done

  # Anything outside it needs an explicit record from install time.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in "$managed_dir"/*) continue ;; esac
    if remove_file_if_present "$path"; then
      removed=1
    fi
  done <<< "$recorded"

  # A macroscope binary in a system prefix that our state does not name was put
  # there by somebody else. Say so rather than deleting it by basename.
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    for path in "$dir/macroscope" "$dir/macroscope-mcp"; do
      [ -e "$path" ] || continue
      if printf '%s\n' "$recorded" | grep -qxF -- "$path"; then
        continue
      fi
      info "Left $path in place (not recorded as installed by Macroscope)"
    done
  done <<< "$(system_bin_dirs | tr ':' '\n')"

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
    "$codex_home/plugins/macroscope-codereview"
  do
    if remove_owned_plugin_dir "$dir" codex; then removed=1; fi
  done
  for dir in \
    "$claude_config/plugins/marketplaces/macroscope-local" \
    "$claude_config/plugins/cache/macroscope-local"
  do
    if remove_owned_plugin_dir "$dir" claude; then removed=1; fi
  done
  for dir in \
    "$HOME/.cursor/plugins/local/macroscope" \
    "$HOME/.cursor/plugins/local/macroscope-codereview"
  do
    if remove_owned_plugin_dir "$dir" cursor; then removed=1; fi
  done

  # OpenCode's skill namespace is flat and user-wide, so even a `macroscope-`
  # prefixed directory there is only ours if it carries the ownership marker.
  for dir in \
    "$opencode_config/skills/macroscope" \
    "$opencode_config/skills/macroscope-codereview" \
    "$opencode_config/skills/macroscope-autoloop" \
    "$opencode_config/skills/macroscope-local-review" \
    "$opencode_config/skills/macroscope-triage-pr-comments" \
    "$opencode_config/skills/macroscope-respond-to-pr-comments" \
    "$opencode_config/skills/macroscope-review-pr"
  do
    if remove_marked_skill_dir "$dir"; then
      removed=1
    fi
  done

  # Unprefixed OpenCode skill names predate the marker: legacy evidence only.
  for dir in \
    "$opencode_config/skills/codereview" \
    "$opencode_config/skills/autoloop" \
    "$opencode_config/skills/local-review" \
    "$opencode_config/skills/triage-pr-comments" \
    "$opencode_config/skills/respond-to-pr-comments" \
    "$opencode_config/skills/review-pr"
  do
    if remove_legacy_skill_dir "$dir"; then
      removed=1
    fi
  done

  if [ -d "$codex_plugin_cache_root" ]; then
    local owned_marketplace_names=""
    local candidate=""
    owned_marketplace_names="$(
      {
        printf '%s\n' "$PY_PLUGIN_OWNERSHIP"
        cat <<'PY'
import json
import os
import sys

path = sys.argv[1]
names = set()

if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = None
    if isinstance(data, dict):
        marketplace_name = data.get("name")
        plugins = data.get("plugins")
        if isinstance(plugins, list) and is_safe_marketplace_name(marketplace_name):
            if any(is_owned_marketplace_entry(item) for item in plugins):
                names.add(marketplace_name.strip())

for name in sorted(names):
    print(name)
PY
      } | python3 - "$codex_marketplace_json"
    )"
    # The cache is scanned by walking the directories that actually exist, not
    # by interpolating names out of marketplace.json: a name from that file can
    # only ever match a real directory, never steer one. `local-user-plugins`
    # is Codex's default marketplace, so a `macroscope` cache under it still
    # needs evidence — an installer-owned marketplace entry, or our ownership
    # marker inside the cached plugin — before it is deleted.
    for candidate in "$codex_plugin_cache_root"/*; do
      [ -d "$candidate" ] || continue
      marketplace_name="$(basename "$candidate")"
      is_safe_marketplace_name "$marketplace_name" || continue
      for dir in \
        "$candidate/macroscope" \
        "$candidate/macroscope-codereview"
      do
        [ -d "$dir" ] || continue
        local legacy_owned=0
        printf '%s\n' "$owned_marketplace_names" | grep -qxF -- "$marketplace_name" && legacy_owned=1
        remove_owned_codex_cache_versions "$dir" "$legacy_owned"
      done
    done
  fi

  if install_state_records_tool opencode || has_ownership_marker "$opencode_config/skills/macroscope-codereview" || has_ownership_marker "$opencode_config/skills/macroscope-autoloop"; then
    if remove_file_if_present "$opencode_config/plugins/macroscope.js"; then removed=1; fi
    # Command files share OpenCode's flat, user-wide namespace under names a
    # user can legitimately own, and no release ever wrote a marker beside one.
    # Install state naming "opencode" says an integration exists, not that this
    # particular file is part of it, so each file must still look like the
    # command body the bundle ships.
    for file in \
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
    "$opencode_config/commands/review-pr.md"
    do
      [ -f "$file" ] || continue
      if ! is_macroscope_owned_command_file "$file"; then
        info "Left $file in place (not a Macroscope command file)"
        continue
      fi
      if remove_file_if_present "$file"; then removed=1; fi
    done
  fi
  if install_state_records_tool claude || has_ownership_marker "$claude_config/plugins/marketplaces/macroscope-local"; then
    remove_file_if_present "$claude_config/hooks/macroscope-bash-autoallow.sh" && removed=1 || true
  fi

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

  {
    printf '%s\n' "$PY_PLUGIN_OWNERSHIP"
    printf '%s\n' "$PY_MCP_OWNERSHIP"
    cat <<'PY'
import json
import os
import re
import shlex
import sys
import tempfile

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
    home_dir,
    managed_bin_dir,
    installed_hook,
) = sys.argv[1:14]


def is_installed_hook_command(command):
    """True only for a command that runs the hook file this installer wrote.

    Matching the substring `macroscope-installer` anywhere in the command
    deletes a user's own ~/bin/audit-macroscope-installer-runs.sh from their
    settings, so the comparison is against the hook's path.
    """
    if not isinstance(command, str):
        return False
    text = command.strip()
    if not text:
        return False
    try:
        first = shlex.split(text)[0]
    except ValueError:
        first = text.split()[0]
    return os.path.normpath(os.path.expanduser(first)) == os.path.normpath(installed_hook)

owned_mcp_paths = owned_mcp_binary_paths(home_dir, managed_bin_dir, install_state)


def get_owned_marketplace_names(data):
    names = {"local-user-plugins"}
    if not isinstance(data, dict):
        return names

    marketplace_name = normalized_string(data.get("name"))
    plugins = data.get("plugins")
    if not marketplace_name or not isinstance(plugins, list):
        return names

    if any(is_owned_marketplace_entry(item) for item in plugins):
        names.add(marketplace_name)

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

    filtered = [item for item in entries if not is_owned_marketplace_entry(item)]
    return filtered, filtered != entries


def load_json(path):
    if not os.path.exists(path):
        return None, None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f), os.stat(path).st_mode
    except Exception:
        return None, None


def atomic_write_text(path, text, mode):
    """Replace path's contents with text, or leave the file untouched.

    A truncating open would destroy a user's marketplace.json, settings.json
    or config.toml if the process died, the disk filled, or the encode raised
    between truncate and write. Writing a sibling temp file, flushing it to
    disk, and renaming it over the target makes the replacement atomic: a
    reader sees either the old file or the new one, never a truncated one.
    """
    if os.path.islink(path):
        path = os.path.realpath(path)
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".macroscope-write-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_json(path, data, mode):
    atomic_write_text(path, json.dumps(data, indent=2) + "\n", mode)


# State files at or above this schema version come from an installer that
# writes no host permission rules at all. Their absent `permissionOwnership`
# therefore means "this install owns nothing", not "this install predates
# ownership tracking" — the distinction that keeps a user's own
# `Bash(macroscope *)` rule from being swept up by repair/uninstall.
OWNERSHIP_SCHEMA_VERSION = 3


# The one release that ever inserted host permission rules recorded them under
# schemaVersion 1. No release has written any other pre-3 schema, so a state
# file carrying one is not a record this installer's lineage produced.
GRANTING_SCHEMA_VERSION = 1


def read_permission_ownership(state):
    """Ownership map recorded by the install, or None for legacy state.

    None means pre-ownership legacy state: the caller falls back to the
    legacy rule set. A dict (possibly empty) means the install recorded its
    ownership, so only the rules it names may be removed.
    """
    if not isinstance(state, dict):
        # Missing or unparseable state proves nothing is ours: remove nothing.
        return {}
    recorded = state.get("permissionOwnership")
    if isinstance(recorded, dict):
        return recorded
    if recorded is not None:
        # Present but malformed: fail closed.
        return {}
    try:
        schema_version = int(state.get("schemaVersion"))
    except (TypeError, ValueError):
        schema_version = 0
    if schema_version >= OWNERSHIP_SCHEMA_VERSION:
        return {}
    return schema_version


install_state_data, _ = load_json(install_state)
permission_ownership = read_permission_ownership(install_state_data)


def owned_permission_rules(tool, legacy_rules, present_rules):
    """The rules this installation is entitled to remove for a host.

    With a recorded ownership map, only the rules it names. Without one, the
    legacy rule set — but that set is names, not proof: `Bash(macroscope *)` is
    a rule a user is free to write by hand, and deleting theirs is silent
    damage. State written by the release that actually granted rules is direct
    evidence. Any other pre-ownership state is not something a release wrote,
    so the rules must corroborate themselves: the grant always inserted its
    mktemp rules alongside its macroscope ones, and a set that carries none of
    them was written by somebody else.
    """
    if not isinstance(permission_ownership, int):
        tool_state = permission_ownership.get(tool, {})
        inserted = tool_state.get("inserted", []) if isinstance(tool_state, dict) else []
        return {rule for rule in inserted if isinstance(rule, str)} if isinstance(inserted, list) else set()
    legacy_rules = set(legacy_rules)
    if permission_ownership == GRANTING_SCHEMA_VERSION:
        return legacy_rules
    corroborating = {rule for rule in legacy_rules if "mktemp" in rule}
    if corroborating & set(present_rules):
        return legacy_rules
    return set()


def report_removed_permission_rules(where, removed):
    for rule in sorted(removed):
        print("Removed the %s rule a Macroscope install inserted in %s" % (rule, where))


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
    new_text, _ = drop_owned_codex_mcp_server(new_text, owned_mcp_paths, codex_config)
    new_text = re.sub(r'(?m)^# Added by Macroscope installer\n?', "", new_text)
    new_text = re.sub(r'\n{3,}', '\n\n', new_text).strip()
    if new_text:
        new_text += "\n"

    if new_text != text:
        atomic_write_text(codex_config, new_text, mode)


claude_data, claude_mode = load_json(claude_json)
if isinstance(claude_data, dict):
    changed = drop_owned_mcp_server(claude_data.get("mcpServers"), owned_mcp_paths, claude_json)
    if drop_owned_mcp_servers_in_projects(claude_data.get("projects"), owned_mcp_paths, claude_json):
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
        _owned = owned_permission_rules("claude", {"Bash(macroscope *)", "Bash(macroscope:*)", "Bash(mktemp *)", "Bash(mktemp:*)"}, allow if isinstance(allow, list) else [])
        if isinstance(allow, list) and any(x in _owned for x in allow):
            permissions["allow"] = [x for x in allow if x not in _owned]
            report_removed_permission_rules(path, [x for x in allow if x in _owned])
            changed = True
            if not permissions["allow"]:
                del permissions["allow"]
            if not permissions:
                data.pop("permissions", None)

    # Remove the PreToolUse Bash hook we installed, preserving any other hooks
    # the user configured. A matcher entry can hold several hooks, so the
    # nested list is filtered command by command: a user hook that happens to
    # share an entry with ours survives, and the entry itself is dropped only
    # once nothing is left in it.
    hooks_cfg = data.get("hooks")
    if isinstance(hooks_cfg, dict):
        pre_tool_use = hooks_cfg.get("PreToolUse")
        if isinstance(pre_tool_use, list):
            filtered = []
            for entry in pre_tool_use:
                if not isinstance(entry, dict):
                    filtered.append(entry)
                    continue
                nested = entry.get("hooks")
                if not isinstance(nested, list):
                    filtered.append(entry)
                    continue
                kept_hooks = [
                    h
                    for h in nested
                    if not (isinstance(h, dict) and is_installed_hook_command(h.get("command")))
                ]
                if kept_hooks == nested:
                    filtered.append(entry)
                    continue
                if not kept_hooks:
                    # Every hook in the entry was ours: the entry goes too.
                    continue
                kept_entry = dict(entry)
                kept_entry["hooks"] = kept_hooks
                filtered.append(kept_entry)
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
    if drop_owned_mcp_server(cursor_data.get("mcpServers"), owned_mcp_paths, cursor_mcp_json):
        write_json(cursor_mcp_json, cursor_data, cursor_mode)


cursor_cli_config = os.path.expanduser("~/.cursor/cli-config.json")
cursor_cli_data, cursor_cli_mode = load_json(cursor_cli_config)
if isinstance(cursor_cli_data, dict):
    changed = False
    permissions = cursor_cli_data.get("permissions")
    if isinstance(permissions, dict):
        allow = permissions.get("allow")
        _owned_shell = owned_permission_rules("cursor", {"Shell(macroscope)", "Shell(macroscope *)", "Shell(mktemp)", "Shell(mktemp *)"}, allow if isinstance(allow, list) else [])
        if isinstance(allow, list):
            filtered = [r for r in allow if r not in _owned_shell]
            if filtered != allow:
                permissions["allow"] = filtered
                report_removed_permission_rules(cursor_cli_config, [r for r in allow if r in _owned_shell])
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
            for key in owned_permission_rules("opencode", {"macroscope", "macroscope *", "mktemp", "mktemp *"}, list(bash)):
                if key in bash:
                    del bash[key]
                    report_removed_permission_rules(opencode_config, [key])
                    changed = True
            if not bash:
                del permission["bash"]
        if not permission:
            del opencode_data["permission"]
    if changed:
        write_json(opencode_config, opencode_data, opencode_mode)
PY
  } | python3 - \
    "$HOME/.agents/plugins/marketplace.json" \
    "$codex_home/config.toml" \
    "$(get_claude_state_file)" \
    "$claude_config/plugins/known_marketplaces.json" \
    "$claude_config/plugins/installed_plugins.json" \
    "$claude_config/settings.json" \
    "$claude_config/settings.local.json" \
    "$HOME/.cursor/mcp.json" \
    "$STATE_FILE" \
    "$opencode_config" \
    "$HOME" \
    "${INSTALL_DIR:-$HOME/.local/bin}" \
    "$claude_config/hooks/macroscope-bash-autoallow.sh"
}

# run_bounded SECONDS COMMAND [ARGS...]
# Runs COMMAND with its output discarded and gives up after SECONDS, returning
# the command's own exit status or 124 on expiry. macOS ships no `timeout`
# binary, so the bound is a background job plus a poll loop.
run_bounded() {
  local limit="$1"
  shift
  local status=0

  python3 - "$limit" "$@" <<'PY' || status=$?
import os
import signal
import subprocess
import sys
import time

try:
    process = subprocess.Popen(
        sys.argv[2:],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
except FileNotFoundError:
    raise SystemExit(127)
except PermissionError:
    raise SystemExit(126)

try:
    raise SystemExit(process.wait(timeout=float(sys.argv[1])))
except subprocess.TimeoutExpired:
    # Signal the whole group the child leads, falling back to the child alone:
    # on macOS killpg can fail with EPERM for a group this process may signal
    # member by member, and a timeout that then escapes as a traceback exits 1,
    # never reports itself, and leaves the hung child running.
    def stop(sig):
        try:
            os.killpg(process.pid, sig)
        except (ProcessLookupError, PermissionError):
            try:
                os.kill(process.pid, sig)
            except ProcessLookupError:
                pass
    stop(signal.SIGTERM)
    time.sleep(0.2)
    stop(signal.SIGKILL)
    process.wait()
    raise SystemExit(124)
PY
  if [ "$status" -eq 124 ]; then
    warn "Timed out after ${limit}s: $*"
  fi
  return "$status"
}

# Seconds any single `claude`/`gemini` CLI cleanup call may take. Matches the
# per-call timeout the Go uninstaller (the primary uninstall path) uses; the
# override exists so tests can exercise expiry without waiting on it.
CLI_CLEANUP_TIMEOUT="${MACROSCOPE_CLI_CLEANUP_TIMEOUT:-10}"

cleanup_cli_registrations() {
  local claude_config="$(get_claude_config_dir)"
  if { install_state_records_tool claude || has_ownership_marker "$claude_config/plugins/marketplaces/macroscope-local"; } && command -v claude >/dev/null 2>&1; then
    if run_bounded "$CLI_CLEANUP_TIMEOUT" claude mcp remove macroscope-codereview -s user; then
      success "Removed legacy Claude Code MCP registration"
    fi
    # Claude Code maintains internal plugin state beyond the JSON config files
    # on disk — disable + uninstall via CLI to reach that internal state. Each
    # call is bounded so a hung or prompting CLI cannot stall the uninstall.
    local _plugin_removed=0
    for plugin_id in macroscope@macroscope-local macroscope-codereview@macroscope-local; do
      run_bounded "$CLI_CLEANUP_TIMEOUT" claude plugins disable "$plugin_id" || true
      if run_bounded "$CLI_CLEANUP_TIMEOUT" claude plugins uninstall "$plugin_id"; then
        _plugin_removed=1
      fi
    done
    if run_bounded "$CLI_CLEANUP_TIMEOUT" claude plugins marketplace remove macroscope-local; then
      _plugin_removed=1
    fi
    [ "$_plugin_removed" -eq 1 ] && success "Removed plugin from Claude Code CLI"
  fi

  if { [ -n "$(recorded_binary_paths)" ] || install_state_predates_binary_path; } && command -v gemini >/dev/null 2>&1; then
    if run_bounded "$CLI_CLEANUP_TIMEOUT" gemini mcp remove macroscope-codereview; then
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

}

determine_install_dir() {
  INSTALL_DIR="${HOME}/.local/bin"
}

prepare_tmp_dir() {
  TMP_DIR=$(mktemp -d)
  chmod 700 "$TMP_DIR"
  trap 'handle_exit $?' EXIT
}

# The resolved version is interpolated straight into a release URL, so it is
# trimmed of surrounding whitespace and then refused outright if anything is
# left that cannot appear in a release tag.
resolve_version() {
  local requested="${MACROSCOPE_VERSION:-${INSTALL_VERSION:-latest}}"
  requested="${requested#"${requested%%[![:space:]]*}"}"
  requested="${requested%"${requested##*[![:space:]]}"}"
  [ -n "$requested" ] || requested="latest"
  case "$requested" in
    *[[:space:][:cntrl:]]* | */* | *'?'* | *'#'* | *'%'*)
      error "Invalid version: whitespace and URL metacharacters are not part of a release tag."
      exit 2
      ;;
  esac
  INSTALL_VERSION="$requested"
  if [ "$INSTALL_VERSION" != "latest" ]; then
    info "Requested version: ${BOLD}${INSTALL_VERSION}${RESET}"
  fi
}

# release_asset_url ASSET_NAME -> download URL for the resolved release.
release_asset_url() {
  local repo="prassoai/macroscope-local"
  if [ "$INSTALL_VERSION" = "latest" ]; then
    printf 'https://github.com/%s/releases/latest/download/%s' "$repo" "$1"
  else
    printf 'https://github.com/%s/releases/download/%s/%s' "$repo" "$INSTALL_VERSION" "$1"
  fi
}

# release_api_url -> GitHub REST endpoint for the resolved release's metadata.
release_api_url() {
  local repo="prassoai/macroscope-local"
  if [ "$INSTALL_VERSION" = "latest" ]; then
    printf 'https://api.github.com/repos/%s/releases/latest' "$repo"
  else
    printf 'https://api.github.com/repos/%s/releases/tags/%s' "$repo" "$INSTALL_VERSION"
  fi
}

# sha256_of FILE -> lowercase hex SHA-256, portable across sha256sum/shasum.
# Returns 2 when no SHA-256 tool is available.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 2
  fi
}

# ensure_release_metadata fetches the release's JSON from the GitHub REST API
# exactly once. GitHub reports a per-asset SHA-256 in each asset's `digest`
# field, which we verify downloads against — no bespoke manifest needed.
# State is "ok" when the fetch succeeded and "error" for any failure (network,
# TLS, 5xx, rate-limit, disk); a failure is deliberately NOT conflated with a
# release that genuinely reports no digest, so callers can fail closed on it.
ensure_release_metadata() {
  [ -z "$RELEASE_METADATA_STATE" ] || return 0
  local dest="$TMP_DIR/release.json"
  if curl -fsSL --proto '=https' --proto-redir '=https' "${CURL_TIMEOUT_ARGS[@]}" \
      -H 'Accept: application/vnd.github+json' \
      "$(release_api_url)" -o "$dest" 2>/dev/null && release_metadata_is_usable "$dest"; then
    RELEASE_METADATA="$dest"
    RELEASE_METADATA_STATE="ok"
  else
    RELEASE_METADATA_STATE="error"
  fi
}

# A 200 carrying an HTML error page, an empty body or a truncated response is a
# failed fetch, not a release that reports no checksums: conflating the two is
# what turns any interception of the metadata call into an unverified install.
release_metadata_is_usable() {
  python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if isinstance(data, dict) and isinstance(data.get("assets"), list) else 1)
PY
}

# asset_sha256 ASSET_NAME -> lowercase hex SHA-256 GitHub reports for the asset,
# or empty when the release metadata is unavailable or carries no sha256 digest.
asset_sha256() {
  python3 - "$RELEASE_METADATA" "$1" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
for asset in data.get("assets", []):
    if isinstance(asset, dict) and asset.get("name") == sys.argv[2]:
        digest = (asset.get("digest") or "").strip()
        if digest.startswith("sha256:"):
            print(digest[len("sha256:"):].strip().lower())
        elif re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            # GitHub reports `sha256:<hex>`; a release published by another
            # tool can report the same hash bare. A 64-hex string is a SHA-256
            # and nothing else, so it is honoured rather than discarded into
            # the unverified-install path.
            print(digest.lower())
        break
PY
}

# asset_digest_state ASSET_NAME -> missing | mismatch | none | ok | unknown
# The cases a caller must tell apart: the release lists nothing resembling the
# asset (an old release, or a platform it never published — the transitional
# grace), it lists the asset under a name differing only in case (the digest is
# right there and the exact-name lookup would silently skip it), it lists one
# with no digest at all (grace again), it reports a SHA-256, or it reports
# something in a format this installer does not understand.
asset_digest_state() {
  python3 - "$RELEASE_METADATA" "$1" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    print("missing"); raise SystemExit(0)
assets = data.get("assets") if isinstance(data, dict) else None
if not isinstance(assets, list):
    print("missing"); raise SystemExit(0)
wanted = sys.argv[2]
for asset in assets:
    if not isinstance(asset, dict):
        continue
    name = asset.get("name")
    if name != wanted:
        continue
    digest = asset.get("digest")
    digest = digest.strip() if isinstance(digest, str) else ""
    if not digest:
        print("none")
    elif re.fullmatch(r"sha256:[0-9a-fA-F]+", digest) or re.fullmatch(r"[0-9a-fA-F]{64}", digest):
        print("ok")
    else:
        print("unknown")
    break
else:
    spellings = {name.lower() for name in
                 (asset.get("name") for asset in assets if isinstance(asset, dict))
                 if isinstance(name, str)}
    print("mismatch" if wanted.lower() in spellings else "missing")
PY
}

# verify_downloaded_artifact FILE ASSET_NAME LABEL
# Verifies a freshly downloaded release artifact against GitHub's reported
# SHA-256 before install. This guards against transport corruption / MITM of
# the download; it is NOT a trust root against a compromised release or GitHub
# account (an attacker with release-write access controls both the bytes and
# the digest GitHub reports). Defending against that requires an independent
# signature and is intentionally out of scope here.
#
# Failure modes are kept distinct:
#   - metadata fetch failed  -> fail closed always (we cannot verify; not proof
#                               the release omits a checksum)
#   - metadata OK, no digest -> transitional grace (warn), or fail closed under
#                               REQUIRE_CHECKSUM=1
#   - metadata OK, digest set -> verify; any mismatch aborts
verify_downloaded_artifact() {
  local file="$1" name="$2" label="$3"
  ensure_release_metadata
  if [ "$RELEASE_METADATA_STATE" = "error" ]; then
    error "Could not fetch release metadata from GitHub to verify ${label} (network or server error)."
    error "Refusing to install unverified ${label}; please retry."
    return 1
  fi
  local state
  state="$(asset_digest_state "$name")"
  if [ "$state" = "mismatch" ]; then
    error "GitHub's release metadata for '${INSTALL_VERSION}' spells ${name} differently, so its digest cannot be matched to this download."
    error "Refusing to install unverified ${label}."
    return 1
  fi
  if [ "$state" = "unknown" ]; then
    error "GitHub reports a digest for ${name} in a format this installer does not recognise."
    error "Refusing to install unverified ${label}."
    return 1
  fi
  local expected=""
  [ "$state" = "missing" ] || expected="$(asset_sha256 "$name")"
  if [ -z "$expected" ]; then
    if [ "$REQUIRE_CHECKSUM" = "1" ]; then
      error "GitHub reports no SHA-256 for ${name} on release '${INSTALL_VERSION}' and MACROSCOPE_REQUIRE_CHECKSUM=1 is set."
      error "Refusing to install unverified ${label}."
      return 1
    fi
    warn "SECURITY: GitHub reports no SHA-256 for ${name} on release '${INSTALL_VERSION}'."
    warn "SECURITY: installing ${label} WITHOUT integrity verification (transitional grace)."
    warn "SECURITY: set MACROSCOPE_REQUIRE_CHECKSUM=1 to require verification and fail closed."
    return 0
  fi
  local actual
  if ! actual="$(sha256_of "$file")"; then
    error "No SHA-256 tool (sha256sum or shasum) available to verify ${label}."
    return 1
  fi
  actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
  if [ "$expected" != "$actual" ]; then
    error "Integrity check FAILED for ${label} — refusing to install."
    error "  expected: ${expected}"
    error "  actual:   ${actual}"
    return 1
  fi
  success "Verified ${label} against GitHub-reported SHA-256"
}

stage_binary() {
  if [ -n "${MACROSCOPE_LOCAL_BINARY_SOURCE:-}" ]; then
    step "Staging local Macroscope CLI..."
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
    step "Building local Macroscope CLI..."
    if [ ! -d "${MACROSCOPE_LOCAL_BACK_REPO}" ]; then
      error "Local back repo not found: ${MACROSCOPE_LOCAL_BACK_REPO}"
      exit 1
    fi

    (
      cd "${MACROSCOPE_LOCAL_BACK_REPO}"
      go build -buildvcs=false -o "$TMP_DIR/macroscope" ./tools/cmd/macrodaemon
    )
    chmod +x "$TMP_DIR/macroscope"
    success "Built and staged local CLI from ${BOLD}${MACROSCOPE_LOCAL_BACK_REPO}${RESET}"
    return
  fi

  step "Downloading Macroscope CLI..."
  local asset="macroscope-${OS}-${ARCH}"
  local url
  url="$(release_asset_url "$asset")"

  info "Downloading from: ${DIM}${url}${RESET}"

  if ! download_with_progress "$url" "$TMP_DIR/macroscope" "Macroscope CLI"; then
    error "Failed to download macroscope"
    echo ""
    echo "Possible reasons:"
    echo "  Release doesn't exist for ${OS}-${ARCH}"
    echo "  Network connectivity issues"
    echo "  Invalid version specified: ${INSTALL_VERSION}"
    echo ""
    echo "Check available releases at:"
    echo "  https://github.com/prassoai/macroscope-local/releases"
    exit 1
  fi

  verify_downloaded_artifact "$TMP_DIR/macroscope" "$asset" "Macroscope CLI binary" || exit 1

  chmod +x "$TMP_DIR/macroscope"

  success "Downloaded and staged the CLI"
}

# The binary is swapped in with `mv -f`, and `mv -f` onto an existing directory
# moves the staged file INSIDE it and reports success — the install would then
# announce a binary that is really a directory, and record that directory as
# the path uninstall is entitled to delete. Anything at the install path that
# is not (or does not resolve to) a regular file is refused before the apply
# begins, while nothing has been written. A symlink to a regular file is a
# shape the installer has always replaced and still does.
check_binary_target() {
  local target="$INSTALL_DIR/macroscope"
  if [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; then
    error "Cannot install into $INSTALL_DIR: it exists and is not a directory."
    error "Move or remove it and rerun."
    return 1
  fi
  if [ -e "$target" ] && [ ! -f "$target" ]; then
    error "Refusing to install over $target: it is not a regular file."
    error "Move or remove it and rerun."
    return 1
  fi
  return 0
}

apply_binary() {
  step "Installing binary..."
  if [ ! -d "$INSTALL_DIR" ]; then
    track_mkdir "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
  fi
  local target="$INSTALL_DIR/macroscope"
  local previous="$INSTALL_DIR/macroscope.old"
  local next="$INSTALL_DIR/.macroscope.new.$$"
  cp "$TMP_DIR/macroscope" "$next"
  chmod +x "$next"
  # The copy the cleanup paths and `recorded_binary_paths` already treat as
  # install-owned: the binary being replaced, kept beside its successor so a
  # bad release can be backed out by hand. Only a binary that actually changes
  # leaves one, so reinstalling the same release stays a no-op.
  if [ -f "$target" ] && [ ! -L "$target" ] && ! cmp -s "$target" "$TMP_DIR/macroscope"; then
    cp -p "$target" "$next.old" && mv -f "$next.old" "$previous" || warn "Could not keep a copy of the previous binary at $previous"
  fi
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
  local claude_config="$(get_claude_config_dir)"
  if tool_selected claude && ! python3 - \
      "$claude_config/plugins/known_marketplaces.json" \
      "$claude_config/settings.json" \
      "$claude_config/plugins/installed_plugins.json" \
      "$({ install_state_records_tool claude || has_ownership_marker "$claude_config/plugins/marketplaces/macroscope-local/plugins/macroscope"; } && printf 1 || printf 0)" <<'PY'
import json, os, sys

def load(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        try:
            value = json.load(f)
        except json.JSONDecodeError as error:
            # A bare decoder message names a line and column in a file the user
            # is never told the name of.
            raise ValueError(f"{path}: is not valid JSON ({error}); fix or remove this file and rerun")
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object at the top level")
    return value

try:
    known = load(sys.argv[1])
    settings = load(sys.argv[2])
    owned = sys.argv[4] == "1"
    if not owned and "macroscope-local" in known:
        raise ValueError(f"{sys.argv[1]}: macroscope-local is not owned by this installation")
    for field in ("extraKnownMarketplaces", "enabledPlugins"):
        if field in settings and not isinstance(settings[field], dict):
            raise ValueError(f"{sys.argv[2]}: expected {field} to be a JSON object")
    if not owned and ("macroscope-local" in settings.get("extraKnownMarketplaces", {}) or
                      "macroscope@macroscope-local" in settings.get("enabledPlugins", {})):
        raise ValueError(f"{sys.argv[2]}: Macroscope registration keys are not owned by this installation")
    installed = load(sys.argv[3])
    plugins = installed.get("plugins", {})
    if not isinstance(plugins, dict):
        raise ValueError(f"{sys.argv[3]}: expected plugins to be a JSON object")
    entries = plugins.get("macroscope@macroscope-local", [])
    if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
        raise ValueError(f"{sys.argv[3]}: expected the Macroscope plugin entry to be a list of JSON objects")
except (OSError, json.JSONDecodeError, ValueError) as error:
    print(error, file=sys.stderr)
    raise SystemExit(1)
PY
  then
    error "Claude Code configuration is not safe to update; fix the reported file and rerun"
    return 1
  fi
  success "Staged binary and plugin bundle are valid"
}

# The plugin bundle is a handful of markdown files and manifests — under 10 KB
# compressed, a little over 100 KB expanded. These ceilings sit hundreds of
# times above that, so only an archive that is not the plugin bundle at all can
# reach them, and nothing unpacks a decompression bomb into the user's home
# before anyone notices.
BUNDLE_MAX_MEMBERS="${MACROSCOPE_MAX_BUNDLE_MEMBERS:-2000}"
BUNDLE_MAX_BYTES="${MACROSCOPE_MAX_BUNDLE_BYTES:-52428800}"

# Prints why the archive is out of bounds and fails; prints nothing and
# succeeds when it is within them.
bundle_archive_exceeds_bounds() {
  python3 - "$1" "$BUNDLE_MAX_MEMBERS" "$BUNDLE_MAX_BYTES" <<'PY'
import sys, tarfile

archive, max_members, max_bytes = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
members = 0
total = 0
try:
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            members += 1
            total += max(member.size, 0)
            if members > max_members:
                print("holds more than %d members" % max_members)
                raise SystemExit(1)
            if total > max_bytes:
                print("expands to more than %d bytes" % max_bytes)
                raise SystemExit(1)
except tarfile.TarError as error:
    print("is not a readable gzip archive (%s)" % error)
    raise SystemExit(1)
PY
}

fetch_plugin_bundle() {
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
    step "Staging public plugin bundle..."
    local_back_plugin_root="${MACROSCOPE_LOCAL_BACK_REPO}/tools/cmd/macrodaemon/public-plugin"
    if ! is_plugin_bundle_root "$local_back_plugin_root"; then
      error "Back repo is missing the public plugin bundle at ${local_back_plugin_root}"
      exit 1
    fi
    copy_tree "$local_back_plugin_root" "$CHECKOUT_DIR"
    success "Using public plugin bundle from ${BOLD}${MACROSCOPE_LOCAL_BACK_REPO}${RESET}"
  elif [ -n "${MACROSCOPE_PLUGIN_BUNDLE_SOURCE:-}" ]; then
    if [ -d "${MACROSCOPE_PLUGIN_BUNDLE_SOURCE}" ]; then
      step "Staging local plugin bundle..."
      copy_tree "${MACROSCOPE_PLUGIN_BUNDLE_SOURCE}" "$CHECKOUT_DIR"
      success "Using local plugin bundle from ${BOLD}${MACROSCOPE_PLUGIN_BUNDLE_SOURCE}${RESET}"
    else
      step "Cloning plugin bundle..."
      git clone --depth 1 "${MACROSCOPE_PLUGIN_BUNDLE_SOURCE}" "$CHECKOUT_DIR" >/dev/null 2>&1
      success "Fetched plugin bundle from ${BOLD}${MACROSCOPE_PLUGIN_BUNDLE_SOURCE}${RESET}"
    fi
  else
    step "Downloading plugin bundle..."
    local bundle_asset="macroscope-plugin-bundle.tar.gz"
    bundle_url="$(release_asset_url "$bundle_asset")"

    info "Downloading plugin bundle from: ${DIM}${bundle_url}${RESET}"

    mkdir -p "$CHECKOUT_DIR"
    if download_with_progress "$bundle_url" "$bundle_archive" "Plugin bundle"; then
      verify_downloaded_artifact "$bundle_archive" "$bundle_asset" "Macroscope plugin bundle" || exit 1
      local bundle_refusal=""
      if ! bundle_refusal="$(bundle_archive_exceeds_bounds "$bundle_archive")"; then
        error "Refusing to extract the plugin bundle: it $bundle_refusal."
        exit 1
      fi
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

  if ! PLUGIN_VERSION="$(python3 - "$CHECKOUT_DIR/plugins/macroscope/.claude-plugin/plugin.json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    version = json.load(f).get("version")
if not isinstance(version, str) or not re.fullmatch(
    r"[0-9]+(?:\.[0-9]+){2}(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?",
    version,
):
    raise SystemExit(1)
print(version)
PY
)"; then
    error "Fetched plugin bundle has an invalid plugin version."
    return 1
  fi
}

# `mkdir -p`, recording every directory level it actually brings into
# existence. A rollback restores the files it snapshotted, but an apply that
# was interrupted part way also leaves behind the host directory scaffolding it
# created to hold them — empty `~/.agents/plugins`, `~/.local/bin`, a Codex
# plugin cache root — on a machine that never had Macroscope. The record is what
# lets rollback take those back out again.
track_mkdir() {
  local dir=""
  local probe=""
  local pending=""
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    probe="$dir"
    while [ -n "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ] && [ ! -d "$probe" ]; do
      pending="${pending}${probe}"$'\n'
      probe="$(dirname "$probe")"
    done
  done
  if [ -n "$pending" ] && [ -n "$CREATED_DIRS_LOG" ]; then
    printf '%s' "$pending" >> "$CREATED_DIRS_LOG"
  fi
  mkdir -p "$@"
}

# Remove the directories this run created, deepest first, and only while they
# are still empty: a directory that now holds something the user owns is no
# longer ours to take away.
remove_created_directories() {
  [ -n "$CREATED_DIRS_LOG" ] && [ -s "$CREATED_DIRS_LOG" ] || return 0
  local dir=""
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    rmdir "$dir" 2>/dev/null || true
  done <<< "$(awk '{ print length($0) "\t" $0 }' "$CREATED_DIRS_LOG" | sort -rn -k1,1 | cut -f2-)"
}

copy_tree() {
  local src="$1"
  local dst="$2"

  rm -rf "$dst"
  track_mkdir "$(dirname "$dst")"
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

# OpenCode commands resolve skills through the native registry. The installed
# skill and command names use the flat namespace macroscope- prefix.
install_opencode_command() {
  local src="$1"
  local dst="$2"

  sed -e 's|\.\./skills/codereview/|../skills/macroscope-codereview/|g' \
      -e 's|\.\./skills/autoloop/|../skills/macroscope-autoloop/|g' \
      -e 's|`/codereview|`/macroscope-codereview|g' \
      -e 's|`/autoloop|`/macroscope-autoloop|g' \
      -e 's|name: "codereview"|name: "macroscope-codereview"|g' \
      -e 's|name: "autoloop"|name: "macroscope-autoloop"|g' \
      "$src" > "$dst"
}

# A skill destination is the installer's to write only when it is absent, or a
# real directory (not a symlink to one) carrying the ownership marker. A
# regular file there is a user's notes, and copy_tree would `rm -rf` it.
opencode_skill_destination_is_ours() {
  local dst="$1"
  { [ -e "$dst" ] || [ -L "$dst" ]; } || return 0
  { [ -d "$dst" ] && [ ! -L "$dst" ] && has_ownership_marker "$dst"; }
}

# Copy one bundled skill into OpenCode's flat skill namespace under its
# prefixed name. A directory already there that does not carry our ownership
# marker belongs to the user: warn and skip rather than clobber it.
install_opencode_skill() {
  local src="$1"
  local dst="$2"
  local skill_name=""

  skill_name="$(basename "$dst")"
  if ! opencode_skill_destination_is_ours "$dst"; then
    warn "Left $dst in place (no Macroscope ownership marker); skipped installing the $skill_name skill"
    return 1
  fi

  copy_tree "$src" "$dst"
  rewrite_opencode_skill_copy "$dst/SKILL.md" "$skill_name"
  write_ownership_marker "$dst"
}

# OpenCode resolves a skill by its directory name and rejects a SKILL.md whose
# frontmatter `name` disagrees with it, so the prefixed copy is rewritten to
# match. Slash-command references are prefixed for the same reason the
# commands are.
rewrite_opencode_skill_copy() {
  local skill_file="$1"
  local skill_name="$2"

  [ -f "$skill_file" ] || return 1
  python3 - "$skill_file" "$skill_name" <<'PY'
import sys

path, name = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")

if lines and lines[0] == "---":
    for index in range(1, len(lines)):
        if lines[index] == "---":
            break
        if lines[index].startswith("name:"):
            lines[index] = "name: " + name
            break

text = "\n".join(lines)
text = text.replace("`/codereview", "`/macroscope-codereview")
text = text.replace("`/autoloop", "`/macroscope-autoloop")

with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
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

  track_mkdir "$config_dir"
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

  local marker="# Added by Macroscope installer"
  local line=""
  line="$(shell_config_line)"
  track_mkdir "$(dirname "$PATH_TARGET")"
  touch "$PATH_TARGET" 2>/dev/null || true
  if ! grep -Fq "$line" "$PATH_TARGET" 2>/dev/null; then
    # An unwritable rc file is a failure, not a silent skip: reporting "Updated"
    # over a file that never received the line sends the user away believing
    # their PATH is configured.
    # One simple command, not a group: bash reports a failed redirection on a
    # compound command but still hands back its zero status, which is how an
    # unwritable rc file came to be announced as updated.
    if ! printf '\n%s\n%s\n' "$marker" "$line" >> "$PATH_TARGET" 2>/dev/null ||
        ! grep -Fq "$line" "$PATH_TARGET" 2>/dev/null; then
      error "Could not add $HOME/.local/bin to PATH in $PATH_TARGET (the file is not writable)."
      error "Add this line by hand, or rerun with --no-path: $line"
      return 1
    fi
    success "Updated $PATH_TARGET"
  else
    info "PATH already configured in $PATH_TARGET"
  fi
  export PATH="$HOME/.local/bin:$PATH"
}

install_codex_cli_shim() {
  step "Checking Codex CLI..."

  local current_codex=""
  local shim_path="$HOME/.local/bin/codex"

  CODEX_SHIM_PATH="$shim_path"
  current_codex="$(command -v codex || true)"

  if [ -n "$current_codex" ] && [ "$current_codex" = "$CODEX_BUNDLED_BINARY" ] && codex_supports_plugins "$current_codex"; then
    success "Codex CLI already uses the bundled Codex desktop binary: ${BOLD}${current_codex}${RESET}"
    return
  fi

  if [ ! -x "$CODEX_BUNDLED_BINARY" ] || ! codex_supports_plugins "$CODEX_BUNDLED_BINARY"; then
    if [ -n "$current_codex" ]; then
      CODEX_PLUGIN_HOST_WARNING="Codex CLI at ${current_codex} does not support local plugins. Install or update the Codex desktop app to use \$macroscope:codereview from the CLI."
      warn "$CODEX_PLUGIN_HOST_WARNING"
    else
      CODEX_PLUGIN_HOST_WARNING="Codex CLI is not installed. Install the Codex desktop app to use \$macroscope:codereview from the CLI."
      warn "$CODEX_PLUGIN_HOST_WARNING"
    fi
    return
  fi

  if [ -e "$shim_path" ] || [ -L "$shim_path" ]; then
    if [ -L "$shim_path" ] || [ ! -f "$shim_path" ] || ! is_managed_codex_shim "$shim_path"; then
      CODEX_PLUGIN_HOST_WARNING="Existing ${shim_path} was left untouched, so the current Codex CLI may still be too old for plugins."
      warn "$CODEX_PLUGIN_HOST_WARNING"
      return
    fi
  fi

  if ! python3 - "$shim_path" "$CODEX_BUNDLED_BINARY" <<'PY'
import os
import shlex
import sys
import tempfile

path, bundled = sys.argv[1:3]
fd, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-codex-shim-")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("#!/bin/bash\nset -euo pipefail\n# Macroscope-managed Codex shim\nexec %s \"$@\"\n" % shlex.quote(bundled))
    os.chmod(temporary, 0o755)
    os.replace(temporary, path)
except Exception:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    raise
PY
  then
    error "Could not install the Codex CLI shim at $shim_path"
    return 1
  fi
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

  if { [ -e "$plugin_dst" ] || [ -L "$plugin_dst" ]; } && \
      { [ ! -d "$plugin_dst" ] || [ -L "$plugin_dst" ] || { ! has_ownership_marker "$plugin_dst" && ! install_state_records_tool codex; }; }; then
    error "Refusing to overwrite unowned Codex plugin at $plugin_dst"
    return 1
  fi
  track_mkdir "$HOME/plugins" "$HOME/.agents/plugins" "$codex_cache_root"
  copy_tree "$plugin_src" "$plugin_dst"

  if ! marketplace_name="$({
    printf '%s\n' "$PY_PLUGIN_OWNERSHIP"
    cat <<'PY'
import json
import os
import sys
import tempfile

path = sys.argv[1]
if os.path.islink(path):
    path = os.path.realpath(path)

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
else:
    data = {
        "name": "local-user-plugins",
        "interface": {"displayName": "Local Plugins"},
        "plugins": [],
    }

# A marketplace file whose root is not an object is not something this
# installer can merge an entry into, and overwriting it would destroy whatever
# the user keeps there. Report it instead of guessing.
if not isinstance(data, dict):
    raise SystemExit(4)

data.setdefault("name", "local-user-plugins")
# The name becomes a Codex cache directory component below. Refuse to write
# anything at all when it cannot be one.
if not is_safe_marketplace_name(data.get("name")):
    raise SystemExit(3)
data.setdefault("interface", {})
data["interface"].setdefault("displayName", "Local Plugins")
# Replace only the entry this installer owns. A `macroscope` entry another
# marketplace registered from its own source stays registered.
plugins = data.get("plugins", [])
if not isinstance(plugins, list):
    raise SystemExit(4)
plugins = [p for p in plugins if not is_owned_marketplace_entry(p)]
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

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-marketplace-")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, os.stat(path).st_mode if os.path.exists(path) else 0o644)
os.replace(tmp, path)

print(data["name"])
PY
  } | python3 - "$marketplace_dst")"; then
    error "Cannot use the Codex marketplace at $marketplace_dst"
    error "Its \"name\" must be a single directory name ([A-Za-z0-9._-]) and its root a JSON object."
    error "Fix or remove that file and rerun; the Codex plugin cache was left untouched."
    return 1
  fi

  # Second gate, in the shell that builds the path: the name python printed is
  # the one interpolated into an `rm -rf` target, so it is checked where it is
  # used and not only where it was read.
  if ! is_safe_marketplace_name "$marketplace_name"; then
    error "Refusing to build a Codex plugin cache path from marketplace name: $marketplace_name"
    return 1
  fi

  codex_cache_dst="$codex_cache_root/$marketplace_name/macroscope/$CODEX_LOCAL_PLUGIN_VERSION"
  plugin_key="macroscope@$marketplace_name"
  if [ -d "$codex_cache_dst" ] && ! has_ownership_marker "$codex_cache_dst" && ! install_state_records_tool codex; then
    error "Refusing to overwrite unowned Codex plugin cache at $codex_cache_dst"
    return 1
  fi
  copy_tree "$plugin_src" "$codex_cache_dst"
  apply_codex_overlay "$plugin_src" "$plugin_dst"
  apply_codex_overlay "$plugin_src" "$codex_cache_dst"
  write_ownership_marker "$plugin_dst"
  write_ownership_marker "$codex_cache_dst"

  if ! python3 - "$codex_config" "$plugin_key" <<'PY'
import os
import re
import sys
import tempfile

# Stock macOS still ships Python 3.9, which has no tomllib. Where it exists the
# edit is proven by parsing the result back; where it does not, the structural
# checks below are all the assurance available, so the edit stays conservative
# either way.
try:
    import tomllib
except ImportError:
    tomllib = None

path, plugin_key = sys.argv[1:3]
if os.path.islink(path):
    path = os.path.realpath(path)

original = ""
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        original = f.read()

# A byte-order mark is not part of a TOML document; every parser rejects one.
# Dropping it is the only way an edit can be written back and read again.
text = original[1:] if original.startswith("﻿") else original


def refuse(reason):
    sys.stderr.write("%s: %s\n" % (path, reason))
    raise SystemExit(3)


def parse(payload):
    if tomllib is None:
        return {}
    try:
        return tomllib.loads(payload)
    except tomllib.TOMLDecodeError:
        return None


if text.strip() and parse(text) is None:
    refuse("not valid TOML; fix or remove this file and rerun")

SEGMENT = r'"[^"\n]*"|\'[^\'\n]*\'|[A-Za-z0-9_-]+'
KEY_PATH = r'(?:%s)(?:[ \t]*\.[ \t]*(?:%s))*' % (SEGMENT, SEGMENT)
TABLE_HEADER = re.compile(r'^[ \t]*\[[ \t]*(%s)[ \t]*\][ \t\r]*(?:#[^\n]*)?$' % KEY_PATH)
ARRAY_HEADER = re.compile(r'^[ \t]*\[\[')
ASSIGNMENT = re.compile(r'^([ \t]*)(%s)[ \t]*=' % KEY_PATH)
BARE_SEGMENT = re.compile(r'^[A-Za-z0-9_-]+$')
# A path no table header can produce, so scanning inside an array of tables
# never mistakes one of its keys for a key of the table being edited.
OPAQUE_TABLE = ("\0",)


def split_key_path(raw):
    parts = []
    for segment in re.findall(SEGMENT, raw):
        if segment[:1] in ('"', "'"):
            parts.append(segment[1:-1])
        else:
            parts.append(segment)
    return tuple(parts)


def render_key(name):
    return name if BARE_SEGMENT.match(name) else '"%s"' % name


def render_path(names):
    return ".".join(render_key(name) for name in names)


def lookup(document, names):
    value = document
    for name in names:
        if not isinstance(value, dict) or name not in value:
            return None
        value = value[name]
    return value


def set_value(payload, table, key, literal):
    """Give table.key the literal value, editing as little as possible.

    An existing assignment is rewritten in place wherever it lives — inside the
    table's own header, or as a dotted key one level up — so a document that
    already declares the key never gains a second declaration of it.
    """
    table = tuple(table)
    wanted = table + (key,)
    lines = payload.split("\n")
    current = ()
    header_index = None

    for index, line in enumerate(lines):
        if ARRAY_HEADER.match(line):
            current = OPAQUE_TABLE
            continue
        header = TABLE_HEADER.match(line)
        if header:
            current = split_key_path(header.group(1))
            if current == table and header_index is None:
                header_index = index
            continue
        assignment = ASSIGNMENT.match(line)
        if assignment is None or current == OPAQUE_TABLE:
            continue
        if current + split_key_path(assignment.group(2)) == wanted:
            replacement = "%s%s = %s" % (assignment.group(1), assignment.group(2), literal)
            lines[index] = replacement + "\r" if line.endswith("\r") else replacement
            return "\n".join(lines)

    if header_index is not None:
        lines.insert(header_index + 1, "%s = %s" % (render_key(key), literal))
        return "\n".join(lines)

    tail = payload
    if tail.strip():
        tail = tail.rstrip("\n") + "\n\n"
    return "%s[%s]\n%s = %s\n" % (tail, render_path(table), render_key(key), literal)


edits = ((("features",), "plugins", "true"), (("plugins", plugin_key), "enabled", "true"))
for table, key, literal in edits:
    text = set_value(text, table, key, literal)

# Nothing is written that cannot be read back: a document this edit could not
# express is left exactly as the user had it, with the path named.
document = parse(text)
if document is None:
    refuse("this installer's edit would not parse as TOML; enable the Macroscope plugin by hand and rerun")
for table, key, literal in edits:
    if tomllib is not None and lookup(document, table + (key,)) is not True:
        refuse("could not set %s = %s; enable the Macroscope plugin by hand and rerun" % (render_path(table + (key,)), literal))
    # Without a parser, the one thing that can still be checked is that the
    # edit did not leave a second declaration of the table behind.
    if tomllib is None and sum(
        1 for line in text.split("\n")
        if TABLE_HEADER.match(line) and split_key_path(TABLE_HEADER.match(line).group(1)) == table
    ) > 1:
        refuse("holds more than one [%s] table; enable the Macroscope plugin by hand and rerun" % render_path(table))

if text == original:
    raise SystemExit(0)

os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-codex-")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(text)
os.chmod(tmp, os.stat(path).st_mode if os.path.exists(path) else 0o644)
os.replace(tmp, path)
PY
  then
    error "Could not enable the Macroscope plugin in $codex_config"
    error "Fix the reported problem in that file and rerun; it was left untouched."
    return 1
  fi

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
  local cache_root="$claude_config/plugins/cache/macroscope-local/macroscope"
  local now=""

  if { [ -e "$marketplace_root" ] || [ -L "$marketplace_root" ]; } && \
      { [ ! -d "$marketplace_root" ] || [ -L "$marketplace_root" ] || { ! has_ownership_marker "$marketplace_root/plugins/macroscope" && ! install_state_records_tool claude; }; }; then
    error "Refusing to overwrite unowned Claude marketplace at $marketplace_root"
    return 1
  fi
  if { [ -e "$cache_root" ] || [ -L "$cache_root" ]; } && \
      { [ ! -d "$cache_root" ] || [ -L "$cache_root" ] || { ! find "$cache_root" -type f -name "$OWNERSHIP_MARKER_FILE" -print -quit 2>/dev/null | grep -q . && ! install_state_records_tool claude; }; }; then
    error "Refusing to overwrite unowned Claude plugin cache at $cache_root"
    return 1
  fi

  track_mkdir "$claude_config/plugins/marketplaces" "$claude_config/plugins/cache/macroscope-local"
  rm -rf "$cache_root"
  track_mkdir "$cache_root"

  rm -rf "$marketplace_root"
  track_mkdir "$marketplace_root"
  copy_tree "$marketplace_src" "$marketplace_root/.claude-plugin"
  track_mkdir "$marketplace_root/plugins"
  copy_claude_plugin_tree "$plugin_src" "$marketplace_root/plugins/macroscope"
  copy_claude_plugin_tree "$plugin_src" "$cache_dst"
  apply_claude_overlay "$plugin_src" "$marketplace_root/plugins/macroscope"
  apply_claude_overlay "$plugin_src" "$cache_dst"
  write_ownership_marker "$marketplace_root/plugins/macroscope"
  write_ownership_marker "$cache_dst"

  now="$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"))
PY
)"

  python3 - "$known_marketplaces" "$marketplace_root" "$now" <<'PY'
import json
import os
import sys
import tempfile

path, marketplace_root, now = sys.argv[1:4]
if os.path.islink(path):
    path = os.path.realpath(path)

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
else:
    data = {}

# Every one of these host files belongs to the user; a root that is not an object
# is not something this installer can merge into, and replacing it wholesale
# would destroy their data. Fail with the path instead of a traceback.
if not isinstance(data, dict):
    raise SystemExit("%s: expected a JSON object at the top level; fix or remove this file and rerun" % path)

data["macroscope-local"] = {
    "source": {"source": "directory", "path": marketplace_root},
    "installLocation": marketplace_root,
    "lastUpdated": now,
}

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-claude-")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, os.stat(path).st_mode if os.path.exists(path) else 0o644)
os.replace(tmp, path)
PY

  python3 - "$claude_settings" "$marketplace_root" <<'PY'
import json
import os
import sys
import tempfile

path, marketplace_root = sys.argv[1:3]
if os.path.islink(path):
    path = os.path.realpath(path)

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
else:
    data = {}

if not isinstance(data, dict):
    raise SystemExit("%s: expected a JSON object at the top level; fix or remove this file and rerun" % path)

extra = data.setdefault("extraKnownMarketplaces", {})
extra["macroscope-local"] = {
    "source": {"source": "directory", "path": marketplace_root}
}

enabled = data.setdefault("enabledPlugins", {})
enabled["macroscope@macroscope-local"] = True

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-claude-")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, os.stat(path).st_mode if os.path.exists(path) else 0o644)
os.replace(tmp, path)
PY

  python3 - "$installed_plugins" "$cache_dst" "$PLUGIN_VERSION" "$now" <<'PY'
import json
import os
import sys
import tempfile

path, install_path, version, now = sys.argv[1:5]
if os.path.islink(path):
    path = os.path.realpath(path)
key = "macroscope@macroscope-local"

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
else:
    data = {"version": 2, "plugins": {}}

if not isinstance(data, dict):
    raise SystemExit("%s: expected a JSON object at the top level; fix or remove this file and rerun" % path)

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

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-claude-")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, os.stat(path).st_mode if os.path.exists(path) else 0o644)
os.replace(tmp, path)
PY

  success "Installed Claude Code plugin to ${BOLD}${cache_dst}${RESET}"
}

clean_tool_state() {
  local tool="$1"
  local remove_plugin="$2"
  local codex_home="$(get_codex_home)"
  local claude_config="$(get_claude_config_dir)"
  {
    printf '%s\n' "$PY_PLUGIN_OWNERSHIP"
    cat <<'PY'
import json, os, re, sys, tempfile
tool, remove_plugin, home, codex_home, claude_config = sys.argv[1:6]
remove_plugin = remove_plugin == "1"

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
        if changed: save(path, data, mode)

elif tool == "codex" and remove_plugin:
    marketplace = os.path.join(home, ".agents/plugins/marketplace.json")
    data, mode = load(marketplace)
    names = {"local-user-plugins"}
    if isinstance(data, dict):
        names.add(str(data.get("name", "local-user-plugins")))
        plugins = data.get("plugins")
        if isinstance(plugins, list):
            filtered = [p for p in plugins if not is_owned_marketplace_entry(p)]
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

PY
  } | python3 - "$tool" "$remove_plugin" "$HOME" "$codex_home" "$claude_config"
}

clean_legacy_mcp_state() {
  [ "$INSTALL_MODE" = "update" ] || return 0
  step "Cleaning legacy MCP artifacts..."
  local legacy_mcp="$HOME/.local/bin/macroscope-mcp"
  local recorded="$(recorded_binary_paths)"
  if { printf '%s\n' "$recorded" | grep -qxF -- "$legacy_mcp" || install_state_predates_binary_path; } && command -v pgrep >/dev/null 2>&1; then
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
  if printf '%s\n' "$recorded" | grep -qxF -- "$legacy_mcp" || install_state_predates_binary_path; then
    rm -f "$legacy_mcp"
  fi
  local codex_home="$(get_codex_home)"
  {
    printf '%s\n' "$PY_MCP_OWNERSHIP"
    cat <<'PY'
import json, os, re, sys, tempfile
owned_mcp_paths = owned_mcp_binary_paths(sys.argv[4], sys.argv[5], sys.argv[6])
for path in sys.argv[1:3]:
    if not os.path.exists(path): continue
    if os.path.islink(path): path = os.path.realpath(path)
    try:
        with open(path, encoding="utf-8") as f: data = json.load(f)
    except Exception: continue
    # A user config whose root is a list or a scalar holds no mcpServers map to
    # clean. Skipping it leaves the file byte-identical; calling .get() on it
    # would raise and abort the whole update into rollback.
    if not isinstance(data, dict): continue
    mode = os.stat(path).st_mode; changed = False
    if drop_owned_mcp_server(data.get("mcpServers"), owned_mcp_paths, path): changed = True
    if drop_owned_mcp_servers_in_projects(data.get("projects"), owned_mcp_paths, path): changed = True
    if changed:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-mcp-")
        with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(data, f, indent=2); f.write("\n")
        os.chmod(tmp, mode); os.replace(tmp, path)
path = sys.argv[3]
if os.path.exists(path):
    if os.path.islink(path): path = os.path.realpath(path)
    mode = os.stat(path).st_mode
    with open(path, encoding="utf-8") as f: text = f.read()
    cleaned, _ = drop_owned_codex_mcp_server(text, owned_mcp_paths, path)
    if cleaned != text:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".macroscope-mcp-")
        with os.fdopen(fd, "w", encoding="utf-8") as f: f.write(cleaned)
        os.chmod(tmp, mode); os.replace(tmp, path)
PY
  } | python3 - \
    "$(get_claude_state_file)" \
    "$HOME/.cursor/mcp.json" \
    "$codex_home/config.toml" \
    "$HOME" \
    "${INSTALL_DIR:-$HOME/.local/bin}" \
    "${STATE_FILE:-$(state_file_path)}"
  success "Legacy MCP artifacts cleaned"
}

remove_tool_integration() {
  local tool="$1"
  step "Removing deselected $tool integration..."
  case "$tool" in
    claude)
      remove_owned_plugin_dir "$(get_claude_config_dir)/plugins/marketplaces/macroscope-local" claude || true
      remove_owned_plugin_dir "$(get_claude_config_dir)/plugins/cache/macroscope-local" claude || true
      ;;
    codex)
      remove_owned_plugin_dir "$HOME/plugins/macroscope" codex || true
      local cache=""
      for cache in "$(get_codex_home)/plugins/cache"/*/macroscope; do
        [ -d "$cache" ] || continue
        remove_owned_codex_cache_versions "$cache" "$(install_state_records_tool codex && printf 1 || printf 0)"
      done
      if is_managed_codex_shim "$HOME/.local/bin/codex"; then rm -f "$HOME/.local/bin/codex"; fi
      ;;
    cursor) remove_owned_plugin_dir "$HOME/.cursor/plugins/local/macroscope" cursor || true ;;
    opencode)
      if install_state_records_tool opencode; then
        rm -f "$(get_opencode_config_dir)/plugins/macroscope.js" "$(get_opencode_config_dir)/commands/macroscope-codereview.md" "$(get_opencode_config_dir)/commands/macroscope-autoloop.md"
      fi
      remove_marked_skill_dir "$(get_opencode_config_dir)/skills/macroscope-codereview" || true
      remove_marked_skill_dir "$(get_opencode_config_dir)/skills/macroscope-autoloop" || true
      migrate_legacy_opencode_skills "$(get_opencode_config_dir)/skills"
      ;;
  esac
  clean_tool_state "$tool" 1
  success "Removed Macroscope-owned $tool integration state"
}

write_install_state() {
  local path_file="$STATE_PATH_FILE"
  [ "$PATH_ACTION" = "modify" ] && path_file="$PATH_TARGET"
  python3 - "$STATE_FILE" "$SELECTED_TOOLS" "$path_file" "$PATH_POLICY" "$INSTALLED_VERSION" "$INSTALLED_BINARY" <<'PY'
import json, os, sys, tempfile
path, tools_csv, path_file, path_policy, version, binary_path = sys.argv[1:7]
selected = [x for x in tools_csv.split(",") if x]
# binaryPath is the ownership record uninstall relies on: it is the only proof
# that a macroscope binary outside the managed directory is ours to delete.
data = {"schemaVersion": 3, "version": version, "tools": selected,
        "pathFile": path_file or None, "pathPolicy": path_policy,
        "binaryPath": binary_path or None}

# The release that inserted host permission rules recorded which ones it had
# inserted, under schemaVersion 1. This installer inserts none and so has
# nothing of its own to record — but dropping that record on the first update
# would strand those rules forever: with nothing naming them, uninstall can no
# longer tell an inserted rule from one the user wrote, and must leave every
# one of them behind. So the record is carried across every rewrite.
try:
    with open(path, encoding="utf-8") as f:
        previous = json.load(f)
except Exception:
    previous = None
if isinstance(previous, dict) and previous.get("schemaVersion") == 1:
    carried = previous.get("permissionOwnership")
    if isinstance(carried, dict) and any(carried.values()):
        data["permissionOwnership"] = carried

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
    "$HOME/.local/bin/macroscope.old" \
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
    "$opencode_config/skills/macroscope-codereview" \
    "$opencode_config/skills/macroscope-autoloop" \
    "$opencode_config/skills/codereview" \
    "$opencode_config/skills/autoloop" \
    "$opencode_config/opencode.json" \
    "$HOME/.macroscope/config.yaml" \
    "$STATE_FILE"
  # The shell configuration file, but only as a file. Rollback restores every
  # target by `rm -rf` plus a copy, so emitting a directory here would delete a
  # whole tree — `--shell-config "$HOME"` would put $HOME on that list. A path
  # we would create, or a regular file we would append a PATH line to, is the
  # only shape this entry can safely take.
  if [ -n "$PATH_TARGET" ] && { [ ! -e "$PATH_TARGET" ] || [ -f "$PATH_TARGET" ]; }; then
    printf '%s\0' "$PATH_TARGET"
  fi
}

snapshot_for_rollback() {
  local backup_root="$TMP_DIR/rollback"
  ROLLBACK_LOG="$TMP_DIR/rollback.log"
  CREATED_DIRS_LOG="$TMP_DIR/created-dirs.log"
  mkdir -p "$backup_root"
  : > "$ROLLBACK_LOG"
  : > "$CREATED_DIRS_LOG"
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

# The shell configuration file is the one rollback target the installer appends
# to rather than owns, and it is the one a user is most likely to have open in
# an editor while the install runs. Restoring the whole snapshot over it would
# silently discard whatever they saved in the meantime, so its rollback removes
# only the block this installer would have added and leaves everything else as
# the user last wrote it.
rollback_shell_config() {
  local path="$1"
  local backup="$2"
  [ -f "$path" ] && [ -f "$backup" ] || return 1
  cmp -s "$path" "$backup" && return 0
  python3 - "$path" "$(shell_config_line)" <<'PY'
import sys

path, line = sys.argv[1:3]
marker = "# Added by Macroscope installer"
with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")
for index in range(len(lines) - 1):
    if lines[index] == marker and lines[index + 1] == line:
        start = index - 1 if index and lines[index - 1] == "" else index
        del lines[start:index + 2]
        break
else:
    raise SystemExit(0)
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
PY
  if ! cmp -s "$path" "$backup"; then
    warn "Kept your changes to $path; only the Macroscope PATH line was removed."
  fi
  return 0
}

rollback_install() {
  [ -f "$ROLLBACK_LOG" ] || return 0
  warn "Installation failed; restoring the previous install-owned state"
  local status="" path="" backup=""
  while IFS= read -r -d '' status &&
        IFS= read -r -d '' path &&
        IFS= read -r -d '' backup; do
    [ -n "$path" ] || continue
    if [ -n "$PATH_TARGET" ] && [ "$path" = "$PATH_TARGET" ] && [ "$status" = "present" ] &&
        rollback_shell_config "$path" "$backup"; then
      continue
    fi
    rm -rf "$path"
    if [ "$status" = "present" ]; then
      mkdir -p "$(dirname "$path")"
      cp -a "$backup" "$path"
    fi
  done < "$ROLLBACK_LOG"
  remove_created_directories
}

# SIGINT and SIGTERM are handled explicitly. An untrapped signal tears the
# shell down without giving the EXIT trap a non-zero `$?` to react to, which
# would let a Ctrl-C or a `kill` delivered mid-apply skip rollback entirely and
# leave the new binary beside the old configuration. The handler records the
# signal and exits with the conventional 128+N status so handle_exit takes the
# same rollback path a mid-apply error takes.
handle_signal() {
  local name="$1"
  local number="$2"
  INTERRUPT_SIGNAL="$name"
  trap - INT TERM
  exit $((128 + number))
}

install_signal_traps() {
  trap 'handle_signal INT 2' INT
  trap 'handle_signal TERM 15' TERM
}

handle_exit() {
  local status="$1"
  if [ -n "$SAVED_TTY_STATE" ]; then
    printf '\033[?25h' > /dev/tty 2>/dev/null || true
    stty "$SAVED_TTY_STATE" < /dev/tty 2>/dev/null || true
    SAVED_TTY_STATE=""
  fi
  if [ -n "$INTERRUPT_SIGNAL" ]; then
    printf '\n'
    warn "Interrupted by SIG${INTERRUPT_SIGNAL}."
  fi
  if { [ "$status" -ne 0 ] || [ -n "$INTERRUPT_SIGNAL" ]; } && [ "$APPLY_STARTED" -eq 1 ] && [ "$APPLY_COMPLETE" -eq 0 ]; then
    rollback_install || true
  fi
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}

install_cursor_plugin() {
  step "Installing Cursor plugin..."

  local plugin_src="$CHECKOUT_DIR/plugins/macroscope"
  local cursor_dst="$HOME/.cursor/plugins/local/macroscope"

  if { [ -e "$cursor_dst" ] || [ -L "$cursor_dst" ]; } && \
      { [ ! -d "$cursor_dst" ] || [ -L "$cursor_dst" ] || { ! has_ownership_marker "$cursor_dst" && ! install_state_records_tool cursor; }; }; then
    error "Refusing to overwrite unowned Cursor plugin at $cursor_dst"
    return 1
  fi

  if [ ! -f "$plugin_src/.cursor-plugin/plugin.json" ]; then
    warn "Cursor manifest not found in the plugin bundle; skipping Cursor installation."
    return
  fi

  track_mkdir "$HOME/.cursor/plugins/local"
  copy_tree "$plugin_src" "$cursor_dst"
  strip_host_overlays "$cursor_dst"
  write_ownership_marker "$cursor_dst"

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
  local refusal=""

  if [ ! -d "$commands_src" ] || [ ! -d "$skills_src" ] || [ ! -f "$plugin_file" ]; then
    warn "OpenCode plugin, command, or skill files were not found in the plugin bundle; skipping OpenCode installation."
    return
  fi

  # Every destination is checked before anything is written. A command file
  # must never end up pointing at a skill directory the installer then refuses
  # to replace, so an unowned destination withdraws the whole OpenCode
  # integration rather than leaving half of it on disk — and, because the other
  # hosts are unaffected by it, it withdraws only that one. The run is reported
  # as failed at the end.
  for skill_name in codereview autoloop; do
    if ! opencode_skill_destination_is_ours "$opencode_skills/macroscope-$skill_name"; then
      warn "Left $opencode_skills/macroscope-$skill_name in place (no Macroscope ownership marker); skipped installing the macroscope-$skill_name skill"
      refusal=1
    fi
  done
  for path in "$opencode_plugins/macroscope.js" "$opencode_commands/macroscope-codereview.md" "$opencode_commands/macroscope-autoloop.md"; do
    if { [ -e "$path" ] || [ -L "$path" ]; } && { [ -L "$path" ] || ! install_state_records_tool opencode; }; then
      warn "Left $path in place (not recorded as installed by Macroscope)"
      refusal=1
    fi
  done
  if [ -n "$refusal" ]; then
    migrate_legacy_opencode_skills "$opencode_skills" 1
    error "Refusing to overwrite the OpenCode files named above."
    warn "Installed no OpenCode integration; every other selected integration was installed."
    HOST_INSTALL_FAILURES="${HOST_INSTALL_FAILURES:+$HOST_INSTALL_FAILURES, }opencode"
    SELECTED_TOOLS="$(printf '%s' "$SELECTED_TOOLS" | tr ',' '\n' | sed '/^opencode$/d' | paste -sd, -)"
    return 0
  fi

  track_mkdir "$opencode_commands" "$opencode_skills" "$opencode_plugins"

  cp "$plugin_file" "$opencode_plugins/macroscope.js"

  # OpenCode uses flat, user-wide namespaces for both skills and commands, so
  # everything we drop into them is prefixed: `codereview` and `autoloop` are
  # names a user's own skill can legitimately own, and the other hosts
  # namespace skills per plugin so the bundle ships them unprefixed. The
  # OpenCode copy is therefore rewritten — OpenCode requires a skill's
  # frontmatter `name` to equal its directory name — and the command files are
  # repointed at the prefixed skill paths they open.
  for command_name in macroscope-codereview macroscope-autoloop; do
    [ -f "$commands_src/$command_name.md" ] || continue
    install_opencode_command "$commands_src/$command_name.md" "$opencode_commands/$command_name.md"
  done

  migrate_legacy_opencode_skills "$opencode_skills"

  for skill_name in codereview autoloop; do
    install_opencode_skill "$skills_src/$skill_name" "$opencode_skills/macroscope-$skill_name"
  done

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
    error "Installed binary path not found/executable: ${INSTALLED_BINARY}"
    return 1
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
  codex_marketplace_name="$(get_codex_marketplace_name)"
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
  if tool_selected opencode && [ -f "$opencode_root/plugins/macroscope.js" ] && [ -f "$opencode_root/commands/macroscope-codereview.md" ] && [ -f "$opencode_root/skills/macroscope-codereview/SKILL.md" ]; then
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
  local completion="Macroscope installation is complete."
  [ "$INSTALL_MODE" = "update" ] && completion="Macroscope update is complete."

  printf "\n${GREEN}${BOLD}✓ %s${RESET}\n" "$completion"
  [ -z "$INSTALLED_VERSION" ] || printf "  Version: %s\n" "$INSTALLED_VERSION"
  [ -z "$INSTALLED_BINARY" ] || printf "  Binary:  %s\n" "$INSTALLED_BINARY"
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
  printf "  Codex        ${CYAN}\$macroscope:codereview${RESET}   ${CYAN}\$macroscope:autoloop${RESET}\n"
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
  install_signal_traps
  parse_options "$@"
  if [ "$OUTPUT_FORMAT" = "json" ]; then
    exec 3>&1
    exec 1>&2
  fi

  check_dependencies

  if repair_only_requested; then
    step "Checking system requirements..."
    STATE_FILE="$(state_file_path)"
    repair_existing_install
    rm -f "$STATE_FILE"
    info "Repair cleanup complete (MACROSCOPE_REPAIR_ONLY=1). Preserved ~/.macroscope and saved credentials."
    return
  fi

  load_install_state
  adopt_legacy_install
  resolve_lifecycle
  resolve_saved_auto_update

  if [ "$SAVED_AUTO_UPDATE" -eq 0 ]; then
    if [ -t 1 ]; then
      printf '\033[H\033[2J'
    fi
  fi

  detect_platform
  determine_install_dir
  resolve_codex_bundled_binary
  resolve_path_action
  resolve_version

  if [ "$SAVED_AUTO_UPDATE" -eq 0 ]; then
    print_flow_title
    flow_section 1 "Integrations" "Choose which coding agents to connect"
  fi
  select_tools
  if [ "$SAVED_AUTO_UPDATE" -eq 0 ]; then
    if [ "$INSTALL_MODE" = "update" ]; then
      flow_section 2 "Update" "Review and apply the update"
    else
      flow_section 2 "Install" "Review and apply the installation"
    fi
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

  check_binary_target
  prepare_tmp_dir
  stage_binary
  if [ -n "$SELECTED_TOOLS" ]; then fetch_plugin_bundle; fi
  validate_staged_artifacts
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
  if [ -n "$HOST_INSTALL_FAILURES" ]; then
    error "Macroscope is installed, but the $HOST_INSTALL_FAILURES integration was not: files there are not this installation's to replace."
    error "Move or remove the files named above and rerun to add it."
    if [ "$OUTPUT_FORMAT" = "json" ]; then
      printf '{"success":false,"dryRun":false,"mode":"%s","tools":"%s","failedIntegrations":"%s"}\n' \
        "$INSTALL_MODE" "$SELECTED_TOOLS" "$HOST_INSTALL_FAILURES" >&3
    fi
    # Exit 4: the CLI is installed and usable, one or more integrations were
    # declined. Distinct from 1 (nothing usable was installed) so a caller that
    # drives this script, the macroscope CLI's own update path in particular,
    # can report an update that succeeded with a skipped integration instead
    # of a failed update.
    return 4
  fi
  print_installation_completion
  if [ "$OUTPUT_FORMAT" = "json" ]; then
    printf '{"success":true,"dryRun":false,"mode":"%s","tools":"%s"}\n' "$INSTALL_MODE" "$SELECTED_TOOLS" >&3
  fi
}

# Allow tests to source this script for the helper functions without running
# the installer. Normal execution (including `curl ... | bash`) is unaffected.
if [ "${MACROSCOPE_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
