#!/usr/bin/env bash
# bash-runtime: 4
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
  # Any other id resolves to the source, as Linear resolves a moved issue's
  # historical identifier. A superseded item reads canceled, or not at all
  # under SUPERSEDED_READ_FAILS.
  read_id="$(jq -r '.variables.id' <<<"$payload")"
  uuid=issue-uuid identifier=CC-720 state="${CURRENT_STATE:-In Review}" type="${CURRENT_TYPE:-started}" archived=null trashed=null
  if [ "$read_id" = "${REPLACEMENT_ID:-}" ]; then
    uuid=replacement-uuid identifier="$REPLACEMENT_ID" state=replacement type="${REPLACEMENT_TYPE:?}" description="$(jq -Rs . "${REPLACEMENT_FILE:?}")"
    archived="${REPLACEMENT_ARCHIVED_AT:-null}" trashed="${REPLACEMENT_TRASHED:-null}"
  elif [ "$read_id" = "${SUPERSEDED_ID:-}" ]; then
    if [ -n "${SUPERSEDED_READ_FAILS:-}" ]; then
      printf '%s' '{"data":{"issue":null}}___HTTP_CODE___200'
      exit 0
    fi
    uuid=superseded-uuid identifier="$SUPERSEDED_ID" state=Canceled type=canceled
  fi
  jq -cj --arg uuid "$uuid" --argjson archived "$archived" --argjson trashed "$trashed" --arg identifier "$identifier" --arg title "${CONTAINER_TITLE:-t}" --argjson children "${CONTAINER_CHILDREN:-[]}" --arg state "$state" --arg type "$type" --arg parent "${CURRENT_PARENT:-}" --argjson d "$description" '{data:{issue:{id:$uuid,identifier:$identifier,title:$title,description:$d,state:(if ($children | length) > 0 and ($title | test("\\(one PR\\)"; "i") | not) then {name:"Todo",type:"unstarted"} else {name:$state,type:$type} end),assignee:null,project:null,projectMilestone:null,cycle:null,team:{key:"CC",id:"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47",name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},priority:3,estimate:null,sortOrder:1.0,url:"https://linear.app/test/issue/CC-720",branchName:"cc-720",createdAt:"2026-07-14T00:00:00Z",updatedAt:"2026-07-14T00:00:00Z",archivedAt:$archived,trashed:$trashed,parent:(if $parent == "" then null else {id:"parent-uuid",identifier:$parent,title:"shared bundle"} end),children:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$children},relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}' <<<'null'
  printf '___HTTP_CODE___200'
  ;;
*"issueUpdate(id:"*)
  if [ -n "${UPDATE_FAILS:-}" ]; then
    printf '%s' '{"errors":[{"message":"update refused"}]}___HTTP_CODE___200'
    exit 0
  fi
  jq -cj --argjson prior_state '{"name":"In Review","type":"started"}' --argjson d "$description" '{data:{issueUpdate:{success:true,issue:{id:"issue-uuid",identifier:"CC-720",title:"t",description:(.variables.input.description // $d),state:(if .variables.input.stateId == "state-verifying" then {name:"Verifying",type:"started"} elif .variables.input.stateId == "state-done" then {name:"Done",type:"completed"} elif .variables.input.stateId == "state-todo" then {name:"Todo",type:"unstarted"} elif .variables.input.stateId == "state-in-review" then {name:"In Review",type:"started"} elif .variables.input.stateId == "state-in-progress" then {name:"In Progress",type:"started"} elif .variables.input.stateId == "state-in-qa" then {name:"In QA",type:"started"} elif .variables.input.stateId == null then $prior_state else error("unsupported state id") end),assignee:null,project:null,projectMilestone:null,cycle:null,parent:null,team:{key:"CC",name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},priority:3,estimate:null,sortOrder:1.0,url:"https://linear.app/test/issue/CC-720",createdAt:"2026-07-14T00:00:00Z",updatedAt:"2026-07-14T00:00:00Z",archivedAt:null,trashed:null,relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}}' <<<"$payload"
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
  '- [x] above the section' \
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
  '- [x] outside the section' >"$boxes"

proof="$TMP_ROOT/evidence.txt"
printf '%s\n' '1: first source read' '2: second source read' '3: third source read' >"$proof"

