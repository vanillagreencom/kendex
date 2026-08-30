#!/usr/bin/env bash
# Pins tools/changelog-collate: it folds in exactly the fragments the
# growth-guards changelog-entries lane names, under the section that lane
# gives each one, carries that lane's verdict out as its own, refuses a
# changelog.d or a CHANGELOG.md the index and the disk disagree about, emits
# each section in Keep a Changelog order and filename order within it,
# deletes every fragment, and leaves CHANGELOG.md whole when it refuses. The refusing direction runs first
# in every pair, and each refusal is checked to have left CHANGELOG.md and the
# fragments as they were — a collator that half-writes or half-deletes is the
# failure this replaces.
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

echo "=== a fragment the format refuses stops the run before any write ==="
reset
fragment fixed ken-1.md '- A placeable fragment.
'
printf -- '- Stray.\n' >"$R/changelog.d/loose.md"
git -C "$R" add -A
run_collate
# The judge owns the whole answer to "is this a fragment", so a stray in the
# fragment tree is its exit 1 here and at every commit, not a release-time
# surprise the collation raises on its own.
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/loose.md is in the fragment tree but is not a fragment"*) true ;; *) false ;; esac \
  && ok "a file outside a section directory is the judge's exit 1, naming it" \
  || bad "a file outside a section directory is the judge's exit 1, naming it" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by the refusal" \
  || bad "CHANGELOG.md is untouched by the refusal" "$(diff "$TMP/before" "$R/CHANGELOG.md" || true)"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "the placeable fragment is not deleted by the refusal" \
  || bad "the placeable fragment is not deleted by the refusal" "it is gone"

reset
fragment bogus ken-1.md '- Wrong section.
'
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/bogus/ken-1.md names no section"*) true ;; *) false ;; esac \
  && ok "an unknown section directory is the judge's refusal, carried out as exit 1" \
  || bad "an unknown section directory is the judge's refusal, carried out as exit 1" "rc=$RC out=$OUT"

# A directory whose name is a RUN of section names is not a section. Looked
# for inside the joined list it is found there, and the judge passes a
# fragment this collation then has no heading for — one judge saying yes and
# the release saying no.
reset
fragment 'added changed' ken-1.md '- Two sections in one directory name.
'
run_collate
# The path is rendered, so the space it carries reaches the reader escaped.
[ "$RC" -eq 1 ] && case "$OUT" in *'changelog.d/added\ changed/ken-1.md names no section'*) true ;; *) false ;; esac \
  && ok "a directory named after a run of sections names no section" \
  || bad "a directory named after a run of sections names no section" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that refusal" \
  || bad "CHANGELOG.md is untouched by that refusal" "it changed"
# The control: each half alone is a real section and collates.
reset
fragment added ken-1.md '- An added entry.
'
run_collate
[ "$RC" -eq 0 ] && ok "control: the same name's first half alone is a section" \
  || bad "control: the same name's first half alone is a section" "rc=$RC out=$OUT"

reset
fragment fixed ken-1.md '- A placeable fragment.
'
mkdir -p "$R/changelog.d/added"
printf 'whatever\n' >"$R/changelog.d/added/notes"
git -C "$R" add -A -- changelog.d
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/added/notes is in the fragment tree but is not a fragment"*) true ;; *) false ;; esac \
  && ok "a path in a section directory that the globs do not cover is refused, not folded in unjudged" \
  || bad "a path in a section directory that the globs do not cover is refused" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that refusal" \
  || bad "CHANGELOG.md is untouched by that refusal" "it changed"

reset
mkdir -p "$R/changelog.d/added"
ln -s ../../CHANGELOG.md "$R/changelog.d/added/notes"
git -C "$R" add -A -- changelog.d
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/added/notes is in the fragment tree but is not a fragment"*) true ;; *) false ;; esac \
  && ok "a symlink under a section directory is refused rather than published verbatim" \
  || bad "a symlink under a section directory is refused" "rc=$RC out=$OUT"
untouched && ok "the symlink target is untouched" \
  || bad "the symlink target is untouched" "it changed"
