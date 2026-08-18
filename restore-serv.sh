#!/usr/bin/env bash

# Service restore runs from the backup folder where this script is located.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Load shared helpers when bundled, but keep this restore script usable by itself.
# BEGIN RESTORE BOOTSTRAP
# Load bundled shared helpers, or define a minimal fallback for old backups.
load_restore_helpers() {
  local helper

  for helper in "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/../lib/common.sh"; do
    if [[ -f "$helper" ]]; then
      # shellcheck source=lib/common.sh
      source "$helper"
      return 0
    fi
  done

  set -Eeuo pipefail
  QUIET="${QUIET:-false}"
  SCRIPT_NAME="${SCRIPT_NAME:-$(basename -- "${BASH_SOURCE[0]}")}"
  RSYNC_RESTORE_ARGS=(-aAXH --numeric-ids --info=progress2)
  TEMP_PATHS=()

  log_message() {
    local level="${1^^}"
    shift
    local ts line cli_line

    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    line="[$ts] [$level] [$SCRIPT_NAME] $*"
    cli_line="[$level] $*"
    [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "$line" >>"$LOG_FILE"
    [[ "$QUIET" == "true" && "$level" == "INFO" ]] || printf '%s\n' "$cli_line"
  }
  log() { log_message "INFO" "$*"; }
  log_warn() { log_message "WARN" "$*"; }
  log_error() { log_message "ERROR" "$*"; }
  die() {
    log_error "$*"
    exit 1
  }
  require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
  require_all_cmds() {
    local cmd
    for cmd in "$@"; do
      require_cmd "$cmd"
    done
  }
  parse_common_args() {
    local arg
    SCRIPT_ARGS=()
    for arg in "$@"; do
      case "$arg" in
      -q | --quiet) QUIET=true ;;
      *) SCRIPT_ARGS+=("$arg") ;;
      esac
    done
  }
  register_temp_path() { TEMP_PATHS+=("$1"); }
  cleanup_temp_paths() {
    local p
    for p in "${TEMP_PATHS[@]}"; do
      [[ -e "$p" ]] && rm -rf -- "$p"
    done
  }
  ui_cleanup() { :; }
  setup_cleanup_trap() { trap 'cleanup_temp_paths; ui_cleanup' EXIT; }
  rsync_restore_copy() { rsync "${RSYNC_RESTORE_ARGS[@]}" "$@"; }
  sudo_rsync_restore_copy() { sudo rsync "${RSYNC_RESTORE_ARGS[@]}" "$@"; }
  confirm_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    local answer

    read -r -p "$prompt [$default]: " answer
    answer="${answer:-$default}"
    answer="$(printf '%s' "$answer" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [[ "$answer" == "y" || "$answer" == "yes" ]]
  }
}

load_restore_helpers
# END RESTORE BOOTSTRAP

LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore.log}"
RESTORE_ID="$(date '+%j-%d-%m-%H-%M-%S')"
ROLLBACK_FILE="$SCRIPT_DIR/restore-serv-rollback-$RESTORE_ID.sh"
RUN_RESULT="failed"
CURRENT_ACTION="none"
STATUS_FILE="$SCRIPT_DIR/backup.status"
MANIFEST_FILE="$SCRIPT_DIR/backup-manifest.txt"
SERVICE_RESTORE_CONFIG=""

# Set built-in restore values before any bundled or local config overrides.
set_service_restore_defaults() {
  SMB_DIRS=(
    "/SMB"
    "/SMB/euclid"
    "/SMB/pneuma-kali"
    "/SMB/lateralus"
    "/SMB/SCP"
    "/SMB/SCP/HDD-01"
    "/SMB/SCP/HDD-02"
    "/SMB/SCP/HDD-03"
  )

  FSTAB_LINES=()
  RETIRED_FSTAB_TARGETS=(
    "/SMB/pneuma-win"
  )

  GRUB_CMDLINE_LINUX_DEFAULT_VALUE="loglevel=3 quiet splash"
  GRUB_TERMINAL_OUTPUT_VALUE="gfxterm"
  GRUB_GFXMODE_VALUE="1440x1080x32"
  GRUB_THEME_VALUE="/boot/grub/themes/lateralus/theme.txt"
}

