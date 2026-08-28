#!/usr/bin/env bash
# Behavioral suite for scripts/mutation-stability: a killed mutant passes,
# a surviving (decoy) mutant fails, a red-before-mutation control refuses,
# and the summary line is the exact reported format.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MS="$SCRIPT_DIR/../scripts/mutation-stability"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; echo "        $2"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ms-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
printf 'add() { echo $(( $1 + $2 )); }\n' > "$REPO/lib.sh"
cat > "$REPO/check.sh" <<'T'
. ./lib.sh
[ "$(add 2 3)" = 5 ]
T
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm x
SHA=$(git -C "$REPO" rev-parse HEAD)

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'bash check.sh' \
      --mutate 'sed -i "s/+/-/" lib.sh' --stability 2 --threads 2) || rc=$?
if [ "$rc" = 0 ]; then ok "killed mutant exits 0"; else bad "killed mutant exits 0" "rc=$rc out=$out"; fi
case "$out" in "mutation: killed 1/1; stability: 2/2 at 2 threads") ok "summary line is the exact format";; *) bad "summary line is the exact format" "$out";; esac

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'bash check.sh' \
      --mutate 'echo "# decoy: still says +" >> lib.sh' --stability 1) || rc=$?
if [ "$rc" = 1 ]; then ok "surviving decoy mutant exits 1"; else bad "surviving decoy mutant exits 1" "rc=$rc out=$out"; fi
case "$out" in "mutation: killed 0/1;"*) ok "survivor reported as killed 0/1";; *) bad "survivor reported as killed 0/1" "$out";; esac

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'false' \
      --mutate 'true' --stability 1 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "red-before-mutation control exits 2"; else bad "red-before-mutation control exits 2" "rc=$rc"; fi
case "$out" in *"before any mutation"*) ok "control names the instrument failure";; *) bad "control names the instrument failure" "$out";; esac

# flaky test: passes only on its first run in a copy (state file marks reruns)
cat > "$REPO/check.sh" <<'T'
. ./lib.sh
[ "$(add 2 3)" = 5 ] || exit 1
[ ! -f .ran ] || exit 1
touch .ran
T
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm flaky
SHA2=$(git -C "$REPO" rev-parse HEAD)
rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA2" --test 'bash check.sh' \
      --mutate 'sed -i "s/+/-/" lib.sh' --stability 3 --threads 2) || rc=$?
if [ "$rc" = 1 ]; then ok "stability failure exits 1 even with the mutant killed"; else bad "stability failure exits 1 even with the mutant killed" "rc=$rc out=$out"; fi
case "$out" in *"stability: 1/3 at 2 threads") ok "partial stability is reported as Y/N";; *) bad "partial stability is reported as Y/N" "$out";; esac

rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA" --test 'bash check.sh' \
      --mutate 'true' --stability 0 2>&1) || rc=$?
if [ "$rc" = 2 ]; then ok "--stability 0 is refused as zero samples"; else bad "--stability 0 is refused as zero samples" "rc=$rc"; fi
rc=0; "$MS" --worktree "$REPO" --sha "$SHA" --test 'true' --mutate 2>/dev/null || rc=$?
if [ "$rc" = 2 ]; then ok "a value-less option exits 2"; else bad "a value-less option exits 2" "rc=$rc"; fi

# A build cache the caller shares across both copies must not hand the clean
# run the mutant's artifact. git archive stamps every file with the commit
# time, so a cache keyed on mtimes, cargo's target dir being the usual one,
# finds nothing newer than what the mutant build left in it. check.sh is that
# cache: it rebuilds only when the source is newer than what it holds.
export CACHE="$TMP/build-cache"
mkdir -p "$CACHE"
cat > "$REPO/check.sh" <<'T'
if [ ! -f "$CACHE/built.sh" ] || [ lib.sh -nt "$CACHE/built.sh" ]; then
  cp lib.sh "$CACHE/built.sh"
fi
. "$CACHE/built.sh"
[ "$(add 2 3)" = 5 ]
T
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm cached
SHA3=$(git -C "$REPO" rev-parse HEAD)
rc=0; out=$("$MS" --worktree "$REPO" --sha "$SHA3" --test 'bash check.sh' \
      --mutate 'sed -i "s/+/-/" lib.sh' --stability 3 --threads 2) || rc=$?
if [ "$rc" = 0 ]; then ok "a shared mtime-keyed build cache stays stable"; else bad "a shared mtime-keyed build cache stays stable" "rc=$rc out=$out"; fi
case "$out" in *"stability: 3/3 at 2 threads") ok "the clean copy rebuilds instead of reusing the mutant";; *) bad "the clean copy rebuilds instead of reusing the mutant" "$out";; esac

# A filesystem or cache that keeps whole seconds rounds an extraction and the
# build before it to the same second, and a cache rebuilds on a strictly newer
# source, not an equal one. Each copy is stamped a full second past the last.
kept=$("$MS" --worktree "$REPO" --sha "$SHA3" --test 'bash check.sh' \
      --mutate 'sed -i "s/+/-/" lib.sh' --stability 1 --threads 2 --keep 2>&1 >/dev/null || true)
root=$(printf '%s\n' "$kept" | sed -n 's/^kept: //p')
if [ -d "$root/clean" ]; then
  gap=$(( $(stat -c %Y "$root/clean/lib.sh") - $(stat -c %Y "$root/mutant/lib.sh") ))
  rm -rf "$root"
  if [ "$gap" -ge 1 ]; then ok "each copy is stamped a whole second past the one before"; else bad "each copy is stamped a whole second past the one before" "gap=${gap}s"; fi
else
  bad "each copy is stamped a whole second past the one before" "--keep printed no temp dir: $kept"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
