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
ARCHIVE_VALIDATION="not_requested"
SERV_BACKUP_CONFIG="$PROJECT_ROOT/config/serv.backup.conf"

# Load user-editable required and optional service source paths.
load_serv_backup_config() {
  [[ -f "$SERV_BACKUP_CONFIG" ]] || die "service backup config not found: $SERV_BACKUP_CONFIG"
  # shellcheck source=config/serv.backup.conf
  source "$SERV_BACKUP_CONFIG"
  SERVICE_PATHS=("${SERVICE_REQUIRED_PATHS[@]}" "${SERVICE_OPTIONAL_PATHS[@]}")
}

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

  require_all_cmds rsync sudo flock findmnt df du cryptsetup install lsblk mv

  for path in "${SERVICE_REQUIRED_PATHS[@]}"; do
    sudo test -e "$path" || die "required source path missing: $path"
  done

  if ! sudo find "$SAMBA_CONFIG_DIR" -maxdepth 1 -type f -name "$SAMBA_CREDS_PATTERN" | grep -q .; then
    log_warn "no $SAMBA_CREDS_GLOB files found"
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

  mapfile -t creds_files < <(sudo find "$SAMBA_CONFIG_DIR" -maxdepth 1 -type f -name "$SAMBA_CREDS_PATTERN" 2>/dev/null || true)
  for item in "${creds_files[@]}"; do
    size="$(sudo_path_size_bytes "$item")"
    total=$((total + size))
  done

  printf '%s\n' "$total"
}

# Write backup metadata that helps identify what this run copied.
write_manifest() {
  local manifest="$BACKUP_DIR/backup-manifest.txt"
  local json_manifest="$BACKUP_DIR/backup-manifest.json"
  local manifest_tmp="$manifest.tmp"
  local json_manifest_tmp="$json_manifest.tmp"

  register_temp_path "$manifest_tmp"
  register_temp_path "$json_manifest_tmp"

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
    manifest_field "Samba Creds Glob" "$SAMBA_CREDS_GLOB"
  } >"$manifest_tmp"

  {
    printf '{\n'
    write_common_manifest_json_fields "serv"
    json_string_field "luks_device" "$LUKS_DEVICE_PATH"
    json_string_field "luks_header_file" "$LUKS_HEADER_FILE"
    json_bool_field "luks_header_created" "$LUKS_HEADER_CREATED"
    json_string_field "service_restore_config" "$PROJECT_ROOT/config/serv.restore.conf"
    json_bool_field "local_service_restore_config" "$([[ -f "$PROJECT_ROOT/config/local/serv.restore.conf" ]] && printf 'true' || printf 'false')"
    json_raw_field "required_service_paths" "$(json_string_array "${SERVICE_REQUIRED_PATHS[@]}")"
    json_raw_field "optional_service_paths" "$(json_string_array "${SERVICE_OPTIONAL_PATHS[@]}")"
    json_string_field "samba_creds_glob" "$SAMBA_CREDS_GLOB" ""
    printf '}\n'
  } >"$json_manifest_tmp"

  mv -- "$manifest_tmp" "$manifest"
  mv -- "$json_manifest_tmp" "$json_manifest"

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
    "config/serv.backup.conf"
    "backup-manifest.txt"
    "backup-manifest.json"
  )

  for required_item in "${required_items[@]}"; do
    [[ -e "$BACKUP_DIR/$required_item" ]] || die "missing expected backup item: $required_item"
  done

  if sudo test -e "$GRUB_THEME_SOURCE"; then
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
    if [[ "$BACKUP_COMPLETE" != "true" || "$exit_code" -ne 0 ]]; then
      set_backup_status "failed"
      ui_finalize "FAILED" "${UI_LAST_ERROR_TEXT:-Service backup failed.}"
      ui_append_final_status "$MANIFEST_FILE"
      audit_log "failed"
    fi
  fi
}

# Publish a verified staging directory under its final BKP-* name.
promote_staged_backup() {
  [[ -d "$BACKUP_DIR" ]] || die "staging backup directory not found: $BACKUP_DIR"
  [[ ! -e "$FINAL_BACKUP_DIR" ]] || die "final backup directory already exists: $FINAL_BACKUP_DIR"

  mv -- "$BACKUP_DIR" "$FINAL_BACKUP_DIR"
  BACKUP_DIR="$FINAL_BACKUP_DIR"
  MANIFEST_FILE="$BACKUP_DIR/backup-manifest.txt"
  log "Published verified backup: $BACKUP_DIR"
}

