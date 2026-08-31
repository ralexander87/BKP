#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Verify a restore script can show help without bundled shared helpers.
run_standalone_help() {
  local script="$1"
  local tmp

  tmp="$(mktemp -d)"
  cp "$PROJECT_ROOT/$script" "$tmp/$script"
  chmod +x "$tmp/$script"
  (cd "$tmp" && "./$script" --help >/dev/null)
  rm -rf "$tmp"
  printf 'standalone help OK: %s\n' "$script"
}

# Verify a restore script can show help with bundled shared helpers.
run_bundled_help() {
  local script="$1"
  local tmp

  tmp="$(mktemp -d)"
  cp "$PROJECT_ROOT/$script" "$tmp/$script"
  mkdir -p "$tmp/lib"
  cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
  chmod +x "$tmp/$script"
  (cd "$tmp" && "./$script" --help >/dev/null)
  rm -rf "$tmp"
  printf 'bundled help OK: %s\n' "$script"
}

# Assert that a menu selection dispatches to the expected function.
assert_dispatch() {
  local script="$1"
  local selection="$2"
  local expected_function="$3"

  awk -v selection="$selection" -v expected="$expected_function" '
    $0 ~ "^[[:space:]]*" selection "\\)" { in_selection = 1; next }
    in_selection && $0 ~ "^[[:space:]]*" expected "[[:space:]]*$" { found = 1 }
    in_selection && /^[[:space:]]*;;/ { exit }
    END { exit(found ? 0 : 1) }
  ' "$script" || {
    printf 'dispatch mismatch: %s option %s should call %s\n' "$script" "$selection" "$expected_function" >&2
    return 1
  }
}

"$PROJECT_ROOT/tools/sync-restore-bootstrap.sh" check

for script in restore-main.sh restore-serv.sh restore-dots.sh; do
  run_standalone_help "$script"
  run_bundled_help "$script"
done

tmp="$(mktemp -d)"
cp "$PROJECT_ROOT/restore-main.sh" "$tmp/restore-main.sh"
chmod +x "$tmp/restore-main.sh"
printf 'N\n' | (cd "$tmp" && ./restore-main.sh >/dev/null)
rm -rf "$tmp"
printf 'cancel path OK: restore-main.sh\n'

tmp="$(mktemp -d)"
cp "$PROJECT_ROOT/restore-main.sh" "$tmp/restore-main.sh"
chmod +x "$tmp/restore-main.sh"
cat >"$tmp/backup-manifest.txt" <<'EOF'
Manifest Version = 999
Backup Status = [COMPLETED]
EOF
if printf 'N\n' | (cd "$tmp" && ./restore-main.sh >/dev/null 2>&1); then
  printf 'unsupported manifest version should block restore-main.sh\n' >&2
  exit 1
fi
rm -rf "$tmp"
printf 'manifest version guard OK: restore-main.sh\n'

tmp="$(mktemp -d)"
cp "$PROJECT_ROOT/restore-dots.sh" "$tmp/restore-dots.sh"
chmod +x "$tmp/restore-dots.sh"
printf '0\n' | (cd "$tmp" && ./restore-dots.sh >/dev/null)
rm -rf "$tmp"
printf 'exit path OK: restore-dots.sh\n'

