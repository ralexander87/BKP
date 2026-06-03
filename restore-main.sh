#!/usr/bin/env bash

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

LOG_FILE="$LOG_ROOT/restore-main.log"

usage() {
  cat <<'EOF'
Usage: ./restore-main.sh

Restore a MAIN/BKP-* backup from an external mounted device.
EOF
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

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ensure_dirs
require_cmd rsync
require_cmd find

DEST_DEVICE="$(select_external_mount "Select restore source device:")"
MAIN_DIR="$DEST_DEVICE/MAIN"
BACKUP_DIR="$(select_backup_dir "$MAIN_DIR")"

log "Restore source: $BACKUP_DIR"
log "Restore target: /"
rsync -aAXHv --numeric-ids "$BACKUP_DIR/" /
log "Done: restore-main"
