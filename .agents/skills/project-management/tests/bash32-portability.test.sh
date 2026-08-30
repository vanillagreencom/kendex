#!/usr/bin/env bash
# vacuous-suite-scan: absence-subject
# These scripts run under macOS system bash, which is 3.2. Bash 4+ constructs
# fail there at runtime rather than at review time, so they are linted out.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"

PASS=0
FAIL=0

# An absent forbidden construct means nothing when there was nothing to look
# in: an empty scripts/ scans clean under every pattern below.
if [ -z "$(find "$SKILL_DIR/scripts" -type f)" ]; then
  echo "FAIL: no shipped script found under $SKILL_DIR/scripts, so this lint read nothing" >&2
  exit 1
fi

check_absent() {
  local pattern="$1" label="$2" hits="" status=0
  # grep's status is part of the answer: 0 found, 1 none, anything else is a
  # scan that did not run — and a scan that did not run is not a clean tree.
  # `2>/dev/null` used to hide that third case, and the pipeline's status came
  # from the `grep -v` at its end, so an unreadable tree printed PASS.
  hits="$(grep -rnE "$pattern" "$SKILL_DIR/scripts")" || status=$?
  if [ "$status" -gt 1 ]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — the scan over %s could not run (grep exited %s)\n' \
      "$label" "$SKILL_DIR/scripts" "$status" >&2
    return 0
  fi
  hits="$(printf '%s' "$hits" | grep -v '^Binary' || true)"
  if [ -n "$hits" ]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$label" >&2
    printf '%s\n' "$hits" >&2
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
