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
