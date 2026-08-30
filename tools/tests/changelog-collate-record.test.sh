#!/usr/bin/env bash
# Pins the RECORD side of tools/changelog-collate: the file it splits, guards
# and rewrites is the one the judge names, its `## [Unreleased]` section is
# located by the shared grammar rather than searched for again, git has to
# carry it before it is written, and an edit only the disk can see stops the
# run. The fragment side is pinned next door in changelog-collate.test.sh.
# The refusing direction runs first in every pair, and each refusal is checked
# to have left the record and the fragments as they were.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLATE="$(cd "$TEST_DIR/.." && pwd)/changelog-collate"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R/.agents/skills/growth-guards"
# The collator calls the judge at the path a clone carries it.
cp -R "$REPO/.agents/skills/growth-guards/scripts" "$R/.agents/skills/growth-guards/scripts"
git -C "$R" init -q
git -C "$R" symbolic-ref HEAD refs/heads/main
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test

reset() { # a fixture CHANGELOG and an empty changelog.d, both in the index
  rm -rf "${R:?}/changelog.d"
  cat >"$R/CHANGELOG.md" <<'EOF'
# Changelog

Preamble.

## [Unreleased]

### Added

- An entry the file already carries.

### Fixed

- A two-line entry
  with a continuation.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
EOF
  git -C "$R" add -A
  # Committed, not merely staged: the judge compares the record's staged copy
  # against HEAD, so a fixture that only stages one reads as a hand edit.
  git -C "$R" commit -q --allow-empty -m "chore: reset the fixture"
  cp "$R/CHANGELOG.md" "$TMP/before"
}

fragment() { # SECTION NAME CONTENT — written and staged, the way a commit carries it
  mkdir -p "$R/changelog.d/$1"
  printf '%s' "$3" >"$R/changelog.d/$1/$2"
  # changelog.d alone: a case that edits CHANGELOG.md on disk means the
  # collator to read it, not the judge's record scope to see a staged hand
  # edit — which is its own refusal, pinned below.
  git -C "$R" add -A -- changelog.d
}

record_is() { # CONTENT on stdin — index, HEAD and the work tree all agree
  cat >"$R/CHANGELOG.md"
  git -C "$R" add -A
  git -C "$R" commit -q -m "chore: set the changelog"
  cp "$R/CHANGELOG.md" "$TMP/before"
}

run_collate() { # [ARG...] — sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$COLLATE" "$@" 2>&1)" || RC=$?
}

untouched() { cmp -s "$R/CHANGELOG.md" "$TMP/before"; }

