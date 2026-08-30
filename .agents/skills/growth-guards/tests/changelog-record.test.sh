#!/usr/bin/env bash
# Pins the RECORD scope of scripts/changelog-entries: the collated file gains
# no line under its `## [Unreleased]` heading that HEAD does not already
# carry, that heading is found by ATX structure outside fenced code rather
# than by substring, an unterminated fence fails closed, and each way the
# scope stands down names itself. The fragment scope is pinned next door in
# changelog-entries.test.sh. Every green assertion is paired with a control
# that proves it can fail.
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

echo "=== the record gains no line under [Unreleased] that HEAD does not carry ==="
new_repo record
# One writer for every variant: the added line goes under [Unreleased],
# which is where appending to a file that ends in a released section does not
# put it.
record() { # [EXTRA-LINE]
  {
    printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n'
    printf -- '- A wrapped entry\n  second line.\n- One line.\n'
    [ $# -eq 0 ] || printf -- '%s\n' "$1"
    printf '\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n'
  } >"$R/CHANGELOG.md"
}
record
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"unchanged under [Unreleased]"*) false ;; *) true ;; esac \
  && ok "a record HEAD does not carry yet is not judged — a first CHANGELOG is not a hand edit" \
  || bad "a record HEAD does not carry yet is not judged" "rc=$RC out=$OUT"
git -C "$R" commit -qm base
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"CHANGELOG.md unchanged under [Unreleased]"*) true ;; *) false ;; esac \
  && ok "an untouched record passes and the verdict says it was judged" \
  || bad "an untouched record passes and the verdict says it was judged" "rc=$RC out=$OUT"
record '- A hand-written line.'
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"CHANGELOG.md gained lines under [Unreleased]"*"- A hand-written line."*) true ;; *) false ;; esac \
  && ok "a hand-written [Unreleased] line fails, quoting the line" \
  || bad "a hand-written [Unreleased] line fails, quoting the line" "rc=$RC out=$OUT"
case "$OUT" in *"A released entry"*) bad "no untouched line is named as gained" "$OUT" ;; *) ok "no untouched line is named as gained" ;; esac
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 0 ] && ok "GROWTH_GUARDS_CHANGELOG_COLLATE=1 declares the collator's write" \
  || bad "GROWTH_GUARDS_CHANGELOG_COLLATE=1 declares the collator's write" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_RECORD='
[ "$RC" -eq 0 ] && ok "an empty record setting switches the scope off" \
  || bad "an empty record setting switches the scope off" "rc=$RC out=$OUT"
# A second copy of a line HEAD carries once is a line this commit gained.
record '- One line.'
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"gained lines under [Unreleased]"*"- One line."*) true ;; *) false ;; esac \
  && ok "a duplicated [Unreleased] line fails, quoting it" \
  || bad "a duplicated [Unreleased] line fails, quoting it" "rc=$RC out=$OUT"
# Blank lines are not content: padding alone cannot refuse, and what keeping
# it out of the compared sets holds is the diagnostic.
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A wrapped entry\n  second line.\n\n\n\n- One line.\n\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "blank padding under [Unreleased] is not a gained line" \
  || bad "blank padding under [Unreleased] is not a gained line" "rc=$RC out=$OUT"
# Rotating the section into a released version gains nothing.
printf '# Changelog\n\n## [Unreleased]\n\n## [1.1.0] - 2026-02-01\n\n### Fixed\n\n- A wrapped entry\n  second line.\n- One line.\n\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "rotating [Unreleased] into a released version adds no line" \
  || bad "rotating [Unreleased] into a released version adds no line" "rc=$RC out=$OUT"

