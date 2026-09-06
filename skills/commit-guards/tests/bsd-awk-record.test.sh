#!/usr/bin/env bash
# The changelog family's encoding check under BWK awk's record rule, as a
# program rather than a lint.
#
# macOS ships BWK awk ("awk version 20200816"), which holds a record as a
# NUL-terminated C string: a line's content stops at its first NUL. GNU awk
# carries the whole line, so nothing on a Linux runner can see the
# difference by reading the source. It is put in a shim on PATH instead and
# the real check runs under it.
#
# What the rule costs: git calls a blob binary only when a NUL falls in its
# leading sample, so a blob whose only NUL is past that sample is text to
# git and must be text to this family too. Under BWK's rule the UTF-8 pass
# never sees that NUL, the blob measures as the short prefix before it, and
# an unmeasurable file is reported as an over-long entry instead of being
# refused. scripts/lib/changelog-grammar.sh translates every NUL to \200 — a
# stray continuation byte its grammar already rejects — before awk reads a
# byte, which is what this suite pins.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"

unset COMMIT_GUARDS_CHANGELOG_CAP COMMIT_GUARDS_CHANGELOG_PATHS \
  COMMIT_GUARDS_CHANGELOG_RECORD COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

REAL_AWK="$(command -v awk)"
shim="$TMP/shim"
mkdir -p "$shim"
cat >"$shim/awk" <<SHIM
#!/bin/sh
# One argument is a program and its input on stdin, which is how the
# changelog family reads a blob. Every other shape — a file operand, -v, -F —
# passes straight through, so this shim judges that one read and nothing else.
if [ "\$#" -eq 1 ]; then
  perl -pe 's/\\0.*//' | $REAL_AWK "\$1"
  exit \$?
fi
exec $REAL_AWK "\$@"
SHIM
chmod 0755 "$shim/awk"

# The shim has teeth, and only on the shape it means to judge.
truncated="$(printf 'ab\000cd\n' | PATH="$shim:$PATH" awk '{ print length($0) }')"
[ "$truncated" = 2 ] || {
  echo "FAIL: the awk shim does not truncate a record at its NUL (length $truncated)" >&2
  exit 1
}
# Compared against the host's own awk, not against a number: BWK awk truncates
# at a NUL whatever the input is, so on macOS the untouched answer is 2 and on
# GNU it is 5. What must hold on both is that the shim changed nothing here.
printf 'ab\000cd\n' >"$TMP/probe"
whole="$(PATH="$shim:$PATH" awk '{ print length($0) }' "$TMP/probe")"
native="$("$REAL_AWK" '{ print length($0) }' "$TMP/probe")"
[ "$whole" = "$native" ] || {
  echo "FAIL: the awk shim altered a call with a file operand (length $whole, host awk says $native)" >&2
  exit 1
}

# A fragment git calls text: 8100 bytes of content, then the file's only NUL.
plant() { # REPO
  mkdir -p "$1/changelog.d/added"
  {
    printf -- '- '
    i=0
    while [ "$i" -lt 8100 ]; do printf x; i=$((i + 1)); done
    printf '\000tail\n'
  } >"$1/changelog.d/added/late-nul.md"
  git -C "$1" add -A
}

new_repo() { # PATH
  mkdir -p "$1"
  git -C "$1" -c init.defaultBranch=main init -q
  git -C "$1" config user.email t@t
  git -C "$1" config user.name t
}

repo="$TMP/nul"
new_repo "$repo"
plant "$repo"
[ -n "$(git -C "$repo" grep --cached -I -l . -- changelog.d/added)" ] || {
  echo "FAIL: git calls the fixture blob binary, so it is not the case this suite means" >&2
  exit 1
}

out=""
status=0
out="$(cd "$repo" && PATH="$shim:$PATH" "$SKILL_DIR/scripts/changelog-entries" 2>&1)" || status=$?
case "$status:$out" in
  2:*"late-nul.md line 1 is not valid UTF-8"*) ;;
  *)
    echo "FAIL: under BWK awk's record rule the NUL past the sample was not refused (exit $status)" >&2
    printf '%s\n' "$out" >&2
    exit 1
    ;;
esac

# The control: a copy of the package with the translation removed must NOT
# refuse it. Without this the assertion above passes on any check, including
# one that never reads the blob's bytes at all.
broken="$TMP/broken-pkg"
mkdir -p "$broken"
cp -R "$SKILL_DIR" "$broken/commit-guards"
grammar="$broken/commit-guards/scripts/lib/changelog-grammar.sh"
perl -pi -e "s/LC_ALL=C tr '\\\\000' '\\\\200' <\"\\\$GG_TMP\\/blob\" \\| LC_ALL=C awk/LC_ALL=C awk/" "$grammar"
grep -q "tr '\\\\000'" "$grammar" && {
  echo "FAIL: the control could not remove the NUL translation; the assertion below proves nothing" >&2
  exit 1
}
broken_repo="$TMP/broken-repo"
new_repo "$broken_repo"
plant "$broken_repo"
broken_out="$(cd "$broken_repo" && PATH="$shim:$PATH" "$broken/commit-guards/scripts/changelog-entries" 2>&1)" || true
case "$broken_out" in
  *"is not valid UTF-8"*)
    echo "FAIL: must-fail control refused the late NUL with the translation removed" >&2
    exit 1
    ;;
esac

echo "pass: bsd-awk-record"
