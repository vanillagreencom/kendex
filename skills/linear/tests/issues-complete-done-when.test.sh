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
  state="$(jq -r '.variables.name' <<<"$payload")"
  case "$state" in
    Verifying) state_id=state-verifying ;;
    Done) state_id=state-done ;;
    Todo) state_id=state-todo ;;
    'In Progress') state_id=state-in-progress ;;
    'In Review') state_id=state-in-review ;;
    'In QA') state_id=state-in-qa ;;
    *) printf 'unsupported workflow state: %s\n' "$state" >&2; exit 2 ;;
  esac
  jq -cn --arg id "$state_id" '{data:{workflowStates:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:$id,type:(if $id == "state-done" then "completed" elif $id == "state-todo" then "unstarted" else "started" end)}]}}}'
  printf '___HTTP_CODE___200'
  ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"team-uuid","key":"CC","name":"Claude"}]}}}___HTTP_CODE___200'
  ;;
*"issue(id:"*)
  jq -cj --arg title "${CONTAINER_TITLE:-t}" --argjson children "${CONTAINER_CHILDREN:-[]}" --arg state "${CURRENT_STATE:-In Review}" --arg type "${CURRENT_TYPE:-started}" --arg parent "${CURRENT_PARENT:-}" --argjson d "$description" '{data:{issue:{id:"issue-uuid",identifier:"CC-720",title:$title,description:$d,state:(if ($children | length) > 0 and ($title | test("\\(one PR\\)"; "i") | not) then {name:"Todo",type:"unstarted"} else {name:$state,type:$type} end),assignee:null,project:null,projectMilestone:null,cycle:null,team:{id:"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47",name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},priority:3,estimate:null,sortOrder:1.0,url:"https://linear.app/test/issue/CC-720",branchName:"cc-720",createdAt:"2026-07-14T00:00:00Z",updatedAt:"2026-07-14T00:00:00Z",archivedAt:null,trashed:null,parent:(if $parent == "" then null else {id:"parent-uuid",identifier:$parent,title:"shared bundle"} end),children:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$children},relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}' <<<'null'
  printf '___HTTP_CODE___200'
  ;;
*"issueUpdate(id:"*)
  if [ -n "${UPDATE_FAILS:-}" ]; then
    printf '%s' '{"errors":[{"message":"update refused"}]}___HTTP_CODE___200'
    exit 0
  fi
  jq -cj --argjson prior_state '{"name":"In Review","type":"started"}' --argjson d "$description" '{data:{issueUpdate:{success:true,issue:{id:"issue-uuid",identifier:"CC-720",title:"t",description:(.variables.input.description // $d),state:(if .variables.input.stateId == "state-verifying" then {name:"Verifying",type:"started"} elif .variables.input.stateId == "state-done" then {name:"Done",type:"completed"} elif .variables.input.stateId == "state-todo" then {name:"Todo",type:"unstarted"} elif .variables.input.stateId == "state-in-review" then {name:"In Review",type:"started"} elif .variables.input.stateId == "state-in-progress" then {name:"In Progress",type:"started"} elif .variables.input.stateId == "state-in-qa" then {name:"In QA",type:"started"} elif .variables.input.stateId == null then $prior_state else error("unsupported state id") end),assignee:null,project:null,projectMilestone:null,cycle:null,parent:null,team:{name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},priority:3,estimate:null,sortOrder:1.0,url:"https://linear.app/test/issue/CC-720",createdAt:"2026-07-14T00:00:00Z",updatedAt:"2026-07-14T00:00:00Z",archivedAt:null,trashed:null,relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}}' <<<"$payload"
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
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues complete "$@")
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
  '  Evidence: existing proof' \
  '  - [ ] third' \
  '' \
  '## Notes' \
  '' \
  '- [ ] outside the section' >"$boxes"

proof="$TMP_ROOT/evidence.txt"
printf '%s\n' '1: first source read' '2: second source read' '3: third source read' >"$proof"

