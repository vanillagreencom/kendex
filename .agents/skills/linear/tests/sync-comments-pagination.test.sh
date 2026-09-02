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
#      removes the file of a scoped issue the pull returned nothing for;
#   F. it writes only issues in scope, so a comment on an archived issue the
#      caller already removed does not come straight back as an orphan file.
#
# Fully offline: graphql_query is stubbed after sourcing, no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$SKILL_DIR/scripts/commands/sync.sh"
assert_tmpdir TMP_ROOT

# --- A. the issues query carries no comments connection ---------------------

issues_query="$(sed -n '/query SyncIssues/,/^    }'"'"'$/p' "$SYNC")"
assert_ne "query SyncIssues is extractable from sync.sh" "$issues_query" ""
assert_not_contains "the issues query nests no comments connection" "$issues_query" "comments"

# --- B. the comments query is top-level, cursored, and asks for pageInfo ----

comments_query="$(sed -n '/query SyncComments/,/^    }'"'"'$/p' "$SYNC")"
assert_ne "query SyncComments is extractable from sync.sh" "$comments_query" ""
for token in 'comments(filter:' '$after' 'hasNextPage' 'endCursor' 'issue { identifier }'; do
  assert_contains "the comments query carries $token" "$comments_query" "$token"
done

# --- the write and the sweep answer to one scope ----------------------------

# Behaviour cannot tell a single derivation from two identical ones, so this
# is pinned structurally: inside write_comments the caller's issue file is
# read exactly once, where the scope is built. A second read is a second
# statement of the scope, and the halves drift from there.
body="$(awk '/^write_comments\(\) \{/,/^\}/' "$SYNC")"
assert_ne "write_comments is extractable from sync.sh" "$body" ""
reads="$(printf '%s\n' "$body" | grep -c 'scope_issues_file')"
# One is the local declaration, one is the derivation; a third is a re-read.
assert_eq "the scope is derived from the caller's issue file exactly once" "$reads" "2"

# --- setup: source the script, stub the API ---------------------------------

# sync.sh sources the skill's libs and self-executes only when run as a
# command; sourced with no arguments it just defines its functions. The libs
# fix CACHE_DIR at source time, so the redirect has to be in place before the
# source, not after it — and this root replaces the assert lib's default
# sandbox because the assertions below name paths under it.
git -C "$TMP_ROOT" init -q -b main
mkdir -p "$TMP_ROOT/.cache/linear/comments"
export LINEAR_CACHE_ROOT="$TMP_ROOT"
cd "$TMP_ROOT"
# shellcheck disable=SC1090
source "$SYNC"