# Reported Linear callers select boxes under level-three or hyphenated
# headings. Explicit selections must never turn an unrecognized checklist
# into permission to complete, even when there is no checklist at all.
while IFS='|' read -r name description; do
  printf '%b' "$description" >"$TMP_ROOT/selection.md"
  for met in all 1; do
    log="$TMP_ROOT/selection-$name-$met.jsonl"
    rc=0
    run_complete "$TMP_ROOT/selection.md" "$log" CC-720 --done-when-met "$met" --evidence-file "$proof" --summary proof \
      >"$TMP_ROOT/selection.out" 2>"$TMP_ROOT/selection.err" || rc=$?
    assert_ne "selection $name/$met refuses" "$rc" 0
    assert_jq "selection $name/$met reports missing checklist" "$(<"$TMP_ROOT/selection.err")" '.error == "done-when-checklist-missing" and .issue == "CC-720"'
    assert_not "selection $name/$met writes nothing" jq -se 'any(.[]; (.query | contains("commentCreate")) or (.query | contains("issueUpdate")))' "$log"
  done
done <<'ROWS'
absent|No checklist.
level-three|### Done when\n- [ ] shared outcome\n### Requirements\n- [ ] requirement
hyphenated|## Done-when\n- [ ] shared outcome
empty|## Done when
no-boxes|## Done when\n* a bullet with no box
ROWS

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
empty|## Done when|state-done|-
no-boxes|## Done when\n* a bullet with no box|state-done|-
ROWS

# A container completes under the ordinary checklist rule: with no checklist
# it needs no box, and its child box stays open until a caller ticks it.
while IFS='|' read -r name title description expected; do
  printf '%b' "$description" >"$TMP_ROOT/container.md"
  log="$TMP_ROOT/container-$name.jsonl"
  rc=0
  CONTAINER_TITLE="$title" CONTAINER_CHILDREN='[{"id":"child-uuid","identifier":"CC-721","title":"child","state":{"name":"Done"}}]' \
    run_complete "$TMP_ROOT/container.md" "$log" CC-720 >"$TMP_ROOT/container.out" 2>"$TMP_ROOT/container.err" || rc=$?
  if [[ "$expected" == refuse ]]; then
    assert_ne "container $name refuses" "$rc" 0
    assert_jq "container $name names its open box" "$(cat "$TMP_ROOT/container.err")" '.error == "post-merge-checklist" and .unmet_branch_boxes == [1]'
    assert_not "container $name stays open" jq -se 'any(.[]; .query | contains("issueUpdate"))' "$log"
  else
    assert_eq "container $name completes" "$rc" 0
    assert_jq "container $name requests its checklist state" "$(updates "$log")" ".variables.input.stateId == \"$expected\""
  fi
done <<'ROWS'
absent|t|No checklist.|state-done
empty|t|## Done when|state-done
post-only|t|## Done when\n- [x] Post-merge: Read health; Where: service; Why after merge: live service; Deadline: 2026-10-04T00:00:00Z\n  Evidence: source read|state-done
child-box|t|## Done when\n- [ ] Every child Done or cancelled|refuse
proved|t|## Done when\n- [x] shared outcome\n  Evidence: source read passed|state-done
ROWS

log="$TMP_ROOT/all.jsonl"
out="$(run_complete "$boxes" "$log" CC-720 --done-when-met all --evidence-file "$proof" 2>"$TMP_ROOT/all.err")" || true
assert_jq "all counts newly ticked boxes" "$out" '.done_when_checked == 2'
update="$(updates "$log")"
assert_jq "the Done update carries the ticked description" "$update" '.variables.input.stateId == "state-done" and (.variables.input.description | contains("- [x] first\n  Evidence: first source read\n- [x] second\n  Evidence: second source read\n  - [x] third\n    Evidence: third source read"))'
assert_jq "a box above the Done-when section stays as filed" "$update" '.variables.input.description | startswith("Problem text.\n\n- [x] above the section\n\n## Done when")'
assert_jq "a box outside the Done-when section stays as filed" "$update" '.variables.input.description | endswith("## Notes\n\n- [x] outside the section\n")'

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
    run_complete "$verification" "$log" CC-720 --done-when-met 1 --evidence-file "$proof" ${phase_args[@]+"${phase_args[@]}"} >"$TMP_ROOT/phase.out" 2>"$TMP_ROOT/phase.err" || rc=$?
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

