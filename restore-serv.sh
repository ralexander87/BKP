#!/usr/bin/env bash

# Service restore runs from the backup folder where this script is located.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Load shared helpers when bundled, but keep this restore script usable by itself.
# BEGIN RESTORE BOOTSTRAP
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
    local line

    line="[$(date '+%Y-%m-%dT%H:%M:%S%z')] [$level] [$SCRIPT_NAME] $*"
    [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "$line" >>"$LOG_FILE"
    [[ "$QUIET" == "true" && "$level" == "INFO" ]] || printf '%s\n' "$line"
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

LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore-serv.log}"
RESTORE_ID="$(date '+%j-%d-%m-%H-%M-%S')"
AUDIT_FILE="$SCRIPT_DIR/restore-serv-audit.log"
ROLLBACK_FILE="$SCRIPT_DIR/restore-serv-rollback-$RESTORE_ID.sh"
RUN_RESULT="failed"
CURRENT_ACTION="none"
STATUS_FILE="$SCRIPT_DIR/backup.status"
SERVICE_RESTORE_CONFIG=""

set_service_restore_defaults() {
  SMB_DIRS=(
    "/SMB"
    "/SMB/euclid"
    "/SMB/pneuma"
    "/SMB/lateralus"
    "/SMB/SCP"
    "/SMB/SCP/HDD-01"
    "/SMB/SCP/HDD-02"
    "/SMB/SCP/HDD-03"
  )

  FSTAB_LINES=(
    '//192.168.8.20/d   /SMB/euclid   cifs   _netdev,credentials=/etc/samba/creds-euclid,uid=1000,gid=1000   0 0'
    '//192.168.8.101/hd-01   /SMB/SCP/HDD-01   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0'
    '//192.168.8.101/hd-02   /SMB/SCP/HDD-02   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0'
    '//192.168.8.101/hd-03   /SMB/SCP/HDD-03   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0'
  )

  GRUB_CMDLINE_LINUX_DEFAULT_VALUE="loglevel=3 quiet splash"
  GRUB_TERMINAL_OUTPUT_VALUE="gfxterm"
  GRUB_GFXMODE_VALUE="1440x1080x32"
  GRUB_THEME_VALUE="/boot/grub/themes/lateralus/theme.txt"
}

load_service_restore_config() {
  local candidate
  local -a candidates=(
    "$SCRIPT_DIR/config/serv.restore.conf"
    "$SCRIPT_DIR/serv.restore.conf"
  )

  set_service_restore_defaults

  if [[ -n "${PROJECT_ROOT:-}" ]]; then
    candidates+=("$PROJECT_ROOT/config/serv.restore.conf")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      # shellcheck source=config/serv.restore.conf
      source "$candidate"
      SERVICE_RESTORE_CONFIG="$candidate"
      return 0
    fi
  done
}

load_service_restore_config

# Record structured audit entries for this restore run.
audit_log() {
  local event="$1"
  printf '%s event=%s action=%s result=%s rollback=%s\n' "$(date -Is)" "$event" "$CURRENT_ACTION" "$RUN_RESULT" "$ROLLBACK_FILE" >>"$AUDIT_FILE"
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
  require_all_cmds rsync sudo cp sed grep tee modprobe findmnt install mktemp
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
  sudo_rsync_restore_copy "$source_file" "$target_dir/"
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
  local -a creds_files=()
  local creds_file

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

  audit_log "action_completed"
  log "Done: Restore samba"
}

# Restore sshd_config into /etc/ssh/.
restore_ssh() {
  confirm_action "Restore SSH" || return 0
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

  [[ -n "$local_user" ]] || local_user="$(id -un)"
  [[ "$local_user" != "root" ]] || die "could not determine a non-root user for ownership"

  confirm_action "Create SMB" || return 0

  for dir in "${SMB_DIRS[@]}"; do
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
  local temp_fstab

  confirm_action "Restore fstab" || return 0
  snapshot_target "/etc/fstab"

  log "Loading cifs kernel module"
  sudo modprobe cifs

  for line in "${FSTAB_LINES[@]}"; do
    if ! sudo grep -Fqx "$line" /etc/fstab; then
      new_lines+=("$line")
    fi
  done

  if [[ "${#new_lines[@]}" -eq 0 ]]; then
    log "All SMB fstab entries already exist; no append needed"
  else
    temp_fstab="$(mktemp)"
    register_temp_path "$temp_fstab"
    sudo cp /etc/fstab "$temp_fstab"

    log "Appending missing SMB mount entries to /etc/fstab (atomic update)"
    printf '\n' >>"$temp_fstab"
    for line in "${new_lines[@]}"; do
      printf '%s\n' "$line" >>"$temp_fstab"
    done

    sudo install -m 0644 "$temp_fstab" /etc/fstab
  fi

  if command -v findmnt >/dev/null 2>&1; then
    sudo findmnt --verify >/dev/null || die "fstab validation failed"
  fi

  audit_log "action_completed"
  log "Done: Restore fstab"
}

set_grub_assignment() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped

  escaped="$(printf '%s' "$value" | sed 's/[&|]/\\&/g')"
  if grep -Eq "^#?${key}=" "$file"; then
    sed -i -E "s|^#?${key}=.*|${key}=\"${escaped}\"|" "$file"
  else
    printf '%s="%s"\n' "$key" "$value" >>"$file"
  fi
}

# Update GRUB defaults in /etc/default/grub to the expected values.
restore_grub_defaults() {
  local temp_grub

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
    log_warn "invalid selection: $selection"
    ;;
  esac
done
