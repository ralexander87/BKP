#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$PROJECT_ROOT/backups}"
LOG_ROOT="${LOG_ROOT:-$PROJECT_ROOT/logs}"

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

ensure_dirs() {
  mkdir -p "$BACKUP_ROOT" "$LOG_ROOT"
}

expand_path() {
  local path="$1"
  path="${path/#\$HOME/$HOME}"
  path="${path/#\~/$HOME}"
  printf '%s\n' "$path"
}

read_config_paths() {
  local file="$1"
  [[ -f "$file" ]] || die "missing config file: $file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    expand_path "$line"
  done <"$file"
}

timestamp() {
  date '+%Y%m%d-%H%M%S'
}

rsync_backup() {
  local include_file="$1"
  local exclude_file="$2"
  local destination="$3"
  local dry_run="$4"

  local args=(-aAXHv --numeric-ids --delete --relative)
  [[ "$dry_run" == "true" ]] && args+=(--dry-run)
  [[ -f "$exclude_file" ]] && args+=(--exclude-from="$exclude_file")

  mkdir -p "$destination"

  while IFS= read -r source; do
    if [[ -e "$source" ]]; then
      log "Backing up: $source"
      rsync "${args[@]}" "$source" "$destination/"
    else
      log "Skipping missing path: $source"
    fi
  done < <(read_config_paths "$include_file")
}

rsync_restore() {
  local source="$1"
  local destination="$2"
  local dry_run="$3"

  [[ -d "$source" ]] || die "restore source is not a directory: $source"

  local args=(-aAXHv --numeric-ids)
  [[ "$dry_run" == "true" ]] && args+=(--dry-run)

  log "Restoring from $source to $destination"
  rsync "${args[@]}" "$source/" "$destination/"
}

compress_backup() {
  local source_dir="$1"
  local archive="$2"

  require_cmd tar
  require_cmd pigz

  [[ -d "$source_dir" ]] || die "cannot compress missing directory: $source_dir"
  mkdir -p "$(dirname -- "$archive")"

  log "Creating archive: $archive"
  tar -C "$(dirname -- "$source_dir")" -cf - "$(basename -- "$source_dir")" | pigz >"$archive"
}

update_latest_link() {
  local target="$1"
  local link="$2"

  ln -sfn "$target" "$link"
}

