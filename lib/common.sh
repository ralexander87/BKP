#!/usr/bin/env bash

# Shared scripts fail fast on errors, unset variables, and failed pipelines.
set -Eeuo pipefail

# Resolve project paths relative to this helper file.
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT="${LOG_ROOT:-$PROJECT_ROOT/logs}"
QUIET="${QUIET:-false}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
SCRIPT_NAME="${SCRIPT_NAME:-$(basename -- "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")}"
UI_ENABLED=false
UI_STARTED_AT=""
UI_LAST_RENDER_TS=0
UI_RENDER_MIN_INTERVAL=1
UI_FINAL_STATE=""
UI_FINAL_MESSAGE=""
UI_LAST_ERROR_TEXT=""
UI_ACTIVE_TASK_ID=""
declare -a UI_META_LINES=()
declare -a UI_TASK_ORDER=()
declare -a UI_MESSAGES=()
declare -A UI_TASK_LABELS=()
declare -A UI_TASK_STATUS=()
declare -A UI_TASK_DETAIL=()
declare -A UI_TASK_SEPARATOR_AFTER=()

# Shared rsync argument profiles for backup and restore operations.
RSYNC_BACKUP_ARGS=(-aAXH --numeric-ids --info=progress2)
RSYNC_RESTORE_ARGS=(-aAXH --numeric-ids --info=progress2)
TEMP_PATHS=()

# Convert log level names to comparable numeric severity.
log_level_value() {
  case "${1^^}" in
  DEBUG) printf '10\n' ;;
  INFO) printf '20\n' ;;
  WARN) printf '30\n' ;;
  ERROR) printf '40\n' ;;
  *) printf '20\n' ;;
  esac
}

# Write a timestamped log entry to LOG_FILE and a clean entry to stdout.
log_message() {
  local level="${1^^}"
  shift
  local text="$*"
  local ts line cli_line

  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  line="[$ts] [$level] [$SCRIPT_NAME] $text"
  cli_line="[$level] $text"
  if [[ "$level" == "ERROR" ]]; then
    UI_LAST_ERROR_TEXT="$text"
  fi

  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi

  if [[ "$UI_ENABLED" == "true" ]]; then
    if [[ "$level" == "WARN" || "$level" == "ERROR" ]]; then
      ui_add_message "$level" "$text"
      ui_render "force"
    fi
    return 0
  fi

  if [[ "$QUIET" != "true" || "$level" != "INFO" ]]; then
    printf '%s\n' "$cli_line"
  fi
}

# Write an INFO log entry.
log_info() {
  [[ "$(log_level_value "INFO")" -lt "$(log_level_value "$LOG_LEVEL")" ]] && return 0
  log_message "INFO" "$*"
}

# Write a WARN log entry.
log_warn() {
  [[ "$(log_level_value "WARN")" -lt "$(log_level_value "$LOG_LEVEL")" ]] && return 0
  log_message "WARN" "$*"
}

# Write an ERROR log entry.
log_error() {
  [[ "$(log_level_value "ERROR")" -lt "$(log_level_value "$LOG_LEVEL")" ]] && return 0
  log_message "ERROR" "$*"
}

# Backwards-compatible log alias used by existing scripts.
log() {
  log_info "$*"
}

# Log an error and stop the active script.
die() {
  log_error "$*"
  exit 1
}

# Ensure an external command exists before it is needed.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Ensure all listed commands exist before continuing.
require_all_cmds() {
  local cmd
  for cmd in "$@"; do
    require_cmd "$cmd"
  done
}

# Create the local log directory used by scripts.
ensure_dirs() {
  mkdir -p "$LOG_ROOT"
}

# Generate the backup timestamp used in BKP folder names.
timestamp() {
  date '+%j-%d-%m-%H-%M-%S'
}

# Convert a byte count into a compact human-readable size.
human_bytes() {
  local bytes="$1"

  numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || printf '%sB\n' "$bytes"
}

