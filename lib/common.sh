#!/usr/bin/env bash

# Shared scripts fail fast on errors, unset variables, and failed pipelines.
set -Eeuo pipefail

# Resolve project paths relative to this helper file.
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$PROJECT_ROOT/backups}"
LOG_ROOT="${LOG_ROOT:-$PROJECT_ROOT/logs}"
QUIET="${QUIET:-false}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
SCRIPT_NAME="${SCRIPT_NAME:-$(basename -- "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")}"
UI_ENABLED=false
UI_TITLE=""
UI_STARTED_AT=""
UI_LAST_RENDER_TS=0
UI_RENDER_MIN_INTERVAL=1
UI_USE_COLOR=false
UI_COLOR_RESET=""
UI_COLOR_TITLE=""
UI_COLOR_INFO=""
UI_COLOR_WARN=""
UI_COLOR_ERROR=""
UI_COLOR_DONE=""
UI_COLOR_RUNNING=""
UI_COLOR_PENDING=""
UI_COLOR_SKIPPED=""
UI_FINAL_STATE=""
UI_FINAL_MESSAGE=""
declare -a UI_META_LINES=()
declare -a UI_TASK_ORDER=()
declare -a UI_MESSAGES=()
declare -A UI_TASK_LABELS=()
declare -A UI_TASK_STATUS=()
declare -A UI_TASK_DETAIL=()

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

# Write a timestamped log entry to LOG_FILE and optionally to stdout.
log_message() {
  local level="${1^^}"
  shift
  local text="$*"
  local ts line

  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  line="[$ts] [$level] [$SCRIPT_NAME] $text"

  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi

  if [[ "$UI_ENABLED" == "true" ]]; then
    if [[ "$level" == "WARN" || "$level" == "ERROR" ]]; then
      ui_add_message "$level" "$text"
      ui_render "force"
    fi
    return
  fi

  if [[ "$QUIET" != "true" || "$level" != "INFO" ]]; then
    printf '%s\n' "$line"
  fi
}

# Write an INFO log entry.
log_info() {
  [[ "$(log_level_value "INFO")" -lt "$(log_level_value "$LOG_LEVEL")" ]] && return
  log_message "INFO" "$*"
}

# Write a WARN log entry.
log_warn() {
  [[ "$(log_level_value "WARN")" -lt "$(log_level_value "$LOG_LEVEL")" ]] && return
  log_message "WARN" "$*"
}

