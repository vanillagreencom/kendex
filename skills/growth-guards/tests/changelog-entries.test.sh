#!/usr/bin/env bash
# Pins for scripts/changelog-entries, the one judge of a repository's
# changelog over two scopes: a fragment is a real text file under a section
# directory holding exactly one list item within the character cap, every
# other tracked path in the fragment tree is refused, and the collated record
# gains no line under [Unreleased] that HEAD does not carry. Its --collate
# write path is pinned next door in changelog-collate.test.sh.
# The configured globs decide what is read, content comes from the index, and
# a scan that could not complete is exit 2. Every green assertion is paired
# with a control that proves it can fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CE="$SKILL_DIR/scripts/changelog-entries"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"

# Hermetic: a leaked setting would mask every case below.
unset GROWTH_GUARDS_CHANGELOG_CAP GROWTH_GUARDS_CHANGELOG_PATHS \
  GROWTH_GUARDS_CHANGELOG_RECORD GROWTH_GUARDS_CHANGELOG_COLLATE \
  GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME — fresh fixture repo in $R
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

run_ce() { # [args...] — run in $R; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$CE" "$@" 2>&1)" || RC=$?
}

run_ce_env() { # KEY=VALUE... — run in $R under those settings; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && env "$@" "$CE" 2>&1)" || RC=$?
}

stage() { git -C "$R" add -A; }

frag() { # SECTION NAME — content on stdin, written and staged
  mkdir -p "$R/changelog.d/$1"
  cat >"$R/changelog.d/$1/$2"
  stage
}

# N copies of a character, so a fixture states the length it means instead of
# carrying a literal nobody can count. The loop counts copies rather than
# measuring the string: ${#out} is characters or bytes depending on the
# caller's locale, which would make every multibyte fixture below a different
# size under LC_ALL=C than under a UTF-8 locale.
rep() { # CHAR N
  local c="$1" n="$2" i=0 out=""
  while [ "$i" -lt "$n" ]; do
    out="$out$c"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

echo "=== control: a repo with no fragments passes, saying nothing matched ==="
new_repo nofragments
printf 'fn main() {}\n' >"$R/ok.rs"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"no tracked file matches"*"changelog.d"*) true ;; *) false ;; esac \
  && ok "no fragment tree is a clean pass naming the paths it looked for" \
  || bad "no fragment tree is a clean pass naming the paths it looked for" "rc=$RC out=$OUT"

echo "=== a fragment over the cap fails; one under it passes ==="
new_repo cap
printf -- '- A short entry.\n' | frag fixed short.md
printf -- '- %s\n' "$(rep x 205)" | frag fixed long.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"FAIL long entry: changelog.d/fixed/long.md — 207 characters (cap 200)"*) true ;; *) false ;; esac \
  && ok "an over-cap fragment fails, naming file, length and cap" \
  || bad "an over-cap fragment fails, naming file, length and cap" "rc=$RC out=$OUT"
case "$OUT" in *"entry: - xxx"*) ok "the diagnostic quotes the entry's first line" ;; *) bad "the diagnostic quotes the entry's first line" "$OUT" ;; esac
case "$OUT" in *"remedies: state the outcome and stop"*) ok "the diagnostic carries the remediation" ;; *) bad "the diagnostic carries the remediation" "$OUT" ;; esac
case "$OUT" in *short.md*) bad "the short fragment is not named" "$OUT" ;; *) ok "the short fragment is not named" ;; esac
case "$OUT" in *"changelog-entries: OK"*) bad "no OK verdict may accompany a violation" "$OUT" ;; *) ok "no OK verdict accompanies the violation" ;; esac

echo "=== the boundary is exact: cap passes, cap+1 fails ==="
new_repo boundary
printf -- '- %s\n' "$(rep x 198)" | frag fixed b.md
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"1 fragment(s) within the cap (200 characters)"*) true ;; *) false ;; esac \
  && ok "an entry of exactly 200 characters passes" \
  || bad "an entry of exactly 200 characters passes" "rc=$RC out=$OUT"
printf -- '- %s\n' "$(rep x 199)" | frag fixed b.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"201 characters (cap 200)"*) true ;; *) false ;; esac \
  && ok "one character past the cap fails" \
  || bad "one character past the cap fails" "rc=$RC out=$OUT"

echo "=== the cap is the whole length rule: no line count ==="
new_repo lines
{
  printf -- '- Six short lines\n'
  printf '  second\n  third\n  fourth\n  fifth\n  sixth.\n'
} | frag fixed six.md
run_ce
[ "$RC" -eq 0 ] && ok "a six-line entry inside the cap passes" \
  || bad "a six-line entry inside the cap passes" "rc=$RC out=$OUT"
# The control: the same shape past the cap does fail, so the pass above is
# the length answering and not the check declining to look.
{
  printf -- '- Six long lines\n'
  printf '  %s\n' "$(rep y 60)" "$(rep y 60)" "$(rep y 60)" "$(rep y 60)"
} | frag fixed six.md
run_ce
[ "$RC" -eq 1 ] && ok "control: the same shape past the cap fails" \
  || bad "control: the same shape past the cap fails" "rc=$RC out=$OUT"

