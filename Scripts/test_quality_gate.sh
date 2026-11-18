#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-quality-gate.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT

write_fixture() {
  local name="$1"
  local contents="$2"
  printf '%s\n' "${contents}" > "${TEMP_DIR}/${name}"
}

write_executable_fixture() {
  local name="$1"
  local contents="$2"
  printf '%b\n' "${contents}" > "${TEMP_DIR}/${name}"
  chmod +x "${TEMP_DIR}/${name}"
}

write_fixture passing.test.log 'Swift test timing summary:
- Selected groups: 4
- First-pass successful groups: 4
- First-pass failed groups: 0
- Full-group retries: 0
- Recovered groups: 0
- Timed out groups: 0'
write_fixture passing.format.parent '/tmp/parent/Sources/CodexBar/Example.swift:1:1: formatting'
write_fixture passing.format.current '/tmp/current/Sources/CodexBar/Example.swift:1:1: formatting'
write_fixture passing.lint.parent '/tmp/parent/Sources/CodexBar/Example.swift:1:1: warning: line (line_length)'
write_fixture passing.lint.current '/tmp/current/Sources/CodexBar/Example.swift:1:1: warning: line (line_length)'
write_fixture empty.baseline ''

python3 "${ROOT_DIR}/Scripts/quality_gate.py" \
  --test-log "${TEMP_DIR}/passing.test.log" \
  --format-baseline-log "${TEMP_DIR}/passing.format.parent" \
  --format-current-log "${TEMP_DIR}/passing.format.current" \
  --lint-baseline-log "${TEMP_DIR}/passing.lint.parent" \
  --lint-current-log "${TEMP_DIR}/passing.lint.current" \
  --test-baseline "${TEMP_DIR}/empty.baseline" \
  --summary-json "${TEMP_DIR}/passing.summary.json" \
  --no-run > "${TEMP_DIR}/passing.output"
python3 - "${TEMP_DIR}/passing.summary.json" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
platform = summary["platform"]
assert platform["os"]
assert platform["os_version"]
assert platform["architecture"]
assert platform["swift_version"]
PY
grep -Fq 'completed groups: 4/4' "${TEMP_DIR}/passing.output"
grep -Fq 'SwiftFormat strict new: 0' "${TEMP_DIR}/passing.output"
grep -Fq 'SwiftLint strict new: 0' "${TEMP_DIR}/passing.output"
grep -Fq 'RESULT: PASS' "${TEMP_DIR}/passing.output"

write_fixture failing.test.log 'Swift test timing summary:
- Selected groups: 4
- First-pass successful groups: 3
- First-pass failed groups: 1
- Full-group retries: 1
- Recovered groups: 0
- Timed out groups: 1
✘ Test CodexBarTests/Example failed'
write_fixture failing.format.current '/tmp/current/Sources/CodexBar/Example.swift:1:1: formatting
/tmp/current/Sources/CodexBar/Example.swift:2:1: formatting'
write_fixture failing.lint.current '/tmp/current/Sources/CodexBar/Example.swift:1:1: warning: line (line_length)
/tmp/current/Sources/CodexBar/Example.swift:2:1: warning: line (line_length)'

set +e
python3 "${ROOT_DIR}/Scripts/quality_gate.py" \
  --test-log "${TEMP_DIR}/failing.test.log" \
  --format-baseline-log "${TEMP_DIR}/passing.format.parent" \
  --format-current-log "${TEMP_DIR}/failing.format.current" \
  --lint-baseline-log "${TEMP_DIR}/passing.lint.parent" \
  --lint-current-log "${TEMP_DIR}/failing.lint.current" \
  --test-baseline "${TEMP_DIR}/empty.baseline" \
  --no-run > "${TEMP_DIR}/failing.output" 2>&1
failure_status=$?
set -e
[[ "${failure_status}" -ne 0 ]]
grep -Fq 'failed groups: 1' "${TEMP_DIR}/failing.output"
grep -Fq 'timed out groups: 1' "${TEMP_DIR}/failing.output"
grep -Fq 'test baseline new: 1' "${TEMP_DIR}/failing.output"
grep -Fq 'SwiftFormat strict new: 1' "${TEMP_DIR}/failing.output"
grep -Fq 'SwiftLint strict new: 1' "${TEMP_DIR}/failing.output"
grep -Fq 'RESULT: FAIL' "${TEMP_DIR}/failing.output"