# More gained lines than the diagnostic quotes, and one carrying an escape
# that sorts into the quoted five: the count is capped and the record's own
# bytes never reach the reader's terminal.
{
  printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n'
  printf -- '- A wrapped entry\n  second line.\n- One line.\n'
  printf -- '- 0 gained with an escape \033[31mred\033[0m.\n'
  printf -- '- %s gained.\n' 1 2 3 4 5 6
  printf '\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n'
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && ok "seven gained lines are refused" \
  || bad "seven gained lines are refused" "rc=$RC out=$OUT"
[ "$(printf '%s\n' "$OUT" | grep -c '^    - ')" -eq 5 ] \
  && ok "the diagnostic quotes five of them, not all seven" \
  || bad "the diagnostic quotes five of them, not all seven" "$OUT"
case "$OUT" in *"?[31mred?[0m"*) ok "the escape in a quoted line is replaced" ;; *) bad "the escape in a quoted line is replaced" "$OUT" ;; esac
printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '[\001-\010\013-\037\177]')" \
  && bad "no control byte from the record may reach the output" "$OUT" \
  || ok "no control byte from the record reaches the output"

echo "=== the heading is found by structure, never by substring ==="
new_repo heading
# The base carries an accepted record: HEAD is what the staged copy is
# compared against, and a HEAD this guard would refuse is a comparison
# skipped, which would leave the grammar cases below nothing to bite on.
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
# A fenced block naming the heading opens no section, so the lines under it
# are still the released ones nobody may claim are unreleased.
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n```\n## [Unreleased]\n```\n\n- A released entry.\n- A line that would be gained if the fence counted.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"carries no '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "a fenced mention of the heading opens no [Unreleased] section" \
  || bad "a fenced mention of the heading opens no [Unreleased] section" "rc=$RC out=$OUT"
# The control: the same line under a real heading is refused, so the pass
# above is the fence and not a rule that stopped looking.
printf '# Changelog\n\n## [Unreleased]\n\n- A line that would be gained if the fence counted.\n\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"gained lines under [Unreleased]"*) true ;; *) false ;; esac \
  && ok "control: the same line under a real heading is refused" \
  || bad "control: the same line under a real heading is refused" "rc=$RC out=$OUT"
# A closing hash sequence and up to three leading spaces are still the heading.
printf '# Changelog\n\n   ## [Unreleased] ##\n\n- A gained line.\n\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"gained lines under [Unreleased]"*"- A gained line."*) true ;; *) false ;; esac \
  && ok "an indented heading with a closing hash sequence still opens the section" \
  || bad "an indented heading with a closing hash sequence still opens the section" "rc=$RC out=$OUT"
# A heading that only STARTS with the canonical text is a different heading.
# The bounds this grammar emits are what the collator splits and deletes
# fragments against, so a prefix match would hand it a section nobody meant.
printf '# Changelog\n\n## [Unreleased] archive\n\n- A gained line.\n\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"carries no '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "a heading that merely begins with [Unreleased] opens no section" \
  || bad "a heading that merely begins with [Unreleased] opens no section" "rc=$RC out=$OUT"
# The control: the exact heading, differing only in case, does open it.
printf '# Changelog\n\n## [UNRELEASED]\n\n- A gained line.\n\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"gained lines under [Unreleased]"*"- A gained line."*) true ;; *) false ;; esac \
  && ok "control: the exact heading opens it whatever its case" \
  || bad "control: the exact heading opens it whatever its case" "rc=$RC out=$OUT"
# Four leading spaces is an indented code block, not a heading.
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n    ## [Unreleased]\n\n- A released entry.\n- Not gained.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"carries no '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "four leading spaces open no heading" \
  || bad "four leading spaces open no heading" "rc=$RC out=$OUT"
# A level-3 heading inside the section does not close it.
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A gained line under a sub-heading.\n\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"- A gained line under a sub-heading."*) true ;; *) false ;; esac \
  && ok "a level-3 heading does not close the section" \
  || bad "a level-3 heading does not close the section" "rc=$RC out=$OUT"