echo "=== wrapping spends no cap: the same text joins to the same length ==="
new_repo wrapping
{
  printf -- '- %s\n' "$(rep a 60)"
  printf '  %s\n' "$(rep a 60)" "$(rep a 60)"
  printf '\n'
  printf '  %s\n' "$(rep a 15)"
} | frag fixed wrapped.md
run_ce
[ "$RC" -eq 0 ] && ok "a wrapped entry with an indented second paragraph is measured whole and passes" \
  || bad "a wrapped entry with an indented second paragraph is measured whole and passes" "rc=$RC out=$OUT"
# 2 for the marker, four runs joined by three collapsed spaces: 2 + 60*3 + 3 + 16.
{
  printf -- '- %s\n' "$(rep a 60)"
  printf '  %s\n' "$(rep a 60)" "$(rep a 60)"
  printf '\n'
  printf '  %s\n' "$(rep a 16)"
} | frag fixed wrapped.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"201 characters (cap 200)"*) true ;; *) false ;; esac \
  && ok "control: one more real character in the same shape fails at 201" \
  || bad "control: one more real character in the same shape fails at 201" "rc=$RC out=$OUT"
# The same characters unwrapped onto one line must measure identically.
printf -- '- %s %s %s %s\n' "$(rep a 60)" "$(rep a 60)" "$(rep a 60)" "$(rep a 16)" | frag fixed wrapped.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"201 characters (cap 200)"*) true ;; *) false ;; esac \
  && ok "the same text unwrapped onto one line measures identically" \
  || bad "the same text unwrapped onto one line measures identically" "rc=$RC out=$OUT"

echo "=== whitespace runs collapse; CR is stripped; trailing space spends nothing ==="
new_repo whitespace
printf -- '- %s\r\n' "$(rep x 198)" | frag fixed cr.md
run_ce
[ "$RC" -eq 0 ] && ok "a CR at the end of a line is not a character" \
  || bad "a CR at the end of a line is not a character" "rc=$RC out=$OUT"
printf -- '- %s   \t  \n' "$(rep x 198)" | frag fixed trail.md
run_ce
[ "$RC" -eq 0 ] && ok "trailing whitespace spends no cap" \
  || bad "trailing whitespace spends no cap" "rc=$RC out=$OUT"
printf -- '- %s     %s\n' "$(rep x 100)" "$(rep x 97)" | frag fixed runs.md
run_ce
[ "$RC" -eq 0 ] && ok "an interior whitespace run collapses to one character" \
  || bad "an interior whitespace run collapses to one character" "rc=$RC out=$OUT"
printf -- '- %s     %s\n' "$(rep x 100)" "$(rep x 98)" | frag fixed runs.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"201 characters"*) true ;; *) false ;; esac \
  && ok "control: the collapsed run leaves exactly one character to overflow" \
  || bad "control: the collapsed run leaves exactly one character to overflow" "rc=$RC out=$OUT"

echo "=== characters, not bytes: a multibyte entry counts once per character ==="
new_repo utf8
printf -- '- %s\n' "$(rep '—' 198)" | frag fixed dash.md
run_ce
[ "$RC" -eq 0 ] && ok "200 em dashes are 200 characters, not 596 bytes" \
  || bad "200 em dashes are 200 characters, not 596 bytes" "rc=$RC out=$OUT"
printf -- '- %s\n' "$(rep '—' 199)" | frag fixed dash.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"201 characters (cap 200)"*) true ;; *) false ;; esac \
  && ok "control: one em dash more is one character more" \
  || bad "control: one em dash more is one character more" "rc=$RC out=$OUT"
# A run of stray continuation bytes has no character count to take: measured
# as "bytes that are not continuation bytes" it would come out at almost
# nothing and pass whatever its length.
mkdir -p "$R/changelog.d/fixed"
{
  printf -- '- valid\n'
  printf '  '
  LC_ALL=C awk 'BEGIN { for (i = 0; i < 300; i++) printf "%c", 191 }'
  printf '\n'
} >"$R/changelog.d/fixed/stray.md"
stage
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"line 2 is not valid UTF-8"*) true ;; *) false ;; esac \
  && ok "a line that is not valid UTF-8 is a collection error naming the line" \
  || bad "a line that is not valid UTF-8 is a collection error naming the line" "rc=$RC out=$OUT"
case "$OUT" in *"changelog-entries: OK"*) bad "no OK verdict may accompany unmeasurable text" "$OUT" ;; *) ok "no OK verdict accompanies unmeasurable text" ;; esac
rm -f "$R/changelog.d/fixed/stray.md"
stage

echo "=== a fragment is exactly one list item, or it is refused ==="
new_repo shape
: | frag fixed empty.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/empty.md has no entry in it"*) true ;; *) false ;; esac \
  && ok "a zero-byte fragment is refused, naming it" \
  || bad "a zero-byte fragment is refused, naming it" "rc=$RC out=$OUT"
printf '\n\n' | frag fixed empty.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"has no entry in it"*) true ;; *) false ;; esac \
  && ok "a whitespace-only fragment is refused" \
  || bad "a whitespace-only fragment is refused" "rc=$RC out=$OUT"
