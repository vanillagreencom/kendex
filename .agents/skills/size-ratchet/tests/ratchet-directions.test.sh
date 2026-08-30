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
unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
# The shipped class list and frozen list are policy, pinned by
# shipped-defaults.test.sh. Every fixture here declares its own thresholds,
# so both start empty and a case that needs one sets it.
export SIZE_RATCHET_DEFAULT_CLASSES="" SIZE_RATCHET_FROZEN_CLASSES=""

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

REMEDY="split at a concept seam (RATCHET_RAISE=1 raises the row only when the added lines are the fix with no seam, or fragments of one concept are merged back into one file)"

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

# The same run with `*.test.*` frozen, for the cases about a class whose rows
# never rise. RAISE=1 declares the raise the way a commit does.
run_frozen() { # [args...]
  OUT=""
  RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_FROZEN_CLASSES='*.test.*' RATCHET_RAISE="${RAISE:-}" "$SR" "$@" 2>&1)" || RC=$?
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
case "$OUT" in *"$REMEDY"*) ok "new-offender diagnostic carries the remedy verbatim" ;; *) bad "new-offender diagnostic carries the remedy verbatim" "$OUT" ;; esac

echo "=== a frozen-class offender gets the split remedy alone ==="
new_repo testoff
mkfile x.test.txt 11
git -C "$R" add -A
run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"new offender: x.test.txt"*) true ;; *) false ;; esac \
  && ok "a frozen path over the threshold is still a new offender" \
  || bad "a frozen path over the threshold is still a new offender" "rc=$RC out=$OUT"
case "$OUT" in *RATCHET_RAISE*) bad "a frozen offender is never offered a raise" "$OUT" ;; *) ok "a frozen offender is never offered a raise" ;; esac
# The control: the same file outside the frozen list is offered the raise.
run_sr
case "$OUT" in *RATCHET_RAISE*) ok "control: an unfrozen offender is offered the declaration" ;; *) bad "control: an unfrozen offender is offered the declaration" "$OUT" ;; esac

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
case "$OUT" in *"$REMEDY"*) ok "growth diagnostic carries the remedy verbatim" ;; *) bad "growth diagnostic carries the remedy verbatim" "$OUT" ;; esac

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

echo "=== tracked-but-absent files count from the index, never stale ==="
# In `git ls-files` but missing from the worktree (unstaged deletion, sparse
# checkout): the size comes from the index blob, so the row still matches —
# treating the file as gone would let --update silently loosen the ratchet.
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

echo "=== a tracked-but-absent exclusion list still applies, from the index ==="
# Same sparse-checkout shape as the baseline case above, for the OTHER tracked
# policy file. A worktree missing the list used to mean zero exclusions, so a
# fresh or partial tree reported violations against the vendored and generated
# files the tracked list excludes — the opposite direction from the baseline
# fallback (noise, not a smuggled offender), but equally a broken scope
# contract: "every tracked file minus the exclusion list" held only in its
# first half.
new_repo excl-absent
mkfile vendor/big.txt 40
git -C "$R" add -A

# Control 1, the failing direction: with no exclusion list, the file IS a
# violation. Without this the passes below could come from the file being
# under threshold or uncounted rather than from the exclusion.
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"vendor/big.txt"*) true ;; *) false ;; esac \
  && ok "control: with no exclusion list, vendor/big.txt is a new offender" \
  || bad "control: with no exclusion list, vendor/big.txt is a new offender" "rc=$RC out=$OUT"

mkdir -p "$R/tools"
printf 'vendor/*\tvendored third-party — size is not a design signal\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A

# Control 2: the exclusion works when the list is materialized.
run_sr
[ "$RC" -eq 0 ] && ok "control: a worktree exclusion list excludes vendor/big.txt" \
  || bad "control: a worktree exclusion list excludes vendor/big.txt" "rc=$RC out=$OUT"

rm "$R/tools/size-ratchet-excludes" # unstaged: the index still lists it
run_sr
[ "$RC" -eq 0 ] && ok "a tracked-but-absent exclusion list is read from the index and still applies" \
  || bad "a tracked-but-absent exclusion list is read from the index" "rc=$RC out=$OUT"
case "$OUT" in
  *"vendor/big.txt"*) bad "the index-read exclusion must keep vendor/big.txt out of the report" "$OUT" ;;
  *) ok "no violation is reported against the index-excluded path" ;;
