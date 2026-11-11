#!/usr/bin/env bash
# bash-runtime: 4
# Surface: a checkbox outside `## Done when`. Authored create, update and
# bulk-update bodies refuse one, naming it; `issues complete` refuses Done and
# Verifying while a stored body holds one open, and a started in-PR bundle
# child holding one fails validate-completion. A quoted or fenced box is not
# a box. Every route reads the shared Done-when parser.
# Inputs: scripts/commands/issues.sh, scripts/lib/issue-validation.sh, this
# suite and its assertion library.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false

# Issue reads answer with the description in DESCRIPTION_FILE; an update
# answers with the description and state it was sent.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
payload="$(sed -n 's/^data = //p' <<<"$(cat)" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
description="$(jq -Rs . "${DESCRIPTION_FILE:?}")"
issue='{id:"issue-uuid",identifier:"CC-1",title:"t",description:$d,state:$s,assignee:null,project:null,projectMilestone:null,cycle:null,parent:null,team:{key:"CC",id:"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47",name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},priority:3,estimate:null,sortOrder:1.0,url:"https://linear.app/x/issue/CC-1",branchName:"cc-1",createdAt:"2026-11-11T00:00:00Z",updatedAt:"2026-11-11T00:00:00Z",archivedAt:null,trashed:null,children:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}'
started='{name:"In Review",type:"started"}'
case "$(jq -r '.query' <<<"$payload")" in
*"teams(filter:"*) printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47","key":"CC","name":"Claude"}]}}}' ;;
*"workflowStates(filter:"*)
  jq -cj '.variables.name as $n | {data:{workflowStates:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:$n,type:(if $n == "Done" then "completed" else "started" end)}]}}}' <<<"$payload" ;;
*"commentCreate(input:"*) printf '%s' '{"data":{"commentCreate":{"success":true,"comment":{"id":"c-1","body":"ok","createdAt":"2026-11-11T00:00:00Z","updatedAt":"2026-11-11T00:00:00Z","user":{"name":"Test"},"issue":{"identifier":"CC-1","updatedAt":"2026-11-11T00:00:00Z"}}}}}' ;;
*"issueCreate(input:"*) jq -cj --argjson d "$description" "($started) as \$s | {data:{issueCreate:{success:true,issue:$issue}}}" <<<'null' ;;
*"issueUpdate(id:"*) jq -cj --argjson d "$description" "(.variables.input.description // \$d) as \$d | {name:(.variables.input.stateId // \"In Review\"),type:\"started\"} as \$s | {data:{issueUpdate:{success:true,issue:$issue}}}" <<<"$payload" ;;
*"issue(id:"*) jq -cj --argjson d "$description" "($started) as \$s | {data:{issue:$issue}}" <<<'null' ;;
*) printf '%s' '{"errors":[{"message":"unexpected query"}]}' ;;
esac
printf '___HTTP_CODE___200'
SH
chmod +x "$TMP_ROOT/bin/curl"

CURL_LOG="$TMP_ROOT/requests.jsonl"
STORED="$TMP_ROOT/stored.md"
run_linear() { # ARG...
  : >"$CURL_LOG"
  RC=0
  (cd "$TMP_ROOT" && env -u LINEAR_REQUIRE_REACH -u LINEAR_AGENT_LABELS PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=CC CURL_LOG="$CURL_LOG" DESCRIPTION_FILE="$STORED" \
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues "$@") \
    >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || RC=$?
  ERR="$(cat "$TMP_ROOT/err")"
}
sent() { jq -s -e --arg op "$1" 'any(.[]; .query | contains($op))' "$CURL_LOG" >/dev/null; }

POST='Post-merge: Read health; Where: service; Why after merge: live service; Deadline: +24h'
# authored TAIL — a filing-bar body whose Done-when box is line 7 and whose
# TAIL, given with printf %b escapes, starts at line 9.
authored() {
  printf '%s\n' '> **Story:** The owner reads a post-merge check after the change merges.' '' \
    '> **Why this matters:** An unread check accepts a change with no proof.' '' \
    '## Done when' '' '- [ ] branch outcome' ''
  printf '%b\n' "$1"
  printf '%s\n' '' '**Reached by**: an item filed with its post-merge check under its own heading'
}

# The grammar table calls the shared write check; the entry-point rows below
# prove each verb reaches it. Columns: name | tail | the refused line and box
# text, or pass.
source "$TMP_ROOT/.agents/skills/linear/scripts/lib/issue-validation.sh"
while IFS='|' read -r name tail line box; do
  rc=0
  require_issue_header_shape "$(authored "$tail")" 2>"$TMP_ROOT/shape.err" || rc=$?
  if [[ "$line" == pass ]]; then
    assert_eq "write check files $name" "$rc" 0
  else
    assert_eq "write check refuses $name" "$rc" 1
    assert_jq "write check names the $name box" "$(cat "$TMP_ROOT/shape.err")" \
      ".rule == \"checkbox-outside-done-when\" and .line == $line and .box == \"$box\" and (.fix | length) > 0"
  fi