# Return success when a mount target is retired and should be removed.
is_retired_fstab_target() {
  local target="$1"
  local retired_target

  for retired_target in "${RETIRED_FSTAB_TARGETS[@]}"; do
    [[ "$target" == "$retired_target" ]] && return 0
  done

  return 1
}

# Drop retired SMB directories and fstab entries from loaded config overrides.
prune_retired_service_restore_values() {
  local dir
  local line
  local mount_target
  local -a kept_fstab_lines=()
  local -a kept_smb_dirs=()

  for dir in "${SMB_DIRS[@]}"; do
    is_retired_fstab_target "$dir" || kept_smb_dirs+=("$dir")
  done
  SMB_DIRS=("${kept_smb_dirs[@]}")

  for line in "${FSTAB_LINES[@]}"; do
    read -r _ mount_target _ <<<"$line"
    [[ -n "$mount_target" ]] || die "invalid configured fstab line: $line"
    is_retired_fstab_target "$mount_target" || kept_fstab_lines+=("$line")
  done
  FSTAB_LINES=("${kept_fstab_lines[@]}")
}

# Load service restore config files from the backup first, then project-local fallbacks.
load_service_restore_config() {
  local candidate
  local -a loaded_configs=()
  local -a candidates=(
    "$SCRIPT_DIR/config/serv.restore.conf"
    "$SCRIPT_DIR/config/local/serv.restore.conf"
    "$SCRIPT_DIR/serv.restore.conf"
  )

  set_service_restore_defaults

  if [[ -n "${PROJECT_ROOT:-}" ]]; then
    candidates+=("$PROJECT_ROOT/config/serv.restore.conf")
    candidates+=("$PROJECT_ROOT/config/local/serv.restore.conf")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      # shellcheck source=config/serv.restore.conf
      source "$candidate"
      loaded_configs+=("$candidate")
    fi
  done

  if [[ "${#loaded_configs[@]}" -gt 0 ]]; then
    SERVICE_RESTORE_CONFIG="${loaded_configs[*]}"
  fi

  prune_retired_service_restore_values
}

load_service_restore_config

# Record structured audit entries for this restore run.
audit_log() {
  local event="$1"
  log "AUDIT event=$event action=$CURRENT_ACTION result=$RUN_RESULT rollback=$ROLLBACK_FILE"
}

# Confirm an action before it changes local configuration.
confirm_action() {
  local label="$1"

  CURRENT_ACTION="$label"
  confirm_yes_no "Start $label?" "N" || {
    audit_log "cancelled"
    log "$label cancelled"
    return 1
  }

  audit_log "action_started"
  return 0
}

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./restore-serv.sh [--quiet]

Restore backed-up service files from the current folder to their system paths.
Root privileges are required.
EOF
}

# Ensure required dependencies exist before menu actions start.
preflight_checks() {
  require_all_cmds sudo awk cat
}

# Show currently available service restore actions.
show_menu() {
  cat <<'EOF'
Select action:
  0 - Exit
============================
  1 - Create SMB
============================
  2 - Restore samba
  3 - Restore SSH
  4 - Restore fstab
  5 - Restore grub theme
  6 - Restore GRUB
============================
  98 - Collect pre-restore
EOF
}

# Ensure backup finished cleanly before allowing restore actions.
read_manifest_status() {
  local manifest_file="$1"
  local status

  status="$(awk -F= '$1 == "backup_status" { print $2; exit }' "$manifest_file")"
  status="${status:-$(awk -F= '$1 == "run_result" { print $2; exit }' "$manifest_file")}"
  status="${status:-$(awk -F' = ' '$1 == "Backup Status" { print $2; exit }' "$manifest_file")}"
  status="${status:-$(awk -F' = ' '$1 == "Run Result" { print $2; exit }' "$manifest_file")}"
  status="${status#[}"
  status="${status%]}"
  status="${status,,}"
  status="${status// /_}"

  case "$status" in
  completed) printf 'complete\n' ;;
  successful) printf 'success\n' ;;
  *) printf '%s\n' "$status" ;;
  esac
}

