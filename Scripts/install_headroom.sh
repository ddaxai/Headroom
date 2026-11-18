#!/usr/bin/env bash
set -euo pipefail

# Install exactly one packaged Headroom app. This script never kills processes: if an old copy is
# running, quit that exact app first and rerun. Existing bundles are moved to a recoverable temp
# directory instead of being overwritten in place.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/.build/headroom-artifacts/Headroom.app"
TARGET_APP="/Applications/Headroom.app"
LEGACY_APP="/Applications/CodexBar.app"
TARGET_BINARY="$TARGET_APP/Contents/MacOS/CodexBar"
LEGACY_BINARY="$LEGACY_APP/Contents/MacOS/CodexBar"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "ERROR: packaged Headroom.app not found at $SOURCE_APP" >&2
    echo "Run ./Scripts/package_relay_app.sh first." >&2
    exit 1
fi

# Never install a stale artifact left by an earlier failed build.  The packaging command writes
# the source commit into the bundle, so an install can be tied to the checkout that invoked it.
EXPECTED_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
SOURCE_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :CodexGitCommit' \
    "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "$EXPECTED_COMMIT" && -n "$SOURCE_COMMIT" && "$EXPECTED_COMMIT" != "$SOURCE_COMMIT" ]]; then
    echo "ERROR: packaged Headroom.app is stale (artifact ${SOURCE_COMMIT}, checkout ${EXPECTED_COMMIT})." >&2
    echo "The previous build failed; do not install this old artifact. Run the package command again." >&2
    exit 3
fi

process_ids_for_path() {
    local path="$1"
    ps -axo pid=,command= | awk -v target="$path" '$2 == target {print $1}'
}

running_path=""
for path in "$TARGET_BINARY" "$LEGACY_BINARY"; do
    if pids="$(process_ids_for_path "$path")" && [[ -n "$pids" ]]; then
        running_path="$path (PID${pids//$'\n'/,})"
        break
    fi
done
if [[ -n "$running_path" ]]; then
    echo "ERROR: an old menu-bar process is still running: $running_path" >&2
    echo "Quit that exact app, then rerun this installer." >&2
    exit 2
fi

BACKUP_DIR="$(mktemp -d /private/tmp/headroom-install.XXXXXX)"
if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/com.ddaxia.headroom.local-meter" >/dev/null 2>&1 || true
fi
if [[ -d "$TARGET_APP" ]]; then
    mv "$TARGET_APP" "$BACKUP_DIR/Headroom.app.previous"
fi
if [[ -d "$LEGACY_APP" ]]; then
    mv "$LEGACY_APP" "$BACKUP_DIR/CodexBar.app.legacy"
fi

ditto "$SOURCE_APP" "$TARGET_APP"
open "$TARGET_APP"

echo "Installed one Headroom.app at $TARGET_APP"
echo "Previous bundles, if any, were moved to $BACKUP_DIR"