# Return the current repository commit when Git metadata is available.
git_short_commit() {
  if command -v git >/dev/null 2>&1; then
    git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown\n'
  else
    printf 'unknown\n'
  fi
}

# Format a boolean value for human-readable manifests.
manifest_bool() {
  case "${1,,}" in
  true | yes | 1) printf '[TRUE]\n' ;;
  *) printf '[FALSE]\n' ;;
  esac
}

# Format a presence marker for human-readable manifests.
manifest_presence() {
  case "${1,,}" in
  present | true | yes | 1) printf '[PRESENT]\n' ;;
  *) printf '[MISSING]\n' ;;
  esac
}

# Format a backup/run status for human-readable manifests.
manifest_status() {
  case "${1,,}" in
  complete | completed | success | successful) printf '[COMPLETED]\n' ;;
  in_progress | in-progress | running) printf '[IN PROGRESS]\n' ;;
  failed | fail | error) printf '[FAILED]\n' ;;
  *) printf '[%s]\n' "${1^^}" ;;
  esac
}

# Write one human-readable manifest field.
manifest_field() {
  local key="$1"
  local value="${2:-}"

  printf '%s = %s\n' "$key" "$value"
}

# Estimate a readable path's size in bytes; missing paths count as zero.
path_size_bytes() {
  local path="$1"

  [[ -e "$path" ]] || {
    printf '0\n'
    return
  }

  du -sb "$path" 2>/dev/null | awk '{ print $1 }'
}

# Estimate a root-owned path's size in bytes; missing paths count as zero.
sudo_path_size_bytes() {
  local path="$1"

  sudo test -e "$path" || {
    printf '0\n'
    return
  }

  sudo du -sb "$path" 2>/dev/null | awk '{ print $1 }'
}

# Warn when destination free space is lower than an already-computed source size.
check_destination_space_for_size() {
  local destination="$1"
  local required="$2"
  local available

  require_cmd df
  available="$(df -PB1 "$destination" | awk 'NR == 2 { print $4 }')"

  log "Estimated source size: $(human_bytes "$required")"
  log "Destination free space: $(human_bytes "$available")"

  if ((required > available)); then
    log_warn "estimated backup size is larger than available destination space"
    confirm_yes_no "Continue anyway?" "N" || die "backup cancelled because destination may be too small"
  fi
}

# Print manifest fields shared by main and service backups.
write_common_manifest_fields() {
  local backup_type="$1"
  local backup_type_label

  case "${backup_type,,}" in
  main) backup_type_label="MAIN" ;;
  serv | service) backup_type_label="SERVICE" ;;
  *) backup_type_label="${backup_type^^}" ;;
  esac

  manifest_field "Backup Type" "[$backup_type_label]"
  manifest_field "Created" "$(date -Is)"
  manifest_field "Hostname" "$(system_hostname)"
  manifest_field "Username" "${USER:-unknown}"
  manifest_field "Project root" "$PROJECT_ROOT"
  manifest_field "GIT Commit" "$(git_short_commit)"
  manifest_field "Destination Device" "$DEST_DEVICE"
  manifest_field "Backup Dir" "$BACKUP_DIR"
  manifest_field "Archive Requested" "$(manifest_bool "$CREATE_ARCHIVE")"
  manifest_field "Archive Path" "$ARCHIVE_NAME"
  manifest_field "Backup Status" "$(manifest_status "$RUN_RESULT")"
  manifest_field "Run Result" "$(manifest_status "$RUN_RESULT")"
}

# Update a backup run status and persist it through the script's manifest writer.
set_backup_status() {
  local status="$1"

  RUN_RESULT="$status"
  write_manifest
}

# Return the final manifest status for a backup script at process exit.
backup_final_status() {
  local exit_code="$1"

  if [[ "$BACKUP_COMPLETE" == "true" && "$exit_code" -eq 0 ]]; then
    printf 'complete\n'
  else
    printf 'failed\n'
  fi
}

