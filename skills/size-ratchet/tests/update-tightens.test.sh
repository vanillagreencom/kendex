#!/usr/bin/env bash
# Pins for --update's tighten-only contract: rows are lowered or removed to
# match reality, NEVER added and NEVER raised — a grown file keeps its old
# row (and keeps failing), a new offender stays out of the baseline, and
# deliberate growth is a hand-edit that then passes (control).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

mkfile() { # PATH LINES
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

run_sr() { # [args...] — run in $R at threshold 10; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 "$SR" "$@" 2>&1)" || RC=$?
}

R="$TMP/upd"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test

# One fixture exercising every row fate at once (threshold 10):
#   grown.txt   actual 20, row 12  -> kept at 12 (never raised), still fails
#   loose.txt   actual 15, row 30  -> lowered to 15
#   shrunk.txt  actual  5, row 12  -> removed (under threshold)
#   gone.txt    no file,   row 40  -> removed (left the tracked set)
#   newoff.txt  actual 25, no row  -> NOT added, still fails
mkfile grown.txt 20
mkfile loose.txt 15
mkfile shrunk.txt 5
mkfile newoff.txt 25
mkdir -p "$R/tools"
printf 'gone.txt\t40\ngrown.txt\t12\nloose.txt\t30\nshrunk.txt\t12\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A

run_sr --update
[ "$RC" -eq 1 ] && ok "--update still exits 1 while growth and a new offender remain" \
  || bad "--update still exits 1 while growth and a new offender remain" "rc=$RC out=$OUT"

expected="$(printf 'grown.txt\t12\nloose.txt\t15\n')"
actual="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$actual" = "$expected" ] && ok "rewritten baseline is byte-exact: grown kept at 12, loose lowered to 15, shrunk+gone removed, newoff NOT added" \
  || bad "rewritten baseline is byte-exact" "$(printf 'expected:\n%s\ngot:\n%s' "$expected" "$actual")"

LC_ALL=C sort -c "$R/tools/size-ratchet-baseline.tsv" \
  && ok "rewritten baseline is LC_ALL=C sorted" || bad "rewritten baseline is LC_ALL=C sorted" "$actual"

case "$OUT" in *"tightened: loose.txt 30 -> 15"*) ok "tightening is announced with old -> new" ;; *) bad "tightening is announced with old -> new" "$OUT" ;; esac
case "$OUT" in *"kept (grew"*) ok "the kept grown row is called out as a hand-edit, never --update" ;; *) bad "the kept grown row is called out" "$OUT" ;; esac
case "$OUT" in *"new offender: newoff.txt"*) ok "the surviving new offender still fails after --update" ;; *) bad "the surviving new offender still fails after --update" "$OUT" ;; esac
case "$OUT" in *"baselined file grew: grown.txt — 20 lines > baseline 12"*) ok "the surviving growth still fails after --update" ;; *) bad "the surviving growth still fails after --update" "$OUT" ;; esac

run_sr --update
actual2="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$RC" -eq 1 ] && [ "$actual2" = "$expected" ] && ok "--update is idempotent: second run changes nothing" \
  || bad "--update is idempotent" "rc=$RC got: $actual2"

# Control: deliberate growth accepted by HAND-EDITING the rows makes the
# repo pass — proving the failures above were the ratchet, not noise.
printf 'grown.txt\t20\nloose.txt\t15\nnewoff.txt\t25\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "hand-edited acceptance rows pass (control: growth is a reviewed human edit)" \
  || bad "hand-edited acceptance rows pass" "rc=$RC out=$OUT"

# A tracked-but-absent file (unstaged deletion / sparse checkout) has an
# unknowable size: --update must preserve its row verbatim, never drop it —
# dropping would loosen the ratchet with a green exit.
R="$TMP/upd-absent"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile keep.txt 15
mkdir -p "$R/tools"
printf 'keep.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
rm "$R/keep.txt" # unstaged: keep.txt stays in git ls-files
run_sr --update
row="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$RC" -eq 0 ] && [ "$row" = "$(printf 'keep.txt\t15')" ] && case "$OUT" in *"preserved"*) true ;; *) false ;; esac \
  && ok "--update preserves the row of a tracked-but-absent file verbatim and says so" \
  || bad "--update preserves the row of a tracked-but-absent file" "rc=$RC row=$row out=$OUT"

# --update with no baseline file: never creates one (it cannot add rows).
R="$TMP/upd2"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile big.txt 20
git -C "$R" add -A
run_sr --update
[ "$RC" -eq 1 ] && [ ! -e "$R/tools/size-ratchet-baseline.tsv" ] && case "$OUT" in *"never adds rows"*) true ;; *) false ;; esac \
  && ok "--update without a baseline writes nothing and the new offender still fails" \
  || bad "--update without a baseline writes nothing" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
