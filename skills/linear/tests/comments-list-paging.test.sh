#!/usr/bin/env bash
# bash-runtime: 4
# `comments list` answers every comment of the issue, in order, when the
# issue's comments run past one page: Linear answers the first page with the
# connection open and a continuation after its cursor the second, and both
# formats merge the pages before they render. A reader of the list, orch's
# acceptance among them, would otherwise take a summary on the second page
# for absent and post a second one.
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
# KEN-8's comments run past one page: the list answers the first with the
# connection open at cursor c8, and the continuation after c8 the second, on
# which the newest `## Completion Summary` sits. KEN-1's fit one page.
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
printf '%s\n' "$payload" >>"$CALLS"
jq -cj '
def comment($id; $body; $at): {id: $id, body: $body, createdAt: $at, updatedAt: $at,
    user: {name: "Fixture Person", email: "owner@example.com"}};
if (.query | test("ContinueConnection")) then
    if .variables.id == "uuid-KEN-8" and .variables.after == "c8" then {data: {issue: {id: "uuid-KEN-8",
        comments: {pageInfo: {hasNextPage: false, endCursor: null},
          nodes: [comment("c8c"; "## Completion Summary\n\nround two"; "2026-10-03T00:00:00.000Z"),
                  comment("c8d"; "fourth"; "2026-10-04T00:00:00.000Z")]}}}}
    else {errors: [{message: "Entity not found: Issue", extensions: {code: "INPUT_ERROR"}}], data: null} end
elif .variables.issueId == "KEN-8" then {data: {issue: {id: "uuid-KEN-8",
    comments: {pageInfo: {hasNextPage: true, endCursor: "c8"},
      nodes: [comment("c8a"; "## Completion Summary\n\nround one"; "2026-10-01T00:00:00.000Z"),
              comment("c8b"; "second"; "2026-10-02T00:00:00.000Z")]}}}}
elif .variables.issueId == "KEN-1" then {data: {issue: {id: "uuid-KEN-1",
    comments: {pageInfo: {hasNextPage: false, endCursor: null},
      nodes: [comment("c1"; "only"; "2026-10-01T00:00:00.000Z")]}}}}
else {errors: [{message: "Entity not found: Issue", extensions: {code: "INPUT_ERROR"}}], data: null} end' <<<"$payload"
printf '___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"

run_list() {
    : >"$TMP_ROOT/calls"
    RC=0
    OUT=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" \
        LINEAR_API_KEY_OVERRIDE=test-key bash .agents/skills/linear/scripts/linear.sh comments list "$@" \
        2>"$TMP_ROOT/err") || RC=$?
}

run_list KEN-8
assert_eq "two pages: succeeds" "$RC" 0
assert_jq "two pages: every comment, in order" "$OUT" '[.[].id] == ["c8a", "c8b", "c8c", "c8d"]'
assert_jq "two pages: the second page's summary is read" "$OUT" \
    '[.[] | select(.body | startswith("## Completion Summary")) | .id] == ["c8a", "c8c"]'
assert_jq "two pages: the safe shape on every page" "$OUT" 'all(.[]; .user_email == "owner@example.com" and (.created_at | length > 0))'
assert_eq "two pages: two requests" "$(wc -l <"$TMP_ROOT/calls" | tr -d ' ')" 2
assert_jq "two pages: the continuation asks after the first page's cursor" "$(tail -1 "$TMP_ROOT/calls")" \
    '.variables.id == "uuid-KEN-8" and .variables.after == "c8" and (.query | contains("user { name email }"))'

run_list KEN-8 --format=raw
assert_eq "two pages, raw: succeeds" "$RC" 0
assert_jq "two pages, raw: every node, in order, with no pageInfo" "$OUT" \
    '[.issue.comments.nodes[].id] == ["c8a", "c8b", "c8c", "c8d"] and (.issue.comments | has("pageInfo") | not)'

run_list KEN-1
assert_eq "one page: succeeds" "$RC" 0
assert_jq "one page: the comment" "$OUT" '[.[].id] == ["c1"]'
assert_eq "one page: one request" "$(wc -l <"$TMP_ROOT/calls" | tr -d ' ')" 1
