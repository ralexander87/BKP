#!/usr/bin/env bash

# Service restore runs from the backup folder where this script is located.
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
  resolve_writable_output_path() {
    local preferred_file="$1"
    local fallback_file="$2"
    local preferred_dir
    local fallback_dir

    preferred_dir="$(dirname -- "$preferred_file")"
    fallback_dir="$(dirname -- "$fallback_file")"
    if { [[ -e "$preferred_file" ]] && [[ -w "$preferred_file" ]]; } ||
      { [[ ! -e "$preferred_file" ]] && [[ -w "$preferred_dir" ]]; }; then
      printf '%s\n' "$preferred_file"
      return 0
    fi
    mkdir -p "$fallback_dir"
    [[ -w "$fallback_dir" ]] || die "runtime output directory is not writable: $fallback_dir"
    printf '%s\n' "$fallback_file"
  }
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

RESTORE_ID="$(date '+%Y-%j-%d-%m-%H-%M-%S')"
RESTORE_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/bkp"
LOG_FILE="${LOG_FILE:-$(resolve_writable_output_path "$SCRIPT_DIR/restore.log" "$RESTORE_STATE_ROOT/restore-serv-$RESTORE_ID.log")}"
ROLLBACK_FILE="$(resolve_writable_output_path "$SCRIPT_DIR/restore-serv-rollback-$RESTORE_ID.sh" "$RESTORE_STATE_ROOT/restore-serv-rollback-$RESTORE_ID.sh")"
RUN_RESULT="in_progress"
CURRENT_ACTION="none"
STATUS_FILE="$SCRIPT_DIR/backup.status"
MANIFEST_FILE="$SCRIPT_DIR/backup-manifest.txt"
SERVICE_RESTORE_CONFIG=""
SYSTEM_SNAPSHOT_STATE="pending"
ACTION_FAILURE_COUNT=0

# Set built-in restore values before any bundled or local config overrides.
set_service_restore_defaults() {
  SMB_DIRS=(
    "/SMB"
    "/SMB/euclid"
    "/SMB/pneuma-kali"
    "/SMB/lateralus"
    "/SMB/SCP"
    "/SMB/SCP/HDD-01"
    "/SMB/SCP/HDD-02"
    "/SMB/SCP/HDD-03"
  )

  FSTAB_LINES=()
  RETIRED_FSTAB_TARGETS=(
    "/SMB/pneuma-win"
  )

  GRUB_CMDLINE_LINUX_DEFAULT_VALUE="loglevel=3 quiet splash"
  GRUB_TERMINAL_OUTPUT_VALUE="gfxterm"
  GRUB_GFXMODE_VALUE="1440x1080x32"
  GRUB_THEME_VALUE="/boot/grub/themes/lateralus/theme.txt"
  GRUB_THEME_SHARED_RELATIVE="BIG/lateralus"
}

# Return success when a mount target is retired and should be removed.
is_retired_fstab_target() {
  local target="$1"
  local retired_target

  for retired_target in "${RETIRED_FSTAB_TARGETS[@]}"; do
    [[ "$target" == "$retired_target" ]] && return 0
  done

  return 1
}

# Drop retired SMB directories and fstab entries from loaded config overrides.
prune_retired_service_restore_values() {
  local dir
  local line
  local mount_target
  local -a kept_fstab_lines=()
  local -a kept_smb_dirs=()

  for dir in "${SMB_DIRS[@]}"; do
    is_retired_fstab_target "$dir" || kept_smb_dirs+=("$dir")
  done
  SMB_DIRS=("${kept_smb_dirs[@]}")

  for line in "${FSTAB_LINES[@]}"; do
    read -r _ mount_target _ <<<"$line"
    [[ -n "$mount_target" ]] || die "invalid configured fstab line: $line"
    is_retired_fstab_target "$mount_target" || kept_fstab_lines+=("$line")
  done
  FSTAB_LINES=("${kept_fstab_lines[@]}")
}

# Load service restore config files from the backup first, then project-local fallbacks.
load_service_restore_config() {
  local candidate
  local -a loaded_configs=()
  local -a candidates=(
    "$SCRIPT_DIR/config/serv.restore.conf"
    "$SCRIPT_DIR/config/local/serv.restore.conf"
    "$SCRIPT_DIR/serv.restore.conf"
  )

  set_service_restore_defaults

  if [[ -n "${PROJECT_ROOT:-}" ]]; then
    candidates+=("$PROJECT_ROOT/config/serv.restore.conf")
    candidates+=("$PROJECT_ROOT/config/local/serv.restore.conf")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      # shellcheck source=config/serv.restore.conf
      source "$candidate"
      loaded_configs+=("$candidate")
    fi
  done

  if [[ "${#loaded_configs[@]}" -gt 0 ]]; then
    SERVICE_RESTORE_CONFIG="${loaded_configs[*]}"
  fi

  prune_retired_service_restore_values
}