rm -f "$R/changelog.d/added/notes"

reset
fragment fixed/deeper ken-2.md '- Deeper.
'
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/deeper/ken-2.md names no section"*) true ;; *) false ;; esac \
  && ok "a fragment below a section directory exits 1, naming it" \
  || bad "a fragment below a section directory exits 1, naming it" "rc=$RC out=$OUT"

reset
fragment fixed ken-1.md '- A placeable fragment.
'
# `*` crosses `/`, so the glob reaches this and its parent names a real
# section. Folding it in and deleting it is the quiet failure a collation
# that folds exactly the judge's list would otherwise make.
mkdir -p "$R/changelog.d/archive/fixed"
printf -- '- Nested under a real section name.\n' >"$R/changelog.d/archive/fixed/ken-3.md"
git -C "$R" add -A -- changelog.d
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/archive/fixed/ken-3.md names no section"*) true ;; *) false ;; esac \
  && ok "a path two directories below the root stops the collation, naming it" \
  || bad "a path two directories below the root stops the collation" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that refusal" \
  || bad "CHANGELOG.md is untouched by that refusal" "it changed"
[ -f "$R/changelog.d/archive/fixed/ken-3.md" ] && ok "and the nested file is not deleted" \
  || bad "and the nested file is not deleted" "it is gone"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "nor is the fragment beside it" \
  || bad "nor is the fragment beside it" "it is gone"

echo "=== the pattern's own depth decides what the collation folds ==="
# The collation folds exactly what the judge places, so every pattern shape
# has to reach it: a narrowing pattern must still collate, and a path deeper
# than its pattern must still stop the run rather than being folded in and
# deleted.
run_collate_shape() { # PATTERN — sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && GROWTH_GUARDS_CHANGELOG_PATHS="$1" "$COLLATE" 2>&1)" || RC=$?
}
reset
fragment fixed ken-1.md '- An entry the release folds in.
'
run_collate_shape 'changelog.d/fixed/*.md'
[ "$RC" -eq 0 ] && ok "a pattern narrowed to one section collates" \
  || bad "a pattern narrowed to one section collates" "rc=$RC out=$OUT"
case "$(cat "$R/CHANGELOG.md")" in *"An entry the release folds in."*) ok "and its entry lands under Fixed" ;;
  *) bad "and its entry lands under Fixed" "$(cat "$R/CHANGELOG.md")" ;; esac
reset
fragment fixed ken-1.md '- A placeable fragment.
'
mkdir -p "$R/changelog.d/fixed/deeper"
printf -- '- Deeper still.\n' >"$R/changelog.d/fixed/deeper/z.md"
git -C "$R" add -A -- changelog.d
run_collate_shape 'changelog.d/fixed/*.md'
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/deeper/z.md names no section"*) true ;; *) false ;; esac \
  && ok "a path deeper than that pattern stops the collation" \
  || bad "a path deeper than that pattern stops the collation" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that refusal" \
  || bad "CHANGELOG.md is untouched by that refusal" "it changed"
[ -f "$R/changelog.d/fixed/deeper/z.md" ] && ok "and the deeper file is not deleted" \
  || bad "and the deeper file is not deleted" "it is gone"
# A glob in the middle places four-segment paths, and those collate.
reset
mkdir -p "$R/changelog.d/team/fixed"
printf -- '- Under a middle glob.\n' >"$R/changelog.d/team/fixed/w.md"
git -C "$R" add -A -- changelog.d
run_collate_shape 'changelog.d/*/fixed/*.md'
[ "$RC" -eq 0 ] && ok "a pattern with a glob in the middle collates what it places" \
  || bad "a pattern with a glob in the middle collates what it places" "rc=$RC out=$OUT"
case "$(cat "$R/CHANGELOG.md")" in *"Under a middle glob."*) ok "and that entry lands under Fixed too" ;;
  *) bad "and that entry lands under Fixed too" "$(cat "$R/CHANGELOG.md")" ;; esac