# A level-1 heading ends the section as surely as a level-2 one, so a line
# below it is not a line under [Unreleased].
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n\n# Notes\n\n- Below a level-1 heading.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: carry a level-1 heading"
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n\n# Notes\n\n- Below a level-1 heading.\n- Added below it.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "a line added below a level-1 heading is outside the section" \
  || bad "a line added below a level-1 heading is outside the section" "rc=$RC out=$OUT"
# The control: the same line above that heading is inside, so the pass above
# is the heading closing the section and not the comparison going blind.
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n- Added above it.\n\n# Notes\n\n- Below a level-1 heading.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"- Added above it."*) true ;; *) false ;; esac \
  && ok "control: the same line above that heading is refused" \
  || bad "control: the same line above that heading is refused" "rc=$RC out=$OUT"

echo "=== an unclosed fence fails closed; a shorter run does not close a longer one ==="
new_repo fences
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
# A stray opening fence above the heading: a parser that swallows headings
# while a fence is open finds no section on either side, compares nothing to
# nothing, and calls a hand-written line unchanged.
printf '# Changelog\n\n```\n\n## [Unreleased]\n\n- One line.\n- SNEAKED IN BY HAND.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"leaves a code fence unclosed"*) true ;; *) false ;; esac \
  && ok "an unterminated fence is exit 2, naming what could not be located" \
  || bad "an unterminated fence is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"unchanged under [Unreleased]"*) bad "no run may call the record unchanged over a document it could not read" "$OUT" ;;
  *) ok "no run calls the record unchanged over a document it could not read" ;; esac
# A run of the fence character with content after it is an opening fence, not
# a closing one, so it ends nothing either.
{
  printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n'
  printf '```\n``` js\n## [Unreleased]\n```\n\n'
  printf '## [Unreleased]\n\n- One line.\n- SNEAKED IN BY HAND.\n'
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"gained lines under [Unreleased]"*"- SNEAKED IN BY HAND."*) true ;; *) false ;; esac \
  && ok "a run with content after it closes no fence, so the heading below it is found" \
  || bad "a run with content after it closes no fence" "rc=$RC out=$OUT"
# A three-backtick line inside a four-backtick block closes nothing, so the
# real four-backtick close is what ends it and the heading after it is found.
{
  printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n'
  printf '````\n```\n````\n\n'
  printf '## [Unreleased]\n\n- One line.\n- SNEAKED IN BY HAND.\n'
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"gained lines under [Unreleased]"*"- SNEAKED IN BY HAND."*) true ;; *) false ;; esac \
  && ok "a shorter run inside a longer fence does not end it, and the heading after it is found" \
  || bad "a shorter run inside a longer fence does not end it" "rc=$RC out=$OUT"
# The control: the same document with nothing added passes, so the refusal
# above is the line and not the fence shape failing outright.
{
  printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n'
  printf '````\n```\n````\n\n'
  printf '## [Unreleased]\n\n- One line.\n'
} >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: carry the fenced record"
run_ce
[ "$RC" -eq 0 ] && ok "control: the same fenced document with nothing added passes" \
  || bad "control: the same fenced document with nothing added passes" "rc=$RC out=$OUT"
# A SECOND canonical heading leaves the section undecided. This judge compares
# CONTENT, and a duplicate emits none of its own, so an empty one would read as
# a record nobody touched while the collator went on to publish under whichever
# heading it saw last.
new_repo recorddup
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
run_ce
[ "$RC" -eq 0 ] && ok "control: one heading is a record this judge reads" \
  || bad "control: one heading is a record this judge reads" "rc=$RC out=$OUT"
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n\n## [Unreleased]\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"more than one '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "a second heading is exit 2, naming what cannot be decided" \
  || bad "a second heading is exit 2, naming what cannot be decided" "rc=$RC out=$OUT"
case "$OUT" in *"unchanged under [Unreleased]"*) bad "no run may call the record unchanged over a document it could not read" "$OUT" ;;
  *) ok "and no run calls that record unchanged" ;; esac
