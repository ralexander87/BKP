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
    in_selection && $0 ~ "(^|[[:space:]])" expected "([[:space:]]|$)" { found = 1 }
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
if printf 'N\n' | (cd "$tmp" && ./restore-main.sh >/dev/null 2>&1); then
  printf 'restore-main.sh should reject an unmarked source folder\n' >&2
  exit 1
fi
cat >"$tmp/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [COMPLETED]
EOF
printf 'N\n' | (cd "$tmp" && ./restore-main.sh >/dev/null)
rm -rf "$tmp"
printf 'source guard and cancel path OK: restore-main.sh\n'

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
mkdir -p "$tmp/backup/Documents" "$tmp/home/Documents"
cp "$PROJECT_ROOT/restore-main.sh" "$tmp/backup/restore-main.sh"
chmod +x "$tmp/backup/restore-main.sh"
cat >"$tmp/backup/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Status = [COMPLETED]
EOF
printf 'new\n' >"$tmp/backup/Documents/new.txt"
printf 'old\n' >"$tmp/home/Documents/old.txt"
printf 'Y\n' | (cd "$tmp/backup" && HOME="$tmp/home" ./restore-main.sh >"$tmp/restore-main.out")
[[ -f "$tmp/home/Documents/new.txt" ]]
grep -Fq '[INFO] Restored: Documents' "$tmp/restore-main.out"
if grep -Eq '[[:digit:]]+%' "$tmp/restore-main.out"; then
  printf 'restore-main.sh should not print rsync progress percentages\n' >&2
  exit 1
fi
find "$tmp/home/PreRestored" -mindepth 1 -maxdepth 1 -type d -name 'Documents-pre-restore-*' \
  -exec test -f '{}/old.txt' \; -print -quit | grep -q .
rm -rf "$tmp"
printf 'automatic pre-restore collection OK: restore-main.sh\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/backup" "$tmp/home" "$tmp/state"
cp "$PROJECT_ROOT/restore-main.sh" "$tmp/backup/restore-main.sh"
chmod +x "$tmp/backup/restore-main.sh"
cat >"$tmp/backup/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [COMPLETED]
EOF
chmod 555 "$tmp/backup"
printf 'N\n' | HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" "$tmp/backup/restore-main.sh" >/dev/null
find "$tmp/state/bkp" -maxdepth 1 -type f -name 'restore-main-*.log' -print -quit | grep -q .
chmod 755 "$tmp/backup"
rm -rf "$tmp"
printf 'read-only restore runtime fallback OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/bin" "$tmp/backup" "$tmp/home" "$tmp/state"
cp "$PROJECT_ROOT/restore-serv.sh" "$tmp/backup/restore-serv.sh"
chmod +x "$tmp/backup/restore-serv.sh"
cat >"$tmp/backup/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [SERVICE]
Backup Status = [COMPLETED]
EOF
cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
  exit 0
fi
exec "$@"
EOF
chmod +x "$tmp/bin/sudo"
chmod 555 "$tmp/backup"
printf '0\n' | HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" PATH="$tmp/bin:$PATH" "$tmp/backup/restore-serv.sh" >/dev/null
find "$tmp/state/bkp" -maxdepth 1 -type f -name 'restore-serv-*.log' -print -quit | grep -q .
find "$tmp/state/bkp" -maxdepth 1 -type f -name 'restore-serv-rollback-*.sh' -print -quit | grep -q .
chmod 755 "$tmp/backup"
rm -rf "$tmp"
printf 'read-only service runtime fallback OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/BKP/DOTS" "$tmp/home" "$tmp/state"
cp "$PROJECT_ROOT/restore-dots.sh" "$tmp/BKP/DOTS/restore-dots.sh"
chmod +x "$tmp/BKP/DOTS/restore-dots.sh"
cat >"$tmp/BKP/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [COMPLETED]
EOF
chmod 555 "$tmp/BKP" "$tmp/BKP/DOTS"
printf '0\n' | HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" "$tmp/BKP/DOTS/restore-dots.sh" >/dev/null
find "$tmp/state/bkp" -maxdepth 1 -type f -name 'restore-dots-*.log' -print -quit | grep -q .
chmod 755 "$tmp/BKP" "$tmp/BKP/DOTS"
rm -rf "$tmp"
printf 'read-only DOTS runtime fallback OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/BKP/DOTS"
cp "$PROJECT_ROOT/restore-dots.sh" "$tmp/BKP/DOTS/restore-dots.sh"
chmod +x "$tmp/BKP/DOTS/restore-dots.sh"
cat >"$tmp/BKP/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [FAILED]
EOF
if printf '0\n' | (cd "$tmp/BKP/DOTS" && ./restore-dots.sh >/dev/null 2>&1); then
  printf 'restore-dots.sh should reject a failed parent backup\n' >&2
  exit 1
