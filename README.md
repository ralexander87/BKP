# BKPv1

> Bash scripts for backing up and restoring Linux user folders, service-related files, and dotfiles.

## Scripts

- `bkp-main.sh` / `restore-main.sh`: user folders, files, and dotfiles backup.
- `bkp-serv.sh` / `restore-serv.sh`: service/system config backup and restore.
- `restore-dots.sh`: dotfiles restore helper copied into backup `DOTS` folders.
- `catalog.sh`: read-only catalog of completed and interrupted backups.

## Requirements

- `bash`
- `rsync`
- `pigz` for optional archive compression
- `shellcheck` for script checks
- `shfmt` for formatting, optional

## Quick Start

#### Run the main backup:

```bash
./bkp-main.sh
```

Use `--quiet` to hide INFO-level terminal output while still writing full logs:

```bash
./bkp-main.sh --quiet
```

- The script lists external mounted devices with source device, filesystem, label, and free space. 
	- If one device is mounted, it is selected automatically
	- If multiple devices are mounted, select the destination by number.

#### Each main backup is written to:

```bash
/path/to/device/MAIN/BKP-<timestamp>
```

#### The backup folder contains selected discovered `$HOME` folders directly:

```text
BKP-<timestamp>/
  Downloads/
  Pictures/
  Documents/
  CustomFolder/
  .ssh/
  DOTS/
  lib/
  backup-manifest.txt
  backup-manifest.json
  restore-main.sh
```

##### The timestamp format is:

```bash
date +%j-%d-%m-%H-%M-%S
```

- Before copying files, `bkp-main.sh` asks whether to create a compressed `.tar.gz` archive after backup
	- The default answer is `N`; when you answer `Y`, compression uses `pigz`
- Backup content is first written to a hidden `.BKP-*.in-progress` folder
	- The folder is renamed to `BKP-*` only after required content passes verification

#### Main archives are written beside the backup folder:

```bash
/path/to/device/MAIN/BKP-<timestamp>.tar.gz
```

- The shared backup-device folders `BIG/wallpapers/` and `BIG/030-Firmware/` are not part of the per-run
	- `BKP-*` folder and are explicitly excluded from compressed main archives
- Before backup starts, `bkp-main.sh` offers a numbered skip list of all discovered non-hidden `$HOME` folders
	- Enter one or more numbers separated by spaces or commas to exclude those folders
- Before starting the backup, the script checks estimated source size against destination free space
	- If the destination appears too small, it warns and asks whether to continue
- Only one main backup can run at a time
	- A lock file in `logs/` prevents accidental overlapping runs

#### Backup runs write terminal output, progress summaries, warnings, errors, and audit-style entries to one shared project log:

```bash
logs/bkp.log
```

- Each backup includes a human-readable `backup-manifest.txt` with timestamp, host, user, destination, archive choice, copied items, Git commit when available, backup status, and final dashboard counters.
- Each backup also includes a versioned `backup-manifest.json` sidecar for tools and automation
	- Both manifests currently use schema version `1`
- New restores require `Backup Status = [COMPLETED]` or `Run Result = [COMPLETED]` in `backup-manifest.txt`
	- Legacy key/value manifests and separate `backup.status` files remain supported for older backups.
- Requested archives are written to a temporary `.in-progress` path
	- `pigz` integrity and tar readability are validated before the archive is renamed to its final path
- Interrupted backup runs are marked failed and temporary archives are removed by the exit cleanup flow
- Terminal output is intentionally grouped. 
	- The backup scripts show a lightweight dashboard with compact run metrics, selected options, named task sections, recent warnings/errors.
	- And a final success/failure summary instead of printing every copied file.

#### Restore the main backup from inside a backup folder:

```bash
cd /path/to/device/MAIN/BKP-<timestamp>
./restore-main.sh
```

`restore-main.sh` also supports `--quiet`

- Each backup includes a copy of `restore-main.sh`
	- It restores from its current folder back into `$HOME` after you confirm with `Y`
- `restore-main.sh` discovers restorable top-level backup items from the current backup folder
	- It skips backup helper content such as `DOTS`, `lib`, `restore-main.sh`, manifests, and logs
	- It restores shared `BIG/030-Firmware/` back to `$HOME/Documents/030-Firmware/` when that shared folder exists
- Restore runs write their output and results to `restore.log` in the backup folder
	- `restore-dots.sh` writes to the parent backup folder's `restore.log` when it is run from `DOTS`
