#!/usr/bin/env bash
# vacuous-suite-scan: absence-subject
# The review-gate scripts run on consumer CI images and on macOS system Bash
# 3.2, so shipped scripts may not use Bash 4+ builtins or syntax
# (mapfile/readarray, associative arrays, automatic FD-allocation
# redirections, case-conversion expansions). The suites that drive those
# scripts are scanned too: a Bash 4 construct breaks a test run on macOS
# system bash exactly as it breaks a script, and CI is Linux/Bash 5, so
# nothing else catches it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
SELF="${BASH_SOURCE[0]##*/}"

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
# parameter Bash takes it on: a name, a subscripted name, a positional, @ or
# *, and an indirect one.
PATTERN="$PATTERN"'|\$\{!?([A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?|[0-9]+|[@*])(,,?|\^\^?)'
PATTERN="$PATTERN"'|(^|[^[:alnum:]_])coproc([[:blank:]]|$)'
# The pipe-with-stderr, the append-both redirection, and the two case
# terminators. Each is anchored on BOTH sides, and both sides carry weight:
# wide enough to admit every real token boundary, a bare word or quote or
# brace or blank or line end, and narrow enough to leave a script's own
# bracket expression alone. Only shapes that cannot occur in real shell are
# excluded, since nothing legal ends a command with [ or ; or ( ahead of a
# pipe, starts one with ) after it, or puts a bare alternation bar after a
# case terminator. Widening one side and not the other reopens the side left
# alone: unanchored, these matched the character classes inside preflight's
# own regexes; anchored on one side only, they missed a quoted left boundary
# and a case arm that runs straight into the next pattern.
PATTERN="$PATTERN"'|(^|[^[;(])\|&([^)]|$)|&>>|(^|[^[]);;?&([^|]|$)'
# --- shared bash32 pattern set: end
# BSD dirname/basename can reject the `--` end-of-options marker; use
# parameter expansion (or a path that cannot start with '-') instead.
PATTERN="$PATTERN"'|(dirname|basename) +--( |$)'
# `"${@}"` is NOT `"$@"`: with no positional parameters and `set -u`, Bash
# 3.2.57 aborts on the braced spelling with `@: unbound variable` while the
# bare one expands to nothing. Same guard shape as an empty array —
# `${@+"$@"}` — or just write `"$@"`.
PATTERN="$PATTERN"'|\$\{@\}'

# Shell files only — a fixture or data file under either directory is not
# code this lint speaks for, and a false positive here reds a required
# shard. Discovery is `find`, and the scan below is plain `grep -nE` one
# file at a time: `--include`/`--exclude`/`-H` are all outside POSIX grep,
# and a lint whose job is protecting BSD userland must not itself depend on
# an extension it cannot exercise in CI.
sh_files=()
while IFS= read -r f; do
  sh_files[${#sh_files[@]}]="$f"
done < <(find "$SCRIPTS_DIR" "$TEST_DIR" -type f -name '*.sh' | LC_ALL=C sort)
if [ "${#sh_files[@]}" -eq 0 ]; then
  echo "FAIL: no shell files found under $SCRIPTS_DIR or $TEST_DIR" >&2
  exit 1
fi
# And the two directories are counted apart. tests/ always holds this file, so
# the check above is satisfied by an empty scripts/ — and an absent forbidden
# construct means nothing when there was nothing shipped to look in.
script_files=0
for f in ${sh_files[@]+"${sh_files[@]}"}; do
  case "$f" in
  "$SCRIPTS_DIR"/*) script_files=$((script_files + 1)) ;;
  esac
done
if [ "$script_files" -eq 0 ]; then
  echo "FAIL: no shell file found under $SCRIPTS_DIR, so this lint read no shipped script" >&2
  exit 1
fi

nl='
'
violations=""
for f in ${sh_files[@]+"${sh_files[@]}"}; do
  # This file is skipped: it carries every pattern above as data.
  if [ "${f##*/}" = "$SELF" ]; then
    continue
  fi
  # `--` before the operands: a path beginning with `-` is parsed as options
  # otherwise. It goes to grep and `bash -n`, which accept it, and NOT to
  # dirname/basename, which reject it on BSD (see the pattern above).
  # grep's status is part of the answer: 0 found, 1 none, anything else is a
  # scan that did not run — and a scan that did not run is not a clean file.
  hits=""
  scan_status=0
  hits="$(grep -nE -- "$PATTERN" "$f")" || scan_status=$?
  if [ "$scan_status" -gt 1 ]; then
    echo "FAIL: the portability scan over $f could not run (grep exited $scan_status)" >&2
    exit 1
  fi
  if [ -n "$hits" ]; then
    violations="$violations$(printf '%s\n' "$hits" | sed "s|^|$f:|")$nl"
  fi
done
if [[ -n "$violations" ]]; then
  echo "Bash 4+ constructs found in review-gate scripts/tests (must run under Bash 3.2):" >&2
  printf '%s' "$violations" >&2
  exit 1
fi

# Syntax-check every shipped script and suite while we are here — the same
# discovered set, this file included.
fail=0
for f in ${sh_files[@]+"${sh_files[@]}"}; do
  if ! bash -n -- "$f"; then
    echo "FAIL: bash -n $f"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1

echo "pass: bash32-portability"
