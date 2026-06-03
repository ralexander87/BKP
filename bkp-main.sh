#!/usr/bin/env bash

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

LOG_FILE="$LOG_ROOT/bkp-main.log"

usage() {
  cat <<'EOF'
Usage: ./bkp-main.sh

Back up selected $HOME folders to an external mounted device.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ensure_dirs
require_cmd rsync

DEST_DEVICE="$(select_external_mount "Select backup destination device:")"
MAIN_DIR="$DEST_DEVICE/MAIN"
RUN_ID="BKP-$(timestamp)"
BACKUP_DIR="$MAIN_DIR/$RUN_ID"
ARCHIVE_NAME="$MAIN_DIR/$RUN_ID.tar.gz"

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

RSYNC_ARGS=(
  -aAXHv
  --numeric-ids
  --relative
  --exclude='*.iso'
  --exclude='.ssh/agent/'
  --exclude='agent/'
)

mkdir -p "$BACKUP_DIR"
log "Backup destination: $BACKUP_DIR"

for item in "${HOME_ITEMS[@]}"; do
  source_path="$HOME/$item"

  if [[ -e "$source_path" ]]; then
    log "Backing up: $source_path"
    rsync "${RSYNC_ARGS[@]}" "$source_path" "$BACKUP_DIR/"
  else
    log "Skipping missing path: $source_path"
  fi
done

if confirm_yes_no "Create compressed .tar.gz archive with pigz?" "N"; then
  require_cmd tar
  require_cmd pigz

  log "Creating archive: $ARCHIVE_NAME"
  tar -C "$MAIN_DIR" -cf - "$RUN_ID" | pigz >"$ARCHIVE_NAME"
  log "Archive created: $ARCHIVE_NAME"
else
  log "Archive skipped"
fi

log "Done: bkp-main"
