#!/usr/bin/env bash
# `issues bulk-get` reads every issue it names: an identifier in any case or a
# UUID, in the order given, archived issues included, in one request when the
# batch read answers every reference, each issue once. A reference the batch
# leaves unanswered, such as a moved issue's earlier identifier, takes one
# lookup by id; one Linear answers it has no issue for refuses the whole read
# with a `missing` list. A lookup that fails any other way fails the read with
# no `missing` and sends no lookup after it.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1
assert_tmpdir TMP_ROOT
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
git -C "$TMP_ROOT" init -q -b main
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

# Linear's issues, answered as Linear answers: the `id` filter matches an
# identifier or a UUID and leaves archived issues out unless the query asks
# for them; `issue(id:)` also matches an identifier the issue had before a
# move, and errors on one it cannot find, in the shape Linear answers a
# missing issue (measured live). KEN-3 is archived; KEN-4 was OLD-7. A lookup
# of RATE-1 is rate limited (Linear serves RATELIMITED under HTTP 400) and one
# of DOWN-1 answers 503, on every attempt.
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
printf '%s\n' "$payload" >>"$CALLS"
case "$(jq -r '.variables.id // empty' <<<"$payload")" in
RATE-1)
    printf '%s' '{"errors":[{"message":"Rate limit exceeded","extensions":{"code":"RATELIMITED"}}]}___HTTP_CODE___400'
    exit 0
    ;;
DOWN-1)
    printf '%s' 'upstream unavailable___HTTP_CODE___503'
    exit 0
    ;;
esac
jq -cj '
def closed: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: []};
def issue($n; $archived; $previous): {id: "00000000-0000-4000-8000-00000000000\($n)", identifier: "KEN-\($n)",
    title: "Fixture text", description: "", state: {name: "Todo", type: "unstarted"}, assignee: null,
    project: null, projectMilestone: null, cycle: null, team: {name: "Fixture"}, labels: closed, priority: 0,
    estimate: null, sortOrder: 0, url: "", createdAt: "2026-10-01T00:00:00.000Z",
    updatedAt: "2026-10-01T00:00:00.000Z", archivedAt: $archived, trashed: null, parent: null,
    children: closed, relations: closed, inverseRelations: closed, _previous: $previous};
def world: [issue(1; null; []), issue(2; null; []), issue(3; "2026-10-02T00:00:00.000Z"; []), issue(4; null; ["OLD-7"])];
.query as $q |
if ($q | test("issue[(]id:")) then
    .variables.id as $ref
    | [world[] | select(.identifier == $ref or .id == $ref or (._previous | index($ref)))] as $hit
    | if ($hit | length) == 1 then {data: {issue: ($hit[0] | del(._previous))}}
      else {errors: [{message: "Entity not found: Issue", path: ["issue"], extensions: {type: "invalid input",
          code: "INPUT_ERROR", statusCode: 400, userError: true, userPresentableMessage: "Could not find referenced Issue."}}],
          data: null} end
else
    .variables.filter.id.in as $refs
    | {data: {issues: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [world[]
        | select(.identifier as $i | .id as $u | $refs | index($i) or index($u))
        | select(.archivedAt == null or ($q | test("includeArchived: *true")))
        | del(._previous)]}}}
end' <<<"$payload"
printf '___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"

# The identifiers printed, the requests sent and the refusal's missing list,
# as one line.
bulk_summary() { # REF...
    local rc=0 out requests missing
    : >"$TMP_ROOT/calls"
    out=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" \
        LINEAR_API_KEY_OVERRIDE=test-key LINEAR_RETRY_BASE_DELAY=0 bash .agents/skills/linear/scripts/linear.sh issues bulk-get "$@" \
        --format=ids 2>"$TMP_ROOT/err") || rc=$?
    requests=$(wc -l <"$TMP_ROOT/calls" | tr -d ' ')
    missing=$(jq -sc 'map(.missing | arrays) | add // []' "$TMP_ROOT/err" 2>/dev/null) || missing=unparsed
    printf 'rc=%s out=%s requests=%s missing=%s\n' "$rc" "${out//$'\n'/,}" "$requests" "$missing"
}

# label|refs|want
while IFS='|' read -r label refs want; do
    [[ -n "$label" ]] || continue
    read -r -a argv <<<"$refs"
    assert_eq "$label" "$(bulk_summary "${argv[@]}")" "$want"
done <<'ROWS'
a UUID reads its issue|00000000-0000-4000-8000-000000000002|rc=0 out=KEN-2 requests=1 missing=[]
mixed refs are read in one request|ken-1 00000000-0000-4000-8000-000000000002|rc=0 out=KEN-1,KEN-2 requests=1 missing=[]
the issues print in the order named|KEN-2 KEN-1|rc=0 out=KEN-2,KEN-1 requests=1 missing=[]
an archived issue is read in one request|KEN-3 KEN-1|rc=0 out=KEN-3,KEN-1 requests=1 missing=[]
two refs naming one issue print it once|KEN-1 00000000-0000-4000-8000-000000000001|rc=0 out=KEN-1 requests=1 missing=[]
a moved issue's earlier identifier resolves|OLD-7 KEN-1|rc=0 out=KEN-4,KEN-1 requests=2 missing=[]
an unknown reference refuses the read|KEN-1 KEN-404|rc=1 out= requests=2 missing=["KEN-404"]
a rate-limited lookup fails the read without missing|RATE-1 KEN-404|rc=1 out= requests=4 missing=[]
a 503 lookup fails the read without missing|DOWN-1 KEN-404|rc=1 out= requests=4 missing=[]
not a reference refuses before any request|KEN-1 KEN2|rc=1 out= requests=0 missing=[]
ROWS

# Coding agents execute the command in a Hint line after a failed read.
# Execute the suggested bulk read to check its arguments, not its prose.
while IFS='|' read -r label extra; do
    rc=0
    out=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" \
        LINEAR_API_KEY_OVERRIDE=test-key LINEAR_RETRY_BASE_DELAY=0 "$BASH" .agents/skills/linear/scripts/linear.sh \
        issues get KEN-1 "$extra" 2>"$TMP_ROOT/get-err") || rc=$?
    assert_eq "$label: get succeeds" "$rc" 0
    hint=$(sed -n 's/^Hint: .*\(linear.sh issues bulk-get .*\)$/\1/p' "$TMP_ROOT/get-err")
    read -r -a argv <<<"$hint"
    assert_eq "$label: bulk-get accepts the hint" "$(bulk_summary "${argv[@]:3}")" \
        'rc=0 out=KEN-1 requests=1 missing=[]'
    bundle_hint=$(sed -n 's/^Hint: .*\(linear.sh issues get .*\)$/\1/p' "$TMP_ROOT/get-err")
    read -r -a argv <<<"$bundle_hint"
    assert_eq "$label: bundle command uses the supported option" "${argv[*]}" \
        'linear.sh issues get KEN-1 --with-bundle'
done <<'ROWS'
get with --bundle|--bundle
ROWS
