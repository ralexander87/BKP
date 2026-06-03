#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore-main.log}"

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

log() {
  printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

confirm_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer

  read -r -p "$prompt [$default]: " answer
  answer="${answer:-$default}"

  [[ "$answer" =~ ^[Yy]$ ]]
}

usage() {
  cat <<'EOF'
Usage: ./restore-main.sh

Restore backup content from the current folder to $HOME.
EOF
}

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

log "Restore source: $SCRIPT_DIR"
log "Restore target: $HOME"

if ! confirm_yes_no "Start restore from current folder to \$HOME?" "N"; then
  log "Restore cancelled"
  exit 0
fi

for item in "${HOME_ITEMS[@]}"; do
  source_path="$SCRIPT_DIR/$item"

  if [[ -e "$source_path" ]]; then
    log "Restoring: $item"
    rsync -aAXH --numeric-ids --info=progress2 "$source_path" "$HOME/"
  else
    log "Skipping missing backup item: $item"
  fi
done

fix_ssh_permissions
log "Done: restore-main"