echo "=== a fragment is exactly one list item, or it is refused ==="
reset
fragment fixed empty.md ''
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/empty.md has no entry in it"*) true ;; *) false ;; esac \
  && ok "a zero-byte fragment exits 1, naming it" \
  || bad "a zero-byte fragment exits 1, naming it" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by the empty fragment" \
  || bad "CHANGELOG.md is untouched by the empty fragment" "it changed"
[ -f "$R/changelog.d/fixed/empty.md" ] && ok "the empty fragment is still on disk, not silently consumed" \
  || bad "the empty fragment is still on disk, not silently consumed" "it is gone"

reset
fragment fixed blank.md '

'
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/blank.md has no entry in it"*) true ;; *) false ;; esac \
  && ok "a whitespace-only fragment exits 1, naming it" \
  || bad "a whitespace-only fragment exits 1, naming it" "rc=$RC out=$OUT"
[ -f "$R/changelog.d/fixed/blank.md" ] && ok "the whitespace-only fragment survives the refusal" \
  || bad "the whitespace-only fragment survives the refusal" "it is gone"

reset
fragment fixed marker.md $'- \n' # a marker and nothing after it
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/marker.md has no entry in it"*) true ;; *) false ;; esac \
  && ok "a marker with nothing after it exits 1, naming it" \
  || bad "a marker with nothing after it exits 1, naming it" "rc=$RC out=$OUT"
untouched && ok "no empty list item is folded in" \
  || bad "no empty list item is folded in" "$(diff "$TMP/before" "$R/CHANGELOG.md" || true)"
[ -f "$R/changelog.d/fixed/marker.md" ] && ok "the marker-only fragment survives the refusal" \
  || bad "the marker-only fragment survives the refusal" "it is gone"

reset
fragment fixed two.md '- First entry.
- Second entry.
'
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/two.md holds more than the one entry"*) true ;; *) false ;; esac \
  && ok "two list items in one fragment exit 1, naming it" \
  || bad "two list items in one fragment exit 1, naming it" "rc=$RC out=$OUT"

reset
fragment fixed heading.md '- An entry.

## [9.9.9] - 2026-01-01
'
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/heading.md holds more than the one entry"*) true ;; *) false ;; esac \
  && ok "a heading inside a fragment exits 1 rather than ending the section it folds into" \
  || bad "a heading inside a fragment exits 1 rather than ending the section it folds into" "rc=$RC out=$OUT"

reset
fragment fixed prose.md 'Not a list item.
'
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/prose.md does not open with a list marker"*) true ;; *) false ;; esac \
  && ok "a fragment opening with prose exits 1, naming it" \
  || bad "a fragment opening with prose exits 1, naming it" "rc=$RC out=$OUT"

reset
mkdir -p "$R/changelog.d/fixed"
ln -s ../../CHANGELOG.md "$R/changelog.d/fixed/link.md"
git -C "$R" add -A
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/link.md is tracked as a symlink"*) true ;; *) false ;; esac \
  && ok "a symlinked fragment exits 1 rather than being followed or skipped" \
  || bad "a symlinked fragment exits 1 rather than being followed or skipped" "rc=$RC out=$OUT"
untouched && ok "the symlink target is untouched" \
  || bad "the symlink target is untouched" "it changed"
rm -f "$R/changelog.d/fixed/link.md"

reset
fragment fixed ok.md '- An entry
  continued over
  three lines.
'
run_collate
[ "$RC" -eq 0 ] && ok "an entry with indented continuation lines is taken" \
  || bad "an entry with indented continuation lines is taken" "rc=$RC out=$OUT"

echo "=== the judge is the one that refuses, and a judge that cannot run stops the run ==="
reset
fragment fixed ken-1.md '- A good entry.
'
mv "$R/.agents/skills/growth-guards/scripts/changelog-entries" "$TMP/judge.away"
run_collate
mv "$TMP/judge.away" "$R/.agents/skills/growth-guards/scripts/changelog-entries"
[ "$RC" -eq 2 ] && case "$OUT" in *"changelog-entries is missing or not executable"*) true ;; *) false ;; esac \
  && ok "a missing judge exits 2 rather than folding unjudged fragments in" \
  || bad "a missing judge exits 2 rather than folding unjudged fragments in" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched when the judge cannot run" \
  || bad "CHANGELOG.md is untouched when the judge cannot run" "it changed"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "the fragment survives a missing judge" \
  || bad "the fragment survives a missing judge" "it is gone"