# Bare completion must read every box before either summary or state write.
# The final column names the field that must carry the refusal box number.
while IFS='|' read -r name description expected field; do
  printf '%b' "$description" >"$TMP_ROOT/bare.md"
  log="$TMP_ROOT/bare-$name.jsonl"
  rc=0
  out="$(run_complete "$TMP_ROOT/bare.md" "$log" CC-720 2>"$TMP_ROOT/bare.err")" || rc=$?
  if [[ "$expected" == refuse ]]; then
    assert_ne "bare $name refuses" "$rc" 0
    assert_jq "bare $name names its box" "$(cat "$TMP_ROOT/bare.err")" ".error == \"post-merge-checklist\" and .$field == [1]"
    assert_not "bare $name leaves the state unchanged" jq -se 'any(.[]; .query | contains("issueUpdate"))' "$log"
  else
    assert_eq "bare $name completes" "$rc" 0
    assert_jq "bare $name sets its checklist state" "$(updates "$log")" ".variables.input.stateId == \"$expected\""
  fi
done <<'ROWS'
branch|## Done when\n- [ ] shared outcome|refuse|unmet_branch_boxes
missing-proof|## Done when\n- [x] shared outcome|refuse|missing_evidence_boxes
blank-proof|## Done when\n- [x] shared outcome\n  Evidence:   |refuse|missing_evidence_boxes
unindented-proof|## Done when\n- [x] shared outcome\nEvidence: read|refuse|missing_evidence_boxes
not-direct-proof|## Done when\n- [x] shared outcome\n\n  Evidence: read|refuse|missing_evidence_boxes
complete|## Done when\n- [x] shared outcome\n  Evidence: source read passed|state-done|-
post|## Done when\n- [x] branch proof\n  Evidence: branch read\n- [ ] Post-merge: Read health; Where: service; Why after merge: live service; Deadline: 2026-10-04T00:00:00Z|state-in-review|-
absent|No checklist.|state-done|-
ROWS

# Old containers need an outcome; ordinary no-checklist completion above stays
# supported. The title marker makes a parent with children a single-PR bundle.
while IFS='|' read -r name title description expected; do
  printf '%b' "$description" >"$TMP_ROOT/container.md"
  log="$TMP_ROOT/container-$name.jsonl"
  rc=0
  CONTAINER_TITLE="$title" CONTAINER_CHILDREN='[{"id":"child-uuid","identifier":"CC-721","title":"child","state":{"name":"Done"}}]' \
    run_complete "$TMP_ROOT/container.md" "$log" CC-720 >"$TMP_ROOT/container.out" 2>"$TMP_ROOT/container.err" || rc=$?
  if [[ "$expected" == refuse ]]; then
    assert_ne "container $name refuses" "$rc" 0
    assert_jq "container $name names the missing outcome" "$(cat "$TMP_ROOT/container.err")" '.error == "post-merge-checklist" and .missing_outcome_box == true and (.remedy | type) == "string"'
    assert_not "container $name stays open" jq -se 'any(.[]; .query | contains("issueUpdate"))' "$log"
  else
    assert_eq "container $name completes" "$rc" 0
    assert_jq "container $name requests its checklist state" "$(updates "$log")" ".variables.input.stateId == \"$expected\""
  fi
done <<'ROWS'
absent|t|No checklist.|refuse
empty|t|## Done when|refuse
post-only|t|## Done when\n- [x] Post-merge: Read health; Where: service; Why after merge: live service; Deadline: 2026-10-04T00:00:00Z\n  Evidence: source read|refuse
proved|t|## Done when\n- [x] shared outcome\n  Evidence: source read passed|state-done
single-pr-absent|Bundle (one PR)|No checklist.|state-done
single-pr-post|Bundle (one PR)|## Done when\n- [ ] Post-merge: Read health; Where: service; Why after merge: live service; Deadline: 2026-10-04T00:00:00Z|state-in-review
ROWS

