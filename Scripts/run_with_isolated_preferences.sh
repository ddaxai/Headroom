#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  printf 'Usage: CODEXBAR_PREFERENCES_SUITE=com.ddaxia.headroom.isolated.<name> %s <command> [args...]\n' \
    "$(basename "$0")" >&2
  exit 2
fi

suite_name="${CODEXBAR_PREFERENCES_SUITE:-}"
case "$suite_name" in
  com.ddaxia.headroom.isolated.*)
    ;;
  *)
    printf 'CODEXBAR_PREFERENCES_SUITE must use com.ddaxia.headroom.isolated.*\n' >&2
    exit 2
    ;;
esac

exec env CODEXBAR_PREFERENCES_SUITE="$suite_name" \
  CODEXBAR_RELAY_DEFAULTS_SUITE="$suite_name" \
  "$@"
