#!/usr/bin/env bash
# The restack state machine: what a rebase, a replay or a paused restack looks
# like on disk, whether a pending restack record still describes the worktree it
# was written for, and how an orphaned record is reported and cleared.
#
# Sourced by scripts/worktree after lib/messages.sh and lib/kendex-env.sh. The
# push-authorization records these validations read are written by that script;
# this library only judges them.

rebase_in_progress() {
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

restack_rebase_state_dir() {
  local wt="$1" state="" path=""
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

# The replay engine's paused state is Git's cherry-pick sequencer, which lives
# in the worktree-private git dir and records the detach point in its `head`
# file — the same role rebase-merge/onto plays for the rebase engine.
restack_replay_state_dir() {
  local wt="$1" path=""
  path="$(git -C "$wt" rev-parse --git-path sequencer 2>/dev/null)" || return 1
  [[ "$path" == /* ]] || path="$wt/$path"
  [[ -d "$path" ]] || return 1
  printf '%s\n' "$path"
}

replay_in_progress() {
  local wt="$1" path=""
  restack_replay_state_dir "$wt" >/dev/null 2>&1 && return 0
  path="$(git -C "$wt" rev-parse --git-path CHERRY_PICK_HEAD 2>/dev/null)" || return 1
  [[ "$path" == /* ]] || path="$wt/$path"
  [[ -f "$path" ]]
}

restack_paused_state_dir() {
  local wt="$1"
  if [[ "$(restack_state_get "$wt" mode)" == replay ]]; then
    restack_replay_state_dir "$wt"
  else
    restack_rebase_state_dir "$wt"
  fi
}

restack_engine_in_progress() {
  local wt="$1"
  if [[ "$(restack_state_get "$wt" mode)" == replay ]]; then
    replay_in_progress "$wt"
  else
    rebase_in_progress "$wt"
  fi
}

mark_pending_restack_state() {
  local wt="$1" state_dir="" state_token=""
  state_dir="$(restack_paused_state_dir "$wt")" || return 1
  state_token="$(restack_state_get "$wt" stateToken)"
  [[ -n "$state_token" ]] || return 1
  printf '%s\n' "$state_token" >"$state_dir/kendex-restack-token"
}

# Complete a finished replay: the branch ref moves only after the whole replay
# succeeded, then the worktree reattaches to it. This is the replay engine's
# only branch mutation, shared by the clean create path and restack
# continue/skip completion.
finish_replay_branch_move() {
  local wt="$1" branch="$2" base_oid="$3"
  if ! git -C "$wt" merge-base --is-ancestor "$base_oid" HEAD; then
    worktree_message replay-base-missing "$wt" "Error: Replayed tip in $wt does not contain the recorded base $base_oid; refusing to move '$branch'." >&2
    return 1
  fi
  if ! git -C "$wt" branch -f "$branch" HEAD >/dev/null 2>&1 || \
     ! git -C "$wt" checkout "$branch" >/dev/null 2>&1 || \
     [[ "$(git -C "$wt" branch --show-current 2>/dev/null || true)" != "$branch" ]]; then
    worktree_message replay-attach-failed "$wt" "Error: Could not move '$branch' to the replayed tip and reattach $wt; inspect the worktree." >&2
    return 1
  fi
}

restack_state_refusal() {
  local wt="$1" reason="$2"
  worktree_message restack-state "path=$wt reason=$reason" "$3" >&2
  echo "Only an exact paused state created by 'worktree create <ID> --restack' can be continued, skipped, or aborted." >&2
}

validate_pending_restack_state() {
  local wt="$1" action="${2:-continue}" state_dir="" stored_remote="" stored_branch="" stored_expected=""
  local original_head="" base_oid="" pending="" state_token="" marker_token=""
  local head_name="" rebase_original="" rebase_onto="" mode="" replay_head=""

  if ! is_registered_project_worktree "$wt"; then
    restack_state_refusal "$wt" unregistered "not a registered worktree of this repository"
    return 1
  fi
  mode="$(restack_state_get "$wt" mode)"
  state_dir="$(restack_paused_state_dir "$wt" 2>/dev/null || true)"
  if [[ -z "$state_dir" ]]; then
    restack_state_refusal "$wt" no-paused-state "missing a paused rebase"
    return 1
  fi

  stored_remote="$(restack_state_get "$wt" remote)"
  stored_branch="$(restack_state_get "$wt" branch)"
  stored_expected="$(restack_state_get "$wt" expectedRemoteOid)"
  original_head="$(restack_state_get "$wt" originalHead)"
  base_oid="$(restack_state_get "$wt" baseOid)"
  pending="$(restack_state_get "$wt" pending)"
  state_token="$(restack_state_get "$wt" stateToken)"
  if [[ -z "$stored_remote" || -z "$stored_branch" || -z "$original_head" || -z "$base_oid" ]]; then
    restack_state_refusal "$wt" authorization-missing "missing its tool-created authorization"
    return 1
  fi
  if [[ "$pending" != true ]]; then
    restack_state_refusal "$wt" pending-marker-missing "missing its tool-created pending marker"
    return 1
  fi
  if [[ -z "$state_token" ]]; then
    restack_state_refusal "$wt" token-missing "missing its tool-created state token"
    return 1
  fi
  marker_token="$(head -n 1 "$state_dir/kendex-restack-token" 2>/dev/null || true)"
  if [[ "$marker_token" != "$state_token" ]]; then
    restack_state_refusal "$wt" token-mismatch "missing its matching tool-created state token"
    return 1
  fi
  if ! git -C "$wt" remote get-url "$stored_remote" >/dev/null 2>&1; then
    restack_state_refusal "$wt" remote-missing "bound to a missing remote '$stored_remote'"
    return 1
  fi
  if [[ "$mode" == replay ]]; then
    # Replay analog of the rebase metadata cross-check: the sequencer's head
    # is the detach point (the recorded base) and the branch ref has not moved
    # off the recorded original head — the replay moves it only after the whole
    # range succeeds. Those two pin the state for every action. HEAD being
    # detached is where continue and skip pick onto, so only they require it.
    if [[ ! -f "$state_dir/head" ]]; then
      restack_state_refusal "$wt" sequencer-metadata-missing "missing required Git sequencer metadata"
      return 1
    fi
    replay_head="$(head -n 1 "$state_dir/head" 2>/dev/null || true)"
    if [[ "$replay_head" != "$base_oid" ]] || \
       { [[ "$action" != abort ]] && [[ -n "$(git -C "$wt" branch --show-current 2>/dev/null || true)" ]]; } || \
       [[ "$(git -C "$wt" rev-parse "refs/heads/$stored_branch" 2>/dev/null || true)" != "$original_head" ]]; then
      restack_state_refusal "$wt" replay-mismatch "not the replay recorded by the worktree tool"
      return 1
    fi
  else
    if [[ ! -f "$state_dir/head-name" || ! -f "$state_dir/orig-head" || ! -f "$state_dir/onto" ]]; then
      restack_state_refusal "$wt" rebase-metadata-missing "missing required Git rebase metadata"
      return 1
    fi

    head_name="$(head -n 1 "$state_dir/head-name" 2>/dev/null || true)"
    rebase_original="$(head -n 1 "$state_dir/orig-head" 2>/dev/null || true)"
    rebase_onto="$(head -n 1 "$state_dir/onto" 2>/dev/null || true)"
    if [[ "$head_name" != "refs/heads/$stored_branch" || "$rebase_original" != "$original_head" || "$rebase_onto" != "$base_oid" ]]; then
      restack_state_refusal "$wt" rebase-mismatch "not the rebase recorded by the worktree tool"
      return 1
    fi
  fi
  # continue and skip replay onto the recorded base, so HEAD has to still sit
  # on it. abort unwinds through Git's own paused state, which the cross-check
  # above matched against the record, and its post-conditions verify the
  # restored branch and head: refusing here on HEAD's position alone left the
  # worktree with no guarded exit.
  if ! git -C "$wt" cat-file -e "${original_head}^{commit}" 2>/dev/null || \
     ! git -C "$wt" cat-file -e "${base_oid}^{commit}" 2>/dev/null || \
     { [[ "$action" != abort ]] && ! git -C "$wt" merge-base --is-ancestor "$base_oid" HEAD; }; then
    restack_state_refusal "$wt" base-mismatch "stale or no longer based on its recorded commits"
    return 1
  fi
  if [[ -n "$stored_expected" ]] && ! git -C "$wt" cat-file -e "${stored_expected}^{commit}" 2>/dev/null; then
    restack_state_refusal "$wt" remote-commit-missing "bound to an unavailable remote commit"
    return 1
  fi
  if ! restack_original_head_authorized "$wt" "$stored_expected" "$original_head" "$pending"; then
    restack_state_refusal "$wt" remote-unauthorized "not authorized by its recorded remote branch state"
    return 1
  fi
}

RESTACK_LIVE_EXPECTED_OID=""
validate_pending_restack_remote() {
  local wt="$1" stored_remote="" stored_branch="" stored_expected="" live_expected=""
  stored_remote="$(restack_state_get "$wt" remote)"
  stored_branch="$(restack_state_get "$wt" branch)"
  stored_expected="$(restack_state_get "$wt" expectedRemoteOid)"

  discover_ownership_remote_heads || return 1
  if ! ownership_heads_for_remote "$stored_remote" >/dev/null 2>&1; then
    worktree_message restack-remote-unavailable "$stored_remote" "Error: Could not verify the recorded restack remote '$stored_remote'; refusing to continue or skip." >&2
    return 1
  fi
  live_expected="$(remote_branch_oid_discovered "$stored_remote" "$stored_branch" 2>/dev/null || true)"
  if [[ "$live_expected" != "$stored_expected" ]]; then
    worktree_message restack-remote-moved "$stored_remote/$stored_branch" "Error: Remote '$stored_remote/$stored_branch' changed while the supported restack was paused; refusing to continue or skip." >&2
    echo "Abort the guarded restack before reconciling the moved remote." >&2
    return 1
  fi
  RESTACK_LIVE_EXPECTED_OID="$live_expected"
}

resolve_restack_worktree() {
  local arg="$1"
  if [[ -z "$arg" ]]; then
    printf '%s\n' "$PWD"
  elif [[ "$arg" == */* ]]; then
    printf '%s\n' "$arg"
  else
    worktree_path_for_issue "$arg"
  fi
}

report_paused_restack() {
  local wt="$1" branch="$2" output="$3" conflict_files="" unstaged_files=""
  conflict_files="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)"
  unstaged_files="$(git -C "$wt" diff --name-only 2>/dev/null || true)"
  if [[ -n "$conflict_files" ]]; then
    worktree_message restack-conflicts "$conflict_files" "Restack stopped on conflicts:" >&2
    [[ -n "$output" ]] && sed 's/^/  git: /' <<<"$output" >&2
    sed 's/^/  /' <<<"$conflict_files" >&2
    echo "Resolve and stage each file, then run: $0 restack continue \"$wt\"" >&2
  elif [[ -n "$unstaged_files" ]]; then
    # Git refuses to continue while a tracked file differs from the index and
    # names merge conflicts whatever the real cause. With nothing unmerged,
    # repeating that sends the resolver back to files already staged, and the
    # empty-commit skip below would drop the commit they just resolved.
    worktree_message restack-unstaged "$unstaged_files" "Restack stopped on unstaged changes, not on unresolved conflicts:" >&2
    [[ -n "$output" ]] && sed 's/^/  git: /' <<<"$output" >&2
    sed 's/^/  /' <<<"$unstaged_files" >&2
    echo "Stage or discard them, then run: $0 restack continue \"$wt\"" >&2
  else
    worktree_message restack-empty "$wt" "The current replayed commit may be empty; inspect it, then run: $0 restack skip \"$wt\"" >&2
    [[ -n "$output" ]] && sed 's/^/  git: /' <<<"$output" >&2
  fi
  echo "To restore the pre-restack branch: $0 restack abort \"$wt\"" >&2
  echo "Recorded branch: $branch" >&2
}

# The tail both abort paths share: drop the pending authorization, release the
# claim lock, and re-apply the setup a paused restack un-shadowed. Only the
# closing message differs.
finish_guarded_restack_abort() {
  local wt="$1" outcome="$2"
  cancel_pending_restack_authorization "$wt"
  release_issue_claim_lock
  if ! setup_app_worktree "$wt"; then
    worktree_message restack-setup-failed "$wt" "Warning: Restack was aborted successfully, but worktree setup could not be reapplied. Fix the WORKTREE_* configuration, then run: $0 fix-links '$wt'" >&2
  fi
  worktree_message "restack-$outcome" "$wt"
}

# Git's paused state can be gone while the tool's own record stands: an
# out-of-band 'git rebase --abort' or '--quit', or an abort whose restore check
# refused after Git had already unwound. Nothing can continue or abort a rebase
# that is not running, and every guarded control refuses a missing paused
# state, so abort is the only way to drop that record — without it the exit is
# unsetting the kendex-restack keys by hand. Returns 2 when the record
# is not orphaned after all, for the caller to hand to the guarded controls.
abort_orphaned_restack_record() {
  local wt="$1" branch="" head="" checkout_err=""
  if ! is_registered_project_worktree "$wt"; then
    restack_state_refusal "$wt" unregistered "not a registered worktree of this repository"
    return 1
  fi
  branch="$(restack_state_get "$wt" branch)"
  head="$(restack_state_get "$wt" originalHead)"
  if [[ -z "$branch" || -z "$head" ]]; then
    restack_state_refusal "$wt" authorization-missing "missing its tool-created authorization"
    return 1
  fi
  acquire_issue_claim_lock "$branch" || return 1
  # The lock is what makes the precondition durable. A concurrent
  # 'create <ID> --restack' holds it across the window where it writes the
  # record and starts the rebase, so a sample taken before the lock can name a
  # restack that is live by now, and clearing a live restack's record is not a
  # closed failure. Re-read both under the lock.
  if restack_engine_in_progress "$wt" || [[ "$(restack_state_get "$wt" pending)" != true ]]; then
    release_issue_claim_lock
    return 2
  fi
  if [[ "$(git -C "$wt" rev-parse "refs/heads/$branch" 2>/dev/null || true)" != "$head" ]]; then
    worktree_message restack-orphan-moved "$wt" "Error: No restack is paused in $wt, and '$branch' is no longer at its recorded pre-restack commit $head; refusing to clear the recorded state." >&2
    echo "Something rewrote the branch outside the guarded restack; inspect it before retrying." >&2
    return 1
  fi
  if [[ "$(git -C "$wt" branch --show-current 2>/dev/null || true)" != "$branch" ]] && \
     ! checkout_err="$(git -C "$wt" checkout "$branch" 2>&1)"; then
    worktree_message restack-reattach-failed "$wt" "Error: Could not reattach $wt to '$branch'; the recorded restack state was preserved." >&2
    [[ -n "$checkout_err" ]] && sed 's/^/  git: /' <<<"$checkout_err" >&2
    echo "A 'rebase --quit' or 'cherry-pick --quit' leaves the conflicted index in place: stage or discard the paths Git names above." >&2
    echo "Then re-run: $0 restack abort \"$wt\"" >&2
    return 1
  fi
  finish_guarded_restack_abort "$wt" cleared
}
