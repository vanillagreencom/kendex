#!/usr/bin/env bash
# Pins for scripts/changelog-entries: the cap is a character count and
# nothing else, an entry runs to the next marker, a heading, or a blank line
# followed by unindented prose, the configured globs decide what is read,
# content comes from the index, a path that is not readable changelog text is
# named rather than folded into the clean count, and a scan that could not
# complete is exit 2. Every green assertion is paired with a control that
# proves it can fail.
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
# The marker and 198 em dashes: 200 characters, 596 bytes. The byte figure is
# asserted, not assumed — a fixture built from a locale-dependent measurement
# would shrink to 66 dashes under LC_ALL=C and pass the case below for having
# nothing to measure.
printf -- '- %s\n' "$(rep '—' 198)" >"$R/CHANGELOG.md"
[ "$(wc -c <"$R/CHANGELOG.md")" -eq 597 ] \
  && ok "fixture: the entry really is 596 bytes (597 with its newline)" \
  || bad "fixture: the entry really is 596 bytes" "bytes=$(wc -c <"$R/CHANGELOG.md")"
stage
run_ce
[ "$RC" -eq 0 ] && ok "200 characters of em dashes pass, though they are 596 bytes" \
  || bad "200 characters of em dashes pass, though they are 596 bytes" "rc=$RC out=$OUT"
run_ce_env GROWTH_GUARDS_CHANGELOG_CAP=199
[ "$RC" -eq 1 ] && case "$OUT" in *"200 characters (cap 199)"*) true ;; *) false ;; esac \
  && ok "control: the same entry is 200 characters, not 596 — it fails a cap of 199" \
  || bad "control: the same entry is measured at 200 characters" "rc=$RC out=$OUT"

# Counting non-continuation bytes is the character count only while every
# continuation byte follows a lead byte that claims it. Stray ones carry no
# count at all, and git calls such a blob text as long as it holds no NUL.
new_repo invalid_utf8
printf -- '- ' >"$R/CHANGELOG.md"
LC_ALL=C awk 'BEGIN { for (i = 0; i < 500; i++) printf "%c", 128 }' >>"$R/CHANGELOG.md"
printf '\n' >>"$R/CHANGELOG.md"
stage
[ -n "$(git -C "$R" grep --cached -I -l . -- CHANGELOG.md)" ] \
  && ok "fixture: git calls the blob text, so the binary skip does not reach it" \
  || bad "fixture: git calls the blob text" "git grep skipped it"
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"CHANGELOG.md line 1 is not valid UTF-8"*) true ;; *) false ;; esac \
  && ok "a line that is not valid UTF-8 is a collection error naming the line" \
  || bad "a line that is not valid UTF-8 is a collection error" "rc=$RC out=$OUT"
case "$OUT" in *"changelog-entries: OK"*) bad "no OK verdict may accompany unmeasurable text" "$OUT" ;; *) ok "no OK verdict accompanies unmeasurable text" ;; esac
# The control beside it: the same length in VALID multibyte is measured, so
# the refusal is the encoding and not the byte range.
printf -- '- %s\n' "$(rep '—' 500)" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"502 characters"*) true ;; *) false ;; esac \
  && ok "control: 500 valid em dashes are measured, at 502 characters" \
  || bad "control: 500 valid em dashes are measured" "rc=$RC out=$OUT"