reset
fragment fixed long.md "- $(head -c 260 /dev/zero | tr '\0' 'e')
"
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/long.md"*"characters (cap 200)"*) true ;; *) false ;; esac \
  && ok "the cap is the judge's, and the collation carries its exit 1" \
  || bad "the cap is the judge's, and the collation carries its exit 1" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by the over-cap refusal" \
  || bad "CHANGELOG.md is untouched by the over-cap refusal" "it changed"

run_collate --bogus
[ "$RC" -eq 2 ] && case "$OUT" in *usage*) true ;; *) false ;; esac \
  && ok "an unknown flag exits 2" \
  || bad "an unknown flag exits 2" "rc=$RC out=$OUT"

echo "=== the fragments are the ones git carries ==="
reset
fragment fixed ken-1.md '- A tracked entry.
'
printf 'binary junk\n' >"$R/changelog.d/.DS_Store"
printf -- '- An untracked entry.\n' >"$R/changelog.d/fixed/untracked.md"
run_collate
[ "$RC" -eq 0 ] && ok "an untracked stray under changelog.d does not stop the run" \
  || bad "an untracked stray under changelog.d does not stop the run" "rc=$RC out=$OUT"
case "$(cat "$R/CHANGELOG.md")" in *"An untracked entry"*) bad "the untracked fragment is not folded in" "it was" ;;
  *) ok "the untracked fragment is not folded in" ;; esac
[ -f "$R/changelog.d/fixed/untracked.md" ] && ok "the untracked fragment is not deleted" \
  || bad "the untracked fragment is not deleted" "it is gone"
rm -f "$R/changelog.d/.DS_Store" "$R/changelog.d/fixed/untracked.md"

echo "=== a fragment the index carries and the disk does not is a deletion ==="
# The release runs the collation and then stages: in between, the fragments
# are gone from the disk and still in the index, which is a changelog.d the
# index and the disk disagree about.
reset
fragment fixed ken-1.md '- An entry the release folds in.
'
git -C "$R" commit -q -m "chore: carry a fragment"
run_collate
[ "$RC" -eq 0 ] && ok "the collation folds the committed fragment in" \
  || bad "the collation folds the committed fragment in" "rc=$RC out=$OUT"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"changelog.d/fixed/ken-1.md is in the index but not a file on disk"*) true ;; *) false ;; esac \
  && ok "a second run over that state refuses instead of folding the deletion in again" \
  || bad "a second run over that state refuses instead of folding the deletion in again" "rc=$RC out=$OUT"
# The collated CHANGELOG.md goes into the index with the deletion, which is
# exactly the write the record scope refuses undeclared — so the release
# commit's declaration is what lets the state through.
git -C "$R" add -A
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"gained lines under [Unreleased]"*) true ;; *) false ;; esac \
  && ok "the staged collation is refused while nothing declares it" \
  || bad "the staged collation is refused while nothing declares it" "rc=$RC out=$OUT"
OUT=""
RC=0
OUT="$(cd "$R" && GROWTH_GUARDS_CHANGELOG_COLLATE=1 "$COLLATE" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "GROWTH_GUARDS_CHANGELOG_COLLATE=1 declares it, and there is nothing left to collate" \
  || bad "GROWTH_GUARDS_CHANGELOG_COLLATE=1 declares it, and there is nothing left to collate" "rc=$RC out=$OUT"

