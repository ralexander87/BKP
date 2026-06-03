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
  date '+%j-%d-%m-%H-%M-%S'
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
  local prompt="${1:-Select destination device}"
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
      printf '%s\n' "$prompt" >&2
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

confirm_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer

  read -r -p "$prompt [$default]: " answer
  answer="${answer:-$default}"

  [[ "$answer" =~ ^[Yy]$ ]]
}
