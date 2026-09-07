#!/usr/bin/env bash
# Pins for the changelog family's encoding check under BWK awk's record
# rule, as a program rather than a lint. macOS ships BWK awk, which holds a
# record as a NUL-terminated C string: a line's content stops at its first
# NUL. GNU awk carries the whole line, so nothing on a Linux runner can see
# the difference by reading the source; the rule is put in a shim on PATH
# and the real check runs under it. What the rule costs: git calls a blob
# binary only when a NUL falls in its leading sample, so a blob whose only
# NUL is past that sample is text to git and must be text to this family
# too. Under BWK's rule the UTF-8 pass never sees that NUL, the blob measures
# as the short prefix before it, and an unmeasurable file is reported as an
# over-long entry instead of being refused. scripts/lib/changelog-grammar.sh
# translates every NUL to \200, a stray continuation byte its grammar
# already rejects, before awk reads a byte; this suite pins that.
#
# One table: PACKAGE is the shipped skill or a copy with the translation
# removed; changelog-entries runs under the shim over a fragment git calls
# text, and the row pins the exit status with every line printed.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
unset COMMIT_GUARDS_CHANGELOG_CAP COMMIT_GUARDS_CHANGELOG_PATHS \
  COMMIT_GUARDS_CHANGELOG_RECORD COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# The BWK rule, as a program: one argument is a program with its input on
# stdin, which is how the changelog family reads a blob; that read is
# truncated at each record's first NUL. Every other shape (a file operand,
# -v, -F) passes straight through, so the shim judges that one read only.
REAL_AWK="$(command -v awk)"
shim="$TMP/shim"
mkdir -p "$shim"
cat >"$shim/awk" <<SHIM
#!/bin/sh
if [ "\$#" -eq 1 ]; then
  perl -pe 's/\\0.*//' | $REAL_AWK "\$1"
  exit \$?
fi
exec $REAL_AWK "\$@"
SHIM
chmod 0755 "$shim/awk"

echo "=== premise: the shim truncates the one read it means to judge and nothing else ==="
printf 'ab\000cd\n' >"$TMP/probe"
PATH="$shim:$PATH"
assert_eq "a program over stdin sees the record end at its NUL" "2" "$(awk '{ print length($0) }' <"$TMP/probe")"
# Compared against the host's own awk, not a number: BWK truncates whatever
# the input, so the untouched answer is 2 on macOS and 5 on GNU.
assert_eq "control: a file operand reads as the host's awk reads it" "$("$REAL_AWK" '{ print length($0) }' "$TMP/probe")" "$(awk '{ print length($0) }' "$TMP/probe")"

# The fragment: 8100 bytes of content, then the file's only NUL, past the
# sample git sniffs; git calls it text, and its measure under BWK's rule is
# the prefix.
XS="$(i=0; while [ "$i" -lt 8100 ]; do printf x; i=$((i + 1)); done)"
plant() { # REPO
  mkdir -p "$1/changelog.d/added"
  printf -- '- %s\000tail\n' "$XS" >"$1/changelog.d/added/late-nul.md"
  git -C "$1" add -A
}
R="$TMP/nul"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email t@t
git -C "$R" config user.name t
plant "$R"
assert_eq "premise: git calls the fragment text" "changelog.d/added/late-nul.md" "$(git -C "$R" grep --cached -I -l . -- changelog.d/added)"

# Fixture vocabulary: the package a row runs.
PKG=""
real() { PKG="$SKILL_DIR"; }
broken() { # the package with the NUL translation removed
  PKG="$TMP/broken-pkg/commit-guards"
  mkdir -p "$TMP/broken-pkg"
  cp -R "$SKILL_DIR" "$PKG"
  perl -pi -e "s/LC_ALL=C tr '\\\\000' '\\\\200' <\"\\\$GG_TMP\\/blob\" \\| LC_ALL=C awk/LC_ALL=C awk/" "$PKG/scripts/lib/changelog-grammar.sh"
}
run() { # — the exit status and every line printed by PKG's changelog-entries over the fragment
  local rc=0 out=""
  out="$(cd "$R" && "$PKG/scripts/changelog-entries" 2>&1)" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}
run_rows() { # label | package | expect
  local row label pkg expect
  for row in "$@"; do
    IFS='|' read -r label pkg expect <<<"$row"
    PKG=""
    "$pkg"
    assert_eq "$label" "$expect" "$(run)"
  done
}

echo "=== premise: the broken package holds no translation ==="
broken
assert_eq "the control removed the NUL translation" "0" "$(grep -c "tr '\\\\000'" "$PKG/scripts/lib/changelog-grammar.sh")"

echo "=== a NUL past git's sample is refused as unmeasurable under BWK's record rule, not reported as a long entry ==="
run_rows \
  "the shipped package refuses the fragment naming its line|real|rc=2 ::error::changelog-entries: changelog.d/added/late-nul.md line 1 is not valid UTF-8 — text with no character count cannot be measured" \
  "control: without the translation the record ends at the NUL and the prefix is measured as an over-long entry|broken|rc=1 changelog-entries FAIL long entry: changelog.d/added/late-nul.md — 8102 characters (cap 200);  entry: - $XS;  remedies: state the outcome and stop; a Breaking migration note stays inline, and the reasoning belongs in the commit;changelog-entries: 1 violation(s) — cap 200 characters, 1 fragment(s) measured"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