# Parse shared flags and leave script-specific args in SCRIPT_ARGS.
parse_common_args() {
  local arg
  SCRIPT_ARGS=()
  for arg in "$@"; do
    case "$arg" in
    -q | --quiet)
      QUIET=true
      ;;
    *)
      SCRIPT_ARGS+=("$arg")
      ;;
    esac
  done
}

# Register a temp path to be cleaned up on script exit.
register_temp_path() {
  TEMP_PATHS+=("$1")
}

# Remove temporary files/directories that were registered by the script.
cleanup_temp_paths() {
  local p
  for p in "${TEMP_PATHS[@]}"; do
    [[ -e "$p" ]] && rm -rf -- "$p"
  done
}

# Add a cleanup trap for temp paths and terminal UI teardown.
setup_cleanup_trap() {
  trap 'cleanup_temp_paths; ui_cleanup' EXIT
}

# Run rsync using the standard backup profile.
rsync_backup_copy() {
  rsync "${RSYNC_BACKUP_ARGS[@]}" "$@"
}

# Run rsync using the standard restore profile.
rsync_restore_copy() {
  rsync "${RSYNC_RESTORE_ARGS[@]}" "$@"
}

# Run rsync with sudo using the standard backup profile.
sudo_rsync_backup_copy() {
  sudo rsync "${RSYNC_BACKUP_ARGS[@]}" "$@"
}

# Run rsync with sudo using the standard restore profile.
sudo_rsync_restore_copy() {
  sudo rsync "${RSYNC_RESTORE_ARGS[@]}" "$@"
}

# Resolve the current host name, preferring hostnamectl on systemd-based hosts.
system_hostname() {
  local name=""

  if command -v hostnamectl >/dev/null 2>&1; then
    name="$(hostnamectl --static 2>/dev/null || true)"
    [[ -n "$name" ]] || name="$(hostnamectl --transient 2>/dev/null || true)"
  fi

  [[ -n "$name" ]] || name="${HOSTNAME:-unknown}"
  printf '%s\n' "$name"
}

# Decode findmnt's escaped path bytes, for example "\x20" in mount names.
decode_findmnt_path() {
  printf '%b' "$1"
}

# Show a mounted device by mount label-style basename instead of the full mount path.
display_mount_target() {
  local target="$1"

  printf '/%s\n' "$(basename -- "$target")"
}

# Format one mounted-device line for prompts.
format_mount_option() {
  local target="$1"
  local source="$2"
  local fstype="$3"
  local label="$4"
  local avail="$5"

  printf '%s [%s, %s, label: %s, %s]\n' "$(display_mount_target "$target")" "$source" "$fstype" "$label" "$avail"
}

# Return likely external/removable mount details from real block devices.
list_external_mounts() {
  require_cmd findmnt

  findmnt -rn -o TARGET,SOURCE,FSTYPE |
    awk '
      $2 ~ "^/dev/" &&
      $1 ~ "^(/media/|/run/media/|/mnt/)" &&
      $3 !~ "^(swap|tmpfs|devtmpfs|proc|sysfs|cgroup|cgroup2|overlay|squashfs)$" {
        print $1 "|" $2 "|" $3
      }
    ' |
    while IFS='|' read -r target source fstype; do
      local label avail
      target="$(decode_findmnt_path "$target")"
      source="$(decode_findmnt_path "$source")"
      label="-"
      if command -v lsblk >/dev/null 2>&1; then
        label="$(lsblk -no LABEL "$source" 2>/dev/null | head -n 1 || true)"
        label="${label:-"-"}"
      fi
      avail="$(df -hP "$target" 2>/dev/null | awk 'NR == 2 { print $4 " free" }' || true)"
      avail="${avail:-"unknown free"}"
      printf '%s|%s|%s|%s|%s\n' "$target" "$source" "$fstype" "$label" "$avail"
    done
}

