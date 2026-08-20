#!/usr/bin/env bash

# Load shared helpers for logging, prompts, mount selection, and timestamps.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Unified backup log file. LOG_ROOT is defined by lib/common.sh.
LOG_FILE="$LOG_ROOT/bkp.log"
UI_BACKUP_LABEL=SERVICE
BACKUP_COMPLETE=false
RUN_RESULT="failed"
LUKS_DEVICE_PATH=""
LUKS_HEADER_FILE="luks.bin"
LUKS_HEADER_CREATED=false
MANIFEST_FILE=""

# Service paths required for a complete restore profile.
SERVICE_REQUIRED_PATHS=(
  "/etc/samba/smb.conf"
  "/etc/ssh/sshd_config"
  "/etc/default/grub"
  "/etc/mkinitcpio.conf"
)

# Service paths that are backed up when present, but do not block a run.
SERVICE_OPTIONAL_PATHS=(
  "/boot/grub/themes/lateralus"
)

SERVICE_PATHS=("${SERVICE_REQUIRED_PATHS[@]}" "${SERVICE_OPTIONAL_PATHS[@]}")

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./bkp-serv.sh [--quiet]

Back up selected service files to an external mounted device.
Root privileges are required.
EOF
}

# Record structured audit entries for this backup run.
audit_log() {
  local event="$1"
  log "AUDIT event=$event backup_dir=$BACKUP_DIR result=$RUN_RESULT"
}

# Ensure this host can run backup safely before writing destination data.
preflight_checks() {
  local path

  require_all_cmds rsync sudo flock findmnt df du cryptsetup install lsblk

  for path in "${SERVICE_REQUIRED_PATHS[@]}"; do
    sudo test -e "$path" || die "required source path missing: $path"
  done

  if ! sudo find /etc/samba -maxdepth 1 -type f -name 'creds-*' | grep -q .; then
    log_warn "no /etc/samba/creds-* files found"
  fi
}

# Estimate source size for selected service paths and samba creds-* files.
estimate_backup_size_bytes() {
  local total=0
  local item size
  local -a creds_files=()

  for item in "${SERVICE_PATHS[@]}"; do
    size="$(sudo_path_size_bytes "$item")"
    total=$((total + size))
  done

  mapfile -t creds_files < <(sudo find /etc/samba -maxdepth 1 -type f -name 'creds-*' 2>/dev/null || true)
  for item in "${creds_files[@]}"; do
    size="$(sudo_path_size_bytes "$item")"
    total=$((total + size))
  done

  printf '%s\n' "$total"
}

# Write backup metadata that helps identify what this run copied.
write_manifest() {
  local manifest="$BACKUP_DIR/backup-manifest.txt"

  {
    write_common_manifest_fields "serv"
    manifest_field "LUKS Device" "$LUKS_DEVICE_PATH"
    manifest_field "LUKS Header File" "$LUKS_HEADER_FILE"
    manifest_field "LUKS Header Created" "$(manifest_bool "$LUKS_HEADER_CREATED")"
    manifest_field "Service Restore Config" "$PROJECT_ROOT/config/serv.restore.conf"
    manifest_field "Local Service Restore Config" "$(manifest_presence "$([[ -f "$PROJECT_ROOT/config/local/serv.restore.conf" ]] && printf 'present' || printf 'missing')")"
    manifest_field "Required Service Paths" "${SERVICE_REQUIRED_PATHS[*]}"
    manifest_field "Optional Service Paths" "${SERVICE_OPTIONAL_PATHS[*]}"
    manifest_field "Service Paths" "${SERVICE_PATHS[*]}"
    manifest_field "Samba Creds Glob" "/etc/samba/creds-*"
  } >"$manifest"

  MANIFEST_FILE="$manifest"
  log "Wrote manifest: $manifest"
}

# Copy one path into the backup root as a standalone file/folder.
backup_path() {
  local task_id="$1"
  local source_path="$2"
  local base_name

  if sudo test -e "$source_path"; then
    base_name="$(basename -- "$source_path")"
    log "Backing up: $source_path"
    ui_update_task "$task_id" "RUNNING" "copying $source_path"
    ui_render

    if sudo test -d "$source_path"; then
      sudo_rsync_backup_copy "$source_path/" "$BACKUP_DIR/$base_name/"
    else
      sudo_rsync_backup_copy "$source_path" "$BACKUP_DIR/"
    fi
    ui_update_task "$task_id" "DONE" "No Error"
    ui_render
  else
    log "Skipping missing path: $source_path"
    ui_update_task "$task_id" "SKIPPED" "missing path"
    ui_render
  fi
}