echo "=== the write refuses a changelog.d git and the disk disagree about ==="
# The run folds in the file on disk and then deletes it. An unstaged edit
# would be published and erased with nothing left carrying it.
reset
fragment fixed ken-1.md '- The wording git carries.
'
printf -- '- The unstaged rewrite.\n' >"$R/changelog.d/fixed/ken-1.md"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"differs between git and the working tree"*"changelog.d/fixed/ken-1.md"*) true ;; *) false ;; esac \
  && ok "an unstaged fragment edit exits 2, naming the path" \
  || bad "an unstaged fragment edit exits 2, naming the path" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by the dirty refusal" \
  || bad "CHANGELOG.md is untouched by the dirty refusal" "$(diff "$TMP/before" "$R/CHANGELOG.md" || true)"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "the unstaged fragment is not deleted" \
  || bad "the unstaged fragment is not deleted" "it is gone"
case "$(cat "$R/changelog.d/fixed/ken-1.md")" in *"unstaged rewrite"*) ok "the unstaged edit is still in the file" ;;
  *) bad "the unstaged edit is still in the file" "$(cat "$R/changelog.d/fixed/ken-1.md")" ;; esac
git -C "$R" add -A
run_collate
[ "$RC" -eq 0 ] && ok "staging the edit lets the write proceed" \
  || bad "staging the edit lets the write proceed" "rc=$RC out=$OUT"
case "$(cat "$R/CHANGELOG.md")" in *"unstaged rewrite"*) ok "the staged wording is the one folded in" ;;
  *) bad "the staged wording is the one folded in" "$(cat "$R/CHANGELOG.md")" ;; esac

echo "=== the staleness guard follows the configured paths, not a spelling of its own ==="
# The paths guarded are the ones the judge just named, so a repo that repoints
# the fragment globs is guarded over the tree it actually uses.
reset
mkdir -p "$R/notes.d/fixed"
printf -- '- An entry the release folds in.\n' >"$R/notes.d/fixed/ken-1.md"
git -C "$R" add -A -- notes.d
run_collate_paths() { # sets OUT and RC, with the fragments elsewhere
  OUT=""
  RC=0
  OUT="$(cd "$R" && GROWTH_GUARDS_CHANGELOG_PATHS='notes.d/*/*.md' "$COLLATE" 2>&1)" || RC=$?
}
printf -- '- The unstaged rewrite nothing judged.\n' >"$R/notes.d/fixed/ken-1.md"
run_collate_paths
[ "$RC" -eq 2 ] && case "$OUT" in *"differs between git and the working tree"*"notes.d/fixed/ken-1.md"*) true ;; *) false ;; esac \
  && ok "an unstaged edit under the configured tree exits 2, naming it" \
  || bad "an unstaged edit under the configured tree exits 2, naming it" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that refusal" \
  || bad "CHANGELOG.md is untouched by that refusal" "it changed"
# The control: staged, the same tree collates, so the refusal above is the
# guard reaching notes.d and not the run failing for another reason.
git -C "$R" add -A -- notes.d
run_collate_paths
[ "$RC" -eq 0 ] && ok "control: staged, the same tree collates" \
  || bad "control: staged, the same tree collates" "rc=$RC out=$OUT"
case "$(cat "$R/CHANGELOG.md")" in *"The unstaged rewrite nothing judged."*) ok "and its entry is folded in" ;;
  *) bad "and its entry is folded in" "$(cat "$R/CHANGELOG.md")" ;; esac

echo "=== a changelog the collator cannot read stops the run ==="
reset
fragment fixed ken-1.md '- A fragment.
'
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n- Released.\n' | record_is
run_collate
# The judge's refusal now, carried out as exit 1: the record's shape is one
# rule, judged where every other rule about the record is.
[ "$RC" -eq 1 ] && case "$OUT" in *"carries no '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "a CHANGELOG with no [Unreleased] is the judge's refusal" \
  || bad "a CHANGELOG with no [Unreleased] is the judge's refusal" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that refusal" \
  || bad "CHANGELOG.md is untouched by that refusal" "it changed"
no_leftover && ok "no replacement file is left behind" \
  || bad "no replacement file is left behind" "$(ls "$R")"

