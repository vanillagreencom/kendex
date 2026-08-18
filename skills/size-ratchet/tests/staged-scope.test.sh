#!/usr/bin/env bash
# Pins for --staged: the gate must judge the blobs a commit records, not the
# worktree copies. Each direction carries the default-mode control that shows
# the two really differ.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SR="$SKILL_DIR/scripts/size-ratchet"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sr-staged.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME — fresh fixture repo in $R
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

mkfile() { # PATH LINES
  mkdir -p "$R/$(dirname "$1")"
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' >"$R/$1"
}

run_sr() { # [args...] — threshold 10; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 "$SR" "$@" 2>&1)" || RC=$?
}

echo "=== control: a clean tree passes in both modes ==="
new_repo clean
mkfile a.txt 5
git -C "$R" add -A
run_sr
[ "$RC" -eq 0 ] && ok "default mode passes" || bad "default mode passes" "rc=$RC out=$OUT"
run_sr --staged
[ "$RC" -eq 0 ] && ok "--staged passes" || bad "--staged passes" "rc=$RC out=$OUT"

echo "=== staged growth hidden by a reverted worktree copy ==="
new_repo hidden
mkfile a.txt 5
git -C "$R" add -A
git -C "$R" commit -q -m seed
mkfile a.txt 40
git -C "$R" add a.txt
mkfile a.txt 5
run_sr
[ "$RC" -eq 0 ] && ok "control: the default mode sees only the worktree copy and passes" \
  || bad "default mode passes on hidden growth" "rc=$RC out=$OUT"
run_sr --staged
[ "$RC" -eq 1 ] && ok "--staged fails on the staged blob" || bad "--staged fails on staged blob" "rc=$RC out=$OUT"
case "$OUT" in
  *"new offender: a.txt"*) ok "--staged names the offending path" ;;
  *) bad "--staged names the path" "out=$OUT" ;;
esac

echo "=== worktree growth that is NOT staged ==="
new_repo unstaged
mkfile a.txt 5
git -C "$R" add -A
git -C "$R" commit -q -m seed
mkfile a.txt 40
run_sr
[ "$RC" -eq 1 ] && ok "control: the default mode fails on the worktree copy" || bad "default fails on worktree growth" "rc=$RC out=$OUT"
run_sr --staged
[ "$RC" -eq 0 ] && ok "--staged passes: nothing oversized is being committed" || bad "--staged passes unstaged growth" "rc=$RC out=$OUT"

echo "=== --staged still reads the baseline and its directions ==="
new_repo baselined
mkfile big.txt 40
mkdir -p "$R/tools"
printf 'big.txt\t40\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m seed
run_sr --staged
[ "$RC" -eq 0 ] && ok "a baselined blob at its row passes" || bad "baselined blob passes" "rc=$RC out=$OUT"
mkfile big.txt 41
git -C "$R" add big.txt
mkfile big.txt 40
run_sr --staged
[ "$RC" -eq 1 ] && ok "staged growth past the row fails" || bad "staged growth past row fails" "rc=$RC out=$OUT"

echo "=== staged mode reads tracked policy from the index too ==="
new_repo policy
mkdir -p "$R/tools"
mkfile big.txt 20
printf 'big.txt\t20\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m seed
mkfile big.txt 30
git -C "$R" add big.txt
# An unstaged baseline bump must not authorize the staged growth: the commit
# carries the old row.
printf 'big.txt\t30\n' >"$R/tools/size-ratchet-baseline.tsv"
run_sr --staged
[ "$RC" -eq 1 ] && ok "an unstaged baseline bump does not authorize staged growth" \
  || bad "unstaged baseline bump rejected" "rc=$RC out=$OUT"
git -C "$R" add tools/size-ratchet-baseline.tsv
run_sr --staged
[ "$RC" -eq 0 ] && ok "control: staging the baseline row alongside it passes" \
  || bad "staged baseline row passes" "rc=$RC out=$OUT"

