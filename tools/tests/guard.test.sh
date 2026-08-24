#!/usr/bin/env bash
# Pins the hard line cap in tools/guard and its one escape: a file over the
# cap passes only when a size-ratchet baseline row covers its count and that
# row is at HEAD or declared by RATCHET_RAISE=1 in this change. The failing
# direction runs first so a green pass is evidence, not a check that cannot
# fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$(cd "$TEST_DIR/.." && pwd)/guard"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R/.claude" "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
echo '# fixture' >"$R/AGENTS.md"
ln -s ../AGENTS.md "$R/.claude/CLAUDE.md"
: >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q --no-verify -m fixture

mkfile() { # PATH LINES
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "// line " i }' >"$R/$1"
}

run_guard() { # [VAR=VALUE...] — sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && env "$@" "$GUARD" 2>&1)" || RC=$?
}

echo "=== over the cap with no baseline row fails, RATCHET_RAISE or not ==="
mkfile big.rs 401
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"big.rs is 401 lines (cap 400)"*) true ;; *) false ;; esac \
  && ok "401 lines of .rs fails the 400 cap, naming file/count/cap" \
  || bad "401 lines of .rs fails the 400 cap" "rc=$RC out=$OUT"
case "$OUT" in *"RATCHET_RAISE=1 with the file's row"*) ok "the cap diagnostic names the merge-raise path" ;; *) bad "the cap diagnostic names the merge-raise path" "$OUT" ;; esac
run_guard RATCHET_RAISE=1
[ "$RC" -ne 0 ] && case "$OUT" in *"big.rs is 401 lines"*) true ;; *) false ;; esac \
  && ok "RATCHET_RAISE=1 alone, with no row, still fails the cap" \
  || bad "RATCHET_RAISE=1 alone, with no row, still fails the cap" "rc=$RC out=$OUT"

echo "=== a new row for the merged file passes only under RATCHET_RAISE=1 ==="
printf 'big.rs\t401\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"big.rs is 401 lines"*) true ;; *) false ;; esac \
  && ok "a row added without RATCHET_RAISE=1 does not lift the cap" \
  || bad "a row added without RATCHET_RAISE=1 does not lift the cap" "rc=$RC out=$OUT"
run_guard RATCHET_RAISE=1
[ "$RC" -eq 0 ] && ok "the merged file with its row and RATCHET_RAISE=1 passes" \
  || bad "the merged file with its row and RATCHET_RAISE=1 passes" "rc=$RC out=$OUT"

echo "=== once the row is at HEAD the ratchet governs: later changes pass without RATCHET_RAISE ==="
git -C "$R" commit -q --no-verify -m merge
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "a frozen over-cap file passes on the next change" \
  || bad "a frozen over-cap file passes on the next change" "rc=$RC out=$OUT"

echo "=== growth past the row is not covered ==="
mkfile big.rs 450
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"big.rs is 450 lines"*) true ;; *) false ;; esac \
  && ok "450 lines against a 401 row fails the cap" \
  || bad "450 lines against a 401 row fails the cap" "rc=$RC out=$OUT"
printf 'big.rs\t450\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"baseline rows went up"*"big.rs: 401 -> 450"*) true ;; *) false ;; esac \
  && ok "raising the row without RATCHET_RAISE=1 is refused, naming the row" \
  || bad "raising the row without RATCHET_RAISE=1 is refused" "rc=$RC out=$OUT"
case "$OUT" in *"big.rs is 450 lines"*) bad "a raised row must lift the cap check even when the raise itself is refused" "$OUT" ;; *) ok "the refusal is the raise check alone, not the cap" ;; esac
run_guard RATCHET_RAISE=1
[ "$RC" -eq 0 ] && ok "the raised row with RATCHET_RAISE=1 passes" \
  || bad "the raised row with RATCHET_RAISE=1 passes" "rc=$RC out=$OUT"

