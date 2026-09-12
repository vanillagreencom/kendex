#!/usr/bin/env bash
BRANCH_GROWTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
BRANCH_GROWTH_RENDER_ROOTS=""
# The render-mirror roots every branch measurement pairs against, resolved once
# per process from ORCH_SIZE_RENDER_ROOTS. dev-round-write, dev-return-write
# and dev-artifact-check load no project configuration of their own, so the
# measurement they share resolves it for them, and branch-size-check, which
# does load it, reads the answer here rather than restating the default.
#
# The load runs in a subshell. The same [env] table carries keys such as
# ORCH_STATE_DIR that decide where these scripts read and write their state,
# and resolving a measurement setting must not move that; only this one value
# comes back out. A table this project cannot parse fails the measurement
# rather than falling back to the default, which would score the branch under
# roots the project did not choose.
#
# The one value leaves on descriptor 3, with the subshell's stdout pointed at
# stderr for the duration of the load. The private env file is SOURCED, so
# anything it prints would otherwise land in the capture ahead of the value: a
# stray token naming a real top-level directory becomes a render root, changed
# code under it pairs off as a mirror, and the branch measures smaller than it
# is — the one direction that lets an oversized branch past the tripwire.
branch_growth_render_roots() {
  local worktree="$1" repo_root resolved
  [[ -z "$BRANCH_GROWTH_RENDER_ROOTS" ]] || return 0
  repo_root="$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null)" \
    || branch_growth_fail "'$worktree' is not inside a git repository" || return 1
  resolved="$(
    exec 3>&1 1>&2
    # shellcheck source=kendex-env.sh
    source "$BRANCH_GROWTH_LIB_DIR/kendex-env.sh" || exit 1
    kendex_load_project_env "$repo_root" || exit 1
    printf '%s' "${ORCH_SIZE_RENDER_ROOTS:-}" >&3
  )" || {
    branch_growth_fail "the kendex project settings under '$repo_root' could not be read"
    return 1
  }
  BRANCH_GROWTH_RENDER_ROOTS="${resolved:-.agents .claude .codex .pi}"
}
# The branch's changed lines as the fix-round tripwire scores them: additions
# plus deletions, floor 1, over every path the one classification below did not
# pair off as a render mirror. So the number an implementation receipt records
# and the number a later round is held to are the same quantity branch-size-check
# reports, and a source with a tracked render is counted once rather than twice.
#
# The production and test split that same pass computes is not read here: it
# answers to an allowance this measurement does not use, so no test-path globs
# are passed and only BRANCH_SIZE_BASELINE is read back.
branch_baseline_lines() {
  local worktree="$1" base_resolver="$2" commit="$3" out_name="$4" measured
  branch_size_classified "$worktree" "$base_resolver" "$commit" "" || return 1
  measured="$BRANCH_SIZE_BASELINE"
  (( measured > 0 )) || measured=1
  printf -v "$out_name" '%s' "$measured"
}
BRANCH_GROWTH_BASELINE=""
# Where the recorded baseline came from: `implement` an accepted implementation
# receipt, `adopted` a fix round on a branch no receipt ever covered, and
# `unrecorded` a value written before either writer stamped an origin. Carried
# so a refusal can say which number it is holding the branch to.
BRANCH_GROWTH_BASELINE_ORIGIN=""
# How the recorded value read: `present` a positive integer, `absent` the null a
# fresh state file carries, `invalid` anything else, and empty when the state
# itself could not be read. Only `absent` says no writer has spoken yet, which
# is the one case a caller may answer by adopting a baseline of its own.
BRANCH_GROWTH_BASELINE_STATE=""
BRANCH_GROWTH_CURRENT=""
BRANCH_GROWTH_LIMIT=""
# The recorded baseline and the headroom over it, in one place: every gate that
# reads pr.baseline_lines reads it here, so the multiplier moves for all of
# them or for none.
branch_growth_read_baseline() {
  local script_dir="$1" issue="$2" recorded baseline origin
  BRANCH_GROWTH_BASELINE_STATE=""
  recorded="$("$script_dir/workflow-state" get "$issue" \
    '"\(.pr.baseline_lines // "null") \(.pr.baseline_origin // "unrecorded")"')" \
    || branch_growth_fail "workflow state baseline for '$issue' could not be read" || return 1
  read -r baseline origin <<<"$recorded"
  if [[ "$baseline" =~ ^[1-9][0-9]*$ ]]; then
    BRANCH_GROWTH_BASELINE_STATE="present"
  elif [[ "$baseline" == "null" ]]; then
    BRANCH_GROWTH_BASELINE_STATE="absent"
  else
    BRANCH_GROWTH_BASELINE_STATE="invalid"
  fi
  [[ "$BRANCH_GROWTH_BASELINE_STATE" == "present" ]] || {
    branch_growth_fail "workflow state pr.baseline_lines is missing or invalid"
    return 1
  }
  BRANCH_GROWTH_BASELINE="$baseline"
  BRANCH_GROWTH_BASELINE_ORIGIN="$origin"
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
# The same paths' additions plus deletions, render mirrors left out, which is
# what the fix-round tripwire holds a branch to. It is computed in this one
# pass so the tripwire and the submit-time check cannot disagree about which
# lines a render mirror contributed.
BRANCH_SIZE_BASELINE=""
# Split the branch's added lines into production, test, and mandated render
# mirror lines. Additions alone are counted there, so a rewrite that moves
# lines earns no headroom from what it deleted. Test lines are counted apart
# because they answer to their own allowance, and a total that folds the two
# hides which one grew.
#
# The render-mirror roots come from branch_growth_render_roots, not from an
# argument: every caller of this measurement resolves one list, once. A render
# is counted once, at the source it renders, and the pairing is by path: strip
# a changed path's leading render-root segment and it is a mirror only when what remains
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
#
# $4 is the blank-separated list of extra test-path globs a repository adds to
# the built-in test rule. A pattern matches the whole repository-relative path,
# with `*` any run of characters including `/`, `?` any single character, and
# everything else literal. The list only adds: empty, or matching nothing, it
# leaves every line where the built-in rule put it, which for a path that rule
# does not name is production and the stricter allowance.
#
# The globs reach awk through the environment, not a `-v` assignment: awk
# processes escape sequences in a `-v` value before the program sees it, so a
# backslash in a configured glob would be rewritten, and rewritten differently
# by gawk and mawk. An ENVIRON entry arrives byte for byte.
branch_size_classified() {
  local worktree="$1" base_resolver="$2" commit="$3" test_paths="$4"
  local numstat measured
  branch_growth_render_roots "$worktree" || return 1
  branch_size_numstat "$worktree" "$base_resolver" "$commit" numstat || return 1
  if ! measured="$(BRANCH_GROWTH_TEST_PATHS="$test_paths" \
    awk -F '\t' -v roots="$BRANCH_GROWTH_RENDER_ROOTS" '
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
    # A glob anchored over the whole path: only `*` and `?` are wild, and
    # every other regex metacharacter is escaped, so the dot in check-*.py
    # matches a dot and nothing else.
    function glob_to_regex(g,   out, i, c) {
      out = "^"
      for (i = 1; i <= length(g); i++) {
        c = substr(g, i, 1)
        if (c == "*") out = out ".*"
        else if (c == "?") out = out "."
        else if (index("\\^$.[]|()+{}", c) > 0) out = out "\\" c
        else out = out c
      }
      return out "$"
    }
    function is_test(p,   b, i) {
      if (p ~ /(^|\/)(test|tests|__tests__)\//) return 1
      b = base_name(p)
      if ((b == "tests.rs") || (b ~ /test_util\.rs$/) || (b ~ /\.(test|spec)\./)) return 1
      for (i = 1; i <= npats; i++) if (p ~ pattern[i]) return 1
      return 0
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
    BEGIN {
      nroots = split(roots, root, " ")
      npats = split(ENVIRON["BRANCH_GROWTH_TEST_PATHS"], pattern, " ")
      for (i = 1; i <= npats; i++) pattern[i] = glob_to_regex(pattern[i])
    }
    NF == 0 || ($1 == "-" && $2 == "-") { next }
    $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { failed = 1; next }
    {
      n += 1
      path[n] = new_path($3)
      lines[n] = $1
      changed[n] = $1 + $2
      mirror_rest[n] = render_rest(path[n])
      if (mirror_rest[n] == "") source_stem[stem_path(path[n])] = 1
    }
    END {
      if (failed) exit 2
      for (i = 1; i <= n; i++) {
        if (mirror_rest[i] != "" && pairs_with_source(mirror_rest[i])) { mirror += lines[i]; continue }
        baseline += changed[i]
        if (is_test(path[i])) tests += lines[i]; else production += lines[i]
      }
      printf "%d %d %d %d", production + 0, tests + 0, mirror + 0, baseline + 0
    }
  ' <<<"$numstat")"; then
    branch_growth_fail "git numstat returned an unsupported additions/deletions shape"
    return 1
  fi
  read -r BRANCH_SIZE_PRODUCTION BRANCH_SIZE_TEST BRANCH_SIZE_MIRROR BRANCH_SIZE_BASELINE <<<"$measured"
}