# The near-miss beside the real heading is not a duplicate: it is a different
# heading, which the equality rule already settles.
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n\n## [Unreleased] archive\n\n- Not the section.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "control: a near-miss beside the real heading is no duplicate" \
  || bad "control: a near-miss beside the real heading is no duplicate" "rc=$RC out=$OUT"
# A fenced example of the heading is not one either, so the two rules agree
# about what counts as a heading at all.
printf '# Changelog\n\n## [Unreleased]\n\n```\n## [Unreleased]\n```\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: carry the fenced example"
run_ce
[ "$RC" -eq 0 ] && ok "control: a fenced example of the heading is no duplicate" \
  || bad "control: a fenced example of the heading is no duplicate" "rc=$RC out=$OUT"

echo "=== the record is read the way a fragment is: text, or no verdict ==="
new_repo recordtext
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
run_ce
[ "$RC" -eq 0 ] && ok "control: an ordinary record is judged and clean" \
  || bad "control: an ordinary record is judged and clean" "rc=$RC out=$OUT"
# UNCHANGED and holding bytes that are not valid UTF-8. Nothing is gained, so
# a comparison alone reports clean over a document it cannot count — which is
# the refusal the fragment scope has always given.
{
  printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n  '
  LC_ALL=C awk 'BEGIN { for (i = 0; i < 20; i++) printf "%c", 191 }'
  printf '\n'
} >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: a record with stray bytes"
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"CHANGELOG.md line 6 is not valid UTF-8"*) true ;; *) false ;; esac \
  && ok "an unchanged record that is not valid UTF-8 is exit 2, naming the line" \
  || bad "an unchanged record that is not valid UTF-8 is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"changelog-entries: OK"*) bad "no OK verdict may accompany a record it could not read" "$OUT" ;;
  *) ok "no OK verdict accompanies a record it could not read" ;; esac
# GAINED invalid bytes are the same refusal, not a line violation: the
# encoding is judged before anything is compared.
{
  printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n  '
  LC_ALL=C awk 'BEGIN { for (i = 0; i < 20; i++) printf "%c", 191 }'
  printf '\n- A hand-written line.\n'
} >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"is not valid UTF-8"*) true ;; *) false ;; esac \
  && ok "newly gained invalid bytes are the encoding refusal, not a gained-line violation" \
  || bad "newly gained invalid bytes are the encoding refusal" "rc=$RC out=$OUT"
case "$OUT" in *"gained lines under [Unreleased]"*) bad "no gained-line verdict over unreadable bytes" "$OUT" ;;
  *) ok "no gained-line verdict over unreadable bytes" ;; esac
# Binary content is the other half of the same discipline. Every byte value,
# so a NUL falls in the sample git classifies on.
{
  printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n'
  LC_ALL=C awk 'BEGIN { for (i = 0; i < 256; i++) printf "%c", i }'
} >"$R/CHANGELOG.md"
stage
[ -z "$(git -C "$R" grep --cached -I -l . -- CHANGELOG.md)" ] \
  && ok "fixture: git itself calls the record binary" \
  || bad "fixture: git itself calls the record binary" "git grep listed it"
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"holds binary content"*) true ;; *) false ;; esac \
  && ok "a binary record is exit 2, never compared line by line" \
  || bad "a binary record is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"changelog-entries: OK"*) bad "no OK verdict may accompany a binary record" "$OUT" ;;
  *) ok "no OK verdict accompanies a binary record" ;; esac

echo "=== the declaration bypasses the comparison, not what the record IS ==="
# GROWTH_GUARDS_CHANGELOG_COLLATE=1 is exported exactly while a collation
# runs, so a rule it switched off would be off at the one moment the record
# is about to be rewritten. Only the gained-line comparison is a rule a
# collation legitimately breaks.
new_repo declared
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 0 ] && ok "control: a real record passes under the declaration" \
  || bad "control: a real record passes under the declaration" "rc=$RC out=$OUT"