fi
sed -i 's/\[FAILED\]/[COMPLETED]/' "$tmp/BKP/backup-manifest.txt"
printf '0\n' | (cd "$tmp/BKP/DOTS" && ./restore-dots.sh >/dev/null)
rm -rf "$tmp"
printf 'parent status guard and exit path OK: restore-dots.sh\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/bin" "$tmp/BKP/DOTS" "$tmp/home/.config/hypr"
cp "$PROJECT_ROOT/restore-dots.sh" "$tmp/BKP/DOTS/restore-dots.sh"
chmod +x "$tmp/BKP/DOTS/restore-dots.sh"
printf 'keep\n' >"$tmp/home/.config/hypr/current.conf"
cat >"$tmp/BKP/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [COMPLETED]
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
output=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
printf '#!/usr/bin/env bash\n' >"$output"
EOF
chmod +x "$tmp/bin/curl"
printf '1\nY\nN\n0\n' | (
  cd "$tmp/BKP/DOTS" && HOME="$tmp/home" PATH="$tmp/bin:$PATH" ./restore-dots.sh >/dev/null
)
[[ -f "$tmp/home/.config/hypr/current.conf" ]]
if find "$tmp/home/.config" -maxdepth 1 -name 'hypr-pre-restore-*' -print -quit | grep -q .; then
  printf 'declining downloaded installer execution should not move the Hypr config\n' >&2
  exit 1
fi
rm -rf "$tmp"
printf 'Install DOTS second-confirmation safety OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/bin" "$tmp/BKP/DOTS" "$tmp/home"
cp "$PROJECT_ROOT/restore-dots.sh" "$tmp/BKP/DOTS/restore-dots.sh"
chmod +x "$tmp/BKP/DOTS/restore-dots.sh"
cat >"$tmp/BKP/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [COMPLETED]
EOF
cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$tmp/bin/sudo"
printf '[Autologin]\nUser=old-user\n' >"$tmp/default.conf"
test_user="$(id -un)"
printf '5\nY\n0\n' | (
  cd "$tmp/BKP/DOTS" && HOME="$tmp/home" PATH="$tmp/bin:$PATH" USER="$test_user" SDDM_CONFIG="$tmp/default.conf" ./restore-dots.sh >/dev/null
)
grep -Fqx "User=$test_user" "$tmp/default.conf"
find "$tmp/home/PreRestored" -maxdepth 1 -type f -name 'default.conf-pre-restore-*' -print -quit | grep -q .
rm -rf "$tmp"
printf 'SDDM AutoLogin update OK: restore-dots.sh\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/home/.mydotfiles/com.ml4w.dotfiles.stable/.config/matugen" "$tmp/matugen"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
printf 'new\n' >"$tmp/matugen/config.toml"
printf 'old\n' >"$tmp/home/.mydotfiles/com.ml4w.dotfiles.stable/.config/matugen/config.toml"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-dots.sh" >"$tmp/restore-dots-partial.sh"
cat >>"$tmp/restore-dots-partial.sh" <<'EOF'
restore_config_file "MATUGEN" "matugen/config.toml" "matugen/config.toml"
EOF
(cd "$tmp" && HOME="$tmp/home" bash restore-dots-partial.sh >/dev/null)
grep -Fqx 'new' "$tmp/home/.mydotfiles/com.ml4w.dotfiles.stable/.config/matugen/config.toml"
find "$tmp/home/PreRestored" -maxdepth 1 \
  -name 'config.toml-pre-restore-*' -exec grep -Fqx 'old' '{}' \; -print -quit | grep -q .
