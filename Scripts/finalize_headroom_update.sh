#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR=""
STOP_SCRIPT=""
INSTALL_SCRIPT=""
LOG_FILE=""
REMOTE_COMMIT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir) SOURCE_DIR="$2"; shift 2 ;;
    --stop-script) STOP_SCRIPT="$2"; shift 2 ;;
    --install-script) INSTALL_SCRIPT="$2"; shift 2 ;;
    --log-file) LOG_FILE="$2"; shift 2 ;;
    --remote-commit) REMOTE_COMMIT="$2"; shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SOURCE_DIR" || -z "$STOP_SCRIPT" || -z "$INSTALL_SCRIPT" || -z "$LOG_FILE" ]]; then
  printf 'Missing required finalize arguments.\n' >&2
  exit 2
fi
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
  printf '%s [finalize] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE"
}
status_line() {
  local kind="$1"
  shift
  local line="HEADROOM_UPDATE_STATUS=${kind}"
  local pair
  for pair in "$@"; do line+=" ${pair}"; done
  printf '%s\n' "$line" | tee -a "$LOG_FILE"
}
fail() {
  local reason="$1"
  local message="$2"
  log "$message"
  status_line failed "reason=${reason}"
  exit 5
}

log "Stopping the installed Headroom process."
"$STOP_SCRIPT" >>"$LOG_FILE" 2>&1 || fail stop_failed "Stopping Headroom failed."
log "Installing and relaunching Headroom."
"$INSTALL_SCRIPT" >>"$LOG_FILE" 2>&1 || fail install_failed "Installing Headroom failed."
status_line completed "remote=${REMOTE_COMMIT:-unknown}"
log "Detached Headroom update completed."