# Write an ERROR log entry.
log_error() {
  [[ "$(log_level_value "ERROR")" -lt "$(log_level_value "$LOG_LEVEL")" ]] && return
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

# Create local runtime directories used by scripts.
ensure_dirs() {
  mkdir -p "$BACKUP_ROOT" "$LOG_ROOT"
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

# Return likely external/removable mount details from real block devices.
list_external_mounts() {
  require_cmd findmnt

  findmnt -rn -o TARGET,SOURCE,FSTYPE |
    awk '
      $2 ~ "^/dev/" &&
      $1 ~ "^(/media/|/run/media/|/mnt/)" &&
      $3 !~ "^(swap|tmpfs|devtmpfs|proc|sysfs|cgroup|cgroup2|overlay|squashfs)$" {
        print $1
      }
    ' |
    while IFS= read -r target; do
      local source fstype label avail
      source="$(findmnt -rn -o SOURCE --target "$target")"
      fstype="$(findmnt -rn -o FSTYPE --target "$target")"
      label="-"
      if command -v lsblk >/dev/null 2>&1; then
        label="$(lsblk -no LABEL "$source" 2>/dev/null | head -n 1)"
        label="${label:-"-"}"
      fi
      avail="$(df -hP "$target" 2>/dev/null | awk 'NR == 2 { print $4 " free" }')"
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
    printf 'Using mounted device: %s (%s, %s, label: %s, %s)\n' "$target" "$source" "$fstype" "$label" "$avail" >&2
    printf '%s\n' "$target"
    ;;
  *)
    printf '%s\n' "$prompt" >&2
    local i
    for i in "${!mounts[@]}"; do
      IFS='|' read -r target source fstype label avail <<<"${mounts[$i]}"
      printf '  %d) %s (%s, %s, label: %s, %s)\n' "$((i + 1))" "$target" "$source" "$fstype" "$label" "$avail" >&2
    done

    local selection
    while true; do
      read -r -p "Enter number and press Enter: " selection
      if [[ "$selection" =~ ^[0-9]+$ ]] &&
        ((selection >= 1 && selection <= ${#mounts[@]})); then
        IFS='|' read -r target _ <<<"${mounts[$((selection - 1))]}"
        printf '%s\n' "$target"
        return
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
  UI_TITLE="$1"
  UI_STARTED_AT="$(date '+%H:%M:%S')"
  UI_LAST_RENDER_TS=0
  UI_META_LINES=()
  UI_TASK_ORDER=()
  UI_MESSAGES=()
  UI_TASK_LABELS=()
  UI_TASK_STATUS=()
  UI_TASK_DETAIL=()
  UI_FINAL_STATE=""
  UI_FINAL_MESSAGE=""

  if [[ "$QUIET" == "true" || ! -t 1 ]]; then
    UI_ENABLED=false
    return
  fi

  UI_ENABLED=true
  if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    UI_USE_COLOR=true
    UI_COLOR_RESET=$'\033[0m'
    UI_COLOR_TITLE=$'\033[1;36m'
    UI_COLOR_INFO=$'\033[0;37m'
    UI_COLOR_WARN=$'\033[38;5;208m'
    UI_COLOR_ERROR=$'\033[1;91m'
    UI_COLOR_DONE=$'\033[1;92m'
    UI_COLOR_RUNNING=$'\033[1;96m'
    UI_COLOR_PENDING=$'\033[0;37m'
    UI_COLOR_SKIPPED=$'\033[38;5;208m'
  fi
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

# Update status and detail for an existing dashboard task.
ui_update_task() {
  local task_id="$1"
  local status="$2"
  local detail="${3:-}"

  [[ -n "${UI_TASK_LABELS[$task_id]:-}" ]] || return
  UI_TASK_STATUS["$task_id"]="$status"
  [[ -n "$detail" ]] && UI_TASK_DETAIL["$task_id"]="$detail"
}

# Store warning/error lines visible at bottom of dashboard.
ui_add_message() {
  local level="$1"
  local text="$2"
  local ts

  ts="$(date '+%H:%M:%S')"
  UI_MESSAGES+=("[$ts] [$level] $text")
  if [[ "${#UI_MESSAGES[@]}" -gt 4 ]]; then
    UI_MESSAGES=("${UI_MESSAGES[@]: -4}")
  fi
}

# Apply a color code to text only when dashboard colors are enabled.
ui_color() {
  local color="$1"
  local text="$2"
  if [[ "$UI_USE_COLOR" == "true" ]]; then
    printf '%s%s%s' "$color" "$text" "$UI_COLOR_RESET"
  else
    printf '%s' "$text"
  fi
}

# Return colorized status label used in task table.
ui_colorize_status() {
  local status="$1"
  case "$status" in
  DONE) ui_color "$UI_COLOR_DONE" "$status" ;;
  RUNNING) ui_color "$UI_COLOR_RUNNING" "$status" ;;
  SKIPPED) ui_color "$UI_COLOR_SKIPPED" "$status" ;;
  ERROR) ui_color "$UI_COLOR_ERROR" "$status" ;;
  *) ui_color "$UI_COLOR_PENDING" "$status" ;;
  esac
}

# Render padded status text so colors stay visible and stable in the status column.
ui_status_cell() {
  local status="$1"
  local padded
  padded="$(printf '%-8s' "$status")"
  case "$status" in
  DONE) ui_color "$UI_COLOR_DONE" "$padded" ;;
  RUNNING) ui_color "$UI_COLOR_RUNNING" "$padded" ;;
  SKIPPED) ui_color "$UI_COLOR_SKIPPED" "$padded" ;;
  ERROR) ui_color "$UI_COLOR_ERROR" "$padded" ;;
  *) ui_color "$UI_COLOR_PENDING" "$padded" ;;
  esac
}

# Colorize details text with the same semantic color as the task status.
ui_colorize_detail() {
  local status="$1"
  local detail="$2"
  case "$status" in
  DONE) ui_color "$UI_COLOR_DONE" "$detail" ;;
  RUNNING) ui_color "$UI_COLOR_RUNNING" "$detail" ;;
  SKIPPED) ui_color "$UI_COLOR_SKIPPED" "$detail" ;;
  ERROR) ui_color "$UI_COLOR_ERROR" "$detail" ;;
  *) ui_color "$UI_COLOR_PENDING" "$detail" ;;
  esac
}

# Colorize metric values in the top progress table.
ui_metric_value() {
  local key="$1"
  local value="$2"

  case "$key" in
  Done)
    ui_color "$UI_COLOR_DONE" "$value"
    ;;
  Running)
    ui_color "$UI_COLOR_RUNNING" "$value"
    ;;
  Skipped)
    ui_color "$UI_COLOR_SKIPPED" "$value"
    ;;
  Errors)
    ui_color "$UI_COLOR_ERROR" "$value"
    ;;
  Pending)
    ui_color "$UI_COLOR_PENDING" "$value"
    ;;
  *)
    ui_color "$UI_COLOR_INFO" "$value"
    ;;
  esac
}