rm -rf "$tmp"
printf 'DOTS file snapshot OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/lib"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-dots.sh" >"$tmp/restore-dots-partial.sh"
cat >>"$tmp/restore-dots-partial.sh" <<'EOF'
init_install_extra_log
EXTRA_MISSING_ITEMS=("Package: missing-test")
run_extra_command "Install test" bash -c 'printf "noisy package output\n"; exit 7' || true
finalize_install_extra_log "FAILED"
EOF
(cd "$tmp" && bash restore-dots-partial.sh >restore-dots.out 2>&1)
[[ "$(sed -n '1p' "$tmp/install-extra.log")" == 'Install Extra = [FAILED]' ]]
grep -Fq '  - Package: missing-test' "$tmp/install-extra.log"
grep -Fq '  - Install test (exit 7)' "$tmp/install-extra.log"
grep -Fq 'Process Log:' "$tmp/install-extra.log"
grep -Fq 'noisy package output' "$tmp/install-extra.log"
if grep -Fq 'noisy package output' "$tmp/restore-dots.out"; then
  printf 'Install Extra command output should stay in its detailed log\n' >&2
  exit 1
fi
rm -rf "$tmp"
printf 'Install Extra log format OK: restore-dots.sh\n'

grep -Fq 'RSYNC_RESTORE_ARGS=(-aAXH --numeric-ids)' "$PROJECT_ROOT/restore-dots.sh"
if grep -Fq "tee -a \"\$INSTALL_EXTRA_BODY\"" "$PROJECT_ROOT/restore-dots.sh"; then
  printf 'Install Extra command output should stay in its log instead of flooding the terminal\n' >&2
  exit 1
fi
grep -Fq '99 - Restore Settings' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '3 - Install HyprMod' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '4 - Install Extra' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '5 - Set AutoLogin' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '6 - Change SHELL' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '10 - Restore Wallpapers' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '14 - Restore HYPR' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '17 - Restore MATUGEN' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_folder "MATUGEN" "matugen/templates" "matugen/templates"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '18 - Restore CAVA' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '19 - Restore SWAYNC' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '20 - Restore WLOGOUT' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '21 - Restore QS' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'yubico-authenticator-bin' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'python-ubi-reader-git' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'rambox-pro-bin' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'qrencode' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'python-pywalfox' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'org.videolan.VLC' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'org.gnome.Calculator' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'sudo pacman -R --noconfirm vlc' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'ensure_yay_installed' "$PROJECT_ROOT/restore-dots.sh"
awk '
  /^install_hyprmod\(\)/ { in_func = 1 }
  in_func && /ensure_yay_installed/ { yay_check_seen = 1 }
  in_func && /bash "\$installer"/ {
    installer_seen = 1
    if (!yay_check_seen) {
      exit 1
    }
  }
  in_func && /^}/ { exit(yay_check_seen && installer_seen ? 0 : 1) }
' "$PROJECT_ROOT/restore-dots.sh" || {
  printf 'Install HyprMod must ensure yay is installed before running its installer\n' >&2
  exit 1
}
grep -Fq 'sudo pacman -S --needed --noconfirm base-devel git' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'https://aur.archlinux.org/yay.git' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "makepkg -si --needed --noconfirm" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "flatpak install --noninteractive -y \"\$app\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "yay -S --needed --noconfirm -- \"\${missing_packages[@]}\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '98 - Collect pre-restore' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'uca.xml' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'dracula.qbtheme' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '99)' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "confirm_yes_no \"Start \$label?\" \"N\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'ml4w-change-shell' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'BIG/wallpapers' "$PROJECT_ROOT/restore-dots.sh"
if sed -n '/^restore_hypr()/,/^}/p' "$PROJECT_ROOT/restore-dots.sh" | grep -Eq 'gtk-3.0/bookmarks|waybar/modules.json|quickshell|qs (kill|-d)'; then
  printf 'Restore HYPR should not restore Settings, Waybar, or Quickshell content\n' >&2
  exit 1
fi
grep -Fq 'restore_config_file "Settings" "gtk-3.0/bookmarks" "gtk-3.0/bookmarks"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_file "Settings" "xsettingsd/xsettingsd.conf" "xsettingsd/xsettingsd.conf"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_folder "QS" "quickshell" "quickshell"' "$PROJECT_ROOT/restore-dots.sh"
awk '
  /^restore_qs\(\)/ { in_func = 1 }
  in_func && /^[[:space:]]+qs kill$/ { kill_seen = 1 }
  in_func && /^[[:space:]]+qs -d$/ {
    daemon_seen = 1
    if (!kill_seen) {
      exit 1
    }
  }
  in_func && /^}/ { exit(kill_seen && daemon_seen ? 0 : 1) }
