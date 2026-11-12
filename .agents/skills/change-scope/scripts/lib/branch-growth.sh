#!/usr/bin/env bash
BRANCH_GROWTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH_GROWTH_ERROR=""
branch_growth_fail() {
  BRANCH_GROWTH_ERROR="$1"
  return 1
}
BRANCH_GROWTH_BASE_REF=""
# Reads the Expected delta estimate for item-tier. A missing header is
# permitted, and a stated zero counts as zero; a header with malformed or no
# text returns 1 with no numeric result and leaves the text in
# EXPECTED_DELTA_LINE for the caller's warning.
expected_delta_read() { # BODY
  local line header='^[[:space:]]*[*_]*[Ee]xpected delta[*_]*[[:space:]]*:'
  local grammar='^(0 lines|1 line|[2-9] lines|[1-9][0-9]+ lines)(, (0 test lines|1 test line|[2-9] test lines|[1-9][0-9]+ test lines))?$'
  EXPECTED_DELTA_PRODUCTION=""
  EXPECTED_DELTA_LINE=""
  grep -qE "$header" <<<"$1" || return 0
  line="$(sed -n 's/^[[:space:]]*[*_]*[Ee]xpected delta[*_]*[[:space:]]*:[[:space:]]*//p' <<<"$1")" || return 1
  line="${line%%$'\n'*}"
  line="$(sed 's/[[:space:]]*$//' <<<"$line")" || return 1
  EXPECTED_DELTA_LINE="$line"
  [[ "$line" =~ $grammar ]] || return 1
  EXPECTED_DELTA_PRODUCTION="${BASH_REMATCH[1]%% *}"
}
# What a caller outside this package checks before it uses the measurement.
# A package installed at its own revision can be older than the caller beside
# it, and a call into a signature this library has not got yet does not fail:
# a missing function is `command not found` and an extra argument is dropped.
# So a caller checks this number is at least the one it needs, and nothing
# checks a ceiling: the number is ADDITIVE ONLY. Bump it when a cross-package
# entry point is added, or when an existing one gains an argument every older
# call still reads correctly without. An incompatible change to an existing
# entry point takes a NEW function name and a bump, never a new signature
# under the old name — an older caller would accept this number and then call
# the old spelling. A result variable a caller outside this package reads
# bumps it too: an older library leaves that variable unset.
#
# 2: branch_size_classified sets BRANCH_SIZE_TEST_FILES.
BRANCH_GROWTH_CONTRACT=2
# The ref a branch is compared against: the resolver's base branch on origin,
# else its local branch.
branch_growth_base_ref() {
  local worktree="$1" base_resolver="$2" out_name="$3" base_branch
  base_branch="$("$base_resolver" "$worktree")" \
    || branch_growth_fail "could not resolve the base branch for '$worktree'" || return 1
  if git -C "$worktree" show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
    printf -v "$out_name" '%s' "refs/remotes/origin/$base_branch"
  elif git -C "$worktree" show-ref --verify --quiet "refs/heads/$base_branch"; then
    printf -v "$out_name" '%s' "refs/heads/$base_branch"
  else
    branch_growth_fail "base branch '$base_branch' has no local or origin ref in '$worktree'"
  fi
}
# The one git invocation every branch measurement reads, so callers score
# the same diffstat under the same rules. --find-renames is passed rather than
# left to the runner's diff.renames, so a move counts the same for each caller. core.quotePath=false keeps
# a non-ASCII path literal: under the default git wraps it in double quotes and
# escapes the bytes, and the classifier compares whole paths, so a quoted
# tests/ path stops reading as a test and its lines are scored against the
# production total. The base ref it compared against is left in
# BRANCH_GROWTH_BASE_REF for a caller that binds its verdict to the commits it
# measured.
#
# A caller that already knows the endpoint it is judging passes it as the fifth
# argument, and the base-branch lookup is skipped: the measurement is then of
# the range the caller named, never of whatever this checkout calls its default
# branch. An endpoint that does not resolve fails the measurement. Such a
# caller reaches no resolver and passes none, so $2 is empty there.
branch_size_numstat() {
  local worktree="$1" base_resolver="$2" commit="$3" out_name="$4" base_override="${5:-}"
  local base_ref measured_numstat
  if [[ -z "$base_override" ]]; then
    branch_growth_base_ref "$worktree" "$base_resolver" base_ref || return 1
  elif git -C "$worktree" cat-file -e "${base_override}^{commit}" 2>/dev/null; then
    base_ref="$base_override"
  else
    branch_growth_fail "base '$base_override' does not resolve to a commit in '$worktree'"
    return 1
  fi
  BRANCH_GROWTH_BASE_REF="$base_ref"
  measured_numstat="$(git -C "$worktree" -c core.quotePath=false diff --numstat --no-ext-diff --find-renames "$base_ref"..."$commit" --)" \
    || branch_growth_fail "git could not compare '$base_ref' with '$commit' in '$worktree'" || return 1
  printf -v "$out_name" '%s' "$measured_numstat"
}
BRANCH_GROWTH_RENDER_ROOTS=""
BRANCH_GROWTH_RENDER_ROOTS_DEFAULT=".agents .claude .codex .pi"
# The roots taken from this process's environment alone, for a caller that must
# not load the configuration of the tree it measures. A classifier judging a
# pull request is one: loading that tree's settings would let the change under
# judgement choose the roots its own size is scored against, and would source
# the file its KENDEX_ENV_FILE names. Called before branch_size_classified, it
# leaves branch_growth_render_roots nothing to do.
branch_growth_render_roots_from_env() {
  BRANCH_GROWTH_RENDER_ROOTS="${ORCH_SIZE_RENDER_ROOTS:-$BRANCH_GROWTH_RENDER_ROOTS_DEFAULT}"
}
# The render-mirror roots every branch measurement pairs against, resolved once
# per process from ORCH_SIZE_RENDER_ROOTS. `orch-runtime dev-return write`
# hands the measurement no render roots, so the measurement resolves them from
# the project's settings. CI callers set the roots from their trusted base
# configuration before measuring.
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
# is, which understates the receipt's churn.
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
  BRANCH_GROWTH_RENDER_ROOTS="${resolved:-$BRANCH_GROWTH_RENDER_ROOTS_DEFAULT}"
}
# The implement receipt carries its measured churn, which authorizes no fix
# round. CI classification shares the production/test and render measurement
# below.
branch_baseline_lines() {
  local worktree="$1" base_resolver="$2" commit="$3" out_name="$4" measured
  branch_size_classified "$worktree" "$base_resolver" "$commit" "" || return 1
  measured="$BRANCH_SIZE_BASELINE"
  (( measured > 0 )) || measured=1
  printf -v "$out_name" '%s' "$measured"
}
# The awk functions both programs below share. glob_to_regex reads a
# configured glob as a regex anchored over the whole path: only `*` and `?`
# are wild, and every other regex metacharacter is escaped, so the dot in
# check-*.py matches a dot and nothing else. is_test is the built-in test
# rule, widened by the regexes a program puts in pattern[1..npats].
BRANCH_GROWTH_AWK_PATHS='
    function base_name(p) { sub(/^.*\//, "", p); return p }
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
'
BRANCH_SIZE_PRODUCTION=""
BRANCH_SIZE_TEST=""
BRANCH_SIZE_MIRROR=""
# Every changed path the test rule names, by itself or past a render root,
# one per line, from every numstat row, a binary file's included. A paired
# render mirror's lines count as mirror lines, listed or not; every other row
# counts as test lines exactly when its path is listed. Each rename end is
# listed on its own, as a reader without rename detection names each apart.
BRANCH_SIZE_TEST_FILES=""
# Every counted row's additions plus deletions, render mirrors left out, for
# the implement receipt. This shares CI's render classification.
BRANCH_SIZE_BASELINE=""
# Split added lines into production, test and mandated render mirror lines
# for CI classification. The receipt also reads additions plus deletions.
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
# $5, when the caller passes one, is the base endpoint the measurement runs
# against, replacing the base-branch lookup, and $2 is then unused and empty.
#
# $4 is the blank-separated list of extra test-path globs a repository adds to
# the built-in test rule. A pattern matches the whole repository-relative path
# or, for a path under a render root, the path past that root, with `*` any
# run of characters including `/`, `?` any single character, and everything
# else literal. The list only adds: empty, or matching nothing, it
# leaves every line where the built-in rule put it. A path that rule does not
# name is production code.
#
# The globs reach awk through the environment, not a `-v` assignment: awk
# processes escape sequences in a `-v` value before the program sees it, so a
# backslash in a configured glob would be rewritten, and rewritten differently
# by gawk and mawk. An ENVIRON entry arrives byte for byte.
branch_size_classified() {
  local worktree="$1" base_resolver="$2" commit="$3" test_paths="$4" base_override="${5:-}"
  local numstat measured
  branch_growth_render_roots "$worktree" || return 1
  branch_size_numstat "$worktree" "$base_resolver" "$commit" numstat "$base_override" || return 1
  if ! measured="$(BRANCH_GROWTH_TEST_PATHS="$test_paths" \
    awk -F '\t' -v roots="$BRANCH_GROWTH_RENDER_ROOTS" "$BRANCH_GROWTH_AWK_PATHS"'
    # One end of a numstat path, 1 the path before a rename and 2 after it.
    # git abbreviates a shared prefix and suffix as `a/{b => c}/d`, and a side
    # that is empty there, as in `a/{ => c}/d`, leaves one slash too many.
    function rename_end(p, side,   open_at, close_at, prefix, suffix, moved) {
      if (index(p, " => ") == 0) return p
      open_at = index(p, "{")
      close_at = index(p, "}")
      if (open_at > 0 && close_at > open_at) {
        prefix = substr(p, 1, open_at - 1)
        suffix = substr(p, close_at + 1)
        moved = substr(p, open_at + 1, close_at - open_at - 1)
        if (side == 1) sub(/ => .*$/, "", moved); else sub(/^.* => /, "", moved)
        if (moved == "") suffix = substr(suffix, 2)
        return prefix moved suffix
      }
      if (side == 1) sub(/ => .*$/, "", p); else sub(/^.* => /, "", p)
      return p
    }
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
    function list_if_test(p,   rest) {
      rest = render_rest(p)
      if (is_test(p) || (rest != "" && is_test(rest))) { listed[p] = 1; test_files = test_files "\n" p }
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
    NF > 0 {
      list_if_test(rename_end($3, 1))
      if (index($3, " => ")) list_if_test(rename_end($3, 2))
    }
    NF == 0 || ($1 == "-" && $2 == "-") { next }
    $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { failed = 1; next }
    {
      n += 1
      path[n] = rename_end($3, 2)
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
        if (path[i] in listed) tests += lines[i]; else production += lines[i]
      }
      printf "%d %d %d %d%s", production + 0, tests + 0, mirror + 0, baseline + 0, test_files
    }
  ' <<<"$numstat")"; then
    branch_growth_fail "git numstat returned an unsupported additions/deletions shape"
    return 1
  fi
  read -r BRANCH_SIZE_PRODUCTION BRANCH_SIZE_TEST BRANCH_SIZE_MIRROR BRANCH_SIZE_BASELINE <<<"$measured"
  BRANCH_SIZE_TEST_FILES=""
  case "$measured" in
    *$'\n'*) BRANCH_SIZE_TEST_FILES="${measured#*$'\n'}" ;;
  esac
}
BRANCH_PROTECTION_KIND=""
BRANCH_PROTECTION_PATH=""
BRANCH_PROTECTION_REMOVED=""
BRANCH_PROTECTION_ADDED=""
# Whether the range BASE...HEAD removes test protection, read against the
# `case`, `skip` and `selection` lines of CONF, whose header states each.
# Every count is net over the whole range, so a test moved between files, or
# a test whose body changed while its marker line stayed, removes nothing.
# The first finding, in the order suite, case, skip, selection and then the
# list's own order, sets BRANCH_PROTECTION_KIND, _PATH, _REMOVED and _ADDED;
# a range that removes nothing leaves all four empty. A failed git read, an
# unreadable or malformed list, or a path git prints only quoted returns 1
# with BRANCH_GROWTH_ERROR: a range not read whole earns no finding and no
# clean answer either.
#
# A suite is a file the built-in test rule and a `case` glob both name,
# counted where the range deletes it or renames it out of that glob, net of
# those it adds or renames in. A skip line in a file the range adds narrows
# nothing that ran before, so it counts only in a file the base holds.
branch_protection_removed() { # REPO BASE HEAD CONF
  local repo="$1" range="$2...$3" conf="$4" statuses patch verdict
  BRANCH_PROTECTION_KIND=""
  BRANCH_PROTECTION_PATH=""
  BRANCH_PROTECTION_REMOVED=""
  BRANCH_PROTECTION_ADDED=""
  statuses="$(git -C "$repo" -c core.quotePath=false diff --name-status --no-ext-diff --find-renames "$range" --)" \
    || branch_growth_fail "git could not list the paths '$range' changes in '$repo'" || return 1
  patch="$(git -C "$repo" -c core.quotePath=false diff -U0 --no-ext-diff --no-textconv --no-color \
    --src-prefix=a/ --dst-prefix=b/ --find-renames "$range" --)" \
    || branch_growth_fail "git could not read the lines '$range' changes in '$repo'" || return 1
  if ! verdict="$(BRANCH_PROTECTION_CONF="$conf" awk "$BRANCH_GROWTH_AWK_PATHS"'
    function fail(why) { if (!failed) { failed = 1; reason = why }; exit }
    # A glob is matched against the path itself, which a quoted name is not.
    function plain(p) { if (substr(p, 1, 1) == "\"") fail("quoted-path " p); return p }
    function header_path(s, prefix) {
      sub(/\t$/, "", s)
      if (s == "/dev/null") return ""
      plain(s)
      if (substr(s, 1, 2) != prefix) fail("unprefixed-path " s)
      return substr(s, 3)
    }
    function suite_path(p, g) { return p != "" && is_test(p) && p ~ suite_re[g] }
    function found(what, p, removed, added) { printf "%s\t%s\t%d\t%d\n", what, p, removed, added }
    BEGIN {
      conf = ENVIRON["BRANCH_PROTECTION_CONF"]
      while ((got = (getline line < conf)) > 0) {
        if (line !~ /^(case|skip|selection) /) continue
        word = line; sub(/ .*$/, "", word)
        rest = substr(line, length(word) + 2); sub(/^ +/, "", rest)
        glob = rest; sub(/ .*$/, "", glob)
        ere = substr(rest, length(glob) + 1); sub(/^ +/, "", ere)
        if (glob == "" || (word == "selection") == (ere != "")) fail("malformed-marker " line)
        n++; kind[n] = word; path_re[n] = glob_to_regex(glob); marker[n] = ere
        if (word == "case" && !(glob in suite_of)) { suite_of[glob] = ++suites; suite_re[suites] = path_re[n] }
      }
      if (got < 0) fail("list-unreadable " conf)
      close(conf)
    }
    # The name-status rows come first; the first file header of the patch
    # ends them.
    !in_patch && /^diff --git / { in_patch = 1 }
    !in_patch {
      if ($0 == "") next
      fields = split($0, f, "\t")
      if (fields < 2) fail("status-unreadable " $0)
      for (i = 2; i <= fields; i++) plain(f[i])
      st = substr(f[1], 1, 1); gone = ""; came = ""
      if (st == "R") { gone = f[2]; came = f[3] }
      else if (st == "C") came = f[3]
      else if (st == "D") gone = f[2]
      else if (st == "A") came = f[2]
      for (g = 1; g <= suites; g++) {
        from = suite_path(gone, g); to = suite_path(came, g)
        if (from && !to) { suite_removed[g]++; if (suite_first[g] == "") suite_first[g] = gone }
        if (to && !from) suite_added[g]++
      }
      for (i = 2; i <= fields; i++) for (k = 1; k <= n; k++)
        if (kind[k] == "selection" && selected[k] == "" && f[i] ~ path_re[k]) selected[k] = f[i]
      next
    }
    /^diff --git / { hunk = 0; old_path = ""; new_path = ""; created = 0; next }
    !hunk && /^--- / { old_path = header_path(substr($0, 5), "a/"); created = (old_path == ""); next }
    !hunk && /^\+\+\+ / { new_path = header_path(substr($0, 5), "b/"); next }
    /^@@ / {
      if (!hunk) for (k = 1; k <= n; k++) {
        on_old[k] = (old_path != "" && old_path ~ path_re[k])
        on_new[k] = (new_path != "" && new_path ~ path_re[k])
      }
      hunk = 1
      next
    }
    !hunk { next }
    {
      sign = substr($0, 1, 1)
      if (sign != "-" && sign != "+") next
      removed = (sign == "-")
      text = substr($0, 2)
      for (k = 1; k <= n; k++) {
        if (!(removed ? on_old[k] : on_new[k])) continue
        if (kind[k] != "selection" && text !~ marker[k]) continue
        if (kind[k] == "skip" && !removed && created) continue
        if (removed) { lost[k]++; if (lost_first[k] == "") lost_first[k] = old_path }
        else { gained[k]++; if (gained_first[k] == "") gained_first[k] = new_path }
      }
    }
    END {
      if (failed) { print reason; exit 2 }
      for (g = 1; g <= suites; g++) if (suite_removed[g] > suite_added[g]) {
        found("suite", suite_first[g], suite_removed[g], suite_added[g]); exit
      }
      for (k = 1; k <= n; k++) if (kind[k] == "case" && lost[k] > gained[k]) {
        found("case", lost_first[k], lost[k], gained[k]); exit
      }
      for (k = 1; k <= n; k++) if (kind[k] == "skip" && gained[k] > lost[k]) {
        found("skip", gained_first[k], lost[k], gained[k]); exit
      }
      for (k = 1; k <= n; k++) if (kind[k] == "selection" && selected[k] != "") {
        found("selection", selected[k], lost[k], gained[k]); exit
      }
    }
  ' <<<"$statuses"$'\n'"$patch")"; then
    branch_growth_fail "the protection read of '$range' against '$conf' failed: ${verdict:-awk-failed}"
    return 1
  fi
  [ -n "$verdict" ] || return 0
  IFS=$'\t' read -r BRANCH_PROTECTION_KIND BRANCH_PROTECTION_PATH BRANCH_PROTECTION_REMOVED \
    BRANCH_PROTECTION_ADDED <<<"$verdict"
}
