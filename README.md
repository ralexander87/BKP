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

Use `--quiet` to hide INFO-level terminal output while still writing full logs:

```bash
./bkp-main.sh --quiet
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

Main archives are written beside the backup folder:

```bash
/path/to/device/MAIN/BKP-<timestamp>.tar.gz
```

Before backup starts, `bkp-main.sh` also offers a numbered skip list for `Documents`, `Downloads`, `Pictures`, `Music`, `Videos`, `Obsidian`, and `Code`. Enter one or more numbers separated by spaces or commas (for example `7 3` or `7,3`) to exclude those folders.

Before starting the backup, the script checks estimated source size against destination free space. If the destination appears too small, it warns and asks whether to continue.

Only one main backup can run at a time. A lock file in `logs/` prevents accidental overlapping runs.

Each backup includes `backup-manifest.txt` with timestamp, host, user, destination, archive choice, copied folder list, and git commit when available.

Each main backup also writes `backup.status`. New restores are blocked when this file exists and is not `complete`; older backups without this file still restore with a warning.

Terminal output is intentionally minimal. The scripts show top-level folder status, current-folder transfer progress, and errors instead of printing every copied file.

Restore the main backup from inside a backup folder:

```bash
cd /path/to/device/MAIN/BKP-<timestamp>
./restore-main.sh
```

`restore-main.sh` also supports `--quiet`.

Each backup includes a copy of `restore-main.sh`. It restores from its current folder back into `$HOME` after you confirm with `Y`.

Backups also include `lib/common.sh` beside copied restore scripts. The restore scripts have a small built-in fallback, so they can still start from older backup folders where `lib/common.sh` is missing.

Restore uses `rsync` metadata-preserving options for permissions, ownership, ACLs, and extended attributes.

Before restoring a folder into `$HOME`, `restore-main.sh` moves an existing target folder to `<name>-pre-restore-<timestamp>`.

After restoring `.ssh`, the script sets `.ssh` to `700`, `*.pub` files to `644`, and all other SSH files to `600`.

Service backup:

```bash
./bkp-serv.sh
```

`bkp-serv.sh` also supports `--quiet`.

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

Service archives are written beside the backup folder:

```bash
/path/to/device/SERV/BKP-<timestamp>.tar.gz
```

Service backup content is stored as standalone entries in the backup root (for example `smb.conf`, `sshd_config`, `lateralus/`, `grub`, `mkinitcpio.conf`, `creds-*`, `luks.bin`), not as full `/etc/...` or `/boot/...` directory trees.

Service backup fail-safes:

- preflight checks for required commands and source paths
- destination mount/writable verification before copy
- `backup.status` marker (`in_progress`, `complete`, `failed`) for restore safety
- completeness verification of expected backup content before marking complete
- backup audit log entries in `backup-audit.log`
- restore value config copied to `config/serv.restore.conf`
- LUKS header backup saved as `luks.bin` when a LUKS source is detected; set `LUKS_DEVICE=/dev/...` to force a specific source device

Restore service backup from inside a `SERV/BKP-*` folder:

```bash
cd /path/to/device/SERV/BKP-<timestamp>
./restore-serv.sh
```

`restore-serv.sh` also supports `--quiet`.

Current options:

- `0 - Exit`
- `1 - Restore grub theme`: restores `lateralus` to `/boot/grub/themes/`.
- `2 - Restore samba`: restores `smb.conf` and `creds-*` files to `/etc/samba/`.
- `3 - Restore SSH`: restores `sshd_config` to `/etc/ssh/`.
- `4 - Create SMB`: creates `/SMB`, `/SMB/euclid`, `/SMB/pneuma`, `/SMB/lateralus`, `/SMB/SCP`, `/SMB/SCP/HDD-01`, `/SMB/SCP/HDD-02`, `/SMB/SCP/HDD-03`, then sets ownership to the local non-root user and permissions to `750`.
- `5 - Restore fstab`: runs `sudo modprobe cifs`, adds one blank line, then appends the SMB mount entries to `/etc/fstab`.
- `6 - Restore GRUB`: updates `/etc/default/grub` values for splash, terminal input/output, gfx mode, and GRUB theme path.

Service restore fail-safes:

- restore is blocked unless `backup.status` is `complete`
- SMB directories, fstab lines, and GRUB target values are loaded from `config/serv.restore.conf` when present, with built-in defaults for older backups
- per-action confirmation prompts
- automatic pre-restore snapshots for changed targets (`*-pre-restore-<timestamp>`)
- generated rollback helper script: `restore-serv-rollback-<timestamp>.sh`
- idempotent `fstab` updates (only missing lines are appended)
- atomic file update flow for `/etc/fstab` and `/etc/default/grub` (temp file + install)
- post-restore validation hooks (`testparm -s`, `sshd -t`, `findmnt --verify` when available)
- permission hardening for sensitive files (`/etc/samba/creds-*`, `/etc/ssh/sshd_config`)
- restore audit log entries in `restore-serv-audit.log`

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

`restore-dots.sh` also supports `--quiet`.

Current options:

- `0 - Exit`
- `1 - Install DOTS`: moves `$HOME/.config/hypr` to a safety snapshot, then runs `bash <(curl -s https://ml4w.com/os/stable)`.
- `2 - Restore Wallpapers`: moves the existing wallpapers folder to a safety snapshot, then copies `ml4w/wallpapers` from the current `DOTS` folder.
- `3 - Restore FastFetch`: moves the existing FastFetch folder to a safety snapshot, then copies `fastfetch` from the current `DOTS` folder.
- `4 - Restore KITTY`: moves the existing KITTY folder to a safety snapshot, then copies `kitty` from the current `DOTS` folder.
- `5 - Restore ROFI`: moves the existing ROFI folder to a safety snapshot, then copies `rofi` from the current `DOTS` folder.
- `6 - Restore WAYBAR`: renames `$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/waybar/themes` to `themes-bkp`, then copies `waybar/themes` from the current `DOTS` folder.
- `7 - Restore HYPR`: copies `hypr/conf/keybindings/default.lua`, `hypr/conf/monitor.lua`, and `hypr/conf/windowrules/default.lua` into their matching `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/conf/` subfolders, copies `hypr/hypridle.conf`, `hypr/hyprlock.conf`, `hypr/logo-2.png` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/`, copies `hypr/scripts/uptime.sh` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/scripts/`, copies `waybar/modules.json` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/waybar/modules.json`, copies `gtk-3.0/bookmarks` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/gtk-3.0/bookmarks`, and restores `quickshell/CalendarApp`, `quickshell/CustomTheme`, `quickshell/PowerApp`, `quickshell/SidebarApp`, `quickshell/WallpaperApp`, and `quickshell/WelcomeApp` to their matching `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/quickshell/` subfolders.
- `8 - Install fonts`: runs `BIG/fonts/install.sh` from the backup device root (with a local fallback lookup).

Each restore option asks for confirmation before changing local configuration.
If you answer `N`, the action is cancelled and the script returns to the menu.

The copied `restore-dots.sh` includes the same bundled-helper and fallback behavior as the main restore script.

`config/serv.restore.conf` controls service restore values for SMB directories, fstab lines, and GRUB defaults. This file is copied into each `SERV` backup so restore behavior is tied to the backup that created it.

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

For CI-equivalent local checks:

```bash
make ci-check
```

Run restore portability smoke checks:

```bash
make smoke
```

Run a read-only post-reinstall readiness report:

```bash
make doctor
```

## Versioning

Current version is tracked in the `VERSION` file.

## Changelog

### 0.4.0

- centralized common script helpers (logging, prompts, rsync profiles, dependency checks)
- added log levels and `--quiet` mode across backup/restore scripts
- standardized rsync execution paths for backup and restore operations
- added script-specific preflight dependency checks
- improved restore menu behavior to return to menu after cancelled actions
- switched critical config writes to atomic temp-file updates in service restore
- added GitHub Actions shell CI (`bash -n`, `shellcheck`, `shfmt -d`)

## Publishing

This repository is ready for local git tracking. When you decide to publish it on GitHub, add a remote:

```bash
git remote add origin git@github.com:YOUR_USER/BKPv3.git
git push -u origin main
```