- Backups also include `lib/common.sh` beside copied restore scripts. The restore scripts have a small built-in fallback, so they can still start from older backup folders where `lib/common.sh` is missing
- Restore uses `rsync` metadata-preserving options for permissions, ownership, ACLs, and extended attributes
- Before restoring a folder into `$HOME`, `restore-main.sh` moves an existing target folder to `<name>-pre-restore-<timestamp>`.
- After restoring `.ssh`, the script sets `.ssh` to `700`, `*.pub` files to `644`, and all other SSH files to `600`

#### Service backup:

```bash
./bkp-serv.sh
```

- `bkp-serv.sh` also supports `--quiet`.
- `bkp-serv.sh` uses the mounted-device selector and writes backups to:

```bash
/path/to/device/SERV/BKP-<timestamp>
```

#### It requests root authentication at startup, then backs up:

- `/etc/samba/smb.conf`
- `/etc/samba/creds-*`
- `/etc/ssh/sshd_config`
- `/boot/grub/themes/lateralus/` when present
- `/etc/default/grub`
- `/etc/mkinitcpio.conf`

- Each service backup includes a copy of `restore-serv.sh` inside the backup folder.
	- And supports optional `.tar.gz` compression with `pigz`.

#### Service archives are written beside the backup folder:

```bash
/path/to/device/SERV/BKP-<timestamp>.tar.gz
```

- Service backup content is stored as standalone entries in the backup root (for example `smb.conf`, `sshd_config`, `lateralus/`, `grub`, `mkinitcpio.conf`, `creds-*`, `luks.bin`), not as full `/etc/...` or `/boot/...` directory trees.

#### Service backup fail-safes:

- Preflight checks for required commands and required source paths
- Destination mount/writable verification before copy
- Human-readable backup status marker (`[IN PROGRESS]`, `[COMPLETED]`, or `[FAILED]`) in `backup-manifest.txt` for restore safety
- Completeness verification of expected backup content before marking complete
- Backup audit entries in `logs/bkp.log`
- Restore value config copied to `config/serv.restore.conf`
- LUKS header backup saved as `luks.bin` when a LUKS source is detected; set `LUKS_DEVICE=/dev/...` to force a specific source device

#### Restore service backup from inside a `SERV/BKP-*` folder:

```bash
cd /path/to/device/SERV/BKP-<timestamp>
./restore-serv.sh
```

`restore-serv.sh` also supports `--quiet`.

##### Current options:

- `0 - Exit`
- `1 - Create SMB`: creates 
	- `/SMB`
		- `/SMB/euclid`
		- `/SMB/pneuma-kali`
		- `/SMB/lateralus`
	- `/SMB/SCP`
		- `/SMB/SCP/HDD-01`
		- `/SMB/SCP/HDD-02`
		- `/SMB/SCP/HDD-03`
	- Then sets ownership to the local non-root user and permissions to `750`
- `2 - Restore samba`: restores 
	- `smb.conf`
	- `creds-*` 
		- to `/etc/samba/`
	- Optionally runs `sudo smbpasswd -a <local-user>`
		- Then enables and starts `smb.service`
- `3 - Restore SSH`: restores 
	- `sshd_config`
		- to `/etc/ssh/`
	- Then enables and starts `sshd.service`
- `4 - Restore fstab`: runs 
	- `sudo modprobe cifs`
		- Replaces existing entries for the configured SMB mountpoints
		- Validates the generated table
		- Then atomically installs it as `/etc/fstab`
- `5 - Restore grub theme`: restores 
	- `lateralus`
		- to `/boot/grub/themes/`
- `6 - Restore GRUB`: updates 
	- `/etc/default/grub` values for splash, terminal input/output, gfx mode, and GRUB theme path
		- Then runs `sudo grub-mkconfig -o /boot/grub/grub.cfg`
- `98 - Collect pre-restore`: moves service 
	- `*-pre-restore-*` files and folders from known restore target locations into `$HOME/PreRestored`
	- Preserves their ownership, and updates generated rollback scripts to the new paths

#### Service restore fail-safes:

- Restore is blocked unless
	- `Backup Status` or `Run Result` in `backup-manifest.txt` is `[COMPLETED]`
- SMB directories and GRUB target values are loaded from `config/serv.restore.conf` when presen
	- With local fstab entries loaded from ignored `config/local/serv.restore.conf` when present
- Per-action confirmation prompts
- Automatic pre-restore snapshots for changed targets (`*-pre-restore-<timestamp>`)
- Generated rollback helper script: `restore-serv-rollback-<timestamp>.sh`
- Idempotent `fstab` updates by configured mountpoint (stale entries for those mountpoints are replaced)
- Atomic file update flow for `/etc/fstab` and `/etc/default/grub` (temp file + install)
- Post-restore validation hooks (`testparm -s`, `sshd -t`, `findmnt --verify` when available)
- Permission hardening for sensitive files (`/etc/samba/creds-*`, `/etc/ssh/sshd_config`)
- Restore audit entries in `restore.log`