printf -- '- \n' | frag fixed empty.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"has no entry in it"*) true ;; *) false ;; esac \
  && ok "a marker with nothing after it is refused" \
  || bad "a marker with nothing after it is refused" "rc=$RC out=$OUT"
printf 'Not a list item.\n' | frag fixed empty.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"does not open with a list marker"*) true ;; *) false ;; esac \
  && ok "a fragment opening with prose is refused" \
  || bad "a fragment opening with prose is refused" "rc=$RC out=$OUT"
printf -- '- First entry.\n- Second entry.\n' | frag fixed empty.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"holds more than the one entry"*) true ;; *) false ;; esac \
  && ok "two list items in one fragment are refused" \
  || bad "two list items in one fragment are refused" "rc=$RC out=$OUT"
printf -- '- An entry.\n\n## [9.9.9] - 2026-01-01\n' | frag fixed empty.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"holds more than the one entry"*) true ;; *) false ;; esac \
  && ok "a heading inside a fragment is refused rather than ending the section it folds into" \
  || bad "a heading inside a fragment is refused" "rc=$RC out=$OUT"
printf -- '- An entry\n  continued over\n  three lines.\n' | frag fixed empty.md
run_ce
[ "$RC" -eq 0 ] && ok "control: indented continuation lines are the one entry" \
  || bad "control: indented continuation lines are the one entry" "rc=$RC out=$OUT"

echo "=== a fragment sits directly under a section directory ==="
new_repo sections
sections_ok=1
# Keep a Changelog's six, written out rather than read from the check's own
# list: a set derived from the subject cannot catch that set being narrowed.
for sec in added changed deprecated removed fixed security; do
  printf -- '- An entry filed under %s.\n' "$sec" | frag "$sec" ken-1.md
done
run_ce
[ "$RC" -eq 0 ] && ok "a fragment under each of the six sections passes" \
  || bad "a fragment under each of the six sections passes" "rc=$RC out=$OUT"
printf -- '- Wrong section.\n' | frag bogus ken-1.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/bogus/ken-1.md names no section"*"added changed deprecated removed fixed security"*) true ;; *) false ;; esac \
  && ok "an unknown section directory is refused, naming the accepted set" \
  || bad "an unknown section directory is refused, naming the accepted set" "rc=$RC out=$OUT"
git -C "$R" rm -rq --cached changelog.d/bogus
rm -rf "$R/changelog.d/bogus"
printf -- '- Deeper.\n' | frag fixed/deeper ken-2.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/deeper/ken-2.md names no section"*) true ;; *) false ;; esac \
  && ok "a fragment below a section directory is refused" \
  || bad "a fragment below a section directory is refused" "rc=$RC out=$OUT"
git -C "$R" rm -rq --cached changelog.d/fixed/deeper
rm -rf "$R/changelog.d/fixed/deeper"
# The shape the glob DOES match and the grammar does not: `*` crosses `/`, so
# changelog.d/*/*.md reaches changelog.d/archive/fixed/x.md, whose immediate
# parent is a real section name. Depth is counted from the root the pattern
# roots at, or this reads as a fixed entry and is folded in.
printf -- '- Nested under a real section name.\n' | frag archive/fixed ken-3.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/archive/fixed/ken-3.md names no section"*) true ;; *) false ;; esac \
  && ok "a path two directories below the root is refused, though its parent names a section" \
  || bad "a path two directories below the root is refused" "rc=$RC out=$OUT"
case "$OUT" in *"at that pattern's own depth"*) ok "and the remedy states whose depth decides" ;;
  *) bad "and the remedy states whose depth decides" "$OUT" ;; esac
# The control: the same file one directory up is a fragment, so the refusal
# above is the depth and not the name.
git -C "$R" rm -rq --cached changelog.d/archive
rm -rf -- "${R:?}/changelog.d/archive"
printf -- '- Nested under a real section name.\n' | frag fixed ken-3.md
run_ce
[ "$RC" -eq 0 ] && ok "control: the same entry directly under the section passes" \
  || bad "control: the same entry directly under the section passes" "rc=$RC out=$OUT"
git -C "$R" rm -q --cached changelog.d/fixed/ken-3.md
rm -f "$R/changelog.d/fixed/ken-3.md"
stage
printf -- '- Flat.\n' >"$R/flat.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=flat.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"flat.md names no section"*) true ;; *) false ;; esac \
  && ok "a fragment in no directory at all names no section either" \
  || bad "a fragment in no directory at all names no section either" "rc=$RC out=$OUT"

echo "=== every other tracked path in the fragment tree is refused ==="
new_repo tree
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# changelog.d\n\n- Format notes running past what an entry may say, at length.\n' >"$R/changelog.d/README.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "control: the tree with only fragments and its README is clean" \
  || bad "control: the tree with only fragments and its README is clean" "rc=$RC out=$OUT"
# A path in a section directory the globs do not cover: nothing would ever
# fold it in, and nothing else in the chain would ever look at it.
printf 'whatever\n' >"$R/changelog.d/fixed/notes"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/notes is in the fragment tree but is not a fragment"*) true ;; *) false ;; esac \
  && ok "a path in a section directory that no glob covers is refused, naming the globs" \
  || bad "a path in a section directory that no glob covers is refused" "rc=$RC out=$OUT"
