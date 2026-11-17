# BKPv3

> Bash scripts for backing up and restoring Linux user folders, service configuration, and dotfiles.

## Documentation

- [README-DOTS.md](README-DOTS.md): `bkp-main.sh`, `restore-main.sh`, and every `restore-dots.sh` action
- [README-SERV.md](README-SERV.md): `bkp-serv.sh` and every `restore-serv.sh` action

## Scripts

- `bkp-main.sh`: backs up discovered home folders and ML4W dotfiles
- `ARGUS/argus-main.sh`: backs up discovered home folders and KDE configuration on `argus`
- `restore-main.sh`: restores a completed MAIN backup into `$HOME`
- `restore-dots.sh`: installs or restores selected dotfiles from a MAIN backup
- `bkp-serv.sh`: backs up service and system configuration
- `restore-serv.sh`: restores selected service and system configuration
- `catalog.sh`: provides a read-only catalog of completed and interrupted backups
- `doctor.sh`: reports post-reinstall project and backup readiness

All backup and restore scripts support `--quiet`. INFO messages are hidden from the terminal while full messages continue to be written to their log.

## Quick Start

Run a MAIN backup:

```bash
./bkp-main.sh
```

Run a SERVICE backup:

```bash
./bkp-serv.sh
```

See the [MAIN and DOTS guide](README-DOTS.md) or [SERVICE guide](README-SERV.md) before running restore actions.

## SSH Workflow

BKPv3 handles user and server SSH configuration in separate backup streams:

- MAIN backs up `$HOME/.ssh`, excluding the transient `.ssh/agent/` directory. MAIN restore reapplies directory mode `700`, public-key mode `644`, and mode `600` to other SSH files.
- SERVICE backs up `/etc/ssh/sshd_config` and `/etc/ssh/sshd_config.d/` when the drop-in directory exists.
- SERVICE restore option `3` restores only SSH. Option `94` runs the complete profile, including SSH alongside the sharing, boot, discovery, and smart-card profiles.
- SSH server configuration is validated before installation and again before `sshd.service` is refreshed. Missing host keys are generated with `ssh-keygen -A`; host keys are not copied into SERVICE backups.

MAIN backups can contain private user keys. Keep the backup device and any generated archives protected.

## Requirements

Use the shared dependency check for a complete report:

```bash
make deps
```

Core backup and development commands are reported as failures when absent. Commands used only by individual restore actions are reported as warnings.

## Configuration

Public, version-controlled configuration is split by responsibility:

- `config/main.backup.conf`: MAIN source paths, shared `015-LATERALUS` destinations, hidden files, and rsync exclusions
- `ARGUS/main.backup.conf`: ARGUS MAIN hidden home folders, shell files, and rsync exclusions
- `config/serv.backup.conf`: required SERVICE source paths and the Samba credentials pattern
- `config/dots-extra.conf`: Arch/AUR packages, Flatpaks, and repository VLC removal behavior
- `config/serv.restore.conf`: SMB directory and GRUB restore values

Machine-local values remain under ignored `config/local/`. Relevant local configuration is copied into new backups so restore behavior stays tied to the backup that created it without publishing private values.

## Backup Layout

When the current hostname is `lateralus`, new MAIN and SERVICE backups and their archives are stored under `<external device>/015-LATERALUS/MAIN/` and `<external device>/015-LATERALUS/SERV/`. On `argus`, MAIN backups and optional archives are stored under `<external device>/011-ARGUS/MAIN/`. Other hosts continue to use `<external device>/MAIN/` and `<external device>/SERV/`. Shared assets such as wallpapers and firmware remain directly under `<external device>/015-LATERALUS/` on every host. The catalog and doctor recognize the ARGUS MAIN layout.

On a host named `argus`, the MAIN and SERVICE backup and restore entry points run the corresponding scripts under `ARGUS/`. ARGUS MAIN backs up discovered home folders, configured hidden KDE folders, and selected shell files. It does not include Hyprland or DOTS steps. `ARGUS/argus-serv.sh` and both ARGUS restore scripts remain placeholders for the next changes. ARGUS MAIN backups currently bundle the restore placeholder.

## Backup Catalog

List backups on detected external mounts:

```bash
./catalog.sh
```

Scan one or more specific destinations:

```bash
./catalog.sh /run/media/$USER/netac
```

The catalog reports MAIN/SERV type, folder name, status, creation time, size, archive presence, and archive validation state. Hidden `.BKP-*.in-progress` folders are included so interrupted runs remain visible.

## Logs

Backup runs write terminal output, progress summaries, warnings, errors, and audit entries to:

```text
logs/bkp.log
```

The shared log rotates at 5 MiB and retains five numbered copies by default. Override these values with `LOG_MAX_BYTES` and `LOG_ROTATE_COUNT`.

Errors from both backup scripts are also appended to `logs/err.log`. The file is created only when an error occurs and contains only timestamped `ERROR` entries. It uses the same rotation limits as `bkp.log`.

Restore logs are stored inside the backup when it is writable. Restore errors are also appended to `err.log` beside `restore.log`. On read-only backup media, logs and generated rollback files use `${XDG_STATE_HOME:-$HOME/.local/state}/bkp/`, with `err.log` in that state directory.

## Development

Check dependencies:

```bash
make deps
```

Run shell checks:

```bash
make check
```

Run CI-equivalent local checks:

```bash
make ci-check
```

Run restore portability and behavior checks:

```bash
make smoke
```

