#!/usr/bin/env bash
# bash-runtime: 4
# `linear.sh graphql` sends one read document and prints Linear's `data`
# unchanged. A document that is not a read is refused before any request, an
# answer with a connection left open is refused naming its path, a missing
# entity exits 2, and an error a write would take as already holding stays an
# error on a read.
#
# Runs fully offline against a mocked curl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir ROOT

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
git -C "$ROOT" init -q -b main
mkdir -p "$ROOT/bin"

# Each request's payload is one line of requests.jsonl; the answer is the
# case's body under HTTP 200.
cat >"$ROOT/bin/curl" <<SH
#!/usr/bin/env bash
sed -n 's/^data = //p' | jq -c 'fromjson' >>"$ROOT/requests.jsonl"
printf '%s___HTTP_CODE___200' "\$(cat "$ROOT/body")"
SH
chmod +x "$ROOT/bin/curl"

# run_case BODY ARGS... — RC, OUT, ERR and SENT hold the status, stdout,
# stderr and the number of requests sent.
run_case() {
  printf '%s' "$1" >"$ROOT/body"
  shift
  : >"$ROOT/requests.jsonl"
  RC=0
  (cd "$ROOT" && env -i PATH="$ROOT/bin:$PATH" HOME="$ROOT" LINEAR_API_KEY_OVERRIDE=lin_api_test \
    LINEAR_RETRY_BASE_DELAY=0 bash "$SKILL_DIR/scripts/linear.sh" graphql "$@" \
    >"$ROOT/out" 2>"$ROOT/err") || RC=$?
  OUT="$(cat "$ROOT/out")"
  ERR="$(cat "$ROOT/err")"
  SENT="$(wc -l <"$ROOT/requests.jsonl" | tr -d ' ')"
}

# name|document|body|exit|stdout|stderr substring|requests
while IFS='|' read -r name document body want_rc want_out want_err want_sent; do
  run_case "$body" --query "$document"
  assert_eq "$name: exit" "$RC" "$want_rc"
  assert_eq "$name: stdout" "$OUT" "$want_out"
  if [[ -n "$want_err" ]]; then
    assert_contains "$name: stderr" "$ERR" "$want_err"
  fi
  assert_eq "$name: requests" "$SENT" "$want_sent"
done <<'ROWS'
a closed answer prints data unchanged|query { issue(id: "KEN-1") { title children { pageInfo { hasNextPage } nodes { id } } } }|{"data":{"issue":{"title":"T","children":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"c1"}]}}}}|0|{"issue":{"title":"T","children":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"c1"}]}}}||1
a GraphQL error exits 1 with its message|query { viewer { id } }|{"errors":[{"message":"Field viewer is broken"}]}|1||Field viewer is broken|1
a missing entity exits 2|query { issue(id: "KEN-404") { id } }|{"errors":[{"message":"Entity not found: Issue"}]}|2||Entity not found: Issue|1
an already-exist error on a read exits 1|query { viewer { id } }|{"errors":[{"message":"Relation already exists"}]}|1||Relation already exists|1
a mutation is refused before any request|mutation { issueDelete(id: "x") { success } }|{"data":{}}|1||linear-graphql: read-only|0
the shorthand is refused before any request|{ viewer { id } }|{"data":{}}|1||linear-graphql: read-only|0
an open connection is refused naming its path|query { issue(id: "KEN-1") { children { pageInfo { hasNextPage } nodes { id } } } }|{"data":{"issue":{"children":{"pageInfo":{"hasNextPage":true},"nodes":[]}}}}|1||linear-graphql: open path=issue.children|1
an open nested connection is refused naming its path|query { issue(id: "KEN-1") { children { pageInfo { hasNextPage } nodes { children { pageInfo { hasNextPage } nodes { id } } } } } }|{"data":{"issue":{"children":{"pageInfo":{"hasNextPage":false},"nodes":[{"children":{"pageInfo":{"hasNextPage":true},"nodes":[]}}]}}}}|1||linear-graphql: open path=issue.children.nodes.0.children|1
ROWS

run_case '{"data":{"issue":{"title":"T"}}}' \
  --query 'query Item($id: String!) { issue(id: $id) { title } }' --variables '{"id":"KEN-1"}'
assert_eq "variables reach the request: exit" "$RC" 0
assert "variables reach the request" jq -e '.variables == {"id": "KEN-1"}' "$ROOT/requests.jsonl"

# A write that already holds is still a success: the transport the verb
# shares with every write keeps it.
cat >"$ROOT/subject" <<'SH'
set -euo pipefail
cd "$1"
source "$2"
graphql_request 'mutation { issueRelationCreate(input: {}) { success } }' ''
SH
printf '%s' '{"errors":[{"message":"Relation already exists"}]}' >"$ROOT/body"
RC=0
env -i PATH="$ROOT/bin:$PATH" HOME="$ROOT" LINEAR_API_KEY_OVERRIDE=lin_api_test LINEAR_RETRY_BASE_DELAY=0 \
  bash "$ROOT/subject" "$ROOT" "$SKILL_DIR/scripts/lib/common.sh" >"$ROOT/out" 2>"$ROOT/err" || RC=$?
assert_eq "an already-exist error on a write is a success: exit" "$RC" 0
assert_eq "an already-exist error on a write is a success: stdout" "$(cat "$ROOT/out")" '{"already_exists": true}'
