#!/usr/bin/env bash
# Pins what tools/guard still judges once the shipped packages judge the
# rest: the size-ratchet baseline may only tighten unless RATCHET_RAISE=1
# says otherwise, a CHANGELOG entry runs at most three lines wherever it is
# written, a changelog.d fragment is named and shaped so the collator finds
# it, and the [Unreleased] list gains lines only under CHANGELOG_COLLATE=1.
# It also pins the absence — a line cap, a work marker, a blanket allow and an
# oversized file all pass here, because size-ratchet, todo-ban,
# suppression-ban and byte-ceiling are the judges of those. The failing
# direction runs first so a green pass is evidence, not a check that cannot
# fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$(cd "$TEST_DIR/.." && pwd)/guard"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
RATCHET="$REPO/.agents/skills/size-ratchet/scripts/size-ratchet"
# The repo's own classes line, read where it lives: the seam pinned below is
# between two judges reading one policy, so the test may not restate it.
CLASSES="$(sed -n 's/^SIZE_RATCHET_CLASSES = "\(.*\)"$/\1/p' "$REPO/kendex.settings.toml")"
TMP="$(mktemp -d)"
mkdir -p "$TMP/nohooks"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R/.claude" "$R/tools"
git -C "$R" init -q
git -C "$R" symbolic-ref HEAD refs/heads/main
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
git -C "$R" config core.hooksPath "$TMP/nohooks"
echo '# fixture' >"$R/AGENTS.md"
ln -s ../AGENTS.md "$R/.claude/CLAUDE.md"
: >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m fixture

mkfile() { # PATH LINES
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "// line " i }' >"$R/$1"
}

baseline() { # ROW...
  printf '%s\n' "$@" >"$R/tools/size-ratchet-baseline.tsv"
}

run_guard() { # [VAR=VALUE...] — sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && env "$@" "$GUARD" 2>&1)" || RC=$?
}

run_ratchet() { # sets OUT and RC — the repo's classes, nothing else
  OUT=""
  RC=0
  OUT="$(cd "$R" && env SIZE_RATCHET_CLASSES="$CLASSES" "$RATCHET" 2>&1)" || RC=$?
}

TAB="$(printf '\t')"

echo "=== a baseline row this change adds is a raise ==="
mkfile crates/big.rs 401
baseline "crates/big.rs${TAB}401"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"baseline rows went up"*"new row: crates/big.rs"*) true ;; *) false ;; esac \
  && ok "a new baseline row fails, naming the path" \
  || bad "a new baseline row fails, naming the path" "rc=$RC out=$OUT"
run_guard RATCHET_RAISE=1
[ "$RC" -eq 0 ] && ok "RATCHET_RAISE=1 declares the new row" \
  || bad "RATCHET_RAISE=1 declares the new row" "rc=$RC out=$OUT"
git -C "$R" commit -q -m "chore: baseline the file"

echo "=== a row that goes up is a raise; one that goes down is not ==="
mkfile crates/big.rs 450
baseline "crates/big.rs${TAB}450"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"baseline rows went up"*"crates/big.rs: 401 -> 450"*) true ;; *) false ;; esac \
  && ok "a raised row fails, naming both counts" \
  || bad "a raised row fails, naming both counts" "rc=$RC out=$OUT"
run_guard RATCHET_RAISE=1
[ "$RC" -eq 0 ] && ok "RATCHET_RAISE=1 declares the raise" \
  || bad "RATCHET_RAISE=1 declares the raise" "rc=$RC out=$OUT"
baseline "crates/big.rs${TAB}380"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "a tightened row passes without declaring anything" \
  || bad "a tightened row passes without declaring anything" "rc=$RC out=$OUT"

echo "=== the shipped packages' verdicts are not twinned here ==="
mkfile crates/uncapped.rs 401
mkfile ui/uncapped.ts 300
printf '// %s: unfinished\n' "TO""DO" >"$R/crates/marker.rs" # split, or todo-ban fails this file
printf '#![allow(dead_code)]\n' >"$R/crates/blanket.rs"
head -c 300000 /dev/zero | tr '\0' 'x' >"$R/crates/huge.bin"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] \
  && ok "an over-cap file, a work marker, a blanket allow and a 300 KB file all pass — the packages judge those" \
  || bad "an over-cap file, a work marker, a blanket allow and a 300 KB file all pass — the packages judge those" "rc=$RC out=$OUT"
