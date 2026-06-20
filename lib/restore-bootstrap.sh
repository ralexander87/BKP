load_restore_helpers() {
  local helper

  for helper in "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/../lib/common.sh"; do
    if [[ -f "$helper" ]]; then
      # shellcheck source=lib/common.sh
      source "$helper"
      return
    fi
  done

  set -Eeuo pipefail
  QUIET="${QUIET:-false}"
  SCRIPT_NAME="${SCRIPT_NAME:-$(basename -- "${BASH_SOURCE[0]}")}"
  RSYNC_RESTORE_ARGS=(-aAXH --numeric-ids --info=progress2)
  TEMP_PATHS=()

  log_message() {
    local level="${1^^}"
    shift
    local line

    line="[$(date '+%Y-%m-%dT%H:%M:%S%z')] [$level] [$SCRIPT_NAME] $*"
    [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "$line" >>"$LOG_FILE"
    [[ "$QUIET" == "true" && "$level" == "INFO" ]] || printf '%s\n' "$line"
  }
  log() { log_message "INFO" "$*"; }
  log_warn() { log_message "WARN" "$*"; }
  log_error() { log_message "ERROR" "$*"; }
  die() {
    log_error "$*"
    exit 1
  }
  require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
  require_all_cmds() {
    local cmd
    for cmd in "$@"; do
      require_cmd "$cmd"
    done
  }
  parse_common_args() {
    local arg
    SCRIPT_ARGS=()
    for arg in "$@"; do
      case "$arg" in
      -q | --quiet) QUIET=true ;;
      *) SCRIPT_ARGS+=("$arg") ;;
      esac
    done
  }
  register_temp_path() { TEMP_PATHS+=("$1"); }
  cleanup_temp_paths() {
    local p
    for p in "${TEMP_PATHS[@]}"; do
      [[ -e "$p" ]] && rm -rf -- "$p"
    done
  }
  ui_cleanup() { :; }
  setup_cleanup_trap() { trap 'cleanup_temp_paths; ui_cleanup' EXIT; }
  rsync_restore_copy() { rsync "${RSYNC_RESTORE_ARGS[@]}" "$@"; }
  sudo_rsync_restore_copy() { sudo rsync "${RSYNC_RESTORE_ARGS[@]}" "$@"; }
  confirm_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    local answer

    read -r -p "$prompt [$default]: " answer
    answer="${answer:-$default}"
    answer="$(printf '%s' "$answer" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [[ "$answer" == "y" || "$answer" == "yes" ]]
  }
}

load_restore_helpers