# SwiftLint exits 2 when --strict finds violations. Existing violations are acceptable when the
# baseline delta is zero, so the normal gate must not turn that conventional status into failure.
write_executable_fixture fake-swiftformat '#!/bin/sh\nprintf "0/0 files require formatting.\\n"\nexit 0'
write_executable_fixture clean-swiftlint '#!/bin/sh\nprintf "Done linting! Found 0 violations, 0 serious in 0 files.\\n"\nexit 0'
write_executable_fixture fake-swiftlint '#!/bin/sh\nprintf "Done linting! Found 0 violations, 0 serious in 0 files.\\n"\nexit 2'

CODEXBAR_SWIFTFORMAT_BIN="${TEMP_DIR}/fake-swiftformat" \
CODEXBAR_SWIFTLINT_BIN="${TEMP_DIR}/clean-swiftlint" \
python3 "${ROOT_DIR}/Scripts/quality_gate.py" \
  --skip-tests > "${TEMP_DIR}/lint-clean-status.output" 2>&1
grep -Fq 'SwiftLint status: clean (exit 0)' "${TEMP_DIR}/lint-clean-status.output"
grep -Fq 'RESULT: PASS' "${TEMP_DIR}/lint-clean-status.output"

set +e
CODEXBAR_SWIFTFORMAT_BIN="${TEMP_DIR}/fake-swiftformat" \
CODEXBAR_SWIFTLINT_BIN="${TEMP_DIR}/fake-swiftlint" \
python3 "${ROOT_DIR}/Scripts/quality_gate.py" \
  --skip-tests > "${TEMP_DIR}/lint-status.output" 2>&1
lint_status=$?
set -e
[[ "${lint_status}" -eq 0 ]]
grep -Fq 'SwiftLint strict new: 0' "${TEMP_DIR}/lint-status.output"
grep -Fq 'SwiftLint status: violations reported (exit 2; baseline comparison applied)' \
  "${TEMP_DIR}/lint-status.output"
grep -Fq 'RESULT: PASS' "${TEMP_DIR}/lint-status.output"

write_executable_fixture error-swiftlint '#!/bin/sh\nprintf "/tmp/current/Sources/CodexBar/Example.swift:1:1: error: error-level violation (custom_error)\\n"\nprintf "Done linting! Found 1 violation, 1 serious in 1 file.\\n"\nexit 1'
set +e
CODEXBAR_SWIFTFORMAT_BIN="${TEMP_DIR}/fake-swiftformat" \
CODEXBAR_SWIFTLINT_BIN="${TEMP_DIR}/error-swiftlint" \
python3 "${ROOT_DIR}/Scripts/quality_gate.py" \
  --skip-tests > "${TEMP_DIR}/lint-error-violation.output" 2>&1
lint_error_violation_status=$?
set -e
[[ "${lint_error_violation_status}" -ne 0 ]]
grep -Fq 'SwiftLint status: error-level violations (exit 1)' \
  "${TEMP_DIR}/lint-error-violation.output"
! grep -Fq 'tool error' "${TEMP_DIR}/lint-error-violation.output"

write_executable_fixture broken-swiftlint '#!/bin/sh\nprintf "Done linting! Found 0 violations, 0 serious in 0 files.\\n"\nexit 3'
set +e
CODEXBAR_SWIFTFORMAT_BIN="${TEMP_DIR}/fake-swiftformat" \
CODEXBAR_SWIFTLINT_BIN="${TEMP_DIR}/broken-swiftlint" \
python3 "${ROOT_DIR}/Scripts/quality_gate.py" \
  --skip-tests > "${TEMP_DIR}/lint-failure.output" 2>&1
lint_failure_status=$?
set -e
[[ "${lint_failure_status}" -ne 0 ]]
grep -Fq 'SwiftLint status: tool error or abnormal termination (exit 3)' \
  "${TEMP_DIR}/lint-failure.output"
grep -Fq 'RESULT: FAIL' "${TEMP_DIR}/lint-failure.output"

echo "quality gate tests passed."
