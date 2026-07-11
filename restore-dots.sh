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

RESTORE_LOG_ROOT="$SCRIPT_DIR"
if [[ -f "$SCRIPT_DIR/../backup-manifest.txt" ]]; then
  RESTORE_LOG_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
fi
LOG_FILE="${LOG_FILE:-$RESTORE_LOG_ROOT/restore.log}"
RESTORE_ID="$(date '+%j-%d-%m-%H-%M-%S')"
ML4W_CONFIG_ROOT="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config"
RESTORE_SETTINGS_LOCAL_HOOK="$SCRIPT_DIR/config/local/restore-dots-settings.sh"

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./restore-dots.sh [--quiet]

Run dotfiles restore actions from the current DOTS folder.
EOF
}

# Ensure base dependencies exist before menu actions start.
preflight_checks() {
  require_all_cmds rsync cp mv mkdir mktemp sed find
}

# Show the currently available dotfiles restore actions.
show_menu() {
  cat <<'EOF'
Select action:
  0 - Exit
============================
  1 - Install DOTS
  2 - Install FONTS
============================
  3 - Restore Wallpapers
  4 - Install HyprMod
  5 - Restore FASTFETCH
  6 - Restore KITTY
  7 - Restore ZSHRC
  8 - Restore HYPR
  9 - Restore ROFI
  10 - Restore WAYBAR
  11 - Restore MATUGEN
============================
  98 - Collect pre-restore
  99 - Restore Settings
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

# Restore one folder from DOTS into the matching ML4W config path after action confirmation.
restore_config_folder() {
  local label="$1"
  local source_rel="$2"
  local target_rel="$3"
  local source_dir="$SCRIPT_DIR/$source_rel"
  local target_dir="$ML4W_CONFIG_ROOT/$target_rel"

  require_cmd rsync
  [[ -d "$source_dir" ]] || die "$label source folder not found: $source_dir"

  snapshot_existing_target "$target_dir"
  log "Restoring $label folder: $source_rel"
  mkdir -p "$(dirname -- "$target_dir")"
  rsync_restore_copy "$source_dir/" "$target_dir/"
}

# Normalize quickshell overview fonts after restoring the backed-up config.
customize_quickshell_overview_config() {
  local target_file="$ML4W_CONFIG_ROOT/quickshell/overview/config.json"

  [[ -f "$target_file" ]] || die "quickshell overview config target file not found: $target_file"

  log "Customizing quickshell overview config: $target_file"
  sed -i -E \
    -e 's|^([[:space:]]*"main":[[:space:]]*)"Fira Sans Semibold"|\1"Monofur Nerd Font"|' \
    -e 's|^([[:space:]]*"title":[[:space:]]*)"Fira Sans Semibold"|\1"Monofur Nerd Font"|' \
    -e 's|^([[:space:]]*"expressive":[[:space:]]*)"Fira Sans Semibold"|\1"Monofur Nerd Font"|' \
    "$target_file"
}

# Replace the ML4W wallpapers folder from the current DOTS backup.
restore_wallpapers() {
  restore_config_path "Wallpapers" "ml4w/wallpapers" "ml4w/wallpapers"
}

# Run the ML4W HyprMod installer from the restored dotfiles tree.
install_hyprmod() {
  local installer="$ML4W_CONFIG_ROOT/ml4w/scripts/ml4w-install-hyprmod"

  require_cmd bash
  [[ -f "$installer" ]] || die "HyprMod installer not found: $installer"

  confirm_action "Install HyprMod" || return 0
  log "Running HyprMod installer: $installer"
  bash "$installer"
  log "Done: Install HyprMod"
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
  restore_config_file "HYPR" "hypr/conf/windowrules/default.lua" "hypr/conf/windowrules/default.lua"
  restore_config_file "HYPR" "hypr/hypridle.conf" "hypr/hypridle.conf"
  restore_config_file "HYPR" "hypr/hyprlock.conf" "hypr/hyprlock.conf"
  restore_config_file "HYPR" "hypr/hyprland-gui.lua" "hypr/hyprland-gui.lua"
  restore_config_file "HYPR" "hypr/logo-2.png" "hypr/logo-2.png"
  restore_config_file "HYPR" "hypr/scripts/uptime.sh" "hypr/scripts/uptime.sh"
  restore_config_file "HYPR" "waybar/modules.json" "waybar/modules.json"
  restore_config_file "HYPR" "gtk-3.0/bookmarks" "gtk-3.0/bookmarks"
  restore_config_folder "HYPR" "quickshell/CalendarApp" "quickshell/CalendarApp"
  restore_config_folder "HYPR" "quickshell/CustomTheme" "quickshell/CustomTheme"
  restore_config_folder "HYPR" "quickshell/PowerApp" "quickshell/PowerApp"
  restore_config_folder "HYPR" "quickshell/SidebarApp" "quickshell/SidebarApp"
  restore_config_folder "HYPR" "quickshell/WallpaperApp" "quickshell/WallpaperApp"
  restore_config_folder "HYPR" "quickshell/WelcomeApp" "quickshell/WelcomeApp"
  restore_config_file "HYPR" "quickshell/overview/config.json" "quickshell/overview/config.json"
  customize_quickshell_overview_config
  log "Done: Restore HYPR"
}

restore_zshrc() {
  restore_config_path "ZSHRC" "zshrc" "zshrc"
}

# Restore the matugen theme generator config from DOTS.
restore_matugen() {
  confirm_action "Restore MATUGEN" || return 0
  restore_config_file "MATUGEN" "matugen/config.toml" "matugen/config.toml"
  log "Done: Restore MATUGEN"
}

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

# Move pre-restore snapshots into one home folder for easier review/removal.
collect_pre_restore() {
  local collect_dir="$HOME/PreRestored"
  local source_path
  local target_path
  local count=0
  local -a source_paths=()

  confirm_action "Collect pre-restore" || return 0
  mkdir -p "$collect_dir"

  mapfile -d '' -t source_paths < <(
    find "$HOME" \
      -path "$collect_dir" -prune -o \
      -name '*-pre-restore-*' -print0 -type d -prune
  )

  for source_path in "${source_paths[@]}"; do
    [[ -e "$source_path" ]] || continue
    target_path="$(unique_collect_target "$collect_dir" "$source_path")"
    log "Moving pre-restore snapshot: $source_path -> $target_path"
    mv -- "$source_path" "$target_path"
    count=$((count + 1))
  done

  log "Done: Collect pre-restore ($count item(s) moved to $collect_dir)"
}

run_restore_settings_local_hook() {
  [[ -f "$RESTORE_SETTINGS_LOCAL_HOOK" ]] || {
    log "Skipping local Restore Settings hook; not found: $RESTORE_SETTINGS_LOCAL_HOOK"
    return 0
  }

  require_cmd git
  log "Running local Restore Settings hook: $RESTORE_SETTINGS_LOCAL_HOOK"
  # shellcheck source=/dev/null
  source "$RESTORE_SETTINGS_LOCAL_HOOK"
}

# Apply local visual preferences after restoring the backed-up wlogout glass theme.
customize_wlogout_glass_style() {
  local target_file="$ML4W_CONFIG_ROOT/wlogout/themes/glass/style.css"

  [[ -f "$target_file" ]] || die "wlogout glass style target file not found: $target_file"

  log "Customizing wlogout glass style: $target_file"
  sed -i -E \
    's|^([[:space:]]*)font-family:[[:space:]]*.+$|\1font-family: "Monofur Nerd Font", FontAwesome, Roboto, Helvetica, Arial, sans-serif;|' \
    "$target_file"
  sed -i 's|border-radius: 20px;|border-radius: 5px;|g' "$target_file"
}

customize_thunar_custom_actions() {
  local target_file="$HOME/.config/Thunar/uca.xml"

  if [[ ! -f "$target_file" ]]; then
    log_warn "Skipping Thunar custom action update; file not found: $target_file"
    return 0
  fi

  log "Customizing Thunar custom actions: $target_file"
  sed -i -E 's|^([[:space:]]*)<command>.*</command>[[:space:]]*$|\1<command>kitty</command>|' "$target_file"
}

restore_qbittorrent_theme() {
  local device_root=""
  local source_file=""
  local target_file="$HOME/.config/qBittorrent/dracula.qbtheme"

  device_root="$(cd -- "$SCRIPT_DIR/../../.." 2>/dev/null && pwd)" || die "could not resolve backup device root from: $SCRIPT_DIR"
  source_file="$device_root/BIG/dracula.qbtheme"
  [[ -f "$source_file" ]] || die "qBittorrent theme file not found: $source_file"

  log "Restoring qBittorrent theme: $source_file -> $target_file"
  mkdir -p "$(dirname -- "$target_file")"
  cp -a -- "$source_file" "$target_file"
}

restore_settings() {
  confirm_action "Restore Settings" || return 0

  # Toolkit theme settings.
  restore_config_file "Settings" "gtk-3.0/settings.ini" "gtk-3.0/settings.ini"
  restore_config_file "Settings" "gtk-4.0/settings.ini" "gtk-4.0/settings.ini"
  restore_config_file "Settings" "qt6ct/qt6ct.conf" "qt6ct/qt6ct.conf"

  # ML4W settings files.
  restore_config_file "Settings" "ml4w/settings/filemanager" "ml4w/settings/filemanager"
  restore_config_file "Settings" "ml4w/settings/kitty-cursor-trail.conf" "ml4w/settings/kitty-cursor-trail.conf"
  restore_config_file "Settings" "ml4w/settings/rofi-border-radius.rasi" "ml4w/settings/rofi-border-radius.rasi"
  restore_config_file "Settings" "ml4w/settings/rofi-border.rasi" "ml4w/settings/rofi-border.rasi"
  restore_config_file "Settings" "ml4w/settings/rofi-font.rasi" "ml4w/settings/rofi-font.rasi"
  restore_config_file "Settings" "ml4w/settings/rofi_bordersize.sh" "ml4w/settings/rofi_bordersize.sh"
  restore_config_file "Settings" "ml4w/settings/screenshot-editor" "ml4w/settings/screenshot-editor"
  restore_config_file "Settings" "ml4w/settings/screenshot-folder" "ml4w/settings/screenshot-folder"
  restore_config_file "Settings" "ml4w/settings/terminal.sh" "ml4w/settings/terminal.sh"
  restore_config_file "Settings" "ml4w/settings/waybar-quicklinks.json" "ml4w/settings/waybar-quicklinks.json"
  restore_config_file "Settings" "ml4w/settings/waybar_quicklinks.sh" "ml4w/settings/waybar_quicklinks.sh"
  restore_config_file "Settings" "ml4w/settings/waybar_workspaces.sh" "ml4w/settings/waybar_workspaces.sh"

  # Wlogout theme plus local post-restore style edits.
  restore_config_file "Settings" "wlogout/themes/glass/style.css" "wlogout/themes/glass/style.css"
  customize_wlogout_glass_style
  customize_thunar_custom_actions
  restore_qbittorrent_theme

  run_restore_settings_local_hook
  log "Done: Restore Settings"
}

# Run BIG/fonts/install.sh from the backup device root to install fonts.
install_fonts() {
  local device_root=""
  local candidate_local="$SCRIPT_DIR/BIG/fonts/install.sh"
  local candidate_device=""
  local installer=""
  local big_root=""
  local steelfish_font=""
  local target_font_dir="$HOME/.local/share/fonts"

  if device_root="$(cd -- "$SCRIPT_DIR/../../.." 2>/dev/null && pwd)"; then
    candidate_device="$device_root/BIG/fonts/install.sh"
  fi

  if [[ -f "$candidate_device" ]]; then
    installer="$candidate_device"
    big_root="$device_root/BIG"
  elif [[ -f "$candidate_local" ]]; then
    installer="$candidate_local"
    big_root="$SCRIPT_DIR/BIG"
  else
    die "fonts installer not found. Expected BIG/fonts/install.sh on backup device"
  fi

  steelfish_font="$big_root/Steelfish Outline.ttf"
  [[ -f "$steelfish_font" ]] || die "Steelfish font file not found: $steelfish_font"

  require_cmd bash
  confirm_action "Install fonts" || return 0
  log "Running fonts installer: $installer"
  bash "$installer"
  log "Installing font file: $steelfish_font -> $target_font_dir"
  mkdir -p "$target_font_dir"
  cp -a -- "$steelfish_font" "$target_font_dir/"
  if command -v fc-cache >/dev/null 2>&1; then
    log "Refreshing font cache: $target_font_dir"
    fc-cache -f "$target_font_dir"
  fi
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
    install_fonts
    ;;
  3)
    restore_wallpapers
    ;;
  4)
    install_hyprmod
    ;;
  5)
    restore_fastfetch
    ;;
  6)
    restore_kitty
    ;;
  7)
    restore_zshrc
    ;;
  8)
    restore_hypr
    ;;
  9)
    restore_rofi
    ;;
  10)
    restore_waybar
    ;;
  11)
    restore_matugen
    ;;
  98)
    collect_pre_restore
    ;;
  99)
    restore_settings
    ;;
  *)
    log "Invalid selection: $selection"
    ;;
  esac
done
