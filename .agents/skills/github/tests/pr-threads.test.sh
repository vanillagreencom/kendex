#!/usr/bin/env bash
# pr-threads: the resolution filters in both output formats (the raw branch
# once echoed the GraphQL result unfiltered, so `--unresolved --format=raw`
# returned resolved threads), the filter applied across every fetched page,
# and the raw payload handed on as the API returned it.
#
# A row is `label|world|argv|rc|out|graphql`:
#   world    `page2` stages a second thread page behind a cursor (the stub
#            serves it only to a call carrying that cursor); `-` for one page
#   argv     pr-threads' arguments as written, after the PR number
#   rc       the exit status
#   out      raw: `raw nodes=[<id>:<r|u>,...] bytes=<exact|reshaped>`, the
#            node ids in output order with their resolution, and whether the
#            whole payload equals, byte for byte, the envelope jq builds from
#            those same fixture nodes (a dropped field, a reordered key or a
#            changed envelope reads `reshaped`);
#            safe: `safe count=<n> unresolved=<n> threads=[<id>:<r|u>,...]
#            first=<author>/<path>:<line>/<body>` of the first listed thread;
#            `-` when empty
#   graphql  how many `api graphql` calls the row made (one per page)
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PR_THREADS="$REPO_ROOT/skills/github/scripts/commands/pr-threads.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q

# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

# --- the threads --------------------------------------------------------------
thread() { # id isResolved
  printf '{"id":"%s","isResolved":%s,"isOutdated":false,"path":"src/lib.rs","line":7,"comments":{"nodes":[{"author":{"login":"reviewer"},"body":"note"}]}}' "$1" "$2"
}
PAGE1="[$(thread PRRT_done_a true),$(thread PRRT_done_b true),$(thread PRRT_open false)]"
PAGE2="[$(thread PRRT_page2_open false),$(thread PRRT_page2_done true)]"

# page NODES HAS_NEXT CURSOR: one GraphQL thread page.
page() {
  jq -cn --argjson nodes "$1" --argjson next "$2" --arg cursor "$3" \
    '{data:{repository:{pullRequest:{reviewThreads:{nodes:$nodes,pageInfo:{hasNextPage:$next,endCursor:(if $cursor == "" then null else $cursor end)}}}}}}'
}

# --- the world ------------------------------------------------------------------
build() {
  local w
  gh_stub_reset
  for w in "$@"; do
    case "$w" in
      # Page two is keyed on the cursor in the call's argv, not on the call
      # being the second: a code path that stopped sending the cursor would
      # otherwise still be handed page two.
      page2)
        gh_stub_answer api-graphql "$(page "$PAGE1" true cursor-page-2)"
        gh_stub_answer 'api-graphql:cursor=cursor-page-2' "$(page "$PAGE2" false '')"
        ;;
      -) gh_stub_answer api-graphql "$(page "$PAGE1" false '')" ;;
      *) echo "UNKNOWN-WORD: $w" >&2; exit 2 ;;
    esac
  done
}

out_text() {
  local text ids reference
  text="$(cat "$TMP_ROOT/stdout")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  if jq -e '.repository' >/dev/null 2>&1 <<<"$text"; then
    ids="$(jq -c '[.repository.pullRequest.reviewThreads.nodes[] | .id]' <<<"$text")"
    # The envelope the script documents, over the fixture nodes the output
    # names, in its order.
    reference="$(jq -cn --argjson all "$(jq -cn --argjson a "$PAGE1" --argjson b "$PAGE2" '$a + $b')" --argjson ids "$ids" \
      '{repository:{pullRequest:{reviewThreads:{nodes:[$ids[] as $i | $all[] | select(.id == $i)],pageInfo:{hasNextPage:false,endCursor:null}}}}}')"
    printf 'raw nodes=[%s] bytes=%s' \
      "$(jq -r '[.repository.pullRequest.reviewThreads.nodes[] | .id + ":" + (if .isResolved then "r" else "u" end)] | join(",")' <<<"$text")" \
      "$([[ "$text" == "$reference" ]] && printf exact || printf reshaped)"
    return
  fi
  jq -r '"safe count=\(.count) unresolved=\(.unresolved_count) threads=[\([.threads[] | .id + ":" + (if .is_resolved then "r" else "u" end)] | join(","))] first=\(.threads[0] | if . == null then "-" else "\(.author)/\(.path):\(.line)/\(.body)" end)"' <<<"$text"
}

run() {
  local rc=0
  local -a argv=()
  # shellcheck disable=SC2206
  [[ "$1" == - ]] || argv=($1)
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO \
    "$PR_THREADS" 123 ${argv[@]+"${argv[@]}"} >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  printf 'rc=%s out=%s graphql=%s' "$rc" "$(out_text)" "$(gh_stub_calls | grep -c '^api graphql' || true)"
}

run_table() {
  local title="$1" rows="$2" label world argv rc out graphql got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label world argv rc out graphql <<<"$row"
    for field in "$label" "$world" "$argv" "$rc" "$out" "$graphql"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    # shellcheck disable=SC2086
    build $world
    got="$(run "$argv")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$rc out=$out graphql=$graphql" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

run_table "the resolution filters" "\
raw --unresolved keeps only the unresolved node, the payload untouched|-|--unresolved --format=raw|0|raw nodes=[PRRT_open:u] bytes=exact|1
raw --resolved keeps only the resolved nodes|-|--resolved --format=raw|0|raw nodes=[PRRT_done_a:r,PRRT_done_b:r] bytes=exact|1
unfiltered raw is the API payload, every thread|-|--format=raw|0|raw nodes=[PRRT_done_a:r,PRRT_done_b:r,PRRT_open:u] bytes=exact|1
the filter applies across every fetched page|page2|--unresolved --format=raw|0|raw nodes=[PRRT_open:u,PRRT_page2_open:u] bytes=exact|2
safe --unresolved counts the filtered set and the PR's unresolved total|-|--unresolved|0|safe count=1 unresolved=1 threads=[PRRT_open:u] first=reviewer/src/lib.rs:7/note|1
safe --resolved counts the filtered set, the unresolved total unchanged|-|--resolved|0|safe count=2 unresolved=1 threads=[PRRT_done_a:r,PRRT_done_b:r] first=reviewer/src/lib.rs:7/note|1
"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
