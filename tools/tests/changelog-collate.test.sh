#!/usr/bin/env bash
# Pins tools/changelog-collate: it judges the fragments git carries before it
# writes anything, folds them under their own section in Keep a Changelog
# order and filename order, deletes every one of them, and leaves CHANGELOG.md
# whole when it refuses. The refusing direction runs first in every pair, and
# each refusal is checked to have left CHANGELOG.md and the fragments as they
# were — a collator that half-writes or half-deletes is the failure this
# replaces. --check runs the same judgment and writes nothing.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLATE="$(cd "$TEST_DIR/.." && pwd)/changelog-collate"
TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R"
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
  cp "$R/CHANGELOG.md" "$TMP/before"
}

fragment() { # SECTION NAME CONTENT — written and staged, the way a commit carries it
  mkdir -p "$R/changelog.d/$1"
  printf '%s' "$3" >"$R/changelog.d/$1/$2"
  git -C "$R" add -A
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
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/loose.md is not a changelog fragment"*) true ;; *) false ;; esac \
  && ok "a file outside a section directory exits 1, naming it" \
  || bad "a file outside a section directory exits 1, naming it" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by the refusal" \
  || bad "CHANGELOG.md is untouched by the refusal" "$(diff "$TMP/before" "$R/CHANGELOG.md" || true)"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "the placeable fragment is not deleted by the refusal" \
  || bad "the placeable fragment is not deleted by the refusal" "it is gone"

reset
fragment bogus ken-1.md '- Wrong section.
'
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/bogus/ken-1.md names no known section"*) true ;; *) false ;; esac \
  && ok "an unknown section directory exits 1, naming it" \
  || bad "an unknown section directory exits 1, naming it" "rc=$RC out=$OUT"

reset
fragment fixed/deeper ken-2.md '- Deeper.
'
run_collate
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/deeper/ken-2.md sits below a section directory"*) true ;; *) false ;; esac \
  && ok "a fragment below a section directory exits 1, naming it" \
  || bad "a fragment below a section directory exits 1, naming it" "rc=$RC out=$OUT"

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
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/link.md is a symlink"*) true ;; *) false ;; esac \
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

echo "=== --check judges the same fragments and writes nothing ==="
reset
fragment fixed two.md '- First entry.
- Second entry.
'
run_collate --check
[ "$RC" -eq 1 ] && case "$OUT" in *"changelog.d/fixed/two.md holds more than the one entry"*) true ;; *) false ;; esac \
  && ok "--check exits 1 on a fragment the format refuses" \
  || bad "--check exits 1 on a fragment the format refuses" "rc=$RC out=$OUT"
reset
fragment fixed ken-1.md '- A good entry.
'
run_collate --check
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "--check is silent and exits 0 on a good fragment" \
  || bad "--check is silent and exits 0 on a good fragment" "rc=$RC out=$OUT"
untouched && ok "--check writes no CHANGELOG.md" \
  || bad "--check writes no CHANGELOG.md" "it changed"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "--check deletes no fragment" \
  || bad "--check deletes no fragment" "it is gone"
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

echo "=== a changelog the collator cannot read stops the run ==="
reset
fragment fixed ken-1.md '- A fragment.
'
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n- Released.\n' >"$R/CHANGELOG.md"
cp "$R/CHANGELOG.md" "$TMP/before"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"no '## [Unreleased]' heading"*) true ;; *) false ;; esac \
  && ok "a CHANGELOG with no [Unreleased] exits 2" \
  || bad "a CHANGELOG with no [Unreleased] exits 2" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that refusal" \
  || bad "CHANGELOG.md is untouched by that refusal" "it changed"
no_leftover && ok "no replacement file is left behind" \
  || bad "no replacement file is left behind" "$(ls "$R")"

reset
fragment fixed ken-1.md '- A fragment.
'
printf '# Changelog\n\n## [Unreleased]\n\n### Notes\n\n- Not a section.\n' >"$R/CHANGELOG.md"
cp "$R/CHANGELOG.md" "$TMP/before"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"names 'Notes' under [Unreleased]"*) true ;; *) false ;; esac \
  && ok "a heading that is no Keep a Changelog section exits 2, naming it" \
  || bad "a heading that is no Keep a Changelog section exits 2, naming it" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that refusal too" \
  || bad "CHANGELOG.md is untouched by that refusal too" "it changed"

reset
fragment fixed ken-1.md '- A fragment.
'
rm -f "$R/CHANGELOG.md"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"CHANGELOG.md is missing"*) true ;; *) false ;; esac \
  && ok "a missing CHANGELOG names the file, not an unreadable one" \
  || bad "a missing CHANGELOG names the file, not an unreadable one" "rc=$RC out=$OUT"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "the fragment survives a missing CHANGELOG" \
  || bad "the fragment survives a missing CHANGELOG" "it is gone"

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

echo "=== two headings for one section collapse into one, in section order ==="
reset
cat >"$R/CHANGELOG.md" <<'EOF'
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
