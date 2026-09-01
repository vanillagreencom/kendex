#!/usr/bin/env bash

BRANCH_GROWTH_ERROR=""
BRANCH_GROWTH_STATUS="error"

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

# A line-based baseline keeps binary-only and metadata-only implementations usable.
branch_baseline_lines() {
  local worktree="$1" base_resolver="$2" commit="$3" out_name="$4" count

  branch_diff_lines "$worktree" "$base_resolver" "$commit" count || return 1
  (( count > 0 )) || count=1
  printf -v "$out_name" '%s' "$count"
}

baseline_record_path() {
  local worktree="$1" issue="$2" out_name="$3" common

  common="$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || branch_growth_fail "worktree '$worktree' has no resolvable git common directory" \
    || return 1
  printf -v "$out_name" '%s/kendex/branch-baselines/%s.json' "$common" "$issue"
}

baseline_record_valid() {
  jq -e '
    (.schema_version == 1)
    and ((.issue | type) == "string") and (.issue != "")
    and ((.round_id | type) == "string") and (.round_id != "")
    and ((.commit | type) == "string") and (.commit != "")
    and ((.lines | type) == "number") and (.lines == (.lines | floor)) and (.lines >= 1)
    and (.source == "implementation" or .source == "first-fix")
  ' "$1" >/dev/null 2>&1
}

validate_active_growth_round() {
  local worktree="$1" issue="$2" round_id="$3" script_dir="$4" snapshot root generation

  snapshot="$("$script_dir/workflow-state" get "$issue" \
    '{round: (.dev_round_id // null), worktree: (.worktree // null), generation: (.worktree_gen // null)}')" \
    || branch_growth_fail "workflow state for '$issue' could not be read through its configured directory" \
    || return 1
  root="$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null)" \
    || branch_growth_fail "worktree '$worktree' has no repository root" \
    || return 1
  jq -e --arg round "$round_id" --arg worktree "$root" '
    .round == $round and .worktree == $worktree
    and (.generation == null or ((.generation | type) == "string" and .generation != ""))
  ' <<<"$snapshot" >/dev/null 2>&1 || {
    branch_growth_fail "workflow state does not bind active round '$round_id' to '$root'"
    return 1
  }
  generation="$(jq -r '.generation // empty' <<<"$snapshot")"
  if [[ -n "$generation" ]]; then
    "$script_dir/worktree-claim" --worktree "$root" --issue "$issue" --expect-gen "$generation" >/dev/null \
      || branch_growth_fail "worktree lease '$generation' is no longer active for '$issue'" \
      || return 1
  fi
}

write_baseline_record() {
  local record="$1" issue="$2" round_id="$3" commit="$4" lines="$5" source="$6"
  local dir tmp

  dir="${record%/*}"
  mkdir -p "$dir" || branch_growth_fail "could not create branch-baseline state directory '$dir'" || return 1
  [[ ! -L "$record" ]] || branch_growth_fail "branch-baseline record '$record' must not be a symlink" || return 1
  tmp="$dir/.branch-baseline-$issue.$$.$RANDOM"
  if ! (set -o noclobber; : > "$tmp") 2>/dev/null; then
    branch_growth_fail "could not create branch-baseline scratch '$tmp'"
    return 1
  fi
  jq -n --argjson schema_version 1 --arg issue "$issue" --arg round_id "$round_id" \
    --arg commit "$commit" --argjson lines "$lines" --arg source "$source" \
    '{schema_version: $schema_version, issue: $issue, round_id: $round_id,
      commit: $commit, lines: $lines, source: $source}' > "$tmp" || {
    rm -f "$tmp"
    branch_growth_fail "could not build branch-baseline record '$record'"
    return 1
  }
  if ! ln "$tmp" "$record" 2>/dev/null; then
    cmp -s "$tmp" "$record" || {
      rm -f "$tmp"
      branch_growth_fail "branch-baseline record '$record' already binds a different round"
      return 1
    }
  fi
  rm -f "$tmp"
}