load_service_restore_config

# Record structured audit entries for this restore run.
audit_log() {
  local event="$1"
  local result="$RUN_RESULT"

  case "$event" in
  action_started) result="in_progress" ;;
  action_completed) result="success" ;;
  action_failed) result="failed" ;;
  action_skipped | cancelled) result="skipped" ;;
  esac

  log "AUDIT event=$event action=$CURRENT_ACTION result=$result rollback=$ROLLBACK_FILE"
}

# Offer one Timeshift snapshot before the first system-changing action.
ensure_pre_restore_system_snapshot() {
  local snapshot_comment="BKPv3 pre-restore $RESTORE_ID"

  case "$SYSTEM_SNAPSHOT_STATE" in
  created | skipped | unavailable | failed_continued) return 0 ;;
  failed_blocked) return 1 ;;
  esac

  if ! command -v timeshift >/dev/null 2>&1; then
    SYSTEM_SNAPSHOT_STATE="unavailable"
    log_warn "Timeshift is unavailable; continuing with file-level rollback only"
    return 0
  fi

  if ! confirm_yes_no "Create one Timeshift snapshot before the first system change?" "N"; then
    SYSTEM_SNAPSHOT_STATE="skipped"
    log "Timeshift snapshot skipped"
    return 0
  fi

  log "Creating Timeshift snapshot: $snapshot_comment"
  if sudo timeshift --create --scripted --comments "$snapshot_comment" --tags O; then
    SYSTEM_SNAPSHOT_STATE="created"
    log "Timeshift snapshot created"
    return 0
  fi

  log_error "Timeshift snapshot creation failed"
  if confirm_yes_no "Continue without a Timeshift snapshot?" "N"; then
    SYSTEM_SNAPSHOT_STATE="failed_continued"
    return 0
  fi
  SYSTEM_SNAPSHOT_STATE="failed_blocked"
  return 1
}

# Confirm an action and prepare its optional system snapshot.
confirm_action() {
  local label="$1"
  local snapshot_required="${2:-true}"

  CURRENT_ACTION="$label"
  confirm_yes_no "Start $label?" "N" || {
    audit_log "cancelled"
    log "$label cancelled"
    return 1
  }

  if [[ "$snapshot_required" == "true" ]] && ! ensure_pre_restore_system_snapshot; then
    audit_log "cancelled"
    log "$label cancelled because no system snapshot was available"
    return 1
  fi

  audit_log "action_started"
  return 0
}

# Run one action fail-fast while keeping failures inside the interactive menu.
run_menu_action() {
  local label="$1"
  local action_function="$2"
  local snapshot_required="${3:-true}"
  local action_exit

  confirm_action "$label" "$snapshot_required" || return 0

  set +e
  (
    trap - EXIT ERR INT TERM
    set -Eeuo pipefail
    trap 'cleanup_temp_paths' EXIT
    "$action_function"
  )
  action_exit="$?"
  set -e

  if [[ "$action_exit" -eq 0 ]]; then
    audit_log "action_completed"
    log "Done: $label"
    return 0
  fi

  ACTION_FAILURE_COUNT=$((ACTION_FAILURE_COUNT + 1))
  audit_log "action_failed"
  log_error "$label failed (exit $action_exit); returning to menu"
  return 0
}

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./restore-serv.sh [--quiet]

Restore backed-up service files from the current folder to their system paths.
Root privileges are required.
EOF
}

# Ensure required dependencies exist before menu actions start.
preflight_checks() {
  require_all_cmds sudo awk cat chmod dirname findmnt mktemp mv
}

# Show currently available service restore actions.
show_menu() {
  cat <<'EOF'
Select action:
  0 - Exit
============================
  1 - Create SMB
============================
  2 - Restore samba
  3 - Restore SSH
  4 - Restore fstab
  5 - Restore grub theme
  6 - Restore GRUB
  7 - Restore RAMBOX
============================
  90 - Restore sharing profile
  91 - Restore boot profile
  92 - Restore discovery services
  93 - Restore smart-card service
  94 - Restore complete profile
============================
  98 - Collect pre-restore
EOF
}

# Ensure backup finished cleanly before allowing restore actions.
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

read_manifest_type() {
  local backup_type

  backup_type="$(awk -F= '$1 == "backup_type" { print $2; exit }' "$1")"
  backup_type="${backup_type:-$(awk -F' = ' '$1 == "Backup Type" { print $2; exit }' "$1")}"
  backup_type="${backup_type#[}"
  backup_type="${backup_type%]}"
  printf '%s\n' "${backup_type,,}"
}