# A symlink is the case the collator's own rename would then turn into a
# regular file, with nothing having read what it pointed at.
printf '# Elsewhere\n\n## [Unreleased]\n\n- One line.\n' >"$R/elsewhere.md"
rm -f "$R/CHANGELOG.md"
ln -s elsewhere.md "$R/CHANGELOG.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 2 ] && case "$OUT" in *"tracked as a symlink or gitlink"*) true ;; *) false ;; esac \
  && ok "a staged record symlink is refused under the declaration too" \
  || bad "a staged record symlink is refused under the declaration too" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD
rm -f "$R/elsewhere.md"
# So are the text rules: what the record IS does not turn on who is writing.
{
  printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n  '
  LC_ALL=C awk 'BEGIN { for (i = 0; i < 20; i++) printf "%c", 191 }'
  printf '\n'
} >"$R/CHANGELOG.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 2 ] && case "$OUT" in *"is not valid UTF-8"*) true ;; *) false ;; esac \
  && ok "a record that is not valid UTF-8 is refused under the declaration too" \
  || bad "a record that is not valid UTF-8 is refused under the declaration too" "rc=$RC out=$OUT"
{
  printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n'
  LC_ALL=C awk 'BEGIN { for (i = 0; i < 256; i++) printf "%c", i }'
} >"$R/CHANGELOG.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 2 ] && case "$OUT" in *"holds binary content"*) true ;; *) false ;; esac \
  && ok "a binary record is refused under the declaration too" \
  || bad "a binary record is refused under the declaration too" "rc=$RC out=$OUT"
# And the one rule it DOES bypass still stands down: a gained line passes.
git -C "$R" reset -q --hard HEAD
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n- A collated line.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && ok "control: that same gained line is refused undeclared" \
  || bad "control: that same gained line is refused undeclared" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 0 ] && ok "and the declaration is what lets it through" \
  || bad "and the declaration is what lets it through" "rc=$RC out=$OUT"

echo "=== the comparison does not turn on the caller's collation ==="
# comm and its inputs must agree on one order. These lines sort one way by
# byte and another under a locale that folds punctuation, so a mismatch makes
# comm call a sorted file unsorted and name lines nobody wrote.
new_repo locale
printf -- '- A fragment.\n' | frag fixed ken-1.md
UR='# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- **Breaking:** alpha.\n- plain beta.\n- `code` gamma.\n- Zeta delta.\n'
printf "$UR" >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: a changelog that sorts two ways"
# The locale is discovered from the file under test: any installed one whose
# order over these very lines differs from byte order will do.
COLLATE_LOCALE=""
for cand in $(locale -a 2>/dev/null); do
  case "$cand" in C | C.* | POSIX) continue ;; esac
  LC_ALL="$cand" sort "$R/CHANGELOG.md" >"$TMP/loc" 2>/dev/null || continue
  LC_ALL=C sort "$R/CHANGELOG.md" >"$TMP/byte"
  cmp -s "$TMP/loc" "$TMP/byte" && continue
  COLLATE_LOCALE="$cand"
  break
done
if [ -z "$COLLATE_LOCALE" ]; then
  echo "  note  no installed locale orders these lines differently from C — the collation pair cannot run here"
else
  printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- **Breaking:** alpha.\n- plain beta.\n- `code` gamma.\n' >"$R/CHANGELOG.md"
  stage
  run_ce_env "LC_ALL=$COLLATE_LOCALE"
  [ "$RC" -eq 0 ] && ok "a deletion-only edit passes under $COLLATE_LOCALE" \
    || bad "a deletion-only edit passes under $COLLATE_LOCALE" "rc=$RC out=$OUT"
  printf "$UR"'- A hand-written line.\n' >"$R/CHANGELOG.md"
  stage
  run_ce_env "LC_ALL=$COLLATE_LOCALE"
  [ "$RC" -eq 1 ] && case "$OUT" in *"gained lines under [Unreleased]"*"- A hand-written line."*) true ;; *) false ;; esac \
    && ok "under $COLLATE_LOCALE the one added line is the only one named" \
    || bad "under $COLLATE_LOCALE the one added line is the only one named" "rc=$RC out=$OUT"
  case "$OUT" in *Breaking*) bad "no untouched line is named as gained" "$OUT" ;; *) ok "no untouched line is named as gained" ;; esac
