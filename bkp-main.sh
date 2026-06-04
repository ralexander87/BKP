#!/usr/bin/env bash

# Load shared helpers for logging, prompts, mount selection, and timestamps.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Main backup log file. LOG_ROOT is defined by lib/common.sh.
LOG_FILE="$LOG_ROOT/bkp-main.log"

# Print command usage for help requests.
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

# Prepare local runtime folders and verify the main copy tool exists.
ensure_dirs
require_cmd rsync

# Ask the user which external mounted device should receive the backup.
DEST_DEVICE="$(select_external_mount "Select backup destination device:")"

# Build the backup folder names and archive path for this run.
MAIN_DIR="$DEST_DEVICE/MAIN"
RUN_ID="BKP-$(timestamp)"
BACKUP_DIR="$MAIN_DIR/$RUN_ID"
ARCHIVE_NAME="$MAIN_DIR/$RUN_ID.tar.gz"
CREATE_ARCHIVE=false

# Dotfiles source is copied into DOTS, which is the renamed backup copy of .config.
DOTS_SOURCE="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config"
DOTS_DIR="$BACKUP_DIR/DOTS"

# Ask for archive creation before copying starts so required tools fail early.
if confirm_yes_no "Create compressed .tar.gz archive with pigz after backup?" "N"; then
  require_cmd tar
  require_cmd pigz
  CREATE_ARCHIVE=true
fi

# Top-level $HOME items copied directly into the backup folder.
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

# Base rsync flags preserve permissions, ownership metadata, ACLs, and xattrs.
RSYNC_ARGS=(
  -aAXH
  --numeric-ids
  --info=progress2
)

mkdir -p "$BACKUP_DIR"
log "Backup destination: $BACKUP_DIR"

# Copy each requested $HOME item into BACKUP_DIR, with per-folder exclusions.
for item in "${HOME_ITEMS[@]}"; do
  source_path="$HOME/$item"
  item_args=("${RSYNC_ARGS[@]}")

  # Skip ISO files from Downloads and the nested .ssh/agent folder.
  case "$item" in
    "Downloads") item_args+=(--exclude='*.iso') ;;
    ".ssh") item_args+=(--exclude='agent/') ;;
  esac

  if [[ -e "$source_path" ]]; then
    log "Backing up: $source_path"
    rsync "${item_args[@]}" "$source_path" "$BACKUP_DIR/"
  else
    log "Skipping missing path: $source_path"
  fi
done

# Store the portable main restore script inside the backup folder.
install -m 0755 "$PROJECT_ROOT/restore-main.sh" "$BACKUP_DIR/restore-main.sh"
log "Copied restore script: $BACKUP_DIR/restore-main.sh"

# Copy the ML4W dotfiles .config tree into DOTS and include its restore helper.
if [[ -d "$DOTS_SOURCE" ]]; then
  log "Backing up dotfiles config: $DOTS_SOURCE"
  mkdir -p "$DOTS_DIR"
  rsync "${RSYNC_ARGS[@]}" "$DOTS_SOURCE/" "$DOTS_DIR/"
  install -m 0755 "$PROJECT_ROOT/restore-dots.sh" "$DOTS_DIR/restore-dots.sh"
  log "Copied restore script: $DOTS_DIR/restore-dots.sh"
else
  log "Skipping missing dotfiles config: $DOTS_SOURCE"
fi

# Compress the finished backup folder only if the user selected that at startup.
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  log "Creating archive: $ARCHIVE_NAME"
  tar -C "$MAIN_DIR" -cf - "$RUN_ID" | pigz >"$ARCHIVE_NAME"
  log "Archive created: $ARCHIVE_NAME"
else
  log "Archive skipped"
fi

log "Done: bkp-main"