verify_backup_status() {
  local manifest_status=""
  local manifest_version=""
  local manifest_type=""

  if [[ -f "$MANIFEST_FILE" ]]; then
    manifest_version="$(read_manifest_version "$MANIFEST_FILE")"
    [[ -z "$manifest_version" || "$manifest_version" == "1" ]] || die "unsupported manifest version: $manifest_version"
    manifest_type="$(read_manifest_type "$MANIFEST_FILE")"
    [[ -z "$manifest_type" || "$manifest_type" == "service" || "$manifest_type" == "serv" ]] || die "backup type is not SERVICE: $manifest_type"
    manifest_status="$(read_manifest_status "$MANIFEST_FILE")"
    if [[ -n "$manifest_status" ]]; then
      [[ "$manifest_status" == "complete" || "$manifest_status" == "success" ]] || die "backup status is not complete: $manifest_status"
      return 0
    fi
  fi

  [[ -f "$STATUS_FILE" ]] || die "backup status not found in manifest or legacy file: $MANIFEST_FILE"
  [[ "$(cat "$STATUS_FILE")" == "complete" ]] || die "backup status is not complete: $(cat "$STATUS_FILE")"
}

# Restore one file from the current backup into a target directory.
restore_file_to_dir() {
  local label="$1"
  local source_rel="$2"
  local target_dir="$3"
  local source_file="$SCRIPT_DIR/$source_rel"

  [[ -f "$source_file" ]] || die "$label source file not found: $source_file"

  log "Restoring $label file: $source_rel -> $target_dir"
  sudo mkdir -p "$target_dir"
  sudo_rsync_restore_copy "$source_file" "$target_dir/"
}

# Resolve the non-root desktop user for ownership and Samba account actions.
local_non_root_user() {
  local local_user="${SUDO_USER:-${USER:-}}"

  [[ -n "$local_user" ]] || local_user="$(id -un)"
  [[ "$local_user" != "root" ]] || die "could not determine a non-root user"
  printf '%s\n' "$local_user"
}

# Insert rollback commands immediately after the generated script header.
prepend_rollback_commands() {
  local marker="# Rollback commands are stored newest-first."
  local rollback_dir
  local rollback_temp
  local line
  local command_line
  local marker_found=false

  rollback_dir="$(dirname -- "$ROLLBACK_FILE")"
  rollback_temp="$(mktemp "$rollback_dir/.restore-serv-rollback.XXXXXX")"
  register_temp_path "$rollback_temp"
  while IFS= read -r line; do
    printf '%s\n' "$line" >>"$rollback_temp"
    if [[ "$line" == "$marker" ]]; then
      marker_found=true
      for command_line in "$@"; do
        printf '%s\n' "$command_line" >>"$rollback_temp"
      done
    fi
  done <"$ROLLBACK_FILE"

  [[ "$marker_found" == "true" ]] || die "rollback command marker not found: $ROLLBACK_FILE"
  chmod --reference="$ROLLBACK_FILE" "$rollback_temp"
  mv -- "$rollback_temp" "$ROLLBACK_FILE"
}

# Snapshot target path before modifying it and register rollback command.
snapshot_target() {
  local target="$1"
  local snapshot="$target-pre-restore-$RESTORE_ID"
  local collect_dir="$HOME/PreRestored"
  local collected_snapshot
  local remove_command
  local restore_command
  local target_fstype

  if [[ ! -e "$target" && ! -L "$target" ]]; then
    printf -v remove_command 'sudo rm -rf -- %q' "$target"
    prepend_rollback_commands "$remove_command"
    return 0
  fi
  [[ ! -e "$snapshot" && ! -L "$snapshot" ]] || die "snapshot already exists: $snapshot"

  log "Creating snapshot: $target -> $snapshot"
  target_fstype="$(target_filesystem_type "$target")"
  case "$target_fstype" in
  vfat | exfat | msdos | ntfs | ntfs3 | fuseblk)
    sudo cp -R -- "$target" "$snapshot"
    ;;
  *)
    sudo cp -a -- "$target" "$snapshot"
    ;;
  esac
  mkdir -p "$collect_dir"
  collected_snapshot="$(unique_collect_target "$collect_dir" "$snapshot")"
  log "Moving safety snapshot into PreRestored: $snapshot -> $collected_snapshot"
  sudo mv -- "$snapshot" "$collected_snapshot"
  printf -v remove_command 'sudo rm -rf -- %q' "$target"
  case "$target_fstype" in
  vfat | exfat | msdos | ntfs | ntfs3 | fuseblk)
    printf -v restore_command 'sudo cp -R -- %q %q' "$collected_snapshot" "$target"
    ;;
  *)
    printf -v restore_command 'sudo cp -a -- %q %q' "$collected_snapshot" "$target"
    ;;
  esac
  prepend_rollback_commands "$remove_command" "$restore_command"
}

