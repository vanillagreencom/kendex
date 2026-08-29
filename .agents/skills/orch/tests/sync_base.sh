#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/skills/orch/scripts/sync-base"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
assert_eq() { [[ "$1" == "$2" ]] && ok "$3" || { printf '        expected: %s\n        got:      %s\n' "$2" "$1"; fail "$3"; }; }

UPSTREAM="$TMP_ROOT/upstream.git"
SEED="$TMP_ROOT/seed"
CLONE="$TMP_ROOT/clone"
git init -q --bare "$UPSTREAM"
git init -q "$SEED"
git -C "$SEED" config user.email test@example.com
git -C "$SEED" config user.name test
printf 'one\n' > "$SEED/file"
printf 'tracked\n' > "$SEED/local"
git -C "$SEED" add file local
git -C "$SEED" commit -q -m one
git -C "$SEED" branch -M main
git -C "$SEED" push -q "$UPSTREAM" main
git --git-dir="$UPSTREAM" symbolic-ref HEAD refs/heads/main
git clone -q "$UPSTREAM" "$CLONE"
git -C "$CLONE" config user.email test@example.com
git -C "$CLONE" config user.name test
git -C "$CLONE" remote set-head origin main

printf 'two\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m two
git -C "$SEED" push -q "$UPSTREAM" main
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "base checkout sync prints only the branch"
assert_eq "$(git -C "$CLONE" rev-parse main)" "$(git -C "$SEED" rev-parse main)" "base checkout fast-forwards"

git -C "$CLONE" switch -q -c feature
printf 'three\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m three
git -C "$SEED" push -q "$UPSTREAM" main
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "by-name sync prints the base branch"
assert_eq "$(git -C "$CLONE" branch --show-current)" "feature" "by-name sync keeps the active branch"
assert_eq "$(git -C "$CLONE" rev-parse main)" "$(git -C "$SEED" rev-parse main)" "unowned base ref fast-forwards"

STALE_TREE="$TMP_ROOT/stale-tree"
STALE_GONE="$TMP_ROOT/stale-tree-gone"
git -C "$CLONE" worktree add -q "$STALE_TREE" main
mv "$STALE_TREE" "$STALE_GONE"
printf 'four\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m four
git -C "$SEED" push -q "$UPSTREAM" main
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "stale-owner sync prints the branch"
assert_eq "$(git -C "$CLONE" rev-parse main)" "$(git -C "$SEED" rev-parse main)" "prune removes stale ownership before the update"
git -C "$CLONE" worktree list --porcelain | grep -Fq "$STALE_TREE" && fail "stale worktree registration is pruned" || ok "stale worktree registration is pruned"

BASE_TREE="$TMP_ROOT/base"$'\n'"tree"
git -C "$CLONE" worktree add -q "$BASE_TREE" main
printf 'five\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m five
git -C "$SEED" push -q "$UPSTREAM" main
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "owned-base sync prints the branch"
assert_eq "$(git -C "$BASE_TREE" rev-parse HEAD)" "$(git -C "$SEED" rev-parse main)" "sync advances the worktree that owns the base"

printf 'dirty\n' >> "$BASE_TREE/local"
printf 'six\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m six
git -C "$SEED" push -q "$UPSTREAM" main
before="$(git -C "$BASE_TREE" rev-parse HEAD)"
rc=0
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/tracked-dirty.err")" || rc=$?
[[ $rc -ne 0 ]] && ok "nonconflicting tracked dirtiness fails closed" || fail "nonconflicting tracked dirtiness fails closed"
assert_eq "$out" "" "tracked-dirty sync prints no branch"
assert_eq "$(git -C "$BASE_TREE" rev-parse HEAD)" "$before" "tracked-dirty base does not advance"
grep -Fq 'base checkout is dirty' "$TMP_ROOT/tracked-dirty.err" && ok "tracked-dirty refusal names the checkout" || fail "tracked-dirty refusal names the checkout"
grep -Fq ' local' "$TMP_ROOT/tracked-dirty.err" && ok "tracked-dirty refusal names the path" || fail "tracked-dirty refusal names the path"
git -C "$BASE_TREE" restore local
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "cleaned tracked base can catch up"

printf 'untracked\n' > "$BASE_TREE/untracked"
printf 'seven\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m seven
git -C "$SEED" push -q "$UPSTREAM" main
before="$(git -C "$BASE_TREE" rev-parse HEAD)"
rc=0
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/untracked-dirty.err")" || rc=$?
[[ $rc -ne 0 ]] && ok "nonconflicting untracked dirtiness fails closed" || fail "nonconflicting untracked dirtiness fails closed"
assert_eq "$out" "" "untracked-dirty sync prints no branch"
assert_eq "$(git -C "$BASE_TREE" rev-parse HEAD)" "$before" "untracked-dirty base does not advance"
grep -Fq '?? untracked' "$TMP_ROOT/untracked-dirty.err" && ok "untracked-dirty refusal names the path" || fail "untracked-dirty refusal names the path"
rm -f -- "$BASE_TREE/untracked"
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "cleaned untracked base can catch up"

git -C "$BASE_TREE" commit -q --allow-empty -m diverged
printf 'eight\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m eight
git -C "$SEED" push -q "$UPSTREAM" main
rc=0
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/diverged.err")" || rc=$?
[[ $rc -ne 0 ]] && ok "divergent base fails closed" || fail "divergent base fails closed"
assert_eq "$out" "" "failed sync prints no branch"
grep -Fq 'Not possible to fast-forward' "$TMP_ROOT/diverged.err" && ok "divergence reports the fast-forward refusal" || fail "divergence reports the fast-forward refusal"

MERGE_WORKFLOW="$REPO_ROOT/skills/orch/workflows/merge-pr.md"
grep -Fq 'scripts/sync-base [MAIN_REPO_ROOT]' "$MERGE_WORKFLOW" && ok "merge-pr delegates base synchronization to the script" || fail "merge-pr delegates base synchronization to the script"
grep -Fq 'merge --ff-only "origin/[BASE_BRANCH]"' "$MERGE_WORKFLOW" && fail "merge-pr removes the prose base-sync procedure" || ok "merge-pr removes the prose base-sync procedure"

printf 'sync-base: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
