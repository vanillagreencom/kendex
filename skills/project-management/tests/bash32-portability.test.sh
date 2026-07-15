#!/usr/bin/env bash
# Regression: project-management scripts must stay Bash 3.2-compatible
# (macOS system bash). Guards against Bash 4+ constructs reappearing
# (vstack#582 follow-up — verification-scope shipped with declare -A).
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
