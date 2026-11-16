#!/usr/bin/env bash

# Load shared helpers for logging, prompts, mount selection, and timestamps.
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

# Unified backup log file. LOG_ROOT is defined by lib/common.sh.
LOG_FILE="$LOG_ROOT/bkp.log"
UI_BACKUP_LABEL=MAIN
MANIFEST_FILE=""
BACKUP_COMPLETE=false
RUN_RESULT="failed"
ARCHIVE_VALIDATION="not_requested"
MAIN_BACKUP_CONFIG="$PROJECT_ROOT/ARGUS/main.backup.conf"

# Load user-editable source paths, shared destinations, and exclusions.
load_main_backup_config() {
  [[ -f "$MAIN_BACKUP_CONFIG" ]] || die "main backup config not found: $MAIN_BACKUP_CONFIG"
  # shellcheck source=ARGUS/main.backup.conf
  source "$MAIN_BACKUP_CONFIG"
}

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./ARGUS/argus-main.sh [--quiet]

Back up selected $HOME folders to an external mounted device.
EOF
}

# Ensure required user-space dependencies exist before backup starts.
preflight_checks() {
  require_all_cmds rsync flock findmnt df du install sort mv chmod
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

# Print the separator used by the pre-backup folder selection prompt.
print_prompt_separator() {
  printf '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n'
}

# Let the user choose top-level folders to skip by entering menu numbers.
prompt_skip_home_items() {
  local answer normalized token idx
  local -A selected=()
  local -a skip_items=()

  print_prompt_separator
  printf '\n'
  printf -- '- Select folder to exclude.\n'
  printf '  \n'
  printf '  0 - EXIT\n'
  printf '  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n'

  for idx in "${!SKIPPABLE_HOME_ITEMS[@]}"; do
    printf '  %s - %s\n' "$((idx + 1))" "${SKIPPABLE_HOME_ITEMS[$idx]}"
  done
  printf '  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n'
  printf '\n'
  print_prompt_separator
  printf -- '- [Enter for none. Space or comma separated]\n'
  read -r -p "-  Skip selection : " answer

  # Empty input means no exclusions; keep full backup behavior.
  [[ -n "$answer" ]] || return 0

  normalized="${answer//,/ }"
  for token in $normalized; do
    [[ "$token" =~ ^[0-9]+$ ]] || die "invalid skip selection value: $token"
    if [[ "$token" == "0" ]]; then
      log "Backup cancelled from exclude menu"
      printf 'Backup cancelled.\n'
      exit 0
    fi
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

# Build the backup item list from top-level non-hidden $HOME folders, excluding PreRestored.
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
  done < <(find "$HOME" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name 'PreRestored' -print | sort)

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

  printf '%s\n' "$total"
}

# Write the same versioned MAIN manifest format as the primary backup script.
write_manifest() {
  local manifest="$BACKUP_DIR/backup-manifest.txt"
  local json_manifest="$BACKUP_DIR/backup-manifest.json"
  local manifest_tmp="$manifest.tmp"
  local json_manifest_tmp="$json_manifest.tmp"

  register_temp_path "$manifest_tmp"
  register_temp_path "$json_manifest_tmp"

  {
    write_common_manifest_fields "main"
    manifest_field "Main Backup Config" "$MAIN_BACKUP_CONFIG"
    manifest_field "Home Hidden Files" "${HOME_HIDDEN_FILES[*]}"
    manifest_field "Home Items" "${HOME_ITEMS[*]}"
  } >"$manifest_tmp"

  {
    printf '{\n'
    write_common_manifest_json_fields "main"
    json_string_field "main_backup_config" "$MAIN_BACKUP_CONFIG"
    json_raw_field "home_hidden_files" "$(json_string_array "${HOME_HIDDEN_FILES[@]}")"
    json_raw_field "home_items" "$(json_string_array "${HOME_ITEMS[@]}")" ""
    printf '}\n'
  } >"$json_manifest_tmp"

  mv -- "$manifest_tmp" "$manifest"
  mv -- "$json_manifest_tmp" "$json_manifest"
  MANIFEST_FILE="$manifest"
  log "Wrote manifest: $manifest"
}

# Check the portable restore helper and manifest before publication.
verify_backup_contents() {
  local required_item
  for required_item in restore-main.sh lib/common.sh config/main.backup.conf backup-manifest.txt backup-manifest.json; do
    [[ -e "$BACKUP_DIR/$required_item" ]] || die "missing expected backup item: $required_item"
  done
}

# Persist final complete/failed status when the script exits.
finalize_status() {
  local exit_code="$1"

  if [[ -d "$BACKUP_DIR" ]]; then
    if [[ "$BACKUP_COMPLETE" != "true" || "$exit_code" -ne 0 ]]; then
      set_backup_status "failed"
      ui_finalize "FAILED" "${UI_LAST_ERROR_TEXT:-Main backup failed.}"
      ui_append_final_status "$MANIFEST_FILE"
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

# Create, validate, and atomically publish the optional main archive.
create_validated_archive() {
  local archive_tmp="$MAIN_DIR/.${RUN_ID}.tar.gz.in-progress"

  register_temp_path "$archive_tmp"
  install -m 0600 /dev/null "$archive_tmp"
  ARCHIVE_VALIDATION="pending"
  set_backup_status "in_progress"
  if ! tar -C "$MAIN_DIR" -cf - "$RUN_ID" | pigz >"$archive_tmp"; then
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
  chmod 0600 "$ARCHIVE_NAME"
  ARCHIVE_VALIDATION="passed"
}

parse_common_args "$@"
if [[ "${SCRIPT_ARGS[0]:-}" == "-h" || "${SCRIPT_ARGS[0]:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Prepare local runtime folders and verify required tools exist.
ensure_dirs
init_log_file
load_main_backup_config
preflight_checks
setup_cleanup_trap
trap 'ui_report_error "$LINENO" "$BASH_COMMAND"' ERR

# Prevent two main backups from running at the same time.
LOCK_FILE="$LOG_ROOT/argus-main.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || die "another argus-main.sh run is already active"

# Ask the user which external mounted device should receive the backup.
DEST_DEVICE="$(select_external_mount "Select backup destination device:")"

# Build the backup folder names and archive path for this run.
MAIN_DIR="$DEST_DEVICE/11-ARGUS/MAIN"
RUN_ID="BKP-$(timestamp)"
FINAL_BACKUP_DIR="$MAIN_DIR/$RUN_ID"
BACKUP_DIR="$MAIN_DIR/.${RUN_ID}.in-progress"
ARCHIVE_NAME="$MAIN_DIR/$RUN_ID.tar.gz"
CREATE_ARCHIVE=false

# Ask for archive creation before copying starts so required tools fail early.
if confirm_yes_no "- Create .tar.gz archive after backup?" "N"; then
  require_cmd tar
  require_cmd pigz
  CREATE_ARCHIVE=true
fi

# Optional skip map keyed by item names selected in prompt_skip_home_items.
declare -A SKIP_HOME_ITEMS=()

# Discover current top-level $HOME folders before showing the skip menu.
discover_home_items

# Ask for optional folder exclusions before backup starts.
prompt_skip_home_items

# Check destination free space before creating the backup folder.
check_destination_space_for_size "$DEST_DEVICE" "$(estimate_backup_size_bytes)"

mkdir -p "$MAIN_DIR"
[[ ! -e "$BACKUP_DIR" ]] || die "staging backup already exists: $BACKUP_DIR"
[[ ! -e "$FINAL_BACKUP_DIR" ]] || die "backup already exists: $FINAL_BACKUP_DIR"
mkdir "$BACKUP_DIR"
log "Backup staging destination: $BACKUP_DIR"
trap 'finalize_status "$?"; cleanup_temp_paths; ui_cleanup' EXIT
setup_signal_traps
set_backup_status "in_progress"

# Start terminal dashboard for visual progress and selected options.
ui_init
skip_count="${#SKIP_HOME_ITEMS[@]}"
ui_add_meta "Destination" "${MAIN_DIR#"$DEST_DEVICE"}/$RUN_ID"
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  ui_add_meta "Archive" "YES"
else
  ui_add_meta "Archive" "NO"
fi
ui_add_meta "Skipped Folders" "$skip_count"

for item in "${HOME_ITEMS[@]}"; do
  ui_add_task "main-$item" "$item"
done
if [[ "${#SKIPPABLE_HOME_ITEMS[@]}" -gt 0 && "${#HIDDEN_HOME_ITEMS[@]}" -gt 0 ]]; then
  ui_add_task_separator_after "main-${SKIPPABLE_HOME_ITEMS[-1]}" "Hidden Folders"
fi
if [[ "${#HIDDEN_HOME_ITEMS[@]}" -gt 0 ]]; then
  ui_add_task_separator_after "main-${HIDDEN_HOME_ITEMS[-1]}" "Post Backup"
elif [[ "${#SKIPPABLE_HOME_ITEMS[@]}" -gt 0 ]]; then
  ui_add_task_separator_after "main-${SKIPPABLE_HOME_ITEMS[-1]}" "Post Backup"
fi
ui_add_task "main-restore-script" "Copy restore-main.sh"
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
  "Downloads")
    for exclude_pattern in "${DOWNLOADS_EXCLUDES[@]}"; do item_args+=(--exclude="$exclude_pattern"); done
    ;;
  ".ssh")
    for exclude_pattern in "${SSH_EXCLUDES[@]}"; do item_args+=(--exclude="$exclude_pattern"); done
    ;;
  esac

  if [[ -e "$source_path" ]]; then
    log "Backing up: $source_path"
    ui_update_task "main-$item" "RUNNING" "copying from $source_path"
    ui_render
    if ui_run_command "main-$item" "copying from $source_path" run_rsync_main rsync "${item_args[@]}" "$source_path" "$BACKUP_DIR/"; then
      :
    else
      exit_code="$?"
      unreadable_path="$(find "$source_path" -xdev \( ! -readable -o -type d ! -executable \) -print -quit 2>/dev/null || true)"
      if [[ -n "$unreadable_path" ]]; then
        log_error "Cannot back up $item because this source path is unreadable: $unreadable_path. Correct its ownership/permissions or skip $item."
      fi
      exit "$exit_code"
    fi
    ui_update_task "main-$item" "DONE" "No Error"
    ui_render
  else
    log "Skipping missing path: $source_path"
    ui_update_task "main-$item" "SKIPPED" "missing path"
    ui_render
  fi
done

# Bundle the ARGUS restore placeholder and shared helpers with this backup.
ui_update_task "main-restore-script" "RUNNING" "copying restore-main.sh"
ui_render
install -m 0755 "$PROJECT_ROOT/ARGUS/restore-main.sh" "$BACKUP_DIR/restore-main.sh"
mkdir -p "$BACKUP_DIR/lib" "$BACKUP_DIR/config"
install -m 0644 "$PROJECT_ROOT/lib/common.sh" "$BACKUP_DIR/lib/common.sh"
install -m 0644 "$MAIN_BACKUP_CONFIG" "$BACKUP_DIR/config/main.backup.conf"
log "Copied restore script: $BACKUP_DIR/restore-main.sh"
ui_update_task "main-restore-script" "DONE" "COPIED"
ui_render

# Store shell setup files inside this run rather than in a shared desktop folder.
hidden_files_copied=0
ui_update_task "main-hidden-files" "RUNNING" "copying hidden files"
ui_render
for hidden_file in "${HOME_HIDDEN_FILES[@]}"; do
  source_path="$HOME/$hidden_file"
  if [[ -f "$source_path" ]]; then
    log "Backing up hidden file: $source_path -> $BACKUP_DIR/"
    run_rsync_main rsync_backup_copy "$source_path" "$BACKUP_DIR/"
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

# Verify and publish the staged backup before optional compression.
ui_update_task "main-manifest" "RUNNING" "writing manifest"
ui_render
set_backup_status "in_progress"
verify_backup_contents
promote_staged_backup

# Compress the finished backup folder only if the user selected that at startup.
if [[ "$CREATE_ARCHIVE" == "true" ]]; then
  log "Creating archive: $ARCHIVE_NAME"
  ui_update_task "main-archive" "RUNNING" "compressing backup"
  ui_render
  create_validated_archive
  log "Archive created and validated: $ARCHIVE_NAME"
  ui_update_task "main-archive" "DONE" "VALIDATED"
  ui_render "force"
else
  log "Archive skipped"
fi

set_backup_status "complete"
verify_backup_contents
BACKUP_COMPLETE=true
ui_update_task "main-manifest" "DONE" "WRITTEN"
ui_render

log "Done: argus-main"
ui_add_message "INFO" "Backup finished successfully"
ui_finalize "SUCCESS" "All selected MAIN backup tasks completed."
ui_append_final_status "$MANIFEST_FILE"
log_ui_final_status
