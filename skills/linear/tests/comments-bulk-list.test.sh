#!/usr/bin/env bash
# `comments bulk-list` reads the comments of several issues in one request
# and prints one object keyed by identifier, the identifier as named: a moved
# issue's earlier identifier keys the comments of the issue it now names. An
# identifier Linear returns no issue for refuses the whole read with a
# `missing` list, and an argument not
# shaped TEAM-123, a UUID included, refuses before any request, so neither
# reads as an issue with no comments.
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
# Linear answers every requested identifier but KEN-404, OLD-7 and OLD-8 with
# one issue; KEN-1 carries one comment, the rest none. A lookup of one issue by
# id finds KEN-1 under its earlier identifier OLD-7 and KEN-8 under OLD-8, and
# no other issue. KEN-8's comments run past one page: its lookup answers the
# first with the connection open, and a continuation after cursor c8 the second.
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
printf '%s\n' "$payload" >>"$CALLS"
jq -cj '
def comment($id; $body): {id: $id, body: $body, createdAt: "2026-10-01T00:00:00.000Z",
    updatedAt: "2026-10-01T00:00:00.000Z", user: {name: "Fixture Person"}};
def issue($id): {id: ("uuid-" + $id), identifier: $id,
    comments: (if $id == "KEN-8" then {pageInfo: {hasNextPage: true, endCursor: "c8"}, nodes: [comment("c8a"; "first page")]}
      else {pageInfo: {hasNextPage: false, endCursor: null},
        nodes: (if $id == "KEN-1" then [comment("c1"; "## Completion Summary")] else [] end)} end)};
if (.query | test("ContinueConnection")) then
    if .variables.id == "uuid-KEN-8" and .variables.after == "c8" then {data: {issue: {id: "uuid-KEN-8",
        comments: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [comment("c8b"; "second page")]}}}}
    else {errors: [{message: "Entity not found: Issue", extensions: {code: "INPUT_ERROR"}}], data: null} end
elif (.query | test("issue[(]id:")) then
    if .variables.id == "OLD-7" then {data: {issue: issue("KEN-1")}}
    elif .variables.id == "OLD-8" then {data: {issue: issue("KEN-8")}}
    else {errors: [{message: "Entity not found: Issue", extensions: {code: "INPUT_ERROR"}}], data: null} end
else {data: {issues: {pageInfo: {hasNextPage: false, endCursor: null},
    nodes: [.variables.filter.id.in[] | select(. != "KEN-404" and . != "OLD-7" and . != "OLD-8") | issue(.)]}}} end' <<<"$payload"
printf '___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"

run_bulk() {
    : >"$TMP_ROOT/calls"
    RC=0
    OUT=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" \
        LINEAR_API_KEY_OVERRIDE=test-key bash .agents/skills/linear/scripts/linear.sh comments bulk-list "$@" \
        2>"$TMP_ROOT/err") || RC=$?
}

run_bulk KEN-1 ken-2
assert_eq "two issues: succeeds" "$RC" 0
assert_jq "two issues: one key per issue, in identifier case" "$OUT" 'keys == ["KEN-1", "KEN-2"]'
assert_jq "two issues: each key holds that issue's comments" "$OUT" \
    '(.["KEN-1"] | length == 1 and .[0].body == "## Completion Summary") and .["KEN-2"] == []'
assert_eq "two issues: one request" "$(wc -l <"$TMP_ROOT/calls" | tr -d ' ')" 1
assert_jq "two issues: the request names both identifiers" "$(cat "$TMP_ROOT/calls")" \
    '.variables.filter.id.in == ["KEN-1", "KEN-2"]'

run_bulk KEN-1 --format=raw
assert_jq "raw: comments keep Linear's fields" "$OUT" '.["KEN-1"][0].user.name == "Fixture Person"'

run_bulk OLD-7
assert_eq "a moved issue's earlier identifier: succeeds" "$RC" 0
assert_jq "a moved issue's earlier identifier keys the comments of the issue it names" "$OUT" \
    'keys == ["OLD-7"] and (.["OLD-7"] | length == 1 and .[0].body == "## Completion Summary")'
assert_eq "a moved issue's earlier identifier: two requests" "$(wc -l <"$TMP_ROOT/calls" | tr -d ' ')" 2

run_bulk OLD-8
assert_eq "a moved issue's comments past one page: succeeds" "$RC" 0
assert_jq "a moved issue's comments past one page are read to the end" "$OUT" \
    '[.["OLD-8"][].body] == ["first page", "second page"]'
assert_eq "a moved issue's comments past one page: three requests" "$(wc -l <"$TMP_ROOT/calls" | tr -d ' ')" 3

run_bulk KEN-1 KEN-404
assert_eq "missing: refuses" "$RC" 1
assert_eq "missing: prints nothing" "$OUT" ''
assert_jq "missing: names the identifier" "$(cat "$TMP_ROOT/err")" '.missing == ["KEN-404"]'

run_bulk KEN-1 KEN2
assert_eq "not an identifier: refuses" "$RC" 1
assert_not "not an identifier: refuses before any request" test -s "$TMP_ROOT/calls"

run_bulk KEN-1 00000000-0000-4000-8000-000000000001
assert_eq "a UUID: refuses" "$RC" 1
assert_not "a UUID: refuses before any request" test -s "$TMP_ROOT/calls"

run_bulk KEN-1 "KEN-2
"
assert_eq "a line break: refuses" "$RC" 1
assert_not "a line break: refuses before any request" test -s "$TMP_ROOT/calls"

run_bulk
assert_eq "no identifiers: refuses" "$RC" 1
