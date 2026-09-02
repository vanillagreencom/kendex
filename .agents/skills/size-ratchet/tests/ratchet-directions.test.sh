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
# The remedy for a verdict whose path carries NO row yet. Both such verdicts
# take it, frozen or not: the declaration admits a first row in every class.
BOOT="split at a concept seam, or declare the row with RATCHET_RAISE=1 — a first row for a path HEAD's baseline does not carry is a bootstrap, admitted in every class"

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
case "$OUT" in *"$BOOT"*) ok "new-offender diagnostic carries the bootstrap remedy verbatim" ;; *) bad "new-offender diagnostic carries the bootstrap remedy verbatim" "$OUT" ;; esac

echo "=== the freeze refuses a raise of an EXISTING row, and a new offender has none ==="
new_repo testoff
mkfile x.test.txt 11
git -C "$R" add -A
run_frozen
[ "$RC" -eq 1 ] && case "$OUT" in *"new offender: x.test.txt"*) true ;; *) false ;; esac \
  && ok "a frozen path over the threshold is still a new offender" \
  || bad "a frozen path over the threshold is still a new offender" "rc=$RC out=$OUT"
case "$OUT" in *"$BOOT"*) ok "and is offered the bootstrap: no row exists yet, so the freeze has none to refuse" ;; *) bad "a frozen new offender is offered the bootstrap" "$OUT" ;; esac
# The control: once the row EXISTS, the same frozen path is offered the split
# alone. That is the case the freeze speaks to, and the only one.
mkdir -p "$R/tools"
printf 'x.test.txt\t11\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m row
mkfile x.test.txt 15
git -C "$R" add -A
run_frozen
# Both halves: the string it IS given, and the absence of either wording that
# carries RATCHET_RAISE. Without the positive half an empty remedy passes.
if [ "$RC" -eq 1 ] && case "$OUT" in *"baselined file grew: x.test.txt"*) true ;; *) false ;; esac \
  && case "$OUT" in *"remedy: split at a concept seam (a frozen class never raises an existing row)"*) true ;; *) false ;; esac \
  && case "$OUT" in *RATCHET_RAISE*) false ;; *) true ;; esac; then
  ok "control: a frozen baselined file that grew is told to split, and offered no raise"
else
  bad "control: a frozen row refuses the raise" "rc=$RC out=$OUT"
fi

echo "=== a baseline row at the current count freezes the offender ==="
new_repo frozen
mkfile big.txt 15
mkdir -p "$R/tools"
printf 'big.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
# HEAD carries the row from here on, so a growth verdict below is a RAISE the
# remedy speaks to rather than a first row nothing has frozen yet.
git -C "$R" commit -q -m row
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
git -C "$R" commit -q -m row
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

echo "=== a ! row carves a subtree back into the measured set ==="
# A rendered install can only be named by a tree wildcard, and a repo that
# keeps hand-written source inside that tree — a skill declared
# `source = "in-place"` — needs a way to say so. Without it the coverage is
# silently absent, which is the fail-open direction for a gate.
new_repo carve
mkfile .agents/skills/rendered/big.txt 50   # a real render: stays excluded
mkfile .agents/skills/in-place/big.txt 50   # the source of record: carved back
mkdir -p "$R/tools"
printf '.agents/*\tkendex render, governed at its source\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A

# Control: the blanket row alone silences BOTH, which is the defect.
run_sr
[ "$RC" -eq 0 ] && ok "control: the blanket .agents/* row silences both trees" \
  || bad "control: the blanket .agents/* row silences both trees" "rc=$RC out=$OUT"

printf '.agents/*\tkendex render, governed at its source\n!.agents/skills/in-place/*\tin-place skill: this tree IS the source\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *".agents/skills/in-place/big.txt"*) true ;; *) false ;; esac \
  && ok "the carved tree is measured again and its offender is named" \
  || bad "the carved tree is measured again" "rc=$RC out=$OUT"
case "$OUT" in
  *".agents/skills/rendered/big.txt"*) bad "the carve must not widen past its own pattern" "$OUT" ;;
  *) ok "the sibling render under the same blanket row stays excluded" ;;
esac

# Order is not policy: the carve wins whether it precedes or follows the row
# it cuts into, so a list reads as a set of rules rather than as a sequence.
printf '!.agents/skills/in-place/*\tin-place skill: this tree IS the source\n.agents/*\tkendex render, governed at its source\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_sr
[ "$RC" -eq 1 ] && case "$OUT" in *".agents/skills/in-place/big.txt"*) true ;; *) false ;; esac \
  && ok "a carve above the row it cuts into carves just the same" \
  || bad "a carve above the row it cuts into carves just the same" "rc=$RC out=$OUT"

