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
mkdir -p "$tmp/lib" "$tmp/ARGUS" "$tmp/bin" "$tmp/standalone/ARGUS"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
cp "$PROJECT_ROOT"/ARGUS/*.sh "$tmp/ARGUS/"
cp "$PROJECT_ROOT"/ARGUS/restore-*.sh "$tmp/standalone/ARGUS/"
cp "$PROJECT_ROOT"/{bkp-main,bkp-serv,restore-main,restore-serv}.sh "$tmp/"
cp "$PROJECT_ROOT"/{restore-main,restore-serv}.sh "$tmp/standalone/"
cat >"$tmp/ARGUS/argus-main.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ARGUS MAIN HANDOFF\n'
exit 17
EOF
cat >"$tmp/bin/hostnamectl" <<'EOF'
#!/usr/bin/env bash
printf 'argus\n'
EOF
chmod +x "$tmp/bin/hostnamectl"
for script in bkp-main.sh bkp-serv.sh restore-main.sh restore-serv.sh; do
  case "$script" in
  bkp-main.sh) expected='ARGUS MAIN HANDOFF' ;;
  restore-main.sh) expected='ARGUS MAIN' ;;
  bkp-serv.sh | restore-serv.sh) expected='ARGUS SERVICE' ;;
  esac
  if PATH="$tmp/bin:$PATH" "$tmp/$script" >"$tmp/dispatch.out" 2>&1; then
    printf '%s should dispatch to its ARGUS script\n' "$script" >&2
    exit 1
  fi
  grep -Fq "$expected" "$tmp/dispatch.out"
done
for script in restore-main.sh restore-serv.sh; do
  if PATH="$tmp/bin:$PATH" "$tmp/standalone/$script" >"$tmp/dispatch.out" 2>&1; then
    printf 'standalone %s should dispatch to its ARGUS placeholder\n' "$script" >&2
    exit 1
  fi
  grep -Fq 'not implemented yet' "$tmp/dispatch.out"
done
[[ ! -e "$tmp/logs/bkp.log" && ! -e "$tmp/restore.log" ]]
rm -rf "$tmp"
printf 'ARGUS hostname dispatch OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/project/ARGUS" "$tmp/project/lib" "$tmp/home/Documents" "$tmp/home/.config" "$tmp/device"
cp "$PROJECT_ROOT/ARGUS/argus-main.sh" "$tmp/project/ARGUS/argus-main.sh"
cp "$PROJECT_ROOT/ARGUS/restore-main.sh" "$tmp/project/ARGUS/restore-main.sh"
cp "$PROJECT_ROOT/ARGUS/main.backup.conf" "$tmp/project/ARGUS/main.backup.conf"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/project/lib/common.sh"
cat >>"$tmp/project/lib/common.sh" <<'EOF'
select_external_mount() { printf '%s\n' "$ARGUS_TEST_DEVICE"; }
EOF
printf 'document\n' >"$tmp/home/Documents/example.txt"
printf 'kde setting\n' >"$tmp/home/.config/kde.conf"
printf 'shell setting\n' >"$tmp/home/.bashrc"
printf 'N\n\n' | HOME="$tmp/home" ARGUS_TEST_DEVICE="$tmp/device" \
  "$tmp/project/ARGUS/argus-main.sh" --quiet >"$tmp/argus-main.out"
argus_backup="$(find "$tmp/device/011-ARGUS/MAIN" -mindepth 1 -maxdepth 1 -type d -name 'BKP-*' -print -quit)"
[[ -n "$argus_backup" ]]
[[ -f "$argus_backup/Documents/example.txt" && -f "$argus_backup/.config/kde.conf" ]]
[[ -f "$argus_backup/.bashrc" && -f "$argus_backup/config/main.backup.conf" ]]
[[ ! -e "$argus_backup/DOTS" ]]
grep -Fq 'Backup Status = [COMPLETED]' "$argus_backup/backup-manifest.txt"
rm -rf "$tmp"
printf 'ARGUS MAIN backup layout OK\n'

tmp="$(mktemp -d)"
cp "$PROJECT_ROOT/restore-main.sh" "$tmp/restore-main.sh"
chmod +x "$tmp/restore-main.sh"
if printf 'N\n' | (cd "$tmp" && ./restore-main.sh >/dev/null 2>&1); then
  printf 'restore-main.sh should reject an unmarked source folder\n' >&2
  exit 1
fi
grep -Fq '[ERROR] [restore-main.sh]' "$tmp/err.log"
if grep -Eq '\[(INFO|WARN)\]' "$tmp/err.log"; then
  printf 'standalone restore err.log should contain errors only\n' >&2
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
cp "$PROJECT_ROOT/restore-main.sh" "$tmp/restore-main.sh"
printf 'backup_status=complete\n' >"$tmp/backup-manifest.txt"
printf 'complete\n' >"$tmp/backup.status"
if printf 'N\n' | (cd "$tmp" && ./restore-main.sh >/dev/null 2>&1); then
  printf 'pre-0.4 status markers should not authorize restore-main.sh\n' >&2
  exit 1
fi
rm -rf "$tmp"
printf 'pre-0.4 backup status rejected OK: restore-main.sh\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/backup/Documents" "$tmp/home/Documents"
cp "$PROJECT_ROOT/restore-main.sh" "$tmp/backup/restore-main.sh"
chmod +x "$tmp/backup/restore-main.sh"
cat >"$tmp/backup/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [COMPLETED]
EOF
printf 'new\n' >"$tmp/backup/Documents/new.txt"
mkdir -p "$tmp/backup/ARGUS"
printf 'helper\n' >"$tmp/backup/ARGUS/restore-main.sh"
printf 'old error\n' >"$tmp/backup/err.log"
printf 'rotated error\n' >"$tmp/backup/err.log.1"
printf 'old\n' >"$tmp/home/Documents/old.txt"
printf 'Y\n' | (cd "$tmp/backup" && HOME="$tmp/home" ./restore-main.sh >"$tmp/restore-main.out")
[[ -f "$tmp/home/Documents/new.txt" ]]
[[ ! -e "$tmp/home/ARGUS" && ! -e "$tmp/home/err.log" && ! -e "$tmp/home/err.log.1" ]]
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
mkdir -p "$tmp/backup" "$tmp/home" "$tmp/bin"
cp "$PROJECT_ROOT/restore-main.sh" "$tmp/backup/restore-main.sh"
chmod +x "$tmp/backup/restore-main.sh"
cat >"$tmp/backup/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [COMPLETED]
EOF
printf 'restore data\n' >"$tmp/backup/restore-item"
cat >"$tmp/bin/rsync" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
chmod +x "$tmp/bin/rsync"
if printf 'Y\n' | HOME="$tmp/home" PATH="$tmp/bin:$PATH" "$tmp/backup/restore-main.sh" >/dev/null 2>&1; then
  printf 'restore-main.sh should fail when rsync fails\n' >&2
  exit 1
fi
grep -Fq '[ERROR] [restore-main.sh] command failed at line' "$tmp/backup/err.log"
rm -rf "$tmp"
printf 'restore command failure error log OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/device/MAIN/BKP-test/config" "$tmp/device/015-LATERALUS" "$tmp/home/.local/share/applications"
cp "$PROJECT_ROOT/restore-main.sh" "$tmp/device/MAIN/BKP-test/restore-main.sh"
cp "$PROJECT_ROOT/config/main.backup.conf" "$tmp/device/MAIN/BKP-test/config/main.backup.conf"
chmod +x "$tmp/device/MAIN/BKP-test/restore-main.sh"
cat >"$tmp/device/MAIN/BKP-test/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [COMPLETED]
EOF
printf 'new desktop entry\n' >"$tmp/device/015-LATERALUS/cc.arduino.IDE2.desktop"
printf 'old desktop entry\n' >"$tmp/home/.local/share/applications/cc.arduino.IDE2.desktop"
printf 'Y\n' | HOME="$tmp/home" "$tmp/device/MAIN/BKP-test/restore-main.sh" >/dev/null
grep -Fqx 'new desktop entry' "$tmp/home/.local/share/applications/cc.arduino.IDE2.desktop"
find "$tmp/home/PreRestored" -maxdepth 1 -type f -name 'cc.arduino.IDE2.desktop-pre-restore-*' \
  -exec grep -Fqx 'old desktop entry' '{}' \; -print -quit | grep -q .
rm -rf "$tmp"
printf 'shared Arduino desktop entry restore OK: restore-main.sh\n'

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

# Exercise ordered menu batches through the real prompt and action confirmations.
tmp="$(mktemp -d)"
mkdir -p "$tmp/BKP/DOTS/fastfetch" "$tmp/BKP/DOTS/kitty" "$tmp/home"
cp "$PROJECT_ROOT/restore-dots.sh" "$tmp/BKP/DOTS/restore-dots.sh"
cat >"$tmp/BKP/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [COMPLETED]
EOF
printf 'fastfetch fixture\n' >"$tmp/BKP/DOTS/fastfetch/test.conf"
printf 'kitty fixture\n' >"$tmp/BKP/DOTS/kitty/test.conf"
printf '18,17 0 21\ny\ny\n' | HOME="$tmp/home" bash "$tmp/BKP/DOTS/restore-dots.sh" >"$tmp/ordered.out"
[[ -f "$tmp/home/.mydotfiles/com.ml4w.dotfiles.stable/.config/fastfetch/test.conf" ]]
[[ -f "$tmp/home/.mydotfiles/com.ml4w.dotfiles.stable/.config/kitty/test.conf" ]]
awk '/Done: Restore FastFetch/ { first = 1 } /Done: Restore KITTY/ { second = first; exit } END { exit(second ? 0 : 1) }' "$tmp/ordered.out"
if grep -Fq 'Skipping WAYBAR' "$tmp/ordered.out"; then
  printf 'DOTS batch should stop when option 0 is reached\n' >&2
  exit 1
fi
mkdir -p "$tmp/cancel-home"
printf '18 17\nn\ny\n0\n' | HOME="$tmp/cancel-home" bash "$tmp/BKP/DOTS/restore-dots.sh" >"$tmp/cancel.out"
[[ ! -e "$tmp/cancel-home/.mydotfiles/com.ml4w.dotfiles.stable/.config/fastfetch" ]]
[[ -f "$tmp/cancel-home/.mydotfiles/com.ml4w.dotfiles.stable/.config/kitty/test.conf" ]]
mkdir -p "$tmp/invalid-home"
printf '\n17 invalid\n0\n' | HOME="$tmp/invalid-home" bash "$tmp/BKP/DOTS/restore-dots.sh" >"$tmp/invalid.out"
grep -Fq 'Invalid selection: invalid' "$tmp/invalid.out"
[[ ! -e "$tmp/invalid-home/.mydotfiles" ]]
rm -rf "$tmp"
printf 'DOTS ordered menu batches, cancellation, and validation OK\n'

# Exercise group expansion through the real menu with harmless action handlers.
tmp="$(mktemp -d)"
mkdir -p "$tmp/BKP/DOTS" "$tmp/home"
cat >"$tmp/BKP/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [COMPLETED]
EOF
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-dots.sh" >"$tmp/BKP/DOTS/restore-dots.sh"
for action in install_hypr_conf connect_wifi install_fonts install_dots set_autologin change_shell \
  install_extra restore_wallpapers restore_shell_rc restore_kitty restore_fastfetch restore_hypr \
  restore_rofi restore_waybar restore_matugen restore_cava restore_swaync restore_wlogout \
  restore_qs restore_walker collect_pre_restore restore_settings; do
  # The generated handler expands the trace path when it runs.
  # shellcheck disable=SC2016
  printf '%s() { printf "%%s\\n" "%s" >>"$DOTS_ACTION_TRACE"; }\n' "$action" "$action" >>"$tmp/BKP/DOTS/restore-dots.sh"
done
awk '/^parse_common_args / { main = 1 } main { print }' "$PROJECT_ROOT/restore-dots.sh" >>"$tmp/BKP/DOTS/restore-dots.sh"
cat >"$tmp/BKP/restore-main.sh" <<'EOF'
#!/usr/bin/env bash
printf 'restore_main\n' >>"$DOTS_ACTION_TRACE"
printf '%s\n' "$PWD" >"$PWD/main-cwd"
printf '%s\n' "$@" >"$PWD/main-args"
[[ ! -f "$PWD/main-fail" ]]
EOF
run_dots_group_test() {
  local input="$1" expected="$2"
  : >"$tmp/actions"
  printf '%s\n0\n' "$input" | HOME="$tmp/home" DOTS_ACTION_TRACE="$tmp/actions" \
    bash "$tmp/BKP/DOTS/restore-dots.sh" >"$tmp/group.out"
  [[ "$(cat "$tmp/actions")" == "$expected" ]] || {
    printf 'Unexpected DOTS group dispatch for: %s\n' "$input" >&2
    return 1
  }
}
p1_expected=$'install_hypr_conf\nconnect_wifi\ninstall_fonts\ninstall_dots\nset_autologin\nchange_shell'
p3_expected=$'restore_wallpapers\nrestore_shell_rc\nrestore_kitty\nrestore_fastfetch\nrestore_hypr\nrestore_rofi\nrestore_waybar\nrestore_matugen\nrestore_cava\nrestore_swaync\nrestore_wlogout\nrestore_qs\nrestore_walker'
run_dots_group_test P1 "$p1_expected"
run_dots_group_test P2 install_extra
run_dots_group_test P3 "$p3_expected"
run_dots_group_test 'p2,17 P1 98 99' "$(printf 'install_extra\nrestore_kitty\n%s\ncollect_pre_restore\nrestore_settings' "$p1_expected")"
run_dots_group_test 'P3,P2,P1' "$(printf '%s\ninstall_extra\n%s' "$p3_expected" "$p1_expected")"
run_dots_group_test 'P1 P4' ''
grep -Fq 'Invalid selection: P4' "$tmp/group.out"
run_dots_group_test '0 P1 P2 P3 90 98 99' ''
run_dots_group_test '90 99' $'restore_main\nrestore_settings'
[[ "$(cat "$tmp/BKP/main-cwd")" == "$tmp/BKP" ]]
[[ ! -s "$tmp/BKP/main-args" || "$(cat "$tmp/BKP/main-args")" == '' ]]
printf '90 0\n' | HOME="$tmp/home" DOTS_ACTION_TRACE="$tmp/actions" \
  bash "$tmp/BKP/DOTS/restore-dots.sh" --quiet >"$tmp/quiet-main.out"
grep -Fxq -- '--quiet' "$tmp/BKP/main-args"
touch "$tmp/BKP/main-fail"
run_dots_group_test '90 99' $'restore_main\nrestore_settings'
grep -Fq 'Restore MAIN failed' "$tmp/group.out"
mv "$tmp/BKP/restore-main.sh" "$tmp/BKP/restore-main-unavailable.sh"
run_dots_group_test '90 99' restore_settings
grep -Fq 'MAIN restore script not found or unreadable' "$tmp/group.out"
rm -rf "$tmp"
printf 'DOTS group order, mixed selections, validation, and standalone 98/99 OK\n'
printf 'DOTS MAIN restore launch, quiet forwarding, failure, and missing script OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/device/MAIN/BKP-test/DOTS" "$tmp/device/STATIC/fonts" \
  "$tmp/home" "$tmp/bin"
cp "$PROJECT_ROOT/restore-dots.sh" "$tmp/device/MAIN/BKP-test/DOTS/restore-dots.sh"
cat >"$tmp/device/MAIN/BKP-test/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Backup Status = [COMPLETED]
EOF
cat >"$tmp/device/STATIC/fonts/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'device\n' >"$FONT_TEST_MARKER"
EOF
cat >"$tmp/bin/fc-cache" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/fc-cache"
printf 'font data\n' >"$tmp/device/STATIC/Steelfish Outline.ttf"
printf '3\nY\n0\n' | HOME="$tmp/home" FONT_TEST_MARKER="$tmp/installer-used" PATH="$tmp/bin:$PATH" \
  bash "$tmp/device/MAIN/BKP-test/DOTS/restore-dots.sh" >/dev/null
grep -Fqx 'device' "$tmp/installer-used"
grep -Fqx 'font data' "$tmp/home/.local/share/fonts/Steelfish Outline.ttf"

mkdir -p "$tmp/device/MAIN/BKP-test/DOTS/STATIC/fonts"
mv "$tmp/device/STATIC/fonts/install.sh" "$tmp/device/MAIN/BKP-test/DOTS/STATIC/fonts/install.sh"
sed -i 's/device/local/' "$tmp/device/MAIN/BKP-test/DOTS/STATIC/fonts/install.sh"
printf 'local font data\n' >"$tmp/device/MAIN/BKP-test/DOTS/STATIC/Steelfish Outline.ttf"
printf '3\nY\n0\n' | HOME="$tmp/home" FONT_TEST_MARKER="$tmp/installer-used" PATH="$tmp/bin:$PATH" \
  bash "$tmp/device/MAIN/BKP-test/DOTS/restore-dots.sh" >/dev/null
grep -Fqx 'local' "$tmp/installer-used"
grep -Fqx 'local font data' "$tmp/home/.local/share/fonts/Steelfish Outline.ttf"
rm -rf "$tmp"
printf 'STATIC fonts installer device and local lookup OK\n'

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
printf '4\nY\nN\n0\n' | (
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

tmp="$(mktemp -d)"
mkdir -p "$tmp/bin" "$tmp/lib"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-dots.sh" >"$tmp/restore-dots-partial.sh"
cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SUDO_TEST_LOG"
EOF
chmod +x "$tmp/bin/sudo"
cat >>"$tmp/restore-dots-partial.sh" <<'EOF'
SUDO_KEEPALIVE_INTERVAL_SECONDS=0.05
start_sudo_keepalive
sleep 0.15
keepalive_pid="$SUDO_KEEPALIVE_PID"
kill -0 "$keepalive_pid"
stop_sudo_keepalive
[[ -z "$SUDO_KEEPALIVE_PID" ]]
if kill -0 "$keepalive_pid" 2>/dev/null; then
  printf 'sudo keepalive process should stop after the action\n' >&2
  exit 1
fi
EOF
if ((EUID != 0)); then
  SUDO_TEST_LOG="$tmp/sudo.log" PATH="$tmp/bin:$PATH" bash "$tmp/restore-dots-partial.sh"
  [[ "$(grep -Fxc -- '-v' "$tmp/sudo.log")" -eq 1 ]]
  grep -Fqx -- '-n -v' "$tmp/sudo.log"
fi
rm -rf "$tmp"
printf 'sudo action keepalive OK: restore-dots.sh\n'

# Exercise Firefox removal without invoking the host package manager.
tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/config"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
cp "$PROJECT_ROOT/config/dots-extra.conf" "$tmp/config/dots-extra.conf"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-dots.sh" >"$tmp/restore-dots-partial.sh"
cat >>"$tmp/restore-dots-partial.sh" <<'EOF'
start_sudo_keepalive() { return 0; }
stop_sudo_keepalive() { printf 'stopped\n' >"$PWD/sudo-stopped"; }
ensure_yay_installed() { return 0; }
yay() { return 1; }
sudo() { "$@"; }
flatpak() { return 0; }
ensure_micronucleus_udev_rules() { return 0; }
install_qt_color_themes() { return 0; }
install_hyprmod() { printf 'hyprmod\n' >"$PWD/hyprmod-called"; }
pacman() {
  case "$*" in
  '-Q firefox') [[ "$FIREFOX_TEST_STATE" != absent ]] ;;
  '-R --noconfirm firefox')
    printf 'remove firefox\n' >>"$PWD/package-removals"
    [[ "$FIREFOX_TEST_STATE" != failure ]]
    ;;
  '-Q vlc') return 1 ;;
  '-Q '*) return 0 ;;
  *) return 1 ;;
  esac
}
if install_extra; then
  [[ "$FIREFOX_TEST_STATE" != failure ]]
  [[ -f "$PWD/hyprmod-called" ]]
  grep -Fqx 'Install Extra = [COMPLETED]' "$INSTALL_EXTRA_LOG"
else
  [[ "$FIREFOX_TEST_STATE" == failure ]]
  [[ ! -e "$PWD/hyprmod-called" ]]
  grep -Fqx 'Install Extra = [FAILED]' "$INSTALL_EXTRA_LOG"
  grep -Fq 'Remove Firefox package (exit 1)' "$INSTALL_EXTRA_LOG"
fi
[[ -f "$PWD/sudo-stopped" ]]
if [[ "$FIREFOX_TEST_STATE" == absent ]]; then
  [[ ! -e "$PWD/package-removals" ]]
else
  grep -Fqx 'remove firefox' "$PWD/package-removals"
fi
EOF
for firefox_test_state in installed absent failure; do
  rm -f "$tmp/package-removals" "$tmp/hyprmod-called" "$tmp/sudo-stopped"
  (cd "$tmp" && FIREFOX_TEST_STATE="$firefox_test_state" bash restore-dots-partial.sh >/dev/null)
done
rm -rf "$tmp"
printf 'Install Extra Firefox removal, absence, and failure handling OK\n'

# Verify installed items never reach an installer, including HyprMod.
tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/config" "$tmp/ml4w/ml4w/scripts" "$tmp/device/STATIC" "$tmp/home"
printf 'Dracula color theme fixture\n' >"$tmp/device/STATIC/Dracula.conf"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
cat >"$tmp/config/dots-extra.conf" <<'EOF'
EXTRA_PACKAGES=(brave-bin qrencode dracula-gtk-theme)
EXTRA_FLATPAKS=(org.gnome.Calculator org.videolan.VLC)
REMOVE_REPOSITORY_VLC=false
EOF
cat >"$tmp/ml4w/ml4w/scripts/ml4w-install-hyprmod" <<'EOF'
printf 'hyprmod\n' >>"$EXTRA_INSTALL_TRACE"
EOF
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-dots.sh" >"$tmp/restore-dots-partial.sh"
cat >>"$tmp/restore-dots-partial.sh" <<'EOF'
ML4W_CONFIG_ROOT="$PWD/ml4w"
resolve_backup_device_root() { printf '%s\n' "$PWD/device"; }
start_sudo_keepalive() { return 0; }
stop_sudo_keepalive() { :; }
ensure_yay_installed() { return 0; }
sudo() { return 1; }
command() {
  if [[ "$*" == '-v hyprmod' ]]; then
    [[ "$EXTRA_TEST_STATE" == installed ]]
  else
    builtin command "$@"
  fi
}
pacman() {
  case "$*" in
  '-Q brave-bin' | '-Q dracula-gtk-theme') return 0 ;;
  '-Q qrencode') [[ "$EXTRA_TEST_STATE" == installed || -f "$PWD/qrencode-installed" ]] ;;
  *) return 1 ;;
  esac
}
yay() {
  [[ "$*" == '-S --needed --noconfirm -- qrencode' ]] || return 1
  printf 'qrencode\n' >>"$EXTRA_INSTALL_TRACE"
  touch "$PWD/qrencode-installed"
}
flatpak() {
  case "$*" in
  'info org.gnome.Calculator') return 0 ;;
  'info org.videolan.VLC') [[ "$EXTRA_TEST_STATE" == installed || -f "$PWD/vlc-installed" ]] ;;
  'install --noninteractive -y org.videolan.VLC')
    printf 'org.videolan.VLC\n' >>"$EXTRA_INSTALL_TRACE"
    touch "$PWD/vlc-installed"
    ;;
  *) return 1 ;;
  esac
}
install_extra
grep -Fqx 'Install Extra = [COMPLETED]' "$INSTALL_EXTRA_LOG"
EOF
: >"$tmp/install-trace"
(cd "$tmp" && HOME="$tmp/home" EXTRA_TEST_STATE=installed EXTRA_INSTALL_TRACE="$tmp/install-trace" bash restore-dots-partial.sh >/dev/null)
[[ ! -s "$tmp/install-trace" ]]
cmp "$tmp/device/STATIC/Dracula.conf" "$tmp/home/.config/qt6ct/colors/Dracula.conf"
cmp "$tmp/device/STATIC/Dracula.conf" "$tmp/home/.config/qt5ct/colors/Dracula.conf"
printf 'old Qt6 colors\n' >"$tmp/home/.config/qt6ct/colors/Dracula.conf"
printf 'old Qt5 colors\n' >"$tmp/home/.config/qt5ct/colors/Dracula.conf"
# Already installed HyprMod must also skip successfully without its installer file.
mv "$tmp/ml4w/ml4w/scripts/ml4w-install-hyprmod" "$tmp/hyprmod-installer"
(cd "$tmp" && HOME="$tmp/home" EXTRA_TEST_STATE=installed EXTRA_INSTALL_TRACE="$tmp/install-trace" bash restore-dots-partial.sh >/dev/null)
[[ ! -s "$tmp/install-trace" ]]
cmp "$tmp/device/STATIC/Dracula.conf" "$tmp/home/.config/qt6ct/colors/Dracula.conf"
cmp "$tmp/device/STATIC/Dracula.conf" "$tmp/home/.config/qt5ct/colors/Dracula.conf"
for toolkit in Qt5 Qt6; do
  find "$tmp/home/PreRestored" -maxdepth 1 -type f -name 'Dracula.conf-pre-restore-*' \
    -exec grep -Fqx "old $toolkit colors" '{}' \; -print -quit | grep -q .
done
mv "$tmp/hyprmod-installer" "$tmp/ml4w/ml4w/scripts/ml4w-install-hyprmod"
(cd "$tmp" && HOME="$tmp/home" EXTRA_TEST_STATE=mixed EXTRA_INSTALL_TRACE="$tmp/install-trace" bash restore-dots-partial.sh >/dev/null)
[[ "$(cat "$tmp/install-trace")" == $'qrencode\norg.videolan.VLC\nhyprmod' ]]
mv "$tmp/device/STATIC/Dracula.conf" "$tmp/device/STATIC/Dracula-unavailable.conf"
if (cd "$tmp" && HOME="$tmp/home" EXTRA_TEST_STATE=installed EXTRA_INSTALL_TRACE="$tmp/install-trace" bash restore-dots-partial.sh >/dev/null); then
  printf 'Install Extra should report a missing Qt color theme as a failure\n' >&2
  exit 1
fi
grep -Fqx 'Install Extra = [FAILED]' "$tmp/install-extra.log"
cmp "$tmp/device/STATIC/Dracula-unavailable.conf" "$tmp/home/.config/qt6ct/colors/Dracula.conf"
cmp "$tmp/device/STATIC/Dracula-unavailable.conf" "$tmp/home/.config/qt5ct/colors/Dracula.conf"
rm -rf "$tmp"
printf 'Install Extra skips installed items and installs only missing packages, Flatpaks, and HyprMod OK\n'
printf 'Install Extra Qt color theme copies, snapshots, and missing source failure OK\n'

grep -Fq 'RSYNC_RESTORE_ARGS=(-aAXH --numeric-ids)' "$PROJECT_ROOT/restore-dots.sh"
if grep -Fq "tee -a \"\$INSTALL_EXTRA_BODY\"" "$PROJECT_ROOT/restore-dots.sh"; then
  printf 'Install Extra command output should stay in its log instead of flooding the terminal\n' >&2
  exit 1
fi
grep -Fq '99 - Restore Settings' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '3 - Install FONTS' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '4 - Install DOTS' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '10 - Install Extra' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq -- '- AUR: Jefferson, Brave, Yubico, hashId, pyUbi,' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq -- '-- Rambox, QRencode, sRec, Minipro, Tabby, HyprMod' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq -- '- FlatPak: VLC, Calc, ArduinoIDE' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq -- '-- Keybinds, NVIDIA, Monitor, Window Rules,' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq -- '-- GTK 3/4, QT6, xSettings, qBittorrent, Thunar TERM, miniPro' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq -- '-- ML4W: Filemanager, Kitty cursor, ROFI (border, radius, font),' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq -- '-- Screenshot, Terminal, Waybar (quicklink, workspace)' "$PROJECT_ROOT/restore-dots.sh"
if grep -Fq '5 - Install HyprMod' "$PROJECT_ROOT/restore-dots.sh"; then
  printf 'Install HyprMod should only be available through Install Extra\n' >&2
  exit 1
fi
grep -Fq '5 - Set AutoLogin' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '6 - Change shell to ZSH' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '15 - Restore Wallpapers' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '16 - Restore ZSHRC, BASHRC' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '19 - Restore HYPR' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '22 - Restore MATUGEN' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_folder "MATUGEN" "matugen/templates" "matugen/templates"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '23 - Restore CAVA' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '24 - Restore SWAYNC' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '25 - Restore WLOGOUT' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '26 - Restore QS' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '27 - Restore WALKER' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '2 - Connect WiFi' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'brave-bin' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fxq '  dracula-gtk-theme' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fxq '  dracula-cursors-git' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fxq '  tela-circle-icon-theme-dracula' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'jefferson-git' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'yubico-authenticator-bin' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'python-ubi-reader-git' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'rambox-pro-bin' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'tabby-bin' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'qrencode' "$PROJECT_ROOT/config/dots-extra.conf"
if grep -Fq 'python-pywalfox' "$PROJECT_ROOT/config/dots-extra.conf"; then
  printf 'Install Extra should not install Pywalfox\n' >&2
  exit 1
fi
grep -Fq 'srec-git' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'minipro-git' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'org.videolan.VLC' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'org.gnome.Calculator' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'cc.arduino.IDE2' "$PROJECT_ROOT/config/dots-extra.conf"
grep -Fq 'sudo pacman -R --noconfirm vlc' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'ensure_yay_installed' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'start_sudo_keepalive' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'sudo -n -v' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'https://raw.githubusercontent.com/micronucleus/micronucleus/master/commandline/49-micronucleus.rules' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '/etc/udev/rules.d/49-micronucleus.rules' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "sudo install -m 0644 \"\$rules_temp\" \"\$MICRONUCLEUS_RULES_TARGET\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'sudo udevadm control --reload-rules' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'sudo udevadm trigger' "$PROJECT_ROOT/restore-dots.sh"
if grep -Fq 'https://dl.brave.com/install.sh' "$PROJECT_ROOT/restore-dots.sh"; then
  printf 'Install Extra should install brave-bin with the AUR package batch\n' >&2
  exit 1
fi
awk '
  /^install_extra\(\)/ { in_func = 1 }
  in_func && /yay -S --needed --noconfirm/ { package_install_seen = 1 }
  in_func && /flatpak install --noninteractive -y/ {
    if (!package_install_seen) exit 1
    flatpak_install_seen = 1
  }
  in_func && /flatpak info "\$VLC_FLATPAK_ID"/ {
    if (!flatpak_install_seen) exit 1
    vlc_verify_seen = 1
  }
  in_func && /sudo pacman -R --noconfirm vlc/ {
    if (!vlc_verify_seen) exit 1
    vlc_remove_seen = 1
  }
  in_func && /ensure_micronucleus_udev_rules/ {
    if (!flatpak_install_seen) exit 1
    rules_seen = 1
  }
  in_func && /install_hyprmod/ {
    if (!vlc_remove_seen || !rules_seen) exit 1
    hyprmod_seen = 1
  }
  in_func && /^}/ {
    exit(package_install_seen && flatpak_install_seen && vlc_verify_seen && vlc_remove_seen && rules_seen && hyprmod_seen ? 0 : 1)
  }
' "$PROJECT_ROOT/restore-dots.sh" || {
  printf 'Install Extra phase order is incorrect\n' >&2
  exit 1
}
awk '
  /^install_extra\(\)/ { in_func = 1 }
  in_func && /ensure_yay_installed/ { yay_check_seen = 1 }
  in_func && /install_hyprmod/ {
    hyprmod_seen = 1
    if (!yay_check_seen) {
      exit 1
    }
  }
  in_func && /^}/ { exit(yay_check_seen && hyprmod_seen ? 0 : 1) }
' "$PROJECT_ROOT/restore-dots.sh" || {
  printf 'Install Extra must ensure yay is installed before packages and HyprMod\n' >&2
  exit 1
}
sed -n '/^install_hyprmod()/,/^}/p' "$PROJECT_ROOT/restore-dots.sh" |
  grep -Fq "run_extra_command \"Install HyprMod\" bash \"\$installer\""
grep -Fq 'sudo pacman -S --needed --noconfirm base-devel git' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'https://aur.archlinux.org/yay.git' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "makepkg -si --needed --noconfirm" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "flatpak install --noninteractive -y \"\$app\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "yay -S --needed --noconfirm -- \"\${missing_packages[@]}\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "Verify Extra package: \$pkg" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "Verify Extra Flatpak: \$app" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '98 - Collect pre-restore' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'uca.xml' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'dracula.qbtheme' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '015-LATERALUS/algorithm.xml' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '015-LATERALUS/60-minipro.rules' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "MINIPRO_ALGORITHM_TARGET=\"\${MINIPRO_ALGORITHM_TARGET:-/usr/share/minipro/algorithm.xml}\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "MINIPRO_UDEV_RULE_TARGET=\"\${MINIPRO_UDEV_RULE_TARGET:-/etc/udev/rules.d/60-minipro.rules}\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "sudo install -m 0644 \"\$algorithm_source\" \"\$MINIPRO_ALGORITHM_TARGET\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "sudo install -m 0644 \"\$rule_source\" \"\$MINIPRO_UDEV_RULE_TARGET\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '99)' "$PROJECT_ROOT/restore-dots.sh"
tmp="$(mktemp -d)"
mkdir -p "$tmp/lib"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-dots.sh" >"$tmp/restore-dots-partial.sh"
cat >>"$tmp/restore-dots-partial.sh" <<'EOF'
confirm_action "Restore HYPR" <<<''
if confirm_action "Restore HYPR" <<<'N'; then
  exit 1
fi
if confirm_action "Install DOTS" <<<''; then
  exit 1
fi
EOF
(cd "$tmp" && bash restore-dots-partial.sh >/dev/null)
rm -rf "$tmp"
printf 'DOTS confirmation defaults OK\n'
grep -Fq 'ml4w-change-shell' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq '015-LATERALUS/wallpapers' "$PROJECT_ROOT/restore-dots.sh"
if sed -n '/^restore_hypr()/,/^}/p' "$PROJECT_ROOT/restore-dots.sh" | grep -Eq 'gtk-3.0/bookmarks|waybar/modules.json|quickshell|qs (kill|-d)'; then
  printf 'Restore HYPR should not restore Settings, Waybar, or Quickshell content\n' >&2
  exit 1
fi
grep -Fq 'restore_config_file "Settings" "gtk-3.0/bookmarks" "gtk-3.0/bookmarks"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_file "Settings" "xsettingsd/xsettingsd.conf" "xsettingsd/xsettingsd.conf"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_path "QS" "quickshell" "quickshell"' "$PROJECT_ROOT/restore-dots.sh"
if grep -Eq 'customize_quickshell|qs kill|qs -d' "$PROJECT_ROOT/restore-dots.sh"; then
  printf 'Restore QS should only restore the complete quickshell folder\n' >&2
  exit 1
fi
grep -Fq 'restore_config_folder "WAYBAR" "waybar/scripts" "waybar/scripts"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_file "WAYBAR" "waybar/modules.json" "waybar/modules.json"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_folder "ZSHRC" "zshrc" "zshrc"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_folder "BASHRC" "bashrc" "bashrc"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "local link_path=\"\$HOME/.config/cava\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq "ln -s -- \"\$target_dir\" \"\$link_path\"" "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_path "SWAYNC" "swaync" "swaync"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_path "WLOGOUT" "wlogout" "wlogout"' "$PROJECT_ROOT/restore-dots.sh"
grep -Fq 'restore_config_path "WALKER" "walker" "walker"' "$PROJECT_ROOT/restore-dots.sh"
if grep -Fq 'customize_wlogout_glass_style' "$PROJECT_ROOT/restore-dots.sh"; then
  printf 'retired wlogout style customization should not remain\n' >&2
  exit 1
fi
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 3 install_fonts
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 4 install_dots
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 5 set_autologin
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 10 install_extra
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 6 change_shell
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 15 restore_wallpapers
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 16 restore_shell_rc
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 17 restore_kitty
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 18 restore_fastfetch
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 19 restore_hypr
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 20 restore_rofi
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 21 restore_waybar
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 22 restore_matugen
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 23 restore_cava
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 24 restore_swaync
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 25 restore_wlogout
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 26 restore_qs
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 27 restore_walker
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 2 connect_wifi
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 1 install_hypr_conf
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 90 restore_main
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 98 collect_pre_restore
assert_dispatch "$PROJECT_ROOT/restore-dots.sh" 99 restore_settings
printf 'restore-dots settings menu OK\n'

tmp="$(mktemp -d)"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-dots.sh" >"$tmp/restore-dots-partial.sh"
cat >>"$tmp/restore-dots-partial.sh" <<'EOF'
confirm_action() { :; }
nmcli() {
  printf '%s|' "$@" >>"$NMCLI_TEST_LOG"
  printf '\n' >>"$NMCLI_TEST_LOG"
  case "$*" in
  '-t -f DEVICE,TYPE device status') printf 'wlan0:wifi\n' ;;
  '-t -f SSID device wifi list ifname wlan0 --rescan yes') printf 'Other\nFeedMe-6+\n' ;;
  'connection show FeedMe-6+') [[ -e "$NMCLI_TEST_PROFILE" ]] ;;
  'connection add '*) touch "$NMCLI_TEST_PROFILE" ;;
  'connection modify '* | '--ask connection up '*) : ;;
  *) return 1 ;;
  esac
}
connect_wifi
connect_wifi
EOF
NMCLI_TEST_LOG="$tmp/nmcli.log" NMCLI_TEST_PROFILE="$tmp/profile" HOME="$tmp" \
  bash "$tmp/restore-dots-partial.sh" >/dev/null
grep -Fq -- 'connection|add|type|wifi|ifname|wlan0|con-name|FeedMe-6+|ssid|FeedMe-6+|autoconnect|yes|--|802-11-wireless.mode|infrastructure|802-11-wireless.mac-address||802-11-wireless.cloned-mac-address||802-11-wireless.mtu|0|802-11-wireless-security.key-mgmt|wpa-psk|802-11-wireless-security.psk-flags|0|ipv4.method|manual|ipv4.addresses|192.168.8.15/24|ipv4.gateway|192.168.8.1|ipv4.dns|192.168.8.1|ipv6.method|disabled|proxy.method|none|' "$tmp/nmcli.log"
grep -Fq -- 'connection|modify|FeedMe-6+|connection.interface-name|wlan0|connection.autoconnect|yes|802-11-wireless.ssid|FeedMe-6+|802-11-wireless.mode|infrastructure|802-11-wireless.mac-address||802-11-wireless.cloned-mac-address||802-11-wireless.mtu|0|802-11-wireless-security.key-mgmt|wpa-psk|802-11-wireless-security.psk-flags|0|ipv4.method|manual|ipv4.addresses|192.168.8.15/24|ipv4.gateway|192.168.8.1|ipv4.dns|192.168.8.1|ipv6.method|disabled|proxy.method|none|' "$tmp/nmcli.log"
grep -Fq -- '--ask|connection|up|FeedMe-6+|ifname|wlan0|' "$tmp/nmcli.log"
rm -rf "$tmp"
printf 'Connect WiFi profile and activation OK\n'

tmp="$(mktemp -d)"
dots_dir="$tmp/device/MAIN/BKP-test/DOTS"
mkdir -p \
  "$dots_dir/lib" \
  "$dots_dir/hypr/conf/keybindings" \
  "$dots_dir/hypr/conf/environments" \
  "$dots_dir/hypr/conf/windowrules" \
  "$dots_dir/hypr/scripts" \
  "$dots_dir/waybar/themes/RALEX" \
  "$dots_dir/waybar/scripts" \
  "$dots_dir/quickshell/overview" \
  "$dots_dir/walker" \
  "$dots_dir/zshrc" \
  "$dots_dir/bashrc" \
  "$dots_dir/btop" \
  "$dots_dir/gtk-3.0" \
  "$dots_dir/gtk-4.0" \
  "$dots_dir/qt6ct" \
  "$dots_dir/xsettingsd" \
  "$dots_dir/ml4w/settings" \
  "$tmp/device/015-LATERALUS" \
  "$tmp/device/STATIC/dracula-pro-pro/assets" \
  "$tmp/device/STATIC/gtksourceview-5/styles" \
  "$tmp/home"
cp "$PROJECT_ROOT/lib/common.sh" "$dots_dir/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-dots.sh" >"$dots_dir/restore-dots-partial.sh"
for source_rel in \
  hypr/conf/keybindings/default.lua \
  hypr/conf/environments/nvidia.lua \
  hypr/conf/monitor.lua \
  hypr/conf/windowrules/default.lua \
  hypr/hypridle.conf \
  hypr/hyprlock.conf \
  hypr/hyprland-gui.lua \
  hypr/logo-2.png \
  hypr/scripts/uptime.sh \
  waybar/modules.json \
  btop/btop.conf \
  gtk-3.0/bookmarks \
  gtk-3.0/settings.ini \
  gtk-4.0/settings.ini \
  qt6ct/qt6ct.conf \
  xsettingsd/xsettingsd.conf \
  ml4w/settings/browser.sh \
  ml4w/settings/editor.sh \
  ml4w/settings/filemanager \
  ml4w/settings/kitty-cursor-trail.conf \
  ml4w/settings/rofi-border-radius.rasi \
  ml4w/settings/rofi-border.rasi \
  ml4w/settings/rofi-font.rasi \
  ml4w/settings/rofi_bordersize.sh \
  ml4w/settings/screenshot-editor \
  ml4w/settings/screenshot-folder \
  ml4w/settings/statusbar \
  ml4w/settings/terminal.sh \
  ml4w/settings/waybar-theme.sh \
  ml4w/settings/waybar-quicklinks.json \
  ml4w/settings/waybar_quicklinks.sh \
  ml4w/settings/waybar_workspaces.sh; do
  printf 'fixture: %s\n' "$source_rel" >"$dots_dir/$source_rel"
done
printf 'theme fixture\n' >"$dots_dir/waybar/themes/RALEX/theme.css"
printf 'other source theme\n' >"$dots_dir/waybar/themes/other.css"
printf 'script fixture\n' >"$dots_dir/waybar/scripts/test.sh"
printf 'walker fixture\n' >"$dots_dir/walker/config.toml"
printf 'zshrc fixture\n' >"$dots_dir/zshrc/config"
printf 'bashrc fixture\n' >"$dots_dir/bashrc/config"
cat >"$dots_dir/quickshell/overview/config.json" <<'EOF'
{
  "main": "Fira Sans Semibold",
  "title": "Fira Sans Semibold",
  "expressive": "Fira Sans Semibold"
}
EOF
printf 'theme fixture\n' >"$tmp/device/015-LATERALUS/dracula.qbtheme"
printf 'qt5 theme fixture\n' >"$tmp/device/STATIC/Dracula.conf"
printf 'brave theme fixture\n' >"$tmp/device/STATIC/dracula-pro-pro/manifest.json"
printf 'brave asset fixture\n' >"$tmp/device/STATIC/dracula-pro-pro/assets/.theme"
printf 'gtksourceview fixture\n' >"$tmp/device/STATIC/gtksourceview-5/styles/dracula.xml"
printf 'hyprland config fixture\n' >"$tmp/device/STATIC/hyprland.lua"
printf 'new algorithm fixture\n' >"$tmp/device/015-LATERALUS/algorithm.xml"
printf 'new minipro rule fixture\n' >"$tmp/device/015-LATERALUS/60-minipro.rules"
cat >>"$dots_dir/restore-dots-partial.sh" <<'EOF'
ML4W_CONFIG_ROOT="$HOME/ml4w-config"
RESTORE_ID="functional-test"
confirm_action() { return 0; }
start_sudo_keepalive() { return 0; }
stop_sudo_keepalive() { :; }
sudo() { "$@"; }
udevadm() { printf '%s\n' "$*" >>"$PWD/udevadm.calls"; }
MINIPRO_ALGORITHM_TARGET="$PWD/system/usr/share/minipro/algorithm.xml"
MINIPRO_UDEV_RULE_TARGET="$PWD/system/etc/udev/rules.d/60-minipro.rules"

mkdir -p "$HOME/.config/hypr"
printf 'original hypr config\n' >"$HOME/original-hypr.lua"
ln -s "$HOME/original-hypr.lua" "$HOME/.config/hypr/hyprland.lua"
install_hypr_conf
[[ ! -L "$HOME/.config/hypr/hyprland.lua" ]]
grep -Fqx 'hyprland config fixture' "$HOME/.config/hypr/hyprland.lua"
grep -Fqx 'original hypr config' "$HOME/original-hypr.lua"
find "$HOME/.config/hypr" -maxdepth 1 -type l -name 'hyprland.lua-pre-starter-*' \
  -lname "$HOME/original-hypr.lua" -print -quit | grep -q .

mkdir -p "$ML4W_CONFIG_ROOT/zshrc" "$ML4W_CONFIG_ROOT/bashrc"
printf 'old zshrc fixture\n' >"$ML4W_CONFIG_ROOT/zshrc/config"
printf 'old bashrc fixture\n' >"$ML4W_CONFIG_ROOT/bashrc/config"
restore_shell_rc
grep -Fqx 'zshrc fixture' "$ML4W_CONFIG_ROOT/zshrc/config"
grep -Fqx 'bashrc fixture' "$ML4W_CONFIG_ROOT/bashrc/config"
find "$HOME/PreRestored" -maxdepth 1 -type d -name 'zshrc-pre-restore-*' \
  -exec grep -Fqx 'old zshrc fixture' '{}/config' \; -print -quit | grep -q .
find "$HOME/PreRestored" -maxdepth 1 -type d -name 'bashrc-pre-restore-*' \
  -exec grep -Fqx 'old bashrc fixture' '{}/config' \; -print -quit | grep -q .

mkdir -p "$ML4W_CONFIG_ROOT/hypr/conf/environments"
printf 'old nvidia fixture\n' >"$ML4W_CONFIG_ROOT/hypr/conf/environments/nvidia.lua"
restore_hypr
[[ -f "$ML4W_CONFIG_ROOT/hypr/conf/keybindings/default.lua" ]]
grep -Fqx 'fixture: hypr/conf/environments/nvidia.lua' "$ML4W_CONFIG_ROOT/hypr/conf/environments/nvidia.lua"
find "$HOME/PreRestored" -maxdepth 1 -type f -name 'nvidia.lua-pre-restore-*' \
  -exec grep -Fqx 'old nvidia fixture' '{}' \; -print -quit | grep -q .
[[ ! -e "$ML4W_CONFIG_ROOT/waybar/modules.json" ]]
[[ ! -e "$ML4W_CONFIG_ROOT/quickshell" ]]

mkdir -p "$ML4W_CONFIG_ROOT/waybar/themes/RALEX"
mkdir -p "$ML4W_CONFIG_ROOT/ml4w/settings"
printf 'old waybar theme setting\n' >"$ML4W_CONFIG_ROOT/ml4w/settings/waybar-theme.sh"
printf 'old RALEX theme\n' >"$ML4W_CONFIG_ROOT/waybar/themes/RALEX/old.css"
printf 'keep local theme\n' >"$ML4W_CONFIG_ROOT/waybar/themes/local.css"
restore_waybar
[[ -f "$ML4W_CONFIG_ROOT/waybar/modules.json" ]]
cmp "$SCRIPT_DIR/ml4w/settings/waybar-theme.sh" "$ML4W_CONFIG_ROOT/ml4w/settings/waybar-theme.sh"
find "$HOME/PreRestored" -maxdepth 1 -type f -name 'waybar-theme.sh-pre-restore-*' \
  -exec grep -Fqx 'old waybar theme setting' '{}' \; -print -quit | grep -q .
grep -Fqx 'theme fixture' "$ML4W_CONFIG_ROOT/waybar/themes/RALEX/theme.css"
[[ ! -e "$ML4W_CONFIG_ROOT/waybar/themes/RALEX/old.css" ]]
grep -Fqx 'keep local theme' "$ML4W_CONFIG_ROOT/waybar/themes/local.css"
[[ ! -e "$ML4W_CONFIG_ROOT/waybar/themes/other.css" ]]
find "$HOME/PreRestored" -maxdepth 1 -type d -name 'RALEX-pre-restore-*' \
  -exec grep -Fqx 'old RALEX theme' '{}/old.css' \; -print -quit | grep -q .
[[ -f "$ML4W_CONFIG_ROOT/waybar/scripts/test.sh" ]]

# Missing WAYBAR sources must leave their targets untouched and allow other items to restore.
(
  mv "$SCRIPT_DIR/ml4w/settings/waybar-theme.sh" "$SCRIPT_DIR/ml4w/settings/waybar-theme-unavailable.sh"
  printf 'keep installed theme setting\n' >"$ML4W_CONFIG_ROOT/ml4w/settings/waybar-theme.sh"
  mv "$SCRIPT_DIR/waybar/scripts" "$SCRIPT_DIR/waybar/scripts-unavailable"
  printf 'keep installed script\n' >"$ML4W_CONFIG_ROOT/waybar/scripts/test.sh"
  printf 'restore available modules\n' >"$SCRIPT_DIR/waybar/modules.json"
  restore_waybar
  grep -Fqx 'keep installed theme setting' "$ML4W_CONFIG_ROOT/ml4w/settings/waybar-theme.sh"
  grep -Fqx 'restore available modules' "$ML4W_CONFIG_ROOT/waybar/modules.json"
  grep -Fqx 'keep installed script' "$ML4W_CONFIG_ROOT/waybar/scripts/test.sh"

  mv "$SCRIPT_DIR/waybar/modules.json" "$SCRIPT_DIR/waybar/modules-unavailable.json"
  mv "$SCRIPT_DIR/waybar/themes/RALEX" "$SCRIPT_DIR/waybar/themes/RALEX-unavailable"
  restore_waybar
  grep -Fqx 'restore available modules' "$ML4W_CONFIG_ROOT/waybar/modules.json"
  grep -Fqx 'theme fixture' "$ML4W_CONFIG_ROOT/waybar/themes/RALEX/theme.css"

  mv "$SCRIPT_DIR/waybar/scripts-unavailable" "$SCRIPT_DIR/waybar/scripts"
  restore_waybar
  grep -Fqx 'script fixture' "$ML4W_CONFIG_ROOT/waybar/scripts/test.sh"
)

mkdir -p "$ML4W_CONFIG_ROOT/quickshell"
printf 'old quickshell fixture\n' >"$ML4W_CONFIG_ROOT/quickshell/old.conf"
restore_qs
grep -Fq '"main": "Fira Sans Semibold"' "$ML4W_CONFIG_ROOT/quickshell/overview/config.json"
[[ ! -e "$ML4W_CONFIG_ROOT/quickshell/old.conf" ]]
find "$HOME/PreRestored" -maxdepth 1 -type d -name 'quickshell-pre-restore-*' \
  -exec grep -Fqx 'old quickshell fixture' '{}/old.conf' \; -print -quit | grep -q .

mkdir -p "$ML4W_CONFIG_ROOT/walker"
printf 'old walker fixture\n' >"$ML4W_CONFIG_ROOT/walker/config.toml"
restore_walker
grep -Fqx 'walker fixture' "$ML4W_CONFIG_ROOT/walker/config.toml"
find "$HOME/PreRestored" -maxdepth 1 -type d -name 'walker-pre-restore-*' \
  -exec grep -Fqx 'old walker fixture' '{}/config.toml' \; -print -quit | grep -q .

mkdir -p "$(dirname -- "$MINIPRO_ALGORITHM_TARGET")" "$(dirname -- "$MINIPRO_UDEV_RULE_TARGET")"
printf 'old algorithm fixture\n' >"$MINIPRO_ALGORITHM_TARGET"
printf 'old minipro rule fixture\n' >"$MINIPRO_UDEV_RULE_TARGET"
mkdir -p "$ML4W_CONFIG_ROOT/btop"
printf 'old btop config\n' >"$ML4W_CONFIG_ROOT/btop/btop.conf"
mkdir -p "$HOME/.config/qt5ct/colors"
printf 'old qt5 theme\n' >"$HOME/.config/qt5ct/colors/Dracula.conf"
mkdir -p "$HOME/.config/BraveSoftware/dracula-pro-pro"
printf 'old brave theme\n' >"$HOME/.config/BraveSoftware/dracula-pro-pro/old.json"
mkdir -p "$HOME/.local/share/gtksourceview-5"
printf 'old gtksourceview fixture\n' >"$HOME/.local/share/gtksourceview-5/old.xml"
mkdir -p "$ML4W_CONFIG_ROOT/ml4w/settings"
for settings_file in browser.sh editor.sh statusbar; do
  printf 'old setting: %s\n' "$settings_file" >"$ML4W_CONFIG_ROOT/ml4w/settings/$settings_file"
done
restore_settings
grep -Fqx 'gtksourceview fixture' "$HOME/.local/share/gtksourceview-5/styles/dracula.xml"
[[ ! -e "$HOME/.local/share/gtksourceview-5/old.xml" ]]
find "$HOME/PreRestored" -maxdepth 1 -type d -name 'gtksourceview-5-pre-restore-*' \
  -exec grep -Fqx 'old gtksourceview fixture' '{}/old.xml' \; -print -quit | grep -q .
grep -Fqx 'brave theme fixture' "$HOME/.config/BraveSoftware/dracula-pro-pro/manifest.json"
grep -Fqx 'brave asset fixture' "$HOME/.config/BraveSoftware/dracula-pro-pro/assets/.theme"
[[ ! -e "$HOME/.config/BraveSoftware/dracula-pro-pro/old.json" ]]
find "$HOME/PreRestored" -maxdepth 1 -type d -name 'dracula-pro-pro-pre-restore-*' \
  -exec grep -Fqx 'old brave theme' '{}/old.json' \; -print -quit | grep -q .
grep -Fqx 'qt5 theme fixture' "$HOME/.config/qt5ct/colors/Dracula.conf"
find "$HOME/PreRestored" -maxdepth 1 -type f -name 'Dracula.conf-pre-restore-*' \
  -exec grep -Fqx 'old qt5 theme' '{}' \; -print -quit | grep -q .
grep -Fqx 'fixture: btop/btop.conf' "$ML4W_CONFIG_ROOT/btop/btop.conf"
find "$HOME/PreRestored" -maxdepth 1 -type f -name 'btop.conf-pre-restore-*' \
  -exec grep -Fqx 'old btop config' '{}' \; -print -quit | grep -q .
for settings_file in browser.sh editor.sh statusbar; do
  grep -Fqx "fixture: ml4w/settings/$settings_file" "$ML4W_CONFIG_ROOT/ml4w/settings/$settings_file"
  find "$HOME/PreRestored" -maxdepth 1 -type f -name "$settings_file-pre-restore-*" \
    -exec grep -Fqx "old setting: $settings_file" '{}' \; -print -quit | grep -q .
done
[[ -f "$ML4W_CONFIG_ROOT/gtk-3.0/bookmarks" ]]
[[ -f "$ML4W_CONFIG_ROOT/xsettingsd/xsettingsd.conf" ]]
grep -Fqx 'new algorithm fixture' "$MINIPRO_ALGORITHM_TARGET"
grep -Fqx 'new minipro rule fixture' "$MINIPRO_UDEV_RULE_TARGET"
[[ "$(stat -c %a "$MINIPRO_ALGORITHM_TARGET")" == "644" ]]
[[ "$(stat -c %a "$MINIPRO_UDEV_RULE_TARGET")" == "644" ]]
find "$HOME/PreRestored" -maxdepth 1 -type f -name 'algorithm.xml-pre-restore-*' \
  -exec grep -Fqx 'old algorithm fixture' '{}' \; -print -quit | grep -q .
find "$HOME/PreRestored" -maxdepth 1 -type f -name '60-minipro.rules-pre-restore-*' \
  -exec grep -Fqx 'old minipro rule fixture' '{}' \; -print -quit | grep -q .
grep -Fqx 'control --reload-rules' "$PWD/udevadm.calls"
grep -Fqx 'trigger' "$PWD/udevadm.calls"
EOF
(cd "$dots_dir" && HOME="$tmp/home" bash restore-dots-partial.sh >/dev/null)
rm -rf "$tmp"
printf 'restore-dots split action behavior OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/backup/config/local" "$tmp/project/config/local"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-serv.sh" >"$tmp/backup/restore-serv-partial.sh"
cat >>"$tmp/backup/restore-serv-partial.sh" <<'EOF'
[[ "$GRUB_GFXMODE_VALUE" == "$EXPECTED_GFXMODE" ]]
EOF
printf 'GRUB_GFXMODE_VALUE=bundled-public\n' >"$tmp/backup/config/serv.restore.conf"
printf 'GRUB_GFXMODE_VALUE=bundled-local\n' >"$tmp/backup/config/local/serv.restore.conf"
printf 'GRUB_GFXMODE_VALUE=project-public\n' >"$tmp/project/config/serv.restore.conf"
printf 'GRUB_GFXMODE_VALUE=project-local\n' >"$tmp/project/config/local/serv.restore.conf"
PROJECT_ROOT="$tmp/project" EXPECTED_GFXMODE=bundled-local \
  bash "$tmp/backup/restore-serv-partial.sh"
rm "$tmp/backup/config/local/serv.restore.conf"
PROJECT_ROOT="$tmp/project" EXPECTED_GFXMODE=bundled-public \
  bash "$tmp/backup/restore-serv-partial.sh"
rm "$tmp/backup/config/serv.restore.conf"
PROJECT_ROOT="$tmp/project" EXPECTED_GFXMODE=project-local \
  bash "$tmp/backup/restore-serv-partial.sh"
rm -rf "$tmp"
printf 'bundled SERVICE restore config precedence OK\n'

grep -Fq '1 - Create SMB' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '5 - Restore grub theme' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq 'GRUB_THEME_SHARED_RELATIVE="015-LATERALUS/lateralus"' "$PROJECT_ROOT/restore-serv.sh"
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
grep -Fq '7 - Restore Plymouth' "$PROJECT_ROOT/restore-serv.sh"
grep -Fq '98 - Collect pre-restore' "$PROJECT_ROOT/restore-serv.sh"
for host_dir in /SMB/020-EUCLID /SMB/010-PNEUMA /SMB/011-ARGUS /SMB/015-LATERALUS; do
  grep -Fq "\"$host_dir\"" "$PROJECT_ROOT/restore-serv.sh"
  grep -Fq "\"$host_dir\"" "$PROJECT_ROOT/config/serv.restore.conf"
done
grep -Fq '"/SMB/SCP"' "$PROJECT_ROOT/config/serv.restore.conf"
grep -Fq 'SAMBA_CREDS_PATTERN="creds-*"' "$PROJECT_ROOT/config/serv.backup.conf"
for retired_smb_path in /SMB/argus-smb /SMB/pneuma-kali /SMB/pneuma-smb /SMB/pneuma-win /SMB/euclid /SMB/pneuma /SMB/argus /SMB/lateralus; do
  grep -Fq "\"$retired_smb_path\"" "$PROJECT_ROOT/restore-serv.sh"
  if grep -Fq "\"$retired_smb_path\"" "$PROJECT_ROOT/config/serv.restore.conf"; then
    printf 'retired SMB directory should not be in public restore config: %s\n' "$retired_smb_path" >&2
    exit 1
  fi
done
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
for profile_action in restore_sharing_profile restore_ssh restore_boot_profile restore_plymouth restore_discovery_profile restore_smartcard_profile; do
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
assert_dispatch "$PROJECT_ROOT/restore-serv.sh" 7 restore_plymouth
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
installer="$tmp/device/015-LATERALUS/daedric-morrowind-plymouth/install.sh"
backup_dir="$tmp/device/015-LATERALUS/SERV/BKP-test"
mkdir -p "$(dirname -- "$installer")" "$backup_dir"
printf '#!/usr/bin/env bash\n' >"$installer"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/restore-serv.sh" >"$backup_dir/restore-serv-partial.sh"
cat >>"$backup_dir/restore-serv-partial.sh" <<'EOF'
sudo() {
  [[ "$1" == bash && "$2" == "$EXPECTED_INSTALLER" ]] || return 1
  printf 'called\n' >"$PLYMOUTH_TEST_MARKER"
}
restore_plymouth
EOF
EXPECTED_INSTALLER="$installer" PLYMOUTH_TEST_MARKER="$tmp/plymouth-called" \
  bash "$backup_dir/restore-serv-partial.sh" >/dev/null
grep -Fqx called "$tmp/plymouth-called"
rm -rf "$tmp"
printf 'shared Plymouth installer dispatch OK\n'

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
  '# TEST SHARE'
  '//new/share   /SMB/test   cifs   _netdev,credentials=/etc/samba/creds-test,uid=1000,gid=1000   0 0'
  ''
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
  '# TEST SHARE' \
  '//old/share /SMB/test cifs old 0 0' \
  '//old/share /SMB/argus-smb cifs old 0 0' \
  '//old/share /SMB/pneuma-kali cifs old 0 0' \
  '//old/share /SMB/pneuma-smb cifs old 0 0' \
  '//old/share /SMB/pneuma-win cifs old 0 0' \
  '//old/share /SMB/euclid cifs old 0 0' \
  '//old/share /SMB/pneuma cifs old 0 0' \
  '//old/share /SMB/argus cifs old 0 0' \
  '//old/share /SMB/lateralus cifs old 0 0' \
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
[[ "$(grep -Fxc '# TEST SHARE' "$tmp/fstab")" -eq 1 ]]
if grep -Fq '//old/share' "$tmp/fstab"; then
  printf 'stale managed fstab entry was not removed\n' >&2
  exit 1
fi
for retired_smb_path in /SMB/argus-smb /SMB/pneuma-kali /SMB/pneuma-smb /SMB/pneuma-win /SMB/euclid /SMB/pneuma /SMB/argus /SMB/lateralus; do
  if grep -Fq "$retired_smb_path" "$tmp/fstab"; then
    printf 'retired fstab entry was not removed: %s\n' "$retired_smb_path" >&2
    exit 1
  fi
done
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
mkdir -p "$tmp/lib" "$tmp/home/Documents" "$tmp/home/PreRestored" "$tmp/home/Projects" "$tmp/home/.hidden"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-main.sh" >"$tmp/bkp-main-partial.sh"
cat >>"$tmp/bkp-main-partial.sh" <<'EOF'
HOME="$PWD/home"
HIDDEN_HOME_ITEMS=(.ssh)
discover_home_items
[[ "${SKIPPABLE_HOME_ITEMS[*]}" == "Documents Projects" ]]
[[ "${HOME_ITEMS[*]}" == "Documents Projects .ssh" ]]
EOF
(cd "$tmp" && bash bkp-main-partial.sh)
rm -rf "$tmp"
printf 'PreRestored excluded from MAIN discovery OK\n'

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
printf '015-LATERALUS-only menu selection OK: bkp-main.sh\n'

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
LATERALUS_WALLPAPERS_DIR="$DEST_DEVICE/015-LATERALUS/wallpapers"
FIRMWARE_SOURCE="$HOME/Documents/030-Firmware"
LATERALUS_FIRMWARE_DIR="$DEST_DEVICE/015-LATERALUS/030-Firmware"
PATH="$PWD/bin:$PATH"
update_shared_firmware_and_wallpapers
EOF
(cd "$tmp" && bash bkp-main-partial.sh >update-lateralus.out)
grep -Fq '[INFO] Running 015-LATERALUS-only firmware and wallpapers update' "$tmp/update-lateralus.out"
grep -Fq '[INFO] Updating shared wallpapers: /wallpapers -> /netac/015-LATERALUS/wallpapers' "$tmp/update-lateralus.out"
grep -Fq '[INFO] Updating shared firmware: /Documents/030-Firmware -> /netac/015-LATERALUS/030-Firmware' "$tmp/update-lateralus.out"
grep -Fq '[INFO] Done: 015-LATERALUS-only firmware and wallpapers update' "$tmp/update-lateralus.out"
grep -Fq -- '- Updated Firmware and Wallpapers in /netac/015-LATERALUS' "$tmp/update-lateralus.out"
rm -rf "$tmp"
printf '015-LATERALUS-only update output OK: bkp-main.sh\n'

# Tabby copies are independent, refresh existing files, and tolerate missing sources.
tmp="$(mktemp -d)"
mkdir -p "$tmp/lib" "$tmp/logs" "$tmp/config" "$tmp/home/.config/tabby/plugins/example" "$tmp/device"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
cp "$PROJECT_ROOT/config/main.backup.conf" "$tmp/config/main.backup.conf"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-main.sh" >"$tmp/bkp-main-partial.sh"
cat >>"$tmp/bkp-main-partial.sh" <<'EOF'
HOME="$PWD/home"
DEST_DEVICE="$PWD/device"
load_main_backup_config
ui_add_task "main-tabby-plugins" "Backup Tabby plugins"
ui_add_task "main-tabby-config.yaml" "Backup Tabby config"
tabby_source="$HOME/.config/tabby"
tabby_destination="$DEST_DEVICE/STATIC/tabby"
printf 'plugin fixture\n' >"$tabby_source/plugins/example/.plugin"
printf 'initial config\n' >"$tabby_source/config.yaml"
printf 'unrelated file\n' >"$tabby_source/ignored.txt"
backup_tabby
cmp "$tabby_source/plugins/example/.plugin" "$tabby_destination/plugins/example/.plugin"
cmp "$tabby_source/config.yaml" "$tabby_destination/config.yaml"
[[ ! -e "$tabby_destination/ignored.txt" ]]
printf 'updated config fixture\n' >"$tabby_source/config.yaml"
printf 'updated plugin fixture\n' >"$tabby_source/plugins/example/.plugin"
printf 'keep destination file\n' >"$tabby_destination/plugins/keep.txt"
backup_tabby
cmp "$tabby_source/plugins/example/.plugin" "$tabby_destination/plugins/example/.plugin"
cmp "$tabby_source/config.yaml" "$tabby_destination/config.yaml"
[[ -f "$tabby_destination/plugins/keep.txt" ]]
mv "$tabby_source/plugins" "$PWD/saved-plugins"
printf 'config fixture with plugins source unavailable\n' >"$tabby_source/config.yaml"
backup_tabby
cmp "$tabby_source/config.yaml" "$tabby_destination/config.yaml"
mv "$tabby_source/config.yaml" "$PWD/saved-config.yaml"
mv "$PWD/saved-plugins" "$tabby_source/plugins"
backup_tabby
cmp "$PWD/saved-config.yaml" "$tabby_destination/config.yaml"
mv "$tabby_source" "$PWD/saved-tabby"
backup_tabby
[[ -f "$tabby_destination/plugins/example/.plugin" ]]
[[ -f "$tabby_destination/config.yaml" ]]
EOF
(cd "$tmp" && bash bkp-main-partial.sh >/dev/null)
rm -rf "$tmp"
printf 'backup-only Tabby STATIC copies and missing sources OK\n'

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
grep -Fq 'lateralus_update_info' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'update_shared_firmware_and_wallpapers' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq '90 - Update Firmware and Wallpapers' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'SKIPPABLE_HOME_ITEMS' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq "[[ -d \"\$DOTS_ROOT\" && -d \"\$DOTS_SOURCE\" ]]" "$PROJECT_ROOT/bkp-main.sh"
grep -Fq "Skipping missing dotfiles root: \$DOTS_ROOT" "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'LATERALUS_WALLPAPERS_RELATIVE="015-LATERALUS/wallpapers"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq 'FIRMWARE_HOME_RELATIVE="Documents/030-Firmware"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq 'LATERALUS_FIRMWARE_RELATIVE="015-LATERALUS/030-Firmware"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq 'LATERALUS_ARDUINO_DESKTOP_RELATIVE="015-LATERALUS/cc.arduino.IDE2.desktop"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq 'ARDUINO_DESKTOP_HOME_RELATIVE=".local/share/applications/cc.arduino.IDE2.desktop"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq 'LATERALUS_HOME_FILES_RELATIVE="015-LATERALUS"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq '".bash_history"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq '".zsh_history"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq '".zshrc"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq '".wget-hsts"' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq "run_rsync_main rsync_backup_copy \"\$source_path\" \"\$LATERALUS_HOME_FILES_DIR/\"" "$PROJECT_ROOT/bkp-main.sh"
grep -Fq -- "--ignore-existing" "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'DOCUMENTS_EXCLUDES=("030-Firmware/")' "$PROJECT_ROOT/config/main.backup.conf"
grep -Fq -- "--exclude='ml4w/wallpapers/'" "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'validate_tar_gz_archive' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq 'validate_tar_gz_archive' "$PROJECT_ROOT/bkp-serv.sh"
grep -Fq '.in-progress' "$PROJECT_ROOT/bkp-main.sh"
grep -Fq '.in-progress' "$PROJECT_ROOT/bkp-serv.sh"
grep -Fq 'restore_shared_firmware' "$PROJECT_ROOT/restore-main.sh"
grep -Fq 'restore_shared_arduino_desktop_entry' "$PROJECT_ROOT/restore-main.sh"
grep -Fq 'discover_restore_items' "$PROJECT_ROOT/restore-main.sh"
grep -Fq 'RESTORE_EXCLUDED_ITEMS' "$PROJECT_ROOT/restore-main.sh"
grep -Fq '"backup-manifest.json"' "$PROJECT_ROOT/restore-main.sh"
grep -Fq '"config"' "$PROJECT_ROOT/restore-main.sh"
grep -Fq '015-LATERALUS/030-Firmware' "$PROJECT_ROOT/restore-main.sh"
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
LATERALUS_WALLPAPERS_DIR="$DEST_DEVICE/015-LATERALUS/wallpapers"
FIRMWARE_SOURCE="/home/ralexander/Documents/030-Firmware"
LATERALUS_FIRMWARE_DIR="$DEST_DEVICE/015-LATERALUS/030-Firmware"
LATERALUS_HOME_FILES_DIR="$DEST_DEVICE/015-LATERALUS"
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
if grep -Fq 'Run Result' "$tmp/BKP/backup-manifest.txt" || grep -Fq '"run_result"' "$tmp/BKP/backup-manifest.json"; then
  printf 'new manifests should not contain duplicate run result fields\n' >&2
  exit 1
fi
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
mkdir -p "$tmp/lib"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/lib/common.sh"
awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/bkp-serv.sh" >"$tmp/bkp-serv-partial.sh"
cat >>"$tmp/bkp-serv-partial.sh" <<'EOF'
findmnt() { printf '/dev/mapper/root[/@]\n'; }
sudo() {
  case "$1 $2" in
  'cryptsetup isLuks') [[ "$3" == /dev/nvme0n1p2 || "$3" == /dev/sda1 ]] ;;
  'cryptsetup status')
    [[ "$3" == root ]] || return 1
    printf '  device:  /dev/nvme0n1p2\n'
    ;;
  *) return 1 ;;
  esac
}
[[ "$(detect_luks_device)" == /dev/nvme0n1p2 ]]
LUKS_DEVICE=/dev/sda1
[[ "$(detect_luks_device)" == /dev/sda1 ]]
EOF
(cd "$tmp" && bash bkp-serv-partial.sh)
rm -rf "$tmp"
printf 'Btrfs root LUKS detection and explicit source OK\n'

tmp="$(mktemp -d)"
cp "$PROJECT_ROOT/lib/common.sh" "$tmp/common.sh"
(cd "$tmp" && bash -c '
  source common.sh
  UI_ENABLED=false
  LOG_FILE="$PWD/test.log"
  log "plain info"
  log_warn "plain warning"
  [[ ! -e err.log ]]
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
[[ "$(wc -l <"$tmp/err.log")" -eq 1 ]]
grep -Fq '[ERROR] [common.sh] plain error' "$tmp/err.log"
rm -rf "$tmp"
printf 'clean CLI and error-only log output OK\n'

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
bash -c '
  source "$1"
  system_hostname() { printf "lateralus\n"; }
  [[ "$(backup_storage_root "$2")" == "$2/015-LATERALUS" ]]
  system_hostname() { printf "other-host\n"; }
  [[ "$(backup_storage_root "$2")" == "$2" ]]
' _ "$PROJECT_ROOT/lib/common.sh" "$tmp/device"
rm -rf "$tmp"
printf 'hostname-based backup layout OK\n'

tmp="$(mktemp -d)"
for script in restore-main.sh restore-serv.sh restore-dots.sh; do
  case "$script" in
  restore-main.sh)
    backup_type=MAIN
    suffix=""
    ;;
  restore-serv.sh)
    backup_type=SERV
    suffix=""
    ;;
  restore-dots.sh)
    backup_type=MAIN
    suffix="/DOTS"
    ;;
  esac
  for storage_root in "$tmp/device" "$tmp/device/015-LATERALUS"; do
    script_dir="$storage_root/$backup_type/BKP-test$suffix"
    mkdir -p "$script_dir"
    awk '/^parse_common_args / { exit } { print }' "$PROJECT_ROOT/$script" >"$script_dir/$script"
    printf '%s\n' 'resolve_backup_device_root' >>"$script_dir/$script"
    [[ "$(bash "$script_dir/$script")" == "$tmp/device" ]]
  done
done
rm -rf "$tmp"
printf 'legacy and nested restore device roots OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/backups/BKP-365-old" "$tmp/backups/BKP-001-new"
touch -d '2025-12-31' "$tmp/backups/BKP-365-old"
touch -d '2026-01-01' "$tmp/backups/BKP-001-new"
awk '/^printf '\''BKP doctor/ { exit } { print }' "$PROJECT_ROOT/doctor.sh" >"$tmp/doctor-partial.sh"
cat >>"$tmp/doctor-partial.sh" <<'EOF'
[[ "$(latest_backup_dir "$1")" == "$1/BKP-001-new" ]]
[[ "$(latest_backup_dir "$2/MAIN" "$2/015-LATERALUS/MAIN")" == "$2/015-LATERALUS/MAIN/BKP-new" ]]
[[ "$(latest_backup_dir "$2/missing/MAIN" "$2/015-LATERALUS/MAIN")" == "$2/015-LATERALUS/MAIN/BKP-new" ]]
EOF
mkdir -p "$tmp/legacy/MAIN/BKP-old" "$tmp/legacy/015-LATERALUS/MAIN/BKP-new"
touch -d '2025-01-01' "$tmp/legacy/MAIN/BKP-old"
touch -d '2026-01-01' "$tmp/legacy/015-LATERALUS/MAIN/BKP-new"
bash "$tmp/doctor-partial.sh" "$tmp/backups" "$tmp/legacy"
rm -rf "$tmp"
printf 'cross-year and nested latest backup selection OK\n'

tmp="$(mktemp -d)"
mkdir -p "$tmp/backup"
awk '/^printf '\''BKP doctor/ { exit } { print }' "$PROJECT_ROOT/doctor.sh" >"$tmp/doctor-partial.sh"
cat >"$tmp/backup/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [MAIN]
Created = 2026-11-17T12:00:00+01:00
Backup Status = [COMPLETED]
EOF
cat >"$tmp/backup/backup-manifest.json" <<'EOF'
{"manifest_version":1,"backup_type":"MAIN","created":"2026-11-17T12:00:00+01:00","backup_status":"COMPLETED"}
EOF
bash -c 'source "$1"; check_manifest_consistency "$2" MAIN; [[ "$EXIT_CODE" -eq 0 ]]' \
  _ "$tmp/doctor-partial.sh" "$tmp/backup" >/dev/null
sed -i 's/"backup_type":"MAIN"/"backup_type":"SERVICE"/' "$tmp/backup/backup-manifest.json"
bash -c 'source "$1"; check_manifest_consistency "$2" MAIN; [[ "$EXIT_CODE" -eq 1 ]]' \
  _ "$tmp/doctor-partial.sh" "$tmp/backup" >/dev/null
printf '{invalid json\n' >"$tmp/backup/backup-manifest.json"
bash -c 'source "$1"; check_manifest_consistency "$2" MAIN; [[ "$EXIT_CODE" -eq 1 ]]' \
  _ "$tmp/doctor-partial.sh" "$tmp/backup" >/dev/null
rm -rf "$tmp"
printf 'doctor text and JSON manifest validation OK\n'

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
mkdir -p "$tmp/MAIN/BKP-test" "$tmp/SERV/BKP-service" "$tmp/015-LATERALUS/MAIN/BKP-nested" "$tmp/015-LATERALUS/SERV/BKP-nested" "$tmp/011-ARGUS/MAIN/BKP-argus"
cat >"$tmp/MAIN/BKP-test/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Created = 2026-08-20T12:00:00+02:00
Backup Status = [COMPLETED]
Archive Validation = [PASSED]
EOF
touch "$tmp/MAIN/BKP-test.tar.gz"
cat >"$tmp/SERV/BKP-service/backup-manifest.txt" <<'EOF'
Manifest Version = 1
Backup Type = [SERVICE]
Created = 2025-01-02T03:04:05+00:00
Backup Status = [COMPLETED]
EOF
mkdir -p "$tmp/SERV/BKP-service/protected"
printf 'protected fixture\n' >"$tmp/SERV/BKP-service/protected/data"
chmod 000 "$tmp/SERV/BKP-service/protected"
"$PROJECT_ROOT/catalog.sh" "$tmp" >"$tmp/catalog.out"
grep -Fq 'MAIN' "$tmp/catalog.out"
grep -Fq 'BKP-test' "$tmp/catalog.out"
grep -Fq 'COMPLETED' "$tmp/catalog.out"
grep -Fq 'PASSED' "$tmp/catalog.out"
grep -Fq 'BKP-service' "$tmp/catalog.out"
grep -Fq 'BKP-argus' "$tmp/catalog.out"
[[ "$(grep -Fc 'BKP-nested' "$tmp/catalog.out")" -eq 2 ]]
grep -Fq '2025-01-02T03:04:05+00:00' "$tmp/catalog.out"
chmod 700 "$tmp/SERV/BKP-service/protected"
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
