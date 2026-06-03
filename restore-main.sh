#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore-main.log}"

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
Usage: ./restore-main.sh

Restore a MAIN/BKP-* backup to $HOME.

When this script is inside a BKP-* folder, it restores from the current
backup folder. Otherwise, it asks you to select an external mounted device
and backup folder.
EOF
}

list_external_mounts() {
  require_cmd findmnt

  findmnt -rn -o TARGET,SOURCE,FSTYPE |
    awk '
      $2 ~ "^/dev/" &&
      $1 ~ "^(/media/|/run/media/|/mnt/)" &&
      $3 !~ "^(swap|tmpfs|devtmpfs|proc|sysfs|cgroup|cgroup2|overlay|squashfs)$" {
        print $1
      }
    '
}

select_external_mount() {
  local mounts=()

  mapfile -t mounts < <(list_external_mounts)

  case "${#mounts[@]}" in
    0)
      die "no external mounted devices found"
      ;;
    1)
      printf 'Using mounted device: %s\n' "${mounts[0]}" >&2
      printf '%s\n' "${mounts[0]}"
      ;;
    *)
      printf 'Select restore source device:\n' >&2
      local i
      for i in "${!mounts[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${mounts[$i]}" >&2
      done

      local selection
      while true; do
        read -r -p "Enter number and press Enter: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] &&
          ((selection >= 1 && selection <= ${#mounts[@]})); then
          printf '%s\n' "${mounts[$((selection - 1))]}"
          return
        fi
        printf 'Invalid selection.\n' >&2
      done
      ;;
  esac
}

select_backup_dir() {
  local main_dir="$1"
  local backups=()

  [[ -d "$main_dir" ]] || die "MAIN folder not found: $main_dir"

  mapfile -t backups < <(find "$main_dir" -maxdepth 1 -mindepth 1 -type d -name 'BKP-*' | sort -r)

  case "${#backups[@]}" in
    0)
      die "no BKP-* backup folders found in: $main_dir"
      ;;
    1)
      printf 'Using backup: %s\n' "${backups[0]}" >&2
      printf '%s\n' "${backups[0]}"
      ;;
    *)
      printf 'Select backup to restore:\n' >&2
      local i
      for i in "${!backups[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "$(basename -- "${backups[$i]}")" >&2
      done

      local selection
      while true; do
        read -r -p "Enter number and press Enter: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] &&
          ((selection >= 1 && selection <= ${#backups[@]})); then
          printf '%s\n' "${backups[$((selection - 1))]}"
          return
        fi
        printf 'Invalid selection.\n' >&2
      done
      ;;
  esac
}

resolve_backup_dir() {
  if [[ "$(basename -- "$SCRIPT_DIR")" == BKP-* ]]; then
    printf '%s\n' "$SCRIPT_DIR"
    return
  fi

  local device
  device="$(select_external_mount)"
  select_backup_dir "$device/MAIN"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd rsync
require_cmd find

BACKUP_DIR="$(resolve_backup_dir)"
[[ -d "$BACKUP_DIR" ]] || die "backup folder not found: $BACKUP_DIR"

log "Restore source: $BACKUP_DIR"
log "Restore target: $HOME"

for item in "${HOME_ITEMS[@]}"; do
  source_path="$BACKUP_DIR/$item"

  if [[ -e "$source_path" ]]; then
    log "Restoring: $item"
    rsync -aAXHv --numeric-ids "$source_path" "$HOME/"
  else
    log "Skipping missing backup item: $item"
  fi
done

log "Done: restore-main"
