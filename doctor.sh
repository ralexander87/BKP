#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXIT_CODE=0

# Print a successful doctor check line.
ok() { printf '[OK] %s\n' "$*"; }

# Print a non-fatal doctor warning line.
warn() { printf '[WARN] %s\n' "$*"; }

# Print a failed check line and remember the failing exit status.
fail() {
  printf '[FAIL] %s\n' "$*"
  EXIT_CODE=1
}

# Check that a required command is available in PATH.
check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "command: $cmd"
  else
    fail "missing command: $cmd"
  fi
}

# Check that an expected local source path exists.
check_path() {
  local path="$1"
  if [[ -e "$path" ]]; then
    ok "path exists: $path"
  else
    warn "path missing: $path"
  fi
}

# Check that a required file exists inside a discovered backup.
check_file_in_backup() {
  local file="$1"
  if [[ -e "$file" ]]; then
    ok "backup file: $file"
  else
    fail "backup file missing: $file"
  fi
}

# Return the newest BKP-* directory under a backup root.
latest_backup_dir() {
  local root="$1"
  find "$root" -maxdepth 1 -type d -name 'BKP-*' 2>/dev/null | sort | tail -n 1
}

# Decode findmnt path escapes before printing paths for humans.
decode_findmnt_path() {
  printf '%b' "$1"
}

# Read backup status from both current human-readable and legacy key=value manifests.
read_manifest_status() {
  local manifest_file="$1"
  local status

  status="$(awk -F= '$1 == "backup_status" { print $2; exit }' "$manifest_file")"
  status="${status:-$(awk -F= '$1 == "run_result" { print $2; exit }' "$manifest_file")}"
  status="${status:-$(awk -F' = ' '$1 == "Backup Status" { print $2; exit }' "$manifest_file")}"
  status="${status:-$(awk -F' = ' '$1 == "Run Result" { print $2; exit }' "$manifest_file")}"
  status="${status#[}"
  status="${status%]}"
  status="${status,,}"
  status="${status// /_}"

  case "$status" in
  completed) printf 'complete\n' ;;
  successful) printf 'success\n' ;;
  *) printf '%s\n' "$status" ;;
  esac
}

# Validate the latest MAIN backup layout and status markers.
check_main_backup() {
  local backup_dir="$1"
  local manifest_file="$backup_dir/backup-manifest.txt"
  local status=""
  local manifest_version=""

  [[ -n "$backup_dir" ]] || return 0
  ok "latest MAIN backup: $backup_dir"
  check_file_in_backup "$backup_dir/restore-main.sh"
  check_file_in_backup "$backup_dir/lib/common.sh"
  check_file_in_backup "$manifest_file"
  if [[ -f "$manifest_file" ]] && grep -Fq 'Manifest Version = 1' "$manifest_file"; then
    check_file_in_backup "$backup_dir/backup-manifest.json"
  else
    warn "JSON manifest not required for legacy MAIN backup"
  fi
  if [[ -f "$manifest_file" ]]; then
    manifest_version="$(awk -F' = ' '$1 == "Manifest Version" { print $2; exit }' "$manifest_file")"
    if [[ -n "$manifest_version" && "$manifest_version" != "1" ]]; then
      fail "unsupported MAIN manifest version: $manifest_version"
    fi
    status="$(read_manifest_status "$manifest_file")"
  fi
  if [[ "$status" == "complete" ]]; then
    ok "main backup status complete: $manifest_file"
  elif [[ -f "$backup_dir/backup.status" ]]; then
    if [[ "$(cat "$backup_dir/backup.status")" == "complete" ]]; then
      ok "main backup status complete: $backup_dir/backup.status (legacy)"
    else
      fail "main backup status is not complete: $(cat "$backup_dir/backup.status")"
    fi
  else
    warn "main backup status missing from manifest; older backup format"
  fi
  if [[ -d "$backup_dir/DOTS" ]]; then
    check_file_in_backup "$backup_dir/DOTS/restore-dots.sh"
    check_file_in_backup "$backup_dir/DOTS/lib/common.sh"
    if [[ -f "$PROJECT_ROOT/config/local/restore-dots-settings.sh" ]]; then
      check_file_in_backup "$backup_dir/DOTS/config/local/restore-dots-settings.sh"
    fi
  else
    warn "DOTS folder missing in MAIN backup: $backup_dir/DOTS"
  fi
}

