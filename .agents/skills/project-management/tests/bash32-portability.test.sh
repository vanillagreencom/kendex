#!/usr/bin/env bash
# These scripts run under macOS system bash, which is 3.2. Bash 4+ constructs
# fail there at runtime rather than at review time, so they are linted out.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"

PASS=0
FAIL=0

check_absent() {
  local pattern="$1" label="$2"
  if grep -rnE "$pattern" "$SKILL_DIR/scripts" 2>/dev/null | grep -v '^Binary'; then
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$label" >&2
  else
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$label"
  fi
}

check_absent 'mapfile|readarray' "no mapfile/readarray in scripts/"
check_absent 'declare -[a-zA-Z]*A|local -[a-zA-Z]*A' "no associative arrays in scripts/"
check_absent '\$\{[A-Za-z_]+(,,|\^\^)\}' "no case-conversion expansions in scripts/"
check_absent 'exec \{[A-Za-z_]+\}' "no auto-allocated FDs in scripts/"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
