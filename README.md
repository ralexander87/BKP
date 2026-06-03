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

Run the main backup:

```bash
./bkp-main.sh
```

The script lists external mounted devices. If one device is mounted, it is selected automatically. If multiple devices are mounted, select the destination by number.

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
  restore-main.sh
```

The timestamp format is:

```bash
date +%j-%d-%m-%H-%M-%S
```

After copying files, `bkp-main.sh` asks whether to create a compressed `.tar.gz` archive. The default answer is `N`; when you answer `Y`, compression uses `pigz`.

Terminal output is intentionally minimal. The scripts show top-level folder status and errors instead of printing every copied file.

Restore the main backup:

```bash
./restore-main.sh
```

Each backup also includes a copy of `restore-main.sh`. When run from inside a `BKP-*` folder, it restores from that current folder back into `$HOME`. When run from the project folder, it uses mounted-device selection and lists available `MAIN/BKP-*` backup folders.

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

## Publishing

This repository is ready for local git tracking. When you decide to publish it on GitHub, add a remote:

```bash
git remote add origin git@github.com:YOUR_USER/BKPv3.git
git push -u origin main
```
