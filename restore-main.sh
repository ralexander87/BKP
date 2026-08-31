#!/usr/bin/env bash

# The restore source is always the folder where this script is located.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Load shared helpers when bundled, but keep this restore script usable by itself.
# BEGIN RESTORE BOOTSTRAP
# Load bundled shared helpers, or define a minimal fallback for old backups.
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
  LOG_MAX_BYTES="${LOG_MAX_BYTES:-5242880}"
  LOG_ROTATE_COUNT="${LOG_ROTATE_COUNT:-5}"
  RSYNC_RESTORE_ARGS=(-aAXH --numeric-ids --info=progress2)
  TEMP_PATHS=()

  log_message() {
    local level="${1^^}"
    shift
    local ts line cli_line

    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    line="[$ts] [$level] [$SCRIPT_NAME] $*"
    cli_line="[$level] $*"
    [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "$line" >>"$LOG_FILE"
    [[ "$QUIET" == "true" && "$level" == "INFO" ]] || printf '%s\n' "$cli_line"
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
  rotate_log_file() {
    local log_file="$1"
    local max_bytes="${2:-$LOG_MAX_BYTES}"
    local keep_count="${3:-$LOG_ROTATE_COUNT}"
    local size index

    [[ -f "$log_file" ]] || return 0
    command -v stat >/dev/null 2>&1 || return 0
    size="$(stat -c %s "$log_file" 2>/dev/null || printf '0')"
    ((size >= max_bytes)) || return 0
    if ((keep_count == 0)); then
      : >"$log_file"
      return 0
    fi
    rm -f -- "$log_file.$keep_count"
    for ((index = keep_count - 1; index >= 1; index--)); do
      [[ -e "$log_file.$index" ]] && mv -f -- "$log_file.$index" "$log_file.$((index + 1))"
    done
    mv -f -- "$log_file" "$log_file.1"
  }
  init_log_file() {
    [[ -n "${LOG_FILE:-}" ]] || return 0
    mkdir -p "$(dirname -- "$LOG_FILE")"
    rotate_log_file "$LOG_FILE"
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

# Keep main restore output compact; the script reports one summary per item.
RSYNC_RESTORE_ARGS=(-aAXH --numeric-ids)
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore.log}"
RESTORE_ID="$(date '+%j-%d-%m-%H-%M-%S')"
STATUS_FILE="$SCRIPT_DIR/backup.status"
MANIFEST_FILE="$SCRIPT_DIR/backup-manifest.txt"
MAIN_BACKUP_CONFIG="$SCRIPT_DIR/config/main.backup.conf"

# Top-level backup internals that should never be restored into $HOME.
RESTORE_EXCLUDED_ITEMS=(
  "DOTS"
  "backup-manifest.txt"
  "backup-manifest.json"
  "backup.status"
  "config"
  "lib"
  "restore-main.sh"
  "restore.log"
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
  require_all_cmds rsync find mv sort awk
}

# Return success when a backup item is restore metadata or helper content.
is_restore_excluded_item() {
  local item="$1"
  local excluded_item

  for excluded_item in "${RESTORE_EXCLUDED_ITEMS[@]}"; do
    [[ "$item" == "$excluded_item" ]] && return 0
  done

  return 1
}

# Discover restorable backup items from the current backup folder.
discover_restore_items() {
  local item
  local path

  HOME_ITEMS=()

  while IFS= read -r -d '' path; do
    item="${path##*/}"
    is_restore_excluded_item "$item" || HOME_ITEMS+=("$item")
  done < <(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -print0 | sort -z)
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

  [[ -e "$target" || -L "$target" ]] || return 0
  [[ ! -e "$snapshot" && ! -L "$snapshot" ]] || die "snapshot already exists: $snapshot"

  log "Moving existing target to safety snapshot: $snapshot"
  mv -- "$target" "$snapshot"
}

# Return a non-conflicting target path inside the PreRestored collection folder.
unique_collect_target() {
  local collect_dir="$1"
  local source_path="$2"
  local name="${source_path##*/}"
  local candidate="$collect_dir/$name"
  local counter=1

  while [[ -e "$candidate" || -L "$candidate" ]]; do
    counter=$((counter + 1))
    candidate="$collect_dir/$name-$counter"
  done

  printf '%s\n' "$candidate"
}

# Move all home pre-restore snapshots into one folder after a successful restore.
collect_pre_restore() {
  local collect_dir="$HOME/PreRestored"
  local source_path
  local target_path
  local count=0
  local -a source_paths=()

  mkdir -p "$collect_dir"
  mapfile -d '' -t source_paths < <(
    find "$HOME" \
      -path "$collect_dir" -prune -o \
      -name '*-pre-restore-*' -print0 -type d -prune
  )

  for source_path in "${source_paths[@]}"; do
    [[ -e "$source_path" || -L "$source_path" ]] || continue
    target_path="$(unique_collect_target "$collect_dir" "$source_path")"
    log "Collecting pre-restore snapshot: $source_path -> $target_path"
    mv -- "$source_path" "$target_path"
    count=$((count + 1))
  done

  log "Collected $count pre-restore snapshot(s) in: $collect_dir"
}

# Resolve the backup device root from a script running inside MAIN/BKP-*.
resolve_backup_device_root() {
  cd -- "$SCRIPT_DIR/../.." 2>/dev/null && pwd
}

# Restore shared firmware stored outside the per-run MAIN/BKP-* folder.
restore_shared_firmware() {
  local device_root
  local source_dir
  local firmware_home_relative="Documents/030-Firmware"
  local big_firmware_relative="BIG/030-Firmware"
  local target_dir

  if [[ -f "$MAIN_BACKUP_CONFIG" ]]; then
    # shellcheck source=config/main.backup.conf
    source "$MAIN_BACKUP_CONFIG"
    firmware_home_relative="$FIRMWARE_HOME_RELATIVE"
    big_firmware_relative="$BIG_FIRMWARE_RELATIVE"
  fi

  device_root="$(resolve_backup_device_root)" || die "could not resolve backup device root from: $SCRIPT_DIR"
  source_dir="$device_root/$big_firmware_relative"
  target_dir="$HOME/$firmware_home_relative"

  if [[ ! -d "$source_dir" ]]; then
    log "Skipping missing shared firmware folder: $source_dir"
    return 0
  fi

  log "Restoring shared firmware: $source_dir -> $target_dir"
  snapshot_existing_target "$target_dir"
  mkdir -p "$target_dir"
  rsync_restore_copy "$source_dir/" "$target_dir/"
  log "Restored shared firmware: $target_dir"
}

# Block restore from incomplete backups while allowing older backup status formats.
read_manifest_status() {
  local manifest_file="$1"
  local status

  status="$(awk -F= '$1 == "backup_status" { print $2; exit }' "$manifest_file")"
  status="${status:-$(awk -F= '$1 == "run_result" { print $2; exit }' "$manifest_file")}"
  status="${status:-$(awk -F' = ' '$1 == "Backup Status" { print $2; exit }' "$manifest_file")}"
  status="${status:-$(awk -F' = ' '$1 == "Run Result" { print $2; exit }' "$manifest_file")}"
  status="${status#[}"
  status="${status%]}"
  status="${status,,}"
  status="${status// /_}"

  case "$status" in
  completed) printf 'complete\n' ;;
  successful) printf 'success\n' ;;
  *) printf '%s\n' "$status" ;;
  esac
}

read_manifest_version() {
  local manifest_file="$1"

  awk -F' = ' '$1 == "Manifest Version" { print $2; exit }' "$manifest_file"
}

verify_backup_status() {
  local manifest_status=""
  local manifest_version=""

  if [[ -f "$MANIFEST_FILE" ]]; then
    manifest_version="$(read_manifest_version "$MANIFEST_FILE")"
    [[ -z "$manifest_version" || "$manifest_version" == "1" ]] || die "unsupported manifest version: $manifest_version"
    manifest_status="$(read_manifest_status "$MANIFEST_FILE")"
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

init_log_file
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

discover_restore_items

# Restore each available backup item into $HOME while preserving metadata.
for item in "${HOME_ITEMS[@]}"; do
  source_path="$SCRIPT_DIR/$item"

  if [[ -e "$source_path" ]]; then
    log "Restoring: $item"
    snapshot_existing_target "$HOME/$item"
    rsync_restore_copy "$source_path" "$HOME/"
    log "Restored: $item"
  else
    log "Skipping missing backup item: $item"
  fi
done

# Restore shared BIG content after the main Documents folder is in place.
restore_shared_firmware

# Normalize SSH file modes after rsync completes.
fix_ssh_permissions
collect_pre_restore
log "Done: restore-main"
