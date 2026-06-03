#!/usr/bin/env bash

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

LOG_FILE="$LOG_ROOT/bkp-main.log"
DRY_RUN=false
COMPRESS=false

usage() {
  cat <<'EOF'
Usage: ./bkp-main.sh [--dry-run] [--compress]

Back up user folders listed in config/main.include.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --compress) COMPRESS=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

ensure_dirs
require_cmd rsync

RUN_ID="$(timestamp)"
DEST="$BACKUP_ROOT/main/$RUN_ID"

rsync_backup "$PROJECT_ROOT/config/main.include" "$PROJECT_ROOT/config/main.exclude" "$DEST" "$DRY_RUN"

if [[ "$DRY_RUN" == "false" ]]; then
  update_latest_link "$RUN_ID" "$BACKUP_ROOT/main/latest"
  [[ "$COMPRESS" == "true" ]] && compress_backup "$DEST" "$PROJECT_ROOT/dist/bkp-main-$RUN_ID.tar.gz"
fi

log "Done: bkp-main"