case "$OUT" in *"changelog.d/*/*.md"*) ok "the refusal names what a fragment must match" ;; *) bad "the refusal names what a fragment must match" "$OUT" ;; esac
git -C "$R" rm -q --cached changelog.d/fixed/notes
rm -f "$R/changelog.d/fixed/notes"
# A symlink there is refused the same way, so its target's bytes are never
# published by something that folds the path in unjudged.
ln -s ../../CHANGELOG.md "$R/changelog.d/fixed/notes"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/notes is in the fragment tree but is not a fragment"*) true ;; *) false ;; esac \
  && ok "a symlink the globs do not cover is refused too" \
  || bad "a symlink the globs do not cover is refused too" "rc=$RC out=$OUT"
git -C "$R" rm -q --cached changelog.d/fixed/notes
rm -f "$R/changelog.d/fixed/notes"
# A stray at the top of the tree, which matches no two-segment glob.
printf -- '- Stray.\n' >"$R/changelog.d/oops.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/oops.md is in the fragment tree but is not a fragment"*) true ;; *) false ;; esac \
  && ok "a stray at the top of the tree is refused" \
  || bad "a stray at the top of the tree is refused" "rc=$RC out=$OUT"
git -C "$R" rm -q --cached changelog.d/oops.md
rm -f "$R/changelog.d/oops.md"
# The README beside it is the one exemption, and only directly under a root.
stage
run_ce
[ "$RC" -eq 0 ] && ok "control: the README directly under the root stays exempt" \
  || bad "control: the README directly under the root stays exempt" "rc=$RC out=$OUT"
printf '# notes\n' >"$R/changelog.d/fixed/README.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/README.md"*) true ;; *) false ;; esac \
  && ok "a README below a section directory is not exempt" \
  || bad "a README below a section directory is not exempt" "rc=$RC out=$OUT"
git -C "$R" rm -q --cached changelog.d/fixed/README.md
rm -f "$R/changelog.d/fixed/README.md"
stage
# A pattern carrying no glob names one file, and naming one file is not
# naming the directory it sits in — so it roots nowhere and sweeps nothing,
# slash or no slash. The pattern below sits two directories deep, which is the
# shape a leading-run derivation would give a root to.
new_repo exactpath
mkdir -p "$R/changelog.d/added"
printf -- '- %s\n' "$(rep x 250)" >"$R/changelog.d/added/only.md"
printf 'not a fragment at all\n' >"$R/changelog.d/added/beside.txt"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/added/only.md'
[ "$RC" -eq 1 ] \
  && case "$OUT" in *"is not a fragment"*) false ;; *) true ;; esac \
  && case "$OUT" in *"long entry: changelog.d/added/only.md"*) true ;; *) false ;; esac \
  && ok "an exact-path pattern carrying a slash roots nowhere and sweeps nothing beside it" \
  || bad "an exact-path pattern carrying a slash roots nowhere" "rc=$RC out=$OUT"