# Record the enabled and active state of a service before changing it.
snapshot_service_state() {
  local service="$1"
  local enabled_command
  local active_command

  if systemctl is-enabled --quiet "$service" 2>/dev/null; then
    printf -v enabled_command 'sudo systemctl enable %q >/dev/null 2>&1 || true' "$service"
  else
    printf -v enabled_command 'sudo systemctl disable %q >/dev/null 2>&1 || true' "$service"
  fi

  if systemctl is-active --quiet "$service" 2>/dev/null; then
    printf -v active_command 'sudo systemctl start %q >/dev/null 2>&1 || true' "$service"
  else
    printf -v active_command 'sudo systemctl stop %q >/dev/null 2>&1 || true' "$service"
  fi
  prepend_rollback_commands "$active_command" "$enabled_command"
}

# Enable a unit and restart it when already active so restored settings take effect.
enable_and_refresh_unit() {
  local unit="$1"

  systemctl cat "$unit" >/dev/null 2>&1 || die "systemd unit not found: $unit"
  snapshot_service_state "$unit"

  log "Enabling systemd unit: $unit"
  sudo systemctl enable "$unit"
  if systemctl is-active --quiet "$unit"; then
    log "Restarting active systemd unit: $unit"
    sudo systemctl restart "$unit"
  else
    log "Starting systemd unit: $unit"
    sudo systemctl start "$unit"
  fi
  sudo systemctl is-active --quiet "$unit" || die "systemd unit did not become active: $unit"
}

# Resolve the filesystem supporting a target, including targets not created yet.
target_filesystem_type() {
  local target="$1"
  local probe="$target"

  while [[ ! -e "$probe" && ! -L "$probe" && "$probe" != "/" ]]; do
    probe="$(dirname -- "$probe")"
  done
  findmnt -n -o FSTYPE --target "$probe"
}

# Restore a tree using only metadata supported by the target filesystem.
restore_tree_to_system() {
  local source_dir="$1"
  local target_dir="$2"
  local target_fstype

  require_all_cmds sudo mkdir rsync findmnt dirname
  target_fstype="$(target_filesystem_type "$target_dir")"
  [[ -n "$target_fstype" ]] || die "could not determine target filesystem: $target_dir"

  log "Target filesystem for $target_dir: $target_fstype"
  sudo mkdir -p "$target_dir"
  case "$target_fstype" in
  vfat | exfat | msdos | ntfs | ntfs3 | fuseblk)
    sudo rsync -rlt --no-perms --no-owner --no-group "$source_dir/" "$target_dir/"
    ;;
  *)
    sudo_rsync_restore_copy "$source_dir/" "$target_dir/"
    ;;
  esac
}

# Unload a module during rollback only when this restore loaded it.
snapshot_kernel_module_state() {
  local module="$1"
  local unload_command

  if [[ ! -d "/sys/module/$module" ]]; then
    printf -v unload_command 'sudo modprobe -r %q >/dev/null 2>&1 || true' "$module"
    prepend_rollback_commands "$unload_command"
  fi
}

# Resolve the backup device root from a script running inside SERV/BKP-*.
resolve_backup_device_root() {
  cd -- "$SCRIPT_DIR/../.." 2>/dev/null && pwd
}

# Restore the shared lateralus grub theme folder into /boot/grub/themes/.
restore_grub_theme() {
  local device_root
  local source_dir
  local target_dir="/boot/grub/themes/lateralus"

  require_all_cmds sudo cp mkdir rsync findmnt dirname
  device_root="$(resolve_backup_device_root)" || die "could not resolve backup device root from: $SCRIPT_DIR"
  source_dir="$device_root/$GRUB_THEME_SHARED_RELATIVE"
  [[ -d "$source_dir" ]] || die "grub theme source folder not found: $source_dir"
  [[ -s "$source_dir/theme.txt" ]] || die "grub theme definition not found or empty: $source_dir/theme.txt"

  snapshot_target "$target_dir"
  log "Restoring grub theme: $source_dir -> /boot/grub/themes/"
  restore_tree_to_system "$source_dir" "$target_dir"
}