' "$PROJECT_ROOT/restore-dots.sh" || {
  printf 'Restore QS must run qs kill before qs -d\n' >&2
  exit 1
}
grep -Fq 'restore_config_folder "WAYBAR" "waybar/scripts" "waybar/scripts"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_file "WAYBAR" "waybar/modules.json" "waybar/modules.json"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "local link_path=\"\$HOME/.config/cava\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "ln -s -- \"\$target_dir\" \"\$link_path\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_path "SWAYNC" "swaync" "swaync"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_path "WLOGOUT" "wlogout" "wlogout"' "$PROJECT_ROOT/restore-dots.sh"
if grep -Fq 'customize_wlogout_glass_style' "$PROJECT_ROOT/restore-dots.sh"; then
  printf 'retired wlogout style customization should not remain\n' >&2
  exit 1
fi
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 1 install_dots
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 2 install_fonts
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 3 install_hyprmod
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 4 install_extra
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 5 set_autologin
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 6 change_shell
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
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 20 restore_wlogout
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 21 restore_qs
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 98 collect_pre_restore
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 99 restore_settings
printf 'restore-dots settings menu OK\n'

tmp="$(mktemp -d)"
dots_dir="$tmp/device/MAIN/BKP-test/DOTS"
mkdir -p \
  "$dots_dir/lib" \
  "$dots_dir/hypr/conf/keybindings" \
  "$dots_dir/hypr/conf/windowrules" \
  "$dots_dir/hypr/scripts" \
  "$dots_dir/waybar/themes" \
  "$dots_dir/waybar/scripts" \
  "$dots_dir/quickshell/overview" \
  "$dots_dir/gtk-3.0" \
  "$dots_dir/gtk-4.0" \
  "$dots_dir/qt6ct" \
  "$dots_dir/xsettingsd" \
  "$dots_dir/ml4w/settings" \
  "$tmp/device/BIG" \
  "$tmp/home"
cp "$PROJECT_ROOT/lib/common.sh" "$dots_dir/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-dots.sh" >"$dots_dir/restore-dots-partial.sh"
for source_rel in \
  hypr/conf/keybindings/default.lua \
  hypr/conf/monitor.lua \
  hypr/conf/windowrules/default.lua \
  hypr/hypridle.conf \
  hypr/hyprlock.conf \
  hypr/hyprland-gui.lua \
  hypr/logo-2.png \
  hypr/scripts/uptime.sh \
  waybar/modules.json \
  gtk-3.0/bookmarks \
  gtk-3.0/settings.ini \
  gtk-4.0/settings.ini \
  qt6ct/qt6ct.conf \
  xsettingsd/xsettingsd.conf \
  ml4w/settings/filemanager \
  ml4w/settings/kitty-cursor-trail.conf \
  ml4w/settings/rofi-border-radius.rasi \
  ml4w/settings/rofi-border.rasi \
  ml4w/settings/rofi-font.rasi \
  ml4w/settings/rofi_bordersize.sh \
  ml4w/settings/screenshot-editor \
  ml4w/settings/screenshot-folder \
  ml4w/settings/terminal.sh \
  ml4w/settings/waybar-quicklinks.json \
  ml4w/settings/waybar_quicklinks.sh \
  ml4w/settings/waybar_workspaces.sh; do
  printf 'fixture: %s\n' "$source_rel" >"$dots_dir/$source_rel"
done
printf 'theme fixture\n' >"$dots_dir/waybar/themes/theme.css"
printf 'script fixture\n' >"$dots_dir/waybar/scripts/test.sh"
cat >"$dots_dir/quickshell/overview/config.json" <<'EOF'
{
  "main": "Fira Sans Semibold",
  "title": "Fira Sans Semibold",
  "expressive": "Fira Sans Semibold"
}
EOF
printf 'theme fixture\n' >"$tmp/device/BIG/dracula.qbtheme"
cat >>"$dots_dir/restore-dots-partial.sh" <<'EOF'
ML4W_CONFIG_ROOT="$HOME/ml4w-config"
RESTORE_ID="functional-test"
confirm_action() { return 0; }
qs() { printf '%s\n' "$*" >>"$HOME/qs-actions.log"; }

