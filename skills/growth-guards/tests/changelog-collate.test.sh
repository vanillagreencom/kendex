#!/usr/bin/env bash
# Pins the WRITE path of scripts/changelog-entries --collate: it folds the
# fragments this run accepted into the record's [Unreleased] section, under
# the heading each fragment's own section names, in Keep a Changelog order and
# filename order within a section; it splits the record at the line numbers
# the STAGED copy was accepted with, collapses two headings for one section
# into one, deletes the fragments and the section directory each leaves empty,
# and refuses without writing when the judgement refuses or when git and the
# working tree disagree about the record or any fragment. The refusing
# direction runs first in every pair, and each refusal is checked to have left
# the record and the fragments as they were — a fold that half-writes or
# half-deletes is the failure this guards.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CE="$(cd "$TEST_DIR/.." && pwd)/scripts/changelog-entries"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"

unset GROWTH_GUARDS_CHANGELOG_CAP GROWTH_GUARDS_CHANGELOG_PATHS \
  GROWTH_GUARDS_CHANGELOG_RECORD GROWTH_GUARDS_CHANGELOG_COLLATE \
  GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test

reset() { # RECORD on stdin — the fixture record and an empty tree, committed
  rm -rf -- "${R:?}/changelog.d"
  cat >"$R/CHANGELOG.md"
  git -C "$R" add -A
  # Committed, not merely staged: the record scope compares the staged copy
  # against HEAD, so a fixture that only stages one reads as a hand edit.
  git -C "$R" commit -q --allow-empty -m "chore: reset the fixture"
  cp "$R/CHANGELOG.md" "$TMP/before"
}

stage_record() { # RECORD on stdin — staged over the committed one, not committed
  cat >"$R/CHANGELOG.md"
  git -C "$R" add -A -- CHANGELOG.md
  cp "$R/CHANGELOG.md" "$TMP/before"
}

frag() { # SECTION NAME — content on stdin, written and staged
  mkdir -p "$R/changelog.d/$1"
  cat >"$R/changelog.d/$1/$2"
  git -C "$R" add -A -- changelog.d
}

run_collate() { OUT=""; RC=0; OUT="$(cd "$R" && "$CE" --collate 2>&1)" || RC=$?; }
untouched() { cmp -s "$R/CHANGELOG.md" "$TMP/before"; }
no_staging() { # no residue beside the record, whatever mktemp named it
  STAGING=""
  for f in "$R"/CHANGELOG.md.*; do
    [ ! -e "$f" ] || STAGING="$STAGING $f"
  done
  [ -z "$STAGING" ]
}

RECORD='# Changelog

## [Unreleased]

### Added

- An entry the record already carries.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
'

echo "=== a record naming a section this family cannot write is refused, and nothing is written ==="
printf '%s' "$RECORD" | sed 's/^### Added$/### Add/' | reset
printf -- '- Folded in.\n' | frag fixed ken-1.md
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"names 'Add' under [Unreleased], which is not a Keep a Changelog section"*) true ;; *) false ;; esac \
  && ok "a misspelled section heading refuses the fold" || bad "a misspelled section heading refuses the fold" "rc=$RC out=$OUT"
untouched && ok "the record is untouched by that refusal" || bad "the record is untouched by that refusal" "$(cat "$R/CHANGELOG.md")"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "and the fragment survives it" || bad "and the fragment survives it" "deleted"

echo "=== a fragment the judge refuses stops the run before any write ==="
printf '%s' "$RECORD" | reset
printf -- '- Folded in.\n' | frag fixed ken-1.md
printf 'Prose, not a list item.\n' | frag fixed bad.md
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/bad.md does not open with a list marker"*) true ;; *) false ;; esac \
  && ok "the fold carries the judgement's refusal as its own" \
  || bad "the fold carries the judgement's refusal as its own" "rc=$RC out=$OUT"
untouched && ok "the record is untouched while one fragment is refused" \
  || bad "the record is untouched while one fragment is refused" "$(cat "$R/CHANGELOG.md")"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "and the acceptable fragment beside it is not folded in and deleted" \
  || bad "and the acceptable fragment beside it is not folded in and deleted" "deleted"

echo "=== every guarantee of the fold, on one record and one exact expected output ==="
# One fixture, because these rules only meet in a file: all six section
# headings spelled from the section names alone, two fragments in one section
# to make within-section filename order observable, a lead carrying a blank
# RUN so the collapse to one blank is visible, and a second '### Added'
# further down so the collapse of two headings into one is too.
printf '%s' '# Changelog