# A SECOND canonical heading is the same question from the other side: this
# mode emits both, and a collator keeping whichever it read last would publish
# the fragments under the wrong one and then delete the files they came from.
reset
fragment fixed ken-1.md '- A fragment.
'
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- Released.\n\n## [Unreleased]\n' | record_is
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"more than one '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "a second [Unreleased] heading exits 2" \
  || bad "a second [Unreleased] heading exits 2" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that refusal" \
  || bad "CHANGELOG.md is untouched by that refusal" "it changed"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "and the fragment it would have misplaced is still there" \
  || bad "and the fragment it would have misplaced is still there" "$(ls -R "$R/changelog.d")"
# The control: the same document with one heading collates, so the refusal is
# the duplicate and not this shape failing outright.
reset
fragment fixed ken-1.md '- A fragment.
'
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- Released.\n' | record_is
run_collate
[ "$RC" -eq 0 ] && ok "control: the same document with one heading collates" \
  || bad "control: the same document with one heading collates" "rc=$RC out=$OUT"

# A heading that merely BEGINS with the canonical text is a different heading,
# and this is the refusal that matters most: the collator folds fragments into
# the bounds it is handed and then deletes the fragment files, so a prefix
# match would consume entries into a section nobody meant and leave no copy.
reset
fragment fixed ken-1.md '- A fragment.
'
printf '# Changelog\n\n## [Unreleased] archive\n\n- Released.\n' | record_is
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"carries no '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "a heading that only begins with [Unreleased] is refused too" \
  || bad "a heading that only begins with [Unreleased] is refused too" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that refusal" \
  || bad "CHANGELOG.md is untouched by that refusal" "it changed"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "and the fragment it would have consumed is still there" \
  || bad "and the fragment it would have consumed is still there" "$(ls -R "$R/changelog.d")"

reset
fragment fixed ken-1.md '- A fragment.
'
printf '# Changelog\n\n## [Unreleased]\n\n### Notes\n\n- Not a section.\n' | record_is
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"names 'Notes' under [Unreleased]"*) true ;; *) false ;; esac \
  && ok "an unsupported section heading is the judge's refusal, naming it" \
  || bad "an unsupported section heading is the judge's refusal, naming it" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that refusal too" \
  || bad "CHANGELOG.md is untouched by that refusal too" "it changed"

# git says nothing about a file it does not track, so a diff-based guard
# cannot see an untracked record at all.
reset
fragment fixed ken-1.md '- A fragment.
'
# Committed away, not merely unstaged: the judge refuses a record HEAD still
# carries and the index does not, which is a deletion rather than the absence
# this case is about.
git -C "$R" rm -q CHANGELOG.md
git -C "$R" commit -q -m "chore: retire the record"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"CHANGELOG.md is not tracked"*) true ;; *) false ;; esac \
  && ok "a record git does not track is refused, naming it" \
  || bad "a record git does not track is refused, naming it" "rc=$RC out=$OUT"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "the fragment survives that refusal" \
  || bad "the fragment survives that refusal" "it is gone"
printf '# Changelog\n\n## [Unreleased]\n' >"$R/CHANGELOG.md"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"CHANGELOG.md is not tracked"*) true ;; *) false ;; esac \
  && ok "an untracked record on disk is refused too, not rewritten unmeasured" \
  || bad "an untracked record on disk is refused too" "rc=$RC out=$OUT"
case "$(cat "$R/CHANGELOG.md")" in *"A fragment."*) bad "and it is left as it was" "$(cat "$R/CHANGELOG.md")" ;;
  *) ok "and it is left as it was" ;; esac
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "and the fragment is not deleted" \
  || bad "and the fragment is not deleted" "it is gone"
# Staged for the first time is enough: the guard can see it from there.
git -C "$R" add -A
run_collate
[ "$RC" -eq 0 ] && ok "a record staged for the first time collates" \
  || bad "a record staged for the first time collates" "rc=$RC out=$OUT"
case "$(cat "$R/CHANGELOG.md")" in *"A fragment."*) ok "and its entry lands in it" ;;
  *) bad "and its entry lands in it" "$(cat "$R/CHANGELOG.md")" ;; esac

