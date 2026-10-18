#!/usr/bin/env bash
# bash-runtime: 4
# Surface: issues complete's explicit completion supersession contract.
# Inputs: scripts/linear.sh, scripts/commands/issues.sh and scripts/lib/*.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload=$(sed -n 's/^data = //p' | jq -r)
printf '%s\n' "$payload" >>"${PAYLOAD_LOG:?}"
query=$(jq -r '.query' <<<"$payload")
case "$query" in
  *'commentCreate(input:'*)
    if [ "$SCENARIO" = comment-fail ]; then
      printf '%s' '{"data":{"commentCreate":{"success":false}}}'
    else
      jq -cn --argjson input "$(jq '.variables.input' <<<"$payload")" '{data:{commentCreate:{success:true,comment:{id:"comment",body:$input.body,issue:{identifier:"CC-721"}}}}}'
    fi ;;
  *'workflowStates(filter:'*)
    jq -cn --arg name "$(jq -r '.variables.name' <<<"$payload")" '{data:{workflowStates:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:$name,type:(if $name == "Done" then "completed" elif $name == "Canceled" then "canceled" else "started" end)}]}}}' ;;
  *'teams(filter:'*)
    printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"team","key":"CC","name":"Test"}]}}}' ;;
  *'issueUpdate(id:'*)
    id=$(jq -r '.variables.id' <<<"$payload")
    if [[ ( "$SCENARIO" = cancel-fail && "$id" = CC-721 ) || "$SCENARIO" = complete-fail ]]; then
      printf '%s' '{"data":{"issueUpdate":{"success":false}}}'
    else
      jq -cn --arg id "$id" '{data:{issueUpdate:{success:true,issue:{id:$id,identifier:$id}}}}'
    fi ;;
  *'issue(id:'*)
    id=$(jq -r '.variables.id' <<<"$payload")
    type=started
    [[ "$SCENARIO" != terminal || "$id" != CC-721 ]] || type=completed
    jq -cn --arg id "$id" --arg type "$type" --rawfile description "$DESCRIPTION_FILE" '{data:{issue:{id:$id,identifier:$id,title:"work",description:$description,state:{name:"In Review",type:$type},team:{id:"team",key:"CC",name:"Test"},children:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"fixture-relation",type:"related",relatedIssue:{id:"CC-721",identifier:"CC-721",title:"old",state:{name:"Todo",type:"unstarted"}}},{id:"ordinary",type:"related",relatedIssue:{id:"CC-999",identifier:"CC-999",state:{name:"Todo",type:"unstarted"}}}]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}' ;;
  *) printf '%s' '{"errors":[{"message":"unexpected fixture query"}]}' ;;
esac
printf '___HTTP_CODE___200'
SH
chmod +x "$TMP_ROOT/bin/curl"

for scenario in done related-only malformed held terminal comment-fail cancel-fail complete-fail; do
  description="$TMP_ROOT/description"
  printf '%s\n' 'Related: CC-999' '**Supersedes**:' '' '- CC-721 (at-completion): Replaced scope' >"$description"
  case "$scenario" in
    related-only) printf '%s\n' 'Related: CC-721' >"$description" ;;
    malformed) printf '%s\n' '**Supersedes**:' '' '- CC-721 (now): Not completion authority' >"$description" ;;
    held) printf '\n## Done when\n\n- [x] Branch work\n  Evidence: fixture\n- [ ] Post-merge: Exercise deployment; Where: logs; Why after merge: needs deployment; Trigger: merge; Deadline: +24h\n' >>"$description" ;;
  esac
  log="$TMP_ROOT/$scenario.jsonl"
  : >"$log"
  rc=0
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=CC \
    PAYLOAD_LOG="$log" DESCRIPTION_FILE="$description" SCENARIO="$scenario" \
    "$BASH" .agents/skills/linear/scripts/linear.sh issues complete CC-720) >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?
  expected_rc=0
  case "$scenario" in *-fail) expected_rc=1 ;; esac
  assert_eq "$scenario returns the completion result" "$rc" "$expected_rc"
  mutations=$(jq -sc '[.[] | select(.query | test("commentCreate|issueUpdate")) | {id:(.variables.input.issueId // .variables.id),state:.variables.input.stateId,body:.variables.input.body}]' "$log")
  case "$scenario" in
    done)
      assert_jq "done cancels the named item after its replacement completes" "$mutations" 'map({id,state}) == [{id:"CC-720",state:"Done"},{id:"CC-721",state:null},{id:"CC-721",state:"Canceled"}]'
      assert_jq "done comments naming the replacement before cancellation" "$mutations" '.[1].body | contains("CC-720")' ;;
    comment-fail|cancel-fail)
      assert_jq "$scenario reaches the old item comment" "$mutations" '.[1].id == "CC-721" and .[1].state == null'
      if [ "$scenario" = comment-fail ]; then
        assert_jq "failed comment prevents cancellation" "$mutations" 'all(.[]; .state != "Canceled")'
      fi ;;
    *)
      assert_jq "$scenario leaves related items unchanged" "$mutations" 'all(.[]; .id == "CC-720")' ;;
  esac
  if [ "$scenario" = malformed ]; then
    assert "malformed entry reports its structured category" jq -se 'any(.[]; .warning == "supersedes-malformed")' "$TMP_ROOT/err"
  fi
done
