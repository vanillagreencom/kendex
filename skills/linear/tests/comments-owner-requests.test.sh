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
jq -cj --arg mode "$MODE" '
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
    (.query | contains("user { id url }")) as $author |
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
else error("unexpected query") end' <<<"$payload"
printf '___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"
run_requests() {
    local presentation=()
    [[ -z "${2:-}" ]] || presentation=("LINEAR_FORMAT=$2")
    RC=0
    : >"$TMP_ROOT/calls"
    OUT=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" \
        LINEAR_API_KEY_OVERRIDE=test-key CALLS="$TMP_ROOT/calls" MODE="$1" MARKER="$TMP_ROOT/executed" \
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
    assert_jq "$mode retains requests and complete evidence" "$OUT" \
        '[.requests[].comment.id] == ["ask-a","ask-b"] and (.issues[0].comments | length) >= 3'
    if [[ "$mode" == large-comments ]]; then
        assert_jq "retained conversation exceeds process argument size" "$OUT" \
            '([.issues[].comments[].body | length] | add) > 180000 and .issues[0].comments[-1].id == "history-79"'
    fi
done
mkdir -p "$TMP_ROOT/checkout-code" "$TMP_ROOT/lib" "$TMP_ROOT/.kendex"
for helper in formatters.sh attachments.sh teams.sh issues.sh launch; do
    printf '%s\n' '#!/usr/bin/env bash' 'printf executed >"$MARKER"' 'exit 91' >"$TMP_ROOT/checkout-code/$helper"
    chmod +x "$TMP_ROOT/checkout-code/$helper"
done
cp "$TMP_ROOT/checkout-code/attachments.sh" "$TMP_ROOT/lib/attachments.sh"
for settings in kendex.settings.toml .kendex/settings.toml; do
    for identity in _LIB_DIR SCRIPT_DIR BASH BASH_ENV; do
        value='./checkout-code'
        case "$identity" in BASH|BASH_ENV) value='./checkout-code/launch' ;; esac
        printf '[env]\n%s="%s"\n' "$identity" "$value" >"$TMP_ROOT/$settings"
        run_requests normal
        assert_not "public $identity replacement refuses" test "$RC" -eq 0
        assert_not "public $identity never executes checkout code" test -e "$TMP_ROOT/executed"
        # A previous failing implementation must not contaminate the next row.
        : >"$TMP_ROOT/executed"
        rm "$TMP_ROOT/executed"
    done
    printf '[env]\nKENDEX_ENV_FILE="fixture-private.env"\nLINEAR_FORMAT="raw"\n' >"$TMP_ROOT/$settings"
    printf 'LINEAR_RETRY_BASE_DELAY=0\n' >"$TMP_ROOT/fixture-private.env"
    run_requests normal
    assert_eq "ordinary settings and selected private file succeed" "$RC" 0
    assert_jq "project raw preference retains safe evidence" "$OUT" \
        '[.requests[].comment.user_id] == ["original-author","original-author"]'
    : >"$TMP_ROOT/$settings"
done
run_requests paginated
assert_eq "continued projection succeeds" "$RC" 0
assert_jq "continued author, thread and URL survive projection" "$OUT" \
    '[.requests[].comment.id] == ["ask-a","ask-b"] and
     any(.requests[]; .comment.id == "ask-b" and .comment.user_id == "original-author" and
       .comment.user_url == "https://linear.app/example/profiles/asker" and .thread == "original-thread" and
       .comment.url == "https://linear.app/example/issue/KEN-1#comment-ask-b") and
     any(.issues[].comments[]; .id == "posted-reply" and .user_id == "owner-id" and
       .user_url == "https://linear.app/example/profiles/owner" and .parent_id == "original-thread" and
       .body == "Owner reply evidence" and .url == "https://linear.app/example/issue/KEN-1#comment-posted-reply")'
run_requests failed-comments
assert_not "an unread configured source fails" test "$RC" -eq 0
assert_eq "an unread source publishes no partial projection" "$OUT" ''