# A carve cannot pull the baseline into its own gate: the baseline is policy
# input, and measuring it would make every row it gains a violation. Both runs
# below share one baseline whose own 11 rows put it over this suite's
# threshold of 10, so a baseline that reached the gate would fail as a new
# offender — a shorter one would pass whether the exemption held or not. Every
# row names a measured file over the threshold, so none reads as stale.
for i in 1 2 3 4 5 6 7 8 9; do mkfile ".agents/skills/in-place/part$i.txt" 11; done
{
  printf '.agents/skills/in-place/big.txt\t50\n'
  for i in 1 2 3 4 5 6 7 8 9; do printf '.agents/skills/in-place/part%s.txt\t11\n' "$i"; done
  printf '.agents/skills/rendered/big.txt\t50\n'
} >"$R/tools/size-ratchet-baseline.tsv"

# No row here matches the baseline path, so the exemption is the only thing
# keeping it out ahead of the EXCLUSION match: move the exemption behind that
# match and the baseline is measured.
printf '!*\tcarve everything back in\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && case "$OUT" in *"tools/size-ratchet-baseline.tsv"*) false ;; *) true ;; esac \
  && ok "the baseline stays exempt ahead of the exclusion match, at 11 rows over the threshold" \
  || bad "the baseline stays exempt ahead of the exclusion match" "rc=$RC out=$OUT"

# `tools/*` excludes both policy files, so the EXCLUDES FILE reaches the carve
# list and the `!*` row pulls it back. The baseline never reaches that list,
# because its exemption is read first, which is what this run pins.
printf 'tools/*\tthe policy files themselves\n!*\tcarve everything back in\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && case "$OUT" in *"tools/size-ratchet-baseline.tsv"*) false ;; *) true ;; esac \
  && ok "the baseline stays exempt ahead of the carve match the excludes file reaches" \
  || bad "the baseline stays exempt ahead of the carve match" "rc=$RC out=$OUT"

# A bare '!' names nothing; silently keeping it would widen or narrow the
# scanned set by a typo.
printf '.agents/*\tkendex render\n!\ta carve with no pattern\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_sr
[ "$RC" -eq 2 ] && case "$OUT" in *":2: '!' carves"*) true ;; *) false ;; esac \
  && ok "a bare ! row is a config error naming its line" \
  || bad "a bare ! row is a config error naming its line" "rc=$RC out=$OUT"

# `!` is escapable, which is the only way left to name a path that literally
# begins with one: `\!name` opens with a backslash, so it never reaches the
# carve arm, and the case matcher reads it as that literal path.
new_repo bang
mkfile '!bang.txt' 11
mkdir -p "$R/tools"
printf '\\!bang.txt\tan escaped literal bang path\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && case "$OUT" in *"!bang.txt"*) false ;; *) true ;; esac \
  && ok "an escaped row excludes the literal bang path rather than carving it" \
  || bad "an escaped row excludes the literal bang path" "rc=$RC out=$OUT"

echo "=== --baseline flag relocates the baseline ==="
new_repo flagpath
mkfile big.txt 15
printf 'big.txt\t15\n' >"$R/custom-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m row
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

echo "=== a run with no HEAD reference says so on the verdict line ==="
# "No reference" passes, but it is not "checked and clean": the added and
# raised checks had nothing to judge against. A bare OK reads as clean, so the
# verdict discloses which of the two it is.
DISCLOSURE="HEAD carries no baseline rows, so added and raised rows were not judged"
new_repo bootstrap-disclosure
mkfile x.test.txt 15
git -C "$R" add -A
git -C "$R" commit -q -m "an offender, no baseline yet"
mkdir -p "$R/tools"
printf 'x.test.txt\t15\n' >"$R/$BASE"
git -C "$R" add -A
RAISE=1 run_frozen
[ "$RC" -eq 0 ] && case "$OUT" in *"size-ratchet: OK"*"$DISCLOSURE"*) true ;; *) false ;; esac \
  && ok "a first baseline passes, and the OK verdict says the added row went unjudged" \
  || bad "the OK verdict discloses that no HEAD reference judged the row" "rc=$RC out=$OUT"
# The control: the same repo and the same command one commit later, when HEAD
# DOES carry the row. Without it an unconditional clause would pass above.
git -C "$R" commit -q -m "the bootstrap row, now HEAD's"
run_frozen
[ "$RC" -eq 0 ] && case "$OUT" in *"$DISCLOSURE"*) false ;; *"size-ratchet: OK"*) true ;; *) false ;; esac \
  && ok "control: once HEAD carries the row, the ordinary OK verdict carries no such clause" \
  || bad "control: a run with a HEAD reference does not disclose" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