restore_hypr
[[ -f "$ML4W_CONFIG_ROOT/hypr/conf/keybindings/default.lua" ]]
[[ ! -e "$ML4W_CONFIG_ROOT/waybar/modules.json" ]]
[[ ! -e "$ML4W_CONFIG_ROOT/quickshell" ]]

restore_waybar
[[ -f "$ML4W_CONFIG_ROOT/waybar/modules.json" ]]
[[ -f "$ML4W_CONFIG_ROOT/waybar/themes/theme.css" ]]
[[ -f "$ML4W_CONFIG_ROOT/waybar/scripts/test.sh" ]]

restore_qs
grep -Fq '"main": "Monofur Nerd Font"' "$ML4W_CONFIG_ROOT/quickshell/overview/config.json"
[[ "$(sed -n '1p' "$HOME/qs-actions.log")" == "kill" ]]
[[ "$(sed -n '2p' "$HOME/qs-actions.log")" == "-d" ]]

restore_settings
[[ -f "$ML4W_CONFIG_ROOT/gtk-3.0/bookmarks" ]]
[[ -f "$ML4W_CONFIG_ROOT/xsettingsd/xsettingsd.conf" ]]
EOF
(cd "$dots_dir" && HOME="$tmp/home" bash restore-dots-partial.sh >/dev/null)
rm -rf "$tmp"
printf 'restore-dots split action behavior OK\n'

grep -Fq '1 - Create SMB' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '5 - Restore grub theme' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'GRUB_THEME_SHARED_RELATIVE="BIG/lateralus"' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq "source_dir=\"\$device_root/\$GRUB_THEME_SHARED_RELATIVE\"" "$PROJECT_ROOT/restore-serv.sh"
grep -Fq "restore_tree_to_system \"\$source_dir\" \"\$target_dir\"" "$PROJECT_ROOT/restore-serv.sh"
grep -Fq "sudo rsync -rlt --no-perms --no-owner --no-group \"\$source_dir/\" \"\$target_dir/\"" "$PROJECT_ROOT/restore-serv.sh"
if grep -Fq 'GRUB_THEME_SOURCE' "$PROJECT_ROOT/bkp-serv.sh" "$PROJECT_ROOT/config/serv.backup.conf"; then
  printf 'service backup should not copy the shared GRUB theme\n' >&2
  exit 1
fi
grep -Fq '90 - Restore sharing profile' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '91 - Restore boot profile' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '92 - Restore discovery services' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '93 - Restore smart-card service' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '94 - Restore complete profile' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '7 - Restore RAMBOX' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq "sudo chmod 755 \"\$target_dir\"" "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '98 - Collect pre-restore' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '"/SMB/pneuma-win"' "$PROJECT_ROOT/restore-serv.sh"
if grep -Fq '"/SMB/pneuma-win"' "$PROJECT_ROOT/config/serv.restore.conf"; then
  printf 'retired SMB directory should not be in public restore config\n' >&2
  exit 1
fi
grep -Fq "validate_sshd_config_file \"\$SCRIPT_DIR/sshd_config\"" "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'sudo ssh-keygen -A' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'enable_and_refresh_unit "sshd.service"' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'sudo chown root:root /etc/samba/smb.conf' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'sudo chmod 644 /etc/samba/smb.conf' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'enable_and_refresh_unit "smb.service"' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'enable_and_refresh_unit "nmb.service"' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'enable_and_refresh_unit "pcscd.socket"' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq "sudo systemctl restart \"\$unit\"" "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'sudo timeshift --create' "$PROJECT_ROOT/restore-serv.sh"
if [[ "$(grep -Fc 'sudo chmod 644 /etc/ssh/sshd_config' "$PROJECT_ROOT/restore-serv.sh")" -ne 1 ]]; then
  printf 'The explicit SSH action must set sshd_config mode to 644\n' >&2
  exit 1
fi
if grep -Fq 'sudo chmod 600 /etc/ssh/sshd_config' "$PROJECT_ROOT/restore-serv.sh"; then
  printf 'SSH restore paths should not set sshd_config mode to 600\n' >&2
  exit 1
fi
if sed -n '/^restore_sharing_profile()/,/^}/p; /^restore_boot_profile()/,/^}/p; /^restore_discovery_profile()/,/^}/p; /^restore_smartcard_profile()/,/^}/p' \
  "$PROJECT_ROOT/restore-serv.sh" | grep -Eq 'SSH|ssh'; then
  printf 'Non-SSH service profiles must not include SSH actions\n' >&2
  exit 1