# Filing and completion read one Deadline rule from done_when_parse: each row
# below gets the same verdict from both. Filing cannot know the merge time, so
# a merge trigger's UTC deadline and a time trigger before merge are judged at
# completion alone, in the refusal table below. A refused row reads its
# completion verdict from the parser completion calls; that table proves the
# command refuses each rule before any write. Columns: name | trigger |
# deadline | the completion rule, or valid.
while IFS='|' read -r name trigger deadline rule; do
  printf '%s\n' '> **Story:** The owner checks a released change. The branch proof is complete. After release, live health decides acceptance.' '' '> **Why this matters:** Live readings keep incomplete acceptance visible.' '' '## Done when' '- [x] branch proof' '  Evidence: branch source read' "- [ ] Post-merge: Read health; Where: service; Why after merge: live release; Trigger: $trigger; Deadline: $deadline" >"$TMP_ROOT/trigger.md"
  filed=0
  require_issue_header_shape "$(cat "$TMP_ROOT/trigger.md")" 2>"$TMP_ROOT/filing.err" || filed=$?
  if [[ "$rule" == valid ]]; then
    log="$TMP_ROOT/trigger-$name.jsonl"
    rc=0
    run_complete "$TMP_ROOT/trigger.md" "$log" CC-720 --post-merge-at "$merged" >"$TMP_ROOT/trigger.out" 2>"$TMP_ROOT/trigger.err" || rc=$?
    assert_eq "post-merge $name files" "$filed" 0
    assert_eq "post-merge $name trigger completes successfully" "$rc" 0
    assert_jq "post-merge $name trigger keeps Verifying" "$(updates "$log")" '.variables.input.stateId == "state-verifying"'
  else
    assert_eq "post-merge $name refuses at filing" "$filed" 1
    assert_jq "post-merge $name names the filing rule" "$(cat "$TMP_ROOT/filing.err")" '.rule == "post-merge-deadline" and .box == 2'
    assert_jq "post-merge $name refuses at completion" "$(done_when_parse "$(cat "$TMP_ROOT/trigger.md")" '[]' "$merged")" ".errors == [{box: 2, rule: \"$rule\"}] and .completion_state == null"
  fi
done <<'ROWS'
merge|merge|2026-10-04T00:00:00Z|valid
time|2026-10-05T00:00:00Z|2026-10-08T00:00:00Z|valid
release|release owner/repo v*|+72h|valid
merge-relative|merge|+72h|valid
time-relative|2026-10-05T00:00:00Z|+24h|valid
merge-early|merge|+0h|post-merge-window
merge-late|merge|+73h|post-merge-window
time-relative-early|2026-10-05T00:00:00Z|+0h|post-merge-window
time-relative-late|2026-10-05T00:00:00Z|+73h|post-merge-window
time-early|2026-10-05T00:00:00Z|2026-10-05T00:00:00Z|post-merge-window
time-late|2026-10-05T00:00:00Z|2026-10-08T00:00:01Z|post-merge-window
release-early|release owner/repo v*|+0h|post-merge-window
release-late|release owner/repo v*|+73h|post-merge-window
release-deadline|release owner/repo v*|2026-10-02T00:00:00Z|post-merge-fields
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
ROWS
# An invalid merge timestamp refuses before any API request.
log="$TMP_ROOT/merge-timestamp.jsonl"
rc=0
run_complete "$verification" "$log" CC-720 --post-merge-at invalid >"$TMP_ROOT/stamp.out" 2>"$TMP_ROOT/stamp.err" || rc=$?
assert_ne "invalid merge timestamp refuses" "$rc" 0
assert_not "invalid merge timestamp refuses before any request" test -s "$log"

# A numeric reading names its figure, comparator, number and unit; any other
# reading is an outcome check. Filing and completion read one parser verdict;
# the refusal table above proves the command refuses a parser error before
# any write. Columns: name | reading | the parser rule, or valid.
while IFS='|' read -r name reading rule; do
  printf '%s\n' '> **Story:** The owner checks a released change. The branch proof is complete. After release, live use decides acceptance.' '' '> **Why this matters:** Live readings keep incomplete acceptance visible.' '' '## Done when' '- [x] branch proof' '  Evidence: branch source read' "- [ ] Post-merge: $reading; Where: Jarvis, the owner's delegate; Why after merge: live use; Deadline: +24h" >"$TMP_ROOT/reading.md"
  filed=0
  require_issue_header_shape "$(cat "$TMP_ROOT/reading.md")" 2>"$TMP_ROOT/filing.err" || filed=$?
  parsed="$(done_when_parse "$(cat "$TMP_ROOT/reading.md")" '[]' "$merged")"
  if [[ "$rule" == valid ]]; then
    assert_eq "reading $name files" "$filed" 0
    assert_jq "reading $name keeps Verifying" "$parsed" '.errors == [] and .completion_state == "Verifying"'
  else
    assert_eq "reading $name refuses at filing" "$filed" 1
    assert_jq "reading $name names the filing rule" "$(cat "$TMP_ROOT/filing.err")" ".rule == \"$rule\" and .box == 2"
    assert_jq "reading $name refuses at completion" "$parsed" ".errors == [{box: 2, rule: \"$rule\"}] and .completion_state == null"
  fi
