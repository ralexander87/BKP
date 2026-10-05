# BKPv3 SERVICE Guide

> Complete guide for `bkp-serv.sh` and `restore-serv.sh`.

[Back to project README](README.md) · [MAIN and DOTS guide](README-DOTS.md)

## Requirements

- `bash`, `rsync`, and `sudo`
- `cryptsetup` and `lsblk` for LUKS header discovery and backup
- `pigz` and `tar` when creating compressed archives
- `systemctl` for service state changes
- Action-specific commands such as `smbpasswd`, `testparm`, `sshd`, `findmnt`, `modprobe`, and `grub-mkconfig`

Run `make deps` from the project root for the complete dependency report.

## SERVICE Backup

Run:

```bash
./bkp-serv.sh
```

Use `--quiet` to hide INFO-level terminal output while keeping full logs:

```bash
./bkp-serv.sh --quiet
```

The script requests root authentication, uses the mounted-device selector, and writes backups to:

```text
/path/to/device/SERV/BKP-<timestamp>
```

It backs up:

- `/etc/samba/smb.conf`
- `/etc/samba/creds-*`
- `/etc/ssh/sshd_config`
- `/etc/default/grub`
- `/etc/mkinitcpio.conf`
- A detected LUKS header as `luks.bin`

Set `LUKS_DEVICE=/dev/...` to force a specific LUKS source device.

Backup content is stored as standalone entries in the backup root, such as `smb.conf`, `sshd_config`, `grub`, `mkinitcpio.conf`, `creds-*`, and `luks.bin`. Each backup also includes `restore-serv.sh`, `lib/common.sh`, and the restore configuration used for that run.

Required source paths and the Samba credentials pattern are configured in `config/serv.backup.conf`.

### Archives and Safety

Optional compressed archives are written beside the backup folder:

```text
/path/to/device/SERV/BKP-<timestamp>.tar.gz
```

Archive creation is offered before the backup starts and defaults to `N`. Compression uses `pigz`. Temporary archives are validated before publication and restricted to mode `600` on filesystems supporting Unix permissions.

SERVICE backup safety behavior includes:

- Required-command and required-source-path preflight checks
- Destination mount and writable checks
- A lock preventing overlapping SERVICE backups
- Initial writes to a hidden `.BKP-*.in-progress` folder
- Human-readable `[IN PROGRESS]`, `[COMPLETED]`, or `[FAILED]` status
- A versioned JSON manifest alongside the human-readable manifest
- Completeness verification before publication
- Audit entries in `logs/bkp.log`
- Restore configuration copied to `config/serv.restore.conf`
- Machine-local `config/local/serv.restore.conf` copied when present
- Failed status recording and temporary archive cleanup after interruption

## SERVICE Restore

Run from inside a completed SERVICE backup:

```bash
cd /path/to/device/SERV/BKP-<timestamp>
./restore-serv.sh
```

`restore-serv.sh` supports `--quiet`. It validates backup status, creates a rollback helper, requests sudo authentication, and opens the menu. Every service action defaults its confirmation prompt to `N`.

### Restore Actions

- `0 - Exit`
- `1 - Create SMB`
  - Creates `/SMB`, `/SMB/euclid`, `/SMB/pneuma-kali`, and `/SMB/lateralus`
  - Creates `/SMB/SCP/HDD-01`, `/SMB/SCP/HDD-02`, and `/SMB/SCP/HDD-03`
  - Sets ownership to the local non-root user and permissions to `750`
- `2 - Restore samba`
  - Restores `smb.conf` and `creds-*` into `/etc/samba/`
  - Uses mode `600` for credential files
  - Validates configuration with `testparm -s` when available
  - Optionally runs `sudo smbpasswd -a <local-user>`
  - Enables and starts `smb.service`
- `3 - Restore SSH`
  - Restores `sshd_config` into `/etc/ssh/`
  - Sets ownership to `root:root` and mode to `644`
  - Validates configuration with `sshd -t` when available
  - Enables and starts `sshd.service`
- `4 - Restore fstab`
  - Loads the CIFS kernel module
  - Replaces existing entries for configured and retired SMB mountpoints
  - Validates the generated table with `findmnt --verify` when available
  - Atomically installs `/etc/fstab`
- `5 - Restore grub theme`
  - Restores shared `BIG/lateralus` from the backup device to `/boot/grub/themes/lateralus`
- `6 - Restore GRUB`
  - Updates configured splash, terminal input/output, graphics mode, and theme values in `/etc/default/grub`
  - Atomically installs the updated file
  - Runs `sudo grub-mkconfig -o /boot/grub/grub.cfg`
- `7 - Restore RAMBOX`
  - Records the previous `/opt/rambox` mode in the rollback helper
  - Sets `/opt/rambox` to mode `755`
- `90 - Restore CONFIG`
  - Restores `smb.conf`, `creds-euclid`, `creds-pneuma`, and `creds-scp` into `/etc/samba/`
  - Restores `sshd_config` into `/etc/ssh/` with mode `644`
  - Enables and starts `avahi-daemon.service`, `wsdd.service`, `sshd.service`, `nmb.service`, and `pcscd.service`
- `98 - Collect pre-restore`
  - Collects legacy `*-pre-restore-*` items from known service target locations into `$HOME/PreRestored`
  - Preserves ownership and updates rollback references to the collected paths

### Restore Configuration

Public restore values are stored in `config/serv.restore.conf`, including SMB directories and GRUB values. Machine-specific fstab lines can be stored in ignored `config/local/serv.restore.conf`.

A SERVICE backup carries these values so its restore behavior stays tied to the backup that created it. Restore starts with built-in defaults and loads available configuration in this order:

```text
config/serv.restore.conf
config/local/serv.restore.conf
serv.restore.conf
project config/serv.restore.conf
project config/local/serv.restore.conf
```

Later files can override earlier values. Retired `/SMB/pneuma-win` data remains managed for cleanup so stale directories and fstab entries can be removed.

### Restore Safety and Rollback

Restore is blocked unless the human-readable manifest reports `[COMPLETED]`, or a supported legacy status file reports completion.

Before modifying an existing target, the script creates a timestamped snapshot and moves it into `$HOME/PreRestored`. It records reverse operations in:

```text
restore-serv-rollback-<timestamp>.sh
```

Rollback covers replaced and newly created targets, SMB directory metadata, service state, and a CIFS module loaded by the restore. Commands are stored newest-first so repeated changes to one target reverse in the correct order.

Additional safeguards include:

- Idempotent fstab updates by configured mountpoint
- Atomic updates for `/etc/fstab` and `/etc/default/grub`
- Post-restore validation where the relevant validation command is available
- Audit entries and action results in `restore.log`
- A user-state fallback for logs and rollback helpers when backup media is read-only
