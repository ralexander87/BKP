#!/usr/bin/env bash

# The restore source is always the folder where this script is located.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Load shared helpers when bundled, but keep this restore script usable by itself.
# BEGIN RESTORE BOOTSTRAP
load_restore_helpers() {
  local helper

  for helper in "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/../lib/common.sh"; do
    if [[ -f "$helper" ]]; then
      # shellcheck source=lib/common.sh
      source "$helper"
      return 0
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
# END RESTORE BOOTSTRAP

LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore.log}"
RESTORE_ID="$(date '+%j-%d-%m-%H-%M-%S')"
STATUS_FILE="$SCRIPT_DIR/backup.status"
MANIFEST_FILE="$SCRIPT_DIR/backup-manifest.txt"

# Backup items expected inside the current backup folder.
HOME_ITEMS=(
  "Downloads"
  "Pictures"
  "Videos"
  "Music"
  "Obsidian"
  "Code"
  "Documents"
  ".themes"
  ".icons"
  ".ssh"
  ".vscode-oss"
)

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./restore-main.sh [--quiet]

Restore backup content from the current folder to $HOME.
EOF
}

# Ensure required dependencies exist before restore starts.
preflight_checks() {
  require_all_cmds rsync find mv
}

# Enforce SSH's strict permission expectations after restoring .ssh.
fix_ssh_permissions() {
  local ssh_dir="$HOME/.ssh"

  [[ -d "$ssh_dir" ]] || return 0

  log "Fixing SSH permissions"
  find "$ssh_dir" -type d -exec chmod 700 {} +
  find "$ssh_dir" -type f -name '*.pub' -exec chmod 644 {} +
  find "$ssh_dir" -type f ! -name '*.pub' -exec chmod 600 {} +
}

# Move an existing target aside before restore instead of overwriting it in place.
snapshot_existing_target() {
  local target="$1"
  local snapshot="$target-pre-restore-$RESTORE_ID"

  [[ -e "$target" ]] || return 0
  [[ ! -e "$snapshot" ]] || die "snapshot already exists: $snapshot"

  log "Moving existing target to safety snapshot: $snapshot"
  mv -- "$target" "$snapshot"
}

verify_backup_status() {
  local manifest_status=""

  if [[ -f "$MANIFEST_FILE" ]]; then
    manifest_status="$(awk -F= '$1 == "backup_status" { print $2; exit }' "$MANIFEST_FILE")"
    manifest_status="${manifest_status:-$(awk -F= '$1 == "run_result" { print $2; exit }' "$MANIFEST_FILE")}"
    if [[ -n "$manifest_status" ]]; then
      [[ "$manifest_status" == "complete" || "$manifest_status" == "success" ]] || die "backup status is not complete: $manifest_status"
      return 0
    fi
  fi

  if [[ -f "$STATUS_FILE" ]]; then
    [[ "$(cat "$STATUS_FILE")" == "complete" ]] || die "backup status is not complete: $(cat "$STATUS_FILE")"
    return 0
  fi

  log_warn "backup status not found in manifest; continuing for older backup format"
}

parse_common_args "$@"
if [[ "${SCRIPT_ARGS[0]:-}" == "-h" || "${SCRIPT_ARGS[0]:-}" == "--help" ]]; then
  usage
  exit 0
fi

preflight_checks
setup_cleanup_trap

# Show the restore source and target before asking for confirmation.
log "Restore source: $SCRIPT_DIR"
log "Restore target: $HOME"
verify_backup_status

# Require explicit confirmation before copying anything into $HOME.
if ! confirm_yes_no "Start restore from current folder to \$HOME?" "N"; then
  log "Restore cancelled"
  exit 0
fi

# Restore each available backup item into $HOME while preserving metadata.
for item in "${HOME_ITEMS[@]}"; do
  source_path="$SCRIPT_DIR/$item"

  if [[ -e "$source_path" ]]; then
    log "Restoring: $item"
    snapshot_existing_target "$HOME/$item"
    rsync_restore_copy "$source_path" "$HOME/"
  else
    log "Skipping missing backup item: $item"
  fi
done

# Normalize SSH file modes after rsync completes.
fix_ssh_permissions
log "Done: restore-main"
