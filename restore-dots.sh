#!/usr/bin/env bash

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

LOG_FILE="$LOG_ROOT/restore-dots.log"
DRY_RUN=false
SOURCE=""
DESTINATION="/"

usage() {
  cat <<'EOF'
Usage: ./restore-dots.sh --source PATH [--destination PATH] [--dry-run]

Restore a dotfiles backup directory. Use --dry-run first.
EOF
}

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

ensure_dirs
require_cmd rsync
[[ -n "$SOURCE" ]] || die "missing required --source PATH"

rsync_restore "$SOURCE" "$DESTINATION" "$DRY_RUN"
log "Done: restore-dots"

