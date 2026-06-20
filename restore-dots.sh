#!/usr/bin/env bash

# DOTS actions operate from the folder where this script is located.
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

LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore-dots.log}"
RESTORE_ID="$(date '+%j-%d-%m-%H-%M-%S')"
ML4W_CONFIG_ROOT="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config"

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./restore-dots.sh [--quiet]

Run dotfiles restore actions from the current DOTS folder.
EOF
}

# Ensure base dependencies exist before menu actions start.
preflight_checks() {
  require_all_cmds rsync cp mv mkdir mktemp sed
}

# Show the currently available dotfiles restore actions.
show_menu() {
  cat <<'EOF'
Select action:
  0 - Exit
  1 - Install DOTS
  2 - Restore Wallpapers
  3 - Restore FastFetch
  4 - Restore KITTY
  5 - Restore ROFI
  6 - Restore WAYBAR
  7 - Restore HYPR
  8 - Install FONTS
EOF
}

# Move an existing target aside before restore instead of deleting it.
snapshot_existing_target() {
  local target="$1"
  local snapshot="$target-pre-restore-$RESTORE_ID"

  [[ -e "$target" ]] || return 0
  [[ ! -e "$snapshot" ]] || die "snapshot already exists: $snapshot"

  log "Moving existing target to safety snapshot: $snapshot"
  mv -- "$target" "$snapshot"
}

# Confirm an action before it changes local configuration.
confirm_action() {
  local label="$1"

  confirm_yes_no "Start $label?" "N" || {
    log "$label cancelled"
    return 1
  }

  return 0
}

# Install ML4W stable DOTS after removing the current Hypr configuration.
install_dots() {
  require_cmd bash
  require_cmd curl

  local installer_url="https://ml4w.com/os/stable"
  local installer_file

  confirm_action "Install DOTS" || return 0
  log "DOTS source folder: $SCRIPT_DIR"
  snapshot_existing_target "$HOME/.config/hypr"

  installer_file="$(mktemp)"
  register_temp_path "$installer_file"
  log "Downloading ML4W stable installer: $installer_url"
  curl --fail --show-error --location --proto '=https' --tlsv1.2 \
    --output "$installer_file" \
    "$installer_url"

  log "Downloaded installer to: $installer_file"
  log "Installer preview (first 20 lines):"
  sed -n '1,20p' "$installer_file"
  confirm_yes_no "Execute downloaded installer now?" "N" || {
    log "Installer execution cancelled by user"
    return 0
  }

  log "Running ML4W stable installer"
  bash "$installer_file"
  log "Done: Install DOTS"
}

# Restore a DOTS subfolder into the matching ML4W config path.
restore_config_path() {
  local label="$1"
  local source_rel="$2"
  local target_rel="$3"
  local source_dir="$SCRIPT_DIR/$source_rel"
  local target_dir="$ML4W_CONFIG_ROOT/$target_rel"

  require_cmd rsync
  [[ -d "$source_dir" ]] || die "$label source folder not found: $source_dir"

  confirm_action "Restore $label" || return 0
  snapshot_existing_target "$target_dir"

  log "Restoring $label from: $source_dir"
  mkdir -p "$(dirname -- "$target_dir")"
  rsync_restore_copy "$source_dir/" "$target_dir/"
  log "Done: Restore $label"
}

# Restore one file from DOTS into the matching ML4W config path.
restore_config_file() {
  local label="$1"
  local source_rel="$2"
  local target_rel="$3"
  local source_file="$SCRIPT_DIR/$source_rel"
  local target_file="$ML4W_CONFIG_ROOT/$target_rel"

  [[ -f "$source_file" ]] || die "$label source file not found: $source_file"

  log "Restoring $label file: $source_rel"
  mkdir -p "$(dirname -- "$target_file")"
  cp -a -- "$source_file" "$target_file"
}

# Replace the ML4W wallpapers folder from the current DOTS backup.
restore_wallpapers() {
  restore_config_path "Wallpapers" "ml4w/wallpapers" "ml4w/wallpapers"
}

