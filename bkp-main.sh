#!/usr/bin/env bash

# Load shared helpers for logging, prompts, mount selection, and timestamps.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Unified backup log file. LOG_ROOT is defined by lib/common.sh.
LOG_FILE="$LOG_ROOT/bkp.log"
UI_RENDER_STYLE=main
UI_BACKUP_LABEL=MAIN
UI_STARTED_LABEL=Started
MANIFEST_FILE=""
BACKUP_COMPLETE=false
RUN_RESULT="failed"

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./bkp-main.sh [--quiet]

Back up selected $HOME folders to an external mounted device.
EOF
}

# Ensure required user-space dependencies exist before backup starts.
preflight_checks() {
  require_all_cmds rsync flock findmnt df du install sort
}

# Treat rsync "vanished source files" (exit 24) as warning, not hard failure.
run_rsync_main() {
  local rc=0
  "$@" || rc=$?
  if [[ "$rc" -eq 24 ]]; then
    log_warn "rsync reported vanished source files (exit 24), continuing"
    return 0
  fi
  return "$rc"
}

# Let the user choose top-level folders to skip by entering menu numbers.
prompt_skip_home_items() {
  local answer normalized token idx
  local -A selected=()
  local -a skip_items=()

  printf 'Optional: choose folders to skip (space or comma separated).\n'
  if [[ "${#SKIPPABLE_HOME_ITEMS[@]}" -eq 0 ]]; then
    printf '  No non-hidden folders found in %s.\n' "\$HOME"
    return 0
  fi

  for idx in "${!SKIPPABLE_HOME_ITEMS[@]}"; do
    printf '  %s - %s\n' "$((idx + 1))" "${SKIPPABLE_HOME_ITEMS[$idx]}"
  done
  read -r -p "Skip selection (Enter for none): " answer

  # Empty input means no exclusions; keep full backup behavior.
  [[ -n "$answer" ]] || return 0

  normalized="${answer//,/ }"
  for token in $normalized; do
    [[ "$token" =~ ^[0-9]+$ ]] || die "invalid skip selection value: $token"
    ((token >= 1 && token <= ${#SKIPPABLE_HOME_ITEMS[@]})) || die "skip selection out of range: $token"
    selected["$token"]=1
  done

  for idx in "${!SKIPPABLE_HOME_ITEMS[@]}"; do
    if [[ -n "${selected[$((idx + 1))]:-}" ]]; then
      skip_items+=("${SKIPPABLE_HOME_ITEMS[$idx]}")
    fi
  done

  if [[ "${#skip_items[@]}" -gt 0 ]]; then
    for item in "${skip_items[@]}"; do
      SKIP_HOME_ITEMS["$item"]=1
    done
    log "Skipping selected folders: ${skip_items[*]}"
  fi
}

# Build the backup item list from every top-level non-hidden $HOME folder plus selected hidden folders.
discover_home_items() {
  local hidden_item
  local item
  local path

  HOME_ITEMS=()
  SKIPPABLE_HOME_ITEMS=()

  while IFS= read -r path; do
    item="${path##*/}"
    SKIPPABLE_HOME_ITEMS+=("$item")
    HOME_ITEMS+=("$item")
  done < <(find "$HOME" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print | sort)

  for hidden_item in "${HIDDEN_HOME_ITEMS[@]}"; do
    HOME_ITEMS+=("$hidden_item")
  done
}

# Estimate the source data size before backup so destination space can be checked.
estimate_backup_size_bytes() {
  local total=0
  local item path size

  for item in "${HOME_ITEMS[@]}"; do
    [[ -n "${SKIP_HOME_ITEMS[$item]:-}" ]] && continue
    path="$HOME/$item"
    size="$(path_size_bytes "$path")"
    total=$((total + size))
  done

  size="$(path_size_bytes "$DOTS_SOURCE")"
  total=$((total + size))

  printf '%s\n' "$total"
}

# Write backup metadata that helps identify what this run copied.
write_manifest() {
  local manifest="$BACKUP_DIR/backup-manifest.txt"

  {
    write_common_manifest_fields "main"
    printf 'dots_root=%s\n' "$DOTS_ROOT"
    printf 'dots_source=%s\n' "$DOTS_SOURCE"
    printf 'wallpapers_source=%s\n' "$WALLPAPERS_SOURCE"
    printf 'big_wallpapers_dir=%s\n' "$BIG_WALLPAPERS_DIR"
    printf 'firmware_source=%s\n' "$FIRMWARE_SOURCE"
    printf 'big_firmware_dir=%s\n' "$BIG_FIRMWARE_DIR"
    printf 'big_home_files_dir=%s\n' "$BIG_HOME_FILES_DIR"
    printf 'home_hidden_files=%s\n' "${HOME_HIDDEN_FILES[*]}"
    printf 'local_restore_dots_settings_hook=%s\n' "$([[ -f "$PROJECT_ROOT/config/local/restore-dots-settings.sh" ]] && printf 'present' || printf 'missing')"
    printf 'home_items=%s\n' "${HOME_ITEMS[*]}"
  } >"$manifest"

  MANIFEST_FILE="$manifest"
  log "Wrote manifest: $manifest"
}

# Verify required files exist before the backup is marked complete.
verify_backup_contents() {
  local required_item
  local -a required_items=(
    "restore-main.sh"
    "lib/common.sh"
    "backup-manifest.txt"
  )

  for required_item in "${required_items[@]}"; do
    [[ -e "$BACKUP_DIR/$required_item" ]] || die "missing expected backup item: $required_item"
  done

  if [[ -d "$DOTS_DIR" ]]; then
    [[ -f "$DOTS_DIR/restore-dots.sh" ]] || die "missing expected backup item: DOTS/restore-dots.sh"
    [[ -f "$DOTS_DIR/lib/common.sh" ]] || die "missing expected backup item: DOTS/lib/common.sh"
    if [[ -f "$PROJECT_ROOT/config/local/restore-dots-settings.sh" ]]; then
      [[ -f "$DOTS_DIR/config/local/restore-dots-settings.sh" ]] || die "missing expected backup item: DOTS/config/local/restore-dots-settings.sh"
    fi
  fi

  if [[ -d "$WALLPAPERS_SOURCE" ]]; then
    [[ -d "$BIG_WALLPAPERS_DIR" ]] || die "missing expected shared wallpaper folder: $BIG_WALLPAPERS_DIR"
  fi

  if [[ -d "$FIRMWARE_SOURCE" ]]; then
    [[ -d "$BIG_FIRMWARE_DIR" ]] || die "missing expected shared firmware folder: $BIG_FIRMWARE_DIR"
  fi

  for hidden_file in "${HOME_HIDDEN_FILES[@]}"; do
    if [[ -f "$HOME/$hidden_file" ]]; then
      [[ -f "$BIG_HOME_FILES_DIR/$hidden_file" ]] || die "missing expected shared hidden file: $BIG_HOME_FILES_DIR/$hidden_file"
    fi
  done
}

# Persist final complete/failed status when the script exits.
finalize_status() {
  local exit_code="$1"

  if [[ -d "$BACKUP_DIR" ]]; then
    set_backup_status "$(backup_final_status "$exit_code")"
    if [[ "$RUN_RESULT" != "complete" ]]; then
      ui_finalize "FAILED" "${UI_LAST_ERROR_TEXT:-Main backup failed.}"
      ui_append_final_status "$MANIFEST_FILE"
    fi
  fi
}

parse_common_args "$@"
if [[ "${SCRIPT_ARGS[0]:-}" == "-h" || "${SCRIPT_ARGS[0]:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Prepare local runtime folders and verify required tools exist.
ensure_dirs
preflight_checks
setup_cleanup_trap
trap 'ui_report_error "$LINENO" "$BASH_COMMAND"' ERR

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
DOTS_ROOT="$HOME/.mydotfiles"
DOTS_SOURCE="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config"
DOTS_DIR="$BACKUP_DIR/DOTS"
WALLPAPERS_SOURCE="$DOTS_SOURCE/ml4w/wallpapers"
BIG_WALLPAPERS_DIR="$DEST_DEVICE/BIG/wallpapers"
FIRMWARE_SOURCE="$HOME/Documents/030-Firmware"
BIG_FIRMWARE_DIR="$DEST_DEVICE/BIG/030-Firmware"
BIG_HOME_FILES_DIR="$DEST_DEVICE/BIG"

# Ask for archive creation before copying starts so required tools fail early.
if confirm_yes_no "Create compressed .tar.gz archive with pigz after backup?" "N"; then
  require_cmd tar
  require_cmd pigz
  CREATE_ARCHIVE=true
fi

# Hidden $HOME folders copied directly into the backup folder when present.
HIDDEN_HOME_ITEMS=(
  ".themes"
  ".icons"
  ".ssh"
  ".vscode-oss"
)

# Backup-only $HOME files copied into BIG and intentionally not restored.
HOME_HIDDEN_FILES=(
  ".bash_history"
  ".zsh_history"
  ".zshrc"
  ".wget-hsts"
)

# Optional skip map keyed by item names selected in prompt_skip_home_items.
declare -A SKIP_HOME_ITEMS=()

# Discover current top-level $HOME folders before showing the skip menu.
discover_home_items

# Ask for optional folder exclusions before backup starts.
prompt_skip_home_items

# Check destination free space before creating the backup folder.
check_destination_space_for_size "$DEST_DEVICE" "$(estimate_backup_size_bytes)"

mkdir -p "$BACKUP_DIR"
log "Backup destination: $BACKUP_DIR"
trap 'finalize_status "$?"; cleanup_temp_paths; ui_cleanup' EXIT
set_backup_status "in_progress"

# Start terminal dashboard for visual progress and selected options.
ui_init "MAIN Backup Progress"
skip_count="${#SKIP_HOME_ITEMS[@]}"
ui_add_meta "Destination" "/MAIN/$RUN_ID"
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  ui_add_meta "Archive" "YES"
else
  ui_add_meta "Archive" "NO"
fi
ui_add_meta "Skipped Folders" "$skip_count"

for item in "${HOME_ITEMS[@]}"; do
  ui_add_task "main-$item" "$item"
done
if [[ "${#SKIPPABLE_HOME_ITEMS[@]}" -gt 0 ]]; then
  ui_add_task_separator_after "main-${SKIPPABLE_HOME_ITEMS[-1]}" "Hidden Folders"
fi
ui_add_task_separator_after "main-.vscode-oss" "Post Backup"
ui_add_task "main-restore-script" "Copy restore-main.sh"
ui_add_task "main-dots-restore" "Copy restore-dots.sh"
ui_add_task "main-dots" "Backup DOTS"
ui_add_task "main-wallpapers" "Backup wallpapers"
ui_add_task "main-firmware" "Backup firmware"
ui_add_task "main-hidden-files" "Backup hidden files"
ui_add_task "main-manifest" "Write manifest"
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  ui_add_task "main-archive" "Create archive"
  ui_add_task_separator_after "main-archive"
else
  ui_add_task_separator_after "main-manifest"
fi
ui_render "force"

# Copy each requested $HOME item into BACKUP_DIR, with per-folder exclusions.
for item in "${HOME_ITEMS[@]}"; do
  source_path="$HOME/$item"
  item_args=("${RSYNC_BACKUP_ARGS[@]}")

  if [[ -n "${SKIP_HOME_ITEMS[$item]:-}" ]]; then
    log "Skipping user-selected folder: $source_path"
    ui_update_task "main-$item" "SKIPPED" "SKIPPED"
    ui_render
    continue
  fi

  # Skip ISO files from Downloads and the nested .ssh/agent folder.
  case "$item" in
  "Documents") item_args+=(--exclude='030-Firmware/') ;;
  "Downloads") item_args+=(--exclude='*.iso') ;;
  ".ssh") item_args+=(--exclude='agent/') ;;
  esac

  if [[ -e "$source_path" ]]; then
    log "Backing up: $source_path"
    ui_update_task "main-$item" "RUNNING" "copying from $source_path"
    ui_render
    ui_run_command "main-$item" "copying from $source_path" run_rsync_main rsync "${item_args[@]}" "$source_path" "$BACKUP_DIR/"
    ui_update_task "main-$item" "DONE" "No Error"
    ui_render
  else
    log "Skipping missing path: $source_path"
    ui_update_task "main-$item" "SKIPPED" "missing path"
    ui_render
  fi
done

# Store the portable main restore script inside the backup folder.
ui_update_task "main-restore-script" "RUNNING" "copying restore-main.sh"
ui_render
install -m 0755 "$PROJECT_ROOT/restore-main.sh" "$BACKUP_DIR/restore-main.sh"
mkdir -p "$BACKUP_DIR/lib"
install -m 0644 "$PROJECT_ROOT/lib/common.sh" "$BACKUP_DIR/lib/common.sh"
log "Copied restore script: $BACKUP_DIR/restore-main.sh"
ui_update_task "main-restore-script" "DONE" "COPIED"
ui_render

# Copy the ML4W dotfiles .config tree into DOTS and include its restore helper.
if [[ -d "$DOTS_ROOT" && -d "$DOTS_SOURCE" ]]; then
  log "Backing up dotfiles config: $DOTS_SOURCE"
  ui_update_task "main-dots" "RUNNING" "copying dotfiles config"
  ui_render
  mkdir -p "$DOTS_DIR"
  ui_run_command "main-dots" "copying dotfiles config" run_rsync_main rsync_backup_copy --exclude='ml4w/wallpapers/' "$DOTS_SOURCE/" "$DOTS_DIR/"
  ui_update_task "main-dots" "DONE" "COPIED"
  ui_update_task "main-dots-restore" "RUNNING" "copying restore-dots.sh"
  ui_render
  install -m 0755 "$PROJECT_ROOT/restore-dots.sh" "$DOTS_DIR/restore-dots.sh"
  mkdir -p "$DOTS_DIR/lib"
  install -m 0644 "$PROJECT_ROOT/lib/common.sh" "$DOTS_DIR/lib/common.sh"
  if [[ -f "$PROJECT_ROOT/config/local/restore-dots-settings.sh" ]]; then
    mkdir -p "$DOTS_DIR/config/local"
    install -m 0600 "$PROJECT_ROOT/config/local/restore-dots-settings.sh" "$DOTS_DIR/config/local/restore-dots-settings.sh"
    log "Copied local restore settings hook: $DOTS_DIR/config/local/restore-dots-settings.sh"
  fi
  log "Copied restore script: $DOTS_DIR/restore-dots.sh"
  ui_update_task "main-dots-restore" "DONE" "COPIED"
  ui_render
else
  if [[ ! -d "$DOTS_ROOT" ]]; then
    log "Skipping missing dotfiles root: $DOTS_ROOT"
  else
    log "Skipping missing dotfiles config: $DOTS_SOURCE"
  fi
  ui_update_task "main-dots" "SKIPPED" "dotfiles path missing"
  ui_update_task "main-dots-restore" "SKIPPED" "dotfiles path missing"
  ui_render
fi

# Copy missing wallpapers into the shared BIG/wallpapers folder on the backup device.
if [[ -d "$WALLPAPERS_SOURCE" ]]; then
  log "Backing up missing wallpapers: $WALLPAPERS_SOURCE -> $BIG_WALLPAPERS_DIR"
  ui_update_task "main-wallpapers" "RUNNING" "copying missing wallpapers"
  ui_render
  mkdir -p "$BIG_WALLPAPERS_DIR"
  ui_run_command "main-wallpapers" "copying missing wallpapers" run_rsync_main rsync_backup_copy --ignore-existing "$WALLPAPERS_SOURCE/" "$BIG_WALLPAPERS_DIR/"
  ui_update_task "main-wallpapers" "DONE" "UPDATED"
  ui_render
else
  log "Skipping missing wallpapers folder: $WALLPAPERS_SOURCE"
  ui_update_task "main-wallpapers" "SKIPPED" "wallpapers path missing"
  ui_render
fi

# Copy missing firmware files into the shared BIG/030-Firmware folder on the backup device.
if [[ -d "$FIRMWARE_SOURCE" ]]; then
  log "Backing up missing firmware: $FIRMWARE_SOURCE -> $BIG_FIRMWARE_DIR"
  ui_update_task "main-firmware" "RUNNING" "copying missing firmware"
  ui_render
  mkdir -p "$BIG_FIRMWARE_DIR"
  ui_run_command "main-firmware" "copying missing firmware" run_rsync_main rsync_backup_copy --ignore-existing "$FIRMWARE_SOURCE/" "$BIG_FIRMWARE_DIR/"
  ui_update_task "main-firmware" "DONE" "UPDATED"
  ui_render
else
  log "Skipping missing firmware folder: $FIRMWARE_SOURCE"
  ui_update_task "main-firmware" "SKIPPED" "firmware path missing"
  ui_render
fi

# Copy selected backup-only hidden files into the shared BIG folder.
hidden_files_copied=0
ui_update_task "main-hidden-files" "RUNNING" "copying hidden files"
ui_render
mkdir -p "$BIG_HOME_FILES_DIR"
for hidden_file in "${HOME_HIDDEN_FILES[@]}"; do
  source_path="$HOME/$hidden_file"
  if [[ -f "$source_path" ]]; then
    log "Backing up hidden file: $source_path -> $BIG_HOME_FILES_DIR/"
    run_rsync_main rsync_backup_copy "$source_path" "$BIG_HOME_FILES_DIR/"
    hidden_files_copied=$((hidden_files_copied + 1))
  else
    log "Skipping missing hidden file: $source_path"
  fi
done
if [[ "$hidden_files_copied" -gt 0 ]]; then
  ui_update_task "main-hidden-files" "DONE" "COPIED $hidden_files_copied file(s)"
else
  ui_update_task "main-hidden-files" "SKIPPED" "hidden files missing"
fi
ui_render

# Add a manifest to the backup before optional compression.
ui_update_task "main-manifest" "RUNNING" "writing manifest"
ui_render
set_backup_status "complete"
verify_backup_contents
BACKUP_COMPLETE=true
ui_update_task "main-manifest" "DONE" "WRITTEN"
ui_render

# Compress the finished backup folder only if the user selected that at startup.
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  log "Creating archive: $ARCHIVE_NAME"
  ui_update_task "main-archive" "RUNNING" "compressing backup"
  ui_render
  tar -C "$MAIN_DIR" \
    --exclude='./BIG/wallpapers' \
    --exclude='./BIG/wallpapers/**' \
    --exclude='./BIG/030-Firmware' \
    --exclude='./BIG/030-Firmware/**' \
    --exclude="$RUN_ID/Documents/030-Firmware" \
    --exclude="$RUN_ID/Documents/030-Firmware/**" \
    -cf - "$RUN_ID" | pigz >"$ARCHIVE_NAME"
  log "Archive created: $ARCHIVE_NAME"
  ui_update_task "main-archive" "DONE" "CREATED"
  ui_render "force"
else
  log "Archive skipped"
fi

log "Done: bkp-main"
ui_add_message "INFO" "Backup finished successfully"
ui_finalize "SUCCESS" "All selected MAIN backup tasks completed."
ui_append_final_status "$MANIFEST_FILE"
log_ui_final_status
