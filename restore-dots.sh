#!/usr/bin/env bash

# DOTS actions operate from the folder where this script is located.
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
  LOG_MAX_BYTES="${LOG_MAX_BYTES:-5242880}"
  LOG_ROTATE_COUNT="${LOG_ROTATE_COUNT:-5}"
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
  rotate_log_file() {
    local log_file="$1"
    local max_bytes="${2:-$LOG_MAX_BYTES}"
    local keep_count="${3:-$LOG_ROTATE_COUNT}"
    local size index

    [[ -f "$log_file" ]] || return 0
    command -v stat >/dev/null 2>&1 || return 0
    size="$(stat -c %s "$log_file" 2>/dev/null || printf '0')"
    ((size >= max_bytes)) || return 0
    if ((keep_count == 0)); then
      : >"$log_file"
      return 0
    fi
    rm -f -- "$log_file.$keep_count"
    for ((index = keep_count - 1; index >= 1; index--)); do
      [[ -e "$log_file.$index" ]] && mv -f -- "$log_file.$index" "$log_file.$((index + 1))"
    done
    mv -f -- "$log_file" "$log_file.1"
  }
  init_log_file() {
    [[ -n "${LOG_FILE:-}" ]] || return 0
    mkdir -p "$(dirname -- "$LOG_FILE")"
    rotate_log_file "$LOG_FILE"
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
DOTS_EXTRA_CONFIG="$SCRIPT_DIR/config/dots-extra.conf"
MAIN_BACKUP_CONFIG="$SCRIPT_DIR/config/main.backup.conf"
SDDM_CONFIG="${SDDM_CONFIG:-/usr/lib/sddm/sddm.conf.d/default.conf}"
INSTALL_EXTRA_LOG="$SCRIPT_DIR/install-extra.log"

# Load package and Flatpak choices bundled with this DOTS backup.
load_dots_extra_config() {
  [[ -f "$DOTS_EXTRA_CONFIG" ]] || die "dotfiles extra config not found: $DOTS_EXTRA_CONFIG"
  # shellcheck source=config/dots-extra.conf
  source "$DOTS_EXTRA_CONFIG"
}

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./restore-dots.sh [--quiet]

Run dotfiles restore actions from the current DOTS folder.
EOF
}

# Ensure base dependencies exist before menu actions start.
preflight_checks() {
  require_all_cmds rsync cp mv mkdir mktemp sed find tee cat
}

# Return the configured login shell for the current user.
current_login_shell() {
  local shell_path=""

  if command -v getent >/dev/null 2>&1; then
    shell_path="$(getent passwd "${USER:-}" 2>/dev/null | awk -F: '{ print $7; exit }')"
  fi

  printf '%s\n' "${shell_path:-${SHELL:-}}"
}

# Resolve the non-root desktop user for local system configuration.
local_non_root_user() {
  local local_user="${SUDO_USER:-${USER:-}}"

  [[ -n "$local_user" ]] || local_user="$(id -un)"
  [[ "$local_user" != "root" ]] || die "could not determine a non-root user"
  id -u "$local_user" >/dev/null 2>&1 || die "local user does not exist: $local_user"
  printf '%s\n' "$local_user"
}

# Show the currently available dotfiles restore actions.
show_menu() {
  cat <<'EOF'
Select action:
  0 - Exit
============================
  1 - Install DOTS
  2 - Install FONTS
  3 - Install HyprMod
  4 - Install Extra
  5 - Set AutoLogin
============================
  10 - Restore Wallpapers
  11 - Restore ZSHRC
  12 - Restore KITTY
  13 - Restore FASTFETCH
  14 - Restore HYPR
  15 - Restore ROFI
  16 - Restore WAYBAR
  17 - Restore MATUGEN
  18 - Restore CAVA
  19 - Restore SWAYNC
  20 - Restore WLOGOUT
============================
  98 - Collect pre-restore
  99 - Restore Settings
EOF
}

# Move an existing target aside before restore instead of deleting it.
snapshot_existing_target() {
  local target="$1"
  local snapshot="$target-pre-restore-$RESTORE_ID"

  [[ -e "$target" || -L "$target" ]] || return 0
  [[ ! -e "$snapshot" && ! -L "$snapshot" ]] || die "snapshot already exists: $snapshot"

  log "Moving existing target to safety snapshot: $snapshot"
  mv -- "$target" "$snapshot"
}

