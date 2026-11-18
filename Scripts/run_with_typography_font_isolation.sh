#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 command [argument ...]" >&2
  exit 2
fi

# Keep snapshot rendering on the process-registered font path used to record the M0 baselines.
FONT_PROFILE='(version 1)
(allow default)
(deny mach-lookup (global-name "com.apple.fonts"))
(deny mach-lookup (global-name "com.apple.fonts.atsbridge"))'

export CODEXBAR_TYPOGRAPHY_FONT_ISOLATION=1
if [[ -x /usr/bin/sandbox-exec ]]; then
  exec /usr/bin/sandbox-exec -p "${FONT_PROFILE}" "$@"
fi
exec "$@"
