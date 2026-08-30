#!/usr/bin/env bash
# vacuous-suite-scan: absence-subject
# orch's scripts run wherever an orchestrator runs, and `skills/orch/SKILL.md`
# § System dependencies declares `bash` 3.2 — macOS system bash. So a shipped
# orch script may not use a Bash 4+ builtin or syntax: mapfile/readarray,
# associative arrays, automatic FD-allocation redirections, case-conversion
# expansions.
#
# KEN-837 is why this suite exists. `local -A pane_cmd` reached
# `scripts/lib/lane-context.sh` and every gate stayed green, because the shell
# shard runs on ubuntu only (`.github/workflows/skill-tests.yml`). Bash 3.2
# rejects `local -A` as an invalid option, and under that file's `set -euo
# pipefail` it aborts `lanes context` outright rather than losing one lane. A
# reviewer caught it by hand and #1847 removed it; nothing else would have.
#
# Comment lines are not scanned. orch documents this prohibition inside the
# scripts it constrains — `scripts/git-context` and `scripts/lib/lane-context.sh`
# both name the construct they avoid and why — and a lint that reds its own
# contract teaches the next author to delete the explanation instead of the
# construct. Case b.4 pins the skip to comments; b.1-b.3 prove code is still
# caught, so the skip cannot be what makes this suite green.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
}
fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$1"
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
# The Bash 4 builtins and the coproc keyword. A name is delimited by the
# characters an identifier cannot hold, so this rule is complete and is
# stated from the grammar rather than from spellings: `coproc(echo hi)` and
# `coproc FOO` are the keyword, `coprocess=1` and `remapfile` are not. That
# is the difference from the operators below, where the grammar gives no
# usable boundary and none is attempted.
PATTERN='(^|[^[:alnum:]_])(mapfile|readarray|coproc)([^[:alnum:]_]|$)'
# declare/typeset/local/readonly carrying a Bash 4 attribute anywhere in the
# options: A (associative), g (global), n (nameref), l and u (the
# declare-family spelling of case conversion). Bash accepts the attributes in
# one cluster or in separate option words, and it accepts them in any order,
# so -A, -rA, -Ar and -r -A are one declaration written four ways and all
# four are caught.
PATTERN="$PATTERN"'|(^|[^[:alnum:]_])(declare|typeset|local|readonly)[[:blank:]]+([-+][[:alnum:]]+[[:blank:]]+)*[-+][[:alnum:]]*[Aglnu]'
# Automatic FD allocation: exec {fd}< , {fd}> , {fd}>>
PATTERN="$PATTERN"'|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
# Case conversion, one character or every one, either direction. The
# parameter forms come from the manual's lists rather than from recall: a
# name, a subscripted name, a positional, an indirect one, and the special
# ones, $ ! # ? - 0 @ and *. Bash 5.3 answers ${-^}, ${?^} and ${#^} with
# "bad substitution" instead of converting; they are matched all the same,
# since a line carrying one is broken under every bash and no correct 3.2
# source holds one, so taking the whole list reddens nothing legal.
PATTERN="$PATTERN"'|\$\{!?([A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?|[0-9]+|[-#?$!@*])(,,?|\^\^?)'
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
# A regex reads text; deciding which text is code is parsing. These are that
# boundary rather than oversights. The misses are checked as misses in
# tools/tests/data/bash32-uncatchable.txt and the over-flags as over-flags in
# bash32-overflagged.txt, so neither list can quietly go stale:
#
#   - an operator inside a regex literal, a string or a comment is flagged.
#     That is the accepted cost of matching operators plainly, and the fix is
#     to respell the line the way preflight's bracket expressions now are.
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

