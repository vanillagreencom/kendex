#!/usr/bin/env bash
# Regression tests for the authorized-restack push lease (vstack#578).
#
# `create --reuse`/`--restack` intentionally rebases a published branch onto
# origin/<default>, rewriting history. After the rewrite, push's fail-closed
# lease (remote head must be an ancestor of HEAD) can never pass, so the
# tool's own restack workflow could not publish through `worktree push`. The
# fix records the observed remote head into the worktree's private git dir
# (`worktree-restack-lease`) before the rebase starts and lets the next push
# use it as an exact --force-with-lease expectation. The record is single-use:
# deleted on push success, and discarded with an actionable error when the
# remote moved past it. Every other push keeps today's fail-closed behavior:
# divergence without a record still refuses, and a record naming a different
# branch is ignored.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  pr:list) ;;
esac
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

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

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf 'orig\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m base
}

# Path of the worktree's private restack-lease state file.
lease_path() {
  local wt="$1" path
  path="$(git -C "$wt" rev-parse --git-path worktree-restack-lease)"
  [[ "$path" == /* ]] || path="$wt/$path"
  printf '%s\n' "$path"
}

# Build a main+origin pair with a PUBLISHED issue branch (pushed to origin,
# like an open PR branch) whose local worktree carries a feature commit.
make_published_pair() {
  local root="$1" issue="$2"
  make_repo "$root/main"
  git init -q --bare "$root/origin.git"
  git -C "$root/main" remote add origin "$root/origin.git"
  git -C "$root/main" push -q -u origin main
  (cd "$root/main" && "$WORKTREE_SCRIPT" create "$issue" >/dev/null 2>&1)
  local wt="$root/trees/$issue"
  printf 'feature\n' > "$wt/file.txt"
  git -C "$wt" add file.txt
  git -C "$wt" commit -q -m 'feature edit'
  git -C "$wt" push -q -u origin "$issue"
}

echo "=== worktree push authorized-restack lease ==="

# --- Full loop: conflicted --restack → resolve → continue → reuse → push -------
LOOP_ROOT="$TMP_ROOT/loop"
make_published_pair "$LOOP_ROOT" issue-loop
LOOP_WT="$LOOP_ROOT/trees/issue-loop"
# main edits the same line and advances origin — restack genuinely conflicts.
printf 'main-side\n' > "$LOOP_ROOT/main/file.txt"
git -C "$LOOP_ROOT/main" add file.txt
git -C "$LOOP_ROOT/main" commit -q -m 'main edit'
git -C "$LOOP_ROOT/main" push -q origin main
loop_remote_pre="$(git --git-dir="$LOOP_ROOT/origin.git" rev-parse refs/heads/issue-loop)"
set +e
(
  cd "$LOOP_ROOT/main" && \
    "$WORKTREE_SCRIPT" create issue-loop --restack >"$LOOP_ROOT/create.out" 2>"$LOOP_ROOT/create.err"
)
loop_create_code=$?
set -e
loop_create_err="$(cat "$LOOP_ROOT/create.err")"
LOOP_LEASE="$(lease_path "$LOOP_WT")"
assert_eq "$loop_create_code" "1" "--restack with conflict still exits 1"
assert_contains "$loop_create_err" "push issue-loop" "--restack guidance ends with the worktree push publish step"
assert_path_exists "$LOOP_LEASE" "--restack records the lease before pausing in the conflict"
assert_eq "$(cat "$LOOP_LEASE")" "refs/heads/issue-loop $loop_remote_pre" "recorded lease names the branch and the pre-restack remote head"

# Resolve, continue, and finish setup exactly as the guidance instructs.
printf 'resolved\n' > "$LOOP_WT/file.txt"
git -C "$LOOP_WT" add file.txt
GIT_EDITOR=true git -C "$LOOP_WT" rebase --continue >/dev/null 2>&1
loop_reuse_out=$(cd "$LOOP_ROOT/main" && "$WORKTREE_SCRIPT" create issue-loop --reuse 2>"$LOOP_ROOT/reuse.err")
assert_eq "$loop_reuse_out" "$LOOP_WT" "create --reuse after the resolved restack finishes setup"
assert_path_exists "$LOOP_LEASE" "finishing setup keeps the recorded lease for the coming push"

set +e
(
  cd "$LOOP_ROOT/main" && \
    "$WORKTREE_SCRIPT" push issue-loop >"$LOOP_ROOT/push.out" 2>"$LOOP_ROOT/push.err"
)
loop_push_code=$?
set -e
assert_eq "$loop_push_code" "0" "push publishes the restacked branch via the recorded lease"
assert_not_contains "$(cat "$LOOP_ROOT/push.err")" "not contained in local branch" "push does not hit the post-rewrite ancestry refusal"
assert_path_absent "$LOOP_LEASE" "successful push consumes the recorded lease"
assert_eq "$(git --git-dir="$LOOP_ROOT/origin.git" rev-parse refs/heads/issue-loop)" "$(git -C "$LOOP_WT" rev-parse HEAD)" "remote head matches the restacked local head"

# --- Clean-reuse rebase (no conflict) has the same rewrite; push must work -----
CLEAN_ROOT="$TMP_ROOT/clean"
make_published_pair "$CLEAN_ROOT" issue-clean
CLEAN_WT="$CLEAN_ROOT/trees/issue-clean"
# main advances on an unrelated file — the reuse rebase is clean but rewrites.
printf 'advanced\n' > "$CLEAN_ROOT/main/main-advanced.txt"
git -C "$CLEAN_ROOT/main" add main-advanced.txt
git -C "$CLEAN_ROOT/main" commit -q -m 'advance main'
git -C "$CLEAN_ROOT/main" push -q origin main
clean_remote_pre="$(git --git-dir="$CLEAN_ROOT/origin.git" rev-parse refs/heads/issue-clean)"
clean_out=$(cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" create issue-clean --reuse 2>"$CLEAN_ROOT/reuse.err")
CLEAN_LEASE="$(lease_path "$CLEAN_WT")"
assert_eq "$clean_out" "$CLEAN_WT" "clean reuse still prints the worktree path"
assert_eq "$(cat "$CLEAN_LEASE")" "refs/heads/issue-clean $clean_remote_pre" "clean reuse rebase records the lease too"
set +e
(
  cd "$CLEAN_ROOT/main" && \
    "$WORKTREE_SCRIPT" push issue-clean >"$CLEAN_ROOT/push.out" 2>"$CLEAN_ROOT/push.err"
)
clean_push_code=$?
set -e
assert_eq "$clean_push_code" "0" "push publishes the clean-reuse rebase via the recorded lease"
assert_path_absent "$CLEAN_LEASE" "successful push consumes the clean-reuse lease"
assert_eq "$(git --git-dir="$CLEAN_ROOT/origin.git" rev-parse refs/heads/issue-clean)" "$(git -C "$CLEAN_WT" rev-parse HEAD)" "remote head matches the rebased local head"

# --- Remote moved after the restack: lease rejects, record discarded -----------
MOVED_ROOT="$TMP_ROOT/moved"
make_published_pair "$MOVED_ROOT" issue-moved
MOVED_WT="$MOVED_ROOT/trees/issue-moved"
printf 'advanced\n' > "$MOVED_ROOT/main/main-advanced.txt"
git -C "$MOVED_ROOT/main" add main-advanced.txt
git -C "$MOVED_ROOT/main" commit -q -m 'advance main'
git -C "$MOVED_ROOT/main" push -q origin main
(cd "$MOVED_ROOT/main" && "$WORKTREE_SCRIPT" create issue-moved --reuse >/dev/null 2>&1)
MOVED_LEASE="$(lease_path "$MOVED_WT")"
assert_path_exists "$MOVED_LEASE" "reuse rebase recorded the lease before the remote moved"
# Someone else pushes to the branch after the restack.
git clone -q "$MOVED_ROOT/origin.git" "$MOVED_ROOT/external"
git -C "$MOVED_ROOT/external" config user.email test@example.com
git -C "$MOVED_ROOT/external" config user.name Test
git -C "$MOVED_ROOT/external" config commit.gpgsign false
git -C "$MOVED_ROOT/external" checkout -q issue-moved
printf 'external\n' > "$MOVED_ROOT/external/external.txt"
git -C "$MOVED_ROOT/external" add external.txt
git -C "$MOVED_ROOT/external" commit -q -m 'external edit'
git -C "$MOVED_ROOT/external" push -q origin issue-moved
moved_remote_head="$(git --git-dir="$MOVED_ROOT/origin.git" rev-parse refs/heads/issue-moved)"
set +e
(
  cd "$MOVED_ROOT/main" && \
    "$WORKTREE_SCRIPT" push issue-moved >"$MOVED_ROOT/push.out" 2>"$MOVED_ROOT/push.err"
)
moved_push_code=$?
set -e
moved_push_err="$(cat "$MOVED_ROOT/push.err")"
assert_eq "$moved_push_code" "1" "push fails when the remote moved past the recorded lease"
assert_contains "$moved_push_err" "moved from" "error says the remote moved after the restack"
assert_contains "$moved_push_err" "after the restack was recorded" "error attributes the rejection to the restack lease"
assert_contains "$moved_push_err" "Fetch and integrate" "error instructs integrating the new remote commits"
assert_path_absent "$MOVED_LEASE" "the stale restack record is discarded"
assert_eq "$(git --git-dir="$MOVED_ROOT/origin.git" rev-parse refs/heads/issue-moved)" "$moved_remote_head" "the moved remote head was not overwritten"

# --- Divergence without any restack record: today's fail-closed refusal --------
PLAIN_ROOT="$TMP_ROOT/plain"
make_published_pair "$PLAIN_ROOT" issue-plain
PLAIN_WT="$PLAIN_ROOT/trees/issue-plain"
plain_remote_pre="$(git --git-dir="$PLAIN_ROOT/origin.git" rev-parse refs/heads/issue-plain)"
# Rewrite local history outside any tool-authorized restack.
git -C "$PLAIN_WT" commit -q --amend -m 'amended feature edit'
assert_path_absent "$(lease_path "$PLAIN_WT")" "no restack record exists for the manual rewrite"
set +e
(
  cd "$PLAIN_ROOT/main" && \
    "$WORKTREE_SCRIPT" push issue-plain >"$PLAIN_ROOT/push.out" 2>"$PLAIN_ROOT/push.err"
)
plain_push_code=$?
set -e
plain_push_err="$(cat "$PLAIN_ROOT/push.err")"
assert_eq "$plain_push_code" "1" "push without a restack record still refuses divergence"
assert_contains "$plain_push_err" "not contained in local branch" "unchanged fail-closed ancestry error"
assert_contains "$plain_push_err" "Fetch and rebase/merge" "unchanged fail-closed recovery instruction"
assert_eq "$(git --git-dir="$PLAIN_ROOT/origin.git" rev-parse refs/heads/issue-plain)" "$plain_remote_pre" "remote branch is untouched"

# --- Record naming a different branch is ignored (fail closed) -----------------
FOREIGN_ROOT="$TMP_ROOT/foreign"
make_published_pair "$FOREIGN_ROOT" issue-foreign
FOREIGN_WT="$FOREIGN_ROOT/trees/issue-foreign"
foreign_remote_pre="$(git --git-dir="$FOREIGN_ROOT/origin.git" rev-parse refs/heads/issue-foreign)"
git -C "$FOREIGN_WT" commit -q --amend -m 'amended feature edit'
FOREIGN_LEASE="$(lease_path "$FOREIGN_WT")"
printf 'refs/heads/some-other-branch %s\n' "$foreign_remote_pre" > "$FOREIGN_LEASE"
set +e
(
  cd "$FOREIGN_ROOT/main" && \
    "$WORKTREE_SCRIPT" push issue-foreign >"$FOREIGN_ROOT/push.out" 2>"$FOREIGN_ROOT/push.err"
)
foreign_push_code=$?
set -e
foreign_push_err="$(cat "$FOREIGN_ROOT/push.err")"
assert_eq "$foreign_push_code" "1" "record for a different branch does not authorize the push"
assert_contains "$foreign_push_err" "not contained in local branch" "different-branch record falls back to today's refusal"
assert_path_exists "$FOREIGN_LEASE" "the ignored record is left in place"
assert_eq "$(cat "$FOREIGN_LEASE")" "refs/heads/some-other-branch $foreign_remote_pre" "the ignored record content is untouched"
assert_eq "$(git --git-dir="$FOREIGN_ROOT/origin.git" rev-parse refs/heads/issue-foreign)" "$foreign_remote_pre" "remote branch is untouched"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
