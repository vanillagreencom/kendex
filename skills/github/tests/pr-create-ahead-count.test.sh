#!/usr/bin/env bash
# Tests for pr-create.sh: the safety-check ahead count, the identity the
# creation names, and the base it targets when --base names none.
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

# Real repo pair: bare origin + working clone. Every row puts the stub gh on
# PATH: with no --base, the base is the repository's default branch, which
# the stub answers (STUB_DEFAULT_BRANCH, main unless a row sets it).
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
# Two more branches at main's tip, each a default branch a row names.
git -C "$CLONE" push -q origin main:develop main:trunk
git -C "$CLONE" checkout -qb feature-x
git -C "$CLONE" commit --allow-empty -qm "feature commit D"
git -C "$CLONE" push -qu origin feature-x
# Rewind local main to the first commit: origin/main keeps all three, so
# local main is now 2 commits behind the remote base.
git -C "$CLONE" branch -qf main "$first_commit"

run_pr_create() {
  (cd "$CLONE" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u WORKTREE_DEFAULT_BRANCH \
    PATH="$TMP_ROOT/bin:$PATH" "$PR_CREATE" "$@")
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
  out=$(cd "$CLONE" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u WORKTREE_DEFAULT_BRANCH PATH="$TMP_ROOT/bin:$PATH" STUB_AUTH_LOG="$AUTH_LOG" ${caller_env#-} "$PR_CREATE" 2>&1)
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

# 1c. The base with no --base: the repository's default branch on GitHub, or
#     WORKTREE_DEFAULT_BRANCH, which is read in its place, so GitHub is never
#     asked. A default branch GitHub cannot name, and a checkout with no
#     GitHub repository, refuse on their first line with nothing created. The
#     must-fail control is a copy of the scripts tree whose read is replaced
#     by main: the develop row then targets main.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR"
cp -R "$REPO_ROOT/skills/github/scripts/." "$MUTANT_DIR/"
READ_LINE='        base=$(kendex_github_default_branch "${PROJECT_ROOT:-$PWD}") || base_rc=$?'
assert_eq "$(grep -cxF -- "$READ_LINE" "$MUTANT_DIR/commands/pr-create.sh")" "1" "control: the default-branch read is one line"
F="$READ_LINE" awk 'BEGIN { f = ENVIRON["F"] } $0 == f { $0 = "        base=main" } { print }' \
  "$MUTANT_DIR/commands/pr-create.sh" >"$MUTANT_DIR/pr-create.edit"
cat -- "$MUTANT_DIR/pr-create.edit" >"$MUTANT_DIR/commands/pr-create.sh"
assert_eq "$(grep -cxF -- "$READ_LINE" "$MUTANT_DIR/commands/pr-create.sh")" "0" "control: the read was replaced"
CALL_LOG="$TMP_ROOT/calls.log"
CLONE_PHYSICAL="$(cd "$CLONE" && pwd -P)"
while IFS='|' read -r label script caller_env rc first base asked; do
  : >"$CALL_LOG"
  [[ "$script" == mutant ]] && script="$MUTANT_DIR/commands/pr-create.sh" || script="$PR_CREATE"
  set +e
  # shellcheck disable=SC2086
  out=$(cd "$CLONE" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u WORKTREE_DEFAULT_BRANCH PATH="$TMP_ROOT/bin:$PATH" STUB_CALL_LOG="$CALL_LOG" ${caller_env#-} "$script" 2>&1)
  got_rc=$?
  set -e
  assert_eq "$got_rc" "$rc" "$label: exit"
  [[ "$first" == - ]] || assert_eq "$(head -1 <<<"$out")" "${first//CLONE/$CLONE_PHYSICAL}" "$label: first line"
  assert_eq "$(sed -n 's/^pr create .*--base \([^ ]*\) .*/\1/p' "$CALL_LOG")" "${base#-}" "$label: the base gh pr create received"
  assert_eq "$(grep -c '^api repos/' "$CALL_LOG" || true)" "$asked" "$label: GitHub reads of the repository"
done <<'ROWS'
GitHub's default branch develop is the base|real|STUB_DEFAULT_BRANCH=develop|0|-|develop|1
must-fail: with the read replaced by main, develop's repository gets main|mutant|STUB_DEFAULT_BRANCH=develop|0|-|main|0
WORKTREE_DEFAULT_BRANCH overrides and GitHub is not asked|real|STUB_DEFAULT_BRANCH=develop WORKTREE_DEFAULT_BRANCH=trunk|0|-|trunk|0
a default branch GitHub cannot name refuses, nothing created|real|STUB_REPO_EXIT=1|1|default-branch: unreadable repo=owner/repo|-|1
a checkout with no GitHub repository refuses, nothing created|real|STUB_NO_REPO=true|1|pr-create: base=unresolved root=CLONE|-|0
ROWS

# 1d. A head that is the base refuses on check 1 whatever the base is named:
#     a develop one commit past origin/develop passes the ahead count, so
#     check 1 alone decides the exit.
git -C "$CLONE" checkout -qb develop origin/develop
git -C "$CLONE" commit --allow-empty -qm "develop commit E"
set +e
out=$(run_pr_create --dry-run --base develop 2>&1)
rc=$?
set -e
assert_eq "$rc" "1" "head equal to a develop base: safety checks fail"
assert_contains "$out" "Commits-ahead: base=origin/develop count=1" \
  "head equal to a develop base: the ahead count passes"
assert_contains "$out" "✗ ERROR: Cannot create PR from the base branch develop into itself" \
  "head equal to a develop base: check 1 refuses"

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
