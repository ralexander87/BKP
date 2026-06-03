#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore-dots.log}"

log() {
  printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

usage() {
  cat <<'EOF'
Usage: ./restore-dots.sh

Run dotfiles restore actions from the current DOTS folder.
EOF
}

show_menu() {
  cat <<'EOF'
Select action:
  0 - Exit
  1 - Install DOTS
  2 - Restore Wallpapers
  3 - Restore FastFetch
EOF
}

install_dots() {
  require_cmd bash
  require_cmd curl

  log "DOTS source folder: $SCRIPT_DIR"
  log "Deleting: $HOME/.config/hypr"
  rm -rf -- "$HOME/.config/hypr"

  log "Running ML4W stable installer"
  bash <(curl -s https://ml4w.com/os/stable)
  log "Done: Install DOTS"
}

restore_wallpapers() {
  local source_dir="$SCRIPT_DIR/ml4w/wallpapers"
  local target_dir="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/ml4w/wallpapers"

  require_cmd rsync
  [[ -d "$source_dir" ]] || die "wallpapers source folder not found: $source_dir"

  log "Deleting: $target_dir"
  rm -rf -- "$target_dir"

  log "Restoring wallpapers from: $source_dir"
  mkdir -p "$(dirname -- "$target_dir")"
  rsync -aAXH --numeric-ids --info=progress2 "$source_dir/" "$target_dir/"
  log "Done: Restore Wallpapers"
}

restore_fastfetch() {
  local source_dir="$SCRIPT_DIR/fastfetch"
  local target_dir="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/fastfetch"

  require_cmd rsync
  [[ -d "$source_dir" ]] || die "fastfetch source folder not found: $source_dir"

  log "Deleting: $target_dir"
  rm -rf -- "$target_dir"

  log "Restoring FastFetch from: $source_dir"
  mkdir -p "$(dirname -- "$target_dir")"
  rsync -aAXH --numeric-ids --info=progress2 "$source_dir/" "$target_dir/"
  log "Done: Restore FastFetch"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

show_menu
read -r -p "Enter selection: " selection

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
  *)
    die "invalid selection: $selection"
    ;;
esac
