#!/usr/bin/env bash
# Behavioral tests for base-freshness — the start-worktree.md § 1 review-cycle
# gate (vstack#904). A reused worktree can sit many commits behind origin, and
# the review cycle previously ran with no fetch anywhere on that path, so
# eleven reviewers evaluated a stale base. The helper must FETCH origin (a
# stale remote-tracking ref is not evidence), report ahead/behind of HEAD vs
# the resolved base branch, and exit 0 fresh / 4 stale / 1 unverifiable.
#
# Bash 3.2 compatible.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

BF="$REPO_ROOT/skills/orch/scripts/base-freshness"

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

commit_upstream() {
  local msg="$1"
  printf '%s\n' "$msg" >>"$UPSTREAM/log.txt"
  git -C "$UPSTREAM" add log.txt
  git -C "$UPSTREAM" commit -q -m "$msg"
}

# Sandbox: an upstream repo pushed to a bare origin, and a clone standing in
# for the reused issue worktree.
UPSTREAM="$TMP_ROOT/upstream"
ORIGIN="$TMP_ROOT/origin.git"
WT="$TMP_ROOT/worktree"

mkdir -p "$UPSTREAM"
git -C "$UPSTREAM" init -q -b main
git -C "$UPSTREAM" config user.email test@example.com
git -C "$UPSTREAM" config user.name Test
git -C "$UPSTREAM" config commit.gpgsign false
commit_upstream base
git init -q --bare "$ORIGIN"
git -C "$UPSTREAM" remote add origin "$ORIGIN"
git -C "$UPSTREAM" push -q -u origin main

git clone -q "$ORIGIN" "$WT"
git -C "$WT" config user.email test@example.com
git -C "$WT" config user.name Test
git -C "$WT" config commit.gpgsign false
git -C "$WT" checkout -q -b issue-42

echo "=== base-freshness review-cycle gate ==="

# Fresh: worktree branch is at origin/main.
set +e
out="$(env -u WORKTREE_DEFAULT_BRANCH "$BF" "$WT" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "0" "fresh worktree exits 0"
assert_eq "$(printf '%s' "$out" | jq -r '.behind')" "0" "fresh worktree reports behind = 0"
assert_eq "$(printf '%s' "$out" | jq -r '.fresh')" "true" "fresh worktree reports fresh = true"
assert_eq "$(printf '%s' "$out" | jq -r '.branch')" "issue-42" "JSON carries the current branch"
assert_eq "$(printf '%s' "$out" | jq -r '.base_branch')" "main" "JSON carries the resolved base branch"

# Stale: origin/main advances AFTER the clone. The worktree's remote-tracking
# ref still points at the old tip, so a nonzero `behind` here proves the
# helper fetched rather than trusting local refs — the vstack#904 failure.
commit_upstream upstream-1
commit_upstream upstream-2
git -C "$UPSTREAM" push -q origin main
git -C "$WT" commit -q --allow-empty -m local-work

set +e
out="$(env -u WORKTREE_DEFAULT_BRANCH "$BF" "$WT" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "4" "stale worktree exits 4"
assert_eq "$(printf '%s' "$out" | jq -r '.behind')" "2" "stale worktree reports commits behind origin base (fetch happened)"
assert_eq "$(printf '%s' "$out" | jq -r '.ahead')" "1" "stale worktree still reports local commits ahead"
assert_eq "$(printf '%s' "$out" | jq -r '.fresh')" "false" "stale worktree reports fresh = false"

# Rebase clears staleness: after rebasing onto the fetched base (what
# `worktree create <ID> --reuse` does), the gate must pass.
git -C "$WT" rebase -q origin/main >/dev/null 2>&1
set +e
out="$(env -u WORKTREE_DEFAULT_BRANCH "$BF" "$WT" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "0" "rebased worktree exits 0"
assert_eq "$(printf '%s' "$out" | jq -r '.behind')" "0" "rebased worktree reports behind = 0"

# WORKTREE_DEFAULT_BRANCH overrides the resolved base (resolve-base-branch
# integration): compare against origin/trunk instead of origin/main.
git -C "$UPSTREAM" checkout -q -b trunk
commit_upstream trunk-only
git -C "$UPSTREAM" push -q origin trunk
git -C "$UPSTREAM" checkout -q main

set +e
out="$(WORKTREE_DEFAULT_BRANCH=trunk "$BF" "$WT" 2>"$TMP_ROOT/err")"
code=$?
set -e
assert_eq "$code" "4" "WORKTREE_DEFAULT_BRANCH base is honored (stale vs trunk)"
assert_eq "$(printf '%s' "$out" | jq -r '.base_branch')" "trunk" "JSON reports the overridden base branch"
assert_eq "$(printf '%s' "$out" | jq -r '.behind')" "1" "behind counted against the overridden base"

# Unverifiable: fetch failure must exit 1 (never 0) so the workflow stops
# instead of reviewing an unknown base.
git -C "$WT" remote set-url origin "$TMP_ROOT/missing.git"
set +e
out="$(env -u WORKTREE_DEFAULT_BRANCH "$BF" "$WT" 2>"$TMP_ROOT/err")"
code=$?
set -e
err="$(cat "$TMP_ROOT/err")"
assert_eq "$code" "1" "fetch failure exits 1"
assert_contains "$err" "base freshness cannot be verified" "fetch failure names the unverified-freshness condition"

# No origin remote at all is equally unverifiable.
git -C "$WT" remote remove origin
set +e
"$BF" "$WT" >/dev/null 2>"$TMP_ROOT/err"
code=$?
set -e
err="$(cat "$TMP_ROOT/err")"
assert_eq "$code" "1" "missing origin remote exits 1"
assert_contains "$err" "no 'origin' remote" "missing origin remote is named in the error"

# Workflow wiring: the start-worktree § 1 gate runs the helper before § 2
# delegation and routes stale bases through the supported reuse rebase.
START_WT="$REPO_ROOT/skills/orch/workflows/start-worktree.md"
wiring="$(cat "$START_WT")"
assert_contains "$wiring" '.agents/skills/orch/scripts/base-freshness [WORKTREE_PATH]' "start-worktree § 1 runs the base-freshness gate"
assert_contains "$wiring" 'worktree create [ISSUE_ID] --reuse' "start-worktree routes stale bases through the supported reuse rebase"
assert_contains "$wiring" 'Never enter § 2 or § 3 on an unverified base' "start-worktree forbids reviewing an unverified base"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
