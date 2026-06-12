#!/usr/bin/env bash

# Load shared helpers for logging, prompts, rsync profiles, and cleanup traps.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# The restore source is always the folder where this script is located.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/restore-main.log}"
RESTORE_ID="$(date '+%j-%d-%m-%H-%M-%S')"

# Backup items expected inside the current backup folder.
HOME_ITEMS=(
  "Downloads"
  "Pictures"
  "Videos"
  "Music"
  "Obsidian"
  "Code"
  "Documents"
  ".themes"
  ".icons"
  ".ssh"
)

# Print command usage for help requests.
usage() {
  cat <<'EOF'
Usage: ./restore-main.sh [--quiet]

Restore backup content from the current folder to $HOME.
EOF
}

# Ensure required dependencies exist before restore starts.
preflight_checks() {
  require_all_cmds rsync find mv
}

# Enforce SSH's strict permission expectations after restoring .ssh.
fix_ssh_permissions() {
  local ssh_dir="$HOME/.ssh"

  [[ -d "$ssh_dir" ]] || return

  log "Fixing SSH permissions"
  find "$ssh_dir" -type d -exec chmod 700 {} +
  find "$ssh_dir" -type f -name '*.pub' -exec chmod 644 {} +
  find "$ssh_dir" -type f ! -name '*.pub' -exec chmod 600 {} +
}

# Move an existing target aside before restore instead of overwriting it in place.
snapshot_existing_target() {
  local target="$1"
  local snapshot="$target-pre-restore-$RESTORE_ID"

  [[ -e "$target" ]] || return
  [[ ! -e "$snapshot" ]] || die "snapshot already exists: $snapshot"

  log "Moving existing target to safety snapshot: $snapshot"
  mv -- "$target" "$snapshot"
}

parse_common_args "$@"
if [[ "${SCRIPT_ARGS[0]:-}" == "-h" || "${SCRIPT_ARGS[0]:-}" == "--help" ]]; then
  usage
  exit 0
fi

preflight_checks
setup_cleanup_trap

# Show the restore source and target before asking for confirmation.
log "Restore source: $SCRIPT_DIR"
log "Restore target: $HOME"

# Require explicit confirmation before copying anything into $HOME.
if ! confirm_yes_no "Start restore from current folder to \$HOME?" "N"; then
  log "Restore cancelled"
  exit 0
fi

# Restore each available backup item into $HOME while preserving metadata.
for item in "${HOME_ITEMS[@]}"; do
  source_path="$SCRIPT_DIR/$item"

  if [[ -e "$source_path" ]]; then
    log "Restoring: $item"
    snapshot_existing_target "$HOME/$item"
    rsync_restore_copy "$source_path" "$HOME/"
  else
    log "Skipping missing backup item: $item"
  fi
done

# Normalize SSH file modes after rsync completes.
fix_ssh_permissions
log "Done: restore-main"
