#!/usr/bin/env bash

# Shared scripts fail fast on errors, unset variables, and failed pipelines.
set -Eeuo pipefail

# Resolve project paths relative to this helper file.
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$PROJECT_ROOT/backups}"
LOG_ROOT="${LOG_ROOT:-$PROJECT_ROOT/logs}"

# Write a timestamped message to screen and the active script log.
log() {
  printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"
}

# Log an error and stop the active script.
die() {
  log "ERROR: $*"
  exit 1
}

# Ensure an external command exists before it is needed.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Create local runtime directories used by scripts.
ensure_dirs() {
  mkdir -p "$BACKUP_ROOT" "$LOG_ROOT"
}

# Expand simple $HOME and ~ prefixes from config files.
expand_path() {
  local path="$1"
  path="${path/#\$HOME/$HOME}"
  path="${path/#\~/$HOME}"
  printf '%s\n' "$path"
}

# Read non-comment config lines and expand supported home prefixes.
read_config_paths() {
  local file="$1"
  [[ -f "$file" ]] || die "missing config file: $file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    expand_path "$line"
  done <"$file"
}

# Generate the backup timestamp used in BKP folder names.
timestamp() {
  date '+%j-%d-%m-%H-%M-%S'
}

# Convert a byte count into a compact human-readable size.
human_bytes() {
  local bytes="$1"

  numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || printf '%sB\n' "$bytes"
}

# Copy configured paths into a backup destination with rsync metadata flags.
rsync_backup() {
  local include_file="$1"
  local exclude_file="$2"
  local destination="$3"
  local dry_run="$4"

  local args=(-aAXHv --numeric-ids --delete --relative)
  [[ "$dry_run" == "true" ]] && args+=(--dry-run)
  [[ -f "$exclude_file" ]] && args+=(--exclude-from="$exclude_file")

  mkdir -p "$destination"

  # Process each configured path independently so missing paths can be logged.
  while IFS= read -r source; do
    if [[ -e "$source" ]]; then
      log "Backing up: $source"
      rsync "${args[@]}" "$source" "$destination/"
    else
      log "Skipping missing path: $source"
    fi
  done < <(read_config_paths "$include_file")
}

# Restore a backup folder into the requested destination.
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

# Create a pigz-compressed tar archive from an existing backup folder.
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

# Point a latest symlink at a newly created backup folder.
update_latest_link() {
  local target="$1"
  local link="$2"

  ln -sfn "$target" "$link"
}

# Return likely external/removable mount details from real block devices.
list_external_mounts() {
  require_cmd findmnt

  findmnt -rn -o TARGET,SOURCE,FSTYPE |
    awk '
      $2 ~ "^/dev/" &&
      $1 ~ "^(/media/|/run/media/|/mnt/)" &&
      $3 !~ "^(swap|tmpfs|devtmpfs|proc|sysfs|cgroup|cgroup2|overlay|squashfs)$" {
        print $1
      }
    ' |
    while IFS= read -r target; do
      local source fstype label avail
      source="$(findmnt -rn -o SOURCE --target "$target")"
      fstype="$(findmnt -rn -o FSTYPE --target "$target")"
      label="-"
      if command -v lsblk >/dev/null 2>&1; then
        label="$(lsblk -no LABEL "$source" 2>/dev/null | head -n 1)"
        label="${label:-"-"}"
      fi
      avail="$(df -hP "$target" 2>/dev/null | awk 'NR == 2 { print $4 " free" }')"
      avail="${avail:-"unknown free"}"
      printf '%s|%s|%s|%s|%s\n' "$target" "$source" "$fstype" "$label" "$avail"
    done
}

# Select an external mount automatically when one exists, or prompt by number.
select_external_mount() {
  local prompt="${1:-Select destination device}"
  local mounts=()

  mapfile -t mounts < <(list_external_mounts)

  case "${#mounts[@]}" in
    0)
      die "no external mounted devices found"
      ;;
    1)
      IFS='|' read -r target source fstype label avail <<<"${mounts[0]}"
      printf 'Using mounted device: %s (%s, %s, label: %s, %s)\n' "$target" "$source" "$fstype" "$label" "$avail" >&2
      printf '%s\n' "$target"
      ;;
    *)
      printf '%s\n' "$prompt" >&2
      local i
      for i in "${!mounts[@]}"; do
        IFS='|' read -r target source fstype label avail <<<"${mounts[$i]}"
        printf '  %d) %s (%s, %s, label: %s, %s)\n' "$((i + 1))" "$target" "$source" "$fstype" "$label" "$avail" >&2
      done

      local selection
      while true; do
        read -r -p "Enter number and press Enter: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] &&
          ((selection >= 1 && selection <= ${#mounts[@]})); then
          IFS='|' read -r target _ <<<"${mounts[$((selection - 1))]}"
          printf '%s\n' "$target"
          return
        fi
        printf 'Invalid selection.\n' >&2
      done
      ;;
  esac
}

# Ask a yes/no question; pressing Enter uses the provided default.
confirm_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer

  read -r -p "$prompt [$default]: " answer
  answer="${answer:-$default}"
  answer="$(printf '%s' "$answer" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"

  [[ "$answer" == "y" || "$answer" == "yes" ]]
}
