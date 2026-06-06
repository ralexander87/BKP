# BKPv3

Bash scripts for backing up and restoring Linux user folders, service-related files, and dotfiles.

## Scripts

- `bkp-main.sh` / `restore-main.sh`: user folders, files, and dotfiles backup.
- `bkp-serv.sh` / `restore-serv.sh`: service/system config backup and restore.
- `restore-dots.sh`: dotfiles restore helper copied into backup `DOTS` folders.

## Requirements

- `bash`
- `rsync`
- `pigz` for optional archive compression
- `shellcheck` for script checks
- `shfmt` for formatting, optional

## Quick Start

Run the main backup:

```bash
./bkp-main.sh
```

The script lists external mounted devices with source device, filesystem, label, and free space. If one device is mounted, it is selected automatically. If multiple devices are mounted, select the destination by number.

Each main backup is written to:

```bash
/path/to/device/MAIN/BKP-<timestamp>
```

The backup folder contains the selected `$HOME` folders directly:

```text
BKP-<timestamp>/
  Downloads/
  Pictures/
  Documents/
  .ssh/
  DOTS/
  restore-main.sh
```

The timestamp format is:

```bash
date +%j-%d-%m-%H-%M-%S
```

Before copying files, `bkp-main.sh` asks whether to create a compressed `.tar.gz` archive after backup. The default answer is `N`; when you answer `Y`, compression uses `pigz`.

Before starting the backup, the script checks estimated source size against destination free space. If the destination appears too small, it warns and asks whether to continue.

Only one main backup can run at a time. A lock file in `logs/` prevents accidental overlapping runs.

Each backup includes `backup-manifest.txt` with timestamp, host, user, destination, archive choice, copied folder list, and git commit when available.

Terminal output is intentionally minimal. The scripts show top-level folder status, current-folder transfer progress, and errors instead of printing every copied file.

Restore the main backup from inside a backup folder:

```bash
cd /path/to/device/MAIN/BKP-<timestamp>
./restore-main.sh
```

Each backup includes a copy of `restore-main.sh`. It restores from its current folder back into `$HOME` after you confirm with `Y`.

Restore uses `rsync` metadata-preserving options for permissions, ownership, ACLs, and extended attributes.

Before restoring a folder into `$HOME`, `restore-main.sh` moves an existing target folder to `<name>-pre-restore-<timestamp>`.

After restoring `.ssh`, the script sets `.ssh` to `700`, `*.pub` files to `644`, and all other SSH files to `600`.

Service backup:

```bash
./bkp-serv.sh
```

`bkp-serv.sh` uses the mounted-device selector and writes backups to:

```bash
/path/to/device/SERV/BKP-<timestamp>
```

It requests root authentication at startup, then backs up:

- `/etc/samba/smb.conf`
- `/etc/samba/creds*`
- `/etc/ssh/sshd_config`
- `/boot/grub/themes/lateralus/`
- `/etc/default/grub`
- `/etc/mkinitcpio.conf`

Each service backup includes a copy of `restore-serv.sh` inside the backup folder and supports optional `.tar.gz` compression with `pigz`.

Service backup content is stored as standalone entries in the backup root (for example `smb.conf`, `sshd_config`, `lateralus/`, `grub`, `mkinitcpio.conf`, `creds-*`), not as full `/etc/...` or `/boot/...` directory trees.

Restore service backup from inside a `SERV/BKP-*` folder:

```bash
cd /path/to/device/SERV/BKP-<timestamp>
./restore-serv.sh
```

Current options:

- `0 - Exit`
- `1 - Restore grub theme`: restores `lateralus` to `/boot/grub/themes/`.
- `2 - Restore samba`: restores `smb.conf` and `creds-*` files to `/etc/samba/`.
- `3 - Restore SSH`: restores `sshd_config` to `/etc/ssh/`.

## Configuration

The current `bkp-main.sh` backs up these `$HOME` folders:

- `Downloads`
- `Pictures`
- `Videos`
- `Music`
- `Obsidian`
- `Code`
- `Documents`
- `.themes`
- `.icons`
- `.ssh`

`Downloads/*.iso` files are excluded. The `.ssh/agent` folder is excluded.

`bkp-main.sh` also copies `$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config` into `DOTS` and copies `restore-dots.sh` into that `DOTS` folder.

Run dotfiles restore actions from inside a backup `DOTS` folder:

```bash
cd /path/to/device/MAIN/BKP-<timestamp>/DOTS
./restore-dots.sh
```

Current options:

- `0 - Exit`
- `1 - Install DOTS`: moves `$HOME/.config/hypr` to a safety snapshot, then runs `bash <(curl -s https://ml4w.com/os/stable)`.
- `2 - Restore Wallpapers`: moves the existing wallpapers folder to a safety snapshot, then copies `ml4w/wallpapers` from the current `DOTS` folder.
- `3 - Restore FastFetch`: moves the existing FastFetch folder to a safety snapshot, then copies `fastfetch` from the current `DOTS` folder.
- `4 - Restore KITTY`: moves the existing KITTY folder to a safety snapshot, then copies `kitty` from the current `DOTS` folder.
- `5 - Restore ROFI`: moves the existing ROFI folder to a safety snapshot, then copies `rofi` from the current `DOTS` folder.
- `6 - Restore WAYBAR`: renames `$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/waybar/themes` to `themes-bkp`, then copies `waybar/themes` from the current `DOTS` folder.
- `7 - Restore HYPR`: copies `hypr/conf/keybindings/default.lua` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/conf/keybindings/`, copies `hypr/conf/monitor.lua` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/conf/`, copies `hypr/hypridle.conf`, `hypr/hyprlock.conf`, `hypr/logo-2.png` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/`, and copies `hypr/scripts/uptime.sh` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/scripts/`.

Each restore option asks for confirmation before changing local configuration.

The files in `config/` are reserved for the other script pairs while the project grows.

## Development

Check dependencies:

```bash
make deps
```

Run shell checks:

```bash
make check
```

`shellcheck` is required for `make check`. `shfmt` remains optional.

## Publishing

This repository is ready for local git tracking. When you decide to publish it on GitHub, add a remote:

```bash
git remote add origin git@github.com:YOUR_USER/BKPv3.git
git push -u origin main
```
