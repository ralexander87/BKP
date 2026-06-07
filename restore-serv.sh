#!/usr/bin/env bash

# Exit on errors, unset variables, and failed pipeline commands.
set -Eeuo pipefail

# Service restore runs from the backup folder where this script is located.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore-serv.log}"
RESTORE_ID="$(date '+%j-%d-%m-%H-%M-%S')"
AUDIT_FILE="$SCRIPT_DIR/restore-serv-audit.log"
ROLLBACK_FILE="$SCRIPT_DIR/restore-serv-rollback-$RESTORE_ID.sh"
RUN_RESULT="failed"
CURRENT_ACTION="none"
STATUS_FILE="$SCRIPT_DIR/backup.status"

# Write a timestamped message to screen and log file.
log() {
  printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"
}

# Record structured audit entries for this restore run.
audit_log() {
  local event="$1"
  printf '%s event=%s action=%s result=%s rollback=%s\n' "$(date -Is)" "$event" "$CURRENT_ACTION" "$RUN_RESULT" "$ROLLBACK_FILE" >>"$AUDIT_FILE"
}

# Log an error and stop the script.
die() {
  log "ERROR: $*"
  exit 1
}

# Ensure an external command exists before it is needed.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Ask a yes/no question; pressing Enter uses the provided default.
confirm_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer

  read -r -p "$prompt [$default]: " answer
  answer="${answer:-$default}"

  [[ "$answer" =~ ^[Yy]$ ]]
}

# Confirm an action before it changes local configuration.
confirm_action() {
  local label="$1"

  CURRENT_ACTION="$label"
  confirm_yes_no "Start $label?" "N" || {
    RUN_RESULT="cancelled"
    audit_log "cancelled"
    log "$label cancelled"
    exit 0
  }

  audit_log "action_started"
}

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./restore-serv.sh

Restore backed-up service files from the current folder to their system paths.
Root privileges are required.
EOF
}

# Show currently available service restore actions.
show_menu() {
  cat <<'EOF'
Select action:
  0 - Exit
  1 - Restore grub theme
  2 - Restore samba
  3 - Restore SSH
  4 - Create SMB
  5 - Restore fstab
  6 - Restore GRUB
EOF
}

# Ensure backup finished cleanly before allowing restore actions.
verify_backup_status() {
  [[ -f "$STATUS_FILE" ]] || die "backup status file not found: $STATUS_FILE"
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
  sudo rsync -aAXH --numeric-ids --info=progress2 "$source_file" "$target_dir/"
}

# Snapshot target path before modifying it and register rollback command.
snapshot_target() {
  local target="$1"
  local snapshot="$target-pre-restore-$RESTORE_ID"

  [[ -e "$target" ]] || return
  [[ ! -e "$snapshot" ]] || die "snapshot already exists: $snapshot"

  log "Creating snapshot: $target -> $snapshot"
  sudo cp -a "$target" "$snapshot"
  printf 'sudo rm -rf -- %q\n' "$target" >>"$ROLLBACK_FILE"
  printf 'sudo cp -a %q %q\n' "$snapshot" "$target" >>"$ROLLBACK_FILE"
}

# Restore the lateralus grub theme folder into /boot/grub/themes/.
restore_grub_theme() {
  local source_dir="$SCRIPT_DIR/lateralus"
  local target_dir="/boot/grub/themes/lateralus"

  [[ -d "$source_dir" ]] || die "grub theme source folder not found: $source_dir"

  confirm_action "Restore grub theme"
  snapshot_target "$target_dir"
  log "Restoring grub theme: $source_dir -> /boot/grub/themes/"
  sudo mkdir -p "$target_dir"
  sudo rsync -aAXH --numeric-ids --info=progress2 "$source_dir/" "$target_dir/"

  if command -v grub-script-check >/dev/null 2>&1; then
    sudo grub-script-check "$target_dir/theme.txt" >/dev/null 2>&1 || die "grub theme validation failed"
  fi

  audit_log "action_completed"
  log "Done: Restore grub theme"
}

# Restore samba smb.conf and creds-* files into /etc/samba/.
restore_samba() {
  local source_smb="smb.conf"
  local source_samba_dir="$SCRIPT_DIR"
  local target_dir="/etc/samba"
  local -a creds_files=()
  local creds_file

  confirm_action "Restore samba"
  snapshot_target "/etc/samba/smb.conf"
  restore_file_to_dir "samba" "$source_smb" "$target_dir"

  shopt -s nullglob
  creds_files=("$source_samba_dir"/creds-*)
  shopt -u nullglob

  if [[ "${#creds_files[@]}" -eq 0 ]]; then
    log "No creds-* files found in backup: $source_samba_dir"
  else
    for creds_file in "${creds_files[@]}"; do
      log "Restoring samba creds file: $(basename -- "$creds_file") -> $target_dir"
      snapshot_target "$target_dir/$(basename -- "$creds_file")"
      sudo rsync -aAXH --numeric-ids --info=progress2 "$creds_file" "$target_dir/"
    done
  fi

  # Harden samba credential files after restore.
  shopt -s nullglob
  creds_files=("$target_dir"/creds-*)
  shopt -u nullglob
  for creds_file in "${creds_files[@]}"; do
    sudo chown root:root "$creds_file"
    sudo chmod 600 "$creds_file"
  done

  if command -v testparm >/dev/null 2>&1; then
    sudo testparm -s >/dev/null || die "samba config validation failed"
  fi

  audit_log "action_completed"
  log "Done: Restore samba"
}

