#!/usr/bin/env bash

# Exit on errors, unset variables, and failed pipeline commands.
set -Eeuo pipefail

# DOTS actions operate from the folder where this script is located.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore-dots.log}"
RESTORE_ID="$(date '+%j-%d-%m-%H-%M-%S')"
ML4W_CONFIG_ROOT="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config"

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
Usage: ./restore-dots.sh

Run dotfiles restore actions from the current DOTS folder.
EOF
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
  8 - Install fonts
EOF
}

# Move an existing target aside before restore instead of deleting it.
snapshot_existing_target() {
  local target="$1"
  local snapshot="$target-pre-restore-$RESTORE_ID"

  [[ -e "$target" ]] || return
  [[ ! -e "$snapshot" ]] || die "snapshot already exists: $snapshot"

  log "Moving existing target to safety snapshot: $snapshot"
  mv -- "$target" "$snapshot"
}

# Confirm an action before it changes local configuration.
confirm_action() {
  local label="$1"

  confirm_yes_no "Start $label?" "N" || {
    log "$label cancelled"
    exit 0
  }
}

# Install ML4W stable DOTS after removing the current Hypr configuration.
install_dots() {
  require_cmd bash
  require_cmd curl

  confirm_action "Install DOTS"
  log "DOTS source folder: $SCRIPT_DIR"
  snapshot_existing_target "$HOME/.config/hypr"

  log "Running ML4W stable installer"
  bash <(curl -s https://ml4w.com/os/stable)
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

  confirm_action "Restore $label"
  snapshot_existing_target "$target_dir"

  log "Restoring $label from: $source_dir"
  mkdir -p "$(dirname -- "$target_dir")"
  rsync -aAXH --numeric-ids --info=progress2 "$source_dir/" "$target_dir/"
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

  confirm_action "Restore WAYBAR"
  if [[ -e "$target_dir" ]]; then
    [[ ! -e "$backup_dir" ]] || die "backup folder already exists: $backup_dir"
    log "Renaming: $target_dir -> $backup_dir"
    mv -- "$target_dir" "$backup_dir"
  else
    log "Skipping rename; target folder not found: $target_dir"
  fi

  log "Restoring WAYBAR themes from: $source_dir"
  mkdir -p "$(dirname -- "$target_dir")"
  rsync -aAXH --numeric-ids --info=progress2 "$source_dir/" "$target_dir/"
  log "Done: Restore WAYBAR"
}

# Restore selected Hypr files from DOTS into the ML4W hypr config tree.
restore_hypr() {
  confirm_action "Restore HYPR"
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
  confirm_action "Install fonts"
  log "Running fonts installer: $installer"
  bash "$installer"
  log "Done: Install fonts"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Read the user's menu selection and run the selected action.
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
    die "invalid selection: $selection"
    ;;
esac
