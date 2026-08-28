#!/usr/bin/env bash
# Pins for scripts/changelog-entries: the cap is a character count and
# nothing else, entry boundaries are the marker/heading/blank rule, the
# configured globs decide what is read, content comes from the index, and a
# scan that could not complete is exit 2. Every green assertion is paired
# with a control that proves it can fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CE="$SKILL_DIR/scripts/changelog-entries"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"

# Hermetic: a leaked setting would mask every case below.
unset GROWTH_GUARDS_CHANGELOG_CAP GROWTH_GUARDS_CHANGELOG_PATHS \
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

# N copies of a character, so a fixture states the length it means instead of
# carrying a literal nobody can count.
rep() { # CHAR N
  local c="$1" n="$2" out=""
  while [ "${#out}" -lt "$n" ]; do out="$out$c"; done
  printf '%s' "$out"
}

echo "=== control: a repo with no changelog passes, saying nothing matched ==="
new_repo nochangelog
printf 'fn main() {}\n' >"$R/ok.rs"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"no tracked file matches"*"CHANGELOG.md"*) true ;; *) false ;; esac \
  && ok "no changelog is a clean pass naming the paths it looked for" \
  || bad "no changelog is a clean pass naming the paths it looked for" "rc=$RC out=$OUT"

echo "=== an entry over the cap fails; one under it passes ==="
new_repo cap
{
  printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n'
  printf -- '- A short entry.\n'
  printf -- '- %s\n' "$(rep x 205)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"FAIL long entry: CHANGELOG.md:8 — 207 characters (cap 200)"*) true ;; *) false ;; esac \
  && ok "an over-cap entry fails, naming file, line, length and cap" \
  || bad "an over-cap entry fails, naming file, line, length and cap" "rc=$RC out=$OUT"
case "$OUT" in *"entry: - xxx"*) ok "the diagnostic quotes the entry's first line" ;; *) bad "the diagnostic quotes the entry's first line" "$OUT" ;; esac
case "$OUT" in *"remedies: state the outcome and stop"*) ok "the diagnostic carries the remediation" ;; *) bad "the diagnostic carries the remediation" "$OUT" ;; esac
case "$OUT" in *"CHANGELOG.md:7"*) bad "the short entry is not named" "$OUT" ;; *) ok "the short entry is not named" ;; esac
case "$OUT" in *"changelog-entries: OK"*) bad "no OK verdict may accompany a violation" "$OUT" ;; *) ok "no OK verdict accompanies the violation" ;; esac

echo "=== the boundary is exact: cap passes, cap+1 fails ==="
new_repo boundary
printf -- '- %s\n' "$(rep x 198)" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"1 entry(ies) in 1 file(s) within the cap (200 characters)"*) true ;; *) false ;; esac \
  && ok "an entry of exactly 200 characters passes" \
  || bad "an entry of exactly 200 characters passes" "rc=$RC out=$OUT"
printf -- '- %s\n' "$(rep x 199)" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"201 characters (cap 200)"*) true ;; *) false ;; esac \
  && ok "one character past the cap fails" \
  || bad "one character past the cap fails" "rc=$RC out=$OUT"

echo "=== the cap is the whole rule: no line count, no continuation grammar ==="
new_repo lines
# Six lines the superseded three-line rule refused, well inside the cap.
{
  printf -- '- Six short lines\n'
  printf '  second\n  third\n  fourth\n  fifth\n  sixth.\n'
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "a six-line entry inside the cap passes" \
  || bad "a six-line entry inside the cap passes" "rc=$RC out=$OUT"
# The control: the same shape past the cap does fail, so the pass above is
# the length answering and not the check declining to look.
{
  printf -- '- Six long lines\n'
  printf '  %s\n' "$(rep y 60)" "$(rep y 60)" "$(rep y 60)" "$(rep y 60)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"260 characters"*) true ;; *) false ;; esac \
  && ok "a multi-line entry past the cap fails on its joined length" \
  || bad "a multi-line entry past the cap fails on its joined length" "rc=$RC out=$OUT"
# Wrapping is invisible: the same text on one line measures the same.
printf -- '- Six long lines %s %s %s %s\n' "$(rep y 60)" "$(rep y 60)" "$(rep y 60)" "$(rep y 60)" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"260 characters"*) true ;; *) false ;; esac \
  && ok "the same text unwrapped onto one line measures identically" \
  || bad "the same text unwrapped onto one line measures identically" "rc=$RC out=$OUT"

echo "=== whitespace runs collapse; CR is stripped ==="
new_repo whitespace
# Deep indentation, doubled spaces and tabs would each push this past the
# cap if they counted; collapsed, the entry is 200 characters.
{
  printf -- '- %s\r\n' "$(rep x 98)"
  printf '\t\t   %s\r\n' "$(rep x 99)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "indentation, doubled whitespace and CRLF do not count toward the cap" \
  || bad "indentation, doubled whitespace and CRLF do not count toward the cap" "rc=$RC out=$OUT"
printf -- '- %s\r\n\t\t   %s\r\n' "$(rep x 98)" "$(rep x 100)" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"201 characters"*) true ;; *) false ;; esac \
  && ok "control: one more real character in the same shape fails" \
  || bad "control: one more real character in the same shape fails" "rc=$RC out=$OUT"

