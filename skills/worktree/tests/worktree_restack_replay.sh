#!/usr/bin/env bash
# Behavioral tests for the policy-blocked restack replay engine (vstack#899).
#
# `create <ID> --reuse --replay` / `--restack --replay` must produce the same
# rebased history as the rebase engine from ordered plain cherry-picks — no
# rebase porcelain at any level, proven here by a PATH shim that fails any git
# invocation carrying a `rebase` argument. The replay must refuse dirty trees
# and merge commits before mutating anything, move the branch ref only after
# the whole replay succeeds, pause conflicts into the same guarded state the
# rebase engine uses (same `restack continue|skip|abort` controls, same state
# token binding), and record the same pinned force-with-lease authorization
# that `worktree push` consumes and the remote lease model fails closed on.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$SKILL_DIR/scripts/worktree}"
SKILL_MD="$SKILL_DIR/SKILL.md"
README_MD="$SKILL_DIR/README.md"
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

# The point of --replay is passing execution policies that reject `git rebase`.
# Replay-path invocations run with this shim first on PATH, so any rebase
# porcelain anywhere under the tool fails the command (and the test).
REAL_GIT="$(command -v git)"
mkdir -p "$TMP_ROOT/norebase"
cat >"$TMP_ROOT/norebase/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == rebase ]]; then
    echo "rebase porcelain invoked under --replay: git \$*" >&2
    exit 97
  fi
done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$TMP_ROOT/norebase/git"
NOREBASE_PATH="$TMP_ROOT/norebase:$PATH"

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