# Resolve the device that holds the LUKS header (supports mapper roots).
detect_luks_device() {
  local root_source candidate pkname current mapper_name mapped_device
  local -a luks_devices=()

  if [[ -n "${LUKS_DEVICE:-}" ]]; then
    sudo cryptsetup isLuks "$LUKS_DEVICE" >/dev/null 2>&1 || die "LUKS_DEVICE is not a LUKS device: $LUKS_DEVICE"
    printf '%s\n' "$LUKS_DEVICE"
    return
  fi

  root_source="$(findmnt -rn -o SOURCE --target /)"
  [[ -n "$root_source" ]] || die "could not determine root source for LUKS detection"

  if sudo cryptsetup isLuks "$root_source" >/dev/null 2>&1; then
    printf '%s\n' "$root_source"
    return
  fi

  # Resolve mapper devices via "cryptsetup status" to find the backing block device.
  if [[ "$root_source" == /dev/mapper/* ]]; then
    mapper_name="$(basename -- "$root_source")"
    mapped_device="$(sudo cryptsetup status "$mapper_name" 2>/dev/null | awk -F': *' '/^[[:space:]]*device:/ { print $2; exit }')"
    if [[ -n "$mapped_device" ]] && sudo cryptsetup isLuks "$mapped_device" >/dev/null 2>&1; then
      printf '%s\n' "$mapped_device"
      return 0
    fi
  fi

  # Walk up the parent device chain (dm -> partition -> disk) and find first LUKS device.
  current="$root_source"
  for _ in {1..8}; do
    pkname="$(lsblk -no PKNAME "$current" 2>/dev/null | head -n 1)"
    [[ -n "$pkname" ]] || break
    candidate="/dev/$pkname"
    if sudo cryptsetup isLuks "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return
    fi
    current="$candidate"
  done

  # Fallback: detect devices with crypto_LUKS filesystem type.
  mapfile -t luks_devices < <(lsblk -pnro NAME,FSTYPE | awk '$2 == "crypto_LUKS" { print $1 }')
  if [[ "${#luks_devices[@]}" -eq 1 ]]; then
    printf '%s\n' "${luks_devices[0]}"
    return
  fi

  if [[ "${#luks_devices[@]}" -gt 1 ]]; then
    log_warn "multiple LUKS devices detected: ${luks_devices[*]}"
    log_warn "set LUKS_DEVICE=/dev/<device> to choose one"
  fi

  return 1
}

# Back up LUKS header into the current service backup folder as luks.bin.
backup_luks_header() {
  local detected

  if [[ -n "${LUKS_DEVICE:-}" ]]; then
    detected="$(detect_luks_device)" || die "LUKS_DEVICE is set but not usable: $LUKS_DEVICE"
  else
    detected="$(detect_luks_device)" || {
      log_warn "skipping LUKS header backup (no LUKS source detected)"
      return
    }
  fi

  LUKS_DEVICE_PATH="$detected"
  log "Backing up LUKS header from: $LUKS_DEVICE_PATH"
  ui_update_task "serv-luks" "RUNNING" "reading header from $LUKS_DEVICE_PATH"
  ui_render
  sudo cryptsetup luksHeaderBackup "$LUKS_DEVICE_PATH" --header-backup-file "$BACKUP_DIR/$LUKS_HEADER_FILE"
  LUKS_HEADER_CREATED=true
  log "Saved LUKS header backup: $BACKUP_DIR/$LUKS_HEADER_FILE"
  ui_update_task "serv-luks" "DONE" "SAVED: $LUKS_HEADER_FILE"
  ui_render
}

# Ensure destination mount is still writable before backup begins.
verify_destination_mount() {
  findmnt -rn --target "$DEST_DEVICE" >/dev/null 2>&1 || die "destination is not mounted: $DEST_DEVICE"
  [[ -w "$DEST_DEVICE" ]] || die "destination is not writable: $DEST_DEVICE"
}

# Verify expected standalone backup content exists before marking complete.
verify_backup_contents() {
  local required_item
  local -a required_items=(
    "smb.conf"
    "sshd_config"
    "grub"
    "mkinitcpio.conf"
    "restore-serv.sh"
    "lib/common.sh"
    "config/serv.restore.conf"
    "backup-manifest.txt"
  )

  for required_item in "${required_items[@]}"; do
    [[ -e "$BACKUP_DIR/$required_item" ]] || die "missing expected backup item: $required_item"
  done

  if sudo test -e "/boot/grub/themes/lateralus"; then
    [[ -e "$BACKUP_DIR/lateralus" ]] || die "missing expected backup item: lateralus"
  fi

  if [[ -f "$PROJECT_ROOT/config/local/serv.restore.conf" ]]; then
    [[ -f "$BACKUP_DIR/config/local/serv.restore.conf" ]] || die "missing expected backup item: config/local/serv.restore.conf"
  fi

  if [[ "$LUKS_HEADER_CREATED" == "true" ]]; then
    [[ -f "$BACKUP_DIR/$LUKS_HEADER_FILE" ]] || die "missing expected backup item: $LUKS_HEADER_FILE"
  fi
}

# Finalize backup status even on failure.
finalize_status() {
  local exit_code="$1"

  if [[ -d "$BACKUP_DIR" ]]; then
    set_backup_status "$(backup_final_status "$exit_code")"
    if [[ "$RUN_RESULT" == "complete" ]]; then
      audit_log "completed"
    else
      ui_finalize "FAILED" "${UI_LAST_ERROR_TEXT:-Service backup failed.}"
      ui_append_final_status "$MANIFEST_FILE"
      audit_log "failed"
    fi
  fi
}

parse_common_args "$@"
if [[ "${SCRIPT_ARGS[0]:-}" == "-h" || "${SCRIPT_ARGS[0]:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Prepare runtime folders and required commands.
ensure_dirs
preflight_checks
trap 'ui_report_error "$LINENO" "$BASH_COMMAND"' ERR

# Prevent two service backups from running at the same time.
LOCK_FILE="$LOG_ROOT/bkp-serv.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || die "another bkp-serv.sh run is already active"

# Ask for sudo auth up front to avoid mid-backup prompts.
log "Requesting root authentication"
sudo -v || die "sudo authentication failed"

# Ask the user which external mounted device should receive the backup.
DEST_DEVICE="$(select_external_mount "Select backup destination device:")"

# Build the backup folder names and archive path for this run.
SERV_DIR="$DEST_DEVICE/SERV"
RUN_ID="BKP-$(timestamp)"
BACKUP_DIR="$SERV_DIR/$RUN_ID"
ARCHIVE_NAME="$SERV_DIR/$RUN_ID.tar.gz"
CREATE_ARCHIVE=false

# Ask for archive creation before copying starts so required tools fail early.
if confirm_yes_no "Create compressed .tar.gz archive with pigz after backup?" "N"; then
  require_cmd tar
  require_cmd pigz
  CREATE_ARCHIVE=true
fi
log "Archive selection: $CREATE_ARCHIVE"

# Check destination free space before creating the backup folder.
check_destination_space_for_size "$DEST_DEVICE" "$(estimate_backup_size_bytes)"
verify_destination_mount

mkdir -p "$BACKUP_DIR"
log "Backup destination: $BACKUP_DIR"
trap 'finalize_status "$?"; cleanup_temp_paths; ui_cleanup' EXIT
set_backup_status "in_progress"
audit_log "started"

# Start terminal dashboard for visual progress and selected options.
ui_init
ui_add_meta "Destination" "/SERV/$RUN_ID"
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  ui_add_meta "Archive" "YES"
else
  ui_add_meta "Archive" "NO"
fi
if [[ -n "${LUKS_DEVICE:-}" ]]; then
  ui_add_meta "LUKS Device" "YES [$LUKS_DEVICE]"
else
  ui_add_meta "LUKS Device" "YES [Auto-Detect]"
fi
ui_add_task "serv-smbconf" "SMB config"
ui_add_task "serv-sshd" "SSH config"
ui_add_task "serv-theme" "GRUB theme lateralus"
ui_add_task "serv-grub" "Default GRUB config"
ui_add_task "serv-mkinitcpio" "Mkinitcpio config"
ui_add_task "serv-creds" "Samba creds-*"
ui_add_task_separator_after "serv-creds" "Post Backup"
ui_add_task "serv-restore-script" "Copy restore-serv.sh"
ui_add_task "serv-luks" "Backup luks.bin"
ui_add_task "serv-manifest" "Write manifest"
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  ui_add_task "serv-archive" "Create archive"
  ui_add_task_separator_after "serv-archive"
else
  ui_add_task_separator_after "serv-manifest"
fi
ui_render "force"

# Back up fixed service paths.
backup_path "serv-smbconf" "/etc/samba/smb.conf"
backup_path "serv-sshd" "/etc/ssh/sshd_config"
backup_path "serv-theme" "/boot/grub/themes/lateralus"
backup_path "serv-grub" "/etc/default/grub"
backup_path "serv-mkinitcpio" "/etc/mkinitcpio.conf"

# Back up all samba creds-* files.
ui_update_task "serv-creds" "RUNNING" "scanning /etc/samba/creds-*"
ui_render
creds_found=false
while IFS= read -r creds_file; do
  [[ -n "$creds_file" ]] || continue
  creds_found=true
  backup_path "serv-creds" "$creds_file"
done < <(sudo find /etc/samba -maxdepth 1 -type f -name 'creds-*' 2>/dev/null || true)
if [[ "$creds_found" == "false" ]]; then
  ui_update_task "serv-creds" "SKIPPED" "no creds-* files found"
  ui_render
else
  ui_update_task "serv-creds" "DONE" "No Error"
  ui_render
fi

# Store the portable service restore script inside the backup folder.
ui_update_task "serv-restore-script" "RUNNING" "copying restore-serv.sh"
ui_render
install -m 0755 "$PROJECT_ROOT/restore-serv.sh" "$BACKUP_DIR/restore-serv.sh"
mkdir -p "$BACKUP_DIR/lib"
install -m 0644 "$PROJECT_ROOT/lib/common.sh" "$BACKUP_DIR/lib/common.sh"
mkdir -p "$BACKUP_DIR/config"
install -m 0644 "$PROJECT_ROOT/config/serv.restore.conf" "$BACKUP_DIR/config/serv.restore.conf"
if [[ -f "$PROJECT_ROOT/config/local/serv.restore.conf" ]]; then
  mkdir -p "$BACKUP_DIR/config/local"
  install -m 0600 "$PROJECT_ROOT/config/local/serv.restore.conf" "$BACKUP_DIR/config/local/serv.restore.conf"
  log "Copied local service restore config: $BACKUP_DIR/config/local/serv.restore.conf"
fi
log "Copied restore script: $BACKUP_DIR/restore-serv.sh"
ui_update_task "serv-restore-script" "DONE" "COPIED"
ui_render

# Back up LUKS header into luks.bin in this backup folder.
backup_luks_header
if [[ "$LUKS_HEADER_CREATED" != "true" ]]; then
  ui_update_task "serv-luks" "SKIPPED" "no luks source detected"
  ui_render
fi

# Add a manifest to the backup before optional compression.
ui_update_task "serv-manifest" "RUNNING" "writing manifest"
ui_render
set_backup_status "complete"
verify_backup_contents
BACKUP_COMPLETE=true
ui_update_task "serv-manifest" "DONE" "WRITTEN"
ui_render

# Compress the finished backup folder only if selected at startup.
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  local_archive_tmp="$SERV_DIR/.${RUN_ID}.tar.gz"
  log "Creating archive: $ARCHIVE_NAME"
  ui_update_task "serv-archive" "RUNNING" "compressing backup"
  ui_render
  sudo tar -C "$SERV_DIR" -cf - "$RUN_ID" | pigz | sudo tee "$local_archive_tmp" >/dev/null
  sudo mv "$local_archive_tmp" "$ARCHIVE_NAME"
  log "Archive created: $ARCHIVE_NAME"
  ui_update_task "serv-archive" "DONE" "CREATED"
  ui_render "force"
else
  log "Archive skipped"
fi

log "Done: bkp-serv"
ui_add_message "INFO" "Backup finished successfully"
ui_finalize "SUCCESS" "All selected SERVICE backup tasks completed."
ui_append_final_status "$MANIFEST_FILE"
log_ui_final_status
