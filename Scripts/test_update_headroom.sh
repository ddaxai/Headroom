#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE_SCRIPT="$ROOT_DIR/Scripts/update_headroom.sh"
TEST_BRANCH="headroom/v0.50-stabilize"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/headroom-update-test.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

REMOTE_DIR="$TEMP_DIR/origin.git"
AUTHOR_DIR="$TEMP_DIR/author"
SOURCE_DIR="$TEMP_DIR/source"
CALLS_FILE="$TEMP_DIR/calls.log"
LAUNCHCTL_CALLS="$TEMP_DIR/launchctl.log"
UPDATE_LOG="$TEMP_DIR/update.log"

help_output="$($UPDATE_SCRIPT --help)"
grep -Fq 'default: ~/Developer/Headroom' <<<"$help_output"
grep -Fq 'default: main' <<<"$help_output"
grep -Fq 'default: ~/Library/Logs/Headroom/update.log' <<<"$help_output"

git init --quiet --bare "$REMOTE_DIR"
git init --quiet --initial-branch="$TEST_BRANCH" "$AUTHOR_DIR"
git -C "$AUTHOR_DIR" config user.name "Headroom Update Test"
git -C "$AUTHOR_DIR" config user.email "headroom-update-test@example.invalid"
mkdir -p "$AUTHOR_DIR/Scripts"