esac

git -C "$R" add -A # stage the deletion: the list truly left the tracked set
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"vendor/big.txt"*) true ;; *) false ;; esac \
  && ok "control: a STAGED deletion of the list really removes the exclusions" \
  || bad "control: a STAGED deletion of the list removes the exclusions" "rc=$RC out=$OUT"

echo "=== the index copy of the exclusion list gets the same validation ==="
# A malformed row must fail loud from the index exactly as from the worktree —
# otherwise the fallback would be a hole in the reason-is-mandatory contract —
# and the diagnostic must say WHICH copy it read.
new_repo excl-index-bad
mkfile vendor/big.txt 40
mkdir -p "$R/tools"
printf 'vendor/* missing-tab-so-no-reason\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
rm "$R/tools/size-ratchet-excludes"
run_sr
[ "$RC" -eq 2 ] && case "$OUT" in *"(index copy):1: expected 'pattern<TAB>reason'"*) true ;; *) false ;; esac \
  && ok "a malformed index-copy row is a config error naming the copy and the line" \
  || bad "a malformed index-copy row is a config error" "rc=$RC out=$OUT"

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

echo "=== a row a change adds or raises is declared, and a frozen one is refused ==="
BASE="tools/size-ratchet-baseline.tsv"
commit_baselined() { # NAME PATH LINES ROWLINES — fixture whose HEAD carries the row
  new_repo "$1"
  mkdir -p "$R/tools"
  mkfile "$2" "$3"
  printf '%s\t%s\n' "$2" "$4" >"$R/$BASE"
  git -C "$R" add -A
  git -C "$R" commit -q -m "seed: a baselined offender"
}
commit_baselined testhead x.test.txt 15 15
run_frozen
[ "$RC" -eq 0 ] && ok "a row already at HEAD is grandfathered" \
  || bad "a row already at HEAD is grandfathered" "rc=$RC out=$OUT"
mkfile x.test.txt 20
printf 'x.test.txt\t20\n' >"$R/$BASE"
git -C "$R" add -A
run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"frozen baseline row raised: x.test.txt — row 15 -> 20 lines"*) true ;; *) false ;; esac \
  && ok "raising a frozen row fails, naming both counts" \
  || bad "raising a frozen row fails, naming both counts" "rc=$RC out=$OUT"
case "$OUT" in *"refuses a raise whatever RATCHET_RAISE says"*) ok "the raise diagnostic says the declaration will not help" ;; *) bad "the raise diagnostic says the declaration will not help" "$OUT" ;; esac
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && ok "and the declaration really does not help — a frozen raise is refused with it" \
  || bad "a frozen raise is refused even when declared" "rc=$RC out=$OUT"
# HEAD carries a baseline, but no row for this path: adding one is the same
# threshold routed around, and the declaration is what carries it.
commit_baselined testnew other.txt 15 15
mkfile y.test.txt 15
printf 'other.txt\t15\ny.test.txt\t15\n' >"$R/$BASE"
git -C "$R" add -A
run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline row added: y.test.txt — a first row, at 15 lines (threshold 10"*) true ;; *) false ;; esac \
  && ok "adding a row fails undeclared, naming the count and threshold" \
  || bad "adding a row fails undeclared, naming the count and threshold" "rc=$RC out=$OUT"
# The remedy on THIS verdict must name the declaration, because the
# declaration is what carries it — even here, in a frozen class.
case "$OUT" in *"remedy: split at a concept seam, or declare the row with RATCHET_RAISE=1"*) ok "and its remedy names the declaration a bootstrap row needs" ;; *) bad "the added-row remedy names RATCHET_RAISE=1" "$OUT" ;; esac
# A new path still gets its bootstrap row: the frozen list refuses raises, not
# first rows.
RAISE=1 run_frozen
[ "$RC" -eq 0 ] && ok "a declared bootstrap row passes even in a frozen class" \
  || bad "a declared bootstrap row passes even in a frozen class" "rc=$RC out=$OUT"