fi
for profile_action in restore_sharing_profile restore_ssh restore_boot_profile restore_discovery_profile restore_smartcard_profile; do
  sed -n '/^restore_complete_profile()/,/^}/p' "$PROJECT_ROOT/restore-serv.sh" | grep -Fq "$profile_action"
done
grep -Fq 'SSH_CONFIG_DROPIN_SOURCE="/etc/ssh/sshd_config.d"' "$PROJECT_ROOT/config/serv.backup.conf"
grep -Fq "backup_path \"serv-sshd-dropins\" \"\$SSH_CONFIG_DROPIN_SOURCE\"" "$PROJECT_ROOT/bkp-serv.sh"
grep -Fq "restore_tree_to_system \"\$source_dropin_dir\" \"\$target_dropin_dir\"" "$PROJECT_ROOT/restore-serv.sh"
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 1 create_smb_tree
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 2 restore_samba
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 3 restore_ssh
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 4 restore_fstab
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 5 restore_grub_theme
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 6 restore_grub_defaults
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 7 restore_rambox
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 90 restore_sharing_profile
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 91 restore_boot_profile
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 92 restore_discovery_profile
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 93 restore_smartcard_profile
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 94 restore_complete_profile
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
mkdir -p "$tmp/lib" "$tmp/sshd_config.d"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-serv.sh" >"$tmp/restore-serv-partial.sh"
cat >>"$tmp/restore-serv-partial.sh" <<'EOF'
sudo() { "$@"; }
printf 'Include /etc/ssh/sshd_config.d/*.conf\nPidFile %s/sshd.pid\n' "$PWD" >sshd_config
printf 'PasswordAuthentication no\n' >sshd_config.d/10-bkp-smoke.conf
validate_sshd_config_file "$PWD/sshd_config" "$PWD/sshd_config.d"
cleanup_temp_paths
EOF
(cd "$tmp" && bash restore-serv-partial.sh)
rm -rf "$tmp"
printf 'restore-serv SSH drop-in validation OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/home/PreRestored"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-serv.sh" >"$tmp/restore-serv-partial.sh"
cat >>"$tmp/restore-serv-partial.sh" <<'EOF'
LOG_FILE="$PWD/audit.log"
CURRENT_ACTION="Restore grub theme"
RUN_RESULT="in_progress"
audit_log "action_started"
audit_log "action_completed"
sudo() { "$@"; }
confirm_yes_no() { return 0; }
timeshift() { printf 'snapshot\n' >>"$PWD/timeshift.calls"; }
SYSTEM_SNAPSHOT_STATE="pending"
ensure_pre_restore_system_snapshot
ensure_pre_restore_system_snapshot
[[ "$(wc -l <"$PWD/timeshift.calls")" -eq 1 ]]

SYSTEM_SNAPSHOT_STATE="skipped"
expected_failure() { return 23; }
run_menu_action "Expected failure" expected_failure
[[ "$ACTION_FAILURE_COUNT" -eq 1 ]]

mkdir -p "$PWD/theme-source" "$PWD/theme-target-parent"
printf 'theme fixture\n' >"$PWD/theme-source/theme.txt"
findmnt() { printf 'vfat\n'; }
restore_tree_to_system "$PWD/theme-source" "$PWD/theme-target-parent/theme"
grep -Fqx 'theme fixture' "$PWD/theme-target-parent/theme/theme.txt"
FSTAB_LINES=(
  '//new/share   /SMB/test   cifs   _netdev,credentials=/etc/samba/creds-test,uid=1000,gid=1000   0 0'
)
ROLLBACK_FILE="$PWD/restore-serv-rollback-test.sh"
snapshot_target "$PWD/new-service-target"
printf 'old service config\n' >"$PWD/existing-service-target"
snapshot_target "$PWD/existing-service-target"
prepend_rollback_commands "# oldest rollback fixture"
prepend_rollback_commands "# newest rollback fixture"
replace_managed_fstab_entries "$1"
update_rollback_snapshot_path "/etc/fstab-pre-restore-test" "$HOME/PreRestored/fstab-pre-restore-test"

