#!/usr/bin/env bash
# vacuous-suite-scan: absence-subject
# size-ratchet runs on consumer CI images and on macOS system Bash 3.2, so
# shipped scripts may not use Bash 4+ builtins or syntax (mapfile/readarray,
# associative arrays, automatic FD-allocation redirections, case-conversion
# expansions).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"

PATTERN='mapfile|readarray|declare -A|declare -gA|local -A'
PATTERN="$PATTERN"'|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
PATTERN="$PATTERN"'|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^)'

# grep's status is part of the answer: 0 found, 1 none, anything else is a
# scan that did not run — and a scan that did not run is not a clean tree.
violations=""
scan_status=0
violations="$(grep -rnE "$PATTERN" "$SCRIPTS_DIR")" || scan_status=$?
if [[ "$scan_status" -gt 1 ]]; then
  echo "the portability scan over $SCRIPTS_DIR could not run (grep exited $scan_status)" >&2
  exit 1
fi
if [[ -n "$violations" ]]; then
  echo "Bash 4+ constructs found in size-ratchet scripts (must run under Bash 3.2):" >&2
  printf '%s\n' "$violations" >&2
  exit 1
fi

# Syntax-check every shipped script while we are here.
fail=0
checked=0
for f in "$SCRIPTS_DIR"/size-ratchet "$SCRIPTS_DIR"/lib/*.sh; do
  if [ -f "$f" ]; then
    checked=$((checked + 1))
  fi
  if ! bash -n "$f"; then
    echo "FAIL: bash -n $f"
    fail=1
  fi
done
# An absent forbidden construct means nothing when there was nothing to look
# in: an empty scripts/ scans clean.
if [ "$checked" -eq 0 ]; then
  echo "FAIL: no shipped script found under $SCRIPTS_DIR, so this lint read nothing" >&2
  exit 1
fi
[ "$fail" -eq 0 ] || exit 1

echo "pass: bash32-portability"