## Configuration

Public, version-controlled configuration is split by responsibility:

- `config/main.backup.conf`: main source paths, shared `BIG` destinations, hidden files, and rsync exclusions
- `config/serv.backup.conf`: required and optional service source paths plus the Samba credentials pattern
- `config/dots-extra.conf`: Arch/AUR packages, Flatpaks, and repository VLC removal behavior
- `config/serv.restore.conf`: SMB directory and GRUB restore values

Machine-local values remain under ignored `config/local/`.

New MAIN and DOTS backups include `config/main.backup.conf`, allowing restore scripts to use the firmware and wallpaper paths recorded with that backup. DOTS backups also include `config/dots-extra.conf`.

The current `bkp-main.sh` backs up discovered `$HOME` folders:

- Every top-level non-hidden folder in `$HOME`
	- Listed in a numbered prompt so the user can exclude any folder for that run
- Selected hidden folders when present
	- `.themes`
	- `.icons`
	- `.ssh`
	- `.vscode-oss`

`Downloads/*.iso` files are excluded. The `.ssh/agent` folder is excluded.

- `bkp-main.sh` also copies `$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config` into `DOTS` and copies `restore-dots.sh` into that `DOTS` folder
- `ml4w/wallpapers/` is excluded from each per-run `DOTS` copy and is stored in the shared backup-device folder `BIG/wallpapers/` instead
- When `$HOME/.mydotfiles` or the nested ML4W config folder is missing, the DOTS backup tasks are skipped without failing the main backup
- Wallpaper backup copies only files missing from `BIG/wallpapers/`
	- existing files in that shared folder are left untouched.
	- The shared `BIG/wallpapers/` folder is not included in compressed `MAIN/BKP-*.tar.gz` archives
- `Documents/030-Firmware/` is excluded from each per-run `Documents` copy and is stored in the shared backup-device folder `BIG/030-Firmware/` instead.
	- Firmware backup copies only files missing from `BIG/030-Firmware/`; existing files in that shared folder are left untouched.
	- `restore-main.sh` restores `BIG/030-Firmware/` back to `$HOME/Documents/030-Firmware/` when that shared folder exists.
	- The shared `BIG/030-Firmware/` folder and per-run `Documents/030-Firmware/` path are excluded from compressed `MAIN/BKP-*.tar.gz` archives.
- Selected backup-only home files are copied directly into `BIG/`
	- `.bash_history`
	- `.zsh_history`
	- `.zshrc`
	- `.wget-hsts`
		- These files are not restored by any restore script
- When ignored `config/local/restore-dots-settings.sh` exists, it is copied into `DOTS/config/local/` and can be run by `99 - Restore Settings`

#### Run dotfiles restore actions from inside a backup `DOTS` folder:

```bash
cd /path/to/device/MAIN/BKP-<timestamp>/DOTS
./restore-dots.sh
```

`restore-dots.sh` also supports `--quiet`.

##### Current options:

- `0 - Exit`
- `1 - Install DOTS`: moves `$HOME/.config/hypr` to a safety snapshot
	- Then runs `bash <(curl -s https://ml4w.com/os/stable)`
- `2 - Install fonts`: runs `BIG/fonts/install.sh` from the backup device root (with a local fallback lookup)
	- Copies `BIG/Steelfish Outline.ttf` into `$HOME/.local/share/fonts/`
		- Refreshes that font cache when `fc-cache` is available
- `3 - Install HyprMod`: runs `$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/ml4w/scripts/ml4w-install-hyprmod`.
- `4 - Install Extra`: removes repository `vlc` with `sudo pacman -R vlc` when installed
	- Checks for `org.videolan.VLC` and `org.gnome.Calculator` Flatpaks
	- Checks for `jefferson`, `yubico-authenticator-bin`, `hashid`, `python-ubi-reader-git`, and `rambox-pro-bin`
		- Prompts before installing missing Flatpaks with `flatpak install` and missing packages with `yay -S --needed`
- `10 - Restore Wallpapers`: moves the existing wallpapers folder to a safety snapshot
	- Then copies wallpapers from the backup device's shared `BIG/wallpapers/` folder
- `11 - Restore ZSHRC`: checks whether the login shell is zsh
	- Optionally `$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/ml4w/scripts/ml4w-change-shell` when zsh is not default
	- Moves an existing `$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/zshrc` folder to a safety snapshot and copies `zshrc` from the current `DOTS` folder