# The control that the frozen list is doing anything at all: the SAME path, a
# row later, RAISED rather than bootstrapped, with the same declaration.
git -C "$R" commit -q -m "the bootstrap row, now HEAD's"
mkfile y.test.txt 20
printf 'other.txt\t15\ny.test.txt\t20\n' >"$R/$BASE"
git -C "$R" add -A
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"frozen baseline row raised: y.test.txt — row 15 -> 20 lines"*) true ;; *) false ;; esac \
  && ok "control: raising that same frozen row is refused under the same declaration" \
  || bad "control: a frozen RAISE is refused where the bootstrap passed" "rc=$RC out=$OUT"
# And the remedy each verdict prints is the one that would work.
case "$OUT" in *"remedy: split at a concept seam (a frozen class never raises an existing row)"*) ok "and its remedy is the split, not a declaration that will not help" ;; *) bad "the frozen raise remedy is the split alone" "$OUT" ;; esac
# The control that this gate is not frozen-class only: an ordinary row is
# refused undeclared and passes declared.
commit_baselined nontest plain.txt 15 15
mkfile plain.txt 20
printf 'plain.txt\t20\n' >"$R/$BASE"
git -C "$R" add -A
run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline row raised: plain.txt — row 15 -> 20 lines"*) true ;; *) false ;; esac \
  && ok "raising an unfrozen row is refused undeclared" \
  || bad "raising an unfrozen row is refused undeclared" "rc=$RC out=$OUT"
RAISE=1 run_frozen
[ "$RC" -eq 0 ] && ok "control: the declaration carries an unfrozen raise" \
  || bad "control: the declaration carries an unfrozen raise" "rc=$RC out=$OUT"
# A row for a file at or under its threshold is stale, and stale is the one
# thing to say about it.
commit_baselined stale z.test.txt 15 15
mkfile z.test.txt 5
git -C "$R" add -A
run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"stale baseline row: z.test.txt"*) true ;; *) false ;; esac \
  && ok "a row under the threshold is stale" \
  || bad "a row under the threshold is stale" "rc=$RC out=$OUT"
case "$OUT" in *"row raised"* | *"row added"*) bad "one root cause is reported once" "$OUT" ;; *) ok "one root cause is reported once" ;; esac
# A hand edit is the only way to a bigger number, and a hand edit is where a
# file with no final newline comes from — so the LAST row is exactly the one a
# dropped incomplete line would stop judging, silently and with exit 0.
new_repo nofinalnewline
mkdir -p "$R/tools"
mkfile aaa.rs 15
mkfile zzz.rs 20
printf 'aaa.rs\t15\nzzz.rs\t15\n' >"$R/$BASE"
git -C "$R" add -A
git -C "$R" commit -q -m "seed: two baselined offenders"
printf 'aaa.rs\t15\nzzz.rs\t20' >"$R/$BASE"
git -C "$R" add -A
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline row raised: zzz.rs — row 15 -> 20 lines"*) true ;; *) false ;; esac \
  && ok "a raise on the last row is judged even with no trailing newline" \
  || bad "the last row of a newline-less baseline is judged" "rc=$RC out=$OUT"
# The control: the identical baseline WITH the newline reports the same thing,
# so the case above is about the missing byte and nothing else.
printf 'aaa.rs\t15\nzzz.rs\t20\n' >"$R/$BASE"
git -C "$R" add -A
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline row raised: zzz.rs — row 15 -> 20 lines"*) true ;; *) false ;; esac \
  && ok "control: the same rows with the newline give the same verdict" \
  || bad "control: the newline-terminated baseline gives the same verdict" "rc=$RC out=$OUT"

# A placeholder committed empty is not a row set: judging against it would
# call every row of the first real baseline one this change added.
new_repo emptyhead
mkdir -p "$R/tools"
: >"$R/$BASE"
mkfile keep.txt 5
git -C "$R" add -A
git -C "$R" commit -q -m "seed: an empty baseline placeholder"
mkfile w.test.txt 15
printf 'w.test.txt\t15\n' >"$R/$BASE"
git -C "$R" add -A
run_frozen
[ "$RC" -eq 0 ] && ok "a zero-row HEAD baseline is no baseline, so the first row passes undeclared" \
  || bad "a zero-row HEAD baseline is no baseline, so the first row passes undeclared" "rc=$RC out=$OUT"