sync_baseline_cache() {
  local state="$1" issue="$2" record="$3" cache

  cache="$("$state" get "$issue" '.pr // null')" \
    || branch_growth_fail "workflow state for '$issue' could not be read through its configured directory" \
    || return 1
  if jq -e --slurpfile record "$record" '
    $record[0] as $r
    | .baseline_lines == $r.lines and .baseline_round_id == $r.round_id
      and .baseline_commit == $r.commit and .baseline_source == $r.source
  ' <<<"$cache" >/dev/null 2>&1; then
    return 0
  fi
  if ! jq -e '
    . == null or (type == "object" and (.baseline_lines == null)
      and (.baseline_round_id == null) and (.baseline_commit == null)
      and (.baseline_source == null))
  ' <<<"$cache" >/dev/null 2>&1; then
    branch_growth_fail "workflow state pr baseline does not match immutable record '$record'"
    return 1
  fi
  "$state" update "$issue" --slurpfile record "$record" '
    $record[0] as $r
    | .pr = ((.pr // {}) + {baseline_lines: $r.lines, baseline_round_id: $r.round_id,
        baseline_commit: $r.commit, baseline_source: $r.source})
  ' || branch_growth_fail "workflow state pr baseline could not be synchronized from '$record'" || return 1
}

# Persist a baseline only after the orchestrator accepts the active implement receipt.
accept_implementation_baseline() {
  local worktree="$1" issue="$2" round_id="$3" commit="$4" receipt_lines="$5" script_dir="$6"
  local measured record

  validate_active_growth_round "$worktree" "$issue" "$round_id" "$script_dir" || return 1
  branch_baseline_lines "$worktree" "$script_dir/resolve-base-branch" "$commit" measured || return 1
  [[ "$receipt_lines" == "$measured" ]] || {
    branch_growth_fail "implementation receipt reports $receipt_lines baseline lines, but commit '$commit' measures $measured"
    return 1
  }
  baseline_record_path "$worktree" "$issue" record || return 1
  if [[ ! -e "$record" ]]; then
    write_baseline_record "$record" "$issue" "$round_id" "$commit" "$measured" implementation || return 1
  fi
  [[ -f "$record" && ! -L "$record" ]] && baseline_record_valid "$record" || {
    branch_growth_fail "branch-baseline record '$record' is missing or invalid"
    return 1
  }
  sync_baseline_cache "$script_dir/workflow-state" "$issue" "$record"
}

# Fresh standalone review routes anchor on the branch at their first fix round.
ensure_fix_baseline() {
  local worktree="$1" issue="$2" round_id="$3" script_dir="$4" record cache lines commit

  validate_active_growth_round "$worktree" "$issue" "$round_id" "$script_dir" || return 1
  baseline_record_path "$worktree" "$issue" record || return 1
  if [[ ! -e "$record" ]]; then
    cache="$("$script_dir/workflow-state" get "$issue" '.pr // null')" \
      || branch_growth_fail "workflow state for '$issue' could not be read through its configured directory" \
      || return 1
    jq -e 'type == "object" and has("baseline_lines") and .baseline_lines == null' \
      <<<"$cache" >/dev/null 2>&1 || {
      branch_growth_fail "workflow state has no immutable branch baseline and is not a fresh standalone route"
      return 1
    }
    commit="$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
      || branch_growth_fail "worktree '$worktree' has no HEAD commit for a first-fix baseline" \
      || return 1
    branch_baseline_lines "$worktree" "$script_dir/resolve-base-branch" "$commit" lines || return 1
    write_baseline_record "$record" "$issue" "$round_id" "$commit" "$lines" first-fix || return 1
  fi
  [[ -f "$record" && ! -L "$record" ]] && baseline_record_valid "$record" || {
    branch_growth_fail "branch-baseline record '$record' is missing or invalid"
    return 1
  }
  sync_baseline_cache "$script_dir/workflow-state" "$issue" "$record"
}

# Refuse a fix round once text growth passes twice its authorized baseline.
enforce_size_tripwire() {
  local worktree="$1" issue="$2" round_id="$3" script_dir="$4" record baseline current

  ensure_fix_baseline "$worktree" "$issue" "$round_id" "$script_dir" || return 1
  baseline_record_path "$worktree" "$issue" record || return 1
  baseline="$(jq -r '.lines' "$record")"
  branch_baseline_lines "$worktree" "$script_dir/resolve-base-branch" HEAD current || return 1
  if (( current > baseline * 2 )); then
    branch_growth_fail \
      "fix round refused: branch diffstat is $current lines; authorized baseline is $baseline lines; fix rounds stop past 2x that baseline, so cut the branch to $((baseline * 2)) lines or fewer" \
      over-limit
    return 1
  fi
}