echo "=== characters, not bytes: a multibyte entry counts once per character ==="
new_repo multibyte
# 198 em dashes is 594 bytes and 200 characters with the marker.
printf -- '- %s\n' "$(rep '—' 198)" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "200 characters of em dashes pass, though they are 596 bytes" \
  || bad "200 characters of em dashes pass, though they are 596 bytes" "rc=$RC out=$OUT"
run_ce_env GROWTH_GUARDS_CHANGELOG_CAP=199
[ "$RC" -eq 1 ] && case "$OUT" in *"200 characters (cap 199)"*) true ;; *) false ;; esac \
  && ok "control: the same entry is 200 characters, not 596 — it fails a cap of 199" \
  || bad "control: the same entry is measured at 200 characters" "rc=$RC out=$OUT"

echo "=== entry boundaries: marker, heading, blank line ==="
new_repo boundaries
{
  printf -- '- First entry\n'
  printf -- '- Second entry\n'
  printf '  its continuation\n'
  printf '\n'
  printf 'A paragraph after the list is not part of the entry.\n'
  printf '\n'
  printf '### Heading\n'
  printf -- '* Star entry\n'
  printf -- '  - a nested bullet belongs to the entry above it\n'
  printf -- '+ Plus entry\n'
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"4 entry(ies) in 1 file(s)"*) true ;; *) false ;; esac \
  && ok "all three markers open an entry; nested bullets, prose and headings do not" \
  || bad "all three markers open an entry; nested bullets, prose and headings do not" "rc=$RC out=$OUT"
# Controls for each boundary, one at a time: a 150-character head plus a
# 150-character neighbour passes only while the boundary separates them.
{
  printf -- '- %s\n' "$(rep a 148)"
  printf '\n'
  printf '  %s\n' "$(rep b 148)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "a blank line ends the entry — the text after it is not measured into it" \
  || bad "a blank line ends the entry" "rc=$RC out=$OUT"
{
  printf -- '- %s\n' "$(rep a 148)"
  printf '### Heading\n'
  printf '  %s\n' "$(rep b 148)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "a heading ends the entry" \
  || bad "a heading ends the entry" "rc=$RC out=$OUT"
{
  printf -- '- %s\n' "$(rep a 148)"
  printf -- '- %s\n' "$(rep b 148)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "the next marker ends the entry" \
  || bad "the next marker ends the entry" "rc=$RC out=$OUT"
# The control the three share: with nothing between them the two halves are
# one entry and fail, so each pass above is the boundary and not the length.
{
  printf -- '- %s\n' "$(rep a 148)"
  printf '  %s\n' "$(rep b 148)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"299 characters"*) true ;; *) false ;; esac \
  && ok "control: with no boundary the two halves are one 299-character entry" \
  || bad "control: with no boundary the two halves are one entry" "rc=$RC out=$OUT"

echo "=== a marker needs its space: rules and glued text are not entries ==="
new_repo markers
{
  printf -- '---\n'
  printf 'Front matter is not an entry.\n'
  printf -- '---\n'
  printf -- '-not-a-marker %s\n' "$(rep z 250)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"no tracked file matches"*) false ;; *"0 entry(ies) in 1 file(s)"*) true ;; *) false ;; esac \
  && ok "a horizontal rule and glued text open no entry, and the file is still read" \
  || bad "a horizontal rule and glued text open no entry" "rc=$RC out=$OUT"

echo "=== the cap is configurable ==="
new_repo configured_cap
printf -- '- %s\n' "$(rep x 250)" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && ok "control: the entry fails the default cap" \
  || bad "control: the entry fails the default cap" "rc=$RC out=$OUT"
run_ce_env GROWTH_GUARDS_CHANGELOG_CAP=300
[ "$RC" -eq 0 ] && case "$OUT" in *"within the cap (300 characters)"*) true ;; *) false ;; esac \
  && ok "a raised cap passes it, and the verdict states the cap it used" \
  || bad "a raised cap passes it" "rc=$RC out=$OUT"
printf 'GROWTH_GUARDS_CHANGELOG_CAP = "300"\n' >"$R/settings.toml"
printf '[env]\n' >"$R/kendex.settings.toml"
cat "$R/settings.toml" >>"$R/kendex.settings.toml"
rm -f "$R/settings.toml"
stage
run_ce
[ "$RC" -eq 0 ] && ok "the committed kendex.settings.toml [env] table sets the cap" \
  || bad "the committed kendex.settings.toml [env] table sets the cap" "rc=$RC out=$OUT"
for badcap in 0 -1 abc 12.5 ""; do
  run_ce_env "GROWTH_GUARDS_CHANGELOG_CAP=$badcap"
  [ "$RC" -eq 2 ] && case "$OUT" in *"must be a positive integer"*) true ;; *) false ;; esac \
    || bad "a cap of '$badcap' is a config error" "rc=$RC out=$OUT"
done
ok "a cap that is not a positive integer is a config error"

echo "=== the paths are configurable globs matched against tracked paths ==="
new_repo paths
mkdir -p "$R/changelog.d/fixed" "$R/docs"
printf -- '- %s\n' "$(rep x 250)" >"$R/changelog.d/fixed/ken-1.md"
printf '# changelog.d\n\n- A README bullet explaining the format at %s length.\n' "$(rep w 220)" >"$R/changelog.d/README.md"
printf -- '- A short entry.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "the default paths read CHANGELOG.md alone" \
  || bad "the default paths read CHANGELOG.md alone" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=CHANGELOG.md changelog.d/*/*.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/ken-1.md:1"*) true ;; *) false ;; esac \
  && ok "a configured glob reaches the fragment tree" \
  || bad "a configured glob reaches the fragment tree" "rc=$RC out=$OUT"
case "$OUT" in *"changelog.d/README.md"*) bad "the two-segment glob keeps the README out" "$OUT" ;; *) ok "the two-segment glob keeps the README out" ;; esac
# The control: the README really does hold an over-cap bullet, so the pass
# above is the glob and not a file that would have passed anyway.
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/README.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/README.md:3"*) true ;; *) false ;; esac \
  && ok "control: named directly, the README's own bullet is over the cap" \
  || bad "control: named directly, the README's own bullet is over the cap" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=docs/CHANGES.md'