echo "=== a commit that MOVES the baseline is refused, in both classes ==="
# The raise gate reads HEAD at the CONFIGURED path. Move that path and HEAD
# carries nothing there, so a raised row — a frozen one included — would land
# with nothing to compare it against. The move is refused instead.
settings_baseline() { # PATH — the fixture's committed settings name it
  printf '[env]\nSIZE_RATCHET_BASELINE = "%s"\n' "$1" >"$R/kendex.settings.toml"
}
relocating_repo() { # NAME PATH LINES ROWLINES — HEAD's rows at tools/a.tsv
  new_repo "$1"
  mkdir -p "$R/tools"
  mkfile "$2" "$3"
  printf '%s\t%s\n' "$2" "$4" >"$R/tools/a.tsv"
  settings_baseline tools/a.tsv
  git -C "$R" add -A
  git -C "$R" commit -q -m "seed: a baselined offender, baseline at tools/a.tsv"
}
relocate() { # PATH ROWLINES — the rows move to tools/b.tsv at ROWLINES
  printf '%s\t%s\n' "$1" "$2" >"$R/tools/b.tsv"
  rm -f "$R/tools/a.tsv"
  settings_baseline tools/b.tsv
  git -C "$R" add -A
}
relocating_repo relocfrozen x.test.txt 15 15
relocate x.test.txt 15
run_frozen
[ "$RC" -eq 0 ] && ok "control: a move that carries the rows unchanged passes" \
  || bad "a move that carries the rows unchanged passes" "rc=$RC out=$OUT"
mkfile x.test.txt 20
relocate x.test.txt 20
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline moved and rewritten: tools/a.tsv -> tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "a frozen row raised across the move is refused, declaration and all" \
  || bad "a frozen raise across a move is refused" "rc=$RC out=$OUT"
case "$OUT" in *"move the baseline in a commit that changes nothing else"*) ok "and the refusal says what to do instead" ;; *) bad "the move refusal names its remedy" "$OUT" ;; esac
# The open class takes the same refusal, and this is where it differs from an
# in-place raise: there the declaration carries it, across a move nothing does.
relocating_repo relocopen plain.txt 15 15
mkfile plain.txt 20
relocate plain.txt 20
run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline moved and rewritten: tools/a.tsv -> tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "an unfrozen row raised across the move is refused undeclared" \
  || bad "an unfrozen raise across a move is refused undeclared" "rc=$RC out=$OUT"
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && ok "and the declaration does not carry it, where in place it would" \
  || bad "the declaration does not carry a raise across a move" "rc=$RC out=$OUT"
# A `git mv` is the same move, and rename detection must not hide it. Four
# rows with one raised keeps the two files similar enough that git pairs them,
# which is exactly when a rename-detecting listing reports no removal at all.
new_repo relocgitmv
mkdir -p "$R/tools"
for f in m p1 p2 p3; do mkfile "$f.test.txt" 15; done
printf 'm.test.txt\t15\np1.test.txt\t15\np2.test.txt\t15\np3.test.txt\t15\n' >"$R/tools/a.tsv"
settings_baseline tools/a.tsv
git -C "$R" add -A
git -C "$R" commit -q -m "seed: four baselined offenders at tools/a.tsv"
mkfile m.test.txt 20
git -C "$R" mv tools/a.tsv tools/b.tsv
printf 'm.test.txt\t20\np1.test.txt\t15\np2.test.txt\t15\np3.test.txt\t15\n' >"$R/tools/b.tsv"
settings_baseline tools/b.tsv
git -C "$R" add -A
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline moved and rewritten: tools/a.tsv -> tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "a git mv of the baseline is the same move, not a rename that hides it" \
  || bad "a git mv of the baseline is the same move" "rc=$RC out=$OUT"
# The staged lane reads the index, and a commit is what it judges.
relocating_repo relocstaged s.test.txt 15 15
mkfile s.test.txt 20
relocate s.test.txt 20
RAISE=1 run_frozen --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline moved and rewritten: tools/a.tsv -> tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "the staged lane refuses the same move" \
  || bad "the staged lane refuses the same move" "rc=$RC out=$OUT"