ROLLBACK_FILE="$PWD/repeated-target-rollback.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  '# Rollback commands are stored newest-first.' >"$ROLLBACK_FILE"
printf 'original\n' >"$PWD/repeated-service-target"
snapshot_target "$PWD/repeated-service-target"
printf 'intermediate\n' >"$PWD/repeated-service-target"
snapshot_target "$PWD/repeated-service-target"
printf 'final\n' >"$PWD/repeated-service-target"
EOF
printf '%s\n' \
  '# test fstab' \
  'UUID=root / ext4 defaults 0 1' \
  '//old/share /SMB/test cifs old 0 0' \
  '//old/share /SMB/pneuma-win cifs old 0 0' \
  '//keep/share /SMB/keep cifs keep 0 0' >"$tmp/fstab"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  '# Generated rollback script for smoke test' \
  '# Rollback commands are stored newest-first.' \
  'sudo cp -a /etc/fstab-pre-restore-test /etc/fstab' >"$tmp/restore-serv-rollback-test.sh"
chmod +x "$tmp/restore-serv-rollback-test.sh"
(cd "$tmp" && HOME="$tmp/home" bash restore-serv-partial.sh "$tmp/fstab" >/dev/null)
cat >"$tmp/bin-sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$tmp/bin-sudo"
mkdir -p "$tmp/bin"
mv "$tmp/bin-sudo" "$tmp/bin/sudo"
(cd "$tmp" && HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash repeated-target-rollback.sh)
grep -Fq 'event=action_started action=Restore grub theme result=in_progress' "$tmp/audit.log"
grep -Fq 'event=action_completed action=Restore grub theme result=success' "$tmp/audit.log"
grep -Fq 'event=action_failed action=Expected failure result=failed' "$tmp/audit.log"
grep -Fq 'Expected failure failed (exit 23); returning to menu' "$tmp/audit.log"
grep -Fqx 'original' "$tmp/repeated-service-target"
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
grep -Fq "sudo rm -rf -- $tmp/new-service-target" "$tmp/restore-serv-rollback-test.sh"
newest_line="$(grep -nF '# newest rollback fixture' "$tmp/restore-serv-rollback-test.sh" | cut -d: -f1)"
oldest_line="$(grep -nF '# oldest rollback fixture' "$tmp/restore-serv-rollback-test.sh" | cut -d: -f1)"
[[ "$newest_line" -lt "$oldest_line" ]]
find "$tmp/home/PreRestored" -maxdepth 1 -type f -name 'existing-service-target-pre-restore-*' \
  -exec grep -Fqx 'old service config' '{}' \; -print -quit | grep -q .
if find "$tmp" -maxdepth 1 -name 'existing-service-target-pre-restore-*' -print -quit | grep -q .; then
  printf 'service snapshot was not moved immediately into PreRestored\n' >&2
  exit 1
fi
grep -Fq "$tmp/home/PreRestored/existing-service-target-pre-restore-" "$tmp/restore-serv-rollback-test.sh"
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
SSH_CONFIG_DROPINS_INCLUDED=false
SERVICE_REQUIRED_PATHS=(/etc/samba/smb.conf /etc/ssh/sshd_config)
SAMBA_CREDS_GLOB="/etc/samba/creds-*"
write_manifest
EOF
(cd "$tmp" && bash bkp-serv-partial.sh >/dev/null)
grep -Fq 'Backup Type = [SERVICE]' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'Archive Requested = [TRUE]' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'LUKS Header Created = [TRUE]' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'Required Service Paths = /etc/samba/smb.conf /etc/ssh/sshd_config' "$tmp/BKP/backup-manifest.txt"
grep -Fq 'SSH Config Drop-ins = [FALSE]' "$tmp/BKP/backup-manifest.txt"
if grep -Fq 'Optional Service Paths' "$tmp/BKP/backup-manifest.txt"; then
  printf 'service manifest should not contain removed optional path fields\n' >&2
  exit 1