grep -Fq '99 - Restore Settings' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '3 - Install HyprMod' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '4 - Install Extra' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '10 - Restore Wallpapers' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '14 - Restore HYPR' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '17 - Restore MATUGEN' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '18 - Restore CAVA' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '19 - Restore SWAYNC' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'yubico-authenticator-bin' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'python-ubi-reader-git' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'rambox-pro-bin' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'org.videolan.VLC' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'org.gnome.Calculator' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'sudo pacman -R vlc' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "flatpak install \"\$app\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "yay -S --needed -- \"\${missing_packages[@]}\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '98 - Collect pre-restore' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'uca.xml' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'dracula.qbtheme' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '99)' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "confirm_yes_no \"Start \$label?\" \"Y\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'current_login_shell()' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'ZSH is not default shell, run script?' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'ml4w-change-shell' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'BIG/wallpapers' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_folder "HYPR" "quickshell" "quickshell"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_folder "WAYBAR" "waybar/scripts" "waybar/scripts"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "local link_path=\"\$HOME/.config/cava\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "ln -s -- \"\$target_dir\" \"\$link_path\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_path "SWAYNC" "swaync" "swaync"' "$PROJECT_ROOT/restore-dots.sh"
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 1 install_dots
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 2 install_fonts
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 3 install_hyprmod
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 4 install_extra
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 10 restore_wallpapers
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 11 restore_zshrc
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 12 restore_kitty
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 13 restore_fastfetch
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 14 restore_hypr
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 15 restore_rofi
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 16 restore_waybar
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 17 restore_matugen
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 18 restore_cava
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 19 restore_swaync
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 98 collect_pre_restore
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 99 restore_settings
printf 'restore-dots settings menu OK\n'

grep -Fq '1 - Create SMB' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '5 - Restore grub theme' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '98 - Collect pre-restore' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '"/SMB/pneuma-win"' "$PROJECT_ROOT/restore-serv.sh"
if grep -Fq '"/SMB/pneuma-win"' "$PROJECT_ROOT/config/serv.restore.conf"; then
  printf 'retired SMB directory should not be in public restore config\n' >&2
  exit 1
fi
grep -Fq 'systemctl enable smb.service' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'systemctl enable sshd.service' "$PROJECT_ROOT/restore-serv.sh"
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 1 create_smb_tree
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 2 restore_samba
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 3 restore_ssh
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 4 restore_fstab
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 5 restore_grub_theme
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 6 restore_grub_defaults
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 98 collect_pre_restore
awk '
  /^restore_fstab\(\) / { in_func = 1 }
  in_func && /sudo modprobe cifs/ { modprobe_seen = 1 }
  in_func && /sudo install -m 0644 "\$temp_fstab" \/etc\/fstab/ {
    install_seen = 1
    if (!modprobe_seen) {
      exit 1
    }
  }
  in_func && /^}/ { exit(modprobe_seen && install_seen ? 0 : 1) }
' "$PROJECT_ROOT/restore-serv.sh" || {
  printf 'restore_fstab must run sudo modprobe cifs before installing /etc/fstab\n' >&2
  exit 1
}
printf 'restore-serv menu OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/home/PreRestored"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-serv.sh" >"$tmp/restore-serv-partial.sh"
cat >>"$tmp/restore-serv-partial.sh" <<'EOF'
FSTAB_LINES=(
  '//new/share   /SMB/test   cifs   _netdev,credentials=/etc/samba/creds-test,uid=1000,gid=1000   0 0'
)
replace_managed_fstab_entries "$1"
update_rollback_snapshot_path "/etc/fstab-pre-restore-test" "$HOME/PreRestored/fstab-pre-restore-test"
EOF
printf '%s\n' \
  '# test fstab' \
  'UUID=root / ext4 defaults 0 1' \
  '//old/share /SMB/test cifs old 0 0' \
  '//old/share /SMB/pneuma-win cifs old 0 0' \
  '//keep/share /SMB/keep cifs keep 0 0' >"$tmp/fstab"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'sudo cp -a /etc/fstab-pre-restore-test /etc/fstab' >"$tmp/restore-serv-rollback-test.sh"
chmod +x "$tmp/restore-serv-rollback-test.sh"
(cd "$tmp" && HOME="$tmp/home" bash restore-serv-partial.sh "$tmp/fstab" >/dev/null)
grep -Fq '//new/share   /SMB/test' "$tmp/fstab"
if grep -Fq '//old/share' "$tmp/fstab"; then
  printf 'stale managed fstab entry was not removed\n' >&2
  exit 1
fi
if grep -Fq '/SMB/pneuma-win' "$tmp/fstab"; then
  printf 'retired fstab entry was not removed\n' >&2
  exit 1