# Rows at the destination are not proof they were the baseline HEAD used. A
# b.tsv that already existed carries its own, and comparing against those is
# how a raise reads as grandfathered while HEAD's real row said 15.
new_repo relocpreexisting
mkdir -p "$R/tools"
mkfile x.test.txt 15
printf 'x.test.txt\t15\n' >"$R/tools/a.tsv"
printf 'x.test.txt\t20\n' >"$R/tools/b.tsv"
settings_baseline tools/a.tsv
git -C "$R" add -A
git -C "$R" commit -q -m "seed: the baseline at tools/a.tsv, a tools/b.tsv already beside it"
mkfile x.test.txt 20
rm -f "$R/tools/a.tsv"
settings_baseline tools/b.tsv
git -C "$R" add -A
RAISE=1 run_frozen --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline moved and rewritten: tools/a.tsv -> tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "a destination that already carried rows is still a move, not a grandfathered row" \
  || bad "a destination that already carried rows is still a move" "rc=$RC out=$OUT"
# Emptying the old baseline in place is the same move, and reports as a
# modification rather than a removal.
new_repo relocemptied
mkdir -p "$R/tools"
mkfile y.test.txt 15
printf 'y.test.txt\t15\n' >"$R/tools/a.tsv"
settings_baseline tools/a.tsv
git -C "$R" add -A
git -C "$R" commit -q -m "seed: the baseline at tools/a.tsv"
mkfile y.test.txt 20
: >"$R/tools/a.tsv"
printf 'y.test.txt\t20\n' >"$R/tools/b.tsv"
settings_baseline tools/b.tsv
git -C "$R" add -A
RAISE=1 run_frozen --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline moved and rewritten: tools/a.tsv -> tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "emptying the old baseline in place is a move, not a modification to ignore" \
  || bad "emptying the old baseline in place is a move" "rc=$RC out=$OUT"
# Replacing the old baseline with a symlink to the NEW one leaves a path that
# reads through as rows, which is how the move looked untouched. A symlink is
# not the row set that was there, whatever it points at. Both modes are run on
# one tree, because the defect was that they disagreed: the index records mode
# 120000 and answered no already, the worktree followed the link.
new_repo relocsymlinkover
mkdir -p "$R/tools"
mkfile x.test.txt 15
printf 'x.test.txt\t15\n' >"$R/tools/a.tsv"
settings_baseline tools/a.tsv
git -C "$R" add -A
git -C "$R" commit -q -m "seed: the baseline at tools/a.tsv"
mkfile x.test.txt 20
printf 'x.test.txt\t20\n' >"$R/tools/b.tsv"
rm -f "$R/tools/a.tsv"
ln -s b.tsv "$R/tools/a.tsv"
settings_baseline tools/b.tsv
git -C "$R" add -A
RAISE=1 run_frozen
WORKTREE_RC="$RC"
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline moved and rewritten: tools/a.tsv -> tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "a symlink over the old baseline is not the row set that was there" \
  || bad "a symlink over the old baseline is not the row set that was there" "rc=$RC out=$OUT"
RAISE=1 run_frozen --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline moved and rewritten: tools/a.tsv -> tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "and the staged lane says the same of the same tree" \
  || bad "the staged lane refuses the symlinked move" "rc=$RC out=$OUT"
[ "$WORKTREE_RC" -eq "$RC" ] \
  && ok "control: the two modes agree on that tree, which is the whole finding" \
  || bad "the two modes agree on the symlinked move" "worktree=$WORKTREE_RC staged=$RC"

# …and the predicate that keeps the wider list honest: a row-shaped file whose
# numbers move is still a row set, so an ordinary edit of one is not a move.
new_repo rowshapededit
mkdir -p "$R/tools"
mkfile e.test.txt 15
printf 'e.test.txt\t15\n' >"$R/$BASE"
printf 'counts/thing\t3\n' >"$R/data.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m "seed: a baseline, and a row-shaped file that is not one"
printf 'counts/thing\t4\n' >"$R/data.tsv"
git -C "$R" add -A
run_frozen
[ "$RC" -eq 0 ] && ok "control: editing a row-shaped file leaves a row set, so it is no move" \
  || bad "control: editing a row-shaped file is no move" "rc=$RC out=$OUT"

