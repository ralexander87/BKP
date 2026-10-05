# BKPv3

> Bash scripts for backing up and restoring Linux user folders, service configuration, and dotfiles.

## Documentation

- [README-DOTS.md](README-DOTS.md): `bkp-main.sh`, `restore-main.sh`, and every `restore-dots.sh` action
- [README-SERV.md](README-SERV.md): `bkp-serv.sh` and every `restore-serv.sh` action

## Scripts

- `bkp-main.sh`: backs up discovered home folders and ML4W dotfiles
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

## Requirements

Use the shared dependency check for a complete report:

```bash
make deps
```

Core backup and development commands are reported as failures when absent. Commands used only by individual restore actions are reported as warnings.

## Configuration

Public, version-controlled configuration is split by responsibility:

- `config/main.backup.conf`: MAIN source paths, shared `BIG` destinations, hidden files, and rsync exclusions
- `config/serv.backup.conf`: required SERVICE source paths and the Samba credentials pattern
- `config/dots-extra.conf`: Arch/AUR packages, Flatpaks, and repository VLC removal behavior
- `config/serv.restore.conf`: SMB directory and GRUB restore values

Machine-local values remain under ignored `config/local/`. Relevant local configuration is copied into new backups so restore behavior stays tied to the backup that created it without publishing private values.

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

Restore logs are stored inside the backup when it is writable. On read-only backup media, logs and generated rollback files use `${XDG_STATE_HOME:-$HOME/.local/state}/bkp/`.

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

`doctor.sh` checks required commands, configured source paths, latest mounted backup structure, backup status markers, local restore files when present, Git state, GitHub authentication, and smoke-check prerequisites.

## Versioning

The current version is stored in `VERSION`.

## Changelog

### 0.5.0

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