# Create, validate, and atomically publish the optional service archive.
create_validated_archive() {
  local archive_tmp="$SERV_DIR/.${RUN_ID}.tar.gz.in-progress"

  register_temp_path "$archive_tmp"
  ARCHIVE_VALIDATION="pending"
  set_backup_status "in_progress"
  if ! sudo tar -C "$SERV_DIR" -cf - "$RUN_ID" | pigz >"$archive_tmp"; then
    ARCHIVE_VALIDATION="failed"
    set_backup_status "failed"
    die "archive creation failed: $ARCHIVE_NAME"
  fi
  if ! validate_tar_gz_archive "$archive_tmp"; then
    ARCHIVE_VALIDATION="failed"
    set_backup_status "failed"
    die "archive validation failed: $ARCHIVE_NAME"
  fi
  mv -- "$archive_tmp" "$ARCHIVE_NAME"
  ARCHIVE_VALIDATION="passed"
}

parse_common_args "$@"
if [[ "${SCRIPT_ARGS[0]:-}" == "-h" || "${SCRIPT_ARGS[0]:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Prepare runtime folders and required commands.
ensure_dirs
init_log_file
load_serv_backup_config
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
FINAL_BACKUP_DIR="$SERV_DIR/$RUN_ID"
BACKUP_DIR="$SERV_DIR/.${RUN_ID}.in-progress"
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

mkdir -p "$SERV_DIR"
[[ ! -e "$BACKUP_DIR" ]] || die "staging backup already exists: $BACKUP_DIR"
[[ ! -e "$FINAL_BACKUP_DIR" ]] || die "backup already exists: $FINAL_BACKUP_DIR"
mkdir "$BACKUP_DIR"
log "Backup staging destination: $BACKUP_DIR"
trap 'finalize_status "$?"; cleanup_temp_paths; ui_cleanup' EXIT
setup_signal_traps
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
backup_path "serv-smbconf" "$SMB_CONFIG_SOURCE"
backup_path "serv-sshd" "$SSH_CONFIG_SOURCE"
backup_path "serv-theme" "$GRUB_THEME_SOURCE"
backup_path "serv-grub" "$GRUB_DEFAULT_SOURCE"
backup_path "serv-mkinitcpio" "$MKINITCPIO_SOURCE"

# Back up all samba creds-* files.
ui_update_task "serv-creds" "RUNNING" "scanning $SAMBA_CREDS_GLOB"
ui_render
creds_found=false
while IFS= read -r creds_file; do
  [[ -n "$creds_file" ]] || continue
  creds_found=true
  backup_path "serv-creds" "$creds_file"
done < <(sudo find "$SAMBA_CONFIG_DIR" -maxdepth 1 -type f -name "$SAMBA_CREDS_PATTERN" 2>/dev/null || true)
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
install -m 0644 "$SERV_BACKUP_CONFIG" "$BACKUP_DIR/config/serv.backup.conf"
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

# Verify and publish the staged backup before optional compression.
ui_update_task "serv-manifest" "RUNNING" "writing manifest"
ui_render
set_backup_status "in_progress"
verify_backup_contents
promote_staged_backup

# Compress the finished backup folder only if selected at startup.
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  log "Creating archive: $ARCHIVE_NAME"
  ui_update_task "serv-archive" "RUNNING" "compressing backup"
  ui_render
  create_validated_archive
  log "Archive created and validated: $ARCHIVE_NAME"
  ui_update_task "serv-archive" "DONE" "VALIDATED"
  ui_render "force"
else
  log "Archive skipped"
fi

set_backup_status "complete"
verify_backup_contents
BACKUP_COMPLETE=true
ui_update_task "serv-manifest" "DONE" "WRITTEN"
ui_render

log "Done: bkp-serv"
ui_add_message "INFO" "Backup finished successfully"
ui_finalize "SUCCESS" "All selected SERVICE backup tasks completed."
ui_append_final_status "$MANIFEST_FILE"
audit_log "completed"
log_ui_final_status
