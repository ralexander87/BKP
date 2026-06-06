#!/usr/bin/env bash

# Exit on errors, unset variables, and failed pipeline commands.
set -Eeuo pipefail

# Service restore runs from the backup folder where this script is located.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore-serv.log}"

# Write a timestamped message to screen and log file.
log() {
  printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"
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

  confirm_yes_no "Start $label?" "N" || {
    log "$label cancelled"
    exit 0
  }
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
EOF
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

# Restore the lateralus grub theme folder into /boot/grub/themes/.
restore_grub_theme() {
  local source_dir="$SCRIPT_DIR/lateralus"
  local target_dir="/boot/grub/themes/lateralus"

  [[ -d "$source_dir" ]] || die "grub theme source folder not found: $source_dir"

  confirm_action "Restore grub theme"
  log "Restoring grub theme: $source_dir -> /boot/grub/themes/"
  sudo mkdir -p "$target_dir"
  sudo rsync -aAXH --numeric-ids --info=progress2 "$source_dir/" "$target_dir/"
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
  restore_file_to_dir "samba" "$source_smb" "$target_dir"

  shopt -s nullglob
  creds_files=("$source_samba_dir"/creds-*)
  shopt -u nullglob

  if [[ "${#creds_files[@]}" -eq 0 ]]; then
    log "No creds-* files found in backup: $source_samba_dir"
  else
    for creds_file in "${creds_files[@]}"; do
      log "Restoring samba creds file: $(basename -- "$creds_file") -> $target_dir"
      sudo rsync -aAXH --numeric-ids --info=progress2 "$creds_file" "$target_dir/"
    done
  fi

  log "Done: Restore samba"
}

# Restore sshd_config into /etc/ssh/.
restore_ssh() {
  confirm_action "Restore SSH"
  restore_file_to_dir "SSH" "sshd_config" "/etc/ssh"
  log "Done: Restore SSH"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd rsync
require_cmd sudo

log "Restore source: $SCRIPT_DIR"
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
  *)
    die "invalid selection: $selection"
    ;;
esac
