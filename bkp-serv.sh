#!/usr/bin/env bash

# Load shared helpers for config parsing, rsync, compression, and logging.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Service backup runtime state.
LOG_FILE="$LOG_ROOT/bkp-serv.log"
DRY_RUN=false
COMPRESS=false

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./bkp-serv.sh [--dry-run] [--compress]

Back up service paths listed in config/serv.include.
Some paths may require sudo.
EOF
}

# Parse optional dry-run/compression flags.
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

# Prepare runtime folders and verify the main copy tool exists.
ensure_dirs
require_cmd rsync

# Create a timestamped service backup destination under backups/serv.
RUN_ID="$(timestamp)"
DEST="$BACKUP_ROOT/serv/$RUN_ID"

# Back up configured service paths with exclusions from config/serv.exclude.
rsync_backup "$PROJECT_ROOT/config/serv.include" "$PROJECT_ROOT/config/serv.exclude" "$DEST" "$DRY_RUN"

# For real runs, update latest and optionally create a compressed archive.
if [[ "$DRY_RUN" == "false" ]]; then
  update_latest_link "$RUN_ID" "$BACKUP_ROOT/serv/latest"
  [[ "$COMPRESS" == "true" ]] && compress_backup "$DEST" "$PROJECT_ROOT/dist/bkp-serv-$RUN_ID.tar.gz"
fi

log "Done: bkp-serv"
