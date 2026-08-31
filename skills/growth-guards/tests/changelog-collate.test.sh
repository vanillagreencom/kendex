#!/usr/bin/env bash
# Pins the WRITE path of scripts/changelog-entries --collate: it folds the
# fragments this run accepted into the record's [Unreleased] section, under
# the heading each fragment's own section names and in Keep a Changelog order,
# deletes them and the directories they emptied, and refuses without writing
# anything when the judgement refuses or when git and the working tree
# disagree. The refusing direction runs first in every pair, and each refusal
# is checked to have left the record and the fragments as they were — a fold
# that half-writes or half-deletes is the failure this guards.
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

frag() { # SECTION NAME — content on stdin, written and staged
  mkdir -p "$R/changelog.d/$1"
  cat >"$R/changelog.d/$1/$2"
  git -C "$R" add -A -- changelog.d
}

run_collate() { OUT=""; RC=0; OUT="$(cd "$R" && "$CE" --collate 2>&1)" || RC=$?; }
untouched() { cmp -s "$R/CHANGELOG.md" "$TMP/before"; }

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

echo "=== the fragments fold in under their own sections, in Keep a Changelog order ==="
printf '%s' "$RECORD" | reset
printf -- '- Folded in.\n' | frag fixed ken-1.md
printf -- '- Also folded in.\n' | frag added ken-2.md
# No trailing newline: two entries glued into one line is what normalizing it
# prevents, and only a fixture written this way can catch that.
printf -- '- Tightened.' | frag security ken-3.md
run_collate
[ "$RC" -eq 0 ] && case "$OUT" in *"folded 3 entries into CHANGELOG.md's [Unreleased] section"*) true ;; *) false ;; esac \
  && ok "the fold reports what it folded" || bad "the fold reports what it folded" "rc=$RC out=$OUT"
EXPECTED='# Changelog

## [Unreleased]

### Added

- An entry the record already carries.
- Also folded in.

### Fixed

- Folded in.

### Security

- Tightened.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
'
[ "$(cat "$R/CHANGELOG.md")" = "$(printf '%s' "$EXPECTED")" ] \
  && ok "the collated block is exactly the expected one" \
  || bad "the collated block is exactly the expected one" "$(diff <(printf '%s' "$EXPECTED") "$R/CHANGELOG.md" || true)"
LEFT="$(find "$R/changelog.d" -mindepth 1 | sort | tr '\n' ' ')"
[ -z "$LEFT" ] && ok "every fragment and the section directories they emptied are gone" \
  || bad "every fragment and the section directories they emptied are gone" "$LEFT"

echo "=== an unstaged edit stops the write ==="
printf '%s' "$RECORD" | reset
printf -- '- Folded in.\n' | frag fixed ken-1.md
printf -- '- Edited only on disk.\n' >"$R/changelog.d/fixed/ken-1.md"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"differs between git and the working tree"*"changelog.d/fixed/ken-1.md"*) true ;; *) false ;; esac \
  && ok "a fragment git and the disk disagree about refuses the fold" \
  || bad "a fragment git and the disk disagree about refuses the fold" "rc=$RC out=$OUT"
untouched && ok "the record is untouched by that refusal too" || bad "the record is untouched by that refusal too" "$(cat "$R/CHANGELOG.md")"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "and the fragment survives it too" || bad "and the fragment survives it too" "deleted"
STAGING=""
for f in "$R"/CHANGELOG.md.*; do
  [ ! -e "$f" ] || STAGING="$STAGING $f"
done
[ -z "$STAGING" ] && ok "no staging file is left beside the record" \
  || bad "no staging file is left beside the record" "$STAGING"

echo "=== nothing to fold is a no-op ==="
printf '%s' "$RECORD" | reset
run_collate
[ "$RC" -eq 0 ] && case "$OUT" in *"no fragments — nothing to collate"*) true ;; *) false ;; esac \
  && ok "an empty tree folds nothing and says so" || bad "an empty tree folds nothing and says so" "rc=$RC out=$OUT"
untouched && ok "the record is untouched with nothing to fold" || bad "the record is untouched with nothing to fold" "$(cat "$R/CHANGELOG.md")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
