#!/usr/bin/env bash
# bash-runtime: 4
# Surface: comments owner-requests preserves distinct original requests.
# Inputs: skills/linear/scripts/.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
assert_tmpdir TMP_ROOT
mkdir -p "$TMP_ROOT/bin"
git -C "$TMP_ROOT" init -q
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
printf '%s\n' "$payload" >>"$CALLS"
response=$(jq -cj --arg mode "$MODE" '
def user: {id:"owner-id",name:"Owner",email:"owner@example.test",url:"https://linear.app/example/profiles/owner"};
def comment($id; $body): {id:$id,body:$body,createdAt:"2026-11-01T01:00:00Z",updatedAt:"2026-11-01T01:00:00Z",
  user:{id:"original-author",name:"Original asker",email:"asker@example.test",url:"https://linear.app/example/profiles/asker"},
  parent:{id:"original-thread"},url:("https://linear.app/example/issue/KEN-1#comment-"+$id)};
def comments: {pageInfo:{hasNextPage:false,endCursor:null},nodes:[
  comment("ask-a";"[Owner](https://linear.app/example/profiles/owner) first question"),
  comment("ask-b";"https://linear.app/example/profiles/owner second question"),
  comment("unrelated";"https://linear.app/example/profiles/owner-other is another user")]}
  | if $mode == "large-comments" then .nodes += [range(80) | comment("history-"+tostring; "retained conversation " * 150)] else . end;
if (.query | contains("GetUserByEmail")) then
  {data:{users:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[user]}}}
elif (.query | contains("TeamKeys")) then {data:{organization:{urlKey:"example",teams:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}
elif (.query | contains("ListIssues")) then
  {data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"issue-uuid",identifier:"KEN-1",url:"https://linear.app/example/issue/KEN-1",updatedAt:"2026-11-01T01:00:00Z",
    description:(if $mode == "large-items" then "retained issue history " * 9000 else "" end)}]}}}
elif (.query | contains("ContinueConnection")) then
  if .variables.id != "issue-uuid" or .variables.after != "comment-page-2" then error("unexpected continuation")
  else
    (.query | contains("user { id }")) as $author |
    (.query | contains("parent { id }")) as $parent |
    (.query | contains("} url")) as $url |
    {data:{issue:{id:"issue-uuid",comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:([
      comment("ask-b";"https://linear.app/example/profiles/owner second question"),
      (comment("posted-reply";"Owner reply evidence") | .user = user)
    ] | map(if $author then . else del(.user.id,.user.url) end |
      if $parent then . else del(.parent) end | if $url then . else del(.url) end))}}}}
  end
elif (.query | contains("comments")) then
  if $mode == "failed-comments" then {errors:[{message:"failed",extensions:{code:"INPUT_ERROR"}}]}
  else {data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"issue-uuid",identifier:"KEN-1",comments:(comments |
    if $mode == "paginated" then .pageInfo = {hasNextPage:true,endCursor:"comment-page-2"} |
      .nodes |= map(select(.id != "ask-b")) else . end)}]}}} end
else error("unexpected query") end' <<<"$payload")
printf '%s' "$response" >>"$RESPONSES"
printf '%s___HTTP_CODE___200' "$response"
STUB
chmod +x "$TMP_ROOT/bin/curl"
run_requests() {
    local presentation=()
    [[ -z "${2:-}" ]] || presentation=("LINEAR_FORMAT=$2")
    RC=0
    : >"$TMP_ROOT/calls"
    : >"$TMP_ROOT/responses"
    OUT=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" \
        LINEAR_API_KEY_OVERRIDE=test-key CALLS="$TMP_ROOT/calls" RESPONSES="$TMP_ROOT/responses" MODE="$1" \
        ${presentation[@]+"${presentation[@]}"} \
        "$BASH" "$SKILL_DIR/scripts/linear.sh" comments owner-requests --email owner@example.test --label owner-waiting \
        2>"$TMP_ROOT/err") || RC=$?
}
run_requests normal
if [[ "$RC" != 0 ]]; then cat "$TMP_ROOT/err" >&2; fi
assert_eq "complete projection succeeds" "$RC" 0
assert_jq "distinct same-issue asks and exact profile mention" "$OUT" '[.requests[].comment.id] == ["ask-a","ask-b"]'
assert_jq "original attribution, date, thread and URL" "$OUT" \
    '.workspace == "example" and all(.requests[]; .issueUuid == "issue-uuid" and .comment.user_id == "original-author" and .comment.user == "Original asker" and .comment.created_at == "2026-11-01T01:00:00Z" and .thread == "original-thread" and (.comment.url | startswith("https://linear.app/example/issue/KEN-1#comment-")))'
assert_jq "existing list filter owner receives assignment and label" "$(jq -s 'map(select(.query | contains("ListIssues")))[0]' "$TMP_ROOT/calls")" \
    '.variables.filter.assignee.email.eqIgnoreCase == "owner@example.test" and .variables.filter.labels.name.eq == "owner-waiting"'
run_requests normal raw
assert_eq "internal projection ignores raw presentation preference" "$RC" 0
assert_jq "raw preference retains safe evidence" "$OUT" \
    '[.requests[].comment.id] == ["ask-a","ask-b"] and all(.requests[]; .comment.user_id == "original-author" and .thread == "original-thread" and .comment.created_at == "2026-11-01T01:00:00Z")'
for mode in large-comments large-items; do
    run_requests "$mode"
    assert_eq "$mode complete document succeeds" "$RC" 0
    assert_jq "$mode retains every request" "$OUT" '[.requests[].comment.id] == ["ask-a","ask-b"]'
    # The answers the reader carried exceed a single process argument.
    assert_not "$mode answers fit one process argument" test "$(wc -c <"$TMP_ROOT/responses")" -le 180000
done
printf '[env]\nKENDEX_ENV_FILE="fixture-private.env"\nLINEAR_FORMAT="raw"\n' >"$TMP_ROOT/kendex.settings.toml"
printf 'LINEAR_RETRY_BASE_DELAY=0\n' >"$TMP_ROOT/fixture-private.env"
run_requests normal
assert_eq "ordinary settings and selected private file succeed" "$RC" 0
assert_jq "project raw preference retains safe evidence" "$OUT" \
    '[.requests[].comment.user_id] == ["original-author","original-author"]'
: >"$TMP_ROOT/kendex.settings.toml"
run_requests paginated
assert_eq "continued projection succeeds" "$RC" 0
assert_jq "continued author, thread and URL survive projection" "$OUT" \
    '[.requests[].comment.id] == ["ask-a","ask-b"] and
     any(.requests[]; .comment.id == "ask-b" and .comment.user_id == "original-author" and
       .thread == "original-thread" and .comment.url == "https://linear.app/example/issue/KEN-1#comment-ask-b")'
run_requests failed-comments
assert_not "an unread configured source fails" test "$RC" -eq 0
assert_eq "an unread source publishes no partial projection" "$OUT" ''