verify_backup_status() {
  local manifest_status=""

  if [[ -f "$MANIFEST_FILE" ]]; then
    manifest_status="$(read_manifest_status "$MANIFEST_FILE")"
    if [[ -n "$manifest_status" ]]; then
      [[ "$manifest_status" == "complete" || "$manifest_status" == "success" ]] || die "backup status is not complete: $manifest_status"
      return 0
    fi
  fi

  [[ -f "$STATUS_FILE" ]] || die "backup status not found in manifest or legacy file: $MANIFEST_FILE"
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
  sudo_rsync_restore_copy "$source_file" "$target_dir/"
}

# Resolve the non-root desktop user for ownership and Samba account actions.
local_non_root_user() {
  local local_user="${SUDO_USER:-${USER:-}}"

  [[ -n "$local_user" ]] || local_user="$(id -un)"
  [[ "$local_user" != "root" ]] || die "could not determine a non-root user"
  printf '%s\n' "$local_user"
}

# Snapshot target path before modifying it and register rollback command.
snapshot_target() {
  local target="$1"
  local snapshot="$target-pre-restore-$RESTORE_ID"

  [[ -e "$target" ]] || return 0
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

  require_all_cmds sudo cp mkdir rsync
  [[ -d "$source_dir" ]] || die "grub theme source folder not found: $source_dir"

  confirm_action "Restore grub theme" || return 0
  snapshot_target "$target_dir"
  log "Restoring grub theme: $source_dir -> /boot/grub/themes/"
  sudo mkdir -p "$target_dir"
  sudo_rsync_restore_copy "$source_dir/" "$target_dir/"

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
  local local_user
  local answer
  local -a creds_files=()
  local creds_file

  require_all_cmds sudo cp mkdir rsync chown chmod systemctl
  confirm_action "Restore samba" || return 0
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
      sudo_rsync_restore_copy "$creds_file" "$target_dir/"
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

  # Optionally register the local desktop user with Samba after config validation.
  local_user="$(local_non_root_user)"
  read -r -p "Add local user to samba ? [Yy/Nn] " answer
  case "$answer" in
  [Yy])
    require_cmd smbpasswd
    log "Adding local user to samba: smbpasswd -a $local_user"
    sudo smbpasswd -a "$local_user"
    ;;
  [Nn] | "")
    log "Skipping samba user add for: $local_user"
    ;;
  *)
    log "Skipping samba user add; invalid answer: $answer"
    ;;
  esac

  log "Enabling smb.service"
  sudo systemctl enable smb.service
  log "Starting smb.service"
  sudo systemctl start smb.service

  audit_log "action_completed"
  log "Done: Restore samba"
}

# Restore sshd_config into /etc/ssh/.
restore_ssh() {
  require_all_cmds sudo cp mkdir rsync chown chmod systemctl

  confirm_action "Restore SSH" || return 0
  snapshot_target "/etc/ssh/sshd_config"
  restore_file_to_dir "SSH" "sshd_config" "/etc/ssh"
  sudo chown root:root /etc/ssh/sshd_config
  sudo chmod 600 /etc/ssh/sshd_config
  if command -v sshd >/dev/null 2>&1; then
    sudo sshd -t || die "sshd config validation failed"
  fi
  log "Enabling sshd.service"
  sudo systemctl enable sshd.service
  log "Starting sshd.service"
  sudo systemctl start sshd.service
  audit_log "action_completed"
  log "Done: Restore SSH"
}

# Create SMB folders and set ownership/perms for the local non-root user.
create_smb_tree() {
  local local_user
  local dir

  require_all_cmds sudo mkdir chown chmod
  confirm_action "Create SMB" || return 0
  local_user="$(local_non_root_user)"

  for dir in "${SMB_DIRS[@]}"; do
    log "Ensuring SMB directory: $dir"
    sudo mkdir -p "$dir"
    sudo chown "$local_user:$local_user" "$dir"
    sudo chmod 750 "$dir"
  done

  audit_log "action_completed"
  log "Done: Create SMB"
}

