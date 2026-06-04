#!/usr/bin/env bash

# Exit on errors, unset variables, and failed pipeline commands.
set -Eeuo pipefail

# The restore source is always the folder where this script is located.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore-main.log}"

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
)

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

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./restore-main.sh

Restore backup content from the current folder to $HOME.
EOF
}

# Enforce SSH's strict permission expectations after restoring .ssh.
fix_ssh_permissions() {
  local ssh_dir="$HOME/.ssh"

  [[ -d "$ssh_dir" ]] || return

  log "Fixing SSH permissions"
  find "$ssh_dir" -type d -exec chmod 700 {} +
  find "$ssh_dir" -type f -name '*.pub' -exec chmod 644 {} +
  find "$ssh_dir" -type f ! -name '*.pub' -exec chmod 600 {} +
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd rsync
require_cmd find

# Show the restore source and target before asking for confirmation.
log "Restore source: $SCRIPT_DIR"
log "Restore target: $HOME"

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
    rsync -aAXH --numeric-ids --info=progress2 "$source_path" "$HOME/"
  else
    log "Skipping missing backup item: $item"
  fi
done

# Normalize SSH file modes after rsync completes.
fix_ssh_permissions
log "Done: restore-main"
