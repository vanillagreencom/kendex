#!/usr/bin/env bash
# Regression tests for `worktree create` reuse rebase-conflict recovery (vstack#567).
#
# When `create` reuses an existing worktree and the rebase onto origin/<default>
# conflicts, the default path aborts the rebase — so the worktree is clean and
# there is no conflict state left to "resolve manually". The error must be
# truthful and actionable: list the conflicting files (captured before the
# abort) and name the two supported recovery paths (`--restack` or
# delete/recreate). `--restack` must redo the rebase and stop IN the conflict
# state with guarded continue/skip/abort guidance. A completed supported rewrite must carry
# an exact, one-worktree push authorization without weakening remote-movement
# or unexpected-local-divergence rejection. Clean-rebase reuse must keep
# working unchanged.
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

rebase_state_exists() {
  local wt="$1" state path
  for state in rebase-merge rebase-apply; do
    path="$(git -C "$wt" rev-parse --git-path "$state" 2>/dev/null)" || continue
    [[ "$path" == /* ]] || path="$wt/$path"
    if [[ -d "$path" ]]; then
      return 0
    fi
  done
  return 1
}

rebase_state_dir() {
  local wt="$1" state path
  for state in rebase-merge rebase-apply; do
    path="$(git -C "$wt" rev-parse --git-path "$state" 2>/dev/null)" || continue
    [[ "$path" == /* ]] || path="$wt/$path"
    if [[ -d "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

assert_rebase_in_progress() {
  local wt="$1" name="$2"
  if rebase_state_exists "$wt"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        no rebase-merge/rebase-apply state in: %s\n' "$name" "$wt"
  fi
}

assert_no_rebase_in_progress() {
  local wt="$1" name="$2"
  if rebase_state_exists "$wt"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        rebase state still present in: %s\n' "$name" "$wt"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
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
  # Pin the historical sibling trees/ base so this file's path assertions stay
  # explicit; default base-dir resolution is covered by worktree_base_dir.sh.
  printf 'WORKTREE_BASE_DIR="../trees"\n' > "$repo/.env"
}

# Build a main+origin pair whose issue worktree diverges from origin/main on
# the same line of file.txt, so a reuse rebase genuinely conflicts.
make_conflict_pair() {
  local root="$1" issue="$2"
  make_repo "$root/main"
  git init -q --bare "$root/origin.git"
  git -C "$root/main" remote add origin "$root/origin.git"
  git -C "$root/main" push -q -u origin main
  # Create through the script so reuse exercises the script's own worktree.
  (cd "$root/main" && "$WORKTREE_SCRIPT" create "$issue" >/dev/null 2>&1)
  local wt="$root/trees/$issue"
  printf 'feature\n' > "$wt/file.txt"
  git -C "$wt" add file.txt
  git -C "$wt" commit -q -m 'feature edit'
  printf 'main-side\n' > "$root/main/file.txt"
  git -C "$root/main" add file.txt
  git -C "$root/main" commit -q -m 'main edit'
  git -C "$root/main" push -q origin main
}

make_published_clean_pair() {
  local root="$1" issue="$2"
  make_repo "$root/main"
  git init -q --bare "$root/origin.git"
  git -C "$root/main" remote add origin "$root/origin.git"
  git -C "$root/main" push -q -u origin main
  (cd "$root/main" && "$WORKTREE_SCRIPT" create "$issue" >/dev/null 2>&1)
  local wt="$root/trees/$issue"
  printf 'feature\n' > "$wt/feature.txt"
  git -C "$wt" add feature.txt
  git -C "$wt" commit -q -m 'feature edit'
  git -C "$wt" push -q origin "HEAD:refs/heads/$issue"
  printf 'advanced\n' > "$root/main/main-advanced.txt"
  git -C "$root/main" add main-advanced.txt
  git -C "$root/main" commit -q -m 'advance main'
  git -C "$root/main" push -q origin main
}

# Build the production-shaped case behind vstack#591: the first local commit is
# already represented (with further edits) on main, so resolving its conflict
# to current-main bytes makes it empty; a later refresh-only commit must still
# replay after the guarded skip.
make_merged_then_refresh_pair() {
  local root="$1" issue="$2"
  make_repo "$root/main"
  git init -q --bare "$root/origin.git"
  git -C "$root/main" remote add origin "$root/origin.git"
  git -C "$root/main" push -q -u origin main
  (cd "$root/main" && "$WORKTREE_SCRIPT" create "$issue" >/dev/null 2>&1)
  local wt="$root/trees/$issue"
  printf 'already merged\n' > "$wt/file.txt"
  git -C "$wt" add file.txt
  git -C "$wt" commit -q -m 'already merged generated edit'
  printf 'refresh only\n' > "$wt/refresh-only.txt"
  git -C "$wt" add refresh-only.txt
  git -C "$wt" commit -q -m 'refresh generated assets'
  git -C "$wt" push -q origin "HEAD:refs/heads/$issue"
  printf 'already merged plus main follow-up\n' > "$root/main/file.txt"
  git -C "$root/main" add file.txt
  git -C "$root/main" commit -q -m 'merge equivalent and follow up'
  git -C "$root/main" push -q origin main
}

echo "=== worktree create reuse rebase-conflict recovery ==="

# --- Default path: abort, truthful and actionable error ------------------------
DEFAULT_ROOT="$TMP_ROOT/default"
make_conflict_pair "$DEFAULT_ROOT" issue-default
DEFAULT_WT="$DEFAULT_ROOT/trees/issue-default"
default_pre_head="$(git -C "$DEFAULT_WT" rev-parse HEAD)"
set +e
(
  cd "$DEFAULT_ROOT/main" && \
    "$WORKTREE_SCRIPT" create issue-default --reuse >"$DEFAULT_ROOT/create.out" 2>"$DEFAULT_ROOT/create.err"
)
default_code=$?
set -e
default_err="$(cat "$DEFAULT_ROOT/create.err")"
assert_eq "$default_code" "1" "default reuse with conflict exits 1"
assert_contains "$default_err" "Conflicting files:" "default error reports captured conflict list"
assert_contains "$default_err" "file.txt" "default error names the conflicting file"
assert_not_contains "$default_err" "Resolve manually" "default error does not claim a conflict state the abort erased"
assert_contains "$default_err" "aborted" "default error says the rebase was aborted"
assert_contains "$default_err" "--restack" "default error names the --restack recovery path"
assert_contains "$default_err" "remove issue-default" "default error names the delete/recreate recovery path"
assert_no_rebase_in_progress "$DEFAULT_WT" "default reuse leaves no rebase in progress"
assert_eq "$(git -C "$DEFAULT_WT" rev-parse HEAD)" "$default_pre_head" "default reuse restores pre-rebase HEAD"
assert_eq "$(git -C "$DEFAULT_WT" status --porcelain)" "" "default reuse leaves the worktree clean"

# --- --restack: stop in the conflict state with continue/abort guidance --------
RESTACK_ROOT="$TMP_ROOT/restack"
make_conflict_pair "$RESTACK_ROOT" issue-restack
RESTACK_WT="$RESTACK_ROOT/trees/issue-restack"
git -C "$RESTACK_WT" push -q origin HEAD:refs/heads/issue-restack
restack_remote_before="$(git --git-dir="$RESTACK_ROOT/origin.git" rev-parse refs/heads/issue-restack)"
set +e
(
  cd "$RESTACK_ROOT/main" && \
    "$WORKTREE_SCRIPT" create issue-restack --restack >"$RESTACK_ROOT/create.out" 2>"$RESTACK_ROOT/create.err"
)
restack_code=$?
set -e
restack_err="$(cat "$RESTACK_ROOT/create.err")"
assert_eq "$restack_code" "1" "--restack reuse with conflict exits 1"
assert_rebase_in_progress "$RESTACK_WT" "--restack leaves the rebase paused in the conflict state"
assert_eq "$(git -C "$RESTACK_WT" diff --name-only --diff-filter=U)" "file.txt" "--restack leaves file.txt unmerged for resolution"
assert_contains "$restack_err" "file.txt" "--restack error names the conflicting file"
assert_contains "$restack_err" "add <file>" "--restack error documents per-file staging"
assert_contains "$restack_err" "restack continue" "--restack error documents the guarded continue command"
assert_contains "$restack_err" "restack skip" "--restack error documents the guarded empty-commit skip command"
assert_contains "$restack_err" "restack abort" "--restack error documents the guarded abort escape hatch"
assert_not_contains "$restack_err" "rebase --continue" "--restack no longer prescribes a policy-rejected raw continue command"
assert_not_contains "$restack_err" "rebase --abort" "--restack no longer prescribes a policy-rejected raw abort command"

# Published paused states created before vstack#591 have the exact authorization
# fields but no explicit pending marker. Keep that in-flight recovery working.
RESTACK_STATE_DIR="$(rebase_state_dir "$RESTACK_WT")"
git -C "$RESTACK_WT" config --worktree --unset-all vstack-restack.pending
git -C "$RESTACK_WT" config --worktree --unset-all vstack-restack.stateToken
rm -f "$RESTACK_STATE_DIR/vstack-restack-token"
assert_eq "$(git -C "$RESTACK_WT" config --worktree --get vstack-restack.pending 2>/dev/null || true)" "" "legacy paused restack fixture omits the new pending marker"

# The documented recovery path must actually work end to end.
printf 'resolved\n' > "$RESTACK_WT/file.txt"
git -C "$RESTACK_WT" add file.txt
resolved_out=$(cd "$RESTACK_ROOT/main" && "$WORKTREE_SCRIPT" restack continue issue-restack 2>"$RESTACK_ROOT/resolved.err")
assert_contains "$resolved_out" "Completed guarded restack" "guarded continue completes the resolved restack"
assert_is_ancestor "$RESTACK_WT" origin/main HEAD "resolved restack branch contains origin/main"
assert_eq "$(cat "$RESTACK_WT/file.txt")" "resolved" "resolved restack keeps the manual resolution"
assert_eq "$(git -C "$RESTACK_WT" config --worktree --get vstack-restack.expectedRemoteOid)" "$restack_remote_before" "resolved restack preserves the exact pre-rewrite remote lease"
assert_eq "$(git -C "$RESTACK_WT" config --worktree --get vstack-restack.authorizedHead)" "$(git -C "$RESTACK_WT" rev-parse HEAD)" "resolved restack authorizes only its exact rewritten head"

set +e
(
  cd "$RESTACK_ROOT/main" && \
    "$WORKTREE_SCRIPT" push issue-restack >"$RESTACK_ROOT/push.out" 2>"$RESTACK_ROOT/push.err"
)
restack_push_code=$?
set -e
assert_eq "$restack_push_code" "0" "resolved supported restack pushes with its exact force-with-lease"
assert_eq "$(git --git-dir="$RESTACK_ROOT/origin.git" rev-parse refs/heads/issue-restack)" "$(git -C "$RESTACK_WT" rev-parse HEAD)" "resolved restack push publishes the rewritten head"
assert_eq "$(git -C "$RESTACK_WT" config --worktree --get vstack-restack.authorizedHead 2>/dev/null || true)" "" "successful push consumes restack authorization"

# A completed restack cannot be controlled again after its sequencer state is
# gone.
set +e
(cd "$RESTACK_ROOT/main" && "$WORKTREE_SCRIPT" restack continue issue-restack >/dev/null 2>"$RESTACK_ROOT/missing-state.err")
missing_state_code=$?
set -e
assert_eq "$missing_state_code" "1" "guarded continue rejects missing rebase state"
assert_contains "$(cat "$RESTACK_ROOT/missing-state.err")" "missing a paused rebase" "missing-state rejection is explicit"

# Unpublished branches have no remote OID to use as a legacy state marker.
# The explicit pending marker must still make their guarded recovery possible,
# then disappear without manufacturing force-push authorization.
UNPUBLISHED_ROOT="$TMP_ROOT/unpublished"
make_conflict_pair "$UNPUBLISHED_ROOT" issue-unpublished
UNPUBLISHED_WT="$UNPUBLISHED_ROOT/trees/issue-unpublished"
set +e
(cd "$UNPUBLISHED_ROOT/main" && "$WORKTREE_SCRIPT" create issue-unpublished --restack >/dev/null 2>"$UNPUBLISHED_ROOT/restack.err")
unpublished_restack_code=$?
set -e
assert_eq "$unpublished_restack_code" "1" "unpublished restack pauses on conflict"
assert_eq "$(git -C "$UNPUBLISHED_WT" config --worktree --get vstack-restack.pending)" "true" "unpublished paused restack records an explicit pending marker"
UNPUBLISHED_STATE_DIR="$(rebase_state_dir "$UNPUBLISHED_WT")"
assert_eq "$(cat "$UNPUBLISHED_STATE_DIR/vstack-restack-token")" "$(git -C "$UNPUBLISHED_WT" config --worktree --get vstack-restack.stateToken)" "unpublished paused restack binds config to the Git sequencer state"
printf 'resolved unpublished\n' > "$UNPUBLISHED_WT/file.txt"
git -C "$UNPUBLISHED_WT" add file.txt
unpublished_out="$(cd "$UNPUBLISHED_ROOT/main" && "$WORKTREE_SCRIPT" restack continue issue-unpublished 2>"$UNPUBLISHED_ROOT/continue.err")"
assert_contains "$unpublished_out" "Completed guarded restack" "guarded continue completes an unpublished restack"
assert_eq "$(git -C "$UNPUBLISHED_WT" config --worktree --get-regexp '^vstack-restack\.' 2>/dev/null || true)" "" "unpublished completion clears pending state without force-push authorization"
assert_is_ancestor "$UNPUBLISHED_WT" origin/main HEAD "unpublished guarded result contains current main"

# --- Already-merged empty commit followed by refresh-only commit ------------
MERGED_REFRESH_ROOT="$TMP_ROOT/merged-refresh"
make_merged_then_refresh_pair "$MERGED_REFRESH_ROOT" issue-merged-refresh
MERGED_REFRESH_WT="$MERGED_REFRESH_ROOT/trees/issue-merged-refresh"
merged_refresh_remote_before="$(git --git-dir="$MERGED_REFRESH_ROOT/origin.git" rev-parse refs/heads/issue-merged-refresh)"
set +e
(cd "$MERGED_REFRESH_ROOT/main" && "$WORKTREE_SCRIPT" create issue-merged-refresh --restack >/dev/null 2>"$MERGED_REFRESH_ROOT/restack.err")
merged_refresh_restack_code=$?
set -e
assert_eq "$merged_refresh_restack_code" "1" "merged-commit restack pauses on the represented edit"
assert_rebase_in_progress "$MERGED_REFRESH_WT" "merged-commit restack has a real paused rebase"
cp "$MERGED_REFRESH_ROOT/main/file.txt" "$MERGED_REFRESH_WT/file.txt"
git -C "$MERGED_REFRESH_WT" add file.txt
merged_refresh_skip_out="$(cd "$MERGED_REFRESH_ROOT/main" && "$WORKTREE_SCRIPT" restack skip issue-merged-refresh 2>"$MERGED_REFRESH_ROOT/skip.err")"
assert_contains "$merged_refresh_skip_out" "Completed guarded restack" "guarded skip drops the represented commit and completes the refresh replay"
assert_no_rebase_in_progress "$MERGED_REFRESH_WT" "guarded skip finishes the rebase"
assert_eq "$(cat "$MERGED_REFRESH_WT/file.txt")" "already merged plus main follow-up" "guarded skip preserves exact current-main bytes"
assert_eq "$(cat "$MERGED_REFRESH_WT/refresh-only.txt")" "refresh only" "guarded skip replays the later refresh-only commit"
assert_is_ancestor "$MERGED_REFRESH_WT" origin/main HEAD "merged-refresh result contains current main"
assert_eq "$(git -C "$MERGED_REFRESH_WT" config --worktree --get vstack-restack.expectedRemoteOid)" "$merged_refresh_remote_before" "merged-refresh result preserves the exact pre-rewrite remote lease"
assert_eq "$(git -C "$MERGED_REFRESH_WT" config --worktree --get vstack-restack.authorizedHead)" "$(git -C "$MERGED_REFRESH_WT" rev-parse HEAD)" "merged-refresh result authorizes only the exact rewritten head"
(cd "$MERGED_REFRESH_ROOT/main" && "$WORKTREE_SCRIPT" push issue-merged-refresh >/dev/null 2>"$MERGED_REFRESH_ROOT/push.err")
assert_eq "$(git --git-dir="$MERGED_REFRESH_ROOT/origin.git" rev-parse refs/heads/issue-merged-refresh)" "$(git -C "$MERGED_REFRESH_WT" rev-parse HEAD)" "merged-refresh exact-lease push publishes the refresh-only result"

# --- Wrong or missing tool authorization fails closed ------------------------
WRONG_STATE_ROOT="$TMP_ROOT/wrong-state"
make_conflict_pair "$WRONG_STATE_ROOT" issue-wrong-state
WRONG_STATE_WT="$WRONG_STATE_ROOT/trees/issue-wrong-state"
git -C "$WRONG_STATE_WT" push -q origin HEAD:refs/heads/issue-wrong-state
set +e
(cd "$WRONG_STATE_ROOT/main" && "$WORKTREE_SCRIPT" create issue-wrong-state --restack >/dev/null 2>"$WRONG_STATE_ROOT/restack.err")
wrong_state_restack_code=$?
set -e
assert_eq "$wrong_state_restack_code" "1" "wrong-state fixture starts from a tool-created paused restack"
WRONG_STATE_DIR="$(rebase_state_dir "$WRONG_STATE_WT")"
printf 'tampered\n' > "$WRONG_STATE_DIR/vstack-restack-token"
set +e
(cd "$WRONG_STATE_ROOT/main" && "$WORKTREE_SCRIPT" restack continue issue-wrong-state >/dev/null 2>"$WRONG_STATE_ROOT/token.err")
wrong_token_code=$?
set -e
assert_eq "$wrong_token_code" "1" "guarded continue rejects an unauthorized sequencer token"
assert_contains "$(cat "$WRONG_STATE_ROOT/token.err")" "matching tool-created state token" "unauthorized token rejection names the missing binding"
assert_rebase_in_progress "$WRONG_STATE_WT" "unauthorized token rejection leaves the rebase untouched"
git -C "$WRONG_STATE_WT" config --worktree --get vstack-restack.stateToken > "$WRONG_STATE_DIR/vstack-restack-token"
git -C "$WRONG_STATE_WT" config --worktree vstack-restack.branch unrelated-branch
set +e
(cd "$WRONG_STATE_ROOT/main" && "$WORKTREE_SCRIPT" restack skip issue-wrong-state >/dev/null 2>"$WRONG_STATE_ROOT/skip.err")
wrong_state_code=$?
set -e
assert_eq "$wrong_state_code" "1" "guarded skip rejects mismatched recorded branch state"
assert_contains "$(cat "$WRONG_STATE_ROOT/skip.err")" "not the rebase recorded by the worktree tool" "wrong-state rejection names the metadata mismatch"
assert_rebase_in_progress "$WRONG_STATE_WT" "wrong-state rejection does not control the unrelated rebase"
git -C "$WRONG_STATE_WT" config --worktree vstack-restack.branch issue-wrong-state
(cd "$WRONG_STATE_ROOT/main" && "$WORKTREE_SCRIPT" restack abort issue-wrong-state >/dev/null)
assert_no_rebase_in_progress "$WRONG_STATE_WT" "guarded abort works after restoring exact recorded state"

# --- Consecutive clean restacks preserve the exact authorization chain -------
CHAINED_ROOT="$TMP_ROOT/chained-restack"
make_published_clean_pair "$CHAINED_ROOT" issue-chained-restack
CHAINED_WT="$CHAINED_ROOT/trees/issue-chained-restack"
chained_remote_before="$(git --git-dir="$CHAINED_ROOT/origin.git" rev-parse refs/heads/issue-chained-restack)"
(cd "$CHAINED_ROOT/main" && "$WORKTREE_SCRIPT" create issue-chained-restack --restack >/dev/null 2>"$CHAINED_ROOT/first-restack.err")
chained_first_head="$(git -C "$CHAINED_WT" rev-parse HEAD)"
assert_eq "$(git -C "$CHAINED_WT" config --worktree --get vstack-restack.authorizedHead)" "$chained_first_head" "first clean restack authorizes its rewritten head"

printf 'advanced twice\n' > "$CHAINED_ROOT/main/main-advanced-twice.txt"
git -C "$CHAINED_ROOT/main" add main-advanced-twice.txt
git -C "$CHAINED_ROOT/main" commit -q -m 'advance main again'
git -C "$CHAINED_ROOT/main" push -q origin main
set +e
(
  cd "$CHAINED_ROOT/main" && \
    "$WORKTREE_SCRIPT" create issue-chained-restack --restack >"$CHAINED_ROOT/second-restack.out" 2>"$CHAINED_ROOT/second-restack.err"
)
chained_second_code=$?
set -e
chained_second_head="$(git -C "$CHAINED_WT" rev-parse HEAD)"
assert_eq "$chained_second_code" "0" "second clean restack accepts the preserved exact-match authorization"
assert_ne "$chained_second_head" "$chained_first_head" "second clean restack rewrites the previously authorized head"
assert_is_ancestor "$CHAINED_WT" origin/main HEAD "second clean restack contains the latest origin/main"
assert_eq "$(git -C "$CHAINED_WT" config --worktree --get vstack-restack.expectedRemoteOid)" "$chained_remote_before" "consecutive restacks retain the original exact remote lease"
assert_eq "$(git -C "$CHAINED_WT" config --worktree --get vstack-restack.authorizedHead)" "$chained_second_head" "second clean restack authorizes only its rewritten head"

set +e
(
  cd "$CHAINED_ROOT/main" && \
    "$WORKTREE_SCRIPT" push issue-chained-restack >"$CHAINED_ROOT/push.out" 2>"$CHAINED_ROOT/push.err"
)
chained_push_code=$?
set -e
assert_eq "$chained_push_code" "0" "consecutive clean restacks push with the original exact lease"
assert_eq "$(git --git-dir="$CHAINED_ROOT/origin.git" rev-parse refs/heads/issue-chained-restack)" "$chained_second_head" "consecutive restack push publishes the final rewritten head"
assert_eq "$(git -C "$CHAINED_WT" config --worktree --get vstack-restack.authorizedHead 2>/dev/null || true)" "" "consecutive restack push consumes authorization"

# --- Remote movement while conflict resolution is pending fails closed -------
PENDING_MOVE_ROOT="$TMP_ROOT/pending-move"
make_conflict_pair "$PENDING_MOVE_ROOT" issue-pending-move
PENDING_MOVE_WT="$PENDING_MOVE_ROOT/trees/issue-pending-move"
git -C "$PENDING_MOVE_WT" push -q origin HEAD:refs/heads/issue-pending-move
set +e
(cd "$PENDING_MOVE_ROOT/main" && "$WORKTREE_SCRIPT" create issue-pending-move --restack >/dev/null 2>"$PENDING_MOVE_ROOT/restack.err")
pending_restack_code=$?
set -e
assert_eq "$pending_restack_code" "1" "pending-movement setup pauses the supported restack"
printf 'resolved\n' > "$PENDING_MOVE_WT/file.txt"
git -C "$PENDING_MOVE_WT" add file.txt
pending_move_old_oid="$(git --git-dir="$PENDING_MOVE_ROOT/origin.git" rev-parse refs/heads/issue-pending-move)"
pending_move_old_tree="$(git --git-dir="$PENDING_MOVE_ROOT/origin.git" rev-parse "${pending_move_old_oid}^{tree}")"
pending_move_external="$(GIT_AUTHOR_NAME=External GIT_AUTHOR_EMAIL=external@example.com GIT_COMMITTER_NAME=External GIT_COMMITTER_EMAIL=external@example.com git --git-dir="$PENDING_MOVE_ROOT/origin.git" commit-tree "$pending_move_old_tree" -p "$pending_move_old_oid" -m 'external pending movement')"
git --git-dir="$PENDING_MOVE_ROOT/origin.git" update-ref refs/heads/issue-pending-move "$pending_move_external"
set +e
(cd "$PENDING_MOVE_ROOT/main" && "$WORKTREE_SCRIPT" restack continue issue-pending-move >/dev/null 2>"$PENDING_MOVE_ROOT/continue.err")
pending_move_code=$?
set -e
assert_eq "$pending_move_code" "1" "remote movement during conflict resolution refuses guarded continuation"
assert_contains "$(cat "$PENDING_MOVE_ROOT/continue.err")" "changed while the supported restack was paused" "pending remote movement reports the invalidated continuation"
assert_rebase_in_progress "$PENDING_MOVE_WT" "rejected stale continuation leaves the rebase paused"
assert_eq "$(git --git-dir="$PENDING_MOVE_ROOT/origin.git" rev-parse refs/heads/issue-pending-move)" "$pending_move_external" "pending remote movement remains untouched"
printf 'WORKTREE_MKDIRS="../outside"\n' >>"$PENDING_MOVE_ROOT/main/.env"
set +e
(cd "$PENDING_MOVE_ROOT/main" && "$WORKTREE_SCRIPT" restack abort issue-pending-move >"$PENDING_MOVE_ROOT/abort.out" 2>"$PENDING_MOVE_ROOT/abort.err")
pending_abort_code=$?
set -e
assert_eq "$pending_abort_code" "0" "guarded abort remains successful when setup config becomes invalid"
assert_contains "$(cat "$PENDING_MOVE_ROOT/abort.err")" "Restack was aborted successfully" "guarded abort reports post-abort setup failure separately"
assert_no_rebase_in_progress "$PENDING_MOVE_WT" "guarded abort remains available after remote movement"

# --- Remote movement after authorization still fails the exact lease ---------
REMOTE_MOVE_ROOT="$TMP_ROOT/remote-move"
make_published_clean_pair "$REMOTE_MOVE_ROOT" issue-remote-move
REMOTE_MOVE_WT="$REMOTE_MOVE_ROOT/trees/issue-remote-move"
(cd "$REMOTE_MOVE_ROOT/main" && "$WORKTREE_SCRIPT" create issue-remote-move --reuse >/dev/null 2>"$REMOTE_MOVE_ROOT/create.err")
remote_move_old_oid="$(git --git-dir="$REMOTE_MOVE_ROOT/origin.git" rev-parse refs/heads/issue-remote-move)"
remote_move_old_tree="$(git --git-dir="$REMOTE_MOVE_ROOT/origin.git" rev-parse "${remote_move_old_oid}^{tree}")"
remote_move_external="$(GIT_AUTHOR_NAME=External GIT_AUTHOR_EMAIL=external@example.com GIT_COMMITTER_NAME=External GIT_COMMITTER_EMAIL=external@example.com git --git-dir="$REMOTE_MOVE_ROOT/origin.git" commit-tree "$remote_move_old_tree" -p "$remote_move_old_oid" -m 'external movement')"
git --git-dir="$REMOTE_MOVE_ROOT/origin.git" update-ref refs/heads/issue-remote-move "$remote_move_external"
set +e
(
  cd "$REMOTE_MOVE_ROOT/main" && \
    "$WORKTREE_SCRIPT" push issue-remote-move >"$REMOTE_MOVE_ROOT/push.out" 2>"$REMOTE_MOVE_ROOT/push.err"
)
remote_move_code=$?
set -e
assert_eq "$remote_move_code" "1" "remote movement after restack authorization rejects the push"
assert_eq "$(git --git-dir="$REMOTE_MOVE_ROOT/origin.git" rev-parse refs/heads/issue-remote-move)" "$remote_move_external" "exact lease preserves the externally advanced remote"
assert_contains "$(cat "$REMOTE_MOVE_ROOT/push.err")" "force-with-lease expectation" "remote movement reports exact-lease rejection"

# --- An unrelated local rewrite cannot reuse prior restack authorization ------
LOCAL_MOVE_ROOT="$TMP_ROOT/local-move"
make_published_clean_pair "$LOCAL_MOVE_ROOT" issue-local-move
LOCAL_MOVE_WT="$LOCAL_MOVE_ROOT/trees/issue-local-move"
(cd "$LOCAL_MOVE_ROOT/main" && "$WORKTREE_SCRIPT" create issue-local-move --reuse >/dev/null 2>"$LOCAL_MOVE_ROOT/create.err")
local_move_tree="$(git -C "$LOCAL_MOVE_WT" rev-parse "origin/main^{tree}")"
local_move_unexpected="$(git -C "$LOCAL_MOVE_WT" commit-tree "$local_move_tree" -p origin/main -m 'unexpected local rewrite')"
git -C "$LOCAL_MOVE_WT" reset -q --hard "$local_move_unexpected"
local_move_remote_before="$(git --git-dir="$LOCAL_MOVE_ROOT/origin.git" rev-parse refs/heads/issue-local-move)"
set +e
(
  cd "$LOCAL_MOVE_ROOT/main" && \
    "$WORKTREE_SCRIPT" push issue-local-move >"$LOCAL_MOVE_ROOT/push.out" 2>"$LOCAL_MOVE_ROOT/push.err"
)
local_move_code=$?
set -e
assert_eq "$local_move_code" "1" "unexpected local rewrite is not covered by prior restack authorization"
assert_eq "$(git --git-dir="$LOCAL_MOVE_ROOT/origin.git" rev-parse refs/heads/issue-local-move)" "$local_move_remote_before" "unexpected local rewrite leaves remote unchanged"
assert_contains "$(cat "$LOCAL_MOVE_ROOT/push.err")" "not contained in local branch" "unexpected local rewrite reports divergence"

# --- Clean-rebase reuse unchanged ----------------------------------------------
CLEAN_ROOT="$TMP_ROOT/clean"
make_repo "$CLEAN_ROOT/main"
git init -q --bare "$CLEAN_ROOT/origin.git"
git -C "$CLEAN_ROOT/main" remote add origin "$CLEAN_ROOT/origin.git"
git -C "$CLEAN_ROOT/main" push -q -u origin main
(cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" create issue-clean >/dev/null 2>&1)
CLEAN_WT="$CLEAN_ROOT/trees/issue-clean"
printf 'fix\n' > "$CLEAN_WT/fix.txt"
git -C "$CLEAN_WT" add fix.txt
git -C "$CLEAN_WT" commit -q -m 'review fix'
printf 'advanced\n' > "$CLEAN_ROOT/main/main-advanced.txt"
git -C "$CLEAN_ROOT/main" add main-advanced.txt
git -C "$CLEAN_ROOT/main" commit -q -m 'advance main'
git -C "$CLEAN_ROOT/main" push -q origin main
clean_pre_head="$(git -C "$CLEAN_WT" rev-parse HEAD)"
clean_out=$(cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" create issue-clean --reuse 2>"$CLEAN_ROOT/create.err")
assert_eq "$clean_out" "$CLEAN_WT" "clean reuse still prints the worktree path"
assert_ne "$(git -C "$CLEAN_WT" rev-parse HEAD)" "$clean_pre_head" "clean reuse rebased HEAD onto advanced origin/main"
assert_path_exists "$CLEAN_WT/main-advanced.txt" "clean reuse pulled in the advanced main content"
assert_is_ancestor "$CLEAN_WT" origin/main HEAD "clean reuse contains origin/main after rebase"
restack_noop_out=$(cd "$CLEAN_ROOT/main" && "$WORKTREE_SCRIPT" create issue-clean --restack 2>"$CLEAN_ROOT/restack-noop.err")
assert_eq "$restack_noop_out" "$CLEAN_WT" "--restack is a no-op when no rebase conflict occurs"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