Preamble.

## [Unreleased]

A lead paragraph the section carries.


A second lead paragraph, after the blank run above.

### Added

- An entry the record already carries.

### Fixed

- A fixed entry the record already carries.

### Added

- A second Added heading further down.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
' | reset
printf -- '- Added, first by filename.\n' | frag added ken-1.md
printf -- '- Added, second by filename.\n' | frag added ken-2.md
printf -- '- Changed something.\n' | frag changed ken-3.md
printf -- '- Deprecated something.\n' | frag deprecated ken-4.md
printf -- '- Removed something.\n' | frag removed ken-5.md
printf -- '- Fixed something.\n' | frag fixed ken-6.md
# No trailing newline: two entries glued into one line is what normalizing it
# prevents, and only a fixture written this way can catch that.
printf -- '- Tightened something.' | frag security ken-7.md
run_collate
[ "$RC" -eq 0 ] && case "$OUT" in *"folded 7 entries into CHANGELOG.md's [Unreleased] section"*) true ;; *) false ;; esac \
  && ok "the fold reports what it folded" || bad "the fold reports what it folded" "rc=$RC out=$OUT"
# The record scope's note rides the fold's line: this run is the one writing
# the record, so which way that scope stood down has no other reader.
case "$OUT" in *"CHANGELOG.md unchanged under [Unreleased]"*) ok "and carries the record scope's note with it" ;;
  *) bad "and carries the record scope's note with it" "$OUT" ;; esac
EXPECTED='# Changelog

Preamble.

## [Unreleased]
A lead paragraph the section carries.

A second lead paragraph, after the blank run above.

### Added

- An entry the record already carries.
- A second Added heading further down.
- Added, first by filename.
- Added, second by filename.

### Changed

- Changed something.

### Deprecated

- Deprecated something.

### Removed

- Removed something.

### Fixed

- A fixed entry the record already carries.
- Fixed something.

### Security

- Tightened something.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
'
[ "$(cat "$R/CHANGELOG.md")" = "$(printf '%s' "$EXPECTED")" ] \
  && ok "the collated block is exactly the expected one" \
  || bad "the collated block is exactly the expected one" "$(diff <(printf '%s' "$EXPECTED") "$R/CHANGELOG.md" || true)"
LEFT="$(find "$R/changelog.d" -mindepth 1 | sort | tr '\n' ' ')"
[ -z "$LEFT" ] && ok "every fragment and the section directory each leaves empty are gone" \
  || bad "every fragment and the section directory each leaves empty are gone" "$LEFT"
no_staging && ok "the install leaves no staging file beside the record" \
  || bad "the install leaves no staging file beside the record" "$STAGING"

echo "=== the record is split at the STAGED copy's line numbers, not HEAD's ==="
# The record scope keeps those numbers for the staged copy alone, so HEAD's
# parse — which runs after it — cannot overwrite them. A fixture whose two
# copies agree cannot tell the two apart, so this one moves the section: the
# staged copy adds preamble ABOVE the heading and gains no line under it, so
# the record scope still passes and the only difference between the copies is
# where the section sits. Split at HEAD's numbers instead, the fold drops
# preamble and writes a section heading above '## [Unreleased]' — and exits 0.
printf '%s' "$RECORD" | reset
printf '%s' '# Changelog

Preamble the staged copy adds.

More preamble.

## [Unreleased]

### Added

- An entry the record already carries.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
' | stage_record
printf -- '- Folded in below the moved heading.\n' | frag fixed ken-1.md
run_collate
[ "$RC" -eq 0 ] && ok "a record whose section moved still folds" || bad "a record whose section moved still folds" "rc=$RC out=$OUT"
MOVED='# Changelog

Preamble the staged copy adds.

More preamble.

## [Unreleased]

### Added

- An entry the record already carries.

### Fixed

- Folded in below the moved heading.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
'
[ "$(cat "$R/CHANGELOG.md")" = "$(printf '%s' "$MOVED")" ] \
  && ok "and it is split where the staged copy puts the section, losing no preamble" \
  || bad "and it is split where the staged copy puts the section, losing no preamble" "$(diff <(printf '%s' "$MOVED") "$R/CHANGELOG.md" || true)"

