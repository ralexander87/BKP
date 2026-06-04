#!/usr/bin/env bash

# Load shared helpers for rsync restore, logging, and validation.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Service restore runtime state.
LOG_FILE="$LOG_ROOT/restore-serv.log"
DRY_RUN=false
SOURCE=""
DESTINATION="/"

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./restore-serv.sh --source PATH [--destination PATH] [--dry-run]

Restore a service backup directory. Use --dry-run first.
Some paths may require sudo.
EOF
}

# Parse restore source, optional destination, and dry-run flag.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE="${2:-}"
      shift
      ;;
    --destination)
      DESTINATION="${2:-}"
      shift
      ;;
    --dry-run) DRY_RUN=true ;;
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
[[ -n "$SOURCE" ]] || die "missing required --source PATH"

# Restore the selected service backup into the requested destination.
rsync_restore "$SOURCE" "$DESTINATION" "$DRY_RUN"
log "Done: restore-serv"
