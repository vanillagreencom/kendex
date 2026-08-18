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

new_repo settings-probe-failure
mkfile big.txt 200
printf '[env]\nSIZE_RATCHET_THRESHOLD = "100"\n' >"$R/vstack.settings.toml"
git -C "$R" add -A
git -C "$R" commit -q -m seed
OUT=""; RC=0
OUT="$(cd "$R" && "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && case "$OUT" in *"threshold 100"*) true ;; *) false ;; esac \
  && ok "control: the committed threshold of 100 rejects the 200-line blob" \
  || bad "committed threshold rejects (probe control)" "rc=$RC out=$OUT"
# The staged-source probe asks the index whether a settings file is tracked.
# `--error-unmatch` reserves exit 1 for "no such path"; reading EVERY nonzero
# status as "untracked" let a broken git drop the committed threshold back to
# the built-in 400 and pass the 200-line offender.
REAL_GIT="$(command -v git)"
GIT_TRACKED_SHIM="$TMP/git-tracked-shim"
mkdir -p "$GIT_TRACKED_SHIM"
cat >"$GIT_TRACKED_SHIM/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "ls-files" ] && [ "\${2:-}" = "--error-unmatch" ]; then
  echo "fatal: simulated index-probe failure" >&2
  exit 71
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GIT_TRACKED_SHIM/git"
OUT=""; RC=0
OUT="$(cd "$R" && PATH="$GIT_TRACKED_SHIM:$PATH" "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not query the index while resolving a setting"*) true ;; *) false ;; esac \
  && ok "a failing tracked-source probe is exit 2, never a silent fall back to the built-in threshold" \
  || bad "settings probe failure" "rc=$RC out=$OUT"
# A settings source that cannot be an index entry — absolute, or escaping the
# root — draws git's "outside repository" refusal, which carries the same 128
# an operational failure does. It is answered before the probe, so such a
# source still reads from the worktree instead of failing the run.
printf '[env]\nSIZE_RATCHET_THRESHOLD = "5"\n' >"$TMP/outside-settings.toml"
for path in "$TMP/outside-settings.toml" "../outside-settings.toml"; do
  OUT=""; RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_SETTINGS_FILE="$path" "$SR" --staged 2>&1)" || RC=$?
  [ "$RC" -eq 1 ] && case "$OUT" in *"threshold 5"*) true ;; *) false ;; esac \
    && ok "an out-of-repo settings source still reads under --staged ($path)" \
    || bad "out-of-repo settings source" "path=$path rc=$RC out=$OUT"
done

# …but a `..` that NORMALIZES back inside is an ordinary index entry, and the
# answer-before-probe shortcut must not swallow it: sub/../vstack.settings.toml
# IS the committed settings file, so reading the worktree copy there handed
# the unstaged threshold bump exactly the authority --staged removes.
new_repo settings-dotdot
mkdir -p "$R/sub"
mkfile big.txt 200
mkfile sub/keep.txt 1
printf '[env]\nSIZE_RATCHET_THRESHOLD = "100"\n' >"$R/vstack.settings.toml"
git -C "$R" add -A
git -C "$R" commit -q -m seed
# Raised on disk only: the commit still carries 100, so the 200-line blob
# fails however the settings path is spelled.
printf '[env]\nSIZE_RATCHET_THRESHOLD = "300"\n' >"$R/vstack.settings.toml"
for path in "vstack.settings.toml" "sub/../vstack.settings.toml" "./vstack.settings.toml" "a/b/../../vstack.settings.toml"; do
  OUT=""; RC=0
  OUT="$(cd "$R" && SIZE_RATCHET_SETTINGS_FILE="$path" "$SR" --staged 2>&1)" || RC=$?
  [ "$RC" -eq 1 ] && case "$OUT" in *"threshold 100"*) true ;; *) false ;; esac \
    && ok "the committed threshold governs a path spelled '$path'" \
    || bad "dot-dot settings path resolves to the index" "path=$path rc=$RC out=$OUT"
done
# Control: a path that STILL escapes once normalized keeps the worktree lane
# — it reads the out-of-repo file ($TMP/outside-settings.toml, threshold 5,
# written above) rather than resolving to anything in the index.
OUT=""; RC=0
OUT="$(cd "$R" && SIZE_RATCHET_SETTINGS_FILE="sub/../../outside-settings.toml" "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && case "$OUT" in *"threshold 5"*) true ;; *) false ;; esac \
  && ok "control: a path that still escapes once normalized reads the out-of-repo file" \
  || bad "normalized escape stays out-of-repo" "rc=$RC out=$OUT"

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