done <<'ROWS'
outcome|The owner sees the update card on the first launch after install|valid
numeric|p95 create latency <= 300 ms across 20 creates|valid
numeric-percent|failed refreshes < 1% of refreshes|valid
no-unit|failed refreshes = 0|post-merge-numeric
no-figure|>= 3 releases|post-merge-numeric
ROWS
parsed="$(done_when_parse "## Done when"$'\n'"- [ ] Post-merge: p95 create latency <= 300 ms across 20 creates; Where: job; Why after merge: live use; Deadline: +24h" '[]')"
assert_jq "a numeric reading keeps its figure, comparator, number and unit" "$parsed" \
  '.boxes[0].numeric == {figure: "p95 create latency", comparator: "<=", value: 300, unit: "ms"}'

# A waived or superseded box is retired, never ticked: it keeps its text
# without a checkbox and holds no state. A met box beside it still needs its
# evidence, and a ticked box cannot retire.
replacement="$TMP_ROOT/replacement.md"
printf '%s\n' '## Done when' '- [ ] The owner sees the update card' >"$replacement"
retire="$TMP_ROOT/retire.md"
own_box="Post-merge: The owner sees the update card; Where: Jarvis, the owner's delegate; Why after merge: a person's screen; Deadline: +24h"
printf '%s\n' '## Done when' '- [x] branch proof' '  Evidence: branch read' \
  "- [ ] Post-merge: p95 create latency <= 300 ms; Where: job; Why after merge: live use; Deadline: +24h" "- [ ] $own_box" >"$retire"
# The parser owns each retirement's shape. Columns: name | retire | evidence | rule.
while IFS='|' read -r name retired evidence rule; do
  assert_jq "retire $name refuses" "$(done_when_parse "$(cat "$retire")" '[]' "$merged" "$evidence" "$retired")" \
    ".errors == [{box: $(jq -r 'keys[0]' <<<"$retired"), rule: \"$rule\"}] and .completion_state == null"
done <<'ROWS'
waive-checked|{"1":"waived"}|{"1":"owner comment c1: dropped"}|done-when-retirement
waive-no-reason|{"2":"waived"}|{"3":"unrelated"}|done-when-retirement
supersede-no-id|{"3":"superseded"}|{"3":"The owner sees the update card"}|done-when-retirement
ROWS
# complete_issue owns the selections and the transfer read-back.
# Columns: name | options | evidence-file lines | replacement CC-730's state
# type, or archived or trashed | what CC-730's Done when holds: the criterion
# as a box, as a post-merge reading, or another criterion | expected state, or
# the refusal.
while IFS='|' read -r name options lines held holds expected; do
  printf '%b' "$lines" >"$TMP_ROOT/retire-evidence.txt"
  case "$holds" in
    box) cp "$replacement" "$TMP_ROOT/replacement-row.md" ;;
    post-merge) printf '%s\n' '## Done when' "- [ ] $own_box" >"$TMP_ROOT/replacement-row.md" ;;
    other) printf '%s\n' '## Done when' '- [ ] The owner sees a different card' >"$TMP_ROOT/replacement-row.md" ;;
  esac
  log="$TMP_ROOT/retire-$name.jsonl"
  type="$held" archived=null trashed=null
  case "$held" in
    archived) type=unstarted archived='"2026-10-02T00:00:00Z"' ;;
    trashed) type=unstarted trashed=true ;;
  esac
  rc=0
  # shellcheck disable=SC2086  # the options column holds separate words
  REPLACEMENT_ID=CC-730 REPLACEMENT_FILE="$TMP_ROOT/replacement-row.md" REPLACEMENT_TYPE="$type" \
    REPLACEMENT_ARCHIVED_AT="$archived" REPLACEMENT_TRASHED="$trashed" \
    run_complete "$retire" "$log" CC-720 --post-merge-at "$merged" $options --evidence-file "$TMP_ROOT/retire-evidence.txt" \
    >"$TMP_ROOT/retire.out" 2>"$TMP_ROOT/retire.err" || rc=$?
  if [[ "$expected" == state-* ]]; then
    assert_eq "retire $name completes" "$rc" 0
    assert_jq "retire $name sets its state" "$(updates "$log")" ".variables.input.stateId == \"$expected\""
    assert_jq "retire $name keeps the waived box unticked" "$(updates "$log")" \
      '.variables.input.description | contains("- Waived: Post-merge: p95") and (test("\\[x\\] Post-merge: p95") | not)'
  else
    assert_ne "retire $name refuses" "$rc" 0
    assert_jq "retire $name names its refusal" "$(cat "$TMP_ROOT/retire.err")" "$expected"
    assert_not "retire $name writes nothing" jq -se 'any(.[]; .query | contains("issueUpdate"))' "$log"
  fi