filemode() { # FILE — its permission bits, GNU stat or BSD stat
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

no_leftover() { # no replacement file survives at the repo root
  local f
  for f in "$R"/CHANGELOG.md.*; do
    [ -e "$f" ] && return 1
  done
  return 0
}

# A stub ahead of PATH is how a failure is reached in the window where the
# replacement file already exists: nothing else in the collator runs mv or cp.
STUB="$TMP/stub"
mkdir -p "$STUB"
stub_failing() { # COMMAND
  printf '#!/bin/sh\necho "%s: refused by the test stub" >&2\nexit 1\n' "$1" >"$STUB/$1"
  chmod +x "$STUB/$1"
}
unstub() { rm -f "$STUB"/*; }

run_collate_stubbed() { # sets OUT and RC, with STUB ahead of PATH
  OUT=""
  RC=0
  OUT="$(cd "$R" && PATH="$STUB:$PATH" "$COLLATE" 2>&1)" || RC=$?
}

echo "=== the record the judge names is the one split, guarded and rewritten ==="
# The judge validates one record; a collation that rewrote another would
# publish a file nothing measured.
reset
mkdir -p "$R/docs"
printf '# Release Notes\n\n## [Unreleased]\n\n### Added\n\n- An entry it already carries.\n' >"$R/docs/Release Notes.md"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: carry a record of its own"
cp "$R/CHANGELOG.md" "$TMP/before"
fragment added ken-1.md '- An entry for the other record.
'
run_collate_record() { # sets OUT and RC, with the record elsewhere
  OUT=""
  RC=0
  OUT="$(cd "$R" && GROWTH_GUARDS_CHANGELOG_RECORD='docs/Release Notes.md' "$COLLATE" 2>&1)" || RC=$?
}
# Every path in a message is rendered, so the assertions read it that way.
SHOWN_RECORD="$(printf '%q' 'docs/Release Notes.md')"
run_collate_record
[ "$RC" -eq 0 ] && case "$OUT" in *"$SHOWN_RECORD's [Unreleased] section"*) true ;; *) false ;; esac \
  && ok "the configured record is what the run reports folding into" \
  || bad "the configured record is what the run reports folding into" "rc=$RC out=$OUT"
case "$(cat "$R/docs/Release Notes.md")" in *"An entry for the other record."*) ok "and the entry lands in it" ;;
  *) bad "and the entry lands in it" "$(cat "$R/docs/Release Notes.md")" ;; esac
untouched && ok "CHANGELOG.md, which the judge did not name, is untouched" \
  || bad "CHANGELOG.md, which the judge did not name, is untouched" "$(diff "$TMP/before" "$R/CHANGELOG.md" || true)"
[ -f "$R/changelog.d/added/ken-1.md" ] && bad "the fragment is deleted" "it survived" \
  || ok "the fragment is deleted"
# The guard follows it too.
git -C "$R" add -A
git -C "$R" commit -q -m "chore: collated"
fragment fixed ken-2.md '- A second entry.
'
printf '\n- A hand-written line nothing judged.\n' >>"$R/docs/Release Notes.md"
run_collate_record
[ "$RC" -eq 2 ] && case "$OUT" in *"differs between git and the working tree"*"$SHOWN_RECORD"*) true ;; *) false ;; esac \
  && ok "an unstaged edit to the configured record exits 2, naming it" \
  || bad "an unstaged edit to the configured record exits 2, naming it" "rc=$RC out=$OUT"
# With that scope off there is nowhere to fold into: a refusal, not a write
# to some other file.
OUT=""
RC=0
OUT="$(cd "$R" && GROWTH_GUARDS_CHANGELOG_RECORD= "$COLLATE" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"record scope is off"*) true ;; *) false ;; esac \
  && ok "no configured record is a refusal, not a write to CHANGELOG.md" \
  || bad "no configured record is a refusal" "rc=$RC out=$OUT"

echo "=== a fenced example of the heading is not the heading ==="
# A search of its own for `## [Unreleased]` puts the fragments under the
# example instead of the heading below it.
reset
cat >"$R/CHANGELOG.md" <<'EOF'
# Changelog

Write entries as fragments, never here:

```
## [Unreleased]

- Not a real entry.
```

## [Unreleased]

### Added

- An entry the file already carries.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
EOF
git -C "$R" add -A
git -C "$R" commit -q -m "chore: a record whose example names the heading"
cp "$R/CHANGELOG.md" "$TMP/before"
fragment added ken-1.md '- An entry the release folds in.
'
run_collate
[ "$RC" -eq 0 ] && ok "the collation takes it" || bad "the collation takes it" "rc=$RC out=$OUT"
cat >"$TMP/expected" <<'EOF'
# Changelog

Write entries as fragments, never here:

```
## [Unreleased]

- Not a real entry.
```

## [Unreleased]

### Added

- An entry the file already carries.
- An entry the release folds in.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
EOF
if diff -u "$TMP/expected" "$R/CHANGELOG.md" >"$TMP/diff" 2>&1; then
  ok "the entry lands under the real heading and the example keeps its own lines"
else
  bad "the entry lands under the real heading and the example keeps its own lines" "$(cat "$TMP/diff")"
fi

echo "=== an unstaged record edit stops the write, the way an unstaged fragment does ==="
# An edit only one of the index and the disk can see must stop the run, or a
# line nothing judged is folded into the released record.
reset
fragment fixed ken-1.md '- A fragment.
'
git -C "$R" commit -q -m "chore: carry the record"
cp "$R/CHANGELOG.md" "$TMP/before"
perl -0pi -e 's/^- An entry the file already carries\.$/- An entry the file already carries.\n- A hand-written line nothing judged./m' "$R/CHANGELOG.md"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"differs between git and the working tree"*"CHANGELOG.md"*) true ;; *) false ;; esac \
  && ok "an unstaged edit to the record exits 2, naming it" \
  || bad "an unstaged edit to the record exits 2, naming it" "rc=$RC out=$OUT"
case "$(cat "$R/CHANGELOG.md")" in *"A hand-written line nothing judged"*) ok "the unstaged edit is still in the file, unpublished" ;;
  *) bad "the unstaged edit is still in the file" "$(cat "$R/CHANGELOG.md")" ;; esac
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "the fragment is not deleted by that refusal" \
  || bad "the fragment is not deleted by that refusal" "it is gone"
# The control: staged, the same edit reaches the judge, which refuses it.
git -C "$R" add -A
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"gained lines under [Unreleased]"*) true ;; *) false ;; esac \
  && ok "control: staged, the same edit is the judge's refusal" \
  || bad "control: staged, the same edit is the judge's refusal" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD

echo "=== a declared collation still refuses a record that is not a file ==="
# GROWTH_GUARDS_CHANGELOG_COLLATE=1 is exported exactly while this runs, so a
# check it disarmed would be off at the moment the record is rewritten: the
# mv below would replace the symlink with a regular file, having read whatever
# it pointed at.
reset
fragment fixed ken-1.md '- A fragment.
'
printf '# Elsewhere\n\n## [Unreleased]\n\n- A line.\n' >"$R/elsewhere.md"
rm -f "$R/CHANGELOG.md"
ln -s elsewhere.md "$R/CHANGELOG.md"
git -C "$R" add -A
OUT=""
RC=0
OUT="$(cd "$R" && GROWTH_GUARDS_CHANGELOG_COLLATE=1 "$COLLATE" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"tracked as a symlink or gitlink"*) true ;; *) false ;; esac \
  && ok "a staged record symlink is refused even under the declaration" \
  || bad "a staged record symlink is refused even under the declaration" "rc=$RC out=$OUT"
[ -L "$R/CHANGELOG.md" ] && ok "and the record is still the symlink it was" \
  || bad "and the record is still the symlink it was" "it was replaced"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "and the fragment is not deleted" \
  || bad "and the fragment is not deleted" "it is gone"
git -C "$R" reset -q --hard HEAD
rm -f "$R/CHANGELOG.md" "$R/elsewhere.md"
git -C "$R" checkout -q -- CHANGELOG.md 2>/dev/null || true

echo "=== no path reaches a message as raw bytes ==="
# A name is somebody else's bytes: a newline in one forges a line in the very
# diagnostic that reports it, and an ESC reaches the terminal that prints it.
reset
NASTY="$(printf 'KEN\n1\033X.md')"
mkdir -p "$R/changelog.d/fixed"
printf -- '- An entry under a hostile name.\n' >"$R/changelog.d/fixed/$NASTY"
git -C "$R" add -A -- changelog.d
printf -- '- The unstaged rewrite.\n' >"$R/changelog.d/fixed/$NASTY"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"differs between git and the working tree"*) true ;; *) false ;; esac \
  && ok "the unstaged edit under that name is refused" \
  || bad "the unstaged edit under that name is refused" "rc=$RC out=$OUT"
printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '[\001-\010\013-\037\177]')" \
  && bad "no control byte from the name may reach the output" "$OUT" \
  || ok "no control byte from the name reaches the output"
# Three lines: the judge's verdict, the refusal, and the one path under it. A
# raw newline in the name would make four, and the reader of the first would
# never see the rest.
[ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 3 ] \
  && ok "the refusal names its one path on one line" \
  || bad "the refusal names its one path on one line" "lines=$(printf '%s\n' "$OUT" | grep -c .) out=$OUT"
# And the same on the success note, which carries the record's own name.
git -C "$R" add -A
run_collate
[ "$RC" -eq 0 ] && ok "control: staged, the same tree collates" \
  || bad "control: staged, the same tree collates" "rc=$RC out=$OUT"
printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '[\001-\010\013-\037\177]')" \
  && bad "no control byte reaches the success note either" "$OUT" \
  || ok "no control byte reaches the success note either"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