# Validate the latest SERV backup layout and status markers.
check_serv_backup() {
  local backup_dir="$1"
  local status_file="$backup_dir/backup.status"
  local manifest_file="$backup_dir/backup-manifest.txt"
  local status=""
  local manifest_version=""

  [[ -n "$backup_dir" ]] || return 0
  ok "latest SERV backup: $backup_dir"
  check_file_in_backup "$backup_dir/restore-serv.sh"
  check_file_in_backup "$backup_dir/lib/common.sh"
  check_file_in_backup "$backup_dir/config/serv.restore.conf"
  if [[ -f "$PROJECT_ROOT/config/local/serv.restore.conf" ]]; then
    check_file_in_backup "$backup_dir/config/local/serv.restore.conf"
  fi
  check_file_in_backup "$manifest_file"
  if [[ -f "$manifest_file" ]] && grep -Fq 'Manifest Version = 1' "$manifest_file"; then
    check_file_in_backup "$backup_dir/backup-manifest.json"
  else
    warn "JSON manifest not required for legacy SERVICE backup"
  fi
  if [[ -f "$manifest_file" ]]; then
    manifest_version="$(awk -F' = ' '$1 == "Manifest Version" { print $2; exit }' "$manifest_file")"
    if [[ -n "$manifest_version" && "$manifest_version" != "1" ]]; then
      fail "unsupported SERVICE manifest version: $manifest_version"
    fi
    status="$(read_manifest_status "$manifest_file")"
  fi
  if [[ "$status" == "complete" ]]; then
    ok "service backup status complete: $manifest_file"
  elif [[ -f "$status_file" ]]; then
    if [[ "$(cat "$status_file")" == "complete" ]]; then
      ok "service backup status complete: $status_file (legacy)"
    else
      fail "service backup status is not complete: $(cat "$status_file")"
    fi
  else
    fail "service backup status missing from manifest and legacy file"
  fi
}

printf 'BKP doctor\n'
printf 'Project: %s\n\n' "$PROJECT_ROOT"

printf 'Dependencies\n'
for cmd in bash rsync pigz shellcheck shfmt git make flock findmnt df du install sudo cryptsetup lsblk tar curl numfmt awk sed grep tee systemctl; do
  check_cmd "$cmd"
done

printf '\nSource paths\n'
for path in \
  "$HOME/Downloads" \
  "$HOME/Pictures" \
  "$HOME/Videos" \
  "$HOME/Music" \
  "$HOME/Obsidian" \
  "$HOME/Code" \
  "$HOME/Documents" \
  "$HOME/.themes" \
  "$HOME/.icons" \
  "$HOME/.ssh" \
  "$HOME/.vscode-oss" \
  "$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config" \
  "/etc/samba/smb.conf" \
  "/etc/ssh/sshd_config" \
  "/boot/grub/themes/lateralus" \
  "/etc/default/grub" \
  "/etc/mkinitcpio.conf"; do
  check_path "$path"
done

printf '\nExternal mounts\n'
mapfile -t mounts < <(
  findmnt -rn -o TARGET,SOURCE,FSTYPE |
    awk '$2 ~ "^/dev/" && $1 ~ "^(/media/|/run/media/|/mnt/)" { print $1 "|" $2 "|" $3 }'
)
if [[ "${#mounts[@]}" -eq 0 ]]; then
  warn "no external backup mount detected"
else
  for mount in "${mounts[@]}"; do
    IFS='|' read -r target source fstype <<<"$mount"
    target="$(decode_findmnt_path "$target")"
    source="$(decode_findmnt_path "$source")"
    ok "mounted backup candidate: $target ($source, $fstype)"
    check_main_backup "$(latest_backup_dir "$target/MAIN")"
    check_serv_backup "$(latest_backup_dir "$target/SERV")"
  done
fi

printf '\nGit\n'
if git -C "$PROJECT_ROOT" status --short >/dev/null 2>&1; then
  ok "git repository readable"
  if git -C "$PROJECT_ROOT" status -sb | grep -q '\.\.\.'; then
    ok "$(git -C "$PROJECT_ROOT" status -sb | head -n 1)"
  fi
else
  fail "git repository not readable"
fi

if ssh -T -o BatchMode=yes git@github.com >/tmp/bkp-doctor-ssh.out 2>&1; then
  ok "GitHub SSH authentication"
else
  ssh_output="$(cat /tmp/bkp-doctor-ssh.out)"
  if [[ "$ssh_output" == *"successfully authenticated"* ]]; then
    ok "GitHub SSH authentication"
  else
    warn "GitHub SSH authentication needs attention: $ssh_output"
  fi
fi
rm -f /tmp/bkp-doctor-ssh.out

printf '\nLocal checks\n'
if make -C "$PROJECT_ROOT" deps >/dev/null; then
  ok "make deps"
else
  fail "make deps failed"
fi

if "$PROJECT_ROOT/tools/smoke.sh" >/dev/null; then
  ok "make smoke prerequisites"
else
  fail "smoke checks failed"
fi

exit "$EXIT_CODE"