fi

echo "=== a record git does not track as a file fails closed ==="
new_repo recordlink
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
run_ce
[ "$RC" -eq 0 ] && ok "control: the real record is judged and clean" \
  || bad "control: the real record is judged and clean" "rc=$RC out=$OUT"
# Replaced in the index by a link out of the tree. Reading it as changelog
# text would measure whatever it points at against HEAD's real record.
printf '# Elsewhere\n\n## [Unreleased]\n\n- One line.\n- SNEAKED IN.\n' >"$R/elsewhere.md"
rm -f "$R/CHANGELOG.md"
ln -s elsewhere.md "$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 2 ] && case "$OUT" in *"tracked as a symlink or gitlink"*) true ;; *) false ;; esac \
  && ok "a record staged as a symlink is exit 2, naming why it could not be read" \
  || bad "a record staged as a symlink is exit 2" "rc=$RC out=$OUT"
case "$OUT" in *"changelog-entries: OK"*) bad "no OK verdict may accompany a record that could not be read" "$OUT" ;;
  *) ok "no OK verdict accompanies a record that could not be read" ;; esac

echo "=== a record scope that stands down says which way it stood down ==="
new_repo standdown
printf -- '- A fragment.\n' | frag fixed ken-1.md
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"no record to judge"*"is not tracked"*) true ;; *) false ;; esac \
  && ok "an untracked record says so" \
  || bad "an untracked record says so" "rc=$RC out=$OUT"
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"HEAD carries no"*) true ;; *) false ;; esac \
  && ok "a record HEAD does not carry yet says so" \
  || bad "a record HEAD does not carry yet says so" "rc=$RC out=$OUT"
git -C "$R" commit -qm base
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 0 ] && case "$OUT" in *"NOT compared"*"GROWTH_GUARDS_CHANGELOG_COLLATE=1"*) true ;; *) false ;; esac \
  && ok "a declared collation says the comparison stood down, and what declared it" \
  || bad "a declared collation says the comparison stood down, and what declared it" "rc=$RC out=$OUT"
case "$OUT" in *"unchanged under [Unreleased]"*) bad "a disarmed gate never claims the record is unchanged" "$OUT" ;;
  *) ok "a disarmed gate never claims the record is unchanged" ;; esac
run_ce_env 'GROWTH_GUARDS_CHANGELOG_RECORD='
[ "$RC" -eq 0 ] && case "$OUT" in *"no record scope"*"is empty"*) true ;; *) false ;; esac \
  && ok "an empty record setting says the scope is off" \
  || bad "an empty record setting says the scope is off" "rc=$RC out=$OUT"
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"unchanged under [Unreleased]"*) true ;; *) false ;; esac \
  && ok "control: judged and clean says exactly that" \
  || bad "control: judged and clean says exactly that" "rc=$RC out=$OUT"

echo "=== a record staged away is a deletion, not a repository that never had one ==="
# The two states look identical from the index alone, and read as the same
# stand-down they would ship the consumer changelog's deletion as a clean run.
new_repo recordgone
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
run_ce
[ "$RC" -eq 0 ] && ok "control: the record HEAD carries is judged and clean" \
  || bad "control: the record HEAD carries is judged and clean" "rc=$RC out=$OUT"
git -C "$R" rm -q CHANGELOG.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"CHANGELOG.md is tracked in HEAD and staged away"*) true ;; *) false ;; esac \
  && ok "deleting the record is refused, naming it" \
  || bad "deleting the record is refused, naming it" "rc=$RC out=$OUT"
case "$OUT" in *"is not tracked"*) bad "a deletion never reads as a repository with no record" "$OUT" ;;
  *) ok "and it never reads as a repository with no record" ;; esac