done <<'ROWS'
waive-one|--done-when-waived 2|2: owner comment c1: the job reader was retired|unstarted|box|state-verifying
waive-met|--done-when-waived 2 --done-when-met 3|2: owner comment c1: dropped\n3: Jarvis read the card|unstarted|box|state-done
supersede|--done-when-superseded 3 --done-when-waived 2|2: owner comment c1: dropped\n3: CC-730 The owner sees the update card|unstarted|box|state-done
supersede-post-merge|--done-when-superseded 3 --done-when-waived 2|2: owner comment c1: dropped\n3: CC-730 The owner sees the update card|unstarted|post-merge|state-done
supersede-missing|--done-when-superseded 3|3: CC-730 The owner sees the update card|unstarted|other|.error == "done-when-transfer-unread" and .box == 3 and .replacement == "CC-730"
supersede-other-box|--done-when-superseded 2 --done-when-waived 3|2: CC-730 The owner sees the update card\n3: owner comment c1: dropped|unstarted|box|.error == "done-when-transfer-unread" and .box == 2
supersede-canceled|--done-when-superseded 3|3: CC-730 The owner sees the update card|canceled|box|.error == "done-when-transfer-unread"
supersede-archived|--done-when-superseded 3|3: CC-730 The owner sees the update card|archived|box|.error == "done-when-transfer-unread"
supersede-trashed|--done-when-superseded 3|3: CC-730 The owner sees the update card|trashed|box|.error == "done-when-transfer-unread"
supersede-self|--done-when-superseded 3|3: CC-720 The owner sees the update card|unstarted|box|.error == "done-when-transfer-unread"
supersede-self-historical|--done-when-superseded 3|3: CC-650 The owner sees the update card|unstarted|box|.error == "done-when-transfer-unread"
overlap|--done-when-waived 2 --done-when-met 2|2: dropped|unstarted|box|.error == "done-when-disposition-overlap"
overlap-all|--done-when-superseded 3 --done-when-met all|3: CC-730 The owner sees the update card|unstarted|box|.error == "done-when-disposition-overlap"
ROWS
record="$(updates "$TMP_ROOT/retire-supersede.jsonl" | jq -r '.variables.input.description')"
record_tail="- Waived: Post-merge: p95 create latency <= 300 ms; Where: job; Why after merge: live use; Deadline: +24h
  Reason: owner comment c1: dropped
- Superseded: $own_box
  Replacement: CC-730 The owner sees the update card"
assert_eq "a retired box keeps its criterion, reason and replacement" "${record: -${#record_tail}}" "$record_tail"

# A Done update that wrote its retirements and then failed a supersession
# returns a retry. Against the written description that retry finishes: each
# retired box keeps its number, so the box after it is still box 4, and the
# retirements it names again change nothing.
printf '%s\n' "$(cat "$retire")" \
  "- [ ] Post-merge: The owner opens the changelog; Where: Jarvis, the owner's delegate; Why after merge: a person's screen; Deadline: +24h" \
  '' '**Supersedes**:' '' '- CC-740 (at-completion): Replaced scope' >"$TMP_ROOT/retry.md"
