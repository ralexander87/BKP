# BKPv3

Bash scripts for backing up and restoring Linux user folders, service-related files, and dotfiles.

## Scripts

- `bkp-main.sh` / `restore-main.sh`: user folders and files.
- `bkp-serv.sh` / `restore-serv.sh`: service configuration/data paths.
- `bkp-dots.sh` / `restore-dots.sh`: dotfiles and user config folders.

## Requirements

- `bash`
- `rsync`
- `pigz` for optional archive compression
- `shellcheck` for script checks
- `shfmt` for formatting, optional

## Quick Start

Run a dry backup first:

```bash
./bkp-main.sh --dry-run
./bkp-dots.sh --dry-run
```

Run a real backup:

```bash
./bkp-main.sh
./bkp-dots.sh
```

Create a compressed archive after backup:

```bash
./bkp-main.sh --compress
```

Restore from a backup directory:

```bash
./restore-main.sh --source backups/main/latest
./restore-dots.sh --source backups/dots/latest
```

## Configuration

Edit the files in `config/` to tune source and destination paths. Lines beginning with `#` and blank lines are ignored.

## Development

Check dependencies:

```bash
make deps
```

Run shell checks:

```bash
make check
```

## Publishing

This repository is ready for local git tracking. When you decide to publish it on GitHub, add a remote:

```bash
git remote add origin git@github.com:YOUR_USER/BKPv3.git
git push -u origin main
```