# git spells a non-ASCII path C-quoted by default, so a listing read as text
# hands the probe `"tools/\303\251.tsv"` and the moved baseline reads as absent.
new_repo relocquoted
mkdir -p "$R/tools"
mkfile x.test.txt 15
printf 'x.test.txt\t15\n' >"$R/tools/é.tsv"
settings_baseline "tools/é.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m "seed: a baseline at a path git would quote"
mkfile x.test.txt 20
printf 'x.test.txt\t20\n' >"$R/tools/b.tsv"
rm -f "$R/tools/é.tsv"
settings_baseline tools/b.tsv
git -C "$R" add -A
RAISE=1 run_frozen --staged
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline moved and rewritten: tools/é.tsv -> tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "a baseline at a path git quotes is still seen leaving" \
  || bad "a baseline at a path git quotes is seen leaving" "rc=$RC out=$OUT"
# The sharper shape: a path may hold a NEWLINE, which is what a listing split on
# newlines — or one translating NULs into them — turns into two paths that HEAD
# carries no row set at. Only NUL delimits a path safely.
new_repo relocnewline
mkdir -p "$R/tools"
mkfile x.test.txt 15
NLPATH="$(printf 'tools/a\nb.tsv')"
printf 'x.test.txt\t15\n' >"$R/$NLPATH"
git -C "$R" add -A
git -C "$R" commit -q -m "seed: a row set at a path holding a newline"
mkfile x.test.txt 20
printf 'x.test.txt\t20\n' >"$R/tools/b.tsv"
rm -f "$R/$NLPATH"
settings_baseline tools/b.tsv
git -C "$R" add -A
RAISE=1 run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"baseline moved and rewritten"*"-> tools/b.tsv"*) true ;; *) false ;; esac \
  && ok "a baseline at a path holding a newline is still seen leaving" \
  || bad "a baseline at a path holding a newline is seen leaving" "rc=$RC out=$OUT"

# A removed file that is not a row set is not a moved baseline: the check reads
# the row shape, so an ordinary deletion beside a first baseline stays a
# bootstrap.
new_repo notabaseline
mkdir -p "$R/tools"
mkfile n.test.txt 5
printf 'some prose, not a row\n' >"$R/notes.txt"
git -C "$R" add -A
git -C "$R" commit -q -m "seed: no baseline, one ordinary file"
mkfile n.test.txt 15
printf 'n.test.txt\t15\n' >"$R/tools/b.tsv"
rm -f "$R/notes.txt"
settings_baseline tools/b.tsv
git -C "$R" add -A
run_frozen
[ "$RC" -eq 0 ] && ok "a removed file that is not a row set is not a moved baseline" \
  || bad "a removed file that is not a row set is not a moved baseline" "rc=$RC out=$OUT"

echo "=== and the three bootstraps still pass: none of them removes a row set ==="
# Each legitimately leaves HEAD with no rows at the configured path, and each
# is what refusing on that emptiness alone would break.
new_repo bootunborn
mkdir -p "$R/tools"
mkfile u.test.txt 15
printf 'u.test.txt\t15\n' >"$R/tools/b.tsv"
settings_baseline tools/b.tsv
git -C "$R" add -A
run_frozen
[ "$RC" -eq 0 ] && ok "an unborn HEAD bootstraps a first baseline at a configured path" \
  || bad "an unborn HEAD bootstraps a first baseline" "rc=$RC out=$OUT"
new_repo bootintroduced
mkfile v.test.txt 5
git -C "$R" add -A
git -C "$R" commit -q -m "seed: a repo with no baseline at all"
mkdir -p "$R/tools"
mkfile v.test.txt 15
printf 'v.test.txt\t15\n' >"$R/tools/b.tsv"
settings_baseline tools/b.tsv
git -C "$R" add -A
run_frozen
[ "$RC" -eq 0 ] && ok "a baseline this change introduces bootstraps, path and all" \
  || bad "a baseline this change introduces bootstraps" "rc=$RC out=$OUT"
relocating_repo bootplaceholder w.test.txt 5 5
: >"$R/tools/a.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m "the baseline, emptied to a placeholder"
mkfile w.test.txt 15
relocate w.test.txt 15
run_frozen
[ "$RC" -eq 0 ] && ok "a HEAD baseline committed empty is no row set, wherever the path moves" \
  || bad "an empty HEAD baseline is no row set across a relocation" "rc=$RC out=$OUT"
case "$OUT" in *"HEAD carries no baseline rows, so added and raised rows were not judged"*) ok "and a bootstrap still says the check had no reference" ;; *) bad "a bootstrap still reports that nothing was judged" "$OUT" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