log="$TMP_ROOT/all.jsonl"
out="$(run_complete "$boxes" "$log" CC-720 --done-when-met all --evidence-file "$proof" 2>"$TMP_ROOT/all.err")" || true
assert_jq "all counts newly ticked boxes" "$out" '.done_when_checked == 2'
update="$(updates "$log")"
assert_jq "the Done update carries the ticked description" "$update" '.variables.input.stateId == "state-done" and (.variables.input.description | contains("- [x] first\n  Evidence: first source read\n- [x] second\n  Evidence: second source read\n  - [x] third\n    Evidence: third source read"))'
assert_jq "a box above the Done-when section stays unchecked" "$update" '.variables.input.description | startswith("Problem text.\n\n- [ ] above the section")'
assert_jq "a box outside the Done-when section stays unchecked" "$update" '.variables.input.description | endswith("## Notes\n\n- [ ] outside the section\n")'

# Selecting only one branch box does not authorize the remaining branch box.
log="$TMP_ROOT/list.jsonl"
rc=0
run_complete "$boxes" "$log" CC-720 --done-when-met 3 --evidence-file "$proof" --summary proof >"$TMP_ROOT/list.out" 2>"$TMP_ROOT/list.err" || rc=$?
assert_ne "an unnamed open branch box refuses" "$rc" 0
assert_jq "the unnamed branch box is identified" "$(cat "$TMP_ROOT/list.err")" '.unmet_branch_boxes == [1]'
assert_not "open branch refuses before summary or update" jq -se 'any(.[]; (.query | contains("commentCreate")) or (.query | contains("issueUpdate")))' "$log"

# Older checked items acquire evidence from their holder's existing read.
printf '%s\n' '## Done when' '- [x] outcome' '  Evidence: ' >"$TMP_ROOT/legacy.md"
log="$TMP_ROOT/legacy.jsonl"
out="$(run_complete "$TMP_ROOT/legacy.md" "$log" CC-720 --done-when-met 1 --evidence-file "$proof" 2>"$TMP_ROOT/legacy.err")" || true
assert_jq "legacy evidence repair adds no new tick" "$out" '.done_when_checked == 0'
assert_jq "legacy evidence repair replaces the empty line in the state update" "$(updates "$log")" '.variables.input.stateId == "state-done" and .variables.input.description == "## Done when\n- [x] outcome\n  Evidence: first source read\n"'

# File input is the producer of each new tick's evidence.
while IFS='|' read -r name content field; do
  printf '%b' "$content" >"$TMP_ROOT/bad-evidence.txt"
  log="$TMP_ROOT/evidence-$name.jsonl"
  rc=0
  run_complete "$boxes" "$log" CC-720 --done-when-met all --evidence-file "$TMP_ROOT/bad-evidence.txt" --summary proof >"$TMP_ROOT/evidence.out" 2>"$TMP_ROOT/evidence.err" || rc=$?
  assert_ne "evidence file $name refuses" "$rc" 0
  assert_jq "evidence file $name reports its category" "$(cat "$TMP_ROOT/evidence.err")" "$field"
  assert_not "evidence file $name refuses before writes" jq -se 'any(.[]; (.query | contains("commentCreate")) or (.query | contains("issueUpdate")))' "$log"
done <<'ROWS'
missing|1: source read|.missing_evidence_boxes == [3]
empty||.missing_evidence_boxes == [1,3]
blank|1:   |.error == "done-when-evidence-file"
duplicate|1: source read\n1: another read|.error == "done-when-evidence-file"
malformed|source read|.error == "done-when-evidence-file"
ROWS

log="$TMP_ROOT/failed.jsonl"
rc=0
UPDATE_FAILS=1 run_complete "$boxes" "$log" CC-720 --summary proof --done-when-met all --evidence-file "$proof" >"$TMP_ROOT/failed.out" 2>"$TMP_ROOT/failed.err" || rc=$?
assert_ne "a failed state update fails completion" "$rc" 0
assert_jq "a failed update followed the summary" "$(jq -s . "$log")" '[.[] | select(.query | contains("commentCreate"))] | length == 1'