rm -f "$R/crates/uncapped.rs" "$R/ui/uncapped.ts" "$R/crates/marker.rs" "$R/crates/blanket.rs" "$R/crates/huge.bin"
git -C "$R" add -A

echo "=== a CHANGELOG entry past three lines fails; three passes ==="
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A three-line entry\n  second line\n  third line.\n- A four-line entry\n  second line\n  third line\n  fourth line.\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"CHANGELOG.md entries run past three lines"*"line 10: 4 lines"*) true ;; *) false ;; esac \
  && ok "a four-line entry fails, naming its line and count" \
  || bad "a four-line entry fails, naming its line and count" "rc=$RC out=$OUT"
case "$OUT" in *"line 7:"*) bad "the three-line entry is not named" "$OUT" ;; *) ok "the three-line entry is not named" ;; esac
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- Four-space continuation\n    second\n    third\n    fourth.\n* Tab continuation\n\tsecond\n\tthird\n\tfourth.\n- Two paragraphs\r\n\r\n  second paragraph\r\n  third line.\r\n+ Lazy continuation\nsecond\nthird\nfourth.\n\nA paragraph after the list is not an entry.\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"line 7: 4 lines"*"line 11: 4 lines"*"line 15: 4 lines"*"line 19: 4 lines"*) true ;; *) false ;; esac \
  && ok "deep-indented, tab-indented, CRLF two-paragraph, and lazy entries under any marker are counted whole" \
  || bad "deep-indented, tab-indented, CRLF two-paragraph, and lazy entries under any marker are counted whole" "rc=$RC out=$OUT"
case "$OUT" in *"line 19: 6 lines"*|*"line 24"*) bad "a paragraph after the list is not counted into the last entry" "$OUT" ;; *) ok "a paragraph after the list is not counted into the last entry" ;; esac
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A three-line entry\n  second line\n  third line.\n- One line.\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "entries of one and three lines pass" \
  || bad "entries of one and three lines pass" "rc=$RC out=$OUT"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$R/CHANGELOG.md"
  run_guard RATCHET_RAISE=
  chmod 644 "$R/CHANGELOG.md"
  [ "$RC" -ne 0 ] && case "$OUT" in *"CHANGELOG.md is unreadable"*) true ;; *) false ;; esac \
    && ok "an unreadable CHANGELOG fails closed, naming the check that could not run" \
    || bad "an unreadable CHANGELOG fails closed, naming the check that could not run" "rc=$RC out=$OUT"
fi

echo "=== a changelog fragment is judged as the entry it becomes ==="
mkdir -p "$R/changelog.d/fixed"
printf -- '- A four-line fragment\n  second line\n  third line\n  fourth line.\n' >"$R/changelog.d/fixed/ken-1.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"changelog.d/fixed/ken-1.md entries run past three lines"*"line 1: 4 lines"*) true ;; *) false ;; esac \
  && ok "an over-long fragment fails, naming the fragment and its count" \
  || bad "an over-long fragment fails, naming the fragment and its count" "rc=$RC out=$OUT"
printf -- '- A three-line fragment\n  second line\n  third line.\n' >"$R/changelog.d/fixed/ken-1.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "a three-line fragment passes" \
  || bad "a three-line fragment passes" "rc=$RC out=$OUT"

echo "=== a fragment is filed where the collator looks for it ==="
printf -- '- Stray.\n' >"$R/changelog.d/loose.md"
mkdir -p "$R/changelog.d/bogus"
printf -- '- Wrong section.\n' >"$R/changelog.d/bogus/ken-2.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"changelog.d/loose.md is not a changelog fragment"*) true ;; *) false ;; esac \
  && ok "a fragment outside a section directory fails, naming it" \
  || bad "a fragment outside a section directory fails, naming it" "rc=$RC out=$OUT"
case "$OUT" in *"changelog.d/bogus/ken-2.md is not a changelog fragment"*) ok "an unknown section directory fails, naming it" ;;
  *) bad "an unknown section directory fails, naming it" "$OUT" ;; esac
