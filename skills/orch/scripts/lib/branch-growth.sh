#!/usr/bin/env bash

BRANCH_GROWTH_ERROR=""

# Print additions plus deletions between the branch base and HEAD.
branch_diff_lines() {
  local worktree="$1"
  local base_resolver="$2"
  local base_branch base_ref numstat

  BRANCH_GROWTH_ERROR=""
  base_branch="$("$base_resolver" "$worktree")" || {
    BRANCH_GROWTH_ERROR="could not resolve the base branch for '$worktree'"
    return 1
  }
  if git -C "$worktree" show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
    base_ref="refs/remotes/origin/$base_branch"
  elif git -C "$worktree" show-ref --verify --quiet "refs/heads/$base_branch"; then
    base_ref="refs/heads/$base_branch"
  else
    BRANCH_GROWTH_ERROR="base branch '$base_branch' has no local or origin ref in '$worktree'"
    return 1
  fi

  numstat="$(git -C "$worktree" diff --numstat --no-ext-diff "$base_ref"...HEAD --)" || {
    BRANCH_GROWTH_ERROR="git could not compare '$base_ref' with HEAD in '$worktree'"
    return 1
  }
  awk -F '\t' '
    NF == 0 { next }
    $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { unreadable = 1; next }
    { lines += $1 + $2 }
    END {
      if (unreadable) exit 2
      print lines + 0
    }
  ' <<<"$numstat" || {
    BRANCH_GROWTH_ERROR="binary changes have no additions-plus-deletions count"
    return 1
  }
}

# Record the first implementation round's branch size and preserve it thereafter.
record_branch_baseline() {
  local worktree="$1" issue="$2" script_dir="$3" baseline lines

  baseline="$("$script_dir/workflow-state" --state-dir "$worktree/tmp" get "$issue" '.pr.baseline_lines // empty')" || {
    BRANCH_GROWTH_ERROR="workflow state for '$issue' could not be read while recording the round-1 diffstat"
    return 1
  }
  if [[ -n "$baseline" && ! "$baseline" =~ ^[0-9]+$ ]]; then
    BRANCH_GROWTH_ERROR="workflow state pr.baseline_lines must be a non-negative integer, got '$baseline'"
    return 1
  fi
  [[ -z "$baseline" ]] || return 0

  lines="$(branch_diff_lines "$worktree" "$script_dir/resolve-base-branch")" || return 1
  "$script_dir/workflow-state" --state-dir "$worktree/tmp" update "$issue" \
    --argjson lines "$lines" \
    '.pr = ((.pr // {}) | if (.baseline_lines // null) == null then .baseline_lines = $lines else . end)' || {
    BRANCH_GROWTH_ERROR="workflow state pr.baseline_lines could not be recorded"
    return 1
  }
}

# Refuse a fix round once branch growth passes twice its first-round size.
enforce_size_tripwire() {
  local worktree="$1" issue="$2" script_dir="$3" baseline current

  baseline="$("$script_dir/workflow-state" --state-dir "$worktree/tmp" get "$issue" '.pr.baseline_lines // empty')" || {
    BRANCH_GROWTH_ERROR="workflow state for '$issue' could not be read before the fix round"
    return 1
  }
  if [[ ! "$baseline" =~ ^[0-9]+$ ]]; then
    BRANCH_GROWTH_ERROR="workflow state pr.baseline_lines is missing or invalid; complete the first implementation round with dev-return-write"
    return 1
  fi
  current="$(branch_diff_lines "$worktree" "$script_dir/resolve-base-branch")" || return 1
  if (( current > baseline * 2 )); then
    BRANCH_GROWTH_ERROR="fix round refused: branch diffstat is $current lines; round-1 baseline is $baseline lines; fix rounds stop past 2x that baseline, so cut the branch to $((baseline * 2)) lines or fewer"
    return 1
  fi
}
