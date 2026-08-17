#!/usr/bin/env bash
# Pins for --seed's bootstrap contract (vstack #1398 / VST-328): the FIRST
# baseline comes from the gate's own collector — exact counts, class-aware
# thresholds, excludes honored, LC_ALL=C order, a self-row when the file
# outgrows its own threshold — and ONLY the first: a baseline with rows
# refuses, because a live ratchet only moves down.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

mkfile() { # PATH LINES
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

run_sr() { # [args...] — run in $R at threshold 10, tests class 20; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_CLASSES='tests/*=20' "$SR" "$@" 2>&1)" || RC=$?
}

echo "=== --seed writes the first baseline from the collector ==="
R="$TMP/seed"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile big-b.txt 25
mkfile big-a.txt 12
mkfile small.txt 5
mkfile tests/suite-ok.sh 15
mkfile tests/suite-big.sh 30
mkfile skipped.txt 40
printf 'skipped.txt\tdeliberately unbounded fixture\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A

run_sr --seed
[ "$RC" -eq 0 ] && ok "--seed exits 0 on a fresh repo" || bad "--seed exit" "rc=$RC out=$OUT"
expected="$(printf 'big-a.txt\t12\nbig-b.txt\t25\ntests/suite-big.sh\t30\n')"
actual="$(cat "$R/tools/size-ratchet-baseline.tsv" 2>/dev/null || echo MISSING)"
[ "$actual" = "$expected" ] && ok "rows are exact counts, class-aware, excludes honored, sorted" \
  || bad "seeded rows" "$(printf 'expected:\n%s\ngot:\n%s' "$expected" "$actual")"

git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "the seeded repo passes the plain check" || bad "post-seed check" "rc=$RC out=$OUT"

echo "=== --seed refuses a live baseline ==="
before="$(cat "$R/tools/size-ratchet-baseline.tsv")"
run_sr --seed
[ "$RC" -eq 2 ] && ok "--seed on a populated baseline is a config error" || bad "refusal rc" "rc=$RC out=$OUT"
case "$OUT" in
  *"3 row(s)"*) ok "the refusal names the row count" ;;
  *) bad "refusal names count" "$OUT" ;;
esac
after="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$before" = "$after" ] && ok "the refused baseline is byte-identical" || bad "refusal wrote" "$after"

echo "=== the baseline that outgrows its own threshold seeds its self-row ==="
R="$TMP/selfrow"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
for i in $(seq 1 12); do mkfile "off-$i.txt" 15; done
git -C "$R" add -A
run_sr --seed
[ "$RC" -eq 0 ] && ok "--seed exits 0 with a self-row fixture" || bad "self-row seed exit" "rc=$RC out=$OUT"
rows="$(wc -l <"$R/tools/size-ratchet-baseline.tsv" | tr -d ' ')"
selfrow="$(grep -F 'tools/size-ratchet-baseline.tsv' "$R/tools/size-ratchet-baseline.tsv" || echo MISSING)"
[ "$selfrow" = "$(printf 'tools/size-ratchet-baseline.tsv\t%s' "$rows")" ] \
  && ok "the self-row carries the final length ($rows)" || bad "self-row" "rows=$rows selfrow=$selfrow"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "the committed baseline passes its own gate" || bad "self-row post-check" "rc=$RC out=$OUT"

echo "=== --seed refuses an index-only baseline ==="
R="$TMP/sparse-seed"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile big.txt 15
: >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
rm "$R/tools/size-ratchet-baseline.tsv" # tracked, absent from the worktree
run_sr --seed
[ "$RC" -eq 2 ] && case "$OUT" in *"index-only baseline"*) true ;; *) false ;; esac \
  && ok "--seed on a sparse-hidden baseline is a config error naming the repair" \
  || bad "sparse seed refusal" "rc=$RC out=$OUT"

echo "=== --staged --seed never replaces unstaged worktree rows ==="
R="$TMP/staged-clobber"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile big.txt 15
: >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
printf 'big.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv" # unstaged rows
run_sr --staged --seed
[ "$RC" -eq 2 ] && case "$OUT" in *"unstaged"*) true ;; *) false ;; esac \
  && ok "--staged --seed refuses while the worktree copy carries unstaged rows" \
  || bad "staged clobber refusal" "rc=$RC out=$OUT"
row="$(cat "$R/tools/size-ratchet-baseline.tsv")"
[ "$row" = "$(printf 'big.txt\t15')" ] && ok "the unstaged rows survive" || bad "unstaged rows" "$row"

echo "=== an excluded baseline gets no self-row ==="
R="$TMP/excluded-baseline"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
for i in $(seq 1 12); do mkfile "off-$i.txt" 15; done
printf 'tools/*\tpolicy files live outside the gate here\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_sr --seed
[ "$RC" -eq 0 ] && ok "--seed exits 0 with the baseline excluded" || bad "excluded seed exit" "rc=$RC out=$OUT"
if grep -qF 'tools/size-ratchet-baseline.tsv' "$R/tools/size-ratchet-baseline.tsv"; then
  bad "excluded self-row" "a self-row was written for an excluded baseline"
else
  ok "no self-row for an excluded baseline"
fi

echo "=== the seeded write stays inside the repository ==="
R="$TMP/contained"
mkdir -p "$R" "$TMP/outside-target"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
mkfile big.txt 15
ln -s "$TMP/outside-target" "$R/policy"
git -C "$R" add -A
OUT=""; RC=0
OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 "$SR" --seed --baseline policy/new/base.tsv 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"outside the repository"*) true ;; *) false ;; esac \
  && ok "--seed refuses a baseline path resolving outside the repo" \
  || bad "containment refusal" "rc=$RC out=$OUT"
[ -z "$(ls -A "$TMP/outside-target")" ] && ok "nothing was written or created outside" || bad "outside side effects" "$(ls "$TMP/outside-target")"

echo "=== mode exclusivity ==="
run_sr --seed --update
[ "$RC" -eq 2 ] && ok "--seed with --update is a config error" || bad "exclusivity" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