echo "=== a UI TypeScript file between the 250 cap and the 400 default has a passing state ==="
# The guard caps .ts at 250 and lifts the cap only for a baseline row; the
# ratchet must judge .ts by the same 250, or it rejects that row as stale
# and the file can pass neither gate. The class mirrors the guard's domain:
# catalog TypeScript the guard never caps stays at the default.
git -C "$R" commit -q --no-verify -m frozen
SR="$(cd "$TEST_DIR/../.." && pwd)/skills/size-ratchet/scripts/size-ratchet"
CLASSES=$(grep -E '^(SIZE_RATCHET_CLASSES|classes) = "' "$(cd "$TEST_DIR/../.." && pwd)/kendex.settings.toml" | head -1 | sed 's/.*= "\(.*\)".*/\1/')
[ -n "$CLASSES" ] || { echo "no size-ratchet classes found in kendex.settings.toml"; exit 2; }
run_ratchet() { # sets OUT and RC — the repo's classes, nothing else
  OUT=""
  RC=0
  OUT="$(cd "$R" && env -u SIZE_RATCHET_THRESHOLD SIZE_RATCHET_SETTINGS_FILE=/dev/null SIZE_RATCHET_CLASSES="$CLASSES" "$SR" 2>&1)" || RC=$?
}
mkfile ui/big.ts 300
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -ne 0 ] && case "$OUT" in *"ui/big.ts is 300 lines (cap 250)"*) true ;; *) false ;; esac \
  && ok "300 lines of ui/ .ts with no row fails the 250 cap" \
  || bad "300 lines of ui/ .ts with no row fails the 250 cap" "rc=$RC out=$OUT"
printf 'big.rs\t450\nui/big.ts\t300\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_guard RATCHET_RAISE=1
[ "$RC" -eq 0 ] && ok "300 lines of ui/ .ts with its row and RATCHET_RAISE=1 passes the guard" \
  || bad "300 lines of ui/ .ts with its row and RATCHET_RAISE=1 passes the guard" "rc=$RC out=$OUT"
run_ratchet
[ "$RC" -eq 0 ] && ok "the ratchet, under the repo's classes, accepts that same row" \
  || bad "the ratchet, under the repo's classes, accepts that same row" "rc=$RC out=$OUT"
git -C "$R" commit -q --no-verify -m ui-row
mkfile pi-extensions/x/big.ts 300
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "control: the guard does not cap catalog .ts" \
  || bad "control: the guard does not cap catalog .ts" "rc=$RC out=$OUT"
run_ratchet
[ "$RC" -eq 0 ] && ok "a 300-line catalog .ts needs no row — the 250 class stops where the guard's cap does" \
  || bad "a 300-line catalog .ts needs no row — the 250 class stops where the guard's cap does" "rc=$RC out=$OUT"
mkfile ui/tests/big.test.ts 300
git -C "$R" add -A
run_ratchet
[ "$RC" -eq 0 ] && ok "a 300-line ui/ test .ts still belongs to the 800 test class, not the 250 one" \
  || bad "a 300-line ui/ test .ts still belongs to the 800 test class, not the 250 one" "rc=$RC out=$OUT"

echo "=== a UI test file between 250 and 800 passes both gates with no row ==="
# The guard's cap mirrors the ratchet's test classes; otherwise a test file
# the ratchet allows up to 800 needs a row the ratchet then calls stale.
mkfile ui/x.test.ts 300
git -C "$R" add -A
run_guard RATCHET_RAISE=
[ "$RC" -eq 0 ] && ok "300-line ui/x.test.ts and ui/tests/big.test.ts pass the guard with no row" \
  || bad "300-line ui/x.test.ts and ui/tests/big.test.ts pass the guard with no row" "rc=$RC out=$OUT"
run_ratchet
[ "$RC" -eq 0 ] && ok "and the ratchet, under the repo's classes, wants no row for them either" \
  || bad "and the ratchet, under the repo's classes, wants no row for them either" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
