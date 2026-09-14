#!/usr/bin/env bash
# Tests for pr-create.sh: the safety-check ahead count, and the identity the
# creation names.
#
# The "commits ahead of base" check must count against the REMOTE base
# (origin/$base) that the PR actually targets. Counting against
# local $base, so a stale local main reported already-merged commits as
# "ahead" — a 1-commit feature branch showed as "3 commit(s) ahead of main".
# When origin is unreachable and no remote-tracking ref exists, the check
# falls back to local $base and labels the count as possibly stale.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PR_CREATE="$REPO_ROOT/skills/github/scripts/commands/pr-create.sh"

# shellcheck source=lib/check-stub.sh
source "$TEST_DIR/lib/check-stub.sh"
TMP_ROOT="$TMPDIR"

# Real repo pair: bare origin + working clone. The --dry-run rows make no gh
# call: the safety checks and that path are pure git plus env-only token
# lookup. Only the creation rows put the stub gh on PATH.
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

echo "=== pr-create ahead count vs stale local base (kendex#537) ==="

# 1. Stale local main, reachable origin -> count against origin/main is 1,
#    not inflated to 3 by the two already-merged commits.
set +e
out=$(run_pr_create --dry-run 2>&1)
rc=$?
set -e
assert_eq "$rc" "0" "stale local main: dry-run passes safety checks"
assert_contains "$out" "Commits-ahead: base=origin/main count=1" \
  "stale local main: notice key names remote base and count"
assert_not_contains "$out" "Commits-ahead: base=main count=3 source=local" \
  "stale local main: does not report inflated local-base count"
assert_not_contains "$out" "source=local" \
  "stale local main: no stale-count warning when origin is reachable"

# 1b. Without --dry-run the creation names the variable it selected and who
#     that token acts as, and gh pr create runs with that token; with no token
#     it warns instead that the current user creates the PR.
AUTH_LOG="$TMP_ROOT/auth.log"
while IFS='|' read -r label caller_env line absent auth; do
  : >"$AUTH_LOG"
  set +e
  # shellcheck disable=SC2086
  out=$(cd "$CLONE" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN PATH="$TMP_ROOT/bin:$PATH" STUB_AUTH_LOG="$AUTH_LOG" ${caller_env#-} "$PR_CREATE" 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" "0" "$label: gh pr create ran"
  assert_contains "$out" "$line" "$label: names who creates the PR"
  assert_not_contains "$out" "$absent" "$label: prints no line for the other case"
  assert_eq "$(sed -n 's/^GH=\([^|]*\)|.*|pr create .*/\1/p' "$AUTH_LOG")" "$auth" "$label: the token gh pr create received"
done <<'ROWS'
GH_TOKEN alone|GH_TOKEN=ghp_CREATE|Using GH_TOKEN as stub-user|Warning: GH_BOT_TOKEN not configured|ghp_CREATE
no token|-|Warning: GH_BOT_TOKEN not configured, using current user|Using |<unset>
ROWS

# 2. Branch pointing at the origin/main tip has NO commits to submit. Against the
#    stale local main it would look 2 ahead and wrongly pass; the hard
#    failure must use the same remote base OID as the count.
git -C "$CLONE" checkout -qb noop origin/main
set +e
out=$(run_pr_create --dry-run 2>&1)
rc=$?
set -e
assert_eq "$rc" "1" "no-new-commits branch: safety checks fail"
assert_contains "$out" "No-commits-ahead: base=origin/main count=0" \
  "no-new-commits branch: refusal key names remote base and count"

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
assert_contains "$out" "Commits-ahead: base=main count=3 source=local" \
  "offline fallback: notice key names local base, count, and source"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
