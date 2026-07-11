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

Backup runs write terminal output, progress summaries, warnings, errors, and audit-style entries to one shared project log:

```bash
logs/bkp.log
```

Each backup includes `backup-manifest.txt` with timestamp, host, user, destination, archive choice, copied folder list, git commit when available, and final dashboard status counters.

Each main backup records `backup_status` in `backup-manifest.txt`. New restores are blocked when this value is not `complete`; older backups with a separate `backup.status` file still restore.

Terminal output is intentionally grouped. The backup scripts show a lightweight dashboard with task status, selected options, separator lines between task groups, recent warnings/errors, and a final success/failure summary instead of printing every copied file.

Restore the main backup from inside a backup folder:

```bash
cd /path/to/device/MAIN/BKP-<timestamp>
./restore-main.sh
```

`restore-main.sh` also supports `--quiet`.

Each backup includes a copy of `restore-main.sh`. It restores from its current folder back into `$HOME` after you confirm with `Y`.

Restore runs write their output and results to `restore.log` in the backup folder. `restore-dots.sh` writes to the parent backup folder's `restore.log` when it is run from `DOTS`.

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
- `backup_status` marker (`in_progress`, `complete`, `failed`) in `backup-manifest.txt` for restore safety
- completeness verification of expected backup content before marking complete
- backup audit entries in `logs/bkp.log`
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
- `1 - Create SMB`: creates `/SMB`, `/SMB/euclid`, `/SMB/pneuma-kali`, `/SMB/pneuma-win`, `/SMB/lateralus`, `/SMB/SCP`, `/SMB/SCP/HDD-01`, `/SMB/SCP/HDD-02`, `/SMB/SCP/HDD-03`, then sets ownership to the local non-root user and permissions to `750`.
- `2 - Restore samba`: restores `smb.conf` and `creds-*` files to `/etc/samba/`, then optionally runs `sudo smbpasswd -a <local-user>`.
- `3 - Restore SSH`: restores `sshd_config` to `/etc/ssh/`.
- `4 - Restore fstab`: runs `sudo modprobe cifs`, adds one blank line, then appends the SMB mount entries to `/etc/fstab`.
- `5 - Restore grub theme`: restores `lateralus` to `/boot/grub/themes/`.
- `6 - Restore GRUB`: updates `/etc/default/grub` values for splash, terminal input/output, gfx mode, and GRUB theme path, then runs `sudo grub-mkconfig -o /boot/grub/grub.cfg`.

Service restore fail-safes:

- restore is blocked unless `backup_status` in `backup-manifest.txt` is `complete`
- SMB directories and GRUB target values are loaded from `config/serv.restore.conf` when present, with local fstab entries loaded from ignored `config/local/serv.restore.conf` when present
- per-action confirmation prompts
- automatic pre-restore snapshots for changed targets (`*-pre-restore-<timestamp>`)
- generated rollback helper script: `restore-serv-rollback-<timestamp>.sh`
- idempotent `fstab` updates (only missing lines are appended)
- atomic file update flow for `/etc/fstab` and `/etc/default/grub` (temp file + install)
- post-restore validation hooks (`testparm -s`, `sshd -t`, `findmnt --verify` when available)
- permission hardening for sensitive files (`/etc/samba/creds-*`, `/etc/ssh/sshd_config`)
- restore audit entries in `restore.log`

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
When ignored `config/local/restore-dots-settings.sh` exists, it is copied into `DOTS/config/local/` and can be run by `99 - Restore Settings`.

Run dotfiles restore actions from inside a backup `DOTS` folder:

```bash
cd /path/to/device/MAIN/BKP-<timestamp>/DOTS
./restore-dots.sh
```

`restore-dots.sh` also supports `--quiet`.

Current options:

- `0 - Exit`
- `1 - Install DOTS`: moves `$HOME/.config/hypr` to a safety snapshot, then runs `bash <(curl -s https://ml4w.com/os/stable)`.
- `2 - Install fonts`: runs `BIG/fonts/install.sh` from the backup device root (with a local fallback lookup), copies `BIG/Steelfish Outline.ttf` into `$HOME/.local/share/fonts/`, and refreshes that font cache when `fc-cache` is available.
- `3 - Restore HYPR`: copies `hypr/conf/keybindings/default.lua`, `hypr/conf/monitor.lua`, and `hypr/conf/windowrules/default.lua` into their matching `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/conf/` subfolders, copies `hypr/hypridle.conf`, `hypr/hyprlock.conf`, `hypr/hyprland-gui.lua`, and `hypr/logo-2.png` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/`, copies `hypr/scripts/uptime.sh` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/scripts/`, copies `waybar/modules.json` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/waybar/modules.json`, copies `gtk-3.0/bookmarks` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/gtk-3.0/bookmarks`, restores quickshell app folders, and applies local font adjustments to `quickshell/overview/config.json`.
- `4 - Restore KITTY`: moves the existing KITTY folder to a safety snapshot, then copies `kitty` from the current `DOTS` folder.
- `5 - Restore ZSHRC`: moves an existing `$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/zshrc` folder to a safety snapshot, then copies `zshrc` from the current `DOTS` folder.
- `6 - Restore ROFI`: moves the existing ROFI folder to a safety snapshot, then copies `rofi` from the current `DOTS` folder.
- `7 - Restore WAYBAR`: renames `$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/waybar/themes` to `themes-bkp`, then copies `waybar/themes` from the current `DOTS` folder.
- `8 - Restore MATUGEN`: copies `matugen/config.toml` from the current `DOTS` folder to the matching ML4W config path.
- `9 - Restore FASTFETCH`: moves the existing FastFetch folder to a safety snapshot, then copies `fastfetch` from the current `DOTS` folder.
- `10 - Restore Wallpapers`: moves the existing wallpapers folder to a safety snapshot, then copies `ml4w/wallpapers` from the current `DOTS` folder.
- `98 - Collect pre-restore`: moves `*-pre-restore-*` files and folders found under `$HOME` into `$HOME/PreRestored`.
- `99 - Restore Settings`: copies selected GTK, Qt, `ml4w/settings/`, and `wlogout/themes/glass/style.css` files from the current `DOTS` folder to the matching ML4W config path, then applies local wlogout style adjustments.

Each restore option asks for confirmation before changing local configuration.
If you answer `N`, the action is cancelled and the script returns to the menu.

The copied `restore-dots.sh` includes the same bundled-helper and fallback behavior as the main restore script.

`config/serv.restore.conf` controls public service restore values for SMB directories and GRUB defaults. Local fstab entries can be stored in ignored `config/local/serv.restore.conf`; when present, this local file is copied into each `SERV` backup so restore behavior is tied to the backup that created it without publishing private mount details.

`config/local/` is intentionally ignored by Git. It is used for machine-local restore data such as fstab entries and optional dotfiles restore hooks. `doctor.sh` checks the latest mounted backups for these local files when they exist in the project.

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

`doctor.sh` checks required commands, source paths, latest mounted backup structure, backup status markers, local ignored restore files when present, Git state, GitHub SSH authentication, and smoke-check prerequisites.

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