log="$TMP_ROOT/missing.jsonl"
rc=0
run_complete "$boxes" "$log" CC-720 --summary proof --done-when-met 2,4 --evidence-file "$proof" >"$TMP_ROOT/missing.out" 2>"$TMP_ROOT/missing.err" || rc=$?
assert_ne "an absent box refuses" "$rc" 0
assert_jq "an absent box identifies its number" "$(cat "$TMP_ROOT/missing.err")" '.missing == [4]'
assert_not "an absent box refuses before any write" jq -se 'any(.[]; (.query | contains("commentCreate")) or (.query | contains("issueUpdate")))' "$log"

for value in 0 x 1,,2 "1, 2"; do
  log="$TMP_ROOT/malformed.jsonl"
  rc=0
  run_complete "$boxes" "$log" CC-720 --done-when-met "$value" >"$TMP_ROOT/malformed.out" 2>"$TMP_ROOT/malformed.err" || rc=$?
  assert_ne "malformed box list refuses" "$rc" 0
  assert_not "malformed box list refuses before any request" test -s "$log"
done

# A section without checkboxes keeps ordinary completion behavior.
plain="$TMP_ROOT/plain.md"
printf '%s\n' '## Done when' '' '* a bullet with no box' >"$plain"
log="$TMP_ROOT/plain.jsonl"
out="$(run_complete "$plain" "$log" CC-720 --done-when-met all --evidence-file "$proof" 2>"$TMP_ROOT/plain.err")" || true
assert_jq "an empty checklist has no new tick" "$out" '.done_when_checked == 0'
assert_jq "an empty checklist sends no description" "$(updates "$log")" '.variables.input | has("description") | not'

merged=2026-10-01T00:00:00Z
post='Post-merge: Read deployment health; Where: live service health; Why after merge: the service runs the merged release; Deadline: 2026-10-04T00:00:00Z'
verification="$TMP_ROOT/verification.md"
printf '%s\n' '## Done when' '- [ ] branch proof' "- [ ] $post" >"$verification"
for row in '1|state-verifying' 'all|state-done'; do
  IFS='|' read -r met expected <<<"$row"
  log="$TMP_ROOT/verification-$met.jsonl"
  out="$(run_complete "$verification" "$log" CC-720 --post-merge-at "$merged" --done-when-met "$met" --evidence-file "$proof" 2>"$TMP_ROOT/verification.err")"
  assert_jq "post-merge $met selects its state" "$(updates "$log")" ".variables.input.stateId == \"$expected\""
done
log="$TMP_ROOT/ordinary.jsonl"
out="$(run_complete "$verification" "$log" CC-720 --done-when-met 1 --evidence-file "$proof" 2>"$TMP_ROOT/ordinary.err")" || true
assert_jq "without merge flags an open post-merge box keeps its started state" "$(updates "$log")" '.variables.input.stateId == "state-in-review"'

# dev-implement writes branch proof before the shared PR merge. merge-pr
# supplies the parent's mergedAt, including after integration set the child Done.
while IFS='|' read -r name current type phase target; do
  log="$TMP_ROOT/phase-$name.jsonl"
  phase_args=()
  [[ "$phase" != merged ]] || phase_args+=(--post-merge-at "$merged")
  rc=0
  CURRENT_STATE="$current" CURRENT_TYPE="$type" CURRENT_PARENT=CC-700 \
    run_complete "$verification" "$log" CC-720 --done-when-met 1 --evidence-file "$proof" "${phase_args[@]}" >"$TMP_ROOT/phase.out" 2>"$TMP_ROOT/phase.err" || rc=$?
  if [[ "$target" == refuse ]]; then
    assert_ne "phase $name refuses" "$rc" 0
    assert_jq "phase $name names the missing phase" "$(cat "$TMP_ROOT/phase.err")" '.error == "completion-phase" and .id == "CC-720"'
    assert_not "phase $name writes nothing" jq -se 'any(.[]; .query | contains("issueUpdate"))' "$log"
  else
    assert_eq "phase $name completes" "$rc" 0
    assert_jq "phase $name selects its state" "$(updates "$log")" ".variables.input.stateId == \"$target\""
    assert_jq "phase $name records branch proof and leaves live proof open" "$(updates "$log")" '.variables.input.description | contains("- [x] branch proof\n  Evidence: first source read\n- [ ] Post-merge:")'
  fi
