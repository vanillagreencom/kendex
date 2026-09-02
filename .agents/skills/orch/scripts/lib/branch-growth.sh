#!/usr/bin/env bash
BRANCH_GROWTH_ERROR=""
branch_growth_fail() {
  BRANCH_GROWTH_ERROR="$1"
  return 1
}
# The one git invocation every branch measurement reads. Both the size
# tripwire and the submit-time size check score the same diffstat, with the
# same rename detection: a file a size ratchet forced a project to move is a
# rename git scores as no lines at all, so no measurement built on this bills
# a mandated move as growth.
branch_size_numstat() {
  local worktree="$1" base_resolver="$2" commit="$3" out_name="$4"
  local base_branch base_ref measured_numstat
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
  measured_numstat="$(git -C "$worktree" diff --numstat --no-ext-diff "$base_ref"..."$commit" --)" \
    || branch_growth_fail "git could not compare '$base_ref' with '$commit' in '$worktree'" || return 1
  printf -v "$out_name" '%s' "$measured_numstat"
}
branch_baseline_lines() {
  local worktree="$1" base_resolver="$2" commit="$3" out_name="$4"
  local numstat measured
  branch_size_numstat "$worktree" "$base_resolver" "$commit" numstat || return 1
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
BRANCH_SIZE_PRODUCTION=""
BRANCH_SIZE_TEST=""
BRANCH_SIZE_MIRROR=""
# Split the branch's whole diffstat into production, test, and mandated render
# mirror lines. Test lines are counted apart because a branch's test growth
# answers to the issue's Done-when surfaces rather than to its production
# allowance, and a total that folds the two hides which one grew.
#
# $4 is the blank-separated list of render-mirror roots. A change under one of
# them is the render a project's guard mandates beside the source it renders,
# so it is counted once, at the source: the mirrored path drops out when a
# changed path outside every root shares its basename stem. A render-only
# branch changes no source, matches nothing, and is measured in full.
branch_size_classified() {
  local worktree="$1" base_resolver="$2" commit="$3" render_roots="$4"
  local numstat measured
  branch_size_numstat "$worktree" "$base_resolver" "$commit" numstat || return 1
  if ! measured="$(awk -F '\t' -v roots="$render_roots" '
    function new_path(p,   open_at, close_at, prefix, suffix, moved) {
      if (index(p, " => ") == 0) return p
      open_at = index(p, "{")
      close_at = index(p, "}")
      if (open_at > 0 && close_at > open_at) {
        prefix = substr(p, 1, open_at - 1)
        suffix = substr(p, close_at + 1)
        moved = substr(p, open_at + 1, close_at - open_at - 1)
        sub(/^.* => /, "", moved)
        return prefix moved suffix
      }
      sub(/^.* => /, "", p)
      return p
    }
    function base_name(p) { sub(/^.*\//, "", p); return p }
    function stem(p,   b, dot) {
      b = base_name(p)
      dot = index(substr(b, 2), ".")
      if (dot > 0) return substr(b, 1, dot)
      return b
    }
    function is_render(p,   first, i) {
      first = p
      sub(/\/.*$/, "", first)
      for (i = 1; i <= nroots; i++) if (first == root[i]) return 1
      return 0
    }
    function is_test(p,   b) {
      if (p ~ /(^|\/)(test|tests|__tests__)\//) return 1
      b = base_name(p)
      return (b == "tests.rs") || (b ~ /test_util\.rs$/) || (b ~ /\.(test|spec)\./)
    }
    BEGIN { nroots = split(roots, root, " ") }
    NF == 0 || ($1 == "-" && $2 == "-") { next }
    $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { failed = 1; next }
    {
      n += 1
      path[n] = new_path($3)
      lines[n] = $1 + $2
      if (!is_render(path[n])) source_stem[stem(path[n])] = 1
    }
    END {
      if (failed) exit 2
      for (i = 1; i <= n; i++) {
        if (is_render(path[i]) && (stem(path[i]) in source_stem)) { mirror += lines[i]; continue }
        if (is_test(path[i])) tests += lines[i]; else production += lines[i]
      }
      printf "%d %d %d", production + 0, tests + 0, mirror + 0
    }
  ' <<<"$numstat")"; then
    branch_growth_fail "git numstat returned an unsupported additions/deletions shape"
    return 1
  fi
  read -r BRANCH_SIZE_PRODUCTION BRANCH_SIZE_TEST BRANCH_SIZE_MIRROR <<<"$measured"
}
