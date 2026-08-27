#!/usr/bin/env bash
# The fake `gh` the selftest and the suites beside it put on PATH: it answers
# every `gh api` read from fixture files under GH_SHIM_FIXTURES and applies
# any --jq filter with real jq, so review-predicate.sh runs unmodified.
# Dispatch is by request shape (the endpoint path, or GraphQL); the switches
# GH_SHIM_FAIL, GH_SHIM_FAIL_TIMES and GH_SHIM_EMPTY drive the fail-loud
# paths, and <name>.page2.json models a second page.
# Every request URL is appended to .urls.log so a case can pin read shapes.
set -euo pipefail
url=""; filter=""; paginate=0; graphql_page2=0; graphql_after=""
while [ $# -gt 0 ]; do
  case "$1" in
    api|--slurp) ;;
    --paginate) paginate=1 ;;
    -f|-F)
      shift
      # A cursor variable marks a follow-up thread page: serve the page-2
      # fixture (when present) so pagination is exercised for real. The
      # cursor VALUE is kept so cursor-keyed fixtures
      # (graphql.cursor-<value>.json) can drive an arbitrarily deep walk —
      # the page-budget bound cannot be proven with a single follow-up page.
      case "$1" in
        after=*)
          graphql_page2=1
          graphql_after="${1#after=}"
          # Cursor-keyed fixtures embed the cursor in a pathname, so the
          # namespace is enforced, not assumed: every cursor this suite
          # authors is [A-Za-z0-9_-]. Anything else would silently fall
          # back to the page-2/default fixture and a case could claim a
          # deep walk it never drove — refuse loudly instead.
          # Empty is refused with the same teeth: an empty after= cannot
          # select a cursor fixture and would silently fall through to the
          # page-2/default fixture — the false coverage this guard exists
          # to prevent.
          case "$graphql_after" in
            '' | *[!A-Za-z0-9_-]*)
              echo "shim: cursor value unusable as a fixture key (allowed: non-empty A-Za-z0-9_-): $graphql_after" >&2
              exit 92
              ;;
          esac
          ;;
      esac
      ;;
    --jq) shift; filter="$1" ;;
    graphql) url="graphql" ;;
    *) [ -z "$url" ] && url="$1" ;;
  esac
  shift
done
case "$url" in
  *"/check-runs"*) name=checkruns ;;
  *"/compare/"*) name=compare ;;
  *"/reviews"*)  name=reviews ;;
  *"/statuses"*) name=statuses ;;
  *"/status"*)   name=status ;;
  *"/issues/"*"/comments"*) name=comments ;;
  graphql)       name=graphql ;;
  *"/pulls/"*)   name=pull ;;
  *) echo "shim: unexpected request: $url" >&2; exit 90 ;;
esac
echo "$url" >>"$GH_SHIM_FIXTURES/.urls.log"
if [ -n "${GH_SHIM_FAIL:-}" ] && [ "$GH_SHIM_FAIL" = "$name" ]; then
  if [ -n "${GH_SHIM_FAIL_TIMES:-}" ]; then
    count=0
    counter="$GH_SHIM_FIXTURES/.failcount.$name"
    [ -f "$counter" ] && count="$(cat "$counter")"
    if [ "$count" -lt "$GH_SHIM_FAIL_TIMES" ]; then
      echo $((count + 1)) >"$counter"
      echo "shim: simulated API failure for $name ($((count + 1))/$GH_SHIM_FAIL_TIMES)" >&2
      exit 1
    fi
  else
    echo "shim: simulated API failure for $name" >&2
    exit 1
  fi
fi
if [ -n "${GH_SHIM_EMPTY:-}" ] && [ "$GH_SHIM_EMPTY" = "$name" ]; then
  exit 0
fi
file="$GH_SHIM_FIXTURES/$name.json"
if [ "$name" = "graphql" ] && [ -n "$graphql_after" ] && [ -f "$GH_SHIM_FIXTURES/graphql.cursor-$graphql_after.json" ]; then
  # Cursor-keyed page: the fixture named by the requested cursor wins, so a
  # case can lay out a distinct advancing page per cursor and walk the full
  # page budget. Falls through to the single page-2 fixture when absent —
  # the two-page pattern's shape.
  file="$GH_SHIM_FIXTURES/graphql.cursor-$graphql_after.json"
elif [ "$name" = "graphql" ] && [ "$graphql_page2" = "1" ] && [ -f "$GH_SHIM_FIXTURES/graphql.page2.json" ]; then
  file="$GH_SHIM_FIXTURES/graphql.page2.json"
elif [ "$name" = "graphql" ] && [ -n "$graphql_after" ]; then
  # A follow-up request with NEITHER a cursor-keyed fixture NOR a page-2
  # fixture would silently re-serve page one — a deep-walk case missing one
  # of its files (a valid-looking cursor with a fixture gap) must refuse,
  # not fabricate coverage.
  echo "shim: follow-up page requested (after=$graphql_after) but no graphql.cursor-$graphql_after.json or graphql.page2.json fixture exists" >&2
  exit 93
fi
[ -f "$file" ] || { echo "shim: no fixture $file" >&2; exit 91; }
if [ -n "$filter" ]; then jq -r "$filter" <"$file"; else cat "$file"; fi
if [ "$paginate" = "1" ] && [ -f "$GH_SHIM_FIXTURES/$name.page2.json" ] && [ -z "$filter" ]; then
  cat "$GH_SHIM_FIXTURES/$name.page2.json"
fi
