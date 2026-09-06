#!/usr/bin/env bash
BRANCH_GROWTH_ERROR=""
branch_growth_fail() {
  BRANCH_GROWTH_ERROR="$1"
  return 1
}
BRANCH_GROWTH_BASE_REF=""
# The one git invocation every branch measurement reads, so both gates score
# the same diffstat under the same rules. --find-renames is passed rather than
# left to the runner's diff.renames, which decides whether a move a size
# ratchet forced costs zero lines or twice the file. The base ref it compared
# against is left in BRANCH_GROWTH_BASE_REF for a caller that binds its
# verdict to the commits it measured.
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
  BRANCH_GROWTH_BASE_REF="$base_ref"
  measured_numstat="$(git -C "$worktree" diff --numstat --no-ext-diff --find-renames "$base_ref"..."$commit" --)" \
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
# The recorded baseline and the headroom over it, in one place: every gate that
# reads pr.baseline_lines reads it here, so the multiplier moves for all of
# them or for none.
branch_growth_read_baseline() {
  local script_dir="$1" issue="$2" baseline
  baseline="$("$script_dir/workflow-state" get "$issue" '.pr.baseline_lines // "null"')" \
    || branch_growth_fail "workflow state baseline for '$issue' could not be read" || return 1
  [[ "$baseline" =~ ^[1-9][0-9]*$ ]] || {
    branch_growth_fail "workflow state pr.baseline_lines is missing or invalid"
    return 1
  }
  BRANCH_GROWTH_BASELINE="$baseline"
  BRANCH_GROWTH_LIMIT=$(( baseline * 2 ))
}
# Measure the branch against workflow state pr.baseline_lines without judging
# it: on success BRANCH_GROWTH_BASELINE, BRANCH_GROWTH_CURRENT and
# BRANCH_GROWTH_LIMIT carry the three numbers and the caller decides what they
# mean. Measurement failure is always the caller's environment failure, never a
# verdict about the branch: dev-round-write refuses a round that is over the
# limit, and the same measurement at acceptance time is how dev-artifact-check
# tells a cut that shrank the branch from one that did not.
measure_size_tripwire() {
  local worktree="$1" issue="$2" script_dir="$3" current
  branch_growth_read_baseline "$script_dir" "$issue" || return 1
  branch_baseline_lines "$worktree" "$script_dir/resolve-base-branch" HEAD current || return 1
  BRANCH_GROWTH_CURRENT="$current"
}
BRANCH_SIZE_PRODUCTION=""
BRANCH_SIZE_TEST=""
BRANCH_SIZE_MIRROR=""
# Split the branch's added lines into production, test, and mandated render
# mirror lines. Additions alone are counted, so a rewrite that moves lines
# earns no headroom from what it deleted. Test lines are counted apart because
# they answer to their own allowance, and a total that folds the two hides
# which one grew.
#
# $4 is the blank-separated list of render-mirror roots. A render is counted
# once, at the source it renders, and the pairing is by path: strip a changed
# path's leading render-root segment and it is a mirror only when what remains
# names a source changed in the same diff — equal to that source's path without
# its final extension, or ending in it at a segment boundary when the source
# path has a directory of its own. The equal form covers a render whose
# extension differs from its source (a markdown agent rendered as a Codex
# toml); the suffix form covers a nested render root (a hook rendered under
# the Pi kendex directory). A root-level source takes only the equal form: by
# basename alone a root README would pair with every README under every
# render root. A render whose own source did not
# change pairs with nothing and is measured in full, and so is a render-only
# branch.
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
    # The path with its final extension removed, so a render and the source it
    # renders compare equal across a changed extension.
    function stem_path(p,   b, dot, head, i) {
      b = base_name(p)
      dot = 0
      for (i = length(b); i > 1; i--) if (substr(b, i, 1) == ".") { dot = i; break }
      if (dot == 0) return p
      head = substr(p, 1, length(p) - length(b))
      return head substr(b, 1, dot - 1)
    }
    function render_rest(p,   first, i) {
      first = p
      sub(/\/.*$/, "", first)
      for (i = 1; i <= nroots; i++) if (first == root[i]) return substr(p, length(first) + 2)
      return ""
    }
    function is_test(p,   b) {
      if (p ~ /(^|\/)(test|tests|__tests__)\//) return 1
      b = base_name(p)
      return (b == "tests.rs") || (b ~ /test_util\.rs$/) || (b ~ /\.(test|spec)\./)
    }
    function pairs_with_source(rest,   rest_stem, s) {
      rest_stem = stem_path(rest)
      for (s in source_stem) {
        if (rest_stem == s) return 1
        if (index(s, "/") > 0 && length(rest_stem) > length(s) \
            && substr(rest_stem, length(rest_stem) - length(s)) == "/" s) return 1
      }
      return 0
    }
    BEGIN { nroots = split(roots, root, " ") }
    NF == 0 || ($1 == "-" && $2 == "-") { next }
    $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { failed = 1; next }
    {
      n += 1
      path[n] = new_path($3)
      lines[n] = $1
      mirror_rest[n] = render_rest(path[n])
      if (mirror_rest[n] == "") source_stem[stem_path(path[n])] = 1
    }
    END {
      if (failed) exit 2
      for (i = 1; i <= n; i++) {
        if (mirror_rest[i] != "" && pairs_with_source(mirror_rest[i])) { mirror += lines[i]; continue }
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
