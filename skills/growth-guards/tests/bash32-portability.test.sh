#!/usr/bin/env bash
# growth-guards runs on consumer CI images and on macOS system Bash 3.2, so
# shipped scripts may not use Bash 4+ builtins or syntax (mapfile/readarray,
# associative arrays, automatic FD-allocation redirections, case-conversion
# expansions).
#
# And the utilities are BSD there, not GNU. That half used to be a text scan
# for the shapes a BSD utility rejects, and it was wrong four times running:
# each spelling missed an argument form the next reviewer found, because a
# lint over shell source has no bottom — the same command can be written in
# more ways than a regex can enumerate, and every round only moved the edge.
#
# So it is not read any more, it is RUN. The BSD rule is put in a shim on
# PATH and the real installer executes under it, which cannot be evaded by
# spelling: whatever the scripts call chmod with, the shim judges it the way
# macOS would. The merge-group macOS lane stays the platform proof; this is
# what every Linux run can say on its own.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
. "$TEST_DIR/lib/harness.bash"

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

# The BSD argv rule, as a program the installer actually runs.
#
# getopt(3) stops at the first non-option argument. For chmod that argument
# is the mode, so every token after it is a file operand — and a `--` there
# is a file named `--`, which does not exist. BSD chmod fails on it. GNU
# permutes its arguments and accepts the same line, which is why this can
# only be caught by judging the call rather than by reading the source.
shim="$TMP/shim"
mkdir -p "$shim"
cat >"$shim/chmod" <<'SHIM'
#!/bin/sh
# Options first, exactly as getopt(3) takes them.
while [ $# -gt 0 ]; do
  case "$1" in
    # `--` here ends option parsing: the mode follows. This is the one
    # correct shape, and it is passed straight through.
    --)
      shift
      break
      ;;
    -[RfhvHLP]*) shift ;;
    # Anything else is the mode, and option parsing is over.
    *) break ;;
  esac
done
# From here every argument is a file operand. A `--` among them is a file
# nobody has.
mode="${1-}"
[ $# -gt 0 ] && shift
for arg in "$@"; do
  if [ "$arg" = "--" ]; then
    echo "chmod: --: No such file or directory" >&2
    exit 1
  fi
done
exec /bin/chmod "$mode" "$@"
SHIM
chmod 0755 "$shim/chmod"

# The shim has teeth, and only on the wrong shape.
: >"$TMP/probe-file"
if PATH="$shim:$PATH" chmod +x -- "$TMP/probe-file" 2>/dev/null; then
  echo "FAIL: the shim accepts a trailing --, so it judges nothing" >&2
  exit 1
fi
if ! PATH="$shim:$PATH" chmod -- +x "$TMP/probe-file" 2>/dev/null; then
  echo "FAIL: the shim rejects the correct order, so it would fail any installer" >&2
  exit 1
fi
[ -x "$TMP/probe-file" ] || {
  echo "FAIL: the shim did not exec the real chmod" >&2
  exit 1
}

# A repository, and the package installed into it the way a consumer has it.
repo="$TMP/bsd-repo"
mkdir -p "$repo/.agents/skills"
git -C "$repo" init -q
git -C "$repo" config user.email t@t
git -C "$repo" config user.name t
cp -R "$SCRIPTS_DIR/.." "$repo/.agents/skills/growth-guards"
installer="$repo/.agents/skills/growth-guards/scripts/install-git-hooks"

out=""
status=0
out="$(PATH="$shim:$PATH" "$installer" --repo "$repo" 2>&1)" || status=$?
if [ "$status" -ne 0 ]; then
  echo "FAIL: the install failed under BSD chmod argv rules (exit $status)" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# git ignores a hook without the bit, so this is the assertion that matters:
# not that the installer said armed, but that the files it wrote can run.
for lane in pre-commit commit-msg kendex-guards; do
  [ -x "$repo/.git/hooks/$lane" ] || {
    echo "FAIL: $lane is not executable after an install under BSD chmod" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
done

# And the package's own verdict agrees, which is the pair that came apart on
# macOS: two hooks reported armed over a repository that gated nothing.
check=""
check_status=0
check="$(PATH="$shim:$PATH" "$installer" --repo "$repo" --check 2>&1)" || check_status=$?
if [ "$check_status" -ne 0 ]; then
  echo "FAIL: --check does not read the repository as armed (exit $check_status)" >&2
  printf '%s\n' "$check" >&2
  exit 1
fi

# The control: a copy of the package with the wrong order restored must NOT
# come out armed. Without this the pin passes on any installer, including one
# that never calls chmod at all.
broken="$TMP/broken"
mkdir -p "$broken/.agents/skills"
git -C "$broken" init -q
git -C "$broken" config user.email t@t
git -C "$broken" config user.name t
cp -R "$SCRIPTS_DIR/.." "$broken/.agents/skills/growth-guards"
broken_installer="$broken/.agents/skills/growth-guards/scripts/install-git-hooks"
perl -pi -e 's/chmod -- \+x/chmod +x --/; s/chmod -- 0755/chmod 0755 --/' "$broken_installer"
grep -q 'chmod +x --' "$broken_installer" || {
  echo "FAIL: the control could not restore the wrong order; the assertion below proves nothing" >&2
  exit 1
}
PATH="$shim:$PATH" "$broken_installer" --repo "$broken" >/dev/null 2>&1 || true
if [ -x "$broken/.git/hooks/pre-commit" ] && [ -x "$broken/.git/hooks/commit-msg" ]; then
  echo "FAIL: must-fail control armed under BSD chmod with the wrong argv order" >&2
  exit 1
fi

echo "pass: bash32-portability"