[ "$RC" -eq 0 ] && case "$OUT" in *"no tracked file matches"*"docs/CHANGES.md"*) true ;; *) false ;; esac \
  && ok "configured paths matching no tracked file are a clean pass" \
  || bad "configured paths matching no tracked file are a clean pass" "rc=$RC out=$OUT"

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
run_ce --all
[ "$RC" -eq 2 ] && case "$OUT" in *"unknown argument '--all'"*) true ;; *) false ;; esac \
  && ok "an unknown argument is a config error" \
  || bad "an unknown argument is a config error" "rc=$RC out=$OUT"

echo "=== the index is what is judged ==="
new_repo index
printf -- '- A short entry.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
printf -- '- %s\n' "$(rep x 250)" >"$R/CHANGELOG.md"
run_ce
[ "$RC" -eq 0 ] && ok "an unstaged worktree edit is not judged" \
  || bad "an unstaged worktree edit is not judged" "rc=$RC out=$OUT"
stage
run_ce
[ "$RC" -eq 1 ] && ok "control: staging the same edit does fail it" \
  || bad "control: staging the same edit does fail it" "rc=$RC out=$OUT"
git -C "$R" reset -q
git -C "$R" checkout -q -- CHANGELOG.md
printf -- '- %s\n' "$(rep x 250)" >"$R/untracked-CHANGELOG.md"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=untracked-CHANGELOG.md'
[ "$RC" -eq 0 ] && case "$OUT" in *"no tracked file matches"*) true ;; *) false ;; esac \
  && ok "an untracked file matching the glob is not judged" \
  || bad "an untracked file matching the glob is not judged" "rc=$RC out=$OUT"

echo "=== a symlink at a configured path is not changelog text ==="
new_repo symlink
printf -- '- %s\n' "$(rep x 250)" >"$R/real.md"
ln -s real.md "$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"0 entry(ies) in 0 file(s)"*|*"no tracked file matches"*) true ;; *) false ;; esac \
  && ok "a tracked symlink is skipped rather than measured as its target's name" \
  || bad "a tracked symlink is skipped" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=real.md'
[ "$RC" -eq 1 ] && ok "control: the file behind the link is judged when it is named" \
  || bad "control: the file behind the link is judged when it is named" "rc=$RC out=$OUT"

echo "=== fail-closed: an unread blob and an unmerged index are exit 2 ==="
new_repo unreadable
printf -- '- %s\n' "$(rep x 250)" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && ok "control: the staged entry fails while its blob is readable" \
  || bad "control: readable blob fails" "rc=$RC out=$OUT"
OID="$(git -C "$R" rev-parse :CHANGELOG.md)"
[ -f "$R/.git/objects/${OID:0:2}/${OID:2}" ] || bad "fixture: the staged blob is not a loose object at the expected path" "$OID"
rm -f -- "$R/.git/objects/${OID:0:2}/${OID:2}"
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"refusing to skip an unread changelog"*) true ;; *) false ;; esac \
  && ok "a vanished staged blob is exit 2, naming what it refuses to skip" \
  || bad "a vanished staged blob is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"changelog-entries: OK"*) bad "no OK verdict may accompany an unread blob" "$OUT" ;; *) ok "no OK verdict accompanies the unread blob" ;; esac

new_repo unmerged
printf 'line1\nbase\nline3\n' >"$R/f.txt"
printf -- '- A short entry.\n' >"$R/CHANGELOG.md"
stage
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