echo "=== a failure past the replacement file leaves nothing half-written ==="
reset
fragment fixed ken-1.md '- A fragment.
'
stub_failing mv
run_collate_stubbed
unstub
[ "$RC" -eq 2 ] && case "$OUT" in *"could not replace CHANGELOG.md"*) true ;; *) false ;; esac \
  && ok "a failing rename exits 2, naming the step" \
  || bad "a failing rename exits 2, naming the step" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is byte-identical after the failing rename" \
  || bad "CHANGELOG.md is byte-identical after the failing rename" "$(diff "$TMP/before" "$R/CHANGELOG.md" || true)"
no_leftover && ok "the replacement file is cleaned up after the failing rename" \
  || bad "the replacement file is cleaned up after the failing rename" "$(ls "$R")"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "the fragment survives the failing rename" \
  || bad "the fragment survives the failing rename" "it is gone"

reset
fragment fixed ken-1.md '- A fragment.
'
stub_failing cp
run_collate_stubbed
unstub
[ "$RC" -eq 2 ] && case "$OUT" in *"could not take CHANGELOG.md's mode"*) true ;; *) false ;; esac \
  && ok "a failing mode copy exits 2, naming the step" \
  || bad "a failing mode copy exits 2, naming the step" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is byte-identical after the failing mode copy" \
  || bad "CHANGELOG.md is byte-identical after the failing mode copy" "it changed"
no_leftover && ok "the replacement file is cleaned up after the failing mode copy" \
  || bad "the replacement file is cleaned up after the failing mode copy" "$(ls "$R")"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "the fragment survives the failing mode copy" \
  || bad "the fragment survives the failing mode copy" "it is gone"

echo "=== a fragment that cannot be deleted is named, and none is left unvisited ==="
if [ "$(id -u)" -ne 0 ]; then
  reset
  fragment fixed a.md '- Undeletable one.
'
  fragment fixed b.md '- Undeletable two.
'
  chmod a-w "$R/changelog.d/fixed"
  run_collate
  chmod u+w "$R/changelog.d/fixed"
  [ "$RC" -eq 2 ] && case "$OUT" in *"changelog.d/fixed/a.md"*"changelog.d/fixed/b.md"*) true ;; *) false ;; esac \
    && ok "the refusal names every fragment that survived, not the first" \
    || bad "the refusal names every fragment that survived, not the first" "rc=$RC out=$OUT"
  case "$(grep -c 'Undeletable one' "$R/CHANGELOG.md")" in 1) ok "the collation itself completed once" ;;
    *) bad "the collation itself completed once" "$(grep -n Undeletable "$R/CHANGELOG.md")" ;; esac
  rm -f "$R/changelog.d/fixed/a.md" "$R/changelog.d/fixed/b.md"
fi

echo "=== fragments fold into their sections and are deleted ==="
# Keep a Changelog's six sections and their headings are spelled out here
# rather than read from the collator's own map: a list derived from the
# subject cannot catch that map being narrowed or a heading being mistyped.
reset
fragment fixed ken-2.md '- Second by filename.
'
fragment fixed ken-1.md '- First by filename
  with a continuation.
'
fragment added ken-3.md '- An added fragment.
'
fragment changed ken-4.md '- A changed fragment.
'
fragment deprecated ken-5.md '- A deprecated fragment.
'
fragment removed ken-6.md '- A removed fragment.
'
fragment security ken-7.md '- A security fragment.' # no trailing newline
printf '# changelog.d\n' >"$R/changelog.d/README.md"
git -C "$R" add -A
chmod 640 "$R/CHANGELOG.md"
run_collate
[ "$RC" -eq 0 ] && case "$OUT" in *"folded 7 entries"*) true ;; *) false ;; esac \
  && ok "the run reports the count it folded" \
  || bad "the run reports the count it folded" "rc=$RC out=$OUT"
cat >"$TMP/expected" <<'EOF'
# Changelog

Preamble.

## [Unreleased]

### Added

- An entry the file already carries.
- An added fragment.

### Changed

