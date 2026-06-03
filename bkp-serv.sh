#!/usr/bin/env bash

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

LOG_FILE="$LOG_ROOT/bkp-serv.log"
DRY_RUN=false
COMPRESS=false

usage() {
  cat <<'EOF'
Usage: ./bkp-serv.sh [--dry-run] [--compress]

Back up service paths listed in config/serv.include.
Some paths may require sudo.
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
DEST="$BACKUP_ROOT/serv/$RUN_ID"

rsync_backup "$PROJECT_ROOT/config/serv.include" "$PROJECT_ROOT/config/serv.exclude" "$DEST" "$DRY_RUN"

if [[ "$DRY_RUN" == "false" ]]; then
  update_latest_link "$RUN_ID" "$BACKUP_ROOT/serv/latest"
  [[ "$COMPRESS" == "true" ]] && compress_backup "$DEST" "$PROJECT_ROOT/dist/bkp-serv-$RUN_ID.tar.gz"
fi

log "Done: bkp-serv"

