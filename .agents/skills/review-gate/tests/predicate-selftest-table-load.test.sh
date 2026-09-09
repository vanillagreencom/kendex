#!/usr/bin/env bash
# A missing decision-table module must stop the selftest instead of silently
# removing its behavior cases while the runner continues without errexit.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf -- "${TMP:?}"' EXIT
cp -R "$SKILL_DIR/scripts" "$TMP/"
mkdir -p "$TMP/tests"
cp -R "$SKILL_DIR/tests/lib" "$TMP/tests/"

missing="$TMP/scripts/../tests/lib/predicate-selftest/predicate-fixture-integrity.sh"
rm -- "$TMP/tests/lib/predicate-selftest/predicate-fixture-integrity.sh"
rc=0
output="$(REVIEW_GATE_SETTINGS_FILE=/dev/null "$TMP/scripts/review-predicate-selftest.sh" 2>&1)" || rc=$?
diagnostic="$(printf '%s\n' "$output" | grep '^review-gate-error=selftest-table-load ' | head -1)"
printf -v expected_path '%q' "$missing"
expected="review-gate-error=selftest-table-load value=$expected_path"
if [ "$rc" = 1 ] && [ "$diagnostic" = "$expected" ]; then
  printf 'test-pass=predicate-selftest-table-load value=missing\n'
else
  printf 'test-failure=predicate-selftest-table-load value=missing\nrc=%s expected=%q actual=%q\n' \
    "$rc" "$expected" "$diagnostic" >&2
  exit 1
fi
