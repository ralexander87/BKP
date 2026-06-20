#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

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

printf 'smoke OK\n'