- A changed fragment.

### Deprecated

- A deprecated fragment.

### Removed

- A removed fragment.

### Fixed

- A two-line entry
  with a continuation.
- First by filename
  with a continuation.
- Second by filename.

### Security

- A security fragment.

## [1.0.0] - 2026-01-01

### Added

- A released entry.
EOF
if diff -u "$TMP/expected" "$R/CHANGELOG.md" >"$TMP/diff" 2>&1; then
  ok "every section folds under its own heading, in Keep a Changelog order"
else
  bad "every section folds under its own heading, in Keep a Changelog order" "$(cat "$TMP/diff")"
fi
[ "$(filemode "$R/CHANGELOG.md")" = 640 ] && ok "the collated file keeps the mode it replaced" \
  || bad "the collated file keeps the mode it replaced" "mode is $(filemode "$R/CHANGELOG.md"), not 640"
chmod 644 "$R/CHANGELOG.md"
leftover=""
for s in added changed deprecated removed fixed security; do
  if [ -d "$R/changelog.d/$s" ]; then leftover="$leftover $s"; fi
done
[ -z "$leftover" ] && ok "the emptied section directories are removed" \
  || bad "the emptied section directories are removed" "still on disk:$leftover"
[ -f "$R/changelog.d/README.md" ] && ok "the README survives the collation" \
  || bad "the README survives the collation" "it is gone"

echo "=== a fragment whose name carries a newline is folded in and deleted ==="
# A newline in a name is a legal byte; read back a line at a time it becomes
# two paths, neither of which exists.
reset
NL_NAME="$(printf 'KEN\n1.md')"
mkdir -p "$R/changelog.d/fixed"
printf -- '- An entry under a name with a newline in it.\n' >"$R/changelog.d/fixed/$NL_NAME"
git -C "$R" add -A -- changelog.d
run_collate
[ "$RC" -eq 0 ] && ok "the collation takes it" || bad "the collation takes it" "rc=$RC out=$OUT"
case "$(cat "$R/CHANGELOG.md")" in *"An entry under a name with a newline in it."*) ok "its entry is folded in" ;;
  *) bad "its entry is folded in" "$(cat "$R/CHANGELOG.md")" ;; esac
[ -e "$R/changelog.d/fixed/$NL_NAME" ] && bad "and the fragment is deleted" "it survived" \
  || ok "and the fragment is deleted"

echo "=== two headings for one section collapse into one, in section order ==="
reset
record_is <<'EOF'
# Changelog

## [Unreleased]

### Fixed

- First block.

### Added

- An added entry.

### Fixed

- Second block.
EOF
fragment fixed ken-1.md '- A fragment.
'
run_collate
cat >"$TMP/expected" <<'EOF'
# Changelog

## [Unreleased]

### Added

- An added entry.

### Fixed

- First block.
- Second block.
- A fragment.
EOF
if diff -u "$TMP/expected" "$R/CHANGELOG.md" >"$TMP/diff" 2>&1; then
  ok "both blocks and the fragment land under one heading, in section order"
else
  bad "both blocks and the fragment land under one heading, in section order" "$(cat "$TMP/diff")"
fi

echo "=== nothing to fold is a no-op ==="
reset
run_collate
[ "$RC" -eq 0 ] && case "$OUT" in *"no fragments"*) true ;; *) false ;; esac \
  && ok "no changelog.d directory is a clean no-op" \
  || bad "no changelog.d directory is a clean no-op" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by the no-op" \
  || bad "CHANGELOG.md is untouched by the no-op" "it changed"
mkdir -p "$R/changelog.d"
printf '# changelog.d\n' >"$R/changelog.d/README.md"
git -C "$R" add -A
run_collate
[ "$RC" -eq 0 ] && case "$OUT" in *"no fragments"*) true ;; *) false ;; esac \
  && ok "a changelog.d holding only the README is a clean no-op" \
  || bad "a changelog.d holding only the README is a clean no-op" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that no-op" \
  || bad "CHANGELOG.md is untouched by that no-op" "it changed"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
