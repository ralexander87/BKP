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
cp "$PROJECT_ROOT/restore-dots.sh" "$tmp/restore-dots.sh"
chmod +x "$tmp/restore-dots.sh"
printf '0\n' | (cd "$tmp" && ./restore-dots.sh >/dev/null)
rm -rf "$tmp"
printf 'exit path OK: restore-dots.sh\n'

grep -Fq '99 - Restore Settings' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '3 - Restore Wallpapers' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '4 - Install HyprMod' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '8 - Restore HYPR' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '11 - Restore MATUGEN' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '98 - Collect pre-restore' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'uca.xml' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'dracula.qbtheme' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '99)' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'confirm_yes_no "Start $label?" "Y"' "$PROJECT_ROOT/restore-dots.sh"
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 1 install_dots
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 2 install_fonts
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 3 restore_wallpapers
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 4 install_hyprmod
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 5 restore_fastfetch
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 6 restore_kitty
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 7 restore_zshrc
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 8 restore_hypr
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 9 restore_rofi
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 10 restore_waybar
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 11 restore_matugen
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 98 collect_pre_restore
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 99 restore_settings
printf 'restore-dots settings menu OK\n'

grep -Fq '1 - Create SMB' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '5 - Restore grub theme' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '98 - Collect pre-restore' "$PROJECT_ROOT/restore-serv.sh"
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
mkdir -p "$tmp/lib"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-main.sh" >"$tmp/bkp-main-partial.sh"
cat >>"$tmp/bkp-main-partial.sh" <<'EOF'
declare -A SKIP_HOME_ITEMS=()
printf '\n' | prompt_skip_home_items >/dev/null
EOF
(cd "$tmp" && bash bkp-main-partial.sh)
rm -rf "$tmp"
printf 'blank skip selection OK: bkp-main.sh\n'

grep -Fq 'config/local/restore-dots-settings.sh' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'DOTS/config/local/restore-dots-settings.sh' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'config/local/serv.restore.conf' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'config/local/serv.restore.conf' "$PROJECT_ROOT/bkp-serv.sh"
grep -Fq '".vscode-oss"' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq '".vscode-oss"' "$PROJECT_ROOT/restore-main.sh"
printf 'local config copy paths OK\n'

grep -Fq 'ui_add_task_separator_after "main-Documents"' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'ui_add_task_separator_after "main-.vscode-oss"' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'Copy restore-main.sh' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'ui_add_task_separator_after "serv-creds"' "$PROJECT_ROOT/bkp-serv.sh"
grep -Fq 'Copy restore-serv.sh' "$PROJECT_ROOT/bkp-serv.sh"
printf 'dashboard task grouping OK\n'

printf 'smoke OK\n'