# Confirm an action before it changes local configuration.
confirm_action() {
  local label="$1"

  confirm_yes_no "Start $label?" "Y" || {
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

# Resolve the backup device root from a script running inside MAIN/BKP-*/DOTS.
resolve_backup_device_root() {
  cd -- "$SCRIPT_DIR/../../.." 2>/dev/null && pwd
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

# Replace the ML4W wallpapers folder from the shared BIG/wallpapers backup.
restore_wallpapers() {
  local device_root
  local source_dir
  local big_wallpapers_relative="BIG/wallpapers"
  local wallpapers_dots_relative="ml4w/wallpapers"
  local target_dir

  if [[ -f "$MAIN_BACKUP_CONFIG" ]]; then
    # shellcheck source=config/main.backup.conf
    source "$MAIN_BACKUP_CONFIG"
    big_wallpapers_relative="$BIG_WALLPAPERS_RELATIVE"
    wallpapers_dots_relative="$WALLPAPERS_DOTS_RELATIVE"
  fi

  require_cmd rsync
  device_root="$(resolve_backup_device_root)" || die "could not resolve backup device root from: $SCRIPT_DIR"
  source_dir="$device_root/$big_wallpapers_relative"
  target_dir="$ML4W_CONFIG_ROOT/$wallpapers_dots_relative"
  [[ -d "$source_dir" ]] || die "wallpapers source folder not found: $source_dir"

  confirm_action "Restore Wallpapers" || return 0
  snapshot_existing_target "$target_dir"

  log "Restoring Wallpapers from: $source_dir"
  mkdir -p "$(dirname -- "$target_dir")"
  rsync_restore_copy "$source_dir/" "$target_dir/"
  log "Done: Restore Wallpapers"
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

# Start a fresh detailed log for one Install Extra run.
init_install_extra_log() {
  INSTALL_EXTRA_STARTED="$(date --iso-8601=seconds)"
  INSTALL_EXTRA_BODY="$(mktemp "$SCRIPT_DIR/.install-extra-body.XXXXXX")"
  register_temp_path "$INSTALL_EXTRA_BODY"
  EXTRA_MISSING_ITEMS=()
  EXTRA_FAILED_ACTIONS=()
}

# Write an Install Extra message to both the normal UI/log and its detailed log.
extra_log_message() {
  local level="${1^^}"
  shift

  if [[ "$level" == "ERROR" ]]; then
    log_error "$*"
  else
    log "$*"
  fi
  printf '[%s] [%s] %s\n' "$(date --iso-8601=seconds)" "$level" "$*" >>"$INSTALL_EXTRA_BODY"
}

# Run one install command, retaining its full output and recording failures.
run_extra_command() {
  local label="$1"
  local status
  shift

  extra_log_message "INFO" "$label"
  if "$@" 2>&1 | tee -a "$INSTALL_EXTRA_BODY"; then
    return 0
  else
    status="${PIPESTATUS[0]}"
    EXTRA_FAILED_ACTIONS+=("$label (exit $status)")
    extra_log_message "ERROR" "$label failed with exit status $status"
    return "$status"
  fi
}

# Run one install command from a required working directory.
run_extra_command_in_dir() {
  local label="$1"
  local working_dir="$2"
  local status
  shift 2

  extra_log_message "INFO" "$label"
  if (cd "$working_dir" && "$@") 2>&1 | tee -a "$INSTALL_EXTRA_BODY"; then
    return 0
  else
    status="${PIPESTATUS[0]}"
    EXTRA_FAILED_ACTIONS+=("$label (exit $status)")
    extra_log_message "ERROR" "$label failed with exit status $status"
    return "$status"
  fi
}

# Record missing command prerequisites instead of losing them on immediate exit.
require_extra_commands() {
  local cmd

  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      EXTRA_FAILED_ACTIONS+=("Required command not found: $cmd")
      extra_log_message "ERROR" "Required command not found: $cmd"
      return 1
    fi
  done
}

# Put the summary first and the complete process output below it.
finalize_install_extra_log() {
  local result="${1^^}"
  local final_temp

  final_temp="$(mktemp "$SCRIPT_DIR/.install-extra-log.XXXXXX")"
  register_temp_path "$final_temp"
  {
    printf 'Install Extra = [%s]\n' "$result"
    printf 'Started = %s\n' "$INSTALL_EXTRA_STARTED"
    printf 'Finished = %s\n' "$(date --iso-8601=seconds)"
    printf 'Missing / Not Installed:\n'
    if [[ "${#EXTRA_MISSING_ITEMS[@]}" -eq 0 ]]; then
      printf '  NONE\n'
    else
      printf '  - %s\n' "${EXTRA_MISSING_ITEMS[@]}"
    fi
    printf 'Failed Actions:\n'
    if [[ "${#EXTRA_FAILED_ACTIONS[@]}" -eq 0 ]]; then
      printf '  NONE\n'
    else
      printf '  - %s\n' "${EXTRA_FAILED_ACTIONS[@]}"
    fi
    printf '\nProcess Log:\n'
    cat "$INSTALL_EXTRA_BODY"
  } >"$final_temp"
  mv -- "$final_temp" "$INSTALL_EXTRA_LOG"
  log "Install Extra log: $INSTALL_EXTRA_LOG"
}

# Install yay from its official AUR package when it is not already available.
ensure_yay_installed() {
  local build_root
  local yay_source

  if command -v yay >/dev/null 2>&1; then
    extra_log_message "INFO" "Yay is already installed"
    return 0
  fi

  EXTRA_MISSING_ITEMS+=("yay")
  extra_log_message "INFO" "Yay is not installed"
  if ((EUID == 0)); then
    EXTRA_FAILED_ACTIONS+=("Build yay as local user")
    extra_log_message "ERROR" "Run restore-dots.sh as a local user; yay cannot be built as root"
    return 1
  fi
  require_extra_commands sudo pacman mktemp || return 1

  run_extra_command "Install yay build requirements" \
    sudo pacman -S --needed --noconfirm base-devel git || return 1
  require_extra_commands git makepkg || return 1

  build_root="$(mktemp -d)"
  register_temp_path "$build_root"
  yay_source="$build_root/yay"

  run_extra_command "Clone the official yay AUR package" \
    git clone --depth 1 -- https://aur.archlinux.org/yay.git "$yay_source" || return 1
  run_extra_command_in_dir "Build and install yay" "$yay_source" \
    makepkg -si --needed --noconfirm || return 1

  if ! command -v yay >/dev/null 2>&1; then
    EXTRA_FAILED_ACTIONS+=("Verify yay installation")
    extra_log_message "ERROR" "Yay installation completed but the command was not found"
    return 1
  fi
  extra_log_message "INFO" "Done: Install yay"
}

# Install extra Arch/AUR packages and Flatpaks after showing what is missing.
install_extra() {
  local app
  local pkg
  local remove_repo_vlc=false
  local -a missing_flatpaks=()
  local -a missing_packages=()

  init_install_extra_log
  if [[ ! -f "$DOTS_EXTRA_CONFIG" ]]; then
    EXTRA_FAILED_ACTIONS+=("Load Extra configuration")
    extra_log_message "ERROR" "Dotfiles Extra config not found: $DOTS_EXTRA_CONFIG"
    finalize_install_extra_log "FAILED"
    return 1
  fi
  load_dots_extra_config

  if ! ensure_yay_installed; then
    finalize_install_extra_log "FAILED"
    return 1
  fi
  if ! require_extra_commands pacman yay flatpak sudo; then
    finalize_install_extra_log "FAILED"
    return 1
  fi

  extra_log_message "INFO" "Checking Extra packages"
  if [[ "$REMOVE_REPOSITORY_VLC" == "true" ]] && pacman -Q vlc >/dev/null 2>&1; then
    extra_log_message "INFO" "Repository VLC is installed and will be removed before Flatpak VLC install"
    remove_repo_vlc=true
  else
    extra_log_message "INFO" "Repository VLC is not installed"
  fi

  for pkg in "${EXTRA_PACKAGES[@]}"; do
    if pacman -Q "$pkg" >/dev/null 2>&1; then
      extra_log_message "INFO" "Extra package already installed: $pkg"
    else
      extra_log_message "INFO" "Extra package missing: $pkg"
      EXTRA_MISSING_ITEMS+=("Package: $pkg")
      missing_packages+=("$pkg")
    fi
  done

  for app in "${EXTRA_FLATPAKS[@]}"; do
    if flatpak info "$app" >/dev/null 2>&1; then
      extra_log_message "INFO" "Extra Flatpak already installed: $app"
    else
      extra_log_message "INFO" "Extra Flatpak missing: $app"
      EXTRA_MISSING_ITEMS+=("Flatpak: $app")
      missing_flatpaks+=("$app")
    fi
  done

  if [[ "$remove_repo_vlc" != "true" && "${#missing_packages[@]}" -eq 0 && "${#missing_flatpaks[@]}" -eq 0 ]]; then
    extra_log_message "INFO" "Done: Install Extra (all items already installed)"
    finalize_install_extra_log "COMPLETED"
    return 0
  fi

  if [[ "$remove_repo_vlc" == "true" ]]; then
    run_extra_command "Remove repository VLC package" \
      sudo pacman -R --noconfirm vlc || {
      finalize_install_extra_log "FAILED"
      return 1
    }
  fi

  for app in "${missing_flatpaks[@]}"; do
    run_extra_command "Install Extra Flatpak: $app" \
      flatpak install --noninteractive -y "$app" || {
      finalize_install_extra_log "FAILED"
      return 1
    }
  done

  if [[ "${#missing_packages[@]}" -gt 0 ]]; then
    run_extra_command "Install Extra packages: ${missing_packages[*]}" \
      yay -S --needed --noconfirm -- "${missing_packages[@]}" || {
      finalize_install_extra_log "FAILED"
      return 1
    }
  fi

  extra_log_message "INFO" "Done: Install Extra"
  finalize_install_extra_log "COMPLETED"
}

# Set SDDM autologin to the local non-root desktop user.
set_autologin() {
  local local_user
  local snapshot="$SDDM_CONFIG-pre-restore-$RESTORE_ID"

  require_all_cmds sudo grep cp sed id
  [[ -f "$SDDM_CONFIG" ]] || die "SDDM config file not found: $SDDM_CONFIG"
  sudo grep -q '^User=' "$SDDM_CONFIG" || die "User= line not found in SDDM config: $SDDM_CONFIG"

  local_user="$(local_non_root_user)"
  [[ "$local_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid local username: $local_user"
  confirm_action "Set AutoLogin for $local_user" || return 0

  sudo test ! -e "$snapshot" || die "snapshot already exists: $snapshot"
  log "Saving SDDM config safety snapshot: $snapshot"
  sudo cp -a -- "$SDDM_CONFIG" "$snapshot"

  log "Setting SDDM AutoLogin user: $local_user"
  sudo sed -i -E "s/^User=.*/User=$local_user/" "$SDDM_CONFIG"
  sudo grep -Fqx "User=$local_user" "$SDDM_CONFIG" || die "failed to verify SDDM AutoLogin user"
  log "Done: Set AutoLogin"
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

# Replace the SWAYNC config folder from the current DOTS backup.
restore_swaync() {
  restore_config_path "SWAYNC" "swaync" "swaync"
}

# Replace the Wlogout config folder from the current DOTS backup.
restore_wlogout() {
  restore_config_path "WLOGOUT" "wlogout" "wlogout"
}

# Replace the CAVA config folder from the current DOTS backup.
restore_cava() {
  local source_dir="$SCRIPT_DIR/cava"
  local target_dir="$ML4W_CONFIG_ROOT/cava"
  local link_path="$HOME/.config/cava"

  require_cmd rsync
  [[ -d "$source_dir" ]] || die "CAVA source folder not found: $source_dir"

  confirm_action "Restore CAVA" || return 0
  snapshot_existing_target "$target_dir"

  log "Restoring CAVA from: $source_dir"
  mkdir -p "$(dirname -- "$target_dir")"
  rsync_restore_copy "$source_dir/" "$target_dir/"

  mkdir -p "$(dirname -- "$link_path")"
  if [[ -L "$link_path" && "$(readlink -- "$link_path")" == "$target_dir" ]]; then
    log "CAVA config link already set: $link_path -> $target_dir"
  else
    snapshot_existing_target "$link_path"
    ln -s -- "$target_dir" "$link_path"
    log "Created CAVA config link: $link_path -> $target_dir"
  fi
  log "Done: Restore CAVA"
}

# Snapshot and restore the backed-up WAYBAR themes and scripts folders.
restore_waybar() {
  [[ -d "$SCRIPT_DIR/waybar/themes" ]] || die "waybar themes source folder not found: $SCRIPT_DIR/waybar/themes"
  [[ -d "$SCRIPT_DIR/waybar/scripts" ]] || die "waybar scripts source folder not found: $SCRIPT_DIR/waybar/scripts"

  confirm_action "Restore WAYBAR" || return 0
  restore_config_folder "WAYBAR" "waybar/themes" "waybar/themes"
  restore_config_folder "WAYBAR" "waybar/scripts" "waybar/scripts"
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
  restore_config_folder "HYPR" "quickshell" "quickshell"
  customize_quickshell_overview_config
  log "Done: Restore HYPR"
}

# Offer to run ML4W's shell changer when zsh is not the login shell.
offer_zsh_shell_change() {
  local shell_path
  local changer="$ML4W_CONFIG_ROOT/ml4w/scripts/ml4w-change-shell"

  shell_path="$(current_login_shell)"
  log "Current login shell: ${shell_path:-unknown}"
  [[ "$(basename -- "$shell_path")" == "zsh" ]] && return 0

  confirm_yes_no "ZSH is not default shell, run script?" "N" || {
    log "ZSH shell change skipped"
    return 0
  }

  require_cmd bash
  [[ -f "$changer" ]] || die "ML4W shell change script not found: $changer"
  log "Running ML4W shell change script: $changer"
  bash "$changer"
}

# Replace the backed-up zshrc config folder in the ML4W config tree.
restore_zshrc() {
  offer_zsh_shell_change
  restore_config_path "ZSHRC" "zshrc" "zshrc"
}

# Restore the matugen theme generator config from DOTS.
restore_matugen() {
  confirm_action "Restore MATUGEN" || return 0
  restore_config_file "MATUGEN" "matugen/config.toml" "matugen/config.toml"
  log "Done: Restore MATUGEN"
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

# Run the optional ignored local hook for machine-specific settings restore steps.
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

# Point Thunar custom actions at kitty after restoring backed-up settings.
customize_thunar_custom_actions() {
  local target_file="$HOME/.config/Thunar/uca.xml"

  if [[ ! -f "$target_file" ]]; then
    log_warn "Skipping Thunar custom action update; file not found: $target_file"
    return 0
  fi

  log "Customizing Thunar custom actions: $target_file"
  sed -i -E 's|^([[:space:]]*)<command>.*</command>[[:space:]]*$|\1<command>kitty</command>|' "$target_file"
}

# Copy the qBittorrent Dracula theme from the backup device BIG folder.
restore_qbittorrent_theme() {
  local device_root=""
  local source_file=""
  local target_file="$HOME/.config/qBittorrent/dracula.qbtheme"

  device_root="$(resolve_backup_device_root)" || die "could not resolve backup device root from: $SCRIPT_DIR"
  source_file="$device_root/BIG/dracula.qbtheme"
  [[ -f "$source_file" ]] || die "qBittorrent theme file not found: $source_file"

  log "Restoring qBittorrent theme: $source_file -> $target_file"
  mkdir -p "$(dirname -- "$target_file")"
  cp -a -- "$source_file" "$target_file"
}

# Restore selected desktop settings and apply local post-restore customizations.
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

  if device_root="$(resolve_backup_device_root)"; then
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

init_log_file
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
    install_hyprmod
    ;;
  4)
    install_extra
    ;;
  5)
    set_autologin
    ;;
  10)
    restore_wallpapers
    ;;
  11)
    restore_zshrc
    ;;
  12)
    restore_kitty
    ;;
  13)
    restore_fastfetch
    ;;
  14)
    restore_hypr
    ;;
  15)
    restore_rofi
    ;;
  16)
    restore_waybar
    ;;
  17)
    restore_matugen
    ;;
  18)
    restore_cava
    ;;
  19)
    restore_swaync
    ;;
  20)
    restore_wlogout
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
