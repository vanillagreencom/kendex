#!/usr/bin/env bash
# growth-guards runs on consumer CI images and on macOS system Bash 3.2, so
# shipped scripts may not use Bash 4+ builtins or syntax (mapfile/readarray,
# associative arrays, automatic FD-allocation redirections, case-conversion
# expansions).
#
# And the utilities are BSD there, not GNU. A rule that only a macOS run can
# break belongs in a check every run makes: this file is where the shipped
# scripts are read for what the other platform does differently.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
. "$TEST_DIR/lib/harness.bash"

PATTERN='mapfile|readarray|declare -A|declare -gA|local -A'
PATTERN="$PATTERN"'|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
PATTERN="$PATTERN"'|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^)'
# chmod with `--` after the mode, which is the wrong side of it.
#
# BSD getopt(3) stops at the first non-option argument — the mode — so a
# `--` behind it is read as a filename, and chmod fails on the nonexistent
# file `--`. GNU chmod permutes its arguments and accepts either order,
# which is how the mistake lives through any number of Linux-only runs.
#
# `chmod +x -- "$hook"` wrote both hook files and made neither executable on
# macOS. git ignores a hook it cannot run, so `guard install` reported two
# armed hooks over a repository that gated nothing. size-ratchet found this
# first and wrote the rule down; the guards had the mistake it describes.
PATTERN="$PATTERN"'|chmod([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^-[:space:]][^[:space:]]*[[:space:]]+--([[:space:]]|$)'

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
  echo "constructs the other platform does not take, in growth-guards scripts:" >&2
  printf '%s\n' "$violations" >&2
  exit 1
fi

# Syntax-check every shipped script while we are here.
fail=0
# Every shipped script, discovered — a new one must not be able to skip the
# check by not being listed.
for f in "$SCRIPTS_DIR"/* "$SCRIPTS_DIR"/lib/*.sh; do
  [ -f "$f" ] || continue
  if ! bash -n "$f"; then
    echo "FAIL: bash -n $f"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1

echo "pass: bash32-portability"