Run the post-reinstall readiness report:

```bash
make doctor
```

On `lateralus`, inspect the active `FeedMe-6+` profile, IPv4 settings, and saved password without printing the password:

```bash
make wifi-live-check
```

To test an actual password-free reconnect, run `./tools/check-wifi-live.sh --reconnect`. NetworkManager takes a 60-second checkpoint and asks you to confirm the result; without confirmation it rolls back the connection.

`doctor.sh` checks required commands, configured source paths, latest mounted backup structure, text and JSON manifest agreement, backup status markers, local restore files when present, SSH client parsing, SSH directory mode, `sshd.service` state, server configuration when noninteractive sudo is available, GitHub SSH authentication, Git state, and smoke-check prerequisites. Its SSH checks are read-only.

## Versioning

The current version is stored in `VERSION`.

## Changelog

### 0.6.0 (in progress)

- Add SERVICE option `8 - Restore Plymouth` to run the shared Daedric Morrowind installer as root
- Keep bundled SERVICE restore settings authoritative when the project configuration has changed
- Validate backup type, version, creation time, and status across text and JSON manifests in doctor
- Add an on-host WiFi profile check and checkpointed reconnect test for `FeedMe-6+`
- Removed restore, catalog, and doctor support for pre-0.4 status files and key/value manifests; version 1 manifests remain supported in both device layouts
- Removed duplicate `Run Result` fields from new text and JSON backup manifests
- Added DOTS option `50 - Connect WiFi` for the `FeedMe-6+` network with a manual IPv4 address, gateway DNS, and IPv6 disabled
- Use zero-padded `015-LATERALUS/` and `011-ARGUS/` folder names on the external device throughout backup, restore, catalog, and doctor workflows
- Store new MAIN and SERVICE backups under `015-LATERALUS/` when the hostname is `lateralus`, while recognizing both layouts during restore and inspection
- Route MAIN and SERVICE backup and restore entry points to `ARGUS/` on the `argus` host
- Implement ARGUS MAIN backups under `011-ARGUS/MAIN/` with KDE home configuration and no DOTS steps
- Made DOTS restore action confirmations default to `Y`, with `N` available to skip an action
- Added `hypr/conf/environments/nvidia.lua` to DOTS option `14 - Restore HYPR`
- Excluded `$HOME/PreRestored` from MAIN backups, including folder selection and size estimates
- Renamed the shared external backup folder from `BIG` to `015-LATERALUS` across backup, restore, doctor, and catalog-related documentation
- Added Minipro algorithm and udev-rule restoration to DOTS option `99 - Restore Settings`
- Reordered DOTS Install Extra into validated package, Flatpak, integration, and HyprMod phases
- Added the `srec-git` and `minipro-git` AUR packages to DOTS option `3 - Install Extra`
- Added Brave Browser through the `brave-bin` AUR package in DOTS option `3 - Install Extra`
- Merged the HyprMod installation into DOTS option `3 - Install Extra` and removed its separate menu action
- Added Arduino IDE 2 to DOTS Install Extra and ensured its Micronucleus udev rule is present
- Switched the Jefferson AUR selection to the maintained `jefferson-git` package
- Added MAIN restore support for the shared `015-LATERALUS/cc.arduino.IDE2.desktop` launcher, including a safety snapshot of an existing launcher

### 0.5.0

- Split SERVICE restore into focused sharing, boot, discovery, and smart-card profiles, plus a complete profile that includes SSH
- Kept the SERVICE menu running after an action failure and added final partial-failure audit reporting
- Added an optional one-time Timeshift snapshot before the first system-changing SERVICE action
- Made GRUB theme restore and rollback aware of FAT-family filesystem limitations
- Hardened SSH restore with isolated backup validation, missing host-key generation, installed-config validation, and safe service refresh
- Added backup and restore coverage for `/etc/ssh/sshd_config.d/` drop-ins and read-only SSH doctor checks
- Split Quickshell into `21 - Restore QS` and moved Waybar modules into `16 - Restore WAYBAR`
- Moved GTK bookmarks and xsettingsd configuration into `99 - Restore Settings`
- Changed restored `sshd_config` mode to `644` for newly created service backups
- Made dotfiles action confirmations default to `N`
- Stored service rollback commands newest-first so repeated changes reverse correctly
- Kept catalog scans running when protected backup content makes `du` return a partial-result error
- Added functional restore coverage for HYPR, Waybar, Quickshell, and Settings
- Centralized dependency reporting and derived doctor source-path checks from backup configuration

### 0.4.0

- Centralized common script helpers for logging, prompts, rsync profiles, and dependency checks
- Added log levels and `--quiet` mode across backup and restore scripts
- Standardized rsync execution paths for backup and restore operations
- Added script-specific preflight dependency checks
- Improved restore menu behavior to return to the menu after cancelled actions
- Switched critical service configuration writes to atomic temporary-file updates
- Added GitHub Actions shell CI with `bash -n`, `shellcheck`, and `shfmt -d`
- Added atomic backup publication, validated archives, versioned manifests, and backup cataloging
- Added dynamic `$HOME` folder selection and shared wallpaper and firmware storage
- Added compact backup dashboards and compact per-item MAIN restore output
- Added automatic MAIN pre-restore snapshot collection into `$HOME/PreRestored`
- Expanded dotfiles restore actions for packages, AutoLogin, shell changes, HYPR, Waybar, CAVA, SWAYNC, and Wlogout
