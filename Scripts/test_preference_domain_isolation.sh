#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="${ROOT}/Scripts/$(basename "${BASH_SOURCE[0]}")"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-preference-isolation.XXXXXX")"
PROBE_ID="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
HOST_DOMAIN="com.ddaxia.headroom.isolated.preference-host.${PROBE_ID}"
ISOLATED_DOMAIN="com.ddaxia.headroom.isolated.preference-suite.${PROBE_ID}"

cleanup() {
  /usr/bin/defaults delete "$HOST_DOMAIN" >/dev/null 2>&1 || true
  /usr/bin/defaults delete "$ISOLATED_DOMAIN" >/dev/null 2>&1 || true
  /bin/sleep 0.1
  host_file="${HOME:?}/Library/Preferences/${HOST_DOMAIN}.plist"
  isolated_file="${HOME:?}/Library/Preferences/${ISOLATED_DOMAIN}.plist"
  [[ -e "$host_file" ]] && /bin/unlink "$host_file"
  [[ -e "$isolated_file" ]] && /bin/unlink "$isolated_file"
  /bin/rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

unsafe_home_token="CFFIXED"'_USER_HOME'
unsafe_home_pattern="${unsafe_home_token}[[:space:]]*="
unsafe_defaults_pattern='defaults[[:space:]]+write'
unsafe_hits="$({
  /usr/bin/grep -REIn --exclude="$(basename "$SELF")" -- "$unsafe_home_pattern" \
    "$ROOT/Scripts" "$ROOT/Tests" || true
  /usr/bin/grep -REIn --exclude="$(basename "$SELF")" -- "$unsafe_defaults_pattern" \
    "$ROOT/Scripts" "$ROOT/Tests" || true
} | /usr/bin/sed "s#${ROOT}/##")"

if [[ -n "$unsafe_hits" ]]; then
  printf 'Unsafe preference-isolation references found:\n%s\n' "$unsafe_hits" >&2
  exit 1
fi

direct_standard_hits="$({
  # This test intentionally mentions the legacy object to prove the default seam is identical.
  /usr/bin/grep -RIn --exclude='CodexBarPreferences.swift' \
    --exclude='ProcessPreferenceIsolationTests.swift' -- 'UserDefaults.standard' \
    "$ROOT/Sources" "$ROOT/Tests" || true
  /usr/bin/grep -REIn --exclude='CodexBarPreferences.swift' \
    --exclude='ProcessPreferenceIsolationTests.swift' -- 'UserDefaults[^[:cntrl:]]*= \.standard' \
    "$ROOT/Sources" "$ROOT/Tests" || true
} | /usr/bin/sed "s#${ROOT}/##")"
if [[ -n "$direct_standard_hits" ]]; then
  printf 'Preference access bypasses CodexBarPreferences:\n%s\n' "$direct_standard_hits" >&2
  exit 1
fi

if [[ ! -x "$ROOT/Scripts/run_with_isolated_preferences.sh" ]]; then
  printf 'Missing isolated preference-domain launcher.\n' >&2
  exit 1
fi

PROBE="$TMP_ROOT/preference-probe.swift"
/usr/bin/sed \
  -e "s|__HOST_DOMAIN__|$HOST_DOMAIN|g" \
  -e "s|__ISOLATED_DOMAIN__|$ISOLATED_DOMAIN|g" \
  "$ROOT/Scripts/Fixtures/preference-isolation-probe.swift" > "$PROBE"

CODEXBAR_PREFERENCES_SUITE="$ISOLATED_DOMAIN" \
  "$ROOT/Scripts/run_with_isolated_preferences.sh" /usr/bin/swift "$PROBE"

if /usr/bin/defaults read "$HOST_DOMAIN" probe >/dev/null 2>&1; then
  printf 'Isolated preference probe touched host domain %s.\n' "$HOST_DOMAIN" >&2
  exit 1
fi
if [[ "$(/usr/bin/defaults read "$ISOLATED_DOMAIN" probe 2>/dev/null || true)" != isolated ]]; then
  printf 'Isolated preference probe did not write to suite %s.\n' "$ISOLATED_DOMAIN" >&2
  exit 1
fi

printf 'Preference-domain isolation test passed; host domain remained untouched.\n'