# Draw dashboard if enabled (rate-limited unless forced).
ui_render() {
  local mode="${1:-}"
  local now
  local line
  local task_id
  local done=0 running=0 skipped=0 failed=0 pending=0 total=0

  [[ "$UI_ENABLED" == "true" ]] || return

  now="$(date +%s)"
  if [[ "$mode" != "force" ]] && ((now - UI_LAST_RENDER_TS < UI_RENDER_MIN_INTERVAL)); then
    return
  fi
  UI_LAST_RENDER_TS="$now"

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
  printf '%s\n' "$(ui_color "$UI_COLOR_TITLE" "=== $UI_TITLE ===")"
  printf 'Run Metrics\n'
  printf '%-16s | %s\n' "Metric" "Value"
  printf '%-16s-+-%s\n' "----------------" "------------------------------"
  printf '%-16s | %s\n' "Started" "$(ui_metric_value "Started" "$UI_STARTED_AT")"
  printf '%-16s | %s\n' "Time" "$(ui_metric_value "Time" "$(date '+%H:%M:%S')")"
  printf '%-16s | %s\n' "Total" "$(ui_metric_value "Total" "$total")"
  printf '%-16s | %s\n' "Done" "$(ui_metric_value "Done" "$done")"
  printf '%-16s | %s\n' "Running" "$(ui_metric_value "Running" "$running")"
  printf '%-16s | %s\n' "Skipped" "$(ui_metric_value "Skipped" "$skipped")"
  printf '%-16s | %s\n' "Errors" "$(ui_metric_value "Errors" "$failed")"
  printf '%-16s | %s\n' "Pending" "$(ui_metric_value "Pending" "$pending")"
  printf '\n'
  printf 'Selected Options\n'
  printf '%-18s | %s\n' "Option" "Value"
  printf '%-18s-+-%s\n' "------------------" "----------------------------------------------"
  for line in "${UI_META_LINES[@]}"; do
    printf '%-18s | %s\n' "${line%%|*}" "${line#*|}"
  done

  printf '\nTasks\n'
  printf '%-3s | %-24s | %-8s | %s\n' "#" "Item" "Status" "Details"
  printf '%-3s-+-%-24s-+-%-8s-+-%s\n' "---" "------------------------" "--------" "----------------------------------------------"
  local i=1
  local status_raw detail_raw
  for task_id in "${UI_TASK_ORDER[@]}"; do
    status_raw="${UI_TASK_STATUS[$task_id]:0:8}"
    detail_raw="${UI_TASK_DETAIL[$task_id]:0:80}"
    printf '%-3d | %-24s | %s | %s\n' \
      "$i" \
      "${UI_TASK_LABELS[$task_id]:0:24}" \
      "$(ui_status_cell "$status_raw")" \
      "$(ui_colorize_detail "$status_raw" "$detail_raw")"
    ((i += 1))
  done

  if [[ "${#UI_MESSAGES[@]}" -gt 0 ]]; then
    printf '\nRecent Warnings/Errors\n'
    for line in "${UI_MESSAGES[@]}"; do
      if [[ "$line" == *"[ERROR]"* ]]; then
        printf '  %s\n' "$(ui_color "$UI_COLOR_ERROR" "$line")"
      elif [[ "$line" == *"[WARN]"* ]]; then
        printf '  %s\n' "$(ui_color "$UI_COLOR_WARN" "$line")"
      else
        printf '  %s\n' "$(ui_color "$UI_COLOR_INFO" "$line")"
      fi
    done
  fi

  if [[ -n "$UI_FINAL_STATE" ]]; then
    printf '\n'
    case "$UI_FINAL_STATE" in
    SUCCESS)
      printf '%s\n' "$(ui_color "$UI_COLOR_DONE" "Final Result: SUCCESS")"
      ;;
    FAILED)
      printf '%s\n' "$(ui_color "$UI_COLOR_ERROR" "Final Result: FAILED")"
      ;;
    *)
      printf 'Final Result: %s\n' "$UI_FINAL_STATE"
      ;;
    esac
    [[ -n "$UI_FINAL_MESSAGE" ]] && printf '%s\n' "$UI_FINAL_MESSAGE"
  fi
}

# Record failed command context in the dashboard and logs.
ui_report_error() {
  local line_no="$1"
  local cmd="$2"
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
    return
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

  [[ -n "$output_file" ]] || return
  [[ -f "$output_file" ]] || return

  ui_compute_counts
  finished_at="$(date -Is)"
  messages="$(ui_messages_summary)"

  {
    printf '\n'
    printf 'ui_final_state=%s\n' "${UI_FINAL_STATE:-unknown}"
    printf 'ui_final_message=%s\n' "${UI_FINAL_MESSAGE:-none}"
    printf 'ui_started_at=%s\n' "${UI_STARTED_AT:-unknown}"
    printf 'ui_finished_at=%s\n' "$finished_at"
    printf 'ui_total_tasks=%s\n' "$UI_COUNT_TOTAL"
    printf 'ui_done=%s\n' "$UI_COUNT_DONE"
    printf 'ui_running=%s\n' "$UI_COUNT_RUNNING"
    printf 'ui_skipped=%s\n' "$UI_COUNT_SKIPPED"
    printf 'ui_errors=%s\n' "$UI_COUNT_ERRORS"
    printf 'ui_pending=%s\n' "$UI_COUNT_PENDING"
    printf 'ui_recent_messages=%s\n' "$messages"
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
    return
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
