#!/usr/bin/env bash
# Pins for every check direction of scripts/size-ratchet. Both failure
# directions (new offender, baselined growth) AND the looser-than-reality
# direction must fire, with a passing control first so a green run is
# evidence, not a check that cannot fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic: a leaked setting would mask every case below.
unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

REMEDY="split at a concept seam, or raise the baseline row in this diff with justification"

new_repo() { # NAME — fresh fixture repo in $R
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

mkfile() { # PATH LINES — file of LINES lines under $R
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

run_sr() { # [args...] — run in $R at threshold 10; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 "$SR" "$@" 2>&1)" || RC=$?
}

echo "=== control: a clean repo passes, including a file exactly AT the threshold ==="
new_repo clean
mkfile a.txt 5
mkfile at-threshold.txt 10
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && case "$OUT" in *"size-ratchet: OK"*) true ;; *) false ;; esac \
  && ok "clean repo passes; 10 lines at threshold 10 is not an offender" \
  || bad "clean repo passes; 10 lines at threshold 10 is not an offender" "rc=$RC out=$OUT"

echo "=== failure direction 1: new offender ==="
new_repo newoff
mkfile big.txt 11
git -C "$R" add -A
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"new offender: big.txt — 11 lines > threshold 10"*) true ;; *) false ;; esac \
  && ok "one line over the threshold fails as a new offender, naming file/count/threshold" \
  || bad "one line over the threshold fails as a new offender" "rc=$RC out=$OUT"
case "$OUT" in *"$REMEDY"*) ok "new-offender diagnostic carries the two remedies verbatim" ;; *) bad "new-offender diagnostic carries the two remedies verbatim" "$OUT" ;; esac

echo "=== a baseline row at the current count freezes the offender ==="
new_repo frozen
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "baselined offender at exactly its row passes" || bad "baselined offender at exactly its row passes" "rc=$RC out=$OUT"

echo "=== failure direction 2: baselined file grows ==="
mkfile big.txt 20
git -C "$R" add -A
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"baselined file grew: big.txt — 20 lines > baseline 15"*) true ;; *) false ;; esac \
  && ok "growth past the row fails, naming file/count/baseline" \
  || bad "growth past the row fails" "rc=$RC out=$OUT"
case "$OUT" in *"$REMEDY"*) ok "growth diagnostic carries the two remedies verbatim" ;; *) bad "growth diagnostic carries the two remedies verbatim" "$OUT" ;; esac

echo "=== failure direction 3: baseline looser than reality ==="
printf 'big.txt\t30\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline looser than reality: big.txt — baseline 30 > actual 20"*) true ;; *) false ;; esac \
  && ok "a row above the actual count fails — the ratchet must move down" \
  || bad "a row above the actual count fails" "rc=$RC out=$OUT"

new_repo stale
mkfile small.txt 5
mkdir -p "$R/tools"
printf 'gone.txt\t42\nsmall.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"stale baseline row: small.txt"*) true ;; *) false ;; esac \
  && ok "a row for a file now under the threshold fails as stale" \
  || bad "a row for a file now under the threshold fails as stale" "rc=$RC out=$OUT"
case "$OUT" in *"stale baseline row: gone.txt"*) ok "a row for a deleted file fails as stale" ;; *) bad "a row for a deleted file fails as stale" "$OUT" ;; esac
case "$OUT" in *"the row (42) must go"*) ok "the gone-file diagnostic keeps its fields aligned (names the row's own count)" ;; *) bad "the gone-file diagnostic keeps its fields aligned" "$OUT" ;; esac

echo "=== tracked-but-absent files are unknown, never stale ==="
# In `git ls-files` but missing from the worktree (unstaged deletion, sparse
# checkout): the size is unknowable, so the row must be preserved — treating
# it as gone would let --update silently loosen the ratchet.
new_repo absent
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
rm "$R/big.txt" # unstaged: the index still lists big.txt
run_sr
[ "$RC" -eq 0 ] && ok "an unstaged-deleted baselined file is preserved, not stale" \
  || bad "an unstaged-deleted baselined file is preserved, not stale" "rc=$RC out=$OUT"
git -C "$R" add -A # stage the deletion: now it truly left the tracked set
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"stale baseline row: big.txt"*) true ;; *) false ;; esac \
  && ok "control: the STAGED deletion is stale — only index-listed-but-absent is preserved" \
  || bad "control: the STAGED deletion is stale" "rc=$RC out=$OUT"

echo "=== newline-containing tracked paths are refused loudly ==="
new_repo nl
mkfile ok.txt 3
printf 'x\n' >"$R/"$'bad\nname.txt'
git -C "$R" add -A
run_sr
[ "$RC" -eq 2 ] && case "$OUT" in *newline*) true ;; *) false ;; esac \
  && ok "a tracked path containing a newline is a loud refusal, not a silently split record" \
  || bad "a tracked path containing a newline is a loud refusal" "rc=$RC out=$OUT"

echo "=== exclusion patterns reach matching intact (no word-split, no glob expansion) ==="
new_repo intact
mkfile "foo bqq.txt" 20   # excluded only if 'foo b*' survives as ONE pattern
mkfile sub/ax-big.txt 20  # excluded only if '*ax-big.txt' is NOT glob-expanded
mkfile zax-big.txt 3      # glob bait in the repo root: an expanding build rewrites the pattern to this
mkdir -p "$R/tools"
printf 'foo b*\tspace-containing pattern\n*ax-big.txt\tglob-bait pattern\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "space-containing and glob-bait patterns both exclude their targets verbatim" \
  || bad "space-containing and glob-bait patterns both exclude their targets verbatim" "rc=$RC out=$OUT"

echo "=== exclusions remove files from the counted set ==="
new_repo excl
mkfile vendor/big.txt 50
mkfile generated.lock 50
mkfile src/real.txt 5
mkdir -p "$R/tools"
printf 'vendor/*\tvendored third-party code\ngenerated.lock\tlockfile\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "excluded offenders (dir glob and exact path) pass" || bad "excluded offenders pass" "rc=$RC out=$OUT"

printf 'vendor/big.txt\t50\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"stale baseline row: vendor/big.txt"*) true ;; *) false ;; esac \
  && ok "a baseline row for an excluded file is stale — excluded files leave the counted set" \
  || bad "a baseline row for an excluded file is stale" "rc=$RC out=$OUT"

echo "=== --baseline flag relocates the baseline ==="
new_repo flagpath
mkfile big.txt 15
printf 'big.txt\t15\n' >"$R/custom-baseline.tsv"
git -C "$R" add -A
run_sr --baseline custom-baseline.tsv
[ "$RC" -eq 0 ] && ok "--baseline points the check at a custom path" || bad "--baseline points the check at a custom path" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