# Replace the FastFetch config folder from the current DOTS backup.
restore_fastfetch() {
  restore_config_path "FastFetch" "fastfetch" "fastfetch"
}

# Replace the KITTY config folder from the current DOTS backup.
restore_kitty() {
  restore_config_path "KITTY" "kitty" "kitty"
}

# Replace the ROFI config folder from the current DOTS backup.
restore_rofi() {
  restore_config_path "ROFI" "rofi" "rofi"
}

# Save the current WAYBAR themes as themes-bkp, then restore backed-up themes.
restore_waybar() {
  local source_dir="$SCRIPT_DIR/waybar/themes"
  local target_dir="$ML4W_CONFIG_ROOT/waybar/themes"
  local backup_dir="$ML4W_CONFIG_ROOT/waybar/themes-bkp"

  require_cmd rsync
  [[ -d "$source_dir" ]] || die "waybar themes source folder not found: $source_dir"

  confirm_action "Restore WAYBAR" || return 0
  if [[ -e "$target_dir" ]]; then
    [[ ! -e "$backup_dir" ]] || die "backup folder already exists: $backup_dir"
    log "Renaming: $target_dir -> $backup_dir"
    mv -- "$target_dir" "$backup_dir"
  else
    log "Skipping rename; target folder not found: $target_dir"
  fi

  log "Restoring WAYBAR themes from: $source_dir"
  mkdir -p "$(dirname -- "$target_dir")"
  rsync_restore_copy "$source_dir/" "$target_dir/"
  log "Done: Restore WAYBAR"
}

# Restore selected Hypr files from DOTS into the ML4W hypr config tree.
restore_hypr() {
  confirm_action "Restore HYPR" || return 0
  restore_config_file "HYPR" "hypr/conf/keybindings/default.lua" "hypr/conf/keybindings/default.lua"
  restore_config_file "HYPR" "hypr/conf/monitor.lua" "hypr/conf/monitor.lua"
  restore_config_file "HYPR" "hypr/hypridle.conf" "hypr/hypridle.conf"
  restore_config_file "HYPR" "hypr/hyprlock.conf" "hypr/hyprlock.conf"
  restore_config_file "HYPR" "hypr/logo-2.png" "hypr/logo-2.png"
  restore_config_file "HYPR" "hypr/scripts/uptime.sh" "hypr/scripts/uptime.sh"
  log "Done: Restore HYPR"
}

# Run BIG/fonts/install.sh from the backup device root to install fonts.
install_fonts() {
  local device_root=""
  local candidate_local="$SCRIPT_DIR/BIG/fonts/install.sh"
  local candidate_device=""
  local installer=""

  if device_root="$(cd -- "$SCRIPT_DIR/../../.." 2>/dev/null && pwd)"; then
    candidate_device="$device_root/BIG/fonts/install.sh"
  fi

  if [[ -f "$candidate_device" ]]; then
    installer="$candidate_device"
  elif [[ -f "$candidate_local" ]]; then
    installer="$candidate_local"
  else
    die "fonts installer not found. Expected BIG/fonts/install.sh on backup device"
  fi

  require_cmd bash
  confirm_action "Install fonts" || return 0
  log "Running fonts installer: $installer"
  bash "$installer"
  log "Done: Install fonts"
}

parse_common_args "$@"
if [[ "${SCRIPT_ARGS[0]:-}" == "-h" || "${SCRIPT_ARGS[0]:-}" == "--help" ]]; then
  usage
  exit 0
fi

preflight_checks
setup_cleanup_trap

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
    install_dots
    ;;
  2)
    restore_wallpapers
    ;;
  3)
    restore_fastfetch
    ;;
  4)
    restore_kitty
    ;;
  5)
    restore_rofi
    ;;
  6)
    restore_waybar
    ;;
  7)
    restore_hypr
    ;;
  8)
    install_fonts
    ;;
  *)
    log "Invalid selection: $selection"
    ;;
  esac
done