done <<'ROWS'
premerge-progress|In Progress|started|before|state-in-progress
premerge-review|In Review|started|before|state-in-review
premerge-custom|In QA|started|before|state-in-qa
postmerge-child|In Progress|started|merged|state-verifying
postmerge-integration-done|Done|completed|merged|state-verifying
unproved-done|Done|completed|before|refuse
unstarted|Todo|unstarted|before|refuse
ROWS
# CRLF is normalized before both numbering and deadline parsing.
crlf="$TMP_ROOT/crlf.md"
sed 's/$/\r/' "$verification" >"$crlf"
log="$TMP_ROOT/crlf.jsonl"
rc=0
out="$(run_complete "$crlf" "$log" CC-720 --post-merge-at "$merged" --done-when-met 1 --evidence-file "$proof" 2>"$TMP_ROOT/crlf.err")" || rc=$?
assert_eq "CRLF post-merge checklist is accepted" "$rc" 0
assert_jq "CRLF checklist remains Verifying" "$(updates "$log")" '.variables.input.stateId == "state-verifying" and (.variables.input.description | contains("\r") | not)'

# Completion consumes the shared parser for every trigger form.
source "$SKILL_DIR/scripts/lib/issue-validation.sh"
parsed="$(done_when_parse "## Done when"$'\n'"- [ ] $post" '[]' "$merged")"
assert_jq "a missing Trigger parses as merge" "$parsed" '.boxes[0].trigger == "merge" and .boxes[0].trigger_kind == "merge"'
parsed="$(done_when_parse "## Done when"$'\n'"- [ ] ${post/merged release/merged release; live evidence}" '[]' "$merged")"
assert_jq "a semicolon in Why preserves the legacy form" "$parsed" '(.errors | length) == 0 and .boxes[0].trigger == "merge"'

while IFS='|' read -r name trigger deadline; do
  printf '%s\n' '## Done when' '- [x] branch proof' '  Evidence: branch source read' "- [ ] Post-merge: Read health; Where: service; Why after merge: live release; Trigger: $trigger; Deadline: $deadline" >"$TMP_ROOT/trigger.md"
  log="$TMP_ROOT/trigger-$name.jsonl"
  rc=0
  run_complete "$TMP_ROOT/trigger.md" "$log" CC-720 --post-merge-at "$merged" >"$TMP_ROOT/trigger.out" 2>"$TMP_ROOT/trigger.err" || rc=$?
  assert_eq "post-merge $name trigger completes successfully" "$rc" 0
  assert_jq "post-merge $name trigger keeps Verifying" "$(updates "$log")" '.variables.input.stateId == "state-verifying"'
done <<'ROWS'
merge|merge|2026-10-04T00:00:00Z
time|2026-10-05T00:00:00Z|2026-10-08T00:00:00Z
release|release owner/repo v*|+72h
ROWS

# The validator and watch consume these normalized fields from one parser.
while IFS='|' read -r stored repo glob; do
  parsed="$(done_when_parse "## Done when"$'\n'"- [ ] Post-merge: Read health; Where: service; Why after merge: live release; Trigger: release $stored; Deadline: +24h" '[]' "$merged")"
  assert_jq "release $stored normalizes before classification" "$parsed" \
    "(.errors | length) == 0 and .boxes[0].trigger_kind == \"release\" and .boxes[0].release_repo == \"$repo\" and .boxes[0].release_glob == \"$glob\" and .boxes[0].trigger == \"release $repo $glob\""
done <<'ROWS'
owner/repo v*|owner/repo|v*
owner/repo v1.\*|owner/repo|v1.*
owner/repo v\[12\]\*|owner/repo|v[12]*
owner/repo\_name v\~\*|owner/repo_name|v~*
ROWS

