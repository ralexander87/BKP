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

# Let the user choose top-level folders to skip by entering menu numbers.
prompt_skip_home_items() {
  local answer normalized token idx
  local -A selected=()
  local -a skip_items=()
  local -a option_labels=(
    "Documents"
    "Downloads"
    "Pictures"
    "Music"
    "Obsidian"
    "Code"
  )

  printf 'Optional: choose folders to skip (space or comma separated).\n'
  printf '  1 - Documents\n'
  printf '  2 - Downloads\n'
  printf '  3 - Pictures\n'
  printf '  4 - Music\n'
  printf '  5 - Obsidian\n'
  printf '  6 - Code\n'
  read -r -p "Skip selection (Enter for none): " answer

  # Empty input means no exclusions; keep full backup behavior.
  [[ -n "$answer" ]] || return

  normalized="${answer//,/ }"
  for token in $normalized; do
    [[ "$token" =~ ^[0-9]+$ ]] || die "invalid skip selection value: $token"
    ((token >= 1 && token <= 6)) || die "skip selection out of range: $token"
    selected["$token"]=1
  done

  for idx in "${!option_labels[@]}"; do
    if [[ -n "${selected[$((idx + 1))]:-}" ]]; then
      skip_items+=("${option_labels[$idx]}")
    fi
  done

  if [[ "${#skip_items[@]}" -gt 0 ]]; then
    for item in "${skip_items[@]}"; do
      SKIP_HOME_ITEMS["$item"]=1
    done
    log "Skipping selected folders: ${skip_items[*]}"
  fi
}

# Estimate a path's size in bytes; missing paths count as zero.
path_size_bytes() {
  local path="$1"

  [[ -e "$path" ]] || {
    printf '0\n'
    return
  }

  du -sb "$path" 2>/dev/null | awk '{ print $1 }'
}

# Estimate the source data size before backup so destination space can be checked.
estimate_backup_size_bytes() {
  local total=0
  local item path size

  for item in "${HOME_ITEMS[@]}"; do
    path="$HOME/$item"
    size="$(path_size_bytes "$path")"
    total=$((total + size))
  done

  size="$(path_size_bytes "$DOTS_SOURCE")"
  total=$((total + size))

  printf '%s\n' "$total"
}

# Warn if the selected destination appears too small for the backup.
check_destination_space() {
  local destination="$1"
  local required available

  require_cmd df
  require_cmd du

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
    printf 'backup_type=main\n'
    printf 'created_at=%s\n' "$(date -Is)"
    printf 'hostname=%s\n' "$(system_hostname)"
    printf 'user=%s\n' "${USER:-unknown}"
    printf 'project_root=%s\n' "$PROJECT_ROOT"
    printf 'git_commit=%s\n' "$git_commit"
    printf 'destination_device=%s\n' "$DEST_DEVICE"
    printf 'backup_dir=%s\n' "$BACKUP_DIR"
    printf 'archive_requested=%s\n' "$CREATE_ARCHIVE"
    printf 'dots_source=%s\n' "$DOTS_SOURCE"
    printf 'home_items=%s\n' "${HOME_ITEMS[*]}"
  } >"$manifest"

  log "Wrote manifest: $manifest"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Prepare local runtime folders and verify required tools exist.
ensure_dirs
require_cmd rsync
require_cmd flock

# Prevent two main backups from running at the same time.
LOCK_FILE="$LOG_ROOT/bkp-main.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || die "another bkp-main.sh run is already active"

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

# Optional skip map keyed by item names selected in prompt_skip_home_items.
declare -A SKIP_HOME_ITEMS=()

# Ask for optional folder exclusions before backup starts.
prompt_skip_home_items

# Base rsync flags preserve permissions, ownership metadata, ACLs, and xattrs.
RSYNC_ARGS=(
  -aAXH
  --numeric-ids
  --info=progress2
)

# Check destination free space before creating the backup folder.
check_destination_space "$DEST_DEVICE"

mkdir -p "$BACKUP_DIR"
log "Backup destination: $BACKUP_DIR"

# Copy each requested $HOME item into BACKUP_DIR, with per-folder exclusions.
for item in "${HOME_ITEMS[@]}"; do
  source_path="$HOME/$item"
  item_args=("${RSYNC_ARGS[@]}")

  if [[ -n "${SKIP_HOME_ITEMS[$item]:-}" ]]; then
    log "Skipping user-selected folder: $source_path"
    continue
  fi

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

# Add a manifest to the backup before optional compression.
write_manifest

# Compress the finished backup folder only if the user selected that at startup.
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  log "Creating archive: $ARCHIVE_NAME"
  tar -C "$MAIN_DIR" -cf - "$RUN_ID" | pigz >"$ARCHIVE_NAME"
  log "Archive created: $ARCHIVE_NAME"
else
  log "Archive skipped"
fi

log "Done: bkp-main"