# Anything that writes outside the sandbox would be editing the developer's
# own Linear cache, so stop before the first write rather than after it.
case "$CACHE_DIR" in
  "$TMP_ROOT"/*) ;;
  *) assert_stop "the cache under test is sandboxed" "CACHE_DIR resolved outside the sandbox: $CACHE_DIR" ;;
esac
assert_contains "the cache under test is sandboxed" "$CACHE_DIR" "$TMP_ROOT/"

# sync_comments captures each response through a command substitution, which
# runs the stub in a subshell, so the call counter lives in a file rather than
# a variable that the subshell would only increment for itself.
COUNTER="$TMP_ROOT/calls"
calls() { cat "$COUNTER"; }
graphql_query() {
  local n
  n=$(( $(cat "$COUNTER") + 1 ))
  echo "$n" >"$COUNTER"
  if [ "$STUB_MODE" = "apierror" ]; then
    echo '{"error":"unexpected query"}' >&2
    return 1
  fi
  if [ "$STUB_MODE" = "noconnection" ]; then
    printf '{"somethingElse":{}}'
    return 0
  fi
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
# sync_comments is product code sourced into this suite, so its status has to
# come from run_output: a command substitution in a `||` operand suspends the
# errexit it relies on, and a pull that aborted partway would report success.
run_output OUT rc sync_comments '{}'

assert_eq "a complete three-page pull succeeds" "$rc" 0
assert_eq "every page is concatenated into one pull" "$(echo "$OUT" | jq 'length')" "3"
assert_eq "paging stops when hasNextPage goes false" "$(calls)" "3"

# --- D. a pull that cannot complete fails and writes nothing ----------------

STUB_MODE=endless
echo 0 >"$COUNTER"
ERR_FILE="$TMP_ROOT/err"
run_output OUT rc sync_comments '{}' 2>"$ERR_FILE"

assert_ne "a pull that never completes fails instead of returning a prefix" "$rc" 0
assert_file_contains "the failure says the cache was left alone" "$ERR_FILE" "nothing was written"
assert_eq "a failed pull writes no comment file" "$(ls -A "$CACHE_DIR/comments")" ""

# --- D2. a failed query fails the pull, it does not return empty ------------

# The callers invoke sync_comments as an `if !` condition, which suspends
# errexit for the whole function body. A query failure that is not checked
# explicitly therefore falls through, and the sync stamps a complete pull over
# a cache that never received one.
# Each mode asserts its OWN diagnostic. A shared "nothing was written" match
# would pass with either guard removed, since the survivor catches the other's
# case with a vaguer message.
check_failure() { # check_failure <mode> <expected fragment>
  local rc=0
  STUB_MODE="$1"
  echo 0 >"$COUNTER"
  run_output OUT rc sync_comments '{}' 2>"$ERR_FILE"

  assert_ne "a $1 response fails the pull" "$rc" 0
  assert_file_contains "a $1 response is diagnosed as: $2" "$ERR_FILE" "$2"
}
check_failure apierror 'the comments query failed'
check_failure noconnection 'returned no comments connection'
STUB_MODE=canned

# --- E. write_comments ------------------------------------------------------

cat >"$TMP_ROOT/scope.json" <<'JSON'
[{"identifier":"T-1"},{"identifier":"T-2"},{"identifier":"T-3"}]
JSON
# T-3 is in scope with no comments in the pull; its stale file must go. The
# project comment belongs to no issue and must land nowhere. T-9 is the
# archived case: the caller removed it from the issue set and deleted its
# file, and the comments connection still returns it.
printf '[]' | jq '.' >"$CACHE_DIR/comments/T-3.json"
cat >"$TMP_ROOT/pull.json" <<'JSON'
[{"id":"a1","body":"one","issue":{"identifier":"T-1"}},
 {"id":"a2","body":"two","issue":{"identifier":"T-1"}},
 {"id":"b1","body":"three","issue":{"identifier":"T-2"}},
 {"id":"z1","body":"on an archived issue","issue":{"identifier":"T-9"}},
 {"id":"p1","body":"project note","issue":null}]
JSON

write_comments "$TMP_ROOT/pull.json" "$TMP_ROOT/scope.json"

assert_eq "an issue's comments are grouped into its own file" \
  "$(jq -r 'length' "$CACHE_DIR/comments/T-1.json")" "2"
assert_eq "the issue field is stripped from the cached node" \
  "$(jq -r '.[0] | has("issue")' "$CACHE_DIR/comments/T-1.json")" "false"
assert_eq "each issue gets its own file" \
  "$(jq -r '.[0].id' "$CACHE_DIR/comments/T-2.json")" "b1"
assert_not "a scoped issue with no comments loses its stale file" \
  test -f "$CACHE_DIR/comments/T-3.json"
assert_eq "a comment on no issue lands in no file" \
  "$(ls "$CACHE_DIR/comments" | grep -v '^T-' || true)" ""

# --- F. the write answers to the same scope as the sweep --------------------

assert_not "a comment on an out-of-scope issue writes no file" \
  test -f "$CACHE_DIR/comments/T-9.json"

# The delete-then-recreate loop, end to end: the caller drops an archived
# issue's file, the very next pull still carries that issue, and the delete
# has to stay deleted.
printf '[{"id":"z0","body":"stale"}]' >"$CACHE_DIR/comments/T-9.json"
rm -f "$CACHE_DIR/comments/T-9.json"
write_comments "$TMP_ROOT/pull.json" "$TMP_ROOT/scope.json"
assert_not "a deleted archived issue's file stays deleted across a pull" \
  test -f "$CACHE_DIR/comments/T-9.json"
