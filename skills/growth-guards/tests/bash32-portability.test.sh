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
# A `--` anywhere but immediately after the `chmod` word.
#
# BSD getopt(3) stops at the first non-option argument, so a `--` that comes
# after anything is read as a filename and chmod fails on the nonexistent
# file `--`. GNU permutes and accepts it wherever it lands, which is how the
# mistake lives through any number of Linux-only runs. `chmod +x -- "$hook"`
# wrote both hook files and made neither executable on macOS; git ignores a
# hook it cannot run, so `guard install` reported two armed hooks over a
# repository that gated nothing.
#
# This rule described the mode twice and got it wrong twice. First as "the
# token that is not a flag", which missed `chmod -x --` because a mode may
# lead with a minus. Then as GNU's mode grammar, which missed `chmod a= --`
# and `chmod g=u --` because a symbolic clause may have an empty permission
# list. A third spelling of the same idea would miss a fourth shape.
#
# So there is no grammar here. What is wrong with these lines has nothing to
# do with what a mode looks like: the `--` is not the first argument. That is
# the whole rule, and it needs to recognise no mode at all — `chmod`, then a
# token that is not `--`, then a bare `--` anywhere after it.
PATTERN="$PATTERN"'|chmod[[:space:]]+(([^-[:space:]]|-[^-[:space:]]|--[^[:space:]])[^[:space:]]*|-)([[:space:]]+[^[:space:]]+)*[[:space:]]+--([[:space:]]|$)'

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

# The scan has to be able to see one, in the shape that got past it. A
# planted line in a scratch copy, run through the same PATTERN: `chmod -x --`
# leads with a minus, which is what the first spelling of the rule read as an
# option and let through.
probe="$(mktemp -d "${TMPDIR:-/tmp}/gg-portability.XXXXXX")"
trap 'rm -rf "$probe"' EXIT
{
  printf '#!/bin/sh\n'
  printf 'chmod -x -- "$f"\n'
  printf 'chmod +x -- "$f"\n'
  printf 'chmod a= -- "$f"\n'
  printf 'chmod g=u -- "$f"\n'
  printf '%s\n' 'chmod 0755 -- "$f"'
  printf '%s\n' 'chmod -R -- 755 "$d"'
} >"$probe/planted.sh"
planted=""
planted_status=0
planted="$(grep -rnE "$PATTERN" "$probe")" || planted_status=$?
if [[ "$planted_status" -gt 1 ]]; then
  echo "FAIL: the scan over the planted probe could not run (grep exited $planted_status)" >&2
  exit 1
fi
for shape in 'chmod -x --' 'chmod +x --' 'chmod a= --' 'chmod g=u --' \
  'chmod 0755 --' 'chmod -R --'; do
  case "$planted" in
    *"$shape"*) ;;
    *)
      echo "FAIL: the scan does not see '$shape'; the rule above proves nothing" >&2
      exit 1
      ;;
  esac
done

# And the right order is not a violation, or the rule would ban the fix.
# Only the one right shape, plus other commands' `--`, which this rule must
# never touch.
{
  printf '#!/bin/sh\n'
  printf 'chmod -- +x "$f"\n'
  printf 'chmod -- 0755 "$f"\n'
  printf 'chmod -- -x "$f"\n'
  printf 'chmod +x "$f"\n'
  printf 'rm -f -- "$f"\n'
  printf 'mv -f -- "$a" "$b"\n'
  printf 'cat -- "$f"\n'
} >"$probe/clean.sh"
rm -f "$probe/planted.sh"
clean_status=0
grep -rnE "$PATTERN" "$probe" >/dev/null || clean_status=$?
if [[ "$clean_status" -ne 1 ]]; then
  echo "FAIL: the scan flags a correctly ordered chmod (grep exited $clean_status)" >&2
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
