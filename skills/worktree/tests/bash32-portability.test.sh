#!/usr/bin/env bash
# vacuous-suite-scan: absence-subject
# Regression test for #575: the worktree skill must stay runnable under macOS
# system Bash 3.2, so shipped scripts may not use Bash 4+ builtins or syntax
# (mapfile/readarray, associative arrays, automatic FD-allocation
# redirections, case-conversion expansions).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"

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

# An absent forbidden construct means nothing when there was nothing to look
# in: an empty scripts/ scans clean.
if [ -z "$(find "$SCRIPTS_DIR" -type f)" ]; then
  echo "FAIL: no shipped script found under $SCRIPTS_DIR, so this lint read nothing" >&2
  exit 1
fi

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
  echo "Bash 4+ constructs found in worktree scripts (must run under Bash 3.2):" >&2
  printf '%s\n' "$violations" >&2
  exit 1
fi

echo "all pass"
