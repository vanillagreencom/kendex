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

# --- shared bash32 pattern set: begin
# Every suite that scans for Bash 4 syntax carries this block verbatim, the
# .agents/skills/ render included.
# tools/tests/bash32-pattern-parity.test.sh holds the copies byte-identical
# and proves the set's teeth once, against the text these files ship. There
# is no file they could source instead: skills install independently, so a
# judge living inside one skill is absent from every install that skips it.
#
# What a text scan cannot decide: whether a script RUNS under Bash 3.2.
# Nothing here does — CI is Linux on Bash 5, and the `bash -n` pass is that
# same shell, so it parses Bash 4 without complaint. A construct assembled at
# runtime — eval, a command held in a variable, a heredoc piped to bash — is
# text this scan does not read as code, and neither is one split over a
# backslash continuation. A clean scan says the source carries no construct
# named below. It says nothing further.
#
# And the set is what it names, not everything Bash 4 added. Parameter
# transformations (${x@Q}), globstar, `wait -n` and `test -v` are outside it
# on purpose; each is its own construct rather than another spelling of one
# below, and adding one means adding its probe and its control with it.
PATTERN='mapfile|readarray'
# declare/typeset/local/readonly carrying a Bash 4 attribute anywhere in the
# options: A (associative), g (global), n (nameref), l and u (the
# declare-family spelling of case conversion). Bash accepts the attributes in
# one cluster or in separate option words, and it accepts them in any order,
# so -A, -rA, -Ar and -r -A are one declaration written four ways and all
# four are caught.
PATTERN="$PATTERN"'|(^|[^[:alnum:]_])(declare|typeset|local|readonly)[[:blank:]]+([-+][[:alnum:]]+[[:blank:]]+)*[-+][[:alnum:]]*[Aglnu]'
# Automatic FD allocation: exec {fd}< , {fd}> , {fd}>>
PATTERN="$PATTERN"'|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
# Case conversion, one character or every one, either direction, over every
# parameter Bash takes it on: a name, a subscripted name, a positional, an
# indirect one, and a special one. The special ones are the manual's list
# rather than the ones that come to mind, and it is shorter than the list of
# special parameters: ${-^}, ${?^} and ${#^} are bad substitutions, so only
# $ ! 0 @ * and _ take the operator, and 0 and _ already read as a name or a
# digit above.
PATTERN="$PATTERN"'|\$\{!?([A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?|[0-9]+|[@*$!])(,,?|\^\^?)'
PATTERN="$PATTERN"'|(^|[^[:alnum:]_])coproc([[:blank:]]|$)'
# The pipe-with-stderr, the append-both redirection, and the two case
# terminators. Each is anchored on BOTH sides, and both sides carry weight:
# wide enough to admit every real token boundary, a bare word or quote or
# brace or blank or line end or an escaped metacharacter, and narrow enough
# to leave a script's own bracket expression alone. Only shapes that cannot
# occur in real shell are excluded, since nothing legal ends a command with a
# bare [ or ; or ( ahead of a pipe, and nothing legal begins one with ] > < )
# ; | & or a backslash after it. Widening one side and not the other reopens
# the side left alone: unanchored, these matched the character classes inside
# preflight's own regexes; anchored on one side only, they missed a quoted
# left boundary and a case arm that runs straight into the next pattern.
#
# The boundary this cannot decide is an escape. `x\(|& cat` is a pipe and
# `[\(|&]` is a character class, and telling them apart is parsing, not
# matching. The anchors take the shapes a pipeline has and let a regex
# literal that spells one through, so a scan is a backstop and never the
# rule: the rule is that every one of these has a Bash 3.2 spelling — `2>&1 |`
# for the pipe, `>>file 2>&1` for the redirection, a repeated case body for
# the fallthrough — and a script that writes those needs no verdict here.
PATTERN="$PATTERN"'|(^|[^[;(]|\\[[;(])\|&([^]><);|&\\]|$)|&>>|(^|[^[]);;?&([^|]|$)'
# --- shared bash32 pattern set: end

check_absent "$PATTERN" "no Bash 4+ construct in scripts/"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