echo "=== an unstaged edit stops the write, on either side of the fold ==="
printf '%s' "$RECORD" | reset
printf -- '- Folded in.\n' | frag fixed ken-1.md
printf -- '- Edited only on disk.\n' >"$R/changelog.d/fixed/ken-1.md"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"differs between git and the working tree"*"changelog.d/fixed/ken-1.md"*) true ;; *) false ;; esac \
  && ok "a fragment git and the disk disagree about refuses the fold" \
  || bad "a fragment git and the disk disagree about refuses the fold" "rc=$RC out=$OUT"
untouched && ok "the record is untouched by that refusal too" || bad "the record is untouched by that refusal too" "$(cat "$R/CHANGELOG.md")"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "and the fragment survives it too" || bad "and the fragment survives it too" "deleted"

# The RECORD half of that same guard. Without it the fold publishes a record
# nothing measured and then deletes the fragments that went into it, so the
# unstaged edit ships with no copy left to recover the entries from.
printf '%s' "$RECORD" | reset
printf -- '- Folded in.\n' | frag fixed ken-1.md
printf -- '\n- An entry only the disk carries.\n' >>"$R/CHANGELOG.md"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"differs between git and the working tree"*"CHANGELOG.md"*) true ;; *) false ;; esac \
  && ok "a record git and the disk disagree about refuses the fold" \
  || bad "a record git and the disk disagree about refuses the fold" "rc=$RC out=$OUT"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "and the fragment survives that refusal" \
  || bad "and the fragment survives that refusal" "deleted"
case "$(cat "$R/CHANGELOG.md")" in
  *"An entry only the disk carries"*) ok "the unstaged record edit is neither published nor overwritten" ;;
  *) bad "the unstaged record edit is neither published nor overwritten" "$(cat "$R/CHANGELOG.md")" ;;
esac

echo "=== a failure at the rename leaves nothing half-written ==="
# A stub ahead of PATH is how a failure is reached in the window where the
# staging file already exists: nothing else in the fold runs mv.
STUB="$TMP/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\necho "mv: refused by the test stub" >&2\nexit 1\n' >"$STUB/mv"
chmod +x "$STUB/mv"
printf '%s' "$RECORD" | reset
printf -- '- Folded in.\n' | frag fixed ken-1.md
OUT=""
RC=0
OUT="$(cd "$R" && PATH="$STUB:$PATH" "$CE" --collate 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not replace the collated changelog"*) true ;; *) false ;; esac \
  && ok "a failed rename is a loud refusal" || bad "a failed rename is a loud refusal" "rc=$RC out=$OUT"
# What the tool said arrives INSIDE the guard's line, not on a bare line ahead
# of it: a reader takes the first line they see as the cause, and `mv: ...`
# alone names the symptom without saying what was being done.
case "$OUT" in
  *"could not replace the collated changelog"*"refused by the test stub"*)
    ok "and it carries what mv said inside its own line" ;;
  *) bad "and it carries what mv said inside its own line" "$OUT" ;;
esac
untouched && ok "the record is byte-identical after the failed rename" \
  || bad "the record is byte-identical after the failed rename" "$(cat "$R/CHANGELOG.md")"
no_staging && ok "and no staging file survives beside it" || bad "and no staging file survives beside it" "$STAGING"
[ -f "$R/changelog.d/fixed/ken-1.md" ] \
  && ok "the fragment is not deleted for a record that was never replaced" \
  || bad "the fragment is not deleted for a record that was never replaced" "deleted"

echo "=== nothing to fold is a no-op ==="
printf '%s' "$RECORD" | reset
run_collate
[ "$RC" -eq 0 ] && case "$OUT" in *"no fragments — nothing to collate"*) true ;; *) false ;; esac \
  && ok "an empty tree folds nothing and says so" || bad "an empty tree folds nothing and says so" "rc=$RC out=$OUT"
# That line is the whole report on a run with nothing else to say, so the
# record scope's note has to reach the operator through it too.
case "$OUT" in
  *"CHANGELOG.md unchanged under [Unreleased]"*) ok "and carries the record scope's note even with nothing to fold" ;;
  *) bad "and carries the record scope's note even with nothing to fold" "$OUT" ;;
esac
untouched && ok "the record is untouched with nothing to fold" || bad "the record is untouched with nothing to fold" "$(cat "$R/CHANGELOG.md")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
