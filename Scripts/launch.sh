#!/bin/bash
set -euo pipefail

# Launch the single Headroom installation (stops only the exact bundled process first).
# Usage: ./Scripts/launch.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$PROJECT_ROOT/.build/headroom-artifacts/Headroom.app"
APP_BINARY="$APP_PATH/Contents/MacOS/CodexBar"

echo "==> Stopping exact Headroom and legacy CodexBar processes"
for app_binary in \
    "$APP_BINARY" \
    "/Applications/Headroom.app/Contents/MacOS/CodexBar" \
    "/Applications/CodexBar.app/Contents/MacOS/CodexBar" \
    "$PROJECT_ROOT/Headroom.app/Contents/MacOS/CodexBar" \
    "$PROJECT_ROOT/CodexBar.app/Contents/MacOS/CodexBar"; do
    while read -r pid; do
        [[ -z "$pid" || "$pid" == "$$" ]] && continue
        kill "$pid" 2>/dev/null || true
    done < <(ps -axo pid=,command= | awk -v target="$app_binary" '$2 == target {print $1}')
done
sleep 0.5

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Headroom.app not found at $APP_PATH"
    echo "Run ./Scripts/package_relay_app.sh first to build the app"
    exit 1
fi

echo "==> Launching Headroom from $APP_PATH"
open "$APP_PATH"

# Wait a moment and check if it's running
sleep 1
if ps -axo command= | grep -F -x "$APP_BINARY" >/dev/null; then
    echo "OK: Headroom is running."
else
    echo "ERROR: App exited immediately. Check crash logs in Console.app (User Reports)."
    exit 1
fi