fi
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
mkdir -p "$tmp/lib" "$tmp/logs" "$tmp/MAIN/BKP-test" "$tmp/SERV/BKP-test"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
printf 'private\n' >"$tmp/MAIN/BKP-test/private.txt"
printf 'private\n' >"$tmp/SERV/BKP-test/private.txt"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-main.sh" >"$tmp/bkp-main-partial.sh"
cat >>"$tmp/bkp-main-partial.sh" <<'EOF'
MAIN_DIR="$PWD/MAIN"
RUN_ID="BKP-test"
ARCHIVE_NAME="$MAIN_DIR/$RUN_ID.tar.gz"
BACKUP_DIR="$MAIN_DIR/$RUN_ID"
set_backup_status() { :; }
create_validated_archive
[[ "$(stat -c %a "$ARCHIVE_NAME")" == "600" ]]
EOF
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-serv.sh" >"$tmp/bkp-serv-partial.sh"
cat >>"$tmp/bkp-serv-partial.sh" <<'EOF'
SERV_DIR="$PWD/SERV"
RUN_ID="BKP-test"
ARCHIVE_NAME="$SERV_DIR/$RUN_ID.tar.gz"
BACKUP_DIR="$SERV_DIR/$RUN_ID"
sudo() { "$@"; }
set_backup_status() { :; }
create_validated_archive
[[ "$(stat -c %a "$ARCHIVE_NAME")" == "600" ]]
EOF
(cd "$tmp" && bash bkp-main-partial.sh >/dev/null && bash bkp-serv-partial.sh >/dev/null)
rm -rf "$tmp"
printf 'private archive permissions OK\n'

bash -c 'source "$1"; [[ "$(timestamp)" =~ ^[0-9]{4}-[0-9]{3}- ]]' _ "$PROJECT_ROOT/lib/common.sh"
printf 'year-safe timestamp OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/backups/BKP-365-old" "$tmp/backups/BKP-001-new"
touch -d '2025-12-31' "$tmp/backups/BKP-365-old"
touch -d '2026-01-01' "$tmp/backups/BKP-001-new"
awk '/^printf '\''BKP doctor/ { exit } { print }' "$PROJECT_ROOT/doctor.sh" >"$tmp/doctor-partial.sh"
cat >>"$tmp/doctor-partial.sh" <<'EOF'
[[ "$(latest_backup_dir "$1")" == "$1/BKP-001-new" ]]
EOF
bash "$tmp/doctor-partial.sh" "$tmp/backups"
rm -rf "$tmp"
printf 'cross-year latest backup selection OK\n'

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
mkdir -p "$tmp/SERV/BKP-legacy/protected"
printf 'protected fixture\n' >"$tmp/SERV/BKP-legacy/protected/data"
chmod 000 "$tmp/SERV/BKP-legacy/protected"
"$PROJECT_ROOT/catalog.sh" "$tmp" >"$tmp/catalog.out"
grep -Fq 'MAIN' "$tmp/catalog.out"
grep -Fq 'BKP-test' "$tmp/catalog.out"
grep -Fq 'COMPLETED' "$tmp/catalog.out"
grep -Fq 'PASSED' "$tmp/catalog.out"
grep -Fq 'BKP-legacy' "$tmp/catalog.out"
grep -Fq '2025-01-02T03:04:05+00:00' "$tmp/catalog.out"
chmod 700 "$tmp/SERV/BKP-legacy/protected"
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
  LOG_FILE="$PWD/task.log"
  ui_add_task "failure" "Expected failure"
  if ui_run_command "failure" "testing failure" bash -c "exit 7" >/dev/null; then
    exit 1
  else
    rc=$?
  fi
  [[ "$rc" -eq 7 ]]
  [[ "${UI_TASK_STATUS[failure]}" == "ERROR" ]]
  grep -Fq "Task Expected failure failed (exit 7)" "$LOG_FILE"
  [[ "$(grep -Fc "[ERROR]" "$LOG_FILE")" -eq 1 ]]

  UI_ENABLED=false
  if ui_run_command "failure" "testing hidden failure" bash -c "exit 9"; then
    exit 1
  else
    rc=$?
  fi
  [[ "$rc" -eq 9 ]]
')

set +e
(cd "$tmp" && bash -c '
  source common.sh
  UI_ENABLED=false
  LOG_FILE="$PWD/trapped-task.log"
  trap '\''ui_report_error "$LINENO" "$BASH_COMMAND"'\'' ERR
  ui_add_task "failure" "Trapped failure"
  ui_run_command "failure" "testing trapped failure" bash -c "exit 11"
') >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 11 ]]
grep -Fq "Task Trapped failure failed (exit 11)" "$tmp/trapped-task.log"
if grep -Fq "command failed at line" "$tmp/trapped-task.log"; then
  exit 1
fi

(cd "$tmp" && bash -c '
  source common.sh
  register_temp_path "$PWD/already-missing"
  cleanup_temp_paths
')
rm -rf "$tmp"
printf 'dashboard command failure propagation OK\n'

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
