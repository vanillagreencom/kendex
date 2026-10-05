#!/usr/bin/env bash
# issues complete --done-when-met ticks the named `## Done when` boxes in the
# issueUpdate that sets Done, leaves every other box as it was, and refuses a
# box number the section does not hold before any write.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false

# The issue read answers with the description in DESCRIPTION_FILE; the update
# answers with the description it was sent, or that one when it was sent none,
# and fails when UPDATE_FAILS is set.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"
description="$(jq -Rs . "${DESCRIPTION_FILE:?}")"

case "$query" in
*"commentCreate(input:"*)
  printf '%s' '{"data":{"commentCreate":{"success":true,"comment":{"id":"comment-1","body":"ok","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:00Z","user":{"name":"Test"},"issue":{"identifier":"CC-720","updatedAt":"2026-07-14T00:00:00Z"}}}}}___HTTP_CODE___200'
  ;;
*"workflowStates(filter:"*)
  printf '%s' '{"data":{"workflowStates":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"state-done"}]}}}___HTTP_CODE___200'
  ;;
*"issue(id:"*)
  jq -cj --argjson d "$description" '{data:{issue:{id:"issue-uuid",identifier:"CC-720",title:"t",description:$d,state:{name:"In Review",type:"started"},assignee:null,project:null,projectMilestone:null,cycle:null,team:{id:"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47",name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},priority:3,estimate:null,sortOrder:1.0,url:"https://linear.app/test/issue/CC-720",branchName:"cc-720",createdAt:"2026-07-14T00:00:00Z",updatedAt:"2026-07-14T00:00:00Z",archivedAt:null,trashed:null,parent:null,children:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}' <<<'null'
  printf '___HTTP_CODE___200'
  ;;
*"issueUpdate(id:"*)
  if [ -n "${UPDATE_FAILS:-}" ]; then
    printf '%s' '{"errors":[{"message":"update refused"}]}___HTTP_CODE___200'
    exit 0
  fi
  jq -cj --argjson d "$description" '{data:{issueUpdate:{success:true,issue:{id:"issue-uuid",identifier:"CC-720",title:"t",description:(.variables.input.description // $d),state:{name:"Done",type:"completed"},assignee:null,project:null,projectMilestone:null,cycle:null,parent:null,team:{name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},priority:3,estimate:null,sortOrder:1.0,url:"https://linear.app/test/issue/CC-720",createdAt:"2026-07-14T00:00:00Z",updatedAt:"2026-07-14T00:00:01Z",archivedAt:null,trashed:null,relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}}' <<<"$payload"
  printf '___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

run_complete() { # DESCRIPTION_FILE PAYLOAD_LOG ARG...
  local description_file="$1" payload_log="$2"
  shift 2
  : >"$payload_log"
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=CC \
    CURL_PAYLOAD_LOG="$payload_log" DESCRIPTION_FILE="$description_file" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues complete "$@")
}

# The issueUpdate payloads in LOG, one compact JSON object per line.
updates() {
  jq -c 'select(.query | contains("issueUpdate"))' "$1"
}

boxes="$TMP_ROOT/boxes.md"
printf '%s\n' \
  'Problem text.' \
  '' \
  '- [ ] above the section' \
  '' \
  '## Done when' \
  '' \
  '- [ ] first' \
  '- [x] second' \
  '  - [ ] third' \
  '' \
  '## Notes' \
  '' \
  '- [ ] outside the section' >"$boxes"

# --- all: every box in the section ticks, in the update that sets Done
log="$TMP_ROOT/all.jsonl"
out="$(run_complete "$boxes" "$log" CC-720 --done-when-met all 2>"$TMP_ROOT/all.err")"
assert_jq "complete --done-when-met all counts the boxes it ticked" "$out" \
  '.success == true and .action == "completed" and .done_when_checked == 2'
