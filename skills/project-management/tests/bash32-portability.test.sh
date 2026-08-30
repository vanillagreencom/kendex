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
# Every suite that scans for Bash 4 syntax carries this block verbatim.
# tools/tests/bash32-pattern-parity.test.sh holds the copies byte-identical
# and proves the set's teeth once, against the text these files ship. There
# is no file they could source instead: skills install independently, so a
# judge living inside one skill is absent from every install that skips it.
#
# What a text scan cannot decide: whether a script RUNS under Bash 3.2.
# Nothing here does — CI is Linux on Bash 5, and the `bash -n` pass is that
# same shell, so it parses Bash 4 without complaint. A construct assembled at
# runtime — eval, a command held in a variable, a heredoc piped to bash — is
# text this scan does not read as code. A clean scan says the source carries
# no construct named below. It says nothing further.
PATTERN='mapfile|readarray'
# declare/typeset/local/readonly whose flag cluster holds A (associative),
# g (global) or n (nameref): -A, -rA, -Ag, -g, -n.
PATTERN="$PATTERN"'|(^|[^[:alnum:]_])(declare|typeset|local|readonly)[[:blank:]]+-[[:alnum:]]*[Agn]'
# Automatic FD allocation: exec {fd}< , {fd}> , {fd}>>
PATTERN="$PATTERN"'|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
# Case conversion, one character (${x^}) or every one (${x^^}), either way.
PATTERN="$PATTERN"'|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,?|\^\^?)'
PATTERN="$PATTERN"'|(^|[^[:alnum:]_])coproc([[:blank:]]|$)'
# |&, &>>, and the ;& / ;;& case terminators. Anchored on the operator's
# neighbours, so a bracket expression in a script's own regex — [;|&(] — is
# not read as a pipe.
PATTERN="$PATTERN"'|(^|[[:blank:]]|[[:alnum:]_)}])\|&|&>>|;;?&([[:blank:]]|$)'
# --- shared bash32 pattern set: end

check_absent "$PATTERN" "no Bash 4+ construct in scripts/"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