sequencer_dir() {
  local wt="$1" path=""
  path="$(git -C "$wt" rev-parse --git-path sequencer 2>/dev/null)" || return 1
  [[ "$path" == /* ]] || path="$wt/$path"
  [[ -d "$path" ]] || return 1
  printf '%s\n' "$path"
}

assert_replay_paused() {
  local wt="$1" name="$2"
  if sequencer_dir "$wt" >/dev/null; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        no cherry-pick sequencer state in: %s\n' "$name" "$wt"
  fi
}

assert_no_replay_paused() {
  local wt="$1" name="$2"
  if sequencer_dir "$wt" >/dev/null; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        cherry-pick sequencer state still present in: %s\n' "$name" "$wt"
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
  printf 'WORKTREE_BASE_DIR="../trees"\n' > "$repo/.env"
}

# Feature edit on a non-conflicting file; main advances on another file, so the
# replay onto the moved base is clean.
make_clean_pair() {
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

# Both sides edit the same line of file.txt, so the replay genuinely conflicts.
make_conflict_pair() {
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
  printf 'main-side\n' > "$root/main/file.txt"
  git -C "$root/main" add file.txt
  git -C "$root/main" commit -q -m 'main edit'
  git -C "$root/main" push -q origin main
}

echo "=== worktree restack --replay (policy-blocked rebase engine) ==="

# --- Happy path: clean replay onto a moved base, no rebase porcelain ---------
HAPPY_ROOT="$TMP_ROOT/happy"
make_clean_pair "$HAPPY_ROOT" issue-replay-happy
HAPPY_WT="$HAPPY_ROOT/trees/issue-replay-happy"
happy_pre_head="$(git -C "$HAPPY_WT" rev-parse HEAD)"
happy_remote_before="$(git --git-dir="$HAPPY_ROOT/origin.git" rev-parse refs/heads/issue-replay-happy)"
set +e
happy_out="$(cd "$HAPPY_ROOT/main" && PATH="$NOREBASE_PATH" "$WORKTREE_SCRIPT" create issue-replay-happy --reuse --replay 2>"$HAPPY_ROOT/create.err")"
happy_code=$?
set -e
assert_eq "$happy_code" "0" "clean replay exits 0 with rebase porcelain fenced off"
assert_eq "$happy_out" "$HAPPY_WT" "clean replay prints the worktree path"
assert_ne "$(git -C "$HAPPY_WT" rev-parse HEAD)" "$happy_pre_head" "clean replay rewrote HEAD onto the moved base"
assert_is_ancestor "$HAPPY_WT" origin/main HEAD "replayed branch contains origin/main"
assert_path_exists "$HAPPY_WT/feature.txt" "replayed branch keeps the feature commit"
assert_path_exists "$HAPPY_WT/main-advanced.txt" "replayed branch picked up the advanced main content"
assert_eq "$(git -C "$HAPPY_WT" branch --show-current)" "issue-replay-happy" "replay reattaches the issue branch after moving it"
assert_eq "$(git -C "$HAPPY_WT" status --porcelain)" "" "replay leaves the worktree clean"
assert_no_replay_paused "$HAPPY_WT" "clean replay leaves no sequencer state"
assert_eq "$(git -C "$HAPPY_WT" config --worktree --get vstack-restack.expectedRemoteOid)" "$happy_remote_before" "replay preserves the exact pre-rewrite remote lease"
assert_eq "$(git -C "$HAPPY_WT" config --worktree --get vstack-restack.authorizedHead)" "$(git -C "$HAPPY_WT" rev-parse HEAD)" "replay authorizes only its exact rewritten head"
assert_eq "$(git -C "$HAPPY_WT" config --worktree --get vstack-restack.mode 2>/dev/null || true)" "" "completed replay clears its engine marker"

set +e
(cd "$HAPPY_ROOT/main" && PATH="$NOREBASE_PATH" "$WORKTREE_SCRIPT" push issue-replay-happy >/dev/null 2>"$HAPPY_ROOT/push.err")
happy_push_code=$?
set -e
assert_eq "$happy_push_code" "0" "replayed branch pushes with its exact force-with-lease"
assert_eq "$(git --git-dir="$HAPPY_ROOT/origin.git" rev-parse refs/heads/issue-replay-happy)" "$(git -C "$HAPPY_WT" rev-parse HEAD)" "lease push publishes the replayed head"
assert_eq "$(git -C "$HAPPY_WT" config --worktree --get vstack-restack.authorizedHead 2>/dev/null || true)" "" "successful push consumes replay authorization"

# --- Dirty tree is refused before any mutation --------------------------------
DIRTY_ROOT="$TMP_ROOT/dirty"
make_clean_pair "$DIRTY_ROOT" issue-replay-dirty
DIRTY_WT="$DIRTY_ROOT/trees/issue-replay-dirty"
printf 'uncommitted\n' >> "$DIRTY_WT/file.txt"
dirty_pre_head="$(git -C "$DIRTY_WT" rev-parse HEAD)"
set +e
(cd "$DIRTY_ROOT/main" && "$WORKTREE_SCRIPT" create issue-replay-dirty --reuse --replay >/dev/null 2>"$DIRTY_ROOT/create.err")
dirty_code=$?
set -e
assert_eq "$dirty_code" "1" "dirty-tree replay exits 1"
assert_contains "$(cat "$DIRTY_ROOT/create.err")" "uncommitted changes" "dirty-tree refusal names the cause"
assert_eq "$(git -C "$DIRTY_WT" rev-parse HEAD)" "$dirty_pre_head" "dirty-tree refusal leaves HEAD unchanged"
assert_eq "$(git -C "$DIRTY_WT" branch --show-current)" "issue-replay-dirty" "dirty-tree refusal leaves the branch checked out"
assert_ne "$(git -C "$DIRTY_WT" status --porcelain)" "" "dirty-tree refusal preserves the uncommitted change"

# --- Merge commits in the range are refused up front ---------------------------
MERGE_ROOT="$TMP_ROOT/merge"
make_clean_pair "$MERGE_ROOT" issue-replay-merge
MERGE_WT="$MERGE_ROOT/trees/issue-replay-merge"
git -C "$MERGE_WT" checkout -q -b side
printf 'side\n' > "$MERGE_WT/side.txt"
git -C "$MERGE_WT" add side.txt
git -C "$MERGE_WT" commit -q -m 'side edit'
git -C "$MERGE_WT" checkout -q issue-replay-merge
git -C "$MERGE_WT" merge -q --no-ff --no-edit side
git -C "$MERGE_WT" branch -q -D side
merge_pre_head="$(git -C "$MERGE_WT" rev-parse HEAD)"
set +e
(cd "$MERGE_ROOT/main" && "$WORKTREE_SCRIPT" create issue-replay-merge --reuse --replay >/dev/null 2>"$MERGE_ROOT/create.err")
merge_code=$?
set -e
assert_eq "$merge_code" "1" "merge-commit replay exits 1"
assert_contains "$(cat "$MERGE_ROOT/create.err")" "merge commits" "merge refusal names the unrepresentable history"
assert_contains "$(cat "$MERGE_ROOT/create.err")" "--reuse" "merge refusal routes to the rebase engine"
assert_eq "$(git -C "$MERGE_WT" rev-parse HEAD)" "$merge_pre_head" "merge refusal leaves HEAD unchanged"
assert_no_replay_paused "$MERGE_WT" "merge refusal leaves no sequencer state"

# --- Conflict under bare --reuse --replay aborts back to a clean state ---------
ABORTING_ROOT="$TMP_ROOT/aborting"
make_conflict_pair "$ABORTING_ROOT" issue-replay-aborting
ABORTING_WT="$ABORTING_ROOT/trees/issue-replay-aborting"
aborting_pre_head="$(git -C "$ABORTING_WT" rev-parse HEAD)"
set +e
(cd "$ABORTING_ROOT/main" && PATH="$NOREBASE_PATH" "$WORKTREE_SCRIPT" create issue-replay-aborting --reuse --replay >/dev/null 2>"$ABORTING_ROOT/create.err")
aborting_code=$?
set -e
aborting_err="$(cat "$ABORTING_ROOT/create.err")"
assert_eq "$aborting_code" "1" "conflicting bare replay exits 1"
assert_contains "$aborting_err" "Conflicting files:" "bare replay reports the captured conflict list"
assert_contains "$aborting_err" "file.txt" "bare replay names the conflicting file"
assert_contains "$aborting_err" "aborted" "bare replay says the replay was aborted"
assert_contains "$aborting_err" "--restack --replay" "bare replay routes conflicts to the pausing replay mode"
assert_no_replay_paused "$ABORTING_WT" "bare replay leaves no sequencer state"
assert_eq "$(git -C "$ABORTING_WT" rev-parse HEAD)" "$aborting_pre_head" "bare replay restores the pre-replay HEAD"
assert_eq "$(git -C "$ABORTING_WT" branch --show-current)" "issue-replay-aborting" "bare replay reattaches the issue branch"
assert_eq "$(git -C "$ABORTING_WT" status --porcelain)" "" "bare replay leaves the worktree clean"

# --- Conflict under --restack --replay pauses the guarded state, then continue -
PAUSE_ROOT="$TMP_ROOT/pause"
make_conflict_pair "$PAUSE_ROOT" issue-replay-pause
PAUSE_WT="$PAUSE_ROOT/trees/issue-replay-pause"
git -C "$PAUSE_WT" push -q origin HEAD:refs/heads/issue-replay-pause
pause_pre_head="$(git -C "$PAUSE_WT" rev-parse HEAD)"
pause_remote_before="$(git --git-dir="$PAUSE_ROOT/origin.git" rev-parse refs/heads/issue-replay-pause)"
set +e
(cd "$PAUSE_ROOT/main" && PATH="$NOREBASE_PATH" "$WORKTREE_SCRIPT" create issue-replay-pause --restack --replay >/dev/null 2>"$PAUSE_ROOT/create.err")
pause_code=$?
set -e
pause_err="$(cat "$PAUSE_ROOT/create.err")"
assert_eq "$pause_code" "1" "pausing replay with conflict exits 1"
assert_replay_paused "$PAUSE_WT" "--restack --replay leaves the cherry-pick paused"
assert_eq "$(git -C "$PAUSE_WT" diff --name-only --diff-filter=U)" "file.txt" "paused replay leaves file.txt unmerged for resolution"
assert_contains "$pause_err" "restack continue" "paused replay documents the guarded continue command"
assert_contains "$pause_err" "restack skip" "paused replay documents the guarded skip command"
assert_contains "$pause_err" "restack abort" "paused replay documents the guarded abort escape hatch"
assert_eq "$(git -C "$PAUSE_WT" config --worktree --get vstack-restack.mode)" "replay" "paused replay records the replay engine marker"
assert_eq "$(git -C "$PAUSE_WT" branch --show-current 2>/dev/null || true)" "" "paused replay keeps HEAD detached"
assert_eq "$(git -C "$PAUSE_WT" rev-parse refs/heads/issue-replay-pause)" "$pause_pre_head" "paused replay has not moved the branch ref"
PAUSE_SEQ_DIR="$(sequencer_dir "$PAUSE_WT")"
assert_eq "$(cat "$PAUSE_SEQ_DIR/vstack-restack-token")" "$(git -C "$PAUSE_WT" config --worktree --get vstack-restack.stateToken)" "paused replay binds config to the Git sequencer state"

printf 'resolved\n' > "$PAUSE_WT/file.txt"
git -C "$PAUSE_WT" add file.txt
pause_continue_out="$(cd "$PAUSE_ROOT/main" && PATH="$NOREBASE_PATH" "$WORKTREE_SCRIPT" restack continue issue-replay-pause 2>"$PAUSE_ROOT/continue.err")"
assert_contains "$pause_continue_out" "Completed guarded restack" "guarded continue completes the resolved replay"
assert_eq "$(git -C "$PAUSE_WT" branch --show-current)" "issue-replay-pause" "completed replay moves and reattaches the issue branch"
assert_is_ancestor "$PAUSE_WT" origin/main HEAD "completed replay contains origin/main"
assert_eq "$(cat "$PAUSE_WT/file.txt")" "resolved" "completed replay keeps the manual resolution"
assert_no_replay_paused "$PAUSE_WT" "completed replay clears the sequencer state"
assert_eq "$(git -C "$PAUSE_WT" config --worktree --get vstack-restack.expectedRemoteOid)" "$pause_remote_before" "completed replay preserves the exact pre-rewrite remote lease"
assert_eq "$(git -C "$PAUSE_WT" config --worktree --get vstack-restack.authorizedHead)" "$(git -C "$PAUSE_WT" rev-parse HEAD)" "completed replay authorizes only its exact rewritten head"

set +e
(cd "$PAUSE_ROOT/main" && "$WORKTREE_SCRIPT" push issue-replay-pause >/dev/null 2>"$PAUSE_ROOT/push.err")
pause_push_code=$?
set -e
assert_eq "$pause_push_code" "0" "resolved replay pushes with its exact force-with-lease"
assert_eq "$(git --git-dir="$PAUSE_ROOT/origin.git" rev-parse refs/heads/issue-replay-pause)" "$(git -C "$PAUSE_WT" rev-parse HEAD)" "resolved replay push publishes the rewritten head"

# --- Empty pick: guarded skip drops it and replays the rest --------------------
SKIP_ROOT="$TMP_ROOT/skip"
make_repo "$SKIP_ROOT/main"
git init -q --bare "$SKIP_ROOT/origin.git"
git -C "$SKIP_ROOT/main" remote add origin "$SKIP_ROOT/origin.git"
git -C "$SKIP_ROOT/main" push -q -u origin main
(cd "$SKIP_ROOT/main" && "$WORKTREE_SCRIPT" create issue-replay-skip >/dev/null 2>&1)
SKIP_WT="$SKIP_ROOT/trees/issue-replay-skip"
printf 'already merged\n' > "$SKIP_WT/file.txt"
git -C "$SKIP_WT" add file.txt
git -C "$SKIP_WT" commit -q -m 'already merged edit'
printf 'refresh only\n' > "$SKIP_WT/refresh-only.txt"
git -C "$SKIP_WT" add refresh-only.txt
git -C "$SKIP_WT" commit -q -m 'refresh only edit'
printf 'already merged plus follow-up\n' > "$SKIP_ROOT/main/file.txt"
git -C "$SKIP_ROOT/main" add file.txt
git -C "$SKIP_ROOT/main" commit -q -m 'merge equivalent and follow up'
git -C "$SKIP_ROOT/main" push -q origin main
set +e
(cd "$SKIP_ROOT/main" && PATH="$NOREBASE_PATH" "$WORKTREE_SCRIPT" create issue-replay-skip --restack --replay >/dev/null 2>"$SKIP_ROOT/create.err")
skip_pause_code=$?
set -e
assert_eq "$skip_pause_code" "1" "represented-commit replay pauses on the conflict"
cp "$SKIP_ROOT/main/file.txt" "$SKIP_WT/file.txt"
git -C "$SKIP_WT" add file.txt
skip_out="$(cd "$SKIP_ROOT/main" && PATH="$NOREBASE_PATH" "$WORKTREE_SCRIPT" restack skip issue-replay-skip 2>"$SKIP_ROOT/skip.err")"
assert_contains "$skip_out" "Completed guarded restack" "guarded skip drops the represented pick and completes the replay"
assert_eq "$(cat "$SKIP_WT/file.txt")" "already merged plus follow-up" "guarded skip preserves exact current-main bytes"
assert_eq "$(cat "$SKIP_WT/refresh-only.txt")" "refresh only" "guarded skip replays the later refresh-only commit"
assert_eq "$(git -C "$SKIP_WT" branch --show-current)" "issue-replay-skip" "guarded skip reattaches the issue branch"
assert_is_ancestor "$SKIP_WT" origin/main HEAD "guarded skip result contains current main"

# --- Guarded abort restores the pre-replay branch (unpublished branch) ---------
ABORT_ROOT="$TMP_ROOT/abort"
make_conflict_pair "$ABORT_ROOT" issue-replay-abort
ABORT_WT="$ABORT_ROOT/trees/issue-replay-abort"
abort_pre_head="$(git -C "$ABORT_WT" rev-parse HEAD)"
set +e
(cd "$ABORT_ROOT/main" && "$WORKTREE_SCRIPT" create issue-replay-abort --restack --replay >/dev/null 2>"$ABORT_ROOT/create.err")
abort_pause_code=$?
set -e
assert_eq "$abort_pause_code" "1" "unpublished replay pauses on conflict"
assert_eq "$(git -C "$ABORT_WT" config --worktree --get vstack-restack.pending)" "true" "unpublished paused replay records the explicit pending marker"
abort_out="$(cd "$ABORT_ROOT/main" && PATH="$NOREBASE_PATH" "$WORKTREE_SCRIPT" restack abort issue-replay-abort 2>"$ABORT_ROOT/abort.err")"
assert_contains "$abort_out" "Aborted guarded restack" "guarded abort reports the restored branch"
assert_no_replay_paused "$ABORT_WT" "guarded abort clears the sequencer state"
assert_eq "$(git -C "$ABORT_WT" rev-parse HEAD)" "$abort_pre_head" "guarded abort restores the recorded original HEAD"
assert_eq "$(git -C "$ABORT_WT" branch --show-current)" "issue-replay-abort" "guarded abort reattaches the issue branch"
assert_eq "$(git -C "$ABORT_WT" status --porcelain)" "" "guarded abort leaves the worktree clean"
assert_eq "$(git -C "$ABORT_WT" config --worktree --get-regexp '^vstack-restack\.' 2>/dev/null || true)" "" "guarded abort clears pending state without authorization"

# --- Remote movement while paused refuses continuation, abort still works ------
MOVED_ROOT="$TMP_ROOT/moved"
make_conflict_pair "$MOVED_ROOT" issue-replay-moved
MOVED_WT="$MOVED_ROOT/trees/issue-replay-moved"
git -C "$MOVED_WT" push -q origin HEAD:refs/heads/issue-replay-moved
set +e
(cd "$MOVED_ROOT/main" && "$WORKTREE_SCRIPT" create issue-replay-moved --restack --replay >/dev/null 2>"$MOVED_ROOT/create.err")
moved_pause_code=$?
set -e
assert_eq "$moved_pause_code" "1" "moved-remote fixture pauses the replay"
printf 'resolved\n' > "$MOVED_WT/file.txt"
git -C "$MOVED_WT" add file.txt
moved_old_oid="$(git --git-dir="$MOVED_ROOT/origin.git" rev-parse refs/heads/issue-replay-moved)"
moved_old_tree="$(git --git-dir="$MOVED_ROOT/origin.git" rev-parse "${moved_old_oid}^{tree}")"
moved_external="$(GIT_AUTHOR_NAME=External GIT_AUTHOR_EMAIL=external@example.com GIT_COMMITTER_NAME=External GIT_COMMITTER_EMAIL=external@example.com git --git-dir="$MOVED_ROOT/origin.git" commit-tree "$moved_old_tree" -p "$moved_old_oid" -m 'external movement while paused')"
git --git-dir="$MOVED_ROOT/origin.git" update-ref refs/heads/issue-replay-moved "$moved_external"
set +e
(cd "$MOVED_ROOT/main" && "$WORKTREE_SCRIPT" restack continue issue-replay-moved >/dev/null 2>"$MOVED_ROOT/continue.err")
moved_continue_code=$?
set -e
assert_eq "$moved_continue_code" "1" "remote movement while paused refuses guarded continuation"
assert_contains "$(cat "$MOVED_ROOT/continue.err")" "changed while the supported restack was paused" "moved-remote refusal names the invalidated continuation"
assert_replay_paused "$MOVED_WT" "moved-remote refusal leaves the replay paused"
(cd "$MOVED_ROOT/main" && "$WORKTREE_SCRIPT" restack abort issue-replay-moved >/dev/null 2>&1)
assert_no_replay_paused "$MOVED_WT" "guarded abort remains available after remote movement"

# --- A push outside the recorded lease fails closed ----------------------------
LEASE_ROOT="$TMP_ROOT/lease"
make_clean_pair "$LEASE_ROOT" issue-replay-lease
LEASE_WT="$LEASE_ROOT/trees/issue-replay-lease"
(cd "$LEASE_ROOT/main" && "$WORKTREE_SCRIPT" create issue-replay-lease --reuse --replay >/dev/null 2>"$LEASE_ROOT/create.err")
lease_old_oid="$(git --git-dir="$LEASE_ROOT/origin.git" rev-parse refs/heads/issue-replay-lease)"
lease_old_tree="$(git --git-dir="$LEASE_ROOT/origin.git" rev-parse "${lease_old_oid}^{tree}")"
lease_external="$(GIT_AUTHOR_NAME=External GIT_AUTHOR_EMAIL=external@example.com GIT_COMMITTER_NAME=External GIT_COMMITTER_EMAIL=external@example.com git --git-dir="$LEASE_ROOT/origin.git" commit-tree "$lease_old_tree" -p "$lease_old_oid" -m 'external movement after authorization')"
git --git-dir="$LEASE_ROOT/origin.git" update-ref refs/heads/issue-replay-lease "$lease_external"
set +e
(cd "$LEASE_ROOT/main" && "$WORKTREE_SCRIPT" push issue-replay-lease >/dev/null 2>"$LEASE_ROOT/push.err")
lease_push_code=$?
set -e
assert_eq "$lease_push_code" "1" "remote movement after replay authorization rejects the push"
assert_eq "$(git --git-dir="$LEASE_ROOT/origin.git" rev-parse refs/heads/issue-replay-lease)" "$lease_external" "pinned lease preserves the externally advanced remote"
assert_contains "$(cat "$LEASE_ROOT/push.err")" "force-with-lease expectation" "outside-lease push reports the exact-lease rejection"

# --- --replay requires an engine to modify -------------------------------------
BAREFLAG_ROOT="$TMP_ROOT/bareflag"
make_repo "$BAREFLAG_ROOT/main"
git init -q --bare "$BAREFLAG_ROOT/origin.git"
git -C "$BAREFLAG_ROOT/main" remote add origin "$BAREFLAG_ROOT/origin.git"
git -C "$BAREFLAG_ROOT/main" push -q -u origin main
set +e
(cd "$BAREFLAG_ROOT/main" && "$WORKTREE_SCRIPT" create issue-replay-bare --replay >/dev/null 2>"$BAREFLAG_ROOT/create.err")
bareflag_code=$?
set -e
assert_eq "$bareflag_code" "1" "--replay without --reuse/--restack is refused"
assert_contains "$(cat "$BAREFLAG_ROOT/create.err")" "--reuse/--restack" "bare --replay refusal names the required engines"

# --- SKILL.md routes to the tool instead of encoding the procedure -------------
REPLAY_HEADING='### Policy-blocked rebase (cherry-pick replay fallback)'
if grep -qF -- "$REPLAY_HEADING" "$SKILL_MD"; then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "SKILL.md keeps the exact heading orch cross-references"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "SKILL.md lost the heading orch cross-references"
fi
replay_section="$(awk -v h="$REPLAY_HEADING" '$0 == h { insec = 1; next } insec && (/^## / || /^### /) { exit } insec { print }' "$SKILL_MD")"
replay_section_lines="$(printf '%s\n' "$replay_section" | grep -c '^' || true)"
if [[ "$replay_section_lines" -le 8 ]]; then
  PASS=$((PASS + 1)); printf '  ok    %s\n' "replay section is a short pointer ($replay_section_lines lines), not a procedure"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s (got %s lines)\n' "replay section should be a short pointer" "$replay_section_lines"
fi
assert_contains "$replay_section" "--replay" "replay section names the tool mode"
assert_contains "$replay_section" "restack continue|skip|abort" "replay section names the shared guarded controls"
if grep -qF -- '```' <<<"$replay_section"; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "replay section still carries fenced command blocks"
else
  PASS=$((PASS + 1)); printf '  ok    %s\n' "replay section carries no fenced command blocks"
fi
assert_contains "$(cat "$README_MD")" "--replay" "README routes policy-blocked rebases to the tool mode"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
