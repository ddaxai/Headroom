#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-swiftlint-baseline.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT

BASELINE="${TEMP_DIR}/baseline.log"
CURRENT="${TEMP_DIR}/current.log"
SAME="${TEMP_DIR}/same.log"

cat > "${BASELINE}" <<'EOF'
/private/tmp/parent/Sources/CodexBar/Example.swift:10:1: error: Line Length Violation: line is too long (line_length)
EOF

cat > "${CURRENT}" <<'EOF'
/Users/build/CodexBar/Sources/CodexBar/Example.swift:10:1: error: Line Length Violation: line is too long (line_length)
/Users/build/CodexBar/Sources/CodexBar/Example.swift:20:1: error: Line Length Violation: another line is too long (line_length)
EOF

cat > "${SAME}" <<'EOF'
/Users/build/CodexBar/Sources/CodexBar/Example.swift:20:1: error: Line Length Violation: moved line is too long (line_length)
EOF

set +e
python3 "${ROOT_DIR}/Scripts/compare_swiftlint_baseline.py" \
  "${BASELINE}" "${CURRENT}" > "${TEMP_DIR}/added.output" 2>&1
added_status=$?
set -e
[[ "${added_status}" -ne 0 ]]
grep -Fq 'new violations: 1' "${TEMP_DIR}/added.output"
grep -Fq 'Sources/CodexBar/Example.swift|line_length: baseline=1 current=2 delta=+1' \
  "${TEMP_DIR}/added.output"

python3 "${ROOT_DIR}/Scripts/compare_swiftlint_baseline.py" \
  "${BASELINE}" "${SAME}" > "${TEMP_DIR}/same.output"
grep -Fq 'new violations: 0' "${TEMP_DIR}/same.output"

echo "SwiftLint baseline comparison tests passed."
