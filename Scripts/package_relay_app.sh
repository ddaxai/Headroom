#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

export APP_IDENTITY="${APP_IDENTITY:-CodexBar Development}"
# Prefer a stable development identity when it is actually installed.  A fresh checkout on a
# machine without that certificate must still be runnable with the normal packaging command; in
# that case fall back to ad-hoc signing explicitly instead of failing late during codesign.
if [[ -z "${CODEXBAR_SIGNING:-}" ]]; then
  available_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if [[ "$available_identities" == *"\"${APP_IDENTITY}\""* ]]; then
    CODEXBAR_SIGNING=identity
  else
    CODEXBAR_SIGNING=adhoc
  fi
fi
export CODEXBAR_SIGNING
export CODEXBAR_APP_NAME="Headroom"
export CODEXBAR_APP_BUNDLE_NAME="Headroom.app"
export CODEXBAR_BUNDLE_ID="com.ddaxia.headroom"
export CODEXBAR_ALLOW_LOCAL_SIGNING="${CODEXBAR_ALLOW_LOCAL_SIGNING:-1}"
export CODEXBAR_APP_GROUP_ID="${CODEXBAR_APP_GROUP_ID:-Y5PE65HELJ.com.ddaxia.headroom}"
export CODEXBAR_BUILD_TOOLS_MODULE_CACHE_PATH="${CODEXBAR_BUILD_TOOLS_MODULE_CACHE_PATH:-$ROOT/.build/headroom-manifest-module-cache}"
# Set HEADROOM_FEED_URL (or CODEXBAR_FEED_URL) for a signed release build. Local
# development builds remain update-disabled until a real Sparkle feed is configured.
export CODEXBAR_FEED_URL="${CODEXBAR_FEED_URL:-${HEADROOM_FEED_URL:-}}"

export CODEXBAR_OUTPUT_DIR="${CODEXBAR_OUTPUT_DIR:-$ROOT/.build/headroom-artifacts}"
exec "$ROOT/Scripts/package_app.sh" "${1:-release}"
