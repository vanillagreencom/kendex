#!/usr/bin/env bash
BRANCH_GROWTH_ERROR=""
BRANCH_GROWTH_STATUS="error"
BRANCH_GROWTH_LINES=""
branch_growth_fail() {
  BRANCH_GROWTH_ERROR="$1"
  BRANCH_GROWTH_STATUS="${2:-error}"
  return 1
}
# Store additions plus deletions between the branch base and one commit.
branch_diff_lines() {
  local worktree="$1" base_resolver="$2" commit="$3" out_name="$4"
  local base_branch base_ref numstat measured
  BRANCH_GROWTH_ERROR=""
  BRANCH_GROWTH_STATUS="error"
  base_branch="$("$base_resolver" "$worktree")" \
    || branch_growth_fail "could not resolve the base branch for '$worktree'" \
    || return 1
  if git -C "$worktree" show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
    base_ref="refs/remotes/origin/$base_branch"
  elif git -C "$worktree" show-ref --verify --quiet "refs/heads/$base_branch"; then
    base_ref="refs/heads/$base_branch"
  else
    branch_growth_fail "base branch '$base_branch' has no local or origin ref in '$worktree'"
    return 1
  fi
  numstat="$(git -C "$worktree" diff --numstat --no-ext-diff "$base_ref"..."$commit" --)" \
    || branch_growth_fail "git could not compare '$base_ref' with '$commit' in '$worktree'" \
    || return 1
  if ! measured="$(awk -F '\t' '
    NF == 0 { next }
    $1 == "-" && $2 == "-" { next }
    $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { failed = 1; next }
    { lines += $1 + $2 }
    END { if (failed) exit 2; print lines + 0 }
  ' <<<"$numstat")"; then
    branch_growth_fail "git numstat returned an unsupported additions/deletions shape"
    return 1
  fi
  printf -v "$out_name" '%s' "$measured"
}
branch_baseline_lines() {
  local worktree="$1" base_resolver="$2" commit="$3" out_name="$4" count
  branch_diff_lines "$worktree" "$base_resolver" "$commit" count || return 1
  (( count > 0 )) || count=1
  printf -v "$out_name" '%s' "$count"
}
validate_active_growth_round() {
  local worktree="$1" issue="$2" round_id="$3" script_dir="$4" snapshot root
  snapshot="$("$script_dir/workflow-state" get "$issue" \
    '{round: (.dev_round_id // null), worktree: (.worktree // null)}')" \
    || branch_growth_fail "workflow state for '$issue' could not be read through its configured directory" \
    || return 1
  root="$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null)" \
    || branch_growth_fail "worktree '$worktree' has no repository root" \
    || return 1
  jq -e --arg round "$round_id" --arg worktree "$root" '
    .round == $round and .worktree == $worktree
  ' <<<"$snapshot" >/dev/null 2>&1 || {
    branch_growth_fail "workflow state does not bind active round '$round_id' to '$root'"
    return 1
  }
}
read_growth_baseline() {
  local issue="$1" script_dir="$2" out_name="$3" value
  value="$("$script_dir/workflow-state" get "$issue" '.pr.baseline_lines // "null"')" \
    || branch_growth_fail "workflow state baseline for '$issue' could not be read" \
    || return 1
  [[ "$value" == "null" || "$value" =~ ^[1-9][0-9]*$ ]] || {
    branch_growth_fail "workflow state pr.baseline_lines must be null or a positive integer"
    return 1
  }
  printf -v "$out_name" '%s' "$value"
}
record_growth_baseline() {
  local worktree="$1" issue="$2" round_id="$3" commit="$4" receipt_lines="$5" script_dir="$6"
  local head measured
  validate_active_growth_round "$worktree" "$issue" "$round_id" "$script_dir" || return 1
  head="$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    || branch_growth_fail "worktree '$worktree' has no current HEAD" \
    || return 1
  [[ "$commit" == "$head" ]] || {
    branch_growth_fail "implementation receipt commit '$commit' is not current HEAD '$head'"
    return 1
  }
  branch_baseline_lines "$worktree" "$script_dir/resolve-base-branch" "$head" measured || return 1
  [[ "$receipt_lines" == "$measured" ]] || {
    branch_growth_fail "implementation receipt reports $receipt_lines baseline lines, but current HEAD measures $measured"
    return 1
  }
  "$script_dir/workflow-state" update "$issue" --argjson lines "$measured" '
    .pr = (.pr // {})
    | if (.pr.baseline_lines // null) == null then .pr.baseline_lines = $lines else . end
  ' || branch_growth_fail "workflow state pr.baseline_lines could not be recorded" || return 1
}
enforce_size_tripwire() {
  local worktree="$1" issue="$2" round_id="$3" script_dir="$4" baseline current
  validate_active_growth_round "$worktree" "$issue" "$round_id" "$script_dir" || return 1
  read_growth_baseline "$issue" "$script_dir" baseline || return 1
  branch_baseline_lines "$worktree" "$script_dir/resolve-base-branch" HEAD current || return 1
  BRANCH_GROWTH_LINES="$current"
  if [[ "$baseline" == "null" ]]; then
    BRANCH_GROWTH_STATUS="uninitialized"
    return 0
  fi
  if (( current > baseline * 2 )); then
    branch_growth_fail \
      "fix round refused: branch diffstat is $current lines; baseline is $baseline lines; fix rounds stop past 2x that baseline, so cut the branch to $((baseline * 2)) lines or fewer" \
      over-limit
    return 1
  fi
  BRANCH_GROWTH_STATUS="ok"
}
