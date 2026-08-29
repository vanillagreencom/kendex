#!/usr/bin/env bash
# Comments are fetched as their own connection, not nested inside the issues
# query. Two reasons, and the test pins both.
#
# Linear scores a query on the product of its requested connection sizes, so a
# per-issue comment page inside an issue page crosses the complexity limit and
# the ISSUES query is rejected outright. And a nested connection can only ever
# return its first page: there is no cursor to ask for the rest, so a long
# thread lands in the cache truncated and indistinguishable from a whole one.
#
# Locks in:
#   A. the issues query nests no comments connection;
#   B. sync_comments is a top-level comments query with a cursor and pageInfo;
#   C. it pages to completion, concatenating every page;
#   D. it FAILS rather than returning a partial pull, and writes nothing;
#   E. write_comments groups a flat pull by issue, drops the issue field, and
#      removes the file of a scoped issue the pull returned nothing for.
#
# Fully offline: graphql_query is stubbed after sourcing, no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$SKILL_DIR/scripts/commands/sync.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

# --- A. the issues query carries no comments connection ---------------------

issues_query="$(sed -n '/query SyncIssues/,/^    }'"'"'$/p' "$SYNC")"
[ -n "$issues_query" ] || bad "issues query" "could not extract query SyncIssues from sync.sh"
case "$issues_query" in
  *comments*) bad "nested comments" "query SyncIssues still nests a comments connection" ;;
  *) ok "the issues query nests no comments connection" ;;
esac

# --- B. the comments query is top-level, cursored, and asks for pageInfo ----

comments_query="$(sed -n '/query SyncComments/,/^    }'"'"'$/p' "$SYNC")"
[ -n "$comments_query" ] || bad "comments query" "could not extract query SyncComments from sync.sh"
for token in 'comments(filter:' '$after' 'hasNextPage' 'endCursor' 'issue { identifier }'; do
  case "$comments_query" in
    *"$token"*) ok "the comments query carries $token" ;;
    *) bad "comments query" "missing $token" ;;
  esac
done

# --- setup: source the script, stub the API ---------------------------------

# sync.sh sources the skill's libs and self-executes only when run as a
# command; sourced with no arguments it just defines its functions. The libs
# resolve the cache from the enclosing git worktree and assign CACHE_DIR
# unconditionally, so the sandbox is a throwaway repo entered before the
# source, not an environment variable set after it.
git -C "$TMP_ROOT" init -q -b main
mkdir -p "$TMP_ROOT/.cache/linear/comments"
cd "$TMP_ROOT"
# shellcheck disable=SC1090
source "$SYNC"

# Anything that writes outside the sandbox would be editing the developer's
# own Linear cache, so stop before the first write rather than after it.
case "$CACHE_DIR" in
  "$TMP_ROOT"/*) ok "the cache under test is sandboxed" ;;
  *) echo "REFUSING: CACHE_DIR resolved outside the sandbox: $CACHE_DIR" >&2; exit 1 ;;
esac

# sync_comments captures each response through a command substitution, which
# runs the stub in a subshell, so the call counter lives in a file rather than
# a variable that the subshell would only increment for itself.
COUNTER="$TMP_ROOT/calls"
calls() { cat "$COUNTER"; }
graphql_query() {
  local n
  n=$(( $(cat "$COUNTER") + 1 ))
  echo "$n" >"$COUNTER"
  if [ "$STUB_MODE" = "endless" ]; then
    printf '{"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"c%s"},"nodes":[{"id":"c%s","body":"b","issue":{"identifier":"T-1"}}]}}' \
      "$n" "$n"
    return 0
  fi
  sed -n "${n}p" "$TMP_ROOT/pages.jsonl"
}

# --- C. pages to completion -------------------------------------------------

STUB_MODE=canned
echo 0 >"$COUNTER"
{
  printf '{"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[{"id":"a1","body":"one","issue":{"identifier":"T-1"}}]}}\n'
  printf '{"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"c2"},"nodes":[{"id":"a2","body":"two","issue":{"identifier":"T-1"}}]}}\n'
  printf '{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"b1","body":"three","issue":{"identifier":"T-2"}}]}}\n'
} >"$TMP_ROOT/pages.jsonl"

echo 0 >"$COUNTER"
if OUT="$(sync_comments '{}')"; then
  [ "$(echo "$OUT" | jq 'length')" = "3" ] \
    && ok "every page is concatenated into one pull" \
    || bad "page concatenation" "got $(echo "$OUT" | jq 'length') nodes"
  [ "$(calls)" = "3" ] \
    && ok "paging stops when hasNextPage goes false" \
    || bad "page count" "$(calls) calls"
else
  bad "sync_comments" "failed on a complete three-page pull"
fi

# --- D. a pull that cannot complete fails and writes nothing ----------------

STUB_MODE=endless
echo 0 >"$COUNTER"
ERR_FILE="$TMP_ROOT/err"
if OUT="$(sync_comments '{}' 2>"$ERR_FILE")"; then
  bad "endless pull" "sync_comments exited 0 on a pull that never completed"
else
  ok "a pull that never completes fails instead of returning a prefix"
  case "$(cat "$ERR_FILE")" in
    *"nothing was written"*) ok "the failure says the cache was left alone" ;;
    *) bad "failure message" "stderr: $(cat "$ERR_FILE")" ;;
  esac
fi
[ -z "$(ls -A "$CACHE_DIR/comments")" ] \
  && ok "a failed pull writes no comment file" \
  || bad "failed pull" "wrote $(ls -A "$CACHE_DIR/comments")"

# --- E. write_comments ------------------------------------------------------

cat >"$TMP_ROOT/scope.json" <<'JSON'
[{"identifier":"T-1"},{"identifier":"T-2"},{"identifier":"T-3"}]
JSON
# T-3 is in scope with no comments in the pull; its stale file must go. The
# project comment belongs to no issue and must land nowhere.
printf '[]' | jq '.' >"$CACHE_DIR/comments/T-3.json"
cat >"$TMP_ROOT/pull.json" <<'JSON'
[{"id":"a1","body":"one","issue":{"identifier":"T-1"}},
 {"id":"a2","body":"two","issue":{"identifier":"T-1"}},
 {"id":"b1","body":"three","issue":{"identifier":"T-2"}},
 {"id":"p1","body":"project note","issue":null}]
JSON

write_comments "$TMP_ROOT/pull.json" "$TMP_ROOT/scope.json"

[ "$(jq -r 'length' "$CACHE_DIR/comments/T-1.json")" = "2" ] \
  && ok "an issue's comments are grouped into its own file" \
  || bad "T-1 grouping" "$(cat "$CACHE_DIR/comments/T-1.json")"
[ "$(jq -r '.[0] | has("issue")' "$CACHE_DIR/comments/T-1.json")" = "false" ] \
  && ok "the issue field is stripped from the cached node" \
  || bad "issue field" "$(jq -c '.[0]' "$CACHE_DIR/comments/T-1.json")"
[ "$(jq -r '.[0].id' "$CACHE_DIR/comments/T-2.json")" = "b1" ] \
  && ok "each issue gets its own file" \
  || bad "T-2 file" "$(cat "$CACHE_DIR/comments/T-2.json" 2>&1)"
[ ! -f "$CACHE_DIR/comments/T-3.json" ] \
  && ok "a scoped issue with no comments loses its stale file" \
  || bad "T-3 file" "still present"
[ -z "$(ls "$CACHE_DIR/comments" | grep -v '^T-')" ] \
  && ok "a comment on no issue lands in no file" \
  || bad "stray file" "$(ls "$CACHE_DIR/comments")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