printf '%s\n' '2: owner comment c1: dropped' '3: CC-730 The owner sees the update card' '4: Jarvis read the changelog' >"$TMP_ROOT/retry-evidence.txt"
log="$TMP_ROOT/retry-first.jsonl"
rc=0
REPLACEMENT_ID=CC-730 REPLACEMENT_FILE="$replacement" REPLACEMENT_TYPE=unstarted SUPERSEDED_ID=CC-740 SUPERSEDED_READ_FAILS=1 \
  run_complete "$TMP_ROOT/retry.md" "$log" CC-720 --post-merge-at "$merged" --done-when-waived 2 --done-when-superseded 3 \
  --done-when-met 4 --evidence-file "$TMP_ROOT/retry-evidence.txt" >"$TMP_ROOT/retry.out" 2>"$TMP_ROOT/retry.err" || rc=$?
assert_ne "retry source reports its failed supersession" "$rc" 0
assert_jq "retry source wrote Done" "$(updates "$log")" '.variables.input.stateId == "state-done"'
diagnostic="$(jq -Rsc '[split("\n")[] | fromjson? | select(.error == "supersession-incomplete")] | last' "$TMP_ROOT/retry.err")"
updates "$log" | jq -j '.variables.input.description' >"$TMP_ROOT/retry-written.md"
retry_options=()
while IFS= read -r option; do retry_options+=("$option"); done < <(jq -r '.retry.options[]' <<<"$diagnostic")
log="$TMP_ROOT/retry-second.jsonl"
rc=0
REPLACEMENT_ID=CC-730 REPLACEMENT_FILE="$replacement" REPLACEMENT_TYPE=unstarted SUPERSEDED_ID=CC-740 CURRENT_STATE=Done CURRENT_TYPE=completed \
  run_complete "$TMP_ROOT/retry-written.md" "$log" "$(jq -r '.retry.issue' <<<"$diagnostic")" "${retry_options[@]}" \
  >"$TMP_ROOT/retry.out" 2>"$TMP_ROOT/retry.err" || rc=$?
assert_eq "the returned retry finishes" "$rc" 0
assert "the retry reads the superseded item" jq -se 'any(.[]; (.query | contains("issue(id:")) and .variables.id == "CC-740")' "$log"
assert "the retry keeps the written checklist" jq -se --rawfile written "$TMP_ROOT/retry-written.md" \
  '[.[] | select(.query | contains("issueUpdate"))] | length == 1 and .[0].variables.input.stateId == "state-done"
   and .[0].variables.input.description == $written' "$log"

# A retired box is a slot no other selection reaches. Columns: name | met | retire | evidence.
while IFS='|' read -r name met retired evidence; do
  assert_jq "retired slot $name refuses" "$(done_when_parse "$(cat "$TMP_ROOT/retry-written.md")" "$met" "$merged" "$evidence" "$retired")" \
    '.errors == [{box: 2, rule: "done-when-retirement"}] and .completion_state == null'
done <<'ROWS'
met|[2]|{}|{"2":"Jarvis read it"}
other-kind|[]|{"2":"superseded"}|{"2":"CC-730 The owner sees the update card"}
other-reason|[]|{"2":"waived"}|{"2":"owner comment c2: another reason"}
ROWS

# A Waived: or Superseded: bullet without its deeper reason line is ordinary
# prose, in the section or outside it, and takes no number.
# Columns: name | description, \n between lines | boxes as [number, text].
while IFS='|' read -r name description boxes; do
  assert_jq "prose $name keeps its boxes" "$(done_when_parse "$(printf '%b' "$description")" '[]')" \
    "[.boxes[] | [.number, .text]] == $boxes and .errors == []"
done <<'ROWS'
waived-last-line|## Done when\n- [ ] one\n- Waived: something|[[1,"one"]]
waived-unindented-reason|## Done when\n- [ ] one\n- Waived: something\nReason: x\n- [ ] two|[[1,"one"],[2,"two"]]
superseded-reason-line|## Done when\n- [ ] one\n- Superseded: something\n  Reason: x\n- [ ] two|[[1,"one"],[2,"two"]]
before-section|## Notes\n- Waived: something\n## Done when\n- [ ] one\n- [ ] two|[[1,"one"],[2,"two"]]
after-section|## Done when\n- [ ] one\n- [ ] two\n## Notes\n- Waived: something|[[1,"one"],[2,"two"]]
outside-with-reason|## Notes\n- Superseded: the earlier approach\n  Replacement: CC-730 x\n## Done when\n- [ ] one\n- [ ] two|[[1,"one"],[2,"two"]]
ROWS
