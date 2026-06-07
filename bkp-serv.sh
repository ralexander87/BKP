#!/usr/bin/env bash

# Load shared helpers for logging, prompts, mount selection, and timestamps.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Service backup log file. LOG_ROOT is defined by lib/common.sh.
LOG_FILE="$LOG_ROOT/bkp-serv.log"
AUDIT_FILE=""
BACKUP_STATUS_FILE=""
BACKUP_COMPLETE=false
RUN_RESULT="failed"
LUKS_DEVICE_PATH=""
LUKS_HEADER_FILE="luks.bin"
LUKS_HEADER_CREATED=false

# Fixed critical service files/folders for this backup profile.
SERVICE_PATHS=(
  "/etc/samba/smb.conf"
  "/etc/ssh/sshd_config"
  "/boot/grub/themes/lateralus"
  "/etc/default/grub"
  "/etc/mkinitcpio.conf"
)

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./bkp-serv.sh

Back up selected service files to an external mounted device.
Root privileges are required.
EOF
}

# Record structured audit entries for this backup run.
audit_log() {
  local event="$1"
  [[ -n "$AUDIT_FILE" ]] || return
  printf '%s event=%s backup_dir=%s result=%s\n' "$(date -Is)" "$event" "$BACKUP_DIR" "$RUN_RESULT" >>"$AUDIT_FILE"
}

# Ensure this host can run backup safely before writing destination data.
preflight_checks() {
  local path

  require_cmd rsync
  require_cmd sudo
  require_cmd flock
  require_cmd findmnt
  require_cmd df
  require_cmd du
  require_cmd cryptsetup

  for path in "${SERVICE_PATHS[@]}"; do
    sudo test -e "$path" || die "required source path missing: $path"
  done

  if ! sudo find /etc/samba -maxdepth 1 -type f -name 'creds*' | grep -q .; then
    log "WARNING: no /etc/samba/creds* files found"
  fi
}

# Estimate a path's size in bytes; missing paths count as zero.
path_size_bytes() {
  local path="$1"

  [[ -e "$path" ]] || {
    printf '0\n'
    return
  }

  sudo du -sb "$path" 2>/dev/null | awk '{ print $1 }'
}

# Estimate source size for selected service paths and samba creds* files.
estimate_backup_size_bytes() {
  local total=0
  local item size
  local -a creds_files=()

  for item in "${SERVICE_PATHS[@]}"; do
    size="$(path_size_bytes "$item")"
    total=$((total + size))
  done

  mapfile -t creds_files < <(sudo find /etc/samba -maxdepth 1 -type f -name 'creds*' 2>/dev/null || true)
  for item in "${creds_files[@]}"; do
    size="$(path_size_bytes "$item")"
    total=$((total + size))
  done

  printf '%s\n' "$total"
}

# Warn if the selected destination appears too small for the backup.
check_destination_space() {
  local destination="$1"
  local required available

  require_cmd df

  required="$(estimate_backup_size_bytes)"
  available="$(df -PB1 "$destination" | awk 'NR == 2 { print $4 }')"

  log "Estimated source size: $(human_bytes "$required")"
  log "Destination free space: $(human_bytes "$available")"

  if ((required > available)); then
    log "WARNING: estimated backup size is larger than available destination space"
    confirm_yes_no "Continue anyway?" "N" || die "backup cancelled because destination may be too small"
  fi
}

# Write backup metadata that helps identify what this run copied.
write_manifest() {
  local manifest="$BACKUP_DIR/backup-manifest.txt"
  local git_commit="unknown"

  if command -v git >/dev/null 2>&1; then
    git_commit="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
  fi

  {
    printf 'backup_type=serv\n'
    printf 'created_at=%s\n' "$(date -Is)"
    printf 'hostname=%s\n' "$(hostname)"
    printf 'user=%s\n' "${USER:-unknown}"
    printf 'project_root=%s\n' "$PROJECT_ROOT"
    printf 'git_commit=%s\n' "$git_commit"
    printf 'destination_device=%s\n' "$DEST_DEVICE"
    printf 'backup_dir=%s\n' "$BACKUP_DIR"
    printf 'archive_requested=%s\n' "$CREATE_ARCHIVE"
    printf 'run_result=%s\n' "$RUN_RESULT"
    printf 'luks_device=%s\n' "$LUKS_DEVICE_PATH"
    printf 'luks_header_file=%s\n' "$LUKS_HEADER_FILE"
    printf 'luks_header_created=%s\n' "$LUKS_HEADER_CREATED"
    printf 'service_paths=%s\n' "${SERVICE_PATHS[*]}"
    printf 'samba_creds_glob=%s\n' "/etc/samba/creds*"
  } >"$manifest"

  log "Wrote manifest: $manifest"
}