done <<ROWS
post-merge-heading|## Post-merge\n\n- [ ] $POST|11|$POST
other-heading|## Notes\n\n- [ ] follow up|11|follow up
checked|## Notes\n\n- [x] already read|11|already read
star-bullet|## Notes\n\n* [ ] follow up|11|follow up
nested|## Notes\n\n- an item\n  - [ ] nested box|12|nested box
after-fence|## Notes\n\n\`\`\`\ncode\n\`\`\`\n- [ ] after the fence|14|after the fence
quoted|## Notes\n\n> - [ ] quoted box|pass|
backtick-fence|## Notes\n\n\`\`\`md\n- [ ] fenced box\n\`\`\`|pass|
tilde-fence|## Notes\n\n~~~~\n- [ ] fenced box\n~~~\n- [ ] still fenced\n~~~~|pass|
no-box|## Notes\n\nplain text|pass|
ROWS

body="$(authored "## Post-merge\n\n- [ ] $POST")"
authored '## Notes' >"$STORED"
while IFS='|' read -r verb; do
  case "$verb" in
    create) args=(create --title t) ;;
    update) args=(update CC-1) ;;
    bulk-update) args=(bulk-update CC-1 CC-2) ;;
  esac
  run_linear "${args[@]}" --description "$body"
  assert_ne "$verb refuses a box under ## Post-merge" "$RC" 0
  assert_jq "$verb names the box under ## Post-merge" "$ERR" '.rule == "checkbox-outside-done-when" and .line == 11'
  assert_not "$verb writes nothing for a box under ## Post-merge" sent Create
  assert_not "$verb updates nothing for a box under ## Post-merge" sent issueUpdate
done <<'ROWS'
create
update
bulk-update
ROWS

# Completion of a stored body, which may predate the write check. Columns:
# name | body | completion arguments | refused open lines, or the state set.
# The parser reads each refused body with every Done-when box met and
# evidenced, so only the outside box can hold its completion state.
printf '%s\n' '1: branch read' >"$TMP_ROOT/proof.txt"
DONE='## Done when\n- [x] branch outcome\n  Evidence: branch read'
while IFS='|' read -r name stored args expected; do
  printf '%b\n' "$stored" >"$STORED"
  read -r -a extra <<<"$args"
  run_linear complete CC-1 --summary proof ${extra[@]+"${extra[@]}"}
  parsed="$(done_when_parse "$(cat "$STORED")" '"all"' 2026-11-11T00:00:00Z '{"1":"branch read"}')"
  if [[ "$expected" == \[* ]]; then
    assert_ne "complete refuses $name" "$RC" 0
    assert_jq "complete names the $name box" "$ERR" \
      ".error == \"done-when-outside\" and .issue == \"CC-1\" and ([.boxes[].line] == $expected)"
    assert_not "complete $name posts no summary" sent commentCreate
    assert_not "complete $name sets no state" sent issueUpdate
    assert_jq "parser holds $name from completion" "$parsed" '.completion_state == null'
  else
    assert_eq "complete accepts $name" "$RC" 0
    assert_jq "complete $name sets $expected" "$(jq -s '[.[] | select(.query | contains("issueUpdate"))] | last' "$CURL_LOG")" \
      ".variables.input.stateId == \"$expected\""
  fi
done <<ROWS
post-merge-heading|$DONE\n\n## Post-merge\n\n- [ ] $POST|--post-merge-at 2026-11-11T00:00:00Z|[7]
bare|$DONE\n\n## Post-merge\n\n- [ ] $POST||[7]
selected|## Done when\n- [ ] branch outcome\n\n## Notes\n- [ ] follow up\n- [x] read|--done-when-met all --evidence-file $TMP_ROOT/proof.txt|[5]
before-section|- [ ] above\n\n$DONE|--post-merge-at 2026-11-11T00:00:00Z|[1]
checked|$DONE\n\n## Notes\n- [x] read|--post-merge-at 2026-11-11T00:00:00Z|Done
ROWS

# A started in-PR bundle child passes the pre-merge check only where the
# post-merge `issues complete` would accept it.
result="$(build_completion_validation_result CC-2 "In Review" CC-1 true bundle-child started "$(printf '%b' "$DONE\n\n## Post-merge\n\n- [ ] $POST")")"
assert_jq "started bundle child post-merge-heading state_ok is false" "$result" '.state_ok == false and .ok == false'
