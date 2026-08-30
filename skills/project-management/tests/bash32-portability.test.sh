#!/usr/bin/env bash
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
# The Bash 4 builtins and the coproc keyword, bounded by the shell's word
# delimiters on both sides: blank, tab, `|`, `&`, `;`, `(`, `)`, `<`, `>`,
# backquote, and the line ends. That is the whole rule and it comes from the
# grammar, not from spellings.
#
# The bound is the WORD, not the identifier. `coproc=1` is an assignment
# token, `coproc-wrapper` a command name, `x=coproc` a value and
# `run --local` an option: in each the shell reads one word and none of them
# is the keyword, though every one of them ends an identifier. Bounding on
# the identifier flagged all four, which is the failure that matters most
# here — a portability suite that reddens correct Bash 3.2 source is one the
# first person it blocks turns off. The catches are unaffected:
# `coproc(echo hi)`, `coproc FOO`, `x && coproc reader`, `run;coproc cat`.
#
# This is the difference from the operators below, where the grammar gives no
# usable boundary and none is attempted.
PATTERN='(^|[[:blank:]|&;()<>`])(mapfile|readarray|coproc)([[:blank:]|&;()<>]|$)'
# declare/typeset/local/readonly carrying a Bash 4 attribute anywhere in the
# options: A (associative), g (global), n (nameref), l and u (the
# declare-family spelling of case conversion). Bash accepts the attributes in
# one cluster or in separate option words, and it accepts them in any order,
# so -A, -rA, -Ar and -r -A are one declaration written four ways and all
# four are caught. The command word takes the same word boundary as the names
# above, for the same reason: `my-declare -A x` and `run --local -A x` are
# legal Bash 3.2 and an identifier boundary flagged both.
PATTERN="$PATTERN"'|(^|[[:blank:]|&;()<>`])(declare|typeset|local|readonly)[[:blank:]]+([-+][[:alnum:]]+[[:blank:]]+)*[-+][[:alnum:]]*[Aglnu]'
# Automatic FD allocation: exec {fd}< , {fd}> , {fd}>>
PATTERN="$PATTERN"'|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
# Case conversion, one character or every one, either direction. The
# parameter forms come from the manual's lists rather than from recall: a
# name, a subscripted name, a positional, an indirect one, and the special
# ones, $ ! # ? - 0 @ and *. Bash 5.3 answers ${-^}, ${?^} and ${#^} with
# "bad substitution" instead of converting; they are matched all the same,
# since a line carrying one is broken under every bash and no correct 3.2
# source holds one, so taking the whole list reddens nothing legal.
# A subscript may hold one level of nesting, which is what indexing an array
# with another array's element needs: ${arr[x[0]]^}. Deeper than that is a
# stated limit below, not an oversight.
PATTERN="$PATTERN"'|\$\{!?([A-Za-z_][A-Za-z0-9_]*(\[([^][]|\[[^]]*\])*\])?|[0-9]+|[-#?$!@*])(,,?|\^\^?)'
# The pipe-with-stderr, the append-both redirection, and the two case
# terminators, matched plainly. There is no boundary anchor here, and that is
# a decision rather than an omission.
#
# Neighbouring characters cannot separate an operator from the same bytes
# inside a regex literal or a string, because the shell grammar permits
# almost anything on either side of one. `printf x |&]` parses, and so do
# `|&/bin/cat`, `|&'cat'`, `|&>out` and `x\(|& cat`. A right-hand set taken
# from the grammar must therefore admit `]`, and admitting `]` matches the
# bracket expression `[|&]` again. Four rounds of anchoring found the
# boundary too permissive twice and too restrictive twice; a rule that costs
# a door per round is the wrong rule, not an under-specified one.
#
# So the cost moves from an unauditable regex to a visible line. A script
# that spells one of these operators inside its own regex or string data IS
# flagged, and the fix is to write it so it does not: a bracket expression's
# members carry no order, so [;|&(`{] becomes [;(`{&|] and matches exactly
# the same characters. skills/preflight/scripts/preflight carries the six
# sites that needed it. A script that genuinely cannot avoid the spelling has
# no escape hatch here yet, and adding one is a change to make then.
#
# WHAT THIS CANNOT DECIDE, named so the next reader does not file it again.
#
# ONE SENTENCE COVERS ALL OF IT: a text scan reads text, and the shell reads
# words. Every gap below is that, in one direction or the other — a name the
# shell resolves through quote removal that the text does not spell, or text
# that spells a construct the shell never runs. Neither is an oversight and
# neither is chased; the answer to both is a lane that runs these suites
# under a real Bash 3.2, filed as this PR's follow-up.
#
# The misses are checked as misses in
# tools/tests/data/bash32-uncatchable.txt and the over-flags as over-flags in
# bash32-overflagged.txt, so neither list can quietly go stale:
#
#   - a name the shell reaches through quote removal: `'mapfile' -t v`,
#     `"declare" -A c`, `map\file -t v`. Bash strips the quoting before it
#     looks the word up, and doing that is the shell's job, not a scan's.
#   - a construct anywhere in the file text is flagged, comment or string
#     alike: `# never use coproc here`, `x=1  # no coproc`, `printf '%s\n'
#     "use coproc here"`. There is no comment skip, and that is deliberate.
#     A `#` line inside a multiline double-quoted word is LIVE CODE that bash
#     expands, so skipping `#` lines let `${name^^}` through a portability
#     gate in silence. Telling the two apart is lexing, and every cheap
#     approximation of it drops hits — it fails open, just less often. This
#     way the cost is loud, lands on whoever wrote the line, and is fixed by
#     respelling it, as preflight's brackets and orch's comments now are.
#   - an operator inside a regex literal or string data is flagged for the
#     same reason. That is the accepted cost of matching operators plainly,
#     and the fix is to respell the line as preflight's brackets now are.
#   - a subscript nested more than one level, or one whose inner expansion
#     carries a literal `]`, as in ${arr[${x%]}]^}. Balancing brackets is
#     beyond a regular expression, so the depth is bounded and declared
#     rather than guessed at.
#   - a construct assembled at runtime: eval, a command held in a variable, a
#     heredoc piped to bash. The text never appears, so nothing reads it.
#   - a declaration split over a backslash continuation, which a
#     line-oriented scan does not see at all.
#   - whether a script RUNS under Bash 3.2. Nothing here does.
#
# What covers these is not another pattern. Each SKILL.md declares the shell
# floor its scripts run on, and a lane running these suites under a real Bash
# 3.2 on the macOS runner is filed as the follow-up to this PR. Until that
# lands, every construct above has a Bash 3.2 spelling — `2>&1 |` for the
# pipe, `>>file 2>&1` for the redirection, a repeated case body for the
# fallthrough — and a script that writes those needs no verdict here.
PATTERN="$PATTERN"'|\|&|&>>|;;?&'
# --- shared bash32 pattern set: end

check_absent "$PATTERN" "no Bash 4+ construct in scripts/"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
