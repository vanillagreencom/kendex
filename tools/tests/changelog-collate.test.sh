#!/usr/bin/env bash
# Pins tools/changelog-collate: fragments land under their own section in
# Keep a Changelog order and filename order, a section the file does not
# carry is opened in that order, the fragments are deleted, and a run with
# nothing to fold changes nothing. The refusing direction runs first in every
# pair, and each refusal is checked to have left CHANGELOG.md untouched —
# a collator that half-writes the file is the failure this replaces.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLATE="$(cd "$TEST_DIR/.." && pwd)/changelog-collate"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R"
git -C "$R" init -q
git -C "$R" symbolic-ref HEAD refs/heads/main

changelog() { # writes the fixture CHANGELOG.md
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
}

fragment() { # SECTION NAME CONTENT
  mkdir -p "$R/changelog.d/$1"
  printf '%s' "$3" >"$R/changelog.d/$1/$2"
}

run_collate() { # sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$COLLATE" 2>&1)" || RC=$?
}

reset() {
  rm -rf "${R:?}/changelog.d"
  changelog
  cp "$R/CHANGELOG.md" "$TMP/before"
}

untouched() { cmp -s "$R/CHANGELOG.md" "$TMP/before"; }

echo "=== a file the collator cannot place stops the run, changing nothing ==="
reset
fragment fixed ken-1.md '- A placeable fragment.
'
printf -- '- Stray.\n' >"$R/changelog.d/loose.md"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"changelog.d/loose.md is not a changelog fragment"*) true ;; *) false ;; esac \
  && ok "a file outside a section directory exits 2, naming it" \
  || bad "a file outside a section directory exits 2, naming it" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by the refusal" \
  || bad "CHANGELOG.md is untouched by the refusal" "$(diff "$TMP/before" "$R/CHANGELOG.md" || true)"
[ -f "$R/changelog.d/fixed/ken-1.md" ] && ok "the placeable fragment is not deleted by the refusal" \
  || bad "the placeable fragment is not deleted by the refusal" "it is gone"

reset
fragment bogus ken-1.md '- Wrong section.
'
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"changelog.d/bogus/ken-1.md names no known section"*) true ;; *) false ;; esac \
  && ok "an unknown section directory exits 2, naming it" \
  || bad "an unknown section directory exits 2, naming it" "rc=$RC out=$OUT"

reset
fragment fixed ken-1.md '- Deep.
'
mkdir -p "$R/changelog.d/fixed/deeper"
printf -- '- Deeper.\n' >"$R/changelog.d/fixed/deeper/ken-2.md"
run_collate
[ "$RC" -eq 2 ] && case "$OUT" in *"changelog.d/fixed/deeper/ken-2.md sits below a section directory"*) true ;; *) false ;; esac \
  && ok "a fragment below a section directory exits 2, naming it" \
  || bad "a fragment below a section directory exits 2, naming it" "rc=$RC out=$OUT"

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
case "$(ls "$R")" in *CHANGELOG.md.*) bad "no replacement file is left behind" "$(ls "$R")" ;;
  *) ok "no replacement file is left behind" ;; esac

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

echo "=== fragments fold into their sections and are deleted ==="
reset
fragment fixed ken-2.md '- Second by filename.
'
fragment fixed ken-1.md '- First by filename
  with a continuation.
'
fragment added ken-3.md '- An added fragment.
'
fragment security ken-4.md '- A security fragment.' # no trailing newline
printf '# changelog.d\n' >"$R/changelog.d/README.md"
run_collate
[ "$RC" -eq 0 ] && case "$OUT" in *"folded 4 fragments"*) true ;; *) false ;; esac \
  && ok "the run reports the count it folded" \
  || bad "the run reports the count it folded" "rc=$RC out=$OUT"
cat >"$TMP/expected" <<'EOF'
# Changelog

Preamble.

## [Unreleased]

### Added

- An entry the file already carries.
- An added fragment.

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
  ok "the collated changelog is exactly the expected file"
else
  bad "the collated changelog is exactly the expected file" "$(cat "$TMP/diff")"
fi
[ -d "$R/changelog.d/fixed" ] && bad "the emptied section directories are removed" "changelog.d/fixed remains" \
  || ok "the emptied section directories are removed"
[ -f "$R/changelog.d/README.md" ] && ok "the README survives the collation" \
  || bad "the README survives the collation" "it is gone"

echo "=== a section the file spells twice merges into the first ==="
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
[ "$RC" -eq 0 ] && case "$OUT" in *"no changelog.d directory"*) true ;; *) false ;; esac \
  && ok "no changelog.d directory is a clean no-op" \
  || bad "no changelog.d directory is a clean no-op" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by the no-op" \
  || bad "CHANGELOG.md is untouched by the no-op" "it changed"
mkdir -p "$R/changelog.d"
printf '# changelog.d\n' >"$R/changelog.d/README.md"
run_collate
[ "$RC" -eq 0 ] && case "$OUT" in *"no fragments"*) true ;; *) false ;; esac \
  && ok "a changelog.d holding only the README is a clean no-op" \
  || bad "a changelog.d holding only the README is a clean no-op" "rc=$RC out=$OUT"
untouched && ok "CHANGELOG.md is untouched by that no-op" \
  || bad "CHANGELOG.md is untouched by that no-op" "it changed"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
