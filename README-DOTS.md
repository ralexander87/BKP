# BKPv3 MAIN and DOTS Guide

> Complete guide for `bkp-main.sh`, `restore-main.sh`, and `restore-dots.sh`.

[Back to project README](README.md) · [SERVICE guide](README-SERV.md)

## Requirements

- `bash` and `rsync`
- `pigz` and `tar` when creating compressed archives
- `curl` for the ML4W installer
- `sudo`, `pacman`, `makepkg`, `git`, `flatpak`, and `yay` for package actions
- `fc-cache` for refreshing the font cache when available

Run `make deps` from the project root for the complete dependency report.

## MAIN Backup

Run:

```bash
./bkp-main.sh
```

Use `--quiet` to hide INFO-level terminal output while keeping full logs:

```bash
./bkp-main.sh --quiet
```

The script lists external mounted devices with source device, filesystem, label, and free space. A single device is selected automatically; when multiple devices are mounted, choose one by number.

The folder-selection prompt provides these actions:

- Press Enter to back up all discovered folders
- Enter one or more displayed folder numbers, separated by spaces or commas, to exclude them
- `0 - EXIT` cancels the backup
- `90 - Update Firmware and Wallpapers` updates only shared `BIG/030-Firmware/` and `BIG/wallpapers/`, then exits without creating a per-run backup

Each backup is written to:

```text
/path/to/device/MAIN/BKP-<timestamp>
```

The backup contains selected discovered `$HOME` folders directly:

```text
BKP-<timestamp>/
  Downloads/
  Pictures/
  Documents/
  <DiscoveredFolder>/
  .ssh/
  DOTS/
  config/
  lib/
  backup-manifest.txt
  backup-manifest.json
  restore-main.sh
```

The timestamp format is generated with:

```bash
date +%Y-%j-%d-%m-%H-%M-%S
```

### Sources and Selection

`bkp-main.sh` handles:

- Every top-level non-hidden folder in `$HOME`
  - A numbered prompt allows any discovered folder to be excluded for that run
- Selected hidden folders when present
  - `.themes`
  - `.icons`
  - `.ssh`
  - `.vscode-oss`
- `$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config`, copied into `DOTS`
- `$HOME/Documents/030-Firmware`, stored in shared `BIG/030-Firmware`
- ML4W wallpapers, stored in shared `BIG/wallpapers`
- Selected backup-only files, stored directly in shared `BIG/`
  - `.bash_history`
  - `.zsh_history`
  - `.zshrc`
  - `.wget-hsts`

The backup-only files in shared `BIG/` are not restored by any restore script.

`Downloads/*.iso` and `.ssh/agent/` are excluded. `Documents/030-Firmware/` is excluded from the per-run Documents copy, and `ml4w/wallpapers/` is excluded from the per-run DOTS copy.

The MAIN backup therefore preserves user SSH configuration, keys, `known_hosts`, and `authorized_keys` while omitting transient agent sockets. These files can contain private credentials, so the backup destination should be protected.

When `$HOME/.mydotfiles` or its nested ML4W configuration folder is absent, DOTS tasks are skipped without failing the MAIN backup. Shared wallpaper and firmware copies use `--ignore-existing`, leaving existing shared files untouched.

Source paths and exclusions are configured in `config/main.backup.conf`. DOTS package choices are configured in `config/dots-extra.conf`. Both files are bundled with relevant new backups.

When ignored `config/local/restore-dots-settings.sh` exists, it is copied into `DOTS/config/local/` for option 99.

### Archives and Safety

Before copying, the script asks whether to create a compressed `.tar.gz` archive. The default is `N`; answering `Y` uses `pigz`.

Archives are written beside the backup folder:

```text
/path/to/device/MAIN/BKP-<timestamp>.tar.gz
```

Shared `BIG/wallpapers/` and `BIG/030-Firmware/` content is excluded from each archive.

MAIN backup safety behavior includes:

- Estimated source-size and destination-free-space checks
- A warning and confirmation when the destination appears too small
- A lock under `logs/` to prevent overlapping MAIN runs
- Initial writes to a hidden `.BKP-*.in-progress` folder
- Publication as `BKP-*` only after required content passes verification
- Human-readable and JSON manifests using schema version `1`
- Temporary `.in-progress` archives validated with pigz and tar before publication
- Published archive mode `600` on filesystems supporting Unix permissions
- Failed status recording and temporary archive cleanup after interruption
- Compact dashboards and final summaries instead of per-file terminal output

## MAIN Restore

Run from inside a completed backup:

```bash
cd /path/to/device/MAIN/BKP-<timestamp>
./restore-main.sh
```

`restore-main.sh` supports `--quiet` and requires confirmation before restoring into `$HOME`. The confirmation defaults to `N`.

It discovers restorable top-level items and skips helper content such as `DOTS`, `config`, `lib`, restore scripts, manifests, and logs. A new restore requires `[COMPLETED]` status in the human-readable manifest; legacy key/value manifests and `backup.status` remain supported.

For each existing target, the script creates a `<name>-pre-restore-<timestamp>` snapshot and moves it into `$HOME/PreRestored` with a collision-safe name before restoration continues. Rsync preserves permissions, ownership, ACLs, extended attributes, hard links, and numeric IDs.

After restoration, it collects legacy `*-pre-restore-*` files and folders that older runs left under `$HOME` into `$HOME/PreRestored`.

