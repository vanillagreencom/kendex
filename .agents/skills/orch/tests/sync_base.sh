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
git -C "$SEED" add file
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

BASE_TREE="$TMP_ROOT/base-tree"
git -C "$CLONE" worktree add -q "$BASE_TREE" main
printf 'four\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m four
git -C "$SEED" push -q "$UPSTREAM" main
out="$($SYNC "$CLONE" 2>"$TMP_ROOT/sync.err")"
assert_eq "$out" "main" "owned-base sync prints the branch"
assert_eq "$(git -C "$BASE_TREE" rev-parse HEAD)" "$(git -C "$SEED" rev-parse main)" "sync advances the worktree that owns the base"

git -C "$BASE_TREE" commit -q --allow-empty -m diverged
printf 'five\n' >> "$SEED/file"
git -C "$SEED" add file
git -C "$SEED" commit -q -m five
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
