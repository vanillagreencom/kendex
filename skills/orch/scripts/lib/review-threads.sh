#!/usr/bin/env bash
# The one reviewThreads walk in orch. approval-wait and queue-wait both decide
# whether a PR still carries open review threads from it, and a waiter that
# counted differently from the guard would let one of them pass a PR the other
# would hold.
#
# Source this file; do not execute it directly.

# A PR with more pages than this cannot be verified inside one probe. The
# bound is a refusal, not a truncation: the walk fails rather than reporting
# the pages it managed to read.
ORCH_THREAD_PAGE_MAX=20

ORCH_THREADS_QUERY='query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { isResolved }
      }
    }
  }
}'

# orch_count_unresolved_threads OWNER REPO NUMBER ERR_FILE
#
# Prints the number of unresolved threads across every page and returns 0 only
# when every page verified. gh's stderr is appended to ERR_FILE so the caller
# can classify a failure as transient or terminal.
#
# Returns 1 — and prints nothing — on a query failure, a PARTIAL response (a
# top-level `errors` array, however well-shaped the data beside it looks), a
# null or malformed reviewThreads, a non-boolean isResolved or hasNextPage, a
# hasNextPage whose cursor is missing or does not advance, or a walk needing
# more than ORCH_THREAD_PAGE_MAX pages. Every one of those is fail-closed:
# an unverifiable read is never "no threads".
orch_count_unresolved_threads() {
  local owner="$1" repo="$2" number="$3" err_file="$4"
  local cursor="" total=0 pages=0 threads_json threads_status
  local page_result page_count page_next page_cursor
  while true; do
    pages=$((pages + 1))
    [ "$pages" -le "$ORCH_THREAD_PAGE_MAX" ] || return 1
    threads_status=0
    set +e
    if [ -n "$cursor" ]; then
      threads_json=$(gh api graphql \
        -f query="$ORCH_THREADS_QUERY" \
        -F owner="$owner" -F repo="$repo" -F number="$number" \
        -F cursor="$cursor" 2>>"$err_file")
    else
      threads_json=$(gh api graphql \
        -f query="$ORCH_THREADS_QUERY" \
        -F owner="$owner" -F repo="$repo" -F number="$number" 2>>"$err_file")
    fi
    threads_status=$?
    set -e
    [ "$threads_status" -eq 0 ] || return 1
    # One strict pass per page: count only when every shape assumption holds.
    # An `errors` field that is present but NOT an array is a malformed body,
    # never an empty error set: `{}` and `""` both measure zero length, which
    # would have read as "no errors" and counted the partial data beside them.
    # `gh api graphql` returns the response envelope; a pre-stripped object is
    # tolerated too, so stubs and future gh versions both parse.
    page_result=$(jq -r '
      if (type != "object") then .
        elif (has("errors") and ((.errors | type) != "array"))
          then error("malformed graphql errors")
        elif ((.errors? // []) | length) > 0
          then error("graphql errors")
        else . end
      | (.data // .) as $d
      | ($d.repository.pullRequest.reviewThreads?) as $rt
      | if ($rt | type) != "object" then error("bad reviewThreads")
        elif ($rt.nodes | type) != "array" then error("bad nodes")
        elif ([$rt.nodes[] | (.isResolved | type)] | all(. == "boolean") | not)
          then error("bad isResolved")
        elif ($rt.pageInfo.hasNextPage | type) != "boolean" then error("bad pageInfo")
        else
          ([$rt.nodes[] | select(.isResolved == false)] | length | tostring)
          + " " + ($rt.pageInfo.hasNextPage | tostring)
          + " " + ($rt.pageInfo.endCursor // "")
        end' <<<"$threads_json" 2>/dev/null) || return 1
    read -r page_count page_next page_cursor <<<"$page_result"
    total=$((total + page_count))
    if [ "$page_next" = "true" ]; then
      # More pages promised: a missing or non-advancing cursor means the walk
      # cannot verify the remainder — fail closed now rather than burn the
      # page budget re-reading the same page.
      [ -n "$page_cursor" ] || return 1
      [ "$page_cursor" != "$cursor" ] || return 1
      cursor="$page_cursor"
    else
      printf '%s\n' "$total"
      return 0
    fi
  done
}