- `12 - Restore KITTY`: moves the existing KITTY folder to a safety snapshot
	- Copies `kitty` from the current `DOTS` folder
- `13 - Restore FASTFETCH`: moves the existing FastFetch folder to a safety snapshot
	- Copies `fastfetch` from the current `DOTS` folder
- `14 - Restore HYPR`: copies `hypr/conf/keybindings/default.lua`, `hypr/conf/monitor.lua`, and `hypr/conf/windowrules/default.lua`
	- Into matching `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/conf/` subfolders
	- Copies `hypr/hypridle.conf`, `hypr/hyprlock.conf`, `hypr/hyprland-gui.lua`, and `hypr/logo-2.png` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/`
	- Copies `hypr/scripts/uptime.sh` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/scripts/`
	- Copies `waybar/modules.json` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/waybar/modules.json`
	- Copies `gtk-3.0/bookmarks` to `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/gtk-3.0/bookmarks`
	- Moves the existing `quickshell` folder to a safety snapshot, restores the complete backed-up folder, and applies local font adjustments to `quickshell/overview/config.json`
- `15 - Restore ROFI`: moves the existing ROFI folder to a safety snapshot, then copies `rofi` from the current `DOTS` folder
- `16 - Restore WAYBAR`: moves the existing Waybar themes folder to a timestamped pre-restore snapshot, 
	- Then copies `waybar/themes` from the current `DOTS` folder
- `17 - Restore MATUGEN`: copies `matugen/config.toml` from the current `DOTS` folder to the matching ML4W config path
- `98 - Collect pre-restore`: moves `*-pre-restore-*` files and folders found under `$HOME` into `$HOME/PreRestored`
- `99 - Restore Settings`: copies selected GTK, Qt, `ml4w/settings/`, and `wlogout/themes/glass/style.css` files from the current `DOTS` folder to the matching ML4W config path
	- Copies `BIG/dracula.qbtheme` from the backup device to `$HOME/.config/qBittorrent/dracula.qbtheme`
	- Applies local wlogout style adjustments and changes Thunar custom action commands in `$HOME/.config/Thunar/uca.xml` to `kitty` when that file exists

- Each restore option asks for confirmation before changing local configuration.
	- If you answer `N`, the action is cancelled and the script returns to the menu
	- The copied `restore-dots.sh` includes the same bundled-helper and fallback behavior as the main restore script

`config/serv.restore.conf` controls public service restore values for SMB directories and GRUB defaults. Local fstab entries can be stored in ignored `config/local/serv.restore.conf`; when present, this local file is copied into each `SERV` backup so restore behavior is tied to the backup that created it without publishing private mount details.

`config/local/` is intentionally ignored by Git. It is used for machine-local restore data such as fstab entries and optional dotfiles restore hooks. `doctor.sh` checks the latest mounted backups for these local files when they exist in the project.

#### List available backups:

```bash
./catalog.sh
```

Pass one or more mounted-device paths to scan specific destinations:

```bash
./catalog.sh /run/media/$USER/netac
```

The catalog reports MAIN/SERV type, folder name, status, creation time, size, archive presence, and archive validation state. Hidden `.BKP-*.in-progress` folders are included so interrupted runs remain visible.

#### Log rotation:

The shared log rotates at 5 MiB and retains five numbered copies by default. Override these values for a run with `LOG_MAX_BYTES` and `LOG_ROTATE_COUNT`.

## Development

#### Check dependencies:

```bash
make deps
```

#### Run shell checks:

```bash
make check
```

`shellcheck` is required for `make check`. `shfmt` remains optional.

The smoke suite also uses `pigz`, `tar`, `truncate`, and `python3` for archive and JSON validation tests.

#### For CI-equivalent local checks:

```bash
make ci-check
```

#### Run restore portability smoke checks:

```bash
make smoke
```

#### Run a read-only post-reinstall readiness report:

```bash
make doctor
```

`doctor.sh` checks required commands, source paths, latest mounted backup structure, backup status markers, local ignored restore files when present, Git state, GitHub SSH authentication, and smoke-check prerequisites.

## Versioning

Current version is tracked in the `VERSION` file.

## Changelog

### 0.4.0

- Centralized common script helpers (logging, prompts, rsync profiles, dependency checks)
- Added log levels and `--quiet` mode across backup/restore scripts
- Standardized rsync execution paths for backup and restore operations
- Added script-specific preflight dependency checks
- Improved restore menu behavior to return to menu after cancelled actions
- Switched critical config writes to atomic temp-file updates in service restore
- Added GitHub Actions shell CI (`bash -n`, `shellcheck`, `shfmt -d`)
