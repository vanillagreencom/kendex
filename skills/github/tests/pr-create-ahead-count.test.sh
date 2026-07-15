#!/usr/bin/env bash
# Regression tests for pr-create.sh safety-check ahead count (vstack#537).
#
# The "commits ahead of base" check must count against the REMOTE base
# (origin/$base) that the PR actually targets. Previously it counted against
# local $base, so a stale local main reported already-merged commits as
# "ahead" — a 1-commit feature branch showed as "3 commit(s) ahead of main".
# When origin is unreachable and no remote-tracking ref exists, the check
# falls back to local $base and labels the count as possibly stale.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PR_CREATE="$REPO_ROOT/skills/github/scripts/commands/pr-create.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unwanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

# Real repo pair: bare origin + working clone. No gh calls are made — the
# safety checks and --dry-run path are pure git plus env-only token lookup.
ORIGIN="$TMP_ROOT/origin.git"
CLONE="$TMP_ROOT/clone"
git init -q --bare "$ORIGIN"
git init -qb main "$CLONE"
git -C "$CLONE" remote add origin "$ORIGIN"
git -C "$CLONE" config user.email test@example.com
git -C "$CLONE" config user.name "Test User"
git -C "$CLONE" config commit.gpgsign false

# origin/main gets three commits; the feature branch adds one on top.
git -C "$CLONE" commit --allow-empty -qm "base commit A"
first_commit=$(git -C "$CLONE" rev-parse HEAD)
git -C "$CLONE" commit --allow-empty -qm "merged commit B"
git -C "$CLONE" commit --allow-empty -qm "merged commit C"
git -C "$CLONE" push -qu origin main
git -C "$CLONE" checkout -qb feature-x
git -C "$CLONE" commit --allow-empty -qm "feature commit D"
git -C "$CLONE" push -qu origin feature-x
# Rewind local main to the first commit: origin/main keeps all three, so
# local main is now 2 commits behind the remote base.
git -C "$CLONE" branch -qf main "$first_commit"

run_pr_create() {
  (cd "$CLONE" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN "$PR_CREATE" "$@")
}

echo "=== pr-create ahead count vs stale local base (vstack#537) ==="

# 1. Stale local main, reachable origin -> count against origin/main is 1,
#    not inflated to 3 by the two already-merged commits.
set +e
out=$(run_pr_create --dry-run 2>&1)
rc=$?
set -e
assert_eq "$rc" "0" "stale local main: dry-run passes safety checks"
assert_contains "$out" "1 commit(s) ahead of origin/main" \
  "stale local main: counts 1 commit ahead of origin/main"
assert_not_contains "$out" "3 commit(s)" \
  "stale local main: does not report inflated local-base count"
assert_not_contains "$out" "may be stale" \
  "stale local main: no stale-count warning when origin is reachable"

# 2. Branch pointing at the origin/main tip has NO new commits. Against the
#    stale local main it would look 2 ahead and wrongly pass; the hard
#    failure must use the same remote base OID as the count.
git -C "$CLONE" checkout -qb noop origin/main
set +e
out=$(run_pr_create --dry-run 2>&1)
rc=$?
set -e
assert_eq "$rc" "1" "no-new-commits branch: safety checks fail"
assert_contains "$out" "No commits ahead of origin/main" \
  "no-new-commits branch: hard failure names remote base"

# 3. Offline fallback: origin unreachable and no remote-tracking ref left.
#    Falls back to local main and labels the count as possibly stale.
git -C "$CLONE" checkout -q feature-x
git -C "$CLONE" remote set-url origin "$TMP_ROOT/missing.git"
git -C "$CLONE" update-ref -d refs/remotes/origin/main
set +e
out=$(run_pr_create --dry-run 2>&1)
rc=$?
set -e
assert_eq "$rc" "0" "offline fallback: dry-run still passes (push warning only)"
assert_contains "$out" "3 commit(s) ahead of local main (origin unreachable; count may be stale)" \
  "offline fallback: local-base count labeled as possibly stale"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