echo "=== entry boundaries: marker, heading, blank-then-unindented ==="
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
# A blank line alone does not end an entry: an indented second paragraph is
# part of it, which is what the fragment tooling accepts as one entry. Left
# out of the measurement, this shape is the whole cap.
{
  printf -- '- %s\n' "$(rep a 148)"
  printf '\n'
  printf '  %s\n' "$(rep b 148)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"299 characters"*) true ;; *) false ;; esac \
  && ok "a blank line does not end the entry — an indented second paragraph is measured into it" \
  || bad "a blank-separated indented paragraph is measured into the entry" "rc=$RC out=$OUT"
# The reviewer's shape, and the one tools/changelog-collate --check accepts:
# a short opening paragraph over a long indented one.
{
  printf -- '- A short first paragraph.\n'
  printf '\n'
  printf '  %s\n' "$(rep p 400)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"427 characters"*) true ;; *) false ;; esac \
  && ok "a short paragraph over a long indented one fails on the pair's length" \
  || bad "a short paragraph over a long indented one fails on the pair's length" "rc=$RC out=$OUT"
# A blank line followed by UNINDENTED prose does end it, so trailing prose is
# never measured into the last entry.
{
  printf -- '- %s\n' "$(rep a 148)"
  printf '\n'
  printf '%s\n' "$(rep b 148)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "a blank line then unindented prose ends the entry" \
  || bad "a blank line then unindented prose ends the entry" "rc=$RC out=$OUT"
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
# The control the boundaries share: with nothing between them the two halves
# are one entry and fail, so each pass above is the boundary and not the
# length.
{
  printf -- '- %s\n' "$(rep a 148)"
  printf '  %s\n' "$(rep b 148)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"299 characters"*) true ;; *) false ;; esac \
  && ok "control: with no boundary the two halves are one 299-character entry" \
  || bad "control: with no boundary the two halves are one entry" "rc=$RC out=$OUT"

echo "=== the heading boundary is ATX syntax, not any leading hash ==="
new_repo atx
# A continuation naming an issue number: a hash with no space after it. Ending
# the entry there would leave 14 characters of it unmeasured and report the
# 200-character head as clean.
{
  printf -- '- %s\n' "$(rep a 198)"
  printf '#601 and more.\n'
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"215 characters"*) true ;; *) false ;; esac \
  && ok "a continuation opening with a hash and no space stays in the entry" \
  || bad "a continuation opening with a hash and no space stays in the entry" "rc=$RC out=$OUT"
# Seven hashes is a paragraph, not a heading, and continues the entry too.
{
  printf -- '- %s\n' "$(rep a 198)"
  printf '####### deep.\n'
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"214 characters"*) true ;; *) false ;; esac \
  && ok "seven hashes open no heading and continue the entry" \
  || bad "seven hashes open no heading and continue the entry" "rc=$RC out=$OUT"
# The other direction: a real ATX heading still ends it, at every depth the
# syntax allows and with no text after the hashes.
for atx in '# One' '###### Six' '#' '######'; do
  {
    printf -- '- %s\n' "$(rep a 198)"
    printf '%s\n' "$atx"
    printf '  %s\n' "$(rep b 148)"
  } >"$R/CHANGELOG.md"
  stage
  run_ce
  [ "$RC" -eq 0 ] || bad "the ATX heading '$atx' ends the entry" "rc=$RC out=$OUT"
done
ok "an ATX heading ends the entry at one through six hashes, bare or with text"

echo "=== an unindented continuation line joins with one space ==="
new_repo lazy
# No blank and no indentation between them, so the whole entry is 100 + 1 + 100.
# Drop the joining space and it is 200, inside the cap: the boundary is here
# on purpose.
{
  printf -- '- %s\n' "$(rep a 98)"
  printf '%s\n' "$(rep b 100)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"201 characters"*) true ;; *) false ;; esac \
  && ok "a lazy continuation joins with one space, and the pair fails at 201" \
  || bad "a lazy continuation joins with one space" "rc=$RC out=$OUT"
{
  printf -- '- %s\n' "$(rep a 98)"
  printf '%s\n' "$(rep b 99)"
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "its twin, one character shorter, passes at exactly 200" \
  || bad "its twin passes at exactly 200" "rc=$RC out=$OUT"

echo "=== trailing whitespace spends no cap ==="
new_repo trailing
printf -- '- %s   \n' "$(rep a 198)" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "an entry of 200 characters plus trailing spaces passes" \
  || bad "an entry of 200 characters plus trailing spaces passes" "rc=$RC out=$OUT"
printf -- '- %s   \n' "$(rep a 199)" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"201 characters"*) true ;; *) false ;; esac \
  && ok "control: one more real character in the same shape fails at 201" \
  || bad "control: one more real character in the same shape fails" "rc=$RC out=$OUT"

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
caps_rejected=1
for badcap in 0 -1 abc 12.5 ""; do
  run_ce_env "GROWTH_GUARDS_CHANGELOG_CAP=$badcap"
  [ "$RC" -eq 2 ] && case "$OUT" in *"must be a positive integer"*) true ;; *) false ;; esac \
    || { caps_rejected=0; bad "a cap of '$badcap' is a config error" "rc=$RC out=$OUT"; }
done
[ "$caps_rejected" -eq 1 ] && ok "every cap that is not a positive integer is a config error"

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

echo "=== a configured glob reaches index paths, never the work tree ==="
new_repo glob_scope
mkdir -p "$R/changelog.d/fixed"
printf -- '- A short fragment.\n' >"$R/changelog.d/fixed/ok.md"
printf -- '- %s\n' "$(rep x 250)" >"$R/changelog.d/fixed/long.md"
stage
# The over-cap fragment leaves the WORK TREE while the index keeps it. A glob
# expanded by the shell would reach ok.md alone and call the commit clean.
rm -f "$R/changelog.d/fixed/long.md"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/*/*.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/long.md:1"*) true ;; *) false ;; esac \
  && ok "a staged fragment absent from the work tree is still measured" \
  || bad "a staged fragment absent from the work tree is still measured" "rc=$RC out=$OUT"
# The other direction: an untracked file the same glob would match changes
# no verdict.
printf -- '- %s\n' "$(rep y 300)" >"$R/changelog.d/fixed/decoy.md"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=changelog.d/*/*.md'
[ "$RC" -eq 1 ] && case "$OUT" in *decoy.md*) false ;; *"changelog.d/fixed/long.md:1"*) true ;; *) false ;; esac \
  && ok "an untracked decoy under the same glob is never measured" \
  || bad "an untracked decoy under the same glob is never measured" "rc=$RC out=$OUT"

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