# Restore sshd_config into /etc/ssh/.
restore_ssh() {
  confirm_action "Restore SSH"
  snapshot_target "/etc/ssh/sshd_config"
  restore_file_to_dir "SSH" "sshd_config" "/etc/ssh"
  sudo chown root:root /etc/ssh/sshd_config
  sudo chmod 600 /etc/ssh/sshd_config
  if command -v sshd >/dev/null 2>&1; then
    sudo sshd -t || die "sshd config validation failed"
  fi
  audit_log "action_completed"
  log "Done: Restore SSH"
}

# Create SMB folders and set ownership/perms for the local non-root user.
create_smb_tree() {
  local local_user="${SUDO_USER:-${USER:-}}"
  local dir
  local -a smb_dirs=(
    "/SMB"
    "/SMB/euclid"
    "/SMB/pneuma"
    "/SMB/lateralus"
    "/SMB/SCP"
    "/SMB/SCP/HDD-01"
    "/SMB/SCP/HDD-02"
    "/SMB/SCP/HDD-03"
  )

  [[ -n "$local_user" ]] || local_user="$(id -un)"
  [[ "$local_user" != "root" ]] || die "could not determine a non-root user for ownership"

  confirm_action "Create SMB"

  for dir in "${smb_dirs[@]}"; do
    log "Ensuring SMB directory: $dir"
    sudo mkdir -p "$dir"
    sudo chown "$local_user:$local_user" "$dir"
    sudo chmod 750 "$dir"
  done

  audit_log "action_completed"
  log "Done: Create SMB"
}

# Load cifs module and append SMB mount entries to /etc/fstab.
restore_fstab() {
  local line
  local -a new_lines=()
  local -a fstab_lines=(
    '//192.168.8.20/d   /SMB/euclid   cifs   _netdev,credentials=/etc/samba/creds-euclid,uid=1000,gid=1000   0 0'
    '//192.168.8.101/hd-01   /SMB/SCP/HDD-01   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0'
    '//192.168.8.101/hd-02   /SMB/SCP/HDD-02   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0'
    '//192.168.8.101/hd-03   /SMB/SCP/HDD-03   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0'
  )

  confirm_action "Restore fstab"
  snapshot_target "/etc/fstab"

  log "Loading cifs kernel module"
  sudo modprobe cifs

  for line in "${fstab_lines[@]}"; do
    if ! sudo grep -Fqx "$line" /etc/fstab; then
      new_lines+=("$line")
    fi
  done

  if [[ "${#new_lines[@]}" -eq 0 ]]; then
    log "All SMB fstab entries already exist; no append needed"
  else
    log "Appending missing SMB mount entries to /etc/fstab"
    sudo sh -c 'printf "\n" >> /etc/fstab'
    for line in "${new_lines[@]}"; do
      printf '%s\n' "$line" | sudo tee -a /etc/fstab >/dev/null
    done
  fi

  if command -v findmnt >/dev/null 2>&1; then
    sudo findmnt --verify >/dev/null || die "fstab validation failed"
  fi

  audit_log "action_completed"
  log "Done: Restore fstab"
}

# Update GRUB defaults in /etc/default/grub to the expected values.
restore_grub_defaults() {
  confirm_action "Restore GRUB"
  snapshot_target "/etc/default/grub"

  log "Updating GRUB config: /etc/default/grub"
  sudo sed -i -E \
    -e 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet splash"|' \
    -e 's|^GRUB_TERMINAL_INPUT=console|#GRUB_TERMINAL_INPUT=console|' \
    -e 's|^#?GRUB_TERMINAL_OUTPUT=.*|GRUB_TERMINAL_OUTPUT=gfxterm|' \
    -e 's|^GRUB_GFXMODE=.*|GRUB_GFXMODE=1440x1080x32|' \
    -e 's|^#GRUB_THEME="/path/to/gfxtheme"|GRUB_THEME="/boot/grub/themes/lateralus/theme.txt"|' \
    /etc/default/grub

  sudo grep -q '^GRUB_THEME="/boot/grub/themes/lateralus/theme.txt"' /etc/default/grub || die "grub theme line validation failed"
  audit_log "action_completed"
  log "Done: Restore GRUB"
}

# Initialize rollback helper script for this restore run.
init_rollback_script() {
  cat >"$ROLLBACK_FILE" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
# Generated rollback script for restore-serv run id: $RESTORE_ID
EOF
  chmod +x "$ROLLBACK_FILE"
}

# Finalize audit result for this restore run.
finalize_restore() {
  local exit_code="$1"

  if [[ "$RUN_RESULT" == "cancelled" ]]; then
    return
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    RUN_RESULT="success"
    audit_log "completed"
  else
    RUN_RESULT="failed"
    audit_log "failed"
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd rsync
require_cmd sudo

log "Restore source: $SCRIPT_DIR"
verify_backup_status
init_rollback_script
audit_log "started"
trap 'finalize_restore $?' EXIT
log "Requesting root authentication"
sudo -v || die "sudo authentication failed"

# Read the user's menu selection and run the selected action.
show_menu
read -r -p "Enter selection: " selection

# Dispatch menu options to their matching functions.
case "$selection" in
  0)
    log "Exit selected"
    exit 0
    ;;
  1)
    restore_grub_theme
    ;;
  2)
    restore_samba
    ;;
  3)
    restore_ssh
    ;;
  4)
    create_smb_tree
    ;;
  5)
    restore_fstab
    ;;
  6)
    restore_grub_defaults
    ;;
  *)
    die "invalid selection: $selection"
    ;;
esac