# Independent refusals must precede both the summary and the state mutation.
# Columns: name | description's post-merge body | branch box checked | rule.
while IFS='|' read -r name body branch rule; do
  printf '%s\n' '## Done when' "- [$branch] branch proof" '  Evidence: branch source read' "- [ ] $body" >"$TMP_ROOT/invalid.md"
  log="$TMP_ROOT/invalid-$name.jsonl"
  rc=0
  run_complete "$TMP_ROOT/invalid.md" "$log" CC-720 --post-merge-at "$merged" --summary proof \
    >"$TMP_ROOT/invalid.out" 2>"$TMP_ROOT/invalid.err" || rc=$?
  assert_ne "post-merge refuses $name" "$rc" 0
  assert_not "post-merge $name refuses before any write" jq -se 'any(.[]; (.query | contains("commentCreate")) or (.query | contains("issueUpdate")))' "$log"
  assert_jq "post-merge $name identifies its rule" "$(cat "$TMP_ROOT/invalid.err")" "$rule"
done <<'ROWS'
branch|Post-merge: Read health; Where: service; Why after merge: live release; Deadline: 2026-10-02T00:00:00Z| |.error == "post-merge-checklist" and .unmet_branch_boxes == [1]
fields|Post-merge: Read health; Deadline: 2026-10-02T00:00:00Z|x|.errors[0].rule == "post-merge-fields"
reading-empty|Post-merge:  ; Where: service; Why after merge: live release; Deadline: 2026-10-02T00:00:00Z|x|.errors[0].rule == "post-merge-fields"
late|Post-merge: Read health; Where: service; Why after merge: live release; Deadline: 2026-10-04T00:00:01Z|x|.errors[0].rule == "post-merge-window"
early|Post-merge: Read health; Where: service; Why after merge: live release; Deadline: 2026-10-01T00:00:00Z|x|.errors[0].rule == "post-merge-window"
date|Post-merge: Read health; Where: service; Why after merge: live release; Deadline: 2026-09-31T12:00:00Z|x|.errors[0].rule == "post-merge-fields"
trigger|Post-merge: Read health; Where: service; Why after merge: live release; Trigger: someday; Deadline: 2026-10-02T00:00:00Z|x|.errors[0].rule == "post-merge-fields"
trigger-empty|Post-merge: Read health; Where: service; Why after merge: live release; Trigger: ; Deadline: 2026-10-02T00:00:00Z|x|.errors[0].rule == "post-merge-fields"
trigger-before-merge|Post-merge: Read health; Where: service; Why after merge: live release; Trigger: 2026-09-30T00:00:00Z; Deadline: 2026-10-02T00:00:00Z|x|.errors[0].rule == "post-merge-window"
time-early|Post-merge: Read health; Where: service; Why after merge: live release; Trigger: 2026-10-05T00:00:00Z; Deadline: 2026-10-05T00:00:00Z|x|.errors[0].rule == "post-merge-window"
time-late|Post-merge: Read health; Where: service; Why after merge: live release; Trigger: 2026-10-05T00:00:00Z; Deadline: 2026-10-08T00:00:01Z|x|.errors[0].rule == "post-merge-window"
release-late|Post-merge: Read health; Where: service; Why after merge: live release; Trigger: release owner/repo v*; Deadline: +73h|x|.errors[0].rule == "post-merge-window"
release-early|Post-merge: Read health; Where: service; Why after merge: live release; Trigger: release owner/repo v*; Deadline: +0h|x|.errors[0].rule == "post-merge-window"
release-deadline|Post-merge: Read health; Where: service; Why after merge: live release; Trigger: release owner/repo v*; Deadline: 2026-10-02T00:00:00Z|x|.errors[0].rule == "post-merge-fields"
ROWS
# An invalid merge timestamp refuses before any API request.
log="$TMP_ROOT/merge-timestamp.jsonl"
rc=0
run_complete "$verification" "$log" CC-720 --post-merge-at invalid >"$TMP_ROOT/stamp.out" 2>"$TMP_ROOT/stamp.err" || rc=$?
assert_ne "invalid merge timestamp refuses" "$rc" 0
assert_not "invalid merge timestamp refuses before any request" test -s "$log"