# Replace entries for configured mountpoints in an fstab file.
replace_managed_fstab_entries() {
  local fstab_file="$1"
  local line
  local mount_target
  local filtered_fstab
  local -a managed_targets=()

  require_all_cmds awk mv mktemp
  filtered_fstab="$(mktemp)"
  register_temp_path "$filtered_fstab"

  for line in "${FSTAB_LINES[@]}"; do
    read -r _ mount_target _ <<<"$line"
    [[ -n "$mount_target" ]] || die "invalid configured fstab line: $line"
    managed_targets+=("$mount_target")
  done
  managed_targets+=("${RETIRED_FSTAB_TARGETS[@]}")

  for mount_target in "${managed_targets[@]}"; do
    awk -v target="$mount_target" '
      /^[[:space:]]*#/ || NF < 2 || $2 != target { print }
    ' "$fstab_file" >"$filtered_fstab"
    mv -- "$filtered_fstab" "$fstab_file"
  done

  printf '\n' >>"$fstab_file"
  for line in "${FSTAB_LINES[@]}"; do
    printf '%s\n' "$line" >>"$fstab_file"
  done
}

# Replace configured SMB mount targets in /etc/fstab.
restore_fstab() {
  local temp_fstab

  require_all_cmds sudo cp install mktemp modprobe
  confirm_action "Restore fstab" || return 0
  if [[ "${#FSTAB_LINES[@]}" -eq 0 && "${#RETIRED_FSTAB_TARGETS[@]}" -eq 0 ]]; then
    log "No SMB fstab entries configured; add local entries in config/local/serv.restore.conf"
    RUN_RESULT="skipped"
    audit_log "action_skipped"
    return 0
  fi

  log "Loading cifs kernel module"
  sudo modprobe cifs

  snapshot_target "/etc/fstab"

  temp_fstab="$(mktemp)"
  register_temp_path "$temp_fstab"
  sudo cp /etc/fstab "$temp_fstab"

  log "Replacing configured SMB mount entries in /etc/fstab (atomic update)"
  replace_managed_fstab_entries "$temp_fstab"

  if command -v findmnt >/dev/null 2>&1; then
    findmnt --verify --tab-file "$temp_fstab" >/dev/null || die "fstab validation failed"
  fi

  sudo install -m 0644 "$temp_fstab" /etc/fstab

  audit_log "action_completed"
  log "Done: Restore fstab"
}

# Set or append one quoted GRUB assignment inside a temp config file.
set_grub_assignment() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped

  require_all_cmds grep sed
  escaped="$(printf '%s' "$value" | sed 's/[&|]/\\&/g')"
  if grep -Eq "^#?${key}=" "$file"; then
    sed -i -E "s|^#?${key}=.*|${key}=\"${escaped}\"|" "$file"
  else
    printf '%s="%s"\n' "$key" "$value" >>"$file"
  fi
}

# Update GRUB defaults, then regenerate the boot menu from the restored values.
restore_grub_defaults() {
  local temp_grub

  require_all_cmds sudo cp install mktemp grep sed grub-mkconfig
  confirm_action "Restore GRUB" || return 0
  snapshot_target "/etc/default/grub"

  temp_grub="$(mktemp)"
  register_temp_path "$temp_grub"
  sudo cp /etc/default/grub "$temp_grub"

  log "Updating GRUB config: /etc/default/grub"
  sed -i -E 's|^GRUB_TERMINAL_INPUT=console|#GRUB_TERMINAL_INPUT=console|' "$temp_grub"
  set_grub_assignment "$temp_grub" "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_CMDLINE_LINUX_DEFAULT_VALUE"
  set_grub_assignment "$temp_grub" "GRUB_TERMINAL_OUTPUT" "$GRUB_TERMINAL_OUTPUT_VALUE"
  set_grub_assignment "$temp_grub" "GRUB_GFXMODE" "$GRUB_GFXMODE_VALUE"
  set_grub_assignment "$temp_grub" "GRUB_THEME" "$GRUB_THEME_VALUE"

  grep -Fqx "GRUB_THEME=\"$GRUB_THEME_VALUE\"" "$temp_grub" || die "grub theme line validation failed"
  sudo install -m 0644 "$temp_grub" /etc/default/grub
  log "Regenerating GRUB menu: /boot/grub/grub.cfg"
  sudo grub-mkconfig -o /boot/grub/grub.cfg
  audit_log "action_completed"
  log "Done: Restore GRUB"
}

# Return a non-conflicting target path inside the PreRestored collection folder.
unique_collect_target() {
  local collect_dir="$1"
  local source_path="$2"
  local name
  local candidate
  local counter=1

  name="$(basename -- "$source_path")"
  candidate="$collect_dir/$name"
  while [[ -e "$candidate" ]]; do
    candidate="$collect_dir/$name-$counter"
    counter=$((counter + 1))
  done

  printf '%s\n' "$candidate"
}

