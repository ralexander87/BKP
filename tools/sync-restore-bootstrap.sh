#!/usr/bin/env bash
set -Eeuo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap="$project_root/lib/restore-bootstrap.sh"
mode="${1:-write}"
restore_scripts=(
  "$project_root/restore-main.sh"
  "$project_root/restore-serv.sh"
  "$project_root/restore-dots.sh"
)

# Replace the generated bootstrap block in one restore script.
replace_bootstrap() {
  local script="$1"
  local tmp

  tmp="$(mktemp)"
  awk -v bootstrap="$bootstrap" '
    BEGIN {
      while ((getline line < bootstrap) > 0) {
        block = block line "\n"
      }
      close(bootstrap)
    }
    /^# BEGIN RESTORE BOOTSTRAP$/ {
      print
      printf "%s", block
      in_block = 1
      next
    }
    /^# END RESTORE BOOTSTRAP$/ {
      in_block = 0
      print
      next
    }
    !in_block { print }
  ' "$script" >"$tmp"
  cat "$tmp" >"$script"
  rm -f "$tmp"
}

# Compare one restore script's generated bootstrap block with the source copy.
check_bootstrap() {
  local script="$1"
  local tmp

  tmp="$(mktemp)"
  awk '
    /^# BEGIN RESTORE BOOTSTRAP$/ { in_block = 1; next }
    /^# END RESTORE BOOTSTRAP$/ { in_block = 0; next }
    in_block { print }
  ' "$script" >"$tmp"

  if ! diff -u "$bootstrap" "$tmp"; then
    printf 'restore bootstrap out of sync: %s\n' "$script" >&2
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

case "$mode" in
write)
  for script in "${restore_scripts[@]}"; do
    replace_bootstrap "$script"
  done
  ;;
check)
  for script in "${restore_scripts[@]}"; do
    check_bootstrap "$script"
  done
  ;;
*)
  printf 'Usage: %s [write|check]\n' "${0##*/}" >&2
  exit 2
  ;;
esac