fi
grep -Fq '//keep/share /SMB/keep' "$tmp/fstab"
[[ "$(awk '$2 == "/SMB/test" { count++ } END { print count + 0 }' "$tmp/fstab")" -eq 1 ]]
grep -Fq "$tmp/home/PreRestored/fstab-pre-restore-test" "$tmp/restore-serv-rollback-test.sh"
rm -rf "$tmp"
printf 'restore-serv managed fstab and rollback path OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/bin" "$tmp/lib"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
cat >"$tmp/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"TARGET,SOURCE,FSTYPE"* ]]; then
  printf '%s\n' '/run/media/ralexander/HD4-04 /dev/sdd1 ext4'
  printf '%s\n' '/run/media/ralexander/1\x20TB\x20SSD /dev/sde1 ext4'
  exit 0
fi
exit 1
EOF
cat >"$tmp/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
case "${@: -1}" in
/dev/sdd1) printf '%s\n' 'HD4-04' ;;
/dev/sde1) printf '%s\n' '1 TB SSD' ;;
*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/df" <<'EOF'
#!/usr/bin/env bash
target="${@: -1}"
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '%s\n' "/dev/mock 100 1 1.2T 1% $target"
EOF
chmod +x "$tmp/bin/findmnt" "$tmp/bin/lsblk" "$tmp/bin/df"
(cd "$tmp" && PATH="$tmp/bin:$PATH" bash -c '
  source lib/common.sh
  mapfile -t mounts < <(list_external_mounts)
  [[ "${#mounts[@]}" -eq 2 ]]
  [[ "${mounts[1]}" == "/run/media/ralexander/1 TB SSD|/dev/sde1|ext4|1 TB SSD|1.2T free" ]]
')
rm -rf "$tmp"
printf 'external mount picker path decoding OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/logs"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-main.sh" >"$tmp/bkp-main-partial.sh"
cat >>"$tmp/bkp-main-partial.sh" <<'EOF'
SKIPPABLE_HOME_ITEMS=(Documents Downloads Pictures)
declare -A SKIP_HOME_ITEMS=()
UPDATE_SHARED_ONLY=false
prompt_skip_home_items >/dev/null <<<''
EOF
(cd "$tmp" && bash bkp-main-partial.sh)
rm -rf "$tmp"
printf 'blank skip selection OK: bkp-main.sh\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/logs"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-main.sh" >"$tmp/bkp-main-partial.sh"
cat >>"$tmp/bkp-main-partial.sh" <<'EOF'
SKIPPABLE_HOME_ITEMS=(Alpha Beta Gamma)
declare -A SKIP_HOME_ITEMS=()
UPDATE_SHARED_ONLY=false
prompt_skip_home_items >/dev/null <<<'2'
[[ -n "${SKIP_HOME_ITEMS[Beta]:-}" ]]
[[ -z "${SKIP_HOME_ITEMS[Alpha]:-}" ]]
EOF
(cd "$tmp" && bash bkp-main-partial.sh)
rm -rf "$tmp"
printf 'dynamic skip selection OK: bkp-main.sh\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/logs"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-main.sh" >"$tmp/bkp-main-partial.sh"
cat >>"$tmp/bkp-main-partial.sh" <<'EOF'
SKIPPABLE_HOME_ITEMS=(Alpha Beta Gamma)
declare -A SKIP_HOME_ITEMS=()
UPDATE_SHARED_ONLY=false
prompt_skip_home_items >/dev/null <<<'90'
[[ "$UPDATE_SHARED_ONLY" == "true" ]]
EOF
(cd "$tmp" && bash bkp-main-partial.sh)
rm -rf "$tmp"
printf 'BIG-only menu selection OK: bkp-main.sh\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/logs" "$tmp/home/Documents/030-Firmware" "$tmp/home/.mydotfiles/com.ml4w.dotfiles.stable/.config/ml4w/wallpapers" "$tmp/netac"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
cat >"$tmp/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '              0   0%    0.00kB/s    0:00:00 (xfr#0, to-chk=0/1)'
EOF
chmod +x "$tmp/bin/rsync"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-main.sh" >"$tmp/bkp-main-partial.sh"
cat >>"$tmp/bkp-main-partial.sh" <<'EOF'
HOME="$PWD/home"
DEST_DEVICE="$PWD/netac"
DOTS_SOURCE="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config"
WALLPAPERS_SOURCE="$DOTS_SOURCE/ml4w/wallpapers"
BIG_WALLPAPERS_DIR="$DEST_DEVICE/BIG/wallpapers"
FIRMWARE_SOURCE="$HOME/Documents/030-Firmware"
BIG_FIRMWARE_DIR="$DEST_DEVICE/BIG/030-Firmware"
PATH="$PWD/bin:$PATH"
update_shared_firmware_and_wallpapers
EOF
(cd "$tmp" && bash bkp-main-partial.sh >update-big.out)
grep -Fq '[INFO] Running BIG-only firmware and wallpapers update' "$tmp/update-big.out"
grep -Fq '[INFO] Updating shared wallpapers: /wallpapers -> /netac/BIG/wallpapers' "$tmp/update-big.out"
grep -Fq '[INFO] Updating shared firmware: /Documents/030-Firmware -> /netac/BIG/030-Firmware' "$tmp/update-big.out"
grep -Fq '[INFO] Done: BIG-only firmware and wallpapers update' "$tmp/update-big.out"
grep -Fq -- '- Updated Firmware and Wallpapers in /netac/BIG' "$tmp/update-big.out"
rm -rf "$tmp"
printf 'BIG-only update output OK: bkp-main.sh\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/logs"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-main.sh" >"$tmp/bkp-main-partial.sh"
cat >>"$tmp/bkp-main-partial.sh" <<'EOF'
SKIPPABLE_HOME_ITEMS=(Alpha Beta Gamma)
declare -A SKIP_HOME_ITEMS=()
UPDATE_SHARED_ONLY=false
prompt_skip_home_items >/dev/null <<<'0'
exit 1
EOF
(cd "$tmp" && bash bkp-main-partial.sh)
rm -rf "$tmp"
printf 'exit menu selection OK: bkp-main.sh\n'

grep -Fq 'config/local/restore-dots-settings.sh' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'DOTS/config/local/restore-dots-settings.sh' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'discover_home_items' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'big_update_info' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'update_shared_firmware_and_wallpapers' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq '90 - Update Firmware and Wallpapers' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'SKIPPABLE_HOME_ITEMS' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq "[[ -d \"\$DOTS_ROOT\" && -d \"\$DOTS_SOURCE\" ]]" "$PROJECT_ROOT/bkp-main.sh"
grep -Fq "Skipping missing dotfiles root: \$DOTS_ROOT" "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'BIG_WALLPAPERS_RELATIVE="BIG/wallpapers"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq 'FIRMWARE_HOME_RELATIVE="Documents/030-Firmware"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq 'BIG_FIRMWARE_RELATIVE="BIG/030-Firmware"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq 'BIG_HOME_FILES_RELATIVE="BIG"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq '".bash_history"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq '".zsh_history"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq '".zshrc"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq '".wget-hsts"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq "run_rsync_main rsync_backup_copy \"\$source_path\" \"\$BIG_HOME_FILES_DIR/\"" "$PROJECT_ROOT/bkp-main.sh"
grep -Fq -- "--ignore-existing" "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'DOCUMENTS_EXCLUDES=("030-Firmware/")' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq -- "--exclude='ml4w/wallpapers/'" "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'validate_tar_gz_archive' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'validate_tar_gz_archive' "$PROJECT_ROOT/bkp-serv.sh"
grep -Fq '.in-progress' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq '.in-progress' "$PROJECT_ROOT/bkp-serv.sh"
grep -Fq 'restore_shared_firmware' "$PROJECT_ROOT/restore-main.sh"
grep -Fq 'discover_restore_items' "$PROJECT_ROOT/restore-main.sh"
grep -Fq 'RESTORE_EXCLUDED_ITEMS' "$PROJECT_ROOT/restore-main.sh"
grep -Fq '"backup-manifest.json"' "$PROJECT_ROOT/restore-main.sh"
grep -Fq '"config"' "$PROJECT_ROOT/restore-main.sh"
grep -Fq 'BIG/030-Firmware' "$PROJECT_ROOT/restore-main.sh"
if grep -Fq '".bash_history"' "$PROJECT_ROOT/restore-main.sh"; then
  printf 'backup-only hidden files should not be restored by restore-main.sh\n' >&2
  exit 1
fi
grep -Fq 'config/local/serv.restore.conf' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'config/local/serv.restore.conf' "$PROJECT_ROOT/bkp-serv.sh"
grep -Fq '".vscode-oss"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq "install -m 0644 \"\$MAIN_BACKUP_CONFIG\" \"\$DOTS_DIR/config/main.backup.conf\"" "$PROJECT_ROOT/bkp-main.sh"
printf 'local config copy paths OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/logs" "$tmp/BKP"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-main.sh" >"$tmp/bkp-main-partial.sh"
cat >>"$tmp/bkp-main-partial.sh" <<'EOF'
DEST_DEVICE="/run/media/ralexander/netac"
BACKUP_DIR="$PWD/BKP"
ARCHIVE_NAME="$BACKUP_DIR.tar.gz"
CREATE_ARCHIVE=false
ARCHIVE_VALIDATION="not_requested"
RUN_RESULT="complete"
DOTS_ROOT="/home/ralexander/.mydotfiles"
DOTS_SOURCE="$DOTS_ROOT/com.ml4w.dotfiles.stable/.config"
WALLPAPERS_SOURCE="$DOTS_SOURCE/ml4w/wallpapers"
BIG_WALLPAPERS_DIR="$DEST_DEVICE/BIG/wallpapers"
FIRMWARE_SOURCE="/home/ralexander/Documents/030-Firmware"
BIG_FIRMWARE_DIR="$DEST_DEVICE/BIG/030-Firmware"
BIG_HOME_FILES_DIR="$DEST_DEVICE/BIG"
HOME_HIDDEN_FILES=(.bash_history .zsh_history .zshrc .wget-hsts)
HOME_ITEMS=(Code Desktop Documents .themes .icons .ssh .vscode-oss)
write_manifest
EOF
(cd "$tmp" && bash bkp-main-partial.sh >/dev/null)
grep -Fq 'Backup Type = [MAIN]' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'Manifest Version = 1' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'Archive Requested = [FALSE]' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'Backup Status = [COMPLETED]' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'DOTS root = /home/ralexander/.mydotfiles' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'Home Hidden Files = .bash_history .zsh_history .zshrc .wget-hsts' "$tmp/BKP/backup-manifest.txt"
python3 -m json.tool "$tmp/BKP/backup-manifest.json" >/dev/null
grep -Fq '"manifest_version": 1' "$tmp/BKP/backup-manifest.json"
rm -rf "$tmp"
printf 'main manifest format OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/logs" "$tmp/BKP"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-serv.sh" >"$tmp/bkp-serv-partial.sh"
cat >>"$tmp/bkp-serv-partial.sh" <<'EOF'
DEST_DEVICE="/run/media/ralexander/netac"
BACKUP_DIR="$PWD/BKP"
ARCHIVE_NAME="$BACKUP_DIR.tar.gz"
CREATE_ARCHIVE=true
ARCHIVE_VALIDATION="passed"
RUN_RESULT="complete"
LUKS_DEVICE_PATH="/dev/nvme0n1p2"
LUKS_HEADER_FILE="luks.bin"
LUKS_HEADER_CREATED=true
SERVICE_REQUIRED_PATHS=(/etc/samba/smb.conf /etc/ssh/sshd_config)
SERVICE_OPTIONAL_PATHS=(/boot/grub/themes/lateralus)
SERVICE_PATHS=("${SERVICE_REQUIRED_PATHS[@]}" "${SERVICE_OPTIONAL_PATHS[@]}")
SAMBA_CREDS_GLOB="/etc/samba/creds-*"
write_manifest
EOF
(cd "$tmp" && bash bkp-serv-partial.sh >/dev/null)
grep -Fq 'Backup Type = [SERVICE]' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'Archive Requested = [TRUE]' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'LUKS Header Created = [TRUE]' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'Service Paths = /etc/samba/smb.conf /etc/ssh/sshd_config /boot/grub/themes/lateralus' "$tmp/BKP/backup-manifest.txt"
python3 -m json.tool "$tmp/BKP/backup-manifest.json" >/dev/null
grep -Fq '"archive_validation": "PASSED"' "$tmp/BKP/backup-manifest.json"
rm -rf "$tmp"
printf 'service manifest format OK\n'

tmp="$(mktemp -d)"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/common.sh"
(cd "$tmp" && bash -c '
  source common.sh
  UI_ENABLED=false
  LOG_FILE="$PWD/test.log"
  log "plain info"
  log_warn "plain warning"
  log_error "plain error"
' >log-cli.out)
grep -Fq '[INFO] plain info' "$tmp/log-cli.out"
grep -Fq '[WARN] plain warning' "$tmp/log-cli.out"
grep -Fq '[ERROR] plain error' "$tmp/log-cli.out"
if grep -Eq '\[[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$tmp/log-cli.out"; then
  printf 'timestamp should not be shown in CLI log output\n' >&2
  exit 1
fi
grep -Eq '\[[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$tmp/test.log"
rm -rf "$tmp"
printf 'clean CLI log output OK\n'

tmp="$(mktemp -d)"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/common.sh"
printf 'first-generation-log\n' >"$tmp/test.log"
(cd "$tmp" && bash -c '
  source common.sh
  rotate_log_file "$PWD/test.log" 1 2
  printf "second-generation-log\n" >test.log
  rotate_log_file "$PWD/test.log" 1 2
')
grep -Fq 'second-generation-log' "$tmp/test.log.1"
grep -Fq 'first-generation-log' "$tmp/test.log.2"
rm -rf "$tmp"
printf 'log rotation OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/source"
printf 'archive-test\n' >"$tmp/source/file.txt"
tar -C "$tmp" -cf - source | pigz >"$tmp/valid.tar.gz"
bash -c 'source "$1"; validate_tar_gz_archive "$2"' _ "$PROJECT_ROOT/lib/common.sh" "$tmp/valid.tar.gz"
cp "$tmp/valid.tar.gz" "$tmp/corrupt.tar.gz"
truncate -s -5 "$tmp/corrupt.tar.gz"
if bash -c 'source "$1"; validate_tar_gz_archive "$2"' _ "$PROJECT_ROOT/lib/common.sh" "$tmp/corrupt.tar.gz" >/dev/null 2>&1; then
  printf 'corrupt archive should fail validation\n' >&2
  exit 1
fi
rm -rf "$tmp"
printf 'archive validation OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/logs" "$tmp/MAIN/.BKP-test.in-progress"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-main.sh" >"$tmp/bkp-main-partial.sh"
touch "$tmp/MAIN/.BKP-test.in-progress/backup-manifest.txt"
touch "$tmp/MAIN/.BKP-test.in-progress/backup-manifest.json"
cat >>"$tmp/bkp-main-partial.sh" <<'EOF'
BACKUP_DIR="$PWD/MAIN/.BKP-test.in-progress"
FINAL_BACKUP_DIR="$PWD/MAIN/BKP-test"
DOTS_DIR="$BACKUP_DIR/DOTS"
promote_staged_backup
[[ "$BACKUP_DIR" == "$FINAL_BACKUP_DIR" ]]
[[ -f "$BACKUP_DIR/backup-manifest.json" ]]
EOF
(cd "$tmp" && bash bkp-main-partial.sh >/dev/null)
[[ -d "$tmp/MAIN/BKP-test" ]]
[[ ! -e "$tmp/MAIN/.BKP-test.in-progress" ]]
rm -rf "$tmp"
printf 'atomic backup publication OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/MAIN/BKP-test" "$tmp/SERV/BKP-legacy"
cat >"$tmp/MAIN/BKP-test/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Created = 2026-08-20T12:00:00+02:00
Backup Status = [COMPLETED]
Archive Validation = [PASSED]
EOF
touch "$tmp/MAIN/BKP-test.tar.gz"
cat >"$tmp/SERV/BKP-legacy/backup-manifest.txt" <<'EOF'
created_at=2025-01-02T03:04:05+00:00
backup_status=complete
EOF
"$PROJECT_ROOT/catalog.sh" "$tmp" >"$tmp/catalog.out"
grep -Fq 'MAIN' "$tmp/catalog.out"
grep -Fq 'BKP-test' "$tmp/catalog.out"
grep -Fq 'COMPLETED' "$tmp/catalog.out"
grep -Fq 'PASSED' "$tmp/catalog.out"
grep -Fq 'BKP-legacy' "$tmp/catalog.out"
grep -Fq '2025-01-02T03:04:05+00:00' "$tmp/catalog.out"
rm -rf "$tmp"
printf 'backup catalog OK\n'

tmp="$(mktemp -d)"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/common.sh"
set +e
(cd "$tmp" && bash -c '
  source common.sh
  UI_ENABLED=false
  LOG_FILE="$PWD/signal.log"
  handle_termination_signal TERM 143
' >/dev/null 2>&1)
signal_rc=$?
set -e
[[ "$signal_rc" -eq 143 ]]
grep -Fq 'run interrupted by signal: TERM' "$tmp/signal.log"
rm -rf "$tmp"
printf 'signal handling OK\n'

tmp="$(mktemp -d)"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/common.sh"
(cd "$tmp" && bash -c '
  source common.sh
  UI_ENABLED=true
  UI_LAST_RENDER_TS=0
  ui_add_meta "Destination" "/run/media/ralexander/netac"
  ui_add_task "downloads" "Downloads" "DONE" "copied"
  ui_add_task "pictures" "Pictures" "RUNNING" "copying"
  ui_add_task_separator_after "pictures" "Hidden folders"
  ui_add_task "themes" ".themes" "PENDING" "waiting"
  ui_add_task_separator_after "themes" "Post backup"
  ui_add_task "manifest" "Write manifest" "PENDING" "waiting"
  ui_render force
' >dashboard.out)
grep -Fq 'Metric | Value' "$tmp/dashboard.out"
grep -Eq '^Total = 4[[:space:]]+\| Done = 1[[:space:]]+\| Running = 1$' "$tmp/dashboard.out"
grep -Fq 'Selected Options' "$tmp/dashboard.out"
grep -Fq 'Task' "$tmp/dashboard.out"
grep -Fq 'Hidden folders' "$tmp/dashboard.out"
grep -Fq 'Post backup' "$tmp/dashboard.out"
rm -rf "$tmp"
printf 'dashboard task grouping OK\n'

tmp="$(mktemp -d)"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/common.sh"
(cd "$tmp" && bash -c '
  source common.sh
  UI_BACKUP_LABEL=SERVICE
  UI_ENABLED=true
  UI_LAST_RENDER_TS=0
  ui_add_meta "Destination" "/SERV/BKP-229-17-08-18-15-34"
  ui_add_meta "Archive" "NO"
  ui_add_meta "LUKS Device" "YES [Auto-Detect]"
  ui_add_task "smb" "SMB config" "DONE" "No Error"
  ui_add_task "ssh" "SSH config" "DONE" "No Error"
  ui_add_task "creds" "Samba creds-*" "RUNNING" "copying /etc/samba/creds-home (0s)"
  ui_add_task_separator_after "creds" "Post Backup"
  ui_add_task "restore" "Copy restore-serv.sh" "DONE" "COPIED"
  ui_add_task "luks" "Backup luks.bin" "DONE" "SAVED: luks.bin"
  ui_add_task "manifest" "Write manifest" "DONE" "WRITTEN"
  ui_finalize "SUCCESS" "All selected SERVICE backup tasks completed."
' >service-dashboard.out)
grep -Fq 'Metric | Value' "$tmp/service-dashboard.out"
if grep -Eq '(Started|Start|End|Time) = ' "$tmp/service-dashboard.out"; then
  printf 'time metrics should not be shown in service dashboard\n' >&2
  exit 1
fi
grep -Fq 'Destination        | /SERV/BKP-229-17-08-18-15-34' "$tmp/service-dashboard.out"
grep -Fq 'Archive            | NO' "$tmp/service-dashboard.out"
grep -Fq 'LUKS Device        | YES [Auto-Detect]' "$tmp/service-dashboard.out"
grep -Fq 'SMB config               | OK/DONE  | NO ERROR' "$tmp/service-dashboard.out"
grep -Fq 'Samba creds-*            | RUNNING  | COPY: /etc/samba/creds-home (0s)' "$tmp/service-dashboard.out"
grep -Fq 'Post Backup' "$tmp/service-dashboard.out"
grep -Fq '[INFO] : SUCCESS... SERVICE backup COMPLETED' "$tmp/service-dashboard.out"
grep -Fq '[ERROR]: No Error Occurred' "$tmp/service-dashboard.out"
rm -rf "$tmp"
printf 'service dashboard OK\n'

tmp="$(mktemp -d)"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/common.sh"
(cd "$tmp" && bash -c '
  source common.sh
  UI_BACKUP_LABEL=MAIN
  UI_ENABLED=true
  UI_LAST_RENDER_TS=0
  ui_add_meta "Destination" "/MAIN/BKP-229-17-08-18-27-32"
  ui_add_meta "Archive" "NO"
  ui_add_meta "Skipped Folders" "1"
  ui_add_task "code" "Code" "DONE" "No Error"
  ui_add_task "templates" "Templates" "SKIPPED" "SKIPPED"
  ui_add_task_separator_after "templates" "Hidden Folders"
  ui_add_task "themes" ".themes" "RUNNING" "copying from $HOME/.themes (0s)"
  ui_add_task_separator_after "themes" "Post Backup"
  ui_add_task "restore" "Copy restore-main.sh" "DONE" "COPIED"
  ui_add_task "hidden" "Backup hidden files" "DONE" "COPIED 4 file(s)"
  ui_add_task "manifest" "Write manifest" "DONE" "WRITTEN"
  ui_finalize "SUCCESS" "All selected MAIN backup tasks completed."
' >main-dashboard.out)
if grep -Eq '(Started|Start|End|Time) = ' "$tmp/main-dashboard.out"; then
  printf 'time metrics should not be shown in main dashboard\n' >&2
  exit 1
fi
grep -Fq 'Destination        | /MAIN/BKP-229-17-08-18-27-32' "$tmp/main-dashboard.out"
grep -Fq 'Skipped Folders    | 1' "$tmp/main-dashboard.out"
grep -Fq 'Code                     | OK/DONE  | NO ERROR' "$tmp/main-dashboard.out"
grep -Fq 'Templates                | SKIPPED  | SKIPPED' "$tmp/main-dashboard.out"
grep -Fq 'Hidden Folders' "$tmp/main-dashboard.out"
grep -Fq '.themes                  | RUNNING  | COPY: /.themes (0s)' "$tmp/main-dashboard.out"
grep -Fq 'Copy restore-main.sh     | OK/DONE  | COPIED' "$tmp/main-dashboard.out"
grep -Fq '[INFO] : SUCCESS... MAIN backup COMPLETED' "$tmp/main-dashboard.out"
grep -Fq '[ERROR]: No Error Occurred' "$tmp/main-dashboard.out"
rm -rf "$tmp"
printf 'main dashboard OK\n'

printf 'smoke OK\n'
