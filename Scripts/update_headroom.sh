#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${HEADROOM_SOURCE_DIR:-${HOME}/Developer/Headroom}"
BRANCH="${HEADROOM_BRANCH:-main}"
REMOTE_OVERRIDE="${HEADROOM_REMOTE:-}"
LOG_FILE="${HEADROOM_UPDATE_LOG:-${HOME}/Library/Logs/Headroom/update.log}"
LAUNCHCTL_BIN="${HEADROOM_LAUNCHCTL:-/bin/launchctl}"
CHECK_ONLY=false
IGNORE_UNTRACKED="${HEADROOM_IGNORE_UNTRACKED:-0}"
ALLOW_LOCAL_RESET="${HEADROOM_ALLOW_LOCAL_RESET:-0}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check-only] [--ignore-untracked] [--allow-local-reset]

Fetch origin/${BRANCH}, compare it with the local checkout, and install a clean update.

Environment:
  HEADROOM_SOURCE_DIR  Source checkout (default: ~/Developer/Headroom)
  HEADROOM_BRANCH      Git branch (default: main)
  HEADROOM_REMOTE      Git remote (default: the branch's configured remote, then origin)
  HEADROOM_UPDATE_LOG  Append-only log (default: ~/Library/Logs/Headroom/update.log)
  HEADROOM_LAUNCHCTL   launchctl executable (default: /bin/launchctl)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=true ;;
    --ignore-untracked) IGNORE_UNTRACKED=1 ;;
    --allow-local-reset) ALLOW_LOCAL_RESET=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

stage() {
  local name="$1"
  local message="$2"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$name" "$message" | tee -a "$LOG_FILE"
}

status_line() {
  local kind="$1"
  shift
  local line="HEADROOM_UPDATE_STATUS=${kind}"
  local pair
  for pair in "$@"; do
    line+=" ${pair}"
  done
  printf '%s\n' "$line" | tee -a "$LOG_FILE"
}

fail() {
  local status="$1"
  local reason="$2"
  local message="$3"
  printf 'ERROR: %s\n' "$message" | tee -a "$LOG_FILE" >&2
  status_line failed "reason=${reason}"
  printf '%s\n' 'Last 20 log lines:' >&2
  tail -n 20 "$LOG_FILE" >&2 || true
  exit "$status"
}

run_logged_stage() {
  local name="$1"
  local message="$2"
  shift 2
  stage "$name" "$message"

  local -a pipeline_status
  set +e
  "$@" 2>&1 | tee -a "$LOG_FILE"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  if [[ "${pipeline_status[0]}" -ne 0 ]]; then
    fail "${pipeline_status[0]}" "${name}_failed" "Stage ${name} failed."
  fi
}

ensure_workspace_is_safe() {
  local tracked_changes untracked_changes
  tracked_changes="$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=no 2>/dev/null)" || \
    fail 3 "checkout_unreadable" "Unable to inspect the Headroom checkout at ${SOURCE_DIR}."
  if [[ -n "$tracked_changes" ]]; then
    fail 4 "tracked_dirty" "Tracked changes are present; update aborted before replacing files.\n${tracked_changes}"
  fi

  untracked_changes="$(git -C "$SOURCE_DIR" ls-files --others --exclude-standard 2>/dev/null)" || \
    fail 3 "checkout_unreadable" "Unable to inspect untracked files in ${SOURCE_DIR}."
  if [[ -n "$untracked_changes" && "$IGNORE_UNTRACKED" != "1" ]]; then
    fail 4 "untracked_files" "Untracked files are present; choose 'ignore untracked files' before updating.\n${untracked_changes}"
  fi
  if [[ -n "$untracked_changes" ]]; then
    stage preflight "Ignoring untracked files by explicit request; git clean will not run."
  fi
}

resolve_remote() {
  local remote="$REMOTE_OVERRIDE"
  if [[ -z "$remote" ]]; then
    remote="$(git -C "$SOURCE_DIR" config --get "branch.${BRANCH}.remote" 2>/dev/null || true)"
  fi
  if [[ -z "$remote" || "$remote" == "." ]]; then
    remote="origin"
  fi
  if ! git -C "$SOURCE_DIR" remote get-url "$remote" >/dev/null 2>&1; then
    fail 3 "remote_missing" "Git remote ${remote} is not configured in ${SOURCE_DIR}."
  fi
  printf '%s' "$remote"
}

is_ancestor() {
  git -C "$SOURCE_DIR" merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1
}

stage preflight "Checking Headroom source at ${SOURCE_DIR}."
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  fail 3 "checkout_missing" "HEADROOM_SOURCE_DIR is not a Git checkout: ${SOURCE_DIR}. Clone it with: git clone https://github.com/ddaxai/Headroom.git ${SOURCE_DIR}"
fi

