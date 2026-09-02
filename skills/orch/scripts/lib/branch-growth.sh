#!/usr/bin/env bash
BRANCH_GROWTH_ERROR=""
branch_growth_fail() {
  BRANCH_GROWTH_ERROR="$1"
  return 1
}
branch_baseline_lines() {
  local worktree="$1" base_resolver="$2" commit="$3" out_name="$4"
  local base_branch base_ref numstat measured
  base_branch="$("$base_resolver" "$worktree")" \
    || branch_growth_fail "could not resolve the base branch for '$worktree'" || return 1
  if git -C "$worktree" show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
    base_ref="refs/remotes/origin/$base_branch"
  elif git -C "$worktree" show-ref --verify --quiet "refs/heads/$base_branch"; then
    base_ref="refs/heads/$base_branch"
  else
    branch_growth_fail "base branch '$base_branch' has no local or origin ref in '$worktree'"
    return 1
  fi
  numstat="$(git -C "$worktree" diff --numstat --no-ext-diff "$base_ref"..."$commit" --)" \
    || branch_growth_fail "git could not compare '$base_ref' with '$commit' in '$worktree'" || return 1
  if ! measured="$(awk -F '\t' '
    NF == 0 || ($1 == "-" && $2 == "-") { next }
    $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { failed = 1; next }
    { lines += $1 + $2 }
    END { if (failed) exit 2; print lines + 0 }
  ' <<<"$numstat")"; then
    branch_growth_fail "git numstat returned an unsupported additions/deletions shape"
    return 1
  fi
  (( measured > 0 )) || measured=1
  printf -v "$out_name" '%s' "$measured"
}
BRANCH_GROWTH_BASELINE=""
BRANCH_GROWTH_CURRENT=""
BRANCH_GROWTH_LIMIT=""
# Measure the branch against workflow state pr.baseline_lines without judging
# it: on success BRANCH_GROWTH_BASELINE, BRANCH_GROWTH_CURRENT and
# BRANCH_GROWTH_LIMIT carry the three numbers and the caller decides what they
# mean. Measurement failure is always the caller's environment failure, never a
# verdict about the branch: dev-round-write refuses a round that is over the
# limit, and the same measurement at acceptance time is how dev-artifact-check
# tells a cut that shrank the branch from one that did not.
measure_size_tripwire() {
  local worktree="$1" issue="$2" script_dir="$3" baseline current
  baseline="$("$script_dir/workflow-state" get "$issue" '.pr.baseline_lines // "null"')" \
    || branch_growth_fail "workflow state baseline for '$issue' could not be read" || return 1
  [[ "$baseline" =~ ^[1-9][0-9]*$ ]] || {
    branch_growth_fail "workflow state pr.baseline_lines is missing or invalid"
    return 1
  }
  branch_baseline_lines "$worktree" "$script_dir/resolve-base-branch" HEAD current || return 1
  BRANCH_GROWTH_BASELINE="$baseline"
  BRANCH_GROWTH_CURRENT="$current"
  BRANCH_GROWTH_LIMIT=$(( baseline * 2 ))
}
