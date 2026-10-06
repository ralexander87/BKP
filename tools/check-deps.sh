#!/usr/bin/env bash
set -Eeuo pipefail

# Commands required by core backup, catalog, and development checks.
required_commands=(
  awk
  bash
  chmod
  cryptsetup
  df
  dirname
  du
  find
  findmnt
  flock
  git
  grep
  install
  lsblk
  make
  mv
  numfmt
  pigz
  python3
  rsync
  sed
  shellcheck
  shfmt
  sort
  stat
  sudo
  systemctl
  tar
  truncate
)

# Commands needed only by specific restore menu actions.
optional_action_commands=(
  curl
  fc-cache
  flatpak
  grub-mkconfig
  makepkg
  pacman
  qs
  smbpasswd
  ssh-keygen
  sshd
  testparm
  timeshift
  yay
)

missing=0

printf 'Required commands\n'
for command_name in "${required_commands[@]}"; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '[OK] %s\n' "$command_name"
  else
    printf '[FAIL] %s\n' "$command_name"
    missing=1
  fi
done

printf '\nOptional action commands\n'
for command_name in "${optional_action_commands[@]}"; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '[OK] %s\n' "$command_name"
  else
    printf '[WARN] %s\n' "$command_name"
  fi
done

exit "$missing"