current_branch="$(git -C "$SOURCE_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [[ "$CHECK_ONLY" != true || "$current_branch" != "$BRANCH" ]]; then
  ensure_workspace_is_safe
fi
REMOTE="$(resolve_remote)"

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
run_logged_stage fetch "Fetching ${REMOTE}/${BRANCH}." \
  git -C "$SOURCE_DIR" fetch --no-prune "$REMOTE" "$BRANCH"

if [[ "$current_branch" != "$BRANCH" ]]; then
  if git -C "$SOURCE_DIR" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    run_logged_stage preflight "Switching clean checkout to ${BRANCH}." \
      git -C "$SOURCE_DIR" checkout --quiet "$BRANCH"
  else
    run_logged_stage preflight "Creating local tracking branch ${BRANCH} from ${REMOTE}/${BRANCH}." \
      git -C "$SOURCE_DIR" checkout --quiet -b "$BRANCH" FETCH_HEAD
  fi
fi

local_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null)" || \
  fail 3 "local_commit_missing" "Unable to resolve the local Headroom commit."
remote_commit="$(git -C "$SOURCE_DIR" rev-parse FETCH_HEAD 2>/dev/null)" || \
  fail 3 "remote_commit_missing" "Unable to resolve the fetched Headroom commit."

stage compare "Comparing local ${local_commit:0:12} with ${REMOTE}/${BRANCH} ${remote_commit:0:12}."
if [[ "$local_commit" == "$remote_commit" ]]; then
  status_line up_to_date "local=${local_commit:0:12}"
  stage done "Headroom is already up to date; no build or install was run."
  exit 0
fi

relation="diverged"
behind="0"
if is_ancestor "$local_commit" "$remote_commit"; then
  relation="available"
  behind="$(git -C "$SOURCE_DIR" rev-list --count "${local_commit}..${remote_commit}")"
elif is_ancestor "$remote_commit" "$local_commit"; then
  relation="local_ahead"
fi

if [[ "$CHECK_ONLY" == true ]]; then
  case "$relation" in
    available) status_line available "local=${local_commit:0:12}" "remote=${remote_commit:0:12}" "behind=${behind}" ;;
    local_ahead) status_line local_ahead "local=${local_commit:0:12}" "remote=${remote_commit:0:12}" ;;
    diverged) status_line diverged "local=${local_commit:0:12}" "remote=${remote_commit:0:12}" ;;
  esac
  stage done "Source comparison finished without changing the checkout."
  exit 0
fi

if [[ "$relation" == "local_ahead" && "$ALLOW_LOCAL_RESET" != "1" ]]; then
  fail 6 "local_ahead" "The local checkout has commits that are not on the private remote; review before replacing them."
fi
if [[ "$relation" == "diverged" && "$ALLOW_LOCAL_RESET" != "1" ]]; then
  fail 6 "diverged" "The local checkout diverged from the private remote; review before replacing it."
fi

PACKAGE_SCRIPT="$SOURCE_DIR/Scripts/package_relay_app.sh"
STOP_SCRIPT="$SOURCE_DIR/Scripts/stop_headroom.sh"
INSTALL_SCRIPT="$SOURCE_DIR/Scripts/install_headroom.sh"
FINALIZE_SCRIPT="$SOURCE_DIR/Scripts/finalize_headroom_update.sh"
run_logged_stage sync "Updating the checkout to ${REMOTE}/${BRANCH}." \
  git -C "$SOURCE_DIR" reset --hard "$remote_commit"
for required_script in "$PACKAGE_SCRIPT" "$STOP_SCRIPT" "$INSTALL_SCRIPT" "$FINALIZE_SCRIPT"; do
  if [[ ! -x "$required_script" ]]; then
    fail 5 "required_script_missing" "Required executable is missing after sync: ${required_script}"
  fi
done
run_logged_stage package "Packaging the release build." \
  env ARCHES=arm64 "$PACKAGE_SCRIPT" release

FINALIZE_LABEL="com.ddaxia.headroom.update.$(date +%s).$$"
status_line scheduled "local=${local_commit:0:12}" "remote=${remote_commit:0:12}"
stage finalize "Scheduling stop, install, and relaunch outside Headroom."
set +e
"$LAUNCHCTL_BIN" submit -l "$FINALIZE_LABEL" -- /bin/bash "$FINALIZE_SCRIPT" \
  --source-dir "$SOURCE_DIR" \
  --stop-script "$STOP_SCRIPT" \
  --install-script "$INSTALL_SCRIPT" \
  --log-file "$LOG_FILE" \
  --remote-commit "${remote_commit:0:12}" \
  2>&1 | tee -a "$LOG_FILE"
submit_status="${PIPESTATUS[0]}"
set -e
if [[ "$submit_status" -ne 0 ]]; then
  fail 5 "finalize_submit_failed" "Could not schedule the detached install step."
fi
stage done "Stop, install, and relaunch were scheduled outside Headroom."