# The control: a globbed pattern over that same directory DOES root there, and
# then the neighbour is refused — so the pass above is the exact-path rule and
# not a sweep that never runs.
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/added/*.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/added/beside.txt is in the fragment tree but is not a fragment"*) true ;; *) false ;; esac \
  && ok "control: a globbed pattern over the same directory does root there" \
  || bad "control: a globbed pattern over the same directory does root there" "rc=$RC out=$OUT"

# The README exemption wins over every root, not merely the last one checked:
# with a nested pair, the deeper root exempts its own README while the
# shallower one still contains it.
new_repo nestedroots
mkdir -p "$R/changelog.d/nested/fixed"
printf -- '- A nested entry.\n' >"$R/changelog.d/nested/fixed/a.md"
printf '# nested\n\n- Format notes.\n' >"$R/changelog.d/nested/README.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/nested/*/*.md changelog.d/*/legacy/*.md'
[ "$RC" -eq 0 ] && ok "a README under the deeper of two nested roots is exempt" \
  || bad "a README under the deeper of two nested roots is exempt" "rc=$RC out=$OUT"
# The control: any other name in its place is swept by the shallower root.
mv "$R/changelog.d/nested/README.md" "$R/changelog.d/nested/NOTES.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/nested/*/*.md changelog.d/*/legacy/*.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/nested/NOTES.md is in the fragment tree but is not a fragment"*) true ;; *) false ;; esac \
  && ok "control: the same file under any other name is swept" \
  || bad "control: the same file under any other name is swept" "rc=$RC out=$OUT"

echo "=== what is not a fragment is settled before any pattern is consulted ==="
# An exemption that only takes effect when no pattern reaches the path is an
# exemption whose meaning turns on the pattern shape. These pin it from the
# other side: the same file, exempt or judged according to where the ROOT
# falls, not according to whether some glob happened to match it first.
new_repo exemptions
printf -- '- A proper entry.\n' | frag fixed x.md
printf '# changelog.d/fixed\n\nHow to write one of these.\n' >"$R/changelog.d/fixed/README.md"
printf '# changelog.d\n\nHow to write one of these.\n' >"$R/changelog.d/README.md"
stage
# Narrowed to one section: the root IS changelog.d/fixed, so the README
# directly under it documents the format — and it matches the glob, which is
# what used to get it judged as a fragment instead.
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/fixed/*.md'
[ "$RC" -eq 0 ] && ok "a README under the root a narrowed pattern derives is exempt, though the glob reaches it" \
  || bad "a README under the root a narrowed pattern derives is exempt" "rc=$RC out=$OUT"
# The default: that same file is root+2, a fragment position, and is judged.
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/README.md"*) true ;; *) false ;; esac \
  && ok "control: under the default pattern the same file is a fragment position and is judged" \
  || bad "control: under the default pattern the same file is judged" "rc=$RC out=$OUT"
case "$OUT" in *"changelog.d/README.md"*) bad "and the README at the default root stays exempt" "$OUT" ;;
  *) ok "and the README at the default root stays exempt" ;; esac
# The configured record is the file fragments are folded INTO. A root drawn
# around it must not make it a stray in its own tree.
new_repo recordinside
printf -- '- A proper entry.\n' | frag fixed x.md
printf '# Changelog\n\n## [Unreleased]\n' >"$R/changelog.d/CHANGELOG.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_RECORD=changelog.d/CHANGELOG.md'
[ "$RC" -eq 0 ] && ok "a record configured inside the fragment tree is not swept as a stray" \
  || bad "a record configured inside the fragment tree is not swept as a stray" "rc=$RC out=$OUT"
# The control: any other file in its place IS a stray, so the pass above is
# the record and not the sweep going quiet.
git -C "$R" rm -q --cached changelog.d/CHANGELOG.md
rm -f "$R/changelog.d/CHANGELOG.md"
printf '# Notes\n' >"$R/changelog.d/NOTES.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_RECORD=changelog.d/CHANGELOG.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/NOTES.md is in the fragment tree but is not a fragment"*) true ;; *) false ;; esac \
  && ok "control: another file in that same place is swept" \
  || bad "control: another file in that same place is swept" "rc=$RC out=$OUT"

echo "=== the pattern says where the section sits, and at what depth ==="
# One rule for every pattern shape: a pattern is <root...>/<section>/<name>,
# so its own last two segments place a path and its own depth decides which
# paths it places. A count applied after the root instead is what makes each
# new pattern shape a new defect.
new_repo shapes
printf -- '- A proper entry.\n' | frag fixed x.md
mkdir -p "$R/changelog.d/archive/fixed"
printf -- '- Nested under a real section name.\n' >"$R/changelog.d/archive/fixed/y.md"
stage
# 1. The default: two globbed segments, rooted at changelog.d.
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/*/*.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/archive/fixed/y.md names no section"*) true ;; *) false ;; esac \
  && ok "the two-glob pattern places changelog.d/fixed and refuses a path a directory deeper" \
  || bad "the two-glob pattern refuses a path a directory deeper" "rc=$RC out=$OUT"
case "$OUT" in *"changelog.d/fixed/x.md"*) bad "and places the entry at its own depth" "$OUT" ;;
  *) ok "and places the entry at its own depth" ;; esac
