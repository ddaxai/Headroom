#!/usr/bin/env bash
set -euo pipefail

# Stop only known Headroom and legacy CodexBar binary paths. Do not use a name-wide process kill.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v launchctl >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/com.ddaxia.headroom.local-meter" >/dev/null 2>&1 || true
fi
paths=(
  "$ROOT_DIR/.build/headroom-artifacts/Headroom.app/Contents/MacOS/CodexBar"
  "$ROOT_DIR/.build/headroom-artifacts/Headroom.app/Contents/Helpers/CodexBarLocalMeterHelper"
  "/Applications/Headroom.app/Contents/MacOS/CodexBar"
  "/Applications/Headroom.app/Contents/Helpers/CodexBarLocalMeterHelper"
  "/Applications/CodexBar.app/Contents/MacOS/CodexBar"
  "$ROOT_DIR/Headroom.app/Contents/MacOS/CodexBar"
  "$ROOT_DIR/Headroom.app/Contents/Helpers/CodexBarLocalMeterHelper"
  "$ROOT_DIR/CodexBar.app/Contents/MacOS/CodexBar"
  "$ROOT_DIR/.build/debug/CodexBar"
  "$ROOT_DIR/.build/release/CodexBar"
  "$ROOT_DIR/.build/debug/CodexBarLocalMeterHelper"
  "$ROOT_DIR/.build/release/CodexBarLocalMeterHelper"
)

for path in "${paths[@]}"; do
  while read -r pid; do
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    kill "$pid" 2>/dev/null || true
  done < <(ps -axo pid=,command= | awk -v target="$path" '$2 == target {print $1}')
done