# scan_bash4 <dir>
# Emits one `file:line:text` line per Bash 4+ construct found on a non-comment
# line of any regular file under <dir>. Exits 2 when the scan could not run: a
# scan that did not run is not a clean tree, and every caller below tells the
# two apart.
scan_bash4() {
    local dir="$1" list="$TMP_ROOT/scan-list.$$" f hits status
    find "$dir" -type f >"$list" || return 2
    LC_ALL=C sort -o "$list" "$list" || return 2
    while IFS= read -r f; do
        hits=""
        status=0
        # `--` before the operand: a path beginning with `-` parses as options
        # otherwise. grep's status is part of the answer — 0 found, 1 none,
        # anything else a scan that did not run.
        hits="$(grep -nE -- "$PATTERN" "$f")" || status=$?
        if [ "$status" -gt 1 ]; then
            printf 'grep exited %s over %s\n' "$status" "$f" >&2
            return 2
        fi
        [ -n "$hits" ] || continue
        printf '%s\n' "$hits" |
            awk -v f="$f" '!/^[0-9]+:[[:blank:]]*#/ { print f ":" $0 }'
    done <"$list"
}

# count_scripts <dir> — regular files under <dir>, the number this lint read.
count_scripts() {
    find "$1" -type f | wc -l | tr -d ' '
}

# probe_dir <name> <line> — a one-file scripts/ holding <line> as its body.
probe_dir() {
    local d="$TMP_ROOT/probe-$1"
    mkdir -p "$d"
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$2"
    } >"$d/probe"
    printf '%s' "$d"
}

# a.1 — the shipped scripts are clean, which is the assertion this file exists
# to make.
violations=""
scan_status=0
violations="$(scan_bash4 "$SCRIPTS_DIR")" || scan_status=$?
if [ "$scan_status" -ne 0 ]; then
    fail "the portability scan over $SCRIPTS_DIR could not run (exit $scan_status)"
elif [ -n "$violations" ]; then
    fail "Bash 4+ constructs in orch scripts (they must run under Bash 3.2):"
    printf '%s\n' "$violations" >&2
else
    pass "no Bash 4+ construct in any shipped orch script"
fi

# a.2 — an absent forbidden construct means nothing when there was nothing to
# look in: an empty scripts/ scans clean.
shipped="$(count_scripts "$SCRIPTS_DIR")"
if [ "$shipped" -gt 0 ]; then
    pass "the scan read $shipped shipped orch script(s)"
else
    fail "no shipped script found under $SCRIPTS_DIR, so this lint read nothing"
fi

# a.3 — and every one of them parses. A construct this pattern set does not
# name still has to be syntax.
syntax_fail=0
while IFS= read -r f; do
    if ! bash -n -- "$f"; then
        fail "bash -n $f"
        syntax_fail=1
    fi
done < <(find "$SCRIPTS_DIR" -type f | LC_ALL=C sort)
[ "$syntax_fail" -eq 1 ] || pass "every shipped orch script parses under bash -n"

# b.1-b.3 — teeth, one per pattern group, injected as code the way KEN-837's
# `local -A` arrived.
for probe in \
    "associative-array:local -A pane_cmd" \
    "mapfile:mapfile -t lanes < panes.txt" \
    "case-conversion:head_lower=\"\${head,,}\"" \
    "fd-allocation:exec {lock_fd}<\"\$lockfile\""; do
    name="${probe%%:*}"
    line="${probe#*:}"
    probe_status=0
    hits="$(scan_bash4 "$(probe_dir "$name" "$line")")" || probe_status=$?
    if [ "$probe_status" -ne 0 ]; then
        fail "scan could not run over the $name probe (exit $probe_status)"
    elif [ -n "$hits" ]; then
        pass "lint flags an injected $name"
    else
        fail "lint MISSED an injected $name (no teeth)"
    fi
done

# b.4 — and the documented exception is exactly that: the same construct, on a
# comment line, is not a violation.
comment_status=0
hits="$(scan_bash4 "$(probe_dir comment '  # has none and rejects `local -A`, which errexit would abort on')")" || comment_status=$?
if [ "$comment_status" -ne 0 ]; then
    fail "scan could not run over the comment probe (exit $comment_status)"
elif [ -z "$hits" ]; then
    pass "lint ignores a comment naming a forbidden construct"
else
    fail "lint false-flagged a comment naming a forbidden construct"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