# 2. Narrowed to ONE section: the section segment is literal, and a valid
#    entry under it is still placed — the shape the derived-root count broke.
git -C "$R" rm -rq --cached changelog.d/archive
rm -rf -- "${R:?}/changelog.d/archive"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/fixed/*.md'
[ "$RC" -eq 0 ] && ok "a pattern narrowed to one section still places its entries" \
  || bad "a pattern narrowed to one section still places its entries" "rc=$RC out=$OUT"
mkdir -p "$R/changelog.d/fixed/deeper"
printf -- '- Deeper still.\n' >"$R/changelog.d/fixed/deeper/z.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/fixed/*.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/deeper/z.md names no section"*) true ;; *) false ;; esac \
  && ok "and refuses a path a directory deeper than it" \
  || bad "and refuses a path a directory deeper than it" "rc=$RC out=$OUT"
git -C "$R" rm -rq --cached changelog.d/fixed/deeper
rm -rf -- "${R:?}/changelog.d/fixed/deeper"
stage
# 3. A glob in the MIDDLE: the section is literal and sits one deeper, so the
#    pattern places four-segment paths and nothing else.
mkdir -p "$R/changelog.d/team/fixed"
printf -- '- Under a middle glob.\n' >"$R/changelog.d/team/fixed/w.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/*/fixed/*.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/x.md is in the fragment tree but is not a fragment"*) true ;; *) false ;; esac \
  && ok "a pattern with a glob in the middle places paths at ITS depth, not two past its root" \
  || bad "a pattern with a glob in the middle places paths at its depth" "rc=$RC out=$OUT"
case "$OUT" in *"changelog.d/team/fixed/w.md"*) bad "and the four-segment path under it is placed" "$OUT" ;;
  *) ok "and the four-segment path under it is placed" ;; esac
git -C "$R" rm -rq --cached changelog.d/team
rm -rf -- "${R:?}/changelog.d/team"
stage

echo "=== a matched path that is not changelog text is refused, never skipped ==="
new_repo notext
printf -- '- A real entry.\n' | frag fixed real.md
ln -s real.md "$R/changelog.d/fixed/link.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/link.md is tracked as a symlink"*) true ;; *) false ;; esac \
  && ok "a tracked symlink is refused, not followed and not skipped" \
  || bad "a tracked symlink is refused" "rc=$RC out=$OUT"
case "$OUT" in *"not measured"*) bad "a refused path is not reported as merely unmeasured" "$OUT" ;; *) ok "a refused path is not reported as merely unmeasured" ;; esac
rm -f "$R/changelog.d/fixed/link.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "control: the same tree without the link passes" \
  || bad "control: the same tree without the link passes" "rc=$RC out=$OUT"

new_repo binary
# Every byte value, so a NUL falls inside the sample git classifies on. awk
# writes them, under LC_ALL=C so a value is a byte and not a character: the
# shell's printf %c stops at the first NUL.
mkdir -p "$R/changelog.d/fixed"
printf -- '- ' >"$R/changelog.d/fixed/bin.md"
LC_ALL=C awk 'BEGIN { for (i = 0; i < 256; i++) printf "%c", i }' >>"$R/changelog.d/fixed/bin.md"
stage
[ -z "$(git -C "$R" grep --cached -I -l . -- changelog.d)" ] \
  && ok "fixture: git itself calls the blob binary, so its --cached scans skip it" \
  || bad "fixture: git itself calls the blob binary" "git grep listed it"
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/bin.md holds binary content"*) true ;; *) false ;; esac \
  && ok "a binary blob is refused, not measured as text" \
  || bad "a binary blob is refused" "rc=$RC out=$OUT"
case "$OUT" in *"characters (cap"*) bad "no length may be reported for a binary blob" "$OUT" ;; *) ok "no length is reported for a binary blob" ;; esac
# git classifies on the leading bytes alone, and so does this check: a NUL
# past that sample is a blob both call text. Sizing the sample differently
# would make one of them disagree with the other.
mkdir -p "$R/changelog.d/added"
{
  printf -- '- '
  rep x 8100
  LC_ALL=C awk 'BEGIN { printf "%c", 0 }'
  printf 'tail\n'
} >"$R/changelog.d/added/late-nul.md"
stage
[ -n "$(git -C "$R" grep --cached -I -l . -- changelog.d/added)" ] \
  && ok "fixture: git calls a blob with its only NUL past the sample text" \
  || bad "fixture: git calls a blob with its only NUL past the sample text" "git grep skipped it"
run_ce
# Read as text, so the NUL in it is a byte with no character count — the
# text-scope refusal, never the binary one. A sample sized past that byte
# would call the same blob binary and disagree with git about it.
[ "$RC" -eq 2 ] && case "$OUT" in *"late-nul.md line 1 is not valid UTF-8"*) true ;; *) false ;; esac \
  && ok "so this check reads it as text too, and refuses the byte rather than the file" \
  || bad "so this check reads it as text too" "rc=$RC out=$OUT"
case "$OUT" in *"binary content"*) bad "no blob git calls text may be refused as binary" "$OUT" ;;
  *) ok "no blob git calls text is refused as binary" ;; esac
git -C "$R" rm -q --cached changelog.d/added/late-nul.md
rm -f "$R/changelog.d/added/late-nul.md"
# The control: high bytes carrying no NUL are text to git and to this check
# alike, so the refusal above is the NUL classification and not a file the
# check declines to read for having bytes over 127 in it.
printf -- '- %s\n' "$(rep '—' 250)" >"$R/changelog.d/fixed/bin.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"binary content"*) false ;; *"252 characters (cap 200)"*) true ;; *) false ;; esac \
  && ok "control: NUL-free high bytes are text and are measured" \
  || bad "control: NUL-free high bytes are measured" "rc=$RC out=$OUT"

echo "=== control bytes never reach the terminal through a diagnostic ==="
new_repo controls
printf -- '- An escape \033[31mred\033[0m and a CR \rhere %s\n' "$(rep z 220)" | frag fixed ctrl.md
run_ce
[ "$RC" -eq 1 ] && ok "control: the entry with control bytes is over the cap" \
  || bad "control: the entry with control bytes is over the cap" "rc=$RC out=$OUT"
case "$OUT" in
  *"?[31mred?[0m"*"CR ?here"*) ok "escape and carriage-return bytes are replaced in the quoted entry" ;;
  *) bad "escape and carriage-return bytes are replaced in the quoted entry" "$OUT" ;;
esac
printf 'x%s' "$OUT" | LC_ALL=C grep -q "$(printf '[\001-\010\013-\037\177]')" \
  && bad "no C0 control byte may survive into the diagnostic" "$OUT" \
  || ok "no C0 control byte survives into the diagnostic"

echo "=== the cap is configurable ==="
new_repo capcfg
printf -- '- %s\n' "$(rep x 250)" | frag fixed long.md
run_ce
[ "$RC" -eq 1 ] && ok "control: the entry fails the default cap" \
  || bad "control: the entry fails the default cap" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_CAP=400'
[ "$RC" -eq 0 ] && case "$OUT" in *"cap (400 characters)"*) true ;; *) false ;; esac \
  && ok "a raised cap passes it, and the verdict names the cap in force" \
  || bad "a raised cap passes it" "rc=$RC out=$OUT"
caps_rejected=1
for badcap in 0 -1 abc 12.5 ""; do
  run_ce_env "GROWTH_GUARDS_CHANGELOG_CAP=$badcap"
  [ "$RC" -eq 2 ] && case "$OUT" in *"must be a positive integer"*) true ;; *) false ;; esac \
    || { caps_rejected=0; bad "a cap of '$badcap' is a config error" "rc=$RC out=$OUT"; }
done
[ "$caps_rejected" -eq 1 ] && ok "every cap that is not a positive integer is a config error"

echo "=== the paths are configurable globs matched against tracked paths ==="
new_repo paths
printf -- '- %s\n' "$(rep x 250)" | frag fixed ken-1.md
printf '# changelog.d\n\n- A README bullet explaining the format at %s length.\n' "$(rep w 220)" >"$R/changelog.d/README.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/ken-1.md"*) true ;; *) false ;; esac \
  && ok "the default glob reaches the fragment tree" \
  || bad "the default glob reaches the fragment tree" "rc=$RC out=$OUT"
case "$OUT" in *"changelog.d/README.md"*) bad "the two-segment glob keeps the README out" "$OUT" ;; *) ok "the two-segment glob keeps the README out" ;; esac
# The control: the README really would be refused if the glob reached it, so
# the pass above is the glob and not a file that would have passed anyway.
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/README.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/README.md"*) true ;; *) false ;; esac \
  && ok "control: named directly, the README is judged and refused" \
  || bad "control: named directly, the README is judged and refused" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=docs/*/*.md'
