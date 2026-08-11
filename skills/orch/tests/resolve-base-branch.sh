#!/usr/bin/env bash
# Behavioral tests for resolve-base-branch — the base-branch resolver used by
# base-freshness and the worktree flows. vstack#1225: a nonexistent worktree
# path fell through the `|| true` swallow to the main fallback with exit 0,
# handing callers an unverified base. The resolver must fail closed (exit 1,
# actionable error) on a missing path or a non-repository directory — on BOTH
# arms, since WORKTREE_DEFAULT_BRANCH skips the git resolution entirely — and
# keep resolving valid worktrees exactly as before.
#
# Bash 3.2 compatible.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

RBB="$REPO_ROOT/skills/orch/scripts/resolve-base-branch"

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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got: %s\n' "$name" "$needle" "$haystack"
  fi
}

# --- fixtures ---------------------------------------------------------------
# A bare upstream with origin/HEAD -> main, and a clone whose remote HEAD is
# resolvable — the happy path the resolver must keep serving.
UPSTREAM="$TMP_ROOT/upstream.git"
CLONE="$TMP_ROOT/clone"
git init -q --bare "$UPSTREAM"
git init -q "$TMP_ROOT/seed"
git -C "$TMP_ROOT/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
git -C "$TMP_ROOT/seed" branch -M main
git -C "$TMP_ROOT/seed" push -q "$UPSTREAM" main
git clone -q "$UPSTREAM" "$CLONE"
git -C "$CLONE" remote set-head origin main

# Case 1: valid clone resolves the remote default branch.
set +e
out="$("$RBB" "$CLONE" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "0" "valid worktree exits 0"
assert_eq "$out" "main" "valid worktree resolves origin/HEAD"

# Case 2: WORKTREE_DEFAULT_BRANCH override on a valid worktree still works.
set +e
out="$(WORKTREE_DEFAULT_BRANCH=trunk "$RBB" "$CLONE" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "0" "override on a valid worktree exits 0"
assert_eq "$out" "trunk" "override value is honored"

# Case 3 (the #1225 defect): a nonexistent path must fail closed, never
# fall through to the main fallback with exit 0.
set +e
out="$("$RBB" "$TMP_ROOT/does-not-exist" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "1" "nonexistent worktree path exits 1"
assert_eq "$out" "" "nonexistent path prints no base branch"
assert_contains "$(cat "$TMP_ROOT/err")" "does not exist" "nonexistent path names the failure"

# Case 4: the override arm validates the path too — WORKTREE_DEFAULT_BRANCH
# must not launder a nonexistent worktree into an exit-0 answer.
set +e
out="$(WORKTREE_DEFAULT_BRANCH=trunk "$RBB" "$TMP_ROOT/also-missing" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "1" "override arm still exits 1 on a missing path"
assert_eq "$out" "" "override arm prints no base branch for a missing path"

# Case 5: an existing directory that is NOT a git work tree fails closed.
mkdir -p "$TMP_ROOT/plain-dir"
set +e
out="$(env -u WORKTREE_DEFAULT_BRANCH GIT_CEILING_DIRECTORIES="$TMP_ROOT" "$RBB" "$TMP_ROOT/plain-dir" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "1" "non-repository directory exits 1"
assert_contains "$(cat "$TMP_ROOT/err")" "not inside a git work tree" "non-repository names the failure"

# Case 6: a valid repo with NO resolvable origin/HEAD still falls back to
# main with exit 0 — the fallback is for unresolvable HEADS, not bad paths.
NOHEAD="$TMP_ROOT/nohead"
git init -q "$NOHEAD"
git -C "$NOHEAD" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
set +e
out="$("$RBB" "$NOHEAD" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "0" "repo without origin/HEAD exits 0"
assert_eq "$out" "main" "repo without origin/HEAD falls back to main"

printf 'resolve-base-branch: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