# A rename out from under the setting is the same deletion by another spelling.
git -C "$R" reset -q --hard HEAD
git -C "$R" mv CHANGELOG.md HISTORY.md
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"CHANGELOG.md is tracked in HEAD and staged away"*) true ;; *) false ;; esac \
  && ok "renaming the record away is the same refusal" \
  || bad "renaming the record away is the same refusal" "rc=$RC out=$OUT"
# The declaration does not reach this refusal. A collation renames a
# replacement over the record and never removes it, so no release owes the
# deletion an exemption, and one that claimed it would ship the consumer
# changelog's removal under the release commit's own declaration.
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 1 ] && case "$OUT" in *"is tracked in HEAD and staged away"*) true ;; *) false ;; esac \
  && ok "a declared collation may not write the removal either" \
  || bad "a declared collation may not write the removal either" "rc=$RC out=$OUT"
# The control that matters: a repository that never carried one still stands
# down cleanly, which is the case this refusal must not swallow.
git -C "$R" reset -q --hard HEAD
new_repo recordnever
printf -- '- A fragment.\n' | frag fixed ken-1.md
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"no record to judge"*"is not tracked"*) true ;; *) false ;; esac \
  && ok "control: a repository that never had a record stands down" \
  || bad "control: a repository that never had a record stands down" "rc=$RC out=$OUT"

echo "=== the declaration bypasses the comparison and nothing else ==="
# Read in one place and permitting one thing. Every other rule in this scope
# is as true during a release as outside one, so each is pinned as still
# running with the declaration set — a rule added later is outside it by
# construction, and these are what would catch it being opted back in.
new_repo recorddeclared
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
# THE one thing it permits: lines the collation folded in.
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n- A folded entry.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"gained lines under [Unreleased]"*) true ;; *) false ;; esac \
  && ok "control: undeclared, the gained line is refused" \
  || bad "control: undeclared, the gained line is refused" "rc=$RC out=$OUT"
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 0 ] && case "$OUT" in *"NOT compared"*"GROWTH_GUARDS_CHANGELOG_COLLATE=1"*) true ;; *) false ;; esac \
  && ok "declared, the same gained line is the write it declares" \
  || bad "declared, the same gained line is the write it declares" "rc=$RC out=$OUT"
# And every other rule, with the declaration set. A symlink record first.
git -C "$R" reset -q --hard HEAD
ln -sf /etc/hostname "$R/link.md"
git -C "$R" rm -q --cached CHANGELOG.md
git -C "$R" mv link.md CHANGELOG.md 2>/dev/null || { rm -f "$R/CHANGELOG.md"; ln -sf /etc/hostname "$R/CHANGELOG.md"; git -C "$R" add -A; }
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 2 ] && case "$OUT" in *"tracked as a symlink or gitlink"*) true ;; *) false ;; esac \
  && ok "declared, a record staged as a symlink is still exit 2" \
  || bad "declared, a record staged as a symlink is still exit 2" "rc=$RC out=$OUT"
# An unclosed fence, which leaves the section unlocatable.
git -C "$R" reset -q --hard HEAD
printf '# Changelog\n\n```\n\n## [Unreleased]\n\n- One line.\n' >"$R/CHANGELOG.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 2 ] && case "$OUT" in *"leaves a code fence unclosed"*) true ;; *) false ;; esac \
  && ok "declared, an unterminated fence is still exit 2" \
  || bad "declared, an unterminated fence is still exit 2" "rc=$RC out=$OUT"
# A second canonical heading, which leaves the section undecided.
git -C "$R" reset -q --hard HEAD
printf '# Changelog\n\n## [Unreleased]\n\n- One line.\n\n## [Unreleased]\n' >"$R/CHANGELOG.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 2 ] && case "$OUT" in *"more than one '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "declared, a second heading is still exit 2" \
  || bad "declared, a second heading is still exit 2" "rc=$RC out=$OUT"