[ "$RC" -eq 0 ] && case "$OUT" in *"no tracked file matches"*"docs"*) true ;; *) false ;; esac \
  && ok "configured paths matching no tracked file are a clean pass" \
  || bad "configured paths matching no tracked file are a clean pass" "rc=$RC out=$OUT"
# Every glob in the list is matched, not the first: only the second one here
# reaches the over-cap fragment.
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=docs/*/*.md changelog.d/*/*.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"long entry: changelog.d/fixed/ken-1.md"*) true ;; *) false ;; esac \
  && ok "the SECOND glob of the list reaches the fragment the first does not, and measures it" \
  || bad "the second glob of the list reaches and measures the fragment" "rc=$RC out=$OUT"

echo "=== a configured path is validated, never quietly matched against nothing ==="
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=/etc/CHANGELOG.md'
[ "$RC" -eq 2 ] && case "$OUT" in *"must be repo-root-relative"*) true ;; *) false ;; esac \
  && ok "an absolute path is a config error" \
  || bad "an absolute path is a config error" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=../CHANGELOG.md'
[ "$RC" -eq 2 ] && case "$OUT" in *"escapes the repository"*) true ;; *) false ;; esac \
  && ok "a path escaping the repository is a config error" \
  || bad "a path escaping the repository is a config error" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=   '
[ "$RC" -eq 2 ] && case "$OUT" in *"names no path"*"GROWTH_GUARDS_CHECKS"*) true ;; *) false ;; esac \
  && ok "an empty path list is a config error naming how to switch the check off" \
  || bad "an empty path list is a config error" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_RECORD=/etc/CHANGELOG.md'
[ "$RC" -eq 2 ] && case "$OUT" in *"must be repo-root-relative"*) true ;; *) false ;; esac \
  && ok "an absolute record path is a config error" \
  || bad "an absolute record path is a config error" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_RECORD=changelog.d/fixed/ken-1.md'
[ "$RC" -eq 2 ] && case "$OUT" in *"is also matched by GROWTH_GUARDS_CHANGELOG_PATHS"*) true ;; *) false ;; esac \
  && ok "a record inside the fragment globs is a config error — the two scopes judge by opposite rules" \
  || bad "a record inside the fragment globs is a config error" "rc=$RC out=$OUT"
run_ce --all
[ "$RC" -eq 2 ] && case "$OUT" in *"unknown argument --all"*) true ;; *) false ;; esac \
  && ok "an unknown argument is a config error" \
  || bad "an unknown argument is a config error" "rc=$RC out=$OUT"

echo "=== a configured glob reaches index paths, never the work tree ==="
new_repo glob_scope
printf -- '- A short fragment.\n' | frag fixed ok.md
printf -- '- %s\n' "$(rep x 250)" | frag fixed long.md
# The over-cap fragment leaves the WORK TREE while the index keeps it. A glob
# expanded by the shell would reach ok.md alone and call the commit clean.
rm -f "$R/changelog.d/fixed/long.md"
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/long.md"*) true ;; *) false ;; esac \
  && ok "a staged fragment absent from the work tree is still measured" \
  || bad "a staged fragment absent from the work tree is still measured" "rc=$RC out=$OUT"
# The other direction: an untracked file the same glob would match changes
# no verdict.
printf -- '- %s\n' "$(rep y 300)" >"$R/changelog.d/fixed/decoy.md"
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *decoy.md*) false ;; *"changelog.d/fixed/long.md"*) true ;; *) false ;; esac \
  && ok "an untracked decoy under the same glob is never measured" \
  || bad "an untracked decoy under the same glob is never measured" "rc=$RC out=$OUT"

