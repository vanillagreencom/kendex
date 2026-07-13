#!/usr/bin/env bash
# Regression tests for `worktree push` auto-rebase behavior.
#
# Core regression (vstack#515): a feature branch that already contains
# origin/<default> as an ancestor (e.g. it merged the latest main) must NOT be
# rebased before push. A plain rebase flattens the merge commit and re-replays
# the merged edits, reintroducing conflicts the merge already resolved, which
# aborts the push. The fix guards both rebase sites with
# `merge-base --is-ancestor origin/<default> HEAD` and skips the rebase when the
# base is already contained. Rebase must still run when the branch is genuinely
# behind (does not contain the base as an ancestor).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Default to the real script; allow override so the pre-fix regression can be
# demonstrated against a temporarily-reverted copy.
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_ne() {
  local got="$1" unwanted="$2" name="$3"
  if [[ "$got" != "$unwanted" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected value to differ from: %s\n' "$name" "$unwanted"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unwanted substring present: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

assert_path_exists() {
  local path="$1" name="$2"
  if [[ -e "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing path: %s\n' "$name" "$path"
  fi
}

assert_path_absent() {
  local path="$1" name="$2"
  if [[ ! -e "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        still exists: %s\n' "$name" "$path"
  fi
}

assert_is_ancestor() {
  local repo="$1" ancestor="$2" descendant="$3" name="$4"
  if git -C "$repo" merge-base --is-ancestor "$ancestor" "$descendant"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        %s is not an ancestor of %s\n' "$name" "$ancestor" "$descendant"
  fi
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf 'orig\n' > "$repo/f"
  git -C "$repo" add f
  git -C "$repo" commit -q -m base
}

echo "=== worktree push auto-rebase ==="

# --- Core regression (vstack#515) ---------------------------------------------
# Feature branch merged origin/main and resolved a same-line conflict, so it
# already contains origin/main as an ancestor. A plain rebase would re-replay
# the feature edit onto main-edit and conflict. push must skip the rebase and
# publish the merge commit unchanged.
ANCESTOR_ROOT="$TMP_ROOT/already-ancestor"
make_repo "$ANCESTOR_ROOT/main"
git init -q --bare "$ANCESTOR_ROOT/origin.git"
git -C "$ANCESTOR_ROOT/main" remote add origin "$ANCESTOR_ROOT/origin.git"
git -C "$ANCESTOR_ROOT/main" push -q -u origin main
git -C "$ANCESTOR_ROOT/main" worktree add -q -b issue-ancestor "$ANCESTOR_ROOT/trees/issue-ancestor" main
# Feature edits the shared line.
printf 'feature\n' > "$ANCESTOR_ROOT/trees/issue-ancestor/f"
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" add f
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" commit -q -m 'feature edit'
# main edits the same line differently and advances origin.
printf 'main-side\n' > "$ANCESTOR_ROOT/main/f"
git -C "$ANCESTOR_ROOT/main" add f
git -C "$ANCESTOR_ROOT/main" commit -q -m 'main edit'
git -C "$ANCESTOR_ROOT/main" push -q origin main
# Feature merges origin/main and resolves the conflict — now it contains
# origin/main as an ancestor, and a plain rebase WOULD conflict.
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" fetch -q origin
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" merge origin/main >/dev/null 2>&1 || true
printf 'merged\n' > "$ANCESTOR_ROOT/trees/issue-ancestor/f"
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" add f
git -C "$ANCESTOR_ROOT/trees/issue-ancestor" commit -q -m 'merge origin/main'
ancestor_pre_head="$(git -C "$ANCESTOR_ROOT/trees/issue-ancestor" rev-parse HEAD)"
set +e
(
  cd "$ANCESTOR_ROOT/main" && \
    "$WORKTREE_SCRIPT" push "$ANCESTOR_ROOT/trees/issue-ancestor" --set-upstream \
      >"$ANCESTOR_ROOT/push.out" 2>"$ANCESTOR_ROOT/push.err"
)
ancestor_code=$?
set -e
ancestor_post_head="$(git -C "$ANCESTOR_ROOT/trees/issue-ancestor" rev-parse HEAD)"
assert_eq "$ancestor_code" "0" "push succeeds when origin/main already merged into branch"
assert_not_contains "$(cat "$ANCESTOR_ROOT/push.err")" "Rebase onto origin/main failed" "push does not hit the spurious rebase-conflict error"
assert_contains "$(cat "$ANCESTOR_ROOT/push.err")" "skipping rebase" "push reports it skipped the unnecessary rebase"
assert_eq "$ancestor_post_head" "$ancestor_pre_head" "HEAD is unchanged (no rebase happened)"
assert_eq "$(git --git-dir="$ANCESTOR_ROOT/origin.git" rev-parse refs/heads/issue-ancestor)" "$ancestor_pre_head" "feature branch lands on remote at the merge commit"

# --- Rebase still happens when genuinely behind -------------------------------
# Feature does NOT contain origin/main as an ancestor (main advanced after the
# branch point) and there are no conflicts. push must rebase and fast-forward
# the base before pushing, proving the skip only triggers on the ancestor case.
BEHIND_ROOT="$TMP_ROOT/behind"
make_repo "$BEHIND_ROOT/main"
git init -q --bare "$BEHIND_ROOT/origin.git"
git -C "$BEHIND_ROOT/main" remote add origin "$BEHIND_ROOT/origin.git"
git -C "$BEHIND_ROOT/main" push -q -u origin main
git -C "$BEHIND_ROOT/main" worktree add -q -b issue-behind "$BEHIND_ROOT/trees/issue-behind" main
# main advances on an unrelated file and pushes.
printf 'advanced\n' > "$BEHIND_ROOT/main/main-advanced.txt"
git -C "$BEHIND_ROOT/main" add main-advanced.txt
git -C "$BEHIND_ROOT/main" commit -q -m 'advance main'
git -C "$BEHIND_ROOT/main" push -q origin main
# Feature adds its own (non-conflicting) file on the old base.
printf 'fix\n' > "$BEHIND_ROOT/trees/issue-behind/fix.txt"
git -C "$BEHIND_ROOT/trees/issue-behind" add fix.txt
git -C "$BEHIND_ROOT/trees/issue-behind" commit -q -m 'review fix'
git -C "$BEHIND_ROOT/trees/issue-behind" fetch -q origin
# Precondition: branch does NOT yet contain the advanced origin/main.
set +e
git -C "$BEHIND_ROOT/trees/issue-behind" merge-base --is-ancestor origin/main HEAD
behind_precond=$?
set -e
assert_eq "$behind_precond" "1" "behind branch does not contain origin/main before push"
behind_pre_head="$(git -C "$BEHIND_ROOT/trees/issue-behind" rev-parse HEAD)"
set +e
(
  cd "$BEHIND_ROOT/main" && \
    "$WORKTREE_SCRIPT" push "$BEHIND_ROOT/trees/issue-behind" --set-upstream \
      >"$BEHIND_ROOT/push.out" 2>"$BEHIND_ROOT/push.err"
)
behind_code=$?
set -e
behind_post_head="$(git -C "$BEHIND_ROOT/trees/issue-behind" rev-parse HEAD)"
assert_eq "$behind_code" "0" "push succeeds for a genuinely-behind branch"
assert_ne "$behind_post_head" "$behind_pre_head" "rebase rewrote HEAD (rebase actually ran)"
assert_path_exists "$BEHIND_ROOT/trees/issue-behind/main-advanced.txt" "rebase moved the base onto advanced origin/main"
assert_is_ancestor "$BEHIND_ROOT/trees/issue-behind" origin/main HEAD "origin/main is contained after rebase"
assert_eq "$(git --git-dir="$BEHIND_ROOT/origin.git" rev-parse refs/heads/issue-behind)" "$behind_post_head" "remote branch matches rebased local head"

# --- --no-rebase skips the rebase (unchanged behavior) ------------------------
# A behind branch pushed with --no-rebase must not be rebased: HEAD stays put
# and the advanced main file is absent from the worktree.
NOREBASE_ROOT="$TMP_ROOT/no-rebase"
make_repo "$NOREBASE_ROOT/main"
git init -q --bare "$NOREBASE_ROOT/origin.git"
git -C "$NOREBASE_ROOT/main" remote add origin "$NOREBASE_ROOT/origin.git"
git -C "$NOREBASE_ROOT/main" push -q -u origin main
git -C "$NOREBASE_ROOT/main" worktree add -q -b issue-norebase "$NOREBASE_ROOT/trees/issue-norebase" main
printf 'advanced\n' > "$NOREBASE_ROOT/main/main-advanced.txt"
git -C "$NOREBASE_ROOT/main" add main-advanced.txt
git -C "$NOREBASE_ROOT/main" commit -q -m 'advance main'
git -C "$NOREBASE_ROOT/main" push -q origin main
printf 'fix\n' > "$NOREBASE_ROOT/trees/issue-norebase/fix.txt"
git -C "$NOREBASE_ROOT/trees/issue-norebase" add fix.txt
git -C "$NOREBASE_ROOT/trees/issue-norebase" commit -q -m 'review fix'
norebase_pre_head="$(git -C "$NOREBASE_ROOT/trees/issue-norebase" rev-parse HEAD)"
set +e
(
  cd "$NOREBASE_ROOT/main" && \
    "$WORKTREE_SCRIPT" push "$NOREBASE_ROOT/trees/issue-norebase" --set-upstream --no-rebase \
      >"$NOREBASE_ROOT/push.out" 2>"$NOREBASE_ROOT/push.err"
)
norebase_code=$?
set -e
norebase_post_head="$(git -C "$NOREBASE_ROOT/trees/issue-norebase" rev-parse HEAD)"
assert_eq "$norebase_code" "0" "--no-rebase push succeeds"
assert_eq "$norebase_post_head" "$norebase_pre_head" "--no-rebase leaves HEAD unchanged"
assert_path_absent "$NOREBASE_ROOT/trees/issue-norebase/main-advanced.txt" "--no-rebase does not pull in advanced main"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