Shared `BIG/030-Firmware/` is restored to `$HOME/Documents/030-Firmware/` when present. After `.ssh` is restored, modes are normalized to:

```text
directories  700
*.pub files  644
other files  600
```

Output is written to `restore.log` in the MAIN backup, with a user-state fallback on read-only media. The bundled `lib/common.sh` is used when present; restore scripts retain a fallback for older backups without it.

## DOTS Restore

Run from inside a completed backup's DOTS folder:

```bash
cd /path/to/device/MAIN/BKP-<timestamp>/DOTS
./restore-dots.sh
```

`restore-dots.sh` supports `--quiet`. It requires the parent MAIN manifest or legacy status marker to report a completed backup.

Actions ask for confirmation before changing local configuration. The default answer is `N`; a cancelled action returns to the menu. Option 4 becomes unattended after selection and does not add package-manager confirmation prompts.

### Install Actions

- `0 - Exit`
- `1 - Install DOTS`
  - Moves `$HOME/.config/hypr` to a safety snapshot
  - Downloads the ML4W Stable installer over HTTPS into a temporary file
  - Displays the first 20 installer lines
  - Runs the downloaded installer with Bash only after a second confirmation, also defaulting to `N`
- `2 - Install FONTS`
  - Runs `BIG/fonts/install.sh` from the backup-device root, with a local fallback lookup
  - Copies `BIG/Steelfish Outline.ttf` into `$HOME/.local/share/fonts/`
  - Refreshes the font cache when `fc-cache` is available
- `3 - Install HyprMod`
  - Requests root authentication once and keeps it valid until the action finishes
  - Installs `yay` from its official AUR package when missing
  - Runs the ML4W `ml4w-install-hyprmod` script after `yay` is available
- `4 - Install Extra`
  - Requests root authentication once and keeps it valid until the action finishes
  - Installs `yay` and its build requirements when needed
  - Removes repository VLC when configured and installed
  - Installs configured Arch/AUR packages and Flatpaks noninteractively
  - Current packages include `jefferson`, `yubico-authenticator-bin`, `hashid`, `python-ubi-reader-git`, `rambox-pro-bin`, `qrencode`, and `python-pywalfox`
  - Current Flatpaks include `org.videolan.VLC` and `org.gnome.Calculator`
  - Writes package-manager details to `install-extra.log`
- `5 - Set AutoLogin`
  - Snapshots `/usr/lib/sddm/sddm.conf.d/default.conf`
  - Sets its `User=` line to the local non-root username using `sudo`
- `6 - Change SHELL`
  - Runs the ML4W `ml4w-change-shell` script

### Restore Actions

- `10 - Restore Wallpapers`
  - Snapshots the current wallpapers folder
  - Copies shared `BIG/wallpapers/` into the ML4W wallpapers folder
- `11 - Restore ZSHRC, BASHRC`
  - Snapshots and restores the complete `zshrc` and `bashrc` folders
- `12 - Restore KITTY`
  - Snapshots and restores the complete `kitty` folder
- `13 - Restore FASTFETCH`
  - Snapshots and restores the complete `fastfetch` folder
- `14 - Restore HYPR`
  - Restores `hypr/conf/keybindings/default.lua`
  - Restores `hypr/conf/monitor.lua`
  - Restores `hypr/conf/windowrules/default.lua`
  - Restores `hypr/hypridle.conf`, `hypr/hyprlock.conf`, `hypr/hyprland-gui.lua`, and `hypr/logo-2.png`
  - Restores `hypr/scripts/uptime.sh`
- `15 - Restore ROFI`
  - Snapshots and restores the complete `rofi` folder
- `16 - Restore WAYBAR`
  - Restores `waybar/modules.json`
  - Snapshots and restores `waybar/themes/` and `waybar/scripts/`
- `17 - Restore MATUGEN`
  - Restores `matugen/config.toml` and the complete `matugen/templates/` folder
- `18 - Restore CAVA`
  - Snapshots and restores the complete `cava` folder
  - Creates `$HOME/.config/cava` as a symlink to the restored ML4W folder
  - Preserves a conflicting local CAVA path as a safety snapshot
- `19 - Restore SWAYNC`
  - Snapshots and restores the complete `swaync` folder
- `20 - Restore WLOGOUT`
  - Snapshots and restores the complete `wlogout` folder
- `21 - Restore QS`
  - Snapshots and restores the complete `quickshell` folder
- `22 - Restore WALKER`
  - Snapshots and restores the complete `walker` folder
- `98 - Collect pre-restore`
  - Collects legacy `*-pre-restore-*` items under `$HOME` into `$HOME/PreRestored`
- `99 - Restore Settings`
  - Restores `gtk-3.0/bookmarks`
  - Restores `gtk-3.0/settings.ini` and `gtk-4.0/settings.ini`
  - Restores `qt6ct/qt6ct.conf`
  - Restores `xsettingsd/xsettingsd.conf`
  - Restores selected `ml4w/settings/` files
  - Copies `BIG/dracula.qbtheme` to `$HOME/.config/qBittorrent/dracula.qbtheme`
  - Changes Thunar custom action commands in `$HOME/.config/Thunar/uca.xml` to `kitty` when present
  - Runs bundled `config/local/restore-dots-settings.sh` when present

Existing files changed by HYPR, Quickshell, Matugen, Settings, Thunar, and qBittorrent actions receive timestamped safety snapshots first. Folder actions use compact summaries without rsync's per-file percentage stream.