# Select an external mount automatically when one exists, or prompt by number.
select_external_mount() {
  local prompt="${1:-Select destination device}"
  local mounts=()

  mapfile -t mounts < <(list_external_mounts)

  case "${#mounts[@]}" in
  0)
    die "no external mounted devices found"
    ;;
  1)
    IFS='|' read -r target source fstype label avail <<<"${mounts[0]}"
    printf -- '- Mounted device: %s\n' "$(format_mount_option "$target" "$source" "$fstype" "$label" "$avail")" >&2
    printf '%s\n' "$target"
    ;;
  *)
    printf '%s\n' "$prompt" >&2
    local i
    for i in "${!mounts[@]}"; do
      IFS='|' read -r target source fstype label avail <<<"${mounts[$i]}"
      printf '  %d - %s\n' "$((i + 1))" "$(format_mount_option "$target" "$source" "$fstype" "$label" "$avail")" >&2
    done

    local selection
    while true; do
      read -r -p "Enter number and press Enter: " selection
      if [[ "$selection" =~ ^[0-9]+$ ]] &&
        ((selection >= 1 && selection <= ${#mounts[@]})); then
        IFS='|' read -r target source fstype label avail <<<"${mounts[$((selection - 1))]}"
        printf -- '- Mounted device: %s\n' "$(format_mount_option "$target" "$source" "$fstype" "$label" "$avail")" >&2
        printf '%s\n' "$target"
        return 0
      fi
      printf 'Invalid selection.\n' >&2
    done
    ;;
  esac
}

# Ask a yes/no question; pressing Enter uses the provided default.
confirm_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer

  read -r -p "$prompt [$default]: " answer
  answer="${answer:-$default}"
  answer="$(printf '%s' "$answer" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"

  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

# Render a lightweight terminal dashboard for backup scripts.
ui_init() {
  UI_STARTED_AT="$(date '+%H:%M:%S')"
  UI_LAST_RENDER_TS=0
  UI_META_LINES=()
  UI_TASK_ORDER=()
  UI_MESSAGES=()
  UI_TASK_LABELS=()
  UI_TASK_STATUS=()
  UI_TASK_DETAIL=()
  UI_TASK_SEPARATOR_AFTER=()
  UI_FINAL_STATE=""
  UI_FINAL_MESSAGE=""
  UI_LAST_ERROR_TEXT=""
  UI_ACTIVE_TASK_ID=""

  if [[ "$QUIET" == "true" || ! -t 1 ]]; then
    UI_ENABLED=false
    return 0
  fi

  UI_ENABLED=true
  RSYNC_BACKUP_ARGS=(-aAXH --numeric-ids)
  RSYNC_RESTORE_ARGS=(-aAXH --numeric-ids)
  tput civis 2>/dev/null || true
}

# Restore terminal cursor state after dashboard usage.
ui_cleanup() {
  if [[ "$UI_ENABLED" == "true" ]]; then
    tput cnorm 2>/dev/null || true
    printf '\n'
  fi
}

# Add one selected-option row in the dashboard header.
ui_add_meta() {
  local key="$1"
  local value="$2"
  UI_META_LINES+=("$key|$value")
}

# Add a dashboard task row.
ui_add_task() {
  local task_id="$1"
  local label="$2"
  local status="${3:-PENDING}"
  local detail="${4:-waiting}"

  UI_TASK_ORDER+=("$task_id")
  UI_TASK_LABELS["$task_id"]="$label"
  UI_TASK_STATUS["$task_id"]="$status"
  UI_TASK_DETAIL["$task_id"]="$detail"
}

# Draw a separator line after a dashboard task row.
ui_add_task_separator_after() {
  local task_id="$1"
  local label="${2:-true}"
  UI_TASK_SEPARATOR_AFTER["$task_id"]="$label"
}

# Update status and detail for an existing dashboard task.
ui_update_task() {
  local task_id="$1"
  local status="$2"
  local detail="${3:-}"

  [[ -n "${UI_TASK_LABELS[$task_id]:-}" ]] || return 0
  UI_TASK_STATUS["$task_id"]="$status"
  [[ -n "$detail" ]] && UI_TASK_DETAIL["$task_id"]="$detail"
  if [[ "$status" == "RUNNING" ]]; then
    UI_ACTIVE_TASK_ID="$task_id"
  elif [[ "$UI_ACTIVE_TASK_ID" == "$task_id" ]]; then
    UI_ACTIVE_TASK_ID=""
  fi
}

# Store warning/error lines visible at bottom of dashboard.
ui_add_message() {
  local level="$1"
  local text="$2"

  UI_MESSAGES+=("[$level] $text")
  if [[ "${#UI_MESSAGES[@]}" -gt 4 ]]; then
    UI_MESSAGES=("${UI_MESSAGES[@]: -4}")
  fi
}

# Repeat a character without relying on external formatting helpers.
ui_repeat_char() {
  local char="$1"
  local count="$2"

  printf '%*s' "$count" '' | tr ' ' "$char"
}

# Print a centered tilde-dashboard heading.
ui_tilde_heading() {
  local title="$1"
  local width=60
  local text=" $title "
  local fill=$((width - ${#text}))
  local left=$((fill / 2))
  local right=$((fill - left))

  ((fill < 0)) && {
    printf '%s\n' "$title"
    return 0
  }

  printf '%s%s%s\n' "$(ui_repeat_char '~' "$left")" "$text" "$(ui_repeat_char '~' "$right")"
}

# Convert internal task statuses to tilde-dashboard labels.
ui_tilde_status_label() {
  local status="$1"

  case "$status" in
  DONE) printf 'OK/DONE\n' ;;
  ERROR) printf 'FAILED\n' ;;
  RUNNING) printf 'RUNNING\n' ;;
  SKIPPED) printf 'SKIPPED\n' ;;
  *) printf 'PENDING\n' ;;
  esac
}