new_repo policy-excludes
mkdir -p "$R/tools"
mkfile big.txt 30
printf '# nothing excluded\n' >"$R/tools/size-ratchet-excludes"
git -C "$R" add -A
git -C "$R" commit -q -m seed
printf 'big.txt\tunstaged exclusion\n' >"$R/tools/size-ratchet-excludes"
run_sr --staged
[ "$RC" -eq 1 ] && ok "an unstaged exclusion does not silence the staged blob" \
  || bad "unstaged exclusion ignored" "rc=$RC out=$OUT"
git -C "$R" add tools/size-ratchet-excludes
run_sr --staged
[ "$RC" -eq 0 ] && ok "control: staging the exclusion applies it" || bad "staged exclusion applies" "rc=$RC out=$OUT"

echo "=== a policy file staged for deletion governs as absent ==="
new_repo policy-deleted
mkdir -p "$R/tools"
mkfile big.txt 40
printf 'big.txt\t40\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m seed
git -C "$R" rm -q --cached tools/size-ratchet-baseline.tsv
# Recreated on disk only: the commit deletes the baseline, so nothing is
# frozen and the over-threshold blob is a new offender again.
printf 'big.txt\t40\n' >"$R/tools/size-ratchet-baseline.tsv"
run_sr --staged
[ "$RC" -eq 1 ] && ok "a baseline staged for deletion no longer freezes anything" \
  || bad "staged baseline deletion" "rc=$RC out=$OUT"
run_sr
[ "$RC" -eq 0 ] && ok "control: the default mode still reads the worktree copy" \
  || bad "default mode reads worktree baseline" "rc=$RC out=$OUT"

echo "=== staged mode reads tracked settings from the index ==="
new_repo policy-settings
mkfile big.txt 8
printf '[env]\nSIZE_RATCHET_THRESHOLD = "5"\n' >"$R/vstack.settings.toml"
git -C "$R" add -A
git -C "$R" commit -q -m seed
OUT=""; RC=0
OUT="$(cd "$R" && "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "control: the committed threshold rejects the file" || bad "committed threshold rejects" "rc=$RC out=$OUT"
# Raised on disk only: the commit still carries a threshold of 5.
printf '[env]\nSIZE_RATCHET_THRESHOLD = "10"\n' >"$R/vstack.settings.toml"
OUT=""; RC=0
OUT="$(cd "$R" && "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "an unstaged threshold bump does not authorize the staged file" \
  || bad "unstaged threshold bump rejected" "rc=$RC out=$OUT"
git -C "$R" add vstack.settings.toml
OUT=""; RC=0
OUT="$(cd "$R" && "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: staging the threshold applies it" || bad "staged threshold applies" "rc=$RC out=$OUT"
OUT=""; RC=0
OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=10 "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "an explicit environment override still wins" || bad "env override wins" "rc=$RC out=$OUT"

new_repo settings-deleted
mkfile big.txt 8
printf '[env]\nSIZE_RATCHET_THRESHOLD = "10"\n' >"$R/vstack.settings.toml"
git -C "$R" add -A
git -C "$R" commit -q -m seed
OUT=""; RC=0
OUT="$(cd "$R" && "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: the committed threshold admits the file" || bad "committed threshold admits" "rc=$RC out=$OUT"
git -C "$R" rm -q --cached vstack.settings.toml
# Recreated on disk only: the commit deletes the settings, so the built-in
# default threshold applies and the file is a new offender.
printf '[env]\nSIZE_RATCHET_THRESHOLD = "10"\n' >"$R/vstack.settings.toml"
OUT=""; RC=0
OUT="$(cd "$R" && SIZE_RATCHET_THRESHOLD=5 "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "control: the file is over the lower threshold" || bad "lower threshold rejects" "rc=$RC out=$OUT"
OUT=""; RC=0
OUT="$(cd "$R" && "$SR" --staged --baseline tools/none.tsv 2>&1)" || RC=$?
case "$OUT" in
  *"threshold 400"*) ok "a settings source staged for deletion governs as absent (built-in default applies)" ;;
  *) bad "staged settings deletion" "rc=$RC out=$OUT" ;;
esac

