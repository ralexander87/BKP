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
  local record
  local latest=""

  while IFS= read -r -d '' record; do
    latest="${record#* }"
  done < <(find "$root" -maxdepth 1 -type d -name 'BKP-*' -printf '%T@ %p\0' 2>/dev/null | sort -z -n)
  printf '%s\n' "$latest"
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
  local source_path

  [[ -n "$backup_dir" ]] || return 0
  ok "latest SERV backup: $backup_dir"
  check_file_in_backup "$backup_dir/restore-serv.sh"
  check_file_in_backup "$backup_dir/lib/common.sh"
  check_file_in_backup "$backup_dir/config/serv.restore.conf"
  for source_path in "${SERVICE_REQUIRED_PATHS[@]}"; do
    check_file_in_backup "$backup_dir/$(basename -- "$source_path")"
  done
  if [[ -d "$SSH_CONFIG_DROPIN_SOURCE" ]]; then
    if [[ -d "$backup_dir/sshd_config.d" ]]; then
      ok "backup directory: $backup_dir/sshd_config.d"
    else
      warn "SSH server drop-ins missing from backup: $backup_dir/sshd_config.d"
    fi
  fi
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

# Report SSH client, server, and Git transport readiness without changing them.
check_ssh_health() {
  local ssh_dir="$HOME/.ssh"
  local ssh_dir_mode
  local validation_dir
  local validation_key
  local auth_output
  local systemctl_output

  printf '\nSSH\n'
  if [[ -d "$ssh_dir" ]]; then
    ssh_dir_mode="$(stat -c '%a' "$ssh_dir")"
    if [[ "$ssh_dir_mode" == "700" ]]; then
      ok "user SSH directory mode: $ssh_dir_mode"
    else
      warn "user SSH directory mode is $ssh_dir_mode; expected 700: $ssh_dir"
    fi
  else
    warn "user SSH directory missing: $ssh_dir"
  fi

  if command -v ssh >/dev/null 2>&1; then
    if ssh -G -o BatchMode=yes github.com >/dev/null 2>&1; then
      ok "SSH client configuration parses"
    else
      warn "SSH client configuration needs attention"
    fi
  else
    warn "SSH client command missing"
  fi

  if systemctl_output="$(systemctl cat sshd.service 2>&1)"; then
    if systemctl is-enabled --quiet sshd.service 2>/dev/null; then
      ok "sshd.service enabled"
    else
      warn "sshd.service is not enabled"
    fi
    if systemctl is-active --quiet sshd.service; then
      ok "sshd.service active"
    else
      warn "sshd.service is not active"
    fi
  elif [[ "$systemctl_output" == *"Failed to connect to"* ]]; then
    warn "systemd system bus unavailable; sshd.service state checks skipped"
  else
    warn "sshd.service unit not found"
  fi

  if command -v sshd >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    validation_dir="$(mktemp -d)"
    validation_key="$validation_dir/ssh_host_ed25519_key"
    ssh-keygen -q -t ed25519 -N "" -f "$validation_key"
    if sudo -n sshd -t -f /etc/ssh/sshd_config -h "$validation_key"; then
      ok "SSH server configuration parses"
    else
      warn "SSH server configuration validation failed"
    fi
    rm -rf -- "$validation_dir"
  else
    warn "SSH server validation skipped; sshd, ssh-keygen, or noninteractive sudo unavailable"
  fi

  if command -v ssh >/dev/null 2>&1; then
    auth_output="$(mktemp)"
    if ssh -T -o BatchMode=yes -o ConnectTimeout=5 git@github.com >"$auth_output" 2>&1; then
      ok "GitHub SSH authentication"
    elif grep -Fq "successfully authenticated" "$auth_output"; then
      ok "GitHub SSH authentication"
    else
      warn "GitHub SSH authentication needs attention: $(cat "$auth_output")"
    fi
    rm -f -- "$auth_output"
  fi
}

printf 'BKP doctor\n'
printf 'Project: %s\n\n' "$PROJECT_ROOT"

printf 'Dependencies\n'
if ! bash "$PROJECT_ROOT/tools/check-deps.sh"; then
  EXIT_CODE=1
fi

printf '\nSource paths\n'
main_backup_config="$PROJECT_ROOT/config/main.backup.conf"
serv_backup_config="$PROJECT_ROOT/config/serv.backup.conf"
# shellcheck source=config/main.backup.conf
source "$main_backup_config"
# shellcheck source=config/serv.backup.conf
source "$serv_backup_config"

source_paths=(
  "$HOME/$DOTS_ROOT_RELATIVE"
  "$HOME/$DOTS_CONFIG_RELATIVE"
  "$HOME/$FIRMWARE_HOME_RELATIVE"
)
for hidden_item in "${HIDDEN_HOME_ITEMS[@]}"; do
  source_paths+=("$HOME/$hidden_item")
done
source_paths+=("${SERVICE_REQUIRED_PATHS[@]}")

for path in "${source_paths[@]}"; do
  check_path "$path"
done

check_ssh_health

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
    check_path "$target/BIG/lateralus"
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

printf '\nLocal checks\n'
if "$PROJECT_ROOT/tools/smoke.sh" >/dev/null; then
  ok "make smoke prerequisites"
else
  fail "smoke checks failed"
fi

exit "$EXIT_CODE"