echo "=== a matched path that is not changelog text is named, never counted clean ==="
new_repo symlink
printf -- '- %s\n' "$(rep x 250)" >"$R/real.md"
ln -s real.md "$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: CHANGELOG.md — tracked as a symlink"*) true ;; *) false ;; esac \
  && ok "a tracked symlink is named as unmeasured, not read as its target's name" \
  || bad "a tracked symlink is named as unmeasured" "rc=$RC out=$OUT"
case "$OUT" in *"1 matched path(s) not measured"*) ok "the verdict counts the skipped path" ;; *) bad "the verdict counts the skipped path" "$OUT" ;; esac
# The wording a matched-but-skipped path must NOT get: it would send its
# reader to widen a glob that already matched.
case "$OUT" in *"no tracked file matches"*) bad "a matched path may not report as nothing matched" "$OUT" ;; *) ok "a matched path does not report as nothing matched" ;; esac
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=real.md'
[ "$RC" -eq 1 ] && ok "control: the file behind the link is judged when it is named" \
  || bad "control: the file behind the link is judged when it is named" "rc=$RC out=$OUT"

new_repo binary
# Every byte value, so a NUL falls inside the sample git classifies on. awk
# writes them, under LC_ALL=C so a value is a byte and not a character: the
# shell's printf %c stops at the first NUL.
printf -- '- ' >"$R/CHANGELOG.md"
LC_ALL=C awk 'BEGIN { for (i = 0; i < 256; i++) printf "%c", i }' >>"$R/CHANGELOG.md"
stage
[ -z "$(git -C "$R" grep --cached -I -l . -- CHANGELOG.md)" ] \
  && ok "fixture: git itself calls the blob binary, so its --cached scans skip it" \
  || bad "fixture: git itself calls the blob binary" "git grep listed it"
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured: CHANGELOG.md — binary content"*) true ;; *) false ;; esac \
  && ok "a binary blob is named as unmeasured, not measured as text" \
  || bad "a binary blob is named as unmeasured" "rc=$RC out=$OUT"
case "$OUT" in *"characters (cap"*) bad "no length may be reported for a binary blob" "$OUT" ;; *) ok "no length is reported for a binary blob" ;; esac
# The control: high bytes carrying no NUL are text to git and to this check
# alike, so the skip above is the NUL classification and not a file the check
# declines to read for having bytes over 127 in it.
printf -- '- %s\n' "$(rep '—' 250)" >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"not measured"*) false ;; *"252 characters (cap 200)"*) true ;; *) false ;; esac \
  && ok "control: NUL-free high bytes are text and are measured" \
  || bad "control: NUL-free high bytes are measured" "rc=$RC out=$OUT"

echo "=== control bytes never reach the terminal through a diagnostic ==="
new_repo controls
printf -- '- An escape \033[31mred\033[0m and a CR \rhere %s\n' "$(rep z 220)" >"$R/CHANGELOG.md"
stage
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

echo "=== hostile bytes in a name or a pattern never leave their line ==="
new_repo hostile
# A tracked filename carrying a newline and an ESC: both are legal bytes in a
# path, and both decide what a message does if they reach one raw.
HOSTILE="$(printf 'CHANGE\nLOG\033X.md')"
printf -- '- %s\n' "$(rep x 250)" >"$R/$HOSTILE"
stage
[ "$(git -C "$R" ls-files | wc -l)" -eq 1 ] \
  && ok "fixture: the hostile name is the one tracked path" \
  || bad "fixture: the hostile name is the one tracked path" "$(git -C "$R" ls-files)"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=*.md'
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

# The skip line carries a path too, and a run that measures nothing is where
# a raw newline in one would be least visible.
new_repo hostile_skip
printf -- '- %s\n' "$(rep x 250)" >"$R/real.md"
ln -s real.md "$R/$HOSTILE"
git -C "$R" add -- "$HOSTILE"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_PATHS=*.md'
[ "$RC" -eq 0 ] && case "$OUT" in *"not measured"*"tracked as a symlink"*) true ;; *) false ;; esac \
  && ok "the hostile name is named as unmeasured" \
  || bad "the hostile name is named as unmeasured" "rc=$RC out=$OUT"
[ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 2 ] \
  && ok "the skip note and its verdict are two lines" \
  || bad "the skip note and its verdict are two lines" "lines=$(printf '%s\n' "$OUT" | grep -c .) out=$OUT"
printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '[\001-\010\013-\037\177]')" \
  && bad "no control byte from the skipped name may reach the output" "$OUT" \
  || ok "no control byte from the skipped name reaches the output"

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