# Rewrite generated rollback scripts after a snapshot is moved into PreRestored.
update_rollback_snapshot_path() {
  local old_path="$1"
  local new_path="$2"
  local old_escaped
  local new_escaped
  local rollback_file
  local rollback_temp
  local -a rollback_files=()

  printf -v old_escaped '%q' "$old_path"
  printf -v new_escaped '%q' "$new_path"

  shopt -s nullglob
  rollback_files=("$SCRIPT_DIR"/restore-serv-rollback-*.sh)
  shopt -u nullglob

  for rollback_file in "${rollback_files[@]}"; do
    grep -Fq "$old_escaped" "$rollback_file" || continue
    rollback_temp="$(mktemp)"
    register_temp_path "$rollback_temp"
    awk -v old="$old_escaped" -v new="$new_escaped" '
      {
        line = $0
        while ((position = index(line, old)) > 0) {
          line = substr(line, 1, position - 1) new substr(line, position + length(old))
        }
        print line
      }
    ' "$rollback_file" >"$rollback_temp"
    chmod --reference="$rollback_file" "$rollback_temp"
    mv -- "$rollback_temp" "$rollback_file"
    log "Updated rollback snapshot path: $rollback_file"
  done
}

# Move service pre-restore snapshots into the same home folder used by restore-dots.
collect_pre_restore() {
  local collect_dir="$HOME/PreRestored"
  local source_path
  local target_path
  local count=0
  local -a search_dirs=(
    "/etc"
    "/etc/default"
    "/etc/samba"
    "/etc/ssh"
    "/boot/grub/themes"
  )
  local -a source_paths=()
  local dir

  require_all_cmds sudo find mv mkdir grep mktemp
  confirm_action "Collect pre-restore" || return 0
  mkdir -p "$collect_dir"

  mapfile -d '' -t source_paths < <(
    for dir in "${search_dirs[@]}"; do
      [[ -d "$dir" ]] || continue
      sudo find "$dir" -maxdepth 1 -name '*-pre-restore-*' -print0
    done
  )

  for source_path in "${source_paths[@]}"; do
    [[ -e "$source_path" ]] || continue
    target_path="$(unique_collect_target "$collect_dir" "$source_path")"
    log "Moving pre-restore snapshot: $source_path -> $target_path"
    sudo mv -- "$source_path" "$target_path"
    update_rollback_snapshot_path "$source_path" "$target_path"
    count=$((count + 1))
  done

  audit_log "action_completed"
  log "Done: Collect pre-restore ($count item(s) moved to $collect_dir)"
}

# Initialize rollback helper script for this restore run.
init_rollback_script() {
  require_cmd chmod

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

  if [[ "$exit_code" -eq 0 ]]; then
    RUN_RESULT="success"
    audit_log "completed"
  else
    RUN_RESULT="failed"
    audit_log "failed"
  fi
}

parse_common_args "$@"
if [[ "${SCRIPT_ARGS[0]:-}" == "-h" || "${SCRIPT_ARGS[0]:-}" == "--help" ]]; then
  usage
  exit 0
fi

preflight_checks

log "Restore source: $SCRIPT_DIR"
log "Service restore config: ${SERVICE_RESTORE_CONFIG:-built-in defaults}"
verify_backup_status
init_rollback_script
audit_log "started"
trap 'finalize_restore "$?"; cleanup_temp_paths; ui_cleanup' EXIT
log "Requesting root authentication"
sudo -v || die "sudo authentication failed"

# Keep showing menu until user selects Exit.
while true; do
  show_menu
  read -r -p "Enter selection: " selection

  # Dispatch menu options to their matching functions.
  case "$selection" in
  0)
    log "Exit selected"
    exit 0
    ;;
  1)
    create_smb_tree
    ;;
  2)
    restore_samba
    ;;
  3)
    restore_ssh
    ;;
  4)
    restore_fstab
    ;;
  5)
    restore_grub_theme
    ;;
  6)
    restore_grub_defaults
    ;;
  98)
    collect_pre_restore
    ;;
  *)
    log_warn "invalid selection: $selection"
    ;;
  esac
done