new_repo settings-symlink
mkfile big.txt 8
printf '[env]\nSIZE_RATCHET_THRESHOLD = "5"\n' >"$R/real-settings.toml"
ln -s real-settings.toml "$R/vstack.settings.toml"
git -C "$R" add -A
git -C "$R" commit -q -m seed
run_sr --staged
[ "$RC" -eq 2 ] && ok "a settings source tracked as a symlink is a loud exit 2" \
  || bad "symlinked settings is exit 2" "rc=$RC out=$OUT"
case "$OUT" in
  *"tracked as a symlink"*) ok "and the diagnostic says why" ;;
  *) bad "symlinked settings diagnostic" "out=$OUT" ;;
esac

new_repo staged-update
mkdir -p "$R/tools"
mkfile big.txt 40
mkfile also.txt 30
printf 'big.txt\t40\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m seed
# An unstaged freeze row must survive an --update even under --staged, which
# rewrites the worktree file it therefore has to read.
printf 'also.txt\t30\nbig.txt\t40\n' >"$R/tools/size-ratchet-baseline.tsv"
run_sr --staged --update
[ "$RC" -eq 0 ] && ok "--staged --update keeps an unstaged freeze row" \
  || bad "staged update keeps unstaged row" "rc=$RC row=$(cat "$R/tools/size-ratchet-baseline.tsv") out=$OUT"
case "$(cat "$R/tools/size-ratchet-baseline.tsv")" in
  *also.txt*) ok "and the row is still in the file it rewrote" ;;
  *) bad "staged update preserves the row" "got: $(cat "$R/tools/size-ratchet-baseline.tsv")" ;;
esac

new_repo staged-update-settings
mkdir -p "$R/tools"
mkfile big.txt 40
printf '[env]\nSIZE_RATCHET_BASELINE = "tools/a.tsv"\n' >"$R/vstack.settings.toml"
printf 'big.txt\t40\n' >"$R/tools/a.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m seed
# Unstaged redirect: update mode rewrites worktree policy, so the settings
# naming WHICH file it rewrites must come from the worktree too.
printf '[env]\nSIZE_RATCHET_BASELINE = "tools/b.tsv"\n' >"$R/vstack.settings.toml"
printf 'big.txt\t41\n' >"$R/tools/b.tsv"
run_sr --staged --update
[ "$(cat "$R/tools/b.tsv")" = "$(printf 'big.txt\t40')" ] \
  && ok "--staged --update tightens the baseline its own settings name" \
  || bad "staged update follows worktree settings" "a=$(cat "$R/tools/a.tsv") b=$(cat "$R/tools/b.tsv")"

new_repo settings-cache-collision
mkfile big.txt 8
mkdir -p "$R/_env"
# Two sources whose names collapse together under a lossy encoding: the one
# materialized first must not answer for the other.
printf 'UNRELATED_KEY=1\n' >"$R/.env.local"
printf '[env]\nSIZE_RATCHET_THRESHOLD = "5"\n' >"$R/_env/local"
git -C "$R" add -A
git -C "$R" commit -q -m seed
OUT=""; RC=0
OUT="$(cd "$R" && SIZE_RATCHET_SETTINGS_FILE=_env/local "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "an explicit settings file is not aliased by a same-encoding source" \
  || bad "settings cache collision" "rc=$RC out=$OUT"
case "$OUT" in
  *"threshold 5"*) ok "and its own threshold is the one applied" ;;
  *) bad "settings cache collision threshold" "out=$OUT" ;;
esac

echo "=== usage ==="
new_repo usage
git -C "$R" commit -q --allow-empty -m seed
run_sr --staged --bogus
[ "$RC" -eq 2 ] && ok "an unknown flag beside --staged is exit 2" || bad "unknown flag is exit 2" "rc=$RC out=$OUT"
OUT="$(cd "$R" && "$SR" --help 2>&1)" || bad "--help exits 0"
case "$OUT" in
  *--staged*) ok "--help documents --staged" ;;
  *) bad "--help documents --staged" "out=$OUT" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
