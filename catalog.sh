#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$PROJECT_ROOT/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./catalog.sh [MOUNT_PATH ...]

List MAIN and SERVICE backups on supplied mount paths.
When no path is supplied, all detected external mounts are scanned.
EOF
}

manifest_value() {
  local manifest_file="$1"
  local key="$2"

  awk -F' = ' -v key="$key" '$1 == key { print $2; exit }' "$manifest_file"
}

clean_manifest_marker() {
  local value="${1:-UNKNOWN}"

  value="${value#[}"
  printf '%s\n' "${value%]}"
}

normalize_catalog_status() {
  local value
  value="$(clean_manifest_marker "${1:-UNKNOWN}")"

  case "${value,,}" in
  complete | completed | success | successful) printf 'COMPLETED\n' ;;
  in_progress | in-progress | running) printf 'IN PROGRESS\n' ;;
  failed | fail | error) printf 'FAILED\n' ;;
  *) printf '%s\n' "$value" ;;
  esac
}

legacy_manifest_value() {
  local manifest_file="$1"
  shift
  local key

  for key in "$@"; do
    awk -F= -v key="$key" '$1 == key { print $2; exit }' "$manifest_file"
  done | awk 'NF { print; exit }'
}

catalog_backup_dir() {
  local backup_type="$1"
  local backup_dir="$2"
  local manifest_file="$backup_dir/backup-manifest.txt"
  local backup_name run_id status created size archive_state validation

  backup_name="$(basename -- "$backup_dir")"
  run_id="${backup_name#.}"
  run_id="${run_id%.in-progress}"
  status="UNKNOWN"
  created="UNKNOWN"
  validation="UNKNOWN"
  if [[ -f "$manifest_file" ]]; then
    status="$(manifest_value "$manifest_file" "Backup Status")"
    [[ -n "$status" ]] || status="$(legacy_manifest_value "$manifest_file" backup_status run_result)"
    status="$(normalize_catalog_status "$status")"
    created="$(manifest_value "$manifest_file" "Created")"
    [[ -n "$created" ]] || created="$(legacy_manifest_value "$manifest_file" created created_at timestamp)"
    [[ -n "$created" ]] || created="UNKNOWN"
    validation="$(clean_manifest_marker "$(manifest_value "$manifest_file" "Archive Validation")")"
  elif [[ "$backup_name" == .*in-progress ]]; then
    status="IN PROGRESS"
  fi

  size="$(du -sh "$backup_dir" 2>/dev/null | awk '{ print $1 }')"
  [[ -n "$size" ]] || size="UNKNOWN"
  if [[ -f "$(dirname -- "$backup_dir")/$run_id.tar.gz" ]]; then
    archive_state="YES"
  else
    archive_state="NO"
  fi

  printf '%-7s | %-28s | %-11s | %-25s | %-8s | %-7s | %s\n' \
    "$backup_type" "$backup_name" "$status" "$created" "$size" "$archive_state" "$validation"
}

catalog_mount() {
  local mount_root="$1"
  local backup_type backup_root backup_dir
  local found=false
  local -a backup_dirs=()

  [[ -d "$mount_root" ]] || die "catalog path is not a directory: $mount_root"
  printf '\nBackup Catalog: %s\n' "$mount_root"
  printf '%-7s | %-28s | %-11s | %-25s | %-8s | %-7s | %s\n' \
    "Type" "Backup" "Status" "Created" "Size" "Archive" "Archive Validation"
  printf '%s\n' "---------------------------------------------------------------------------------------------------------------"

  for backup_type in MAIN SERV; do
    backup_root="$mount_root/$backup_type"
    [[ -d "$backup_root" ]] || continue
    backup_dirs=()
    while IFS= read -r -d '' backup_dir; do
      backup_dirs+=("$backup_dir")
    done < <(find "$backup_root" -mindepth 1 -maxdepth 1 -type d \( -name 'BKP-*' -o -name '.BKP-*.in-progress' \) -print0 | sort -z)
    for backup_dir in "${backup_dirs[@]}"; do
      found=true
      catalog_backup_dir "$backup_type" "$backup_dir"
    done
  done

  [[ "$found" == "true" ]] || printf 'No backups found.\n'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_all_cmds awk du find sort

declare -a mount_roots=()
if [[ "$#" -gt 0 ]]; then
  mount_roots=("$@")
else
  while IFS='|' read -r target _; do
    mount_roots+=("$target")
  done < <(list_external_mounts)
fi

if [[ "${#mount_roots[@]}" -eq 0 ]]; then
  die "no external backup mounts detected; provide a mount path"
fi

for mount_root in "${mount_roots[@]}"; do
  catalog_mount "$mount_root"
done