echo "=== the index is what is judged ==="
new_repo index
printf -- '- A short entry.\n' | frag fixed a.md
git -C "$R" commit -qm base
printf -- '- %s\n' "$(rep x 250)" >"$R/changelog.d/fixed/a.md"
run_ce
[ "$RC" -eq 0 ] && ok "an unstaged worktree edit is not judged" \
  || bad "an unstaged worktree edit is not judged" "rc=$RC out=$OUT"
stage
run_ce
[ "$RC" -eq 1 ] && ok "control: staging the same edit does fail it" \
  || bad "control: staging the same edit does fail it" "rc=$RC out=$OUT"

echo "=== hostile bytes in a name or a pattern never leave their line ==="
new_repo hostile
# A tracked filename carrying a newline and an ESC: both are legal bytes in a
# path, and both decide what a message does if they reach one raw.
HOSTILE="$(printf 'KEN\n1\033X.md')"
mkdir -p "$R/changelog.d/fixed"
printf -- '- %s\n' "$(rep x 250)" >"$R/changelog.d/fixed/$HOSTILE"
stage
[ "$(git -C "$R" ls-files | wc -l)" -eq 1 ] \
  && ok "fixture: the hostile name is the one tracked path" \
  || bad "fixture: the hostile name is the one tracked path" "$(git -C "$R" ls-files)"
run_ce
[ "$RC" -eq 1 ] && ok "the entry under the hostile name is measured and fails" \
  || bad "the entry under the hostile name is measured and fails" "rc=$RC out=$OUT"
# Four lines exactly: the FAIL line, its entry, its remedies, the summary. A
# raw newline in the name would split one of them and hide the rest from a
# caller reading the first.
[ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 4 ] \
  && ok "the verdict stays on its four lines despite the newline in the name" \
  || bad "the verdict stays on its four lines" "lines=$(printf '%s\n' "$OUT" | grep -c .) out=$OUT"
printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '[\001-\010\013-\037\177]')" \
  && bad "no control byte from the name may reach the output" "$OUT" \
  || ok "no control byte from the name reaches the output"
# The same for a configured pattern, which is somebody's bytes too.
run_ce_env "$(printf 'GROWTH_GUARDS_CHANGELOG_PATHS=no\033match.md')"
[ "$RC" -eq 0 ] && case "$OUT" in *"no tracked file matches"*) true ;; *) false ;; esac \
  && ok "a pattern matching nothing is still a clean pass" \
  || bad "a pattern matching nothing is still a clean pass" "rc=$RC out=$OUT"
[ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 1 ] \
  && ok "the nothing-matched verdict is one line" \
  || bad "the nothing-matched verdict is one line" "out=$OUT"
printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '[\001-\010\013-\037\177]')" \
  && bad "no control byte from the pattern may reach the output" "$OUT" \
  || ok "no control byte from the pattern reaches the output"

echo "=== fail-closed: an unread blob and an unmerged index are exit 2 ==="
new_repo unreadable
printf -- '- %s\n' "$(rep x 250)" | frag fixed long.md
run_ce
[ "$RC" -eq 1 ] && ok "control: the staged entry fails while its blob is readable" \
  || bad "control: readable blob fails" "rc=$RC out=$OUT"
OID="$(git -C "$R" rev-parse :changelog.d/fixed/long.md)"
[ -f "$R/.git/objects/${OID:0:2}/${OID:2}" ] || bad "fixture: the staged blob is not a loose object at the expected path" "$OID"
rm -f -- "$R/.git/objects/${OID:0:2}/${OID:2}"
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"refusing to skip an unread changelog"*) true ;; *) false ;; esac \
  && ok "a vanished staged blob is exit 2, naming what it refuses to skip" \
  || bad "a vanished staged blob is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"changelog-entries: OK"*) bad "no OK verdict may accompany an unread blob" "$OUT" ;; *) ok "no OK verdict accompanies the unread blob" ;; esac

new_repo unmerged
printf 'line1\nbase\nline3\n' >"$R/f.txt"
printf -- '- A short entry.\n' | frag fixed a.md
git -C "$R" commit -qm base
git -C "$R" checkout -q -b other
printf 'line1\ntheirs\nline3\n' >"$R/f.txt"
git -C "$R" commit -qam other
git -C "$R" checkout -q main
printf 'line1\nours\nline3\n' >"$R/f.txt"
git -C "$R" commit -qam ours
git -C "$R" merge other >/dev/null 2>&1 || true
[ "$(git -C "$R" ls-files -u | wc -l)" -eq 3 ] \
  && ok "the fixture really is mid-merge (three index stages)" \
  || bad "the fixture really is mid-merge (three index stages)" "stages=$(git -C "$R" ls-files -u | wc -l)"
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"unmerged path"*"finish or abort the merge"*) true ;; *) false ;; esac \
  && ok "an unmerged index is exit 2 naming the remedy" \
  || bad "an unmerged index is exit 2 naming the remedy" "rc=$RC out=$OUT"
case "$OUT" in *"changelog-entries: OK"*) bad "no OK verdict may accompany an unmerged index" "$OUT" ;; *) ok "no OK verdict accompanies the unmerged index" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