cat > "$AUTHOR_DIR/Scripts/package_relay_app.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'package arches=%s args=%s\n' "${ARCHES:-unset}" "$*" >> "${HEADROOM_TEST_CALLS:?}"
SCRIPT
cat > "$AUTHOR_DIR/Scripts/stop_headroom.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'stop\n' >> "${HEADROOM_TEST_CALLS:?}"
SCRIPT
cat > "$AUTHOR_DIR/Scripts/install_headroom.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
# The production installer launches Headroom once after replacing the bundle.
printf 'install-and-relaunch\n' >> "${HEADROOM_TEST_CALLS:?}"
SCRIPT
cat > "$TEMP_DIR/launchctl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${HEADROOM_LAUNCHCTL_CALLS:?}"
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
shift
"$@"
SCRIPT
chmod +x "$AUTHOR_DIR"/Scripts/*.sh "$TEMP_DIR/launchctl"
printf 'initial\n' > "$AUTHOR_DIR/README.test"
git -C "$AUTHOR_DIR" add Scripts README.test
git -C "$AUTHOR_DIR" commit --quiet -m "Initial test source"
git -C "$AUTHOR_DIR" remote add origin "$REMOTE_DIR"
git -C "$AUTHOR_DIR" push --quiet --set-upstream origin "$TEST_BRANCH"
git clone --quiet --branch "$TEST_BRANCH" "$REMOTE_DIR" "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote rename origin fork

run_update() {
  HEADROOM_SOURCE_DIR="$SOURCE_DIR" \
    HEADROOM_BRANCH="$TEST_BRANCH" \
    HEADROOM_UPDATE_LOG="$UPDATE_LOG" \
    HEADROOM_TEST_CALLS="$CALLS_FILE" \
    HEADROOM_LAUNCHCTL="$TEMP_DIR/launchctl" \
    HEADROOM_LAUNCHCTL_CALLS="$LAUNCHCTL_CALLS" \
    "$UPDATE_SCRIPT" "$@"
}

# A current checkout must return without compiling or replacing the app.
current_output="$(run_update)"
grep -Fq 'Headroom is already up to date' <<<"$current_output"
grep -Fq "Fetching fork/${TEST_BRANCH}" <<<"$current_output"
[[ ! -s "$CALLS_FILE" ]]

# A clean checkout on another local branch switches back to the configured branch.
git -C "$SOURCE_DIR" checkout --quiet -b scratch
branch_output="$(run_update --check-only)"
grep -Fq 'HEADROOM_UPDATE_STATUS=up_to_date' <<<"$branch_output"
[[ "$(git -C "$SOURCE_DIR" branch --show-current)" == "$TEST_BRANCH" ]]

# Fetch failures are structured and never wait for terminal input.
working_remote_url="$(git -C "$SOURCE_DIR" remote get-url fork)"
git -C "$SOURCE_DIR" remote set-url fork "$TEMP_DIR/missing-remote.git"
set +e
run_update --check-only >"$TEMP_DIR/fetch.out" 2>"$TEMP_DIR/fetch.err"
fetch_status=$?
set -e
[[ "$fetch_status" -ne 0 ]]
grep -Fq 'reason=fetch_failed' "$UPDATE_LOG"
git -C "$SOURCE_DIR" remote set-url fork "$working_remote_url"

# Check-only reports an available commit but leaves the checkout and app untouched.
cat > "$AUTHOR_DIR/Scripts/finalize_headroom_update.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
stop=""
install=""
log=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop-script) stop="$2"; shift 2 ;;
    --install-script) install="$2"; shift 2 ;;
    --log-file) log="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '[stop] fixture\n' >> "$log"
"$stop"
printf '[install] fixture\n' >> "$log"
"$install"
printf 'HEADROOM_UPDATE_STATUS=completed remote=test\n' >> "$log"
SCRIPT
chmod +x "$AUTHOR_DIR/Scripts/finalize_headroom_update.sh"
printf 'remote update\n' > "$AUTHOR_DIR/remote-update.txt"
git -C "$AUTHOR_DIR" add Scripts/finalize_headroom_update.sh remote-update.txt
git -C "$AUTHOR_DIR" commit --quiet -m "Add remote update"
git -C "$AUTHOR_DIR" push --quiet
before_check="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
check_output="$(run_update --check-only)"
after_check="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
grep -Fq 'HEADROOM_UPDATE_STATUS=available' <<<"$check_output"
[[ "$before_check" == "$after_check" ]]
[[ ! -s "$CALLS_FILE" ]]

# A dirty checkout must abort before reset, packaging, or installation.
printf 'local work\n' >> "$SOURCE_DIR/README.test"
if run_update >"$TEMP_DIR/dirty.out" 2>"$TEMP_DIR/dirty.err"; then
  echo 'ERROR: dirty Headroom checkout was updated.' >&2
  exit 1
fi
grep -Fq 'reason=tracked_dirty' "$UPDATE_LOG"
grep -Fq 'README.test' "$TEMP_DIR/dirty.err"
[[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" == "$before_check" ]]
grep -Fq 'local work' "$SOURCE_DIR/README.test"
[[ ! -s "$CALLS_FILE" ]]

# Once clean, update resets to the fetched commit and runs package -> stop -> install/relaunch.
git -C "$SOURCE_DIR" checkout --quiet -- README.test
update_output="$(run_update)"
grep -Fq 'scheduled' <<<"$update_output"
[[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" == "$(git -C "$AUTHOR_DIR" rev-parse HEAD)" ]]
cat > "$TEMP_DIR/expected-calls.log" <<'EXPECTED'
package arches=arm64 args=release
stop
install-and-relaunch
EXPECTED
cmp "$TEMP_DIR/expected-calls.log" "$CALLS_FILE"
grep -Fq '[package]' "$UPDATE_LOG"
grep -Fq '[install]' "$UPDATE_LOG"
grep -Fq 'HEADROOM_UPDATE_STATUS=scheduled' "$UPDATE_LOG"
grep -Fq 'HEADROOM_UPDATE_STATUS=completed' "$UPDATE_LOG"
grep -Fq 'submit' "$LAUNCHCTL_CALLS"

# Untracked files require an explicit opt-in and are never cleaned automatically.
printf 'remote update 2\n' > "$AUTHOR_DIR/remote-update-2.txt"
git -C "$AUTHOR_DIR" add remote-update-2.txt
git -C "$AUTHOR_DIR" commit --quiet -m "Add second remote update"
git -C "$AUTHOR_DIR" push --quiet
printf 'keep me\n' > "$SOURCE_DIR/user-untracked.txt"
set +e
run_update >"$TEMP_DIR/untracked.out" 2>"$TEMP_DIR/untracked.err"
untracked_status=$?
set -e
[[ "$untracked_status" -ne 0 ]]
grep -Fq 'reason=untracked_files' "$UPDATE_LOG"
[[ -f "$SOURCE_DIR/user-untracked.txt" ]]
run_update --ignore-untracked >"$TEMP_DIR/ignore-untracked.out"
grep -Fq 'Ignoring untracked files' "$TEMP_DIR/ignore-untracked.out"
[[ -f "$SOURCE_DIR/user-untracked.txt" ]]

# Local-ahead and diverged histories require the explicit reset flag and preserve untracked files.
git -C "$SOURCE_DIR" config user.name "Headroom Update Test"
git -C "$SOURCE_DIR" config user.email "headroom-update-test@example.invalid"
printf 'local ahead\n' > "$SOURCE_DIR/local-ahead.txt"
git -C "$SOURCE_DIR" add local-ahead.txt
git -C "$SOURCE_DIR" commit --quiet -m "Local ahead fixture"
set +e
run_update --ignore-untracked >"$TEMP_DIR/local-ahead.out" 2>"$TEMP_DIR/local-ahead.err"
local_ahead_status=$?
set -e
[[ "$local_ahead_status" -eq 6 ]]
grep -Fq 'reason=local_ahead' "$UPDATE_LOG"
run_update --ignore-untracked --allow-local-reset >"$TEMP_DIR/local-reset.out"
[[ ! -f "$SOURCE_DIR/local-ahead.txt" ]]
[[ -f "$SOURCE_DIR/user-untracked.txt" ]]

printf 'local diverged\n' > "$SOURCE_DIR/local-diverged.txt"
git -C "$SOURCE_DIR" add local-diverged.txt
git -C "$SOURCE_DIR" commit --quiet -m "Local diverged fixture"
printf 'remote diverged\n' > "$AUTHOR_DIR/remote-diverged.txt"
git -C "$AUTHOR_DIR" add remote-diverged.txt
git -C "$AUTHOR_DIR" commit --quiet -m "Remote diverged fixture"
git -C "$AUTHOR_DIR" push --quiet
set +e
run_update --ignore-untracked >"$TEMP_DIR/diverged.out" 2>"$TEMP_DIR/diverged.err"
diverged_status=$?
set -e
[[ "$diverged_status" -eq 6 ]]
grep -Fq 'reason=diverged' "$UPDATE_LOG"
run_update --ignore-untracked --allow-local-reset >"$TEMP_DIR/diverged-reset.out"
[[ ! -f "$SOURCE_DIR/local-diverged.txt" ]]
[[ -f "$SOURCE_DIR/user-untracked.txt" ]]

# Command failures preserve the exit status and print the last log lines to stderr.
: > "$CALLS_FILE"
cat > "$AUTHOR_DIR/Scripts/package_relay_app.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'package arches=%s args=%s\n' "${ARCHES:-unset}" "$*" >> "${HEADROOM_TEST_CALLS:?}"
printf 'fixture package failure marker\n' >&2
exit 17
SCRIPT
chmod +x "$AUTHOR_DIR/Scripts/package_relay_app.sh"
git -C "$AUTHOR_DIR" add Scripts/package_relay_app.sh
git -C "$AUTHOR_DIR" commit --quiet -m "Make fixture package fail"
git -C "$AUTHOR_DIR" push --quiet
set +e
run_update --ignore-untracked >"$TEMP_DIR/failure.out" 2>"$TEMP_DIR/failure.err"
failure_status=$?
set -e
[[ "$failure_status" -eq 17 ]]
grep -Fq 'Last 20 log lines' "$TEMP_DIR/failure.err"
grep -Fq 'fixture package failure marker' "$TEMP_DIR/failure.err"
[[ "$(cat "$CALLS_FILE")" == 'package arches=arm64 args=release' ]]

# A missing checkout prints a usable clone command instead of only reporting the bad path.
set +e
HEADROOM_SOURCE_DIR="$TEMP_DIR/missing" \
  HEADROOM_BRANCH="$TEST_BRANCH" \
  HEADROOM_UPDATE_LOG="$UPDATE_LOG" \
  "$UPDATE_SCRIPT" >"$TEMP_DIR/missing.out" 2>"$TEMP_DIR/missing.err"
missing_status=$?
set -e
[[ "$missing_status" -ne 0 ]]
grep -Fq 'git clone https://github.com/ddaxai/Headroom.git' "$TEMP_DIR/missing.err"

printf 'Headroom update script tests passed.\n'