# Keep running-row details compact without changing logs or command paths.
ui_tilde_detail() {
  local status="$1"
  local detail="$2"
  local suffix=""
  local action=""
  local target=""

  if [[ "$status" != "RUNNING" ]]; then
    printf '%s\n' "${detail^^}"
    return 0
  fi

  if [[ "$detail" =~ (.*)(\ \([0-9]+s\))$ ]]; then
    detail="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
  fi

  case "$detail" in
  "copying from "*)
    action="COPY"
    target="${detail#copying from }"
    ;;
  "copying "*)
    action="COPY"
    target="${detail#copying }"
    ;;
  "reading header from "*)
    action="READ"
    target="${detail#reading header from }"
    ;;
  "scanning "*)
    action="SCAN"
    target="${detail#scanning }"
    ;;
  "writing "*)
    action="WRITE"
    target="${detail#writing }"
    ;;
  "compressing "*)
    action="COMPRESS"
    target="${detail#compressing }"
    ;;
  *)
    printf '%s%s\n' "${detail^^}" "$suffix"
    return 0
    ;;
  esac

  if [[ -n "${HOME:-}" && "$target" == "$HOME"* ]]; then
    target="${target#"$HOME"}"
    [[ -n "$target" ]] || target="/"
  elif [[ "$target" != /* ]]; then
    target="${target^^}"
  fi

  printf '%s: %s%s\n' "$action" "$target" "$suffix"
}

# Render the tilde backup dashboard style.
ui_render_tilde() {
  local line task_id status_raw status_label detail_raw
  local backup_label="${UI_BACKUP_LABEL:-SERVICE}"
  local done=0 running=0 skipped=0 failed=0 pending=0 total=0

  for task_id in "${UI_TASK_ORDER[@]}"; do
    case "${UI_TASK_STATUS[$task_id]}" in
    DONE) ((done += 1)) ;;
    RUNNING) ((running += 1)) ;;
    SKIPPED) ((skipped += 1)) ;;
    ERROR) ((failed += 1)) ;;
    *) ((pending += 1)) ;;
    esac
  done
  total="${#UI_TASK_ORDER[@]}"

  printf '\033[H\033[2J'
  ui_tilde_heading "Metric | Value"
  printf 'Total = %-3s | Done = %-3s | Running = %s\n' "$total" "$done" "$running"
  printf 'Skipped = %s | Errors = %s | Pending = %s\n' "$skipped" "$failed" "$pending"

  printf '\n'
  ui_tilde_heading "Selected Options"
  printf '%-18s | %s\n' "Option" "Value"
  printf '%s+%s\n' "$(ui_repeat_char '~' 19)" "$(ui_repeat_char '~' 40)"
  for line in "${UI_META_LINES[@]}"; do
    printf '%-18s | %s\n' "${line%%|*}" "${line#*|}"
  done

  printf '\n'
  ui_tilde_heading "Task"
  printf '%-3s | %-24s | %-8s | %s\n' "#" "Item" "Status" "Details"
  printf '%s+%s+%s+%s\n' \
    "$(ui_repeat_char '~' 4)" \
    "$(ui_repeat_char '~' 26)" \
    "$(ui_repeat_char '~' 10)" \
    "$(ui_repeat_char '~' 17)"
  local i=1
  for task_id in "${UI_TASK_ORDER[@]}"; do
    status_raw="${UI_TASK_STATUS[$task_id]}"
    status_label="$(ui_tilde_status_label "$status_raw")"
    detail_raw="$(ui_tilde_detail "$status_raw" "${UI_TASK_DETAIL[$task_id]}")"
    detail_raw="${detail_raw:0:80}"
    printf '%-3d | %-24s | %-8s | %s\n' \
      "$i" \
      "${UI_TASK_LABELS[$task_id]:0:24}" \
      "$status_label" \
      "$detail_raw"
    if [[ -n "${UI_TASK_SEPARATOR_AFTER[$task_id]:-}" && "${UI_TASK_SEPARATOR_AFTER[$task_id]}" != "true" ]]; then
      ui_tilde_heading "${UI_TASK_SEPARATOR_AFTER[$task_id]}"
    fi
    ((i += 1))
  done
  printf '%s\n' "$(ui_repeat_char '~' 60)"

  printf '\n'
  ui_tilde_heading "Recent Warnings/Errors"
  if [[ -n "$UI_FINAL_STATE" ]]; then
    if [[ "$UI_FINAL_STATE" == "SUCCESS" ]]; then
      printf '[INFO] : SUCCESS... %s backup COMPLETED\n' "$backup_label"
      printf '[ERROR]: No Error Occurred\n'
    else
      local short_error="${UI_LAST_ERROR_TEXT:-Unknown Error}"
      short_error="${short_error%%$'\n'*}"
      [[ "${#short_error}" -gt 54 ]] && short_error="${short_error:0:54}"
      printf '[INFO] : SUCCESS... %s backup ERROR!!!\n' "$backup_label"
      printf '[ERROR]: %s\n' "$short_error"
    fi
  elif [[ "${#UI_MESSAGES[@]}" -gt 0 ]]; then
    for line in "${UI_MESSAGES[@]}"; do
      printf '%s\n' "$line"
    done
  else
    printf '[INFO] : %s backup running\n' "$backup_label"
    printf '[ERROR]: No Error Occurred\n'
  fi
  printf '%s\n' "$(ui_repeat_char '~' 60)"
}

# Draw dashboard if enabled (rate-limited unless forced).
ui_render() {
  local mode="${1:-}"
  local now

  [[ "$UI_ENABLED" == "true" ]] || return 0

  now="$(date +%s)"
  if [[ "$mode" != "force" ]] && ((now - UI_LAST_RENDER_TS < UI_RENDER_MIN_INTERVAL)); then
    return 0
  fi
  UI_LAST_RENDER_TS="$now"
  ui_render_tilde
}

# Record failed command context in the dashboard and logs.
ui_report_error() {
  local line_no="$1"
  local cmd="$2"
  if [[ -n "${UI_ACTIVE_TASK_ID:-}" ]]; then
    ui_update_task "$UI_ACTIVE_TASK_ID" "ERROR" "failed"
  fi
  log_error "command failed at line $line_no: $cmd"
}

# Set final panel state and force one full render.
ui_finalize() {
  local state="$1"
  local message="${2:-}"
  UI_FINAL_STATE="$state"
  UI_FINAL_MESSAGE="$message"
  ui_render "force"
}

# Compute task counters from the current dashboard state.
ui_compute_counts() {
  UI_COUNT_TOTAL=0
  UI_COUNT_DONE=0
  UI_COUNT_RUNNING=0
  UI_COUNT_SKIPPED=0
  UI_COUNT_ERRORS=0
  UI_COUNT_PENDING=0

  local task_id status
  for task_id in "${UI_TASK_ORDER[@]}"; do
    status="${UI_TASK_STATUS[$task_id]}"
    ((UI_COUNT_TOTAL += 1))
    case "$status" in
    DONE) ((UI_COUNT_DONE += 1)) ;;
    RUNNING) ((UI_COUNT_RUNNING += 1)) ;;
    SKIPPED) ((UI_COUNT_SKIPPED += 1)) ;;
    ERROR) ((UI_COUNT_ERRORS += 1)) ;;
    *) ((UI_COUNT_PENDING += 1)) ;;
    esac
  done
}

# Build one-line message summary from recent warning/error list.
ui_messages_summary() {
  if [[ "${#UI_MESSAGES[@]}" -eq 0 ]]; then
    printf 'none\n'
    return 0
  fi

  local joined
  joined="$(printf '%s || ' "${UI_MESSAGES[@]}")"
  joined="${joined% || }"
  printf '%s\n' "$joined"
}

# Append final dashboard status snapshot into a manifest-style file.
ui_append_final_status() {
  local output_file="$1"
  local finished_at messages

  [[ -n "$output_file" ]] || return 0
  [[ -f "$output_file" ]] || return 0

  ui_compute_counts
  finished_at="$(date -Is)"
  messages="$(ui_messages_summary)"

  {
    printf '\n'
    manifest_field "UI Final State" "$(manifest_status "${UI_FINAL_STATE:-unknown}")"
    manifest_field "UI Final Message" "${UI_FINAL_MESSAGE:-none}"
    manifest_field "UI Started At" "${UI_STARTED_AT:-unknown}"
    manifest_field "UI Finished At" "$finished_at"
    manifest_field "UI Total Tasks" "$UI_COUNT_TOTAL"
    manifest_field "UI Done" "$UI_COUNT_DONE"
    manifest_field "UI Running" "$UI_COUNT_RUNNING"
    manifest_field "UI Skipped" "$UI_COUNT_SKIPPED"
    manifest_field "UI Errors" "$UI_COUNT_ERRORS"
    manifest_field "UI Pending" "$UI_COUNT_PENDING"
    manifest_field "UI Recent Messages" "$messages"
    manifest_field "UI Last Error" "${UI_LAST_ERROR_TEXT:-none}"
  } >>"$output_file"
}

# Write final dashboard status snapshot to logs in one compact line.
log_ui_final_status() {
  ui_compute_counts
  log_info "Final UI status: state=${UI_FINAL_STATE:-unknown} total=$UI_COUNT_TOTAL done=$UI_COUNT_DONE running=$UI_COUNT_RUNNING skipped=$UI_COUNT_SKIPPED errors=$UI_COUNT_ERRORS pending=$UI_COUNT_PENDING"
}

# Run a command while refreshing a task row every second until it finishes.
ui_run_command() {
  local task_id="$1"
  local detail="$2"
  shift 2
  local pid start now elapsed exit_code

  if [[ "$UI_ENABLED" != "true" ]]; then
    "$@"
    return 0
  fi

  start="$(date +%s)"
  "$@" &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"
    elapsed=$((now - start))
    ui_update_task "$task_id" "RUNNING" "$detail (${elapsed}s)"
    ui_render "force"
    sleep 1
  done

  if wait "$pid"; then
    return 0
  fi

  exit_code="$?"
  ui_update_task "$task_id" "ERROR" "failed (exit $exit_code)"
  ui_add_message "ERROR" "Task ${UI_TASK_LABELS[$task_id]:-$task_id} failed (exit $exit_code)"
  ui_render "force"
  return "$exit_code"
}