# Restore samba smb.conf and creds-* files into /etc/samba/.
restore_samba() {
  local source_smb="smb.conf"
  local source_samba_dir="$SCRIPT_DIR"
  local target_dir="/etc/samba"
  local local_user
  local answer
  local -a creds_files=()
  local -a restored_creds_files=()
  local creds_file

  require_all_cmds sudo cp mkdir rsync chown chmod systemctl
  [[ -f "$SCRIPT_DIR/$source_smb" ]] || die "samba source file not found: $SCRIPT_DIR/$source_smb"
  if command -v testparm >/dev/null 2>&1; then
    sudo testparm -s "$SCRIPT_DIR/$source_smb" >/dev/null || die "backed-up samba config validation failed"
  fi
  snapshot_target "/etc/samba/smb.conf"
  restore_file_to_dir "samba" "$source_smb" "$target_dir"
  sudo chown root:root /etc/samba/smb.conf
  sudo chmod 644 /etc/samba/smb.conf

  shopt -s nullglob
  creds_files=("$source_samba_dir"/creds-*)
  shopt -u nullglob

  if [[ "${#creds_files[@]}" -eq 0 ]]; then
    log "No creds-* files found in backup: $source_samba_dir"
  else
    for creds_file in "${creds_files[@]}"; do
      log "Restoring samba creds file: $(basename -- "$creds_file") -> $target_dir"
      snapshot_target "$target_dir/$(basename -- "$creds_file")"
      sudo_rsync_restore_copy "$creds_file" "$target_dir/"
      restored_creds_files+=("$target_dir/$(basename -- "$creds_file")")
    done
  fi

  # Harden only credential files restored by this action.
  for creds_file in "${restored_creds_files[@]}"; do
    sudo chown root:root "$creds_file"
    sudo chmod 600 "$creds_file"
  done

  if command -v testparm >/dev/null 2>&1; then
    sudo testparm -s >/dev/null || die "samba config validation failed"
  fi

  # Optionally register the local desktop user with Samba after config validation.
  local_user="$(local_non_root_user)"
  read -r -p "Add local user to samba ? [Yy/Nn] " answer
  case "$answer" in
  [Yy])
    require_cmd smbpasswd
    log "Adding local user to samba: smbpasswd -a $local_user"
    sudo smbpasswd -a "$local_user"
    ;;
  [Nn] | "")
    log "Skipping samba user add for: $local_user"
    ;;
  *)
    log "Skipping samba user add; invalid answer: $answer"
    ;;
  esac

  enable_and_refresh_unit "smb.service"
  enable_and_refresh_unit "nmb.service"
}

# Validate an sshd configuration without depending on installed host keys.
validate_sshd_config_file() {
  local config_file="$1"
  local dropin_dir="${2:-}"
  local validation_dir
  local validation_config
  local validation_key
  local validation_dropin_dir

  require_all_cmds sshd ssh-keygen mktemp cp sed
  validation_dir="$(mktemp -d)"
  register_temp_path "$validation_dir"
  validation_config="$validation_dir/sshd_config"
  validation_key="$validation_dir/ssh_host_ed25519_key"
  cp -- "$config_file" "$validation_config"
  if [[ -n "$dropin_dir" && -d "$dropin_dir" ]]; then
    validation_dropin_dir="$validation_dir/sshd_config.d"
    cp -R -- "$dropin_dir" "$validation_dropin_dir"
    sed "s|/etc/ssh/sshd_config\.d/|$validation_dropin_dir/|g" "$validation_config" >"$validation_config.rewritten"
    mv -- "$validation_config.rewritten" "$validation_config"
  fi
  ssh-keygen -q -t ed25519 -N "" -f "$validation_key"
  sudo sshd -t -f "$validation_config" -h "$validation_key"
}

# Restore sshd_config into /etc/ssh/.
restore_ssh() {
  local source_dropin_dir="$SCRIPT_DIR/sshd_config.d"
  local target_dropin_dir="/etc/ssh/sshd_config.d"

  require_all_cmds sudo cp mkdir rsync chown chmod systemctl sshd ssh-keygen rm find

  [[ -f "$SCRIPT_DIR/sshd_config" ]] || die "SSH source file not found: $SCRIPT_DIR/sshd_config"
  log "Validating backed-up sshd configuration with a temporary host key"
  validate_sshd_config_file "$SCRIPT_DIR/sshd_config" "$source_dropin_dir" || die "backed-up sshd config validation failed"
  snapshot_target "/etc/ssh/sshd_config"
  restore_file_to_dir "SSH" "sshd_config" "/etc/ssh"
  sudo chown root:root /etc/ssh/sshd_config
  sudo chmod 644 /etc/ssh/sshd_config

  if [[ -d "$source_dropin_dir" ]]; then
    log "Restoring SSH server config drop-ins: $source_dropin_dir -> $target_dropin_dir"
    snapshot_target "$target_dropin_dir"
    sudo rm -rf -- "$target_dropin_dir"
    restore_tree_to_system "$source_dropin_dir" "$target_dropin_dir"
    sudo chown -R root:root "$target_dropin_dir"
    sudo find "$target_dropin_dir" -type d -exec chmod 755 {} +
    sudo find "$target_dropin_dir" -type f -exec chmod 644 {} +
  fi

  log "Generating any missing SSH host keys"
  sudo ssh-keygen -A
  sudo sshd -t || die "restored sshd config validation failed"
  enable_and_refresh_unit "sshd.service"
}