echo "=== a failing HEAD probe cannot hand authority to a recreated source ==="
# Staged deletion + worktree recreation: the commit carries threshold 100,
# the deletion is staged, and a recreated worktree copy says 300. The HEAD
# probe is what proves the commit once carried the source; a broken git
# there must fail closed, never read as "never tracked" and let the
# recreated copy authorize the staged 200-line blob.
new_repo settings-recreated
mkfile big.txt 200
printf '[env]\nSIZE_RATCHET_THRESHOLD = "100"\n' >"$R/vstack.settings.toml"
git -C "$R" add -A
git -C "$R" commit -q -m seed
git -C "$R" rm -q --cached vstack.settings.toml
printf '[env]\nSIZE_RATCHET_THRESHOLD = "300"\n' >"$R/vstack.settings.toml"
OUT=""; RC=0
OUT="$(cd "$R" && "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 0 ] \
  && ok "control: a staged settings deletion governs as absent (built-in 400 passes the 200-line blob)" \
  || bad "staged-deletion control" "rc=$RC out=$OUT"
REAL_GIT="$(command -v git)"
GIT_HEAD_SHIM="$TMP/git-head-shim"
mkdir -p "$GIT_HEAD_SHIM"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "${1:-}" = "ls-tree" ]; then\n'
  printf '  echo "fatal: simulated HEAD-tree failure" >&2\n'
  printf '  exit 71\n'
  printf 'fi\n'
  printf 'exec %s "$@"\n' "$REAL_GIT"
} >"$GIT_HEAD_SHIM/git"
chmod +x "$GIT_HEAD_SHIM/git"
OUT=""; RC=0
OUT="$(cd "$R" && PATH="$GIT_HEAD_SHIM:$PATH" "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not probe HEAD while resolving a setting (git ls-tree"*) true ;; *) false ;; esac \
  && ok "a failing settings HEAD probe is exit 2, never authority for the recreated copy" \
  || bad "settings HEAD-probe failure" "rc=$RC out=$OUT"

echo "=== the policy HEAD leg fails closed too ==="
# Same shape for the baseline: staged deletion + recreated worktree copy.
# The classified probe (ls-tree) failing must be exit 2; the old bare
# cat-file read a broken git as "never tracked" and let the recreated
# baseline absorb staged growth.
new_repo baseline-recreated
mkfile big.txt 30
mkdir -p "$R/tools"
printf 'big.txt\t15\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m seed
git -C "$R" rm -q --cached tools/size-ratchet-baseline.tsv
printf 'big.txt\t30\n' >"$R/tools/size-ratchet-baseline.tsv"
OUT=""; RC=0
GIT_CATFILE_SHIM="$TMP/git-catfile-shim"
mkdir -p "$GIT_CATFILE_SHIM"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "${1:-}" = "cat-file" ]; then\n'
  printf '  echo "fatal: simulated HEAD-probe failure" >&2\n'
  printf '  exit 71\n'
  printf 'fi\n'
  printf 'exec %s "$@"\n' "$REAL_GIT"
} >"$GIT_CATFILE_SHIM/git"
chmod +x "$GIT_CATFILE_SHIM/git"
OUT="$(cd "$R" && PATH="$GIT_CATFILE_SHIM:$PATH" SIZE_RATCHET_THRESHOLD=10 "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 1 ] \
  && ok "a broken cat-file no longer hands authority to the recreated baseline (the staged snapshot judges without it)" \
  || bad "recreated baseline under cat-file failure" "rc=$RC out=$OUT"
GIT_TREE_SHIM="$TMP/git-tree-shim"
mkdir -p "$GIT_TREE_SHIM"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "${1:-}" = "ls-tree" ]; then\n'
  printf '  echo "fatal: simulated HEAD-tree failure" >&2\n'
  printf '  exit 71\n'
  printf 'fi\n'
  printf 'exec %s "$@"\n' "$REAL_GIT"
} >"$GIT_TREE_SHIM/git"
chmod +x "$GIT_TREE_SHIM/git"
OUT=""; RC=0
OUT="$(cd "$R" && PATH="$GIT_TREE_SHIM:$PATH" SIZE_RATCHET_THRESHOLD=10 "$SR" --staged 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"(git ls-tree exit 71)"*) true ;; *) false ;; esac \
  && ok "a failing HEAD-tree query is exit 2, never \"never tracked\"" \
  || bad "policy HEAD-probe failure" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