rm -f "$R/changelog.d/loose.md"
rm -rf "${R:?}/changelog.d/bogus"
printf 'Not a list item.\n' >"$R/changelog.d/fixed/ken-3.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"changelog.d/fixed/ken-3.md is not the list item it becomes"*) true ;; *) false ;; esac \
  && ok "a fragment that opens with prose fails, naming it" \
  || bad "a fragment that opens with prose fails, naming it" "rc=$RC out=$OUT"
rm -f "$R/changelog.d/fixed/ken-3.md"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$R/changelog.d/fixed/ken-1.md"
  run_guard RATCHET_RAISE=
  chmod 644 "$R/changelog.d/fixed/ken-1.md"
  [ "$RC" -ne 0 ] && case "$OUT" in *"changelog.d/fixed/ken-1.md is unreadable — the fragment shape check could not run"*) true ;; *) false ;; esac \
    && ok "an unreadable fragment fails closed, naming the check that could not run" \
    || bad "an unreadable fragment fails closed, naming the check that could not run" "rc=$RC out=$OUT"
  case "$OUT" in *"changelog.d/fixed/ken-1.md is unreadable — the entry-length check could not run"*) ok "the entry-length check reports it too" ;;
    *) bad "the entry-length check reports it too" "$OUT" ;; esac
fi
printf '# changelog.d\n\nNot a list item either.\n' >"$R/changelog.d/README.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "the README is not judged as a fragment" \
  || bad "the README is not judged as a fragment" "rc=$RC out=$OUT"

echo "=== the [Unreleased] list is the collator's to write ==="
git -C "$R" commit -q -m "chore: land the changelog"
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A three-line entry\n  second line\n  third line.\n- One line.\n- A hand-written line.\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"gained lines under [Unreleased]"*"- A hand-written line."*) true ;; *) false ;; esac \
  && ok "a hand-written [Unreleased] line fails, quoting the line" \
  || bad "a hand-written [Unreleased] line fails, quoting the line" "rc=$RC out=$OUT"
run_guard RATCHET_RAISE= CHANGELOG_COLLATE=1
[ "$RC" -eq 0 ] && ok "CHANGELOG_COLLATE=1 declares the collator's write" \
  || bad "CHANGELOG_COLLATE=1 declares the collator's write" "rc=$RC out=$OUT"
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n### Fixed\n\n- A three-line entry\n  second line\n  third line.\n- One line.\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "rotating [Unreleased] into a released version adds no line" \
  || bad "rotating [Unreleased] into a released version adds no line" "rc=$RC out=$OUT"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$R/CHANGELOG.md"
  run_guard RATCHET_RAISE=
  chmod 644 "$R/CHANGELOG.md"
  [ "$RC" -ne 0 ] && case "$OUT" in *"could not be compared against HEAD"*) true ;; *) false ;; esac \
    && ok "an unreadable CHANGELOG fails the [Unreleased] rule closed too" \
    || bad "an unreadable CHANGELOG fails the [Unreleased] rule closed too" "rc=$RC out=$OUT"
fi

echo "=== a test row RATCHET_RAISE declares is still refused by the ratchet ==="
# Guard judges the declaration; the ratchet judges the row. A test is never
# raised, so the declaration does not carry it — and the seam only holds if
# the two are asked in the same repo state.
mkfile crates/big.rs 450
mkfile ui/x.test.ts 800
baseline "crates/big.rs${TAB}450"
git -C "$R" add -A
run_ratchet
[ "$RC" -eq 0 ] && ok "control: a test exactly at its class threshold needs no row" \
  || bad "control: a test exactly at its class threshold needs no row" "rc=$RC out=$OUT"
mkfile ui/x.test.ts 801
baseline "crates/big.rs${TAB}450" "ui/x.test.ts${TAB}801"
git -C "$R" add -A
run_guard RATCHET_RAISE=1
[ "$RC" -eq 0 ] && ok "guard takes the declaration for both new rows" \
  || bad "guard takes the declaration for both new rows" "rc=$RC out=$OUT"
run_ratchet
[ "$RC" -eq 1 ] && case "$OUT" in *"test baseline row added: ui/x.test.ts"*) true ;; *) false ;; esac \
  && ok "the ratchet refuses the test row the declaration would have carried" \
  || bad "the ratchet refuses the test row the declaration would have carried" "rc=$RC out=$OUT"
case "$OUT" in *"crates/big.rs"*) bad "the non-test row raised in the same diff is not refused" "$OUT" ;; *) ok "the non-test row raised in the same diff is not refused" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