# Copy one path into the backup root as a standalone file/folder.
backup_path() {
  local source_path="$1"
  local base_name

  if [[ -e "$source_path" ]]; then
    base_name="$(basename -- "$source_path")"
    log "Backing up: $source_path"

    if [[ -d "$source_path" ]]; then
      sudo rsync -aAXH --numeric-ids --info=progress2 "$source_path/" "$BACKUP_DIR/$base_name/"
    else
      sudo rsync -aAXH --numeric-ids --info=progress2 "$source_path" "$BACKUP_DIR/"
    fi
  else
    log "Skipping missing path: $source_path"
  fi
}

# Resolve the device that holds the LUKS header (supports mapper roots).
detect_luks_device() {
  local root_source candidate pkname

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

  pkname="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n 1)"
  if [[ -n "$pkname" ]]; then
    candidate="/dev/$pkname"
    if sudo cryptsetup isLuks "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return
    fi
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
      log "WARNING: skipping LUKS header backup (no LUKS source detected)"
      return
    }
  fi

  LUKS_DEVICE_PATH="$detected"
  log "Backing up LUKS header from: $LUKS_DEVICE_PATH"
  sudo cryptsetup luksHeaderBackup "$LUKS_DEVICE_PATH" --header-backup-file "$BACKUP_DIR/$LUKS_HEADER_FILE"
  LUKS_HEADER_CREATED=true
  log "Saved LUKS header backup: $BACKUP_DIR/$LUKS_HEADER_FILE"
}

# Ensure destination mount is still writable before backup begins.
verify_destination_mount() {
  findmnt -rn --target "$DEST_DEVICE" >/dev/null 2>&1 || die "destination is not mounted: $DEST_DEVICE"
  [[ -w "$DEST_DEVICE" ]] || die "destination is not writable: $DEST_DEVICE"
}

# Mark backup status for restore-side safety checks.
set_backup_status() {
  local status="$1"
  printf '%s\n' "$status" >"$BACKUP_STATUS_FILE"
}

# Verify expected standalone backup content exists before marking complete.
verify_backup_contents() {
  local required_item
  local -a required_items=(
    "smb.conf"
    "sshd_config"
    "lateralus"
    "grub"
    "mkinitcpio.conf"
    "restore-serv.sh"
    "backup-manifest.txt"
  )

  for required_item in "${required_items[@]}"; do
    [[ -e "$BACKUP_DIR/$required_item" ]] || die "missing expected backup item: $required_item"
  done

  if [[ "$LUKS_HEADER_CREATED" == "true" ]]; then
    [[ -f "$BACKUP_DIR/$LUKS_HEADER_FILE" ]] || die "missing expected backup item: $LUKS_HEADER_FILE"
  fi
}

# Finalize backup status even on failure.
finalize_status() {
  local exit_code="$1"

  if [[ -n "$BACKUP_STATUS_FILE" && -d "$BACKUP_DIR" ]]; then
    if [[ "$BACKUP_COMPLETE" == "true" && "$exit_code" -eq 0 ]]; then
      RUN_RESULT="success"
      set_backup_status "complete"
      audit_log "completed"
    else
      RUN_RESULT="failed"
      set_backup_status "failed"
      audit_log "failed"
    fi
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Prepare runtime folders and required commands.
ensure_dirs
preflight_checks

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
check_destination_space "$DEST_DEVICE"
verify_destination_mount

mkdir -p "$BACKUP_DIR"
log "Backup destination: $BACKUP_DIR"
AUDIT_FILE="$BACKUP_DIR/backup-audit.log"
BACKUP_STATUS_FILE="$BACKUP_DIR/backup.status"
RUN_RESULT="in_progress"
set_backup_status "in_progress"
audit_log "started"
trap 'finalize_status $?' EXIT

# Back up fixed service paths.
for path in "${SERVICE_PATHS[@]}"; do
  backup_path "$path"
done

# Back up all samba creds* files.
while IFS= read -r creds_file; do
  backup_path "$creds_file"
done < <(sudo find /etc/samba -maxdepth 1 -type f -name 'creds*' 2>/dev/null || true)

# Store the portable service restore script inside the backup folder.
install -m 0755 "$PROJECT_ROOT/restore-serv.sh" "$BACKUP_DIR/restore-serv.sh"
log "Copied restore script: $BACKUP_DIR/restore-serv.sh"

# Back up LUKS header into luks.bin in this backup folder.
backup_luks_header

# Add a manifest to the backup before optional compression.
write_manifest
verify_backup_contents

# Compress the finished backup folder only if selected at startup.
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  log "Creating archive: $ARCHIVE_NAME"
  sudo tar -C "$SERV_DIR" -cf - "$RUN_ID" | pigz | sudo tee "$ARCHIVE_NAME" >/dev/null
  log "Archive created: $ARCHIVE_NAME"
else
  log "Archive skipped"
fi

BACKUP_COMPLETE=true
log "Done: bkp-serv"