update="$(updates "$log")"
assert_eq "complete --done-when-met all sends one issueUpdate" "$(wc -l <<<"$update" | tr -d ' ')" "1"
assert_jq "the Done update carries the ticked description" "$update" \
  '.variables.input.stateId == "state-done" and .variables.input.description == "Problem text.\n\n- [ ] above the section\n\n## Done when\n\n- [x] first\n- [x] second\n  - [x] third\n\n## Notes\n\n- [ ] outside the section\n"'
assert_jq "a box outside the Done-when section stays unchecked" "$update" \
  '.variables.input.description | endswith("## Notes\n\n- [ ] outside the section\n")'
assert_jq "a box above the Done-when section stays unchecked" "$update" \
  '.variables.input.description | startswith("Problem text.\n\n- [ ] above the section\n\n## Done when\n")'

# --- a list: only the named box ticks; an unnamed box stays unchecked
log="$TMP_ROOT/list.jsonl"
out="$(run_complete "$boxes" "$log" CC-720 --done-when-met 3 2>"$TMP_ROOT/list.err")"
assert_jq "complete --done-when-met 3 ticks one box" "$out" '.done_when_checked == 1'
assert_jq "an unnamed box stays unchecked" "$(updates "$log")" \
  '.variables.input.stateId == "state-done" and .variables.input.description == "Problem text.\n\n- [ ] above the section\n\n## Done when\n\n- [ ] first\n- [x] second\n  - [x] third\n\n## Notes\n\n- [ ] outside the section\n"'

# --- a failed Done update after the summary post: the retry it names keeps
# the met boxes and drops only the summary options
log="$TMP_ROOT/failed.jsonl"
rc=0
UPDATE_FAILS=1 run_complete "$boxes" "$log" CC-720 --summary "Shipped it" --done-when-met 3 \
  >"$TMP_ROOT/failed.out" 2>"$TMP_ROOT/failed.err" || rc=$?
assert_ne "a failed Done update fails the completion" "$rc" 0
assert_file_contains "the retry after a failed Done update keeps --done-when-met" "$TMP_ROOT/failed.err" \
  "Rerun 'issues.sh complete CC-720 --done-when-met 3' without summary flags"

# --- a number past the section's last box refuses before the summary post
log="$TMP_ROOT/missing.jsonl"
rc=0
run_complete "$boxes" "$log" CC-720 --summary "Shipped it" --done-when-met 2,4 \
  >"$TMP_ROOT/missing.out" 2>"$TMP_ROOT/missing.err" || rc=$?
assert_ne "a box number past the section fails the completion" "$rc" 0
assert_file_contains "the refusal names the missing box" "$TMP_ROOT/missing.err" \
  "Done-when box not found in CC-720: 4"
assert_not "a box number past the section refuses before any write" \
  jq -s -e 'any(.[]; (.query | contains("commentCreate")) or (.query | contains("issueUpdate")))' "$log"

# --- a malformed value refuses before any request
for value in 0 x 1,,2 "1, 2"; do
  log="$TMP_ROOT/malformed.jsonl"
  rc=0
  run_complete "$boxes" "$log" CC-720 --done-when-met "$value" \
    >"$TMP_ROOT/malformed.out" 2>"$TMP_ROOT/malformed.err" || rc=$?
  assert_ne "--done-when-met '$value' fails" "$rc" 0
  assert_not "--done-when-met '$value' refuses before any request" test -s "$log"
done

# --- no box to tick: Done alone, the description untouched
plain="$TMP_ROOT/plain.md"
printf '%s\n' '## Done when' '' '* a bullet with no box' >"$plain"
log="$TMP_ROOT/plain.jsonl"
out="$(run_complete "$plain" "$log" CC-720 --done-when-met all 2>"$TMP_ROOT/plain.err")"
assert_jq "a Done-when with no box completes with zero ticked" "$out" \
  '.success == true and .done_when_checked == 0'
assert_jq "a Done-when with no box sends no description" "$(updates "$log")" \
  '.variables.input.stateId == "state-done" and (.variables.input | has("description") | not)'