# Restore the complete non-SSH file-sharing setup.
restore_sharing_profile() {
  create_smb_tree
  restore_samba
  restore_fstab
}

# Restore the GRUB theme and configured GRUB defaults together.
restore_boot_profile() {
  restore_grub_theme
  restore_grub_defaults
}

# Enable and refresh local network discovery services.
restore_discovery_profile() {
  enable_and_refresh_unit "avahi-daemon.service"
  enable_and_refresh_unit "wsdd.service"
}

# Enable the socket-activated smart-card service used by Arch Linux.
restore_smartcard_profile() {
  enable_and_refresh_unit "pcscd.socket"
}

# Restore all grouped system configuration, including remote access.
restore_complete_profile() {
  restore_sharing_profile
  restore_ssh
  restore_boot_profile
  restore_discovery_profile
  restore_smartcard_profile
}

# Create SMB folders and set ownership/perms for the local non-root user.
create_smb_tree() {
  local local_user
  local dir
  local index
  local -a existed=()
  local -a owners=()
  local -a modes=()
  local -a rollback_commands=()
  local rollback_command

  require_all_cmds sudo mkdir chown chmod stat
  local_user="$(local_non_root_user)"

  # Capture all original directory states before mkdir -p changes any parent.
  for dir in "${SMB_DIRS[@]}"; do
    if sudo test -d "$dir"; then
      existed+=(true)
      owners+=("$(sudo stat -c '%u:%g' "$dir")")
      modes+=("$(sudo stat -c '%a' "$dir")")
    elif sudo test -e "$dir"; then
      die "SMB target exists and is not a directory: $dir"
    else
      existed+=(false)
      owners+=("")
      modes+=("")
    fi
  done

  # Register rollback in reverse path order so newly created children are removed first.
  for ((index = ${#SMB_DIRS[@]} - 1; index >= 0; index--)); do
    dir="${SMB_DIRS[$index]}"
    if [[ "${existed[$index]}" == "true" ]]; then
      printf -v rollback_command 'sudo chmod %q %q' "${modes[$index]}" "$dir"
      rollback_commands+=("$rollback_command")
      printf -v rollback_command 'sudo chown %q %q' "${owners[$index]}" "$dir"
      rollback_commands+=("$rollback_command")
    else
      printf -v rollback_command 'sudo rmdir -- %q 2>/dev/null || true' "$dir"
      rollback_commands+=("$rollback_command")
    fi
  done
  prepend_rollback_commands "${rollback_commands[@]}"

  for dir in "${SMB_DIRS[@]}"; do
    log "Ensuring SMB directory: $dir"
    sudo mkdir -p "$dir"
    sudo chown "$local_user:$local_user" "$dir"
    sudo chmod 750 "$dir"
  done

}

# Replace entries for configured mountpoints in an fstab file.
replace_managed_fstab_entries() {
  local fstab_file="$1"
  local line
  local mount_target
  local filtered_fstab
  local -a managed_targets=()

  require_all_cmds awk mv mktemp
  filtered_fstab="$(mktemp)"
  register_temp_path "$filtered_fstab"

  for line in "${FSTAB_LINES[@]}"; do
    read -r _ mount_target _ <<<"$line"
    [[ -n "$mount_target" ]] || die "invalid configured fstab line: $line"
    managed_targets+=("$mount_target")
  done
  managed_targets+=("${RETIRED_FSTAB_TARGETS[@]}")

  for mount_target in "${managed_targets[@]}"; do
    awk -v target="$mount_target" '
      /^[[:space:]]*#/ || NF < 2 || $2 != target { print }
    ' "$fstab_file" >"$filtered_fstab"
    mv -- "$filtered_fstab" "$fstab_file"
  done

  printf '\n' >>"$fstab_file"
  for line in "${FSTAB_LINES[@]}"; do
    printf '%s\n' "$line" >>"$fstab_file"
  done
}

# Replace configured SMB mount targets in /etc/fstab.
restore_fstab() {
  local temp_fstab

  require_all_cmds sudo cp install mktemp modprobe
  if [[ "${#FSTAB_LINES[@]}" -eq 0 && "${#RETIRED_FSTAB_TARGETS[@]}" -eq 0 ]]; then
    log "No SMB fstab entries configured; add local entries in config/local/serv.restore.conf"
    return 0
  fi

  log "Loading cifs kernel module"
  snapshot_kernel_module_state "cifs"
  sudo modprobe cifs

  snapshot_target "/etc/fstab"

  temp_fstab="$(mktemp)"
  register_temp_path "$temp_fstab"
  sudo cp /etc/fstab "$temp_fstab"

  log "Replacing configured SMB mount entries in /etc/fstab (atomic update)"
  replace_managed_fstab_entries "$temp_fstab"

  if command -v findmnt >/dev/null 2>&1; then
    findmnt --verify --tab-file "$temp_fstab" >/dev/null || die "fstab validation failed"
  fi

  sudo install -m 0644 "$temp_fstab" /etc/fstab

}

# Set or append one quoted GRUB assignment inside a temp config file.
set_grub_assignment() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped

  require_all_cmds grep sed
  escaped="$(printf '%s' "$value" | sed 's/[&|]/\\&/g')"
  if grep -Eq "^#?${key}=" "$file"; then
    sed -i -E "s|^#?${key}=.*|${key}=\"${escaped}\"|" "$file"
  else
    printf '%s="%s"\n' "$key" "$value" >>"$file"
  fi
}

# Update GRUB defaults, then regenerate the boot menu from the restored values.
restore_grub_defaults() {
  local temp_grub

  require_all_cmds sudo cp install mktemp grep sed grub-mkconfig bash
  snapshot_target "/etc/default/grub"
  snapshot_target "/boot/grub/grub.cfg"

  temp_grub="$(mktemp)"
  register_temp_path "$temp_grub"
  sudo cp /etc/default/grub "$temp_grub"

  log "Updating GRUB config: /etc/default/grub"
  sed -i -E 's|^GRUB_TERMINAL_INPUT=console|#GRUB_TERMINAL_INPUT=console|' "$temp_grub"
  set_grub_assignment "$temp_grub" "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_CMDLINE_LINUX_DEFAULT_VALUE"
  set_grub_assignment "$temp_grub" "GRUB_TERMINAL_OUTPUT" "$GRUB_TERMINAL_OUTPUT_VALUE"
  set_grub_assignment "$temp_grub" "GRUB_GFXMODE" "$GRUB_GFXMODE_VALUE"
  set_grub_assignment "$temp_grub" "GRUB_THEME" "$GRUB_THEME_VALUE"

  grep -Fqx "GRUB_THEME=\"$GRUB_THEME_VALUE\"" "$temp_grub" || die "grub theme line validation failed"
  bash -n "$temp_grub" || die "generated GRUB defaults syntax validation failed"
  sudo install -m 0644 "$temp_grub" /etc/default/grub
  log "Regenerating GRUB menu: /boot/grub/grub.cfg"
  sudo grub-mkconfig -o /boot/grub/grub.cfg
}

# Restore executable directory permissions required by Rambox.
restore_rambox() {
  local target_dir="/opt/rambox"
  local previous_mode
  local rollback_command

  require_all_cmds sudo chmod stat
  sudo test -d "$target_dir" || die "Rambox folder not found: $target_dir"

  previous_mode="$(sudo stat -c '%a' "$target_dir")"
  [[ "$previous_mode" =~ ^[0-7]{3,4}$ ]] || die "could not read Rambox folder mode: $target_dir"
  printf -v rollback_command 'sudo chmod %q %q' "$previous_mode" "$target_dir"
  prepend_rollback_commands "$rollback_command"

  log "Setting Rambox folder permissions: $target_dir -> 755"
  sudo chmod 755 "$target_dir"
  [[ "$(sudo stat -c '%a' "$target_dir")" == "755" ]] || die "failed to verify Rambox folder permissions: $target_dir"

}

# Return a non-conflicting target path inside the PreRestored collection folder.
unique_collect_target() {
  local collect_dir="$1"
  local source_path="$2"
  local name
  local candidate
  local counter=1

  name="$(basename -- "$source_path")"
  candidate="$collect_dir/$name"
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    candidate="$collect_dir/$name-$counter"
    counter=$((counter + 1))
  done

  printf '%s\n' "$candidate"
}

# Rewrite generated rollback scripts after a snapshot is moved into PreRestored.
update_rollback_snapshot_path() {
  local old_path="$1"
  local new_path="$2"
  local old_escaped
  local new_escaped
  local rollback_file
  local rollback_temp
  local -a rollback_files=()

  printf -v old_escaped '%q' "$old_path"
  printf -v new_escaped '%q' "$new_path"

  shopt -s nullglob
  rollback_files=(
    "$SCRIPT_DIR"/restore-serv-rollback-*.sh
    "$RESTORE_STATE_ROOT"/restore-serv-rollback-*.sh
  )
  shopt -u nullglob

  for rollback_file in "${rollback_files[@]}"; do
    grep -Fq "$old_escaped" "$rollback_file" || continue
    rollback_temp="$(mktemp)"
    register_temp_path "$rollback_temp"
    awk -v old="$old_escaped" -v new="$new_escaped" '
      {
        line = $0
        while ((position = index(line, old)) > 0) {
          line = substr(line, 1, position - 1) new substr(line, position + length(old))
        }
        print line
      }
    ' "$rollback_file" >"$rollback_temp"
    chmod --reference="$rollback_file" "$rollback_temp"
    mv -- "$rollback_temp" "$rollback_file"
    log "Updated rollback snapshot path: $rollback_file"
  done
}

# Collect legacy service pre-restore snapshots left by older restore runs.
collect_pre_restore() {
  local collect_dir="$HOME/PreRestored"
  local source_path
  local target_path
  local count=0
  local -a search_dirs=(
    "/etc"
    "/etc/default"
    "/etc/samba"
    "/etc/ssh"
    "/boot/grub/themes"
  )
  local -a source_paths=()
  local dir

  require_all_cmds sudo find mv mkdir grep mktemp
  mkdir -p "$collect_dir"

  mapfile -d '' -t source_paths < <(
    for dir in "${search_dirs[@]}"; do
      [[ -d "$dir" ]] || continue
      sudo find "$dir" -maxdepth 1 -name '*-pre-restore-*' -print0
    done
  )

  for source_path in "${source_paths[@]}"; do
    [[ -e "$source_path" ]] || continue
    target_path="$(unique_collect_target "$collect_dir" "$source_path")"
    log "Moving pre-restore snapshot: $source_path -> $target_path"
    sudo mv -- "$source_path" "$target_path"
    update_rollback_snapshot_path "$source_path" "$target_path"
    count=$((count + 1))
  done

  log "Collected $count pre-restore item(s) into $collect_dir"
}

# Initialize rollback helper script for this restore run.
init_rollback_script() {
  require_cmd chmod

  cat >"$ROLLBACK_FILE" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
# Generated rollback script for restore-serv run id: $RESTORE_ID
# Rollback commands are stored newest-first.
EOF
  chmod +x "$ROLLBACK_FILE"
}

# Finalize audit result for this restore run.
finalize_restore() {
  local exit_code="$1"

  if [[ "$exit_code" -ne 0 ]]; then
    RUN_RESULT="failed"
    audit_log "failed"
  elif [[ "$ACTION_FAILURE_COUNT" -gt 0 ]]; then
    RUN_RESULT="partial_failure"
    audit_log "completed_with_errors"
  else
    RUN_RESULT="success"
    audit_log "completed"
  fi
}

parse_common_args "$@"
if [[ "${SCRIPT_ARGS[0]:-}" == "-h" || "${SCRIPT_ARGS[0]:-}" == "--help" ]]; then
  usage
  exit 0
fi

init_log_file
preflight_checks

log "Restore source: $SCRIPT_DIR"
log "Service restore config: ${SERVICE_RESTORE_CONFIG:-built-in defaults}"
verify_backup_status
init_rollback_script
audit_log "started"
trap 'finalize_restore "$?"; cleanup_temp_paths; ui_cleanup' EXIT
log "Requesting root authentication"
sudo -v || die "sudo authentication failed"

# Keep showing menu until user selects Exit.
while true; do
  show_menu
  read -r -p "Enter selection: " selection

  # Dispatch menu options to their matching functions.
  case "$selection" in
  0)
    log "Exit selected"
    exit 0
    ;;
  1)
    run_menu_action "Create SMB" create_smb_tree
    ;;
  2)
    run_menu_action "Restore samba" restore_samba
    ;;
  3)
    run_menu_action "Restore SSH" restore_ssh
    ;;
  4)
    run_menu_action "Restore fstab" restore_fstab
    ;;
  5)
    run_menu_action "Restore grub theme" restore_grub_theme
    ;;
  6)
    run_menu_action "Restore GRUB" restore_grub_defaults
    ;;
  7)
    run_menu_action "Restore RAMBOX" restore_rambox
    ;;
  90)
    run_menu_action "Restore sharing profile" restore_sharing_profile
    ;;
  91)
    run_menu_action "Restore boot profile" restore_boot_profile
    ;;
  92)
    run_menu_action "Restore discovery services" restore_discovery_profile
    ;;
  93)
    run_menu_action "Restore smart-card service" restore_smartcard_profile
    ;;
  94)
    run_menu_action "Restore complete profile" restore_complete_profile
    ;;
  98)
    run_menu_action "Collect pre-restore" collect_pre_restore false
    ;;
  *)
    log_warn "invalid selection: $selection"
    ;;
  esac
done