# The heading staged away, which leaves a later collation nowhere to fold.
git -C "$R" reset -q --hard HEAD
printf '# Log\n' >"$R/CHANGELOG.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 1 ] && case "$OUT" in *"carries no '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "declared, staging the heading away is still refused" \
  || bad "declared, staging the heading away is still refused" "rc=$RC out=$OUT"
# The release flow itself, which is what the declaration is FOR: the heading
# renamed to a version and a fresh empty one opened, with the entries folded.
git -C "$R" reset -q --hard HEAD
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- One line.\n- A folded entry.\n' >"$R/CHANGELOG.md"
stage
run_ce_env 'GROWTH_GUARDS_CHANGELOG_COLLATE=1'
[ "$RC" -eq 0 ] && ok "control: the release write the declaration is for still passes" \
  || bad "control: the release write the declaration is for still passes" "rc=$RC out=$OUT"

echo "=== staging the heading away is a refusal, not an unchanged section ==="
# An EMPTY section and a MISSING one both parse to nothing, so the comparison
# alone reports the record unchanged and the malformed state lands.
new_repo recordheading
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Changelog\n\n## [Unreleased]\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
run_ce
[ "$RC" -eq 0 ] && case "$OUT" in *"unchanged under [Unreleased]"*) true ;; *) false ;; esac \
  && ok "control: an empty section HEAD also carries is unchanged" \
  || bad "control: an empty section HEAD also carries is unchanged" "rc=$RC out=$OUT"
printf '# Log\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"carries no '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "staging the heading away is refused, naming what went" \
  || bad "staging the heading away is refused, naming what went" "rc=$RC out=$OUT"
case "$OUT" in *"unchanged under [Unreleased]"*) bad "no run calls that record unchanged" "$OUT" ;;
  *) ok "and no run calls that record unchanged" ;; esac
# The release renames the heading and opens a fresh empty one, so the flow the
# docs describe is not what this refuses.
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 0 ] && ok "control: renaming it and opening a fresh empty one passes" \
  || bad "control: renaming it and opening a fresh empty one passes" "rc=$RC out=$OUT"
# A record that NEVER opened the section is the same refusal, not a lesser
# one: a release folds every fragment into that heading and deletes the files
# they came from, so there is nowhere to put them either way. The collator
# used to be the only thing that said so, at the tag.
new_repo recordnoheading
printf -- '- A fragment.\n' | frag fixed ken-1.md
printf '# Log\n\n- Nothing calls itself unreleased.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm base
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"carries no '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "a record that never opened a section is refused at commit time" \
  || bad "a record that never opened a section is refused at commit time" "rc=$RC out=$OUT"
# The control: opening one is all it takes.
printf '# Log\n\n## [Unreleased]\n\n- Nothing calls itself unreleased.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: open the section"
run_ce
[ "$RC" -eq 0 ] && ok "control: opening the section is all it takes" \
  || bad "control: opening the section is all it takes" "rc=$RC out=$OUT"
# A level-3 heading inside the section that names no section is refused here
# too, which is the other half the collator used to catch alone.
printf '# Log\n\n## [Unreleased]\n\n### Notes\n\n- Not a section.\n' >"$R/CHANGELOG.md"
stage
run_ce
[ "$RC" -eq 1 ] && case "$OUT" in *"names 'Notes' under [Unreleased]"*"not a Keep a Changelog section"*) true ;; *) false ;; esac \
  && ok "an unsupported section heading is refused at commit time" \
  || bad "an unsupported section heading is refused at commit time" "rc=$RC out=$OUT"
# The control: the same shape under a real section heading passes.
printf '# Log\n\n## [Unreleased]\n\n### Fixed\n\n- A real section.\n' >"$R/CHANGELOG.md"
stage
git -C "$R" commit -qm "chore: carry a real section"
run_ce
[ "$RC" -eq 0 ] && ok "control: a real section heading passes" \
  || bad "control: a real section heading passes" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
