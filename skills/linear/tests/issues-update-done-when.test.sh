#!/usr/bin/env bash
# bash-runtime: 4
# Surface: issues update / bulk-update terminal-state preflight.
# Inputs: scripts/commands/issues.sh, scripts/lib/common.sh,
# scripts/lib/issue-validation.sh and the installed linear CLI.
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

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47","key":"CC","name":"Claude"}]}}}'
  ;;
*"workflowStates(filter:"*)
  name="$(jq -r '.variables.name' <<<"$payload")"
  case "$name" in
    Done|Closed) type=completed ;;
    Canceled|Duplicate) type=canceled ;;
    Verifying) type=started ;;
    Todo) type=unstarted ;;
    *) exit 2 ;;
  esac
  jq -cn --arg name "$name" --arg type "$type" \
    '{data:{workflowStates:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:$name,type:$type}]}}}'
  ;;
*"issue(id:"*|*"issueUpdate(id:"*)
  if [[ "${UNREAD_CHILD:-}" = "$(jq -r '.variables.id' <<<"$payload")" ]]; then
    printf '%s' '{"data":{"issue":null}}___HTTP_CODE___200'
    exit 0
  fi
  jq -cn --argjson payload "$payload" --argjson descriptions "${DESCRIPTIONS:?}" \
    --argjson children "${CHILDREN:?}" --arg current "${CURRENT_STATE:-Todo}" '
    $payload.variables as $v
    | {id:$v.id,identifier:$v.id,title:"item",description:($descriptions[$v.id] // ""),
       team:{key:"CC",id:"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47",name:"Claude"},
       state:{name:$current,type:"started"},parent:null,
       children:{nodes:(($children[$v.id] // []) | map({id:.id,identifier:.id,state:{name:"child state",type:.type}})),pageInfo:{hasNextPage:false,endCursor:null}},
       labels:{nodes:[],pageInfo:{hasNextPage:false,endCursor:null}},
       relations:{nodes:[],pageInfo:{hasNextPage:false,endCursor:null}},
       inverseRelations:{nodes:[],pageInfo:{hasNextPage:false,endCursor:null}}} as $issue
    | if ($payload.query | contains("issueUpdate")) then
        {data:{issueUpdate:{success:true,issue:($issue + {description:($v.input.description // $issue.description),state:{name:$v.input.stateId,type:"completed"}})}}}
      else {data:{issue:$issue}} end'
  ;;
*) exit 2 ;;
esac
printf '___HTTP_CODE___200'
SH
chmod +x "$TMP_ROOT/bin/curl"

run_case() {
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=CC \
    CURL_LOG="$TMP_ROOT/requests.jsonl" DESCRIPTIONS="$descriptions" CURRENT_STATE="$current" \
    CHILDREN="$children" UNREAD_CHILD="$unread_child" \
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues "$@")
}

# A batch puts an eligible issue first, then two open items. A failure on the
# last item must leave the first issue untouched and name both open items.
# The diagnostic is the keyed contract consumed by state-changing callers.
while IFS='|' read -r name action current state body expected tree; do
  description="$(printf '%b' "$body")"
  descriptions="$(jq -cn --arg desc "$description" '{"CC-1":"No checklist.","CC-2":$desc,"CC-3":$desc}')"
  children='{}'
  unread_child=''
  case "$tree" in
    open) children='{"CC-2":[{"id":"CC-4","type":"started"}],"CC-3":[{"id":"CC-5","type":"unstarted"}]}' ;;
    closed|grandchild|unreadable)
      child_type=completed
      [[ "$tree" != grandchild ]] || child_type=started
      children="$(jq -cn --arg type "$child_type" '{"CC-2":[{id:"CC-4",type:"completed"}],"CC-4":[{id:"CC-5",type:"canceled"},{id:"CC-6",type:$type}]}')"
      [[ "$tree" != unreadable ]] || unread_child=CC-4
      ;;
  esac
  : >"$TMP_ROOT/requests.jsonl"
  args=("$action")
  if [ "$action" = bulk-update ]; then
    args+=(CC-1 CC-2 CC-3)
  else
    args+=(CC-2)
  fi
  args+=(--state "$state")
  # A refused state must precede all field writes and storage uploads.
  if [[ "$name" = *attachment ]]; then
    printf '%s' attachment >"$TMP_ROOT/file.txt"
    args+=(--attach "$TMP_ROOT/file.txt" --title Changed)
  fi
  rc=0
  run_case "${args[@]}" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?
  requests="$(jq -s . "$TMP_ROOT/requests.jsonl")"
  if [ "$expected" != pass ]; then
    refusal='done-when-open'
    boxes='open_boxes=[1,3]'
    if [ "$expected" = children ]; then
      refusal='open-children'
      boxes='children=CC-4'
      [[ "$tree" != grandchild ]] || boxes='children=CC-6'
    elif [ "$expected" = evidence ]; then
      refusal='done-when-evidence'
      boxes='missing_evidence_boxes=[1,3]'
    fi
    assert_ne "$name refuses" "$rc" 0
    if [ "$expected" = unreadable ]; then
      assert_jq "$name reaches the failed descendant read" "$requests" \
        'any(.[]; (.query | contains("query GetChildren(")) and .variables.id == "CC-4")'
    else
      assert_file_contains "$name identifies refused input" "$TMP_ROOT/err" \
        "linear: refused=$refusal issue=CC-2 $boxes fix="
    fi
    assert_jq "$name writes nothing" "$requests" 'all(.[]; (.query | test("^\\s*mutation") | not))'
    if [[ "$action" = bulk-update && "$expected" != unreadable ]]; then
      [[ "$expected" != children ]] || boxes='children=CC-5'
      assert_file_contains "$name identifies the later refused item" "$TMP_ROOT/err" \
        "linear: refused=$refusal issue=CC-3 $boxes fix="
    fi
  else
    assert_eq "$name succeeds" "$rc" 0
    expected_updates=1
    [ "$action" != bulk-update ] || expected_updates=3
    assert_jq "$name writes the requested state" "$requests" \
      "[.[] | select(.query | contains(\"issueUpdate\")) | .variables.input.stateId] == [range($expected_updates) | \"$state\"]"
  fi
done <<'ROWS'
update|update|Todo|Done|## Done when\n- [ ] first\n- [x] second\n- [ ] third|refuse
verifying|update|Verifying|Done|## Done when\n- [ ] first\n- [x] second\n- [ ] Post-merge: health|refuse
custom-completed|update|Todo|Closed|## Done when\n- [ ] first\n- [X] second\n- [ ] third|refuse
attachment|update|Todo|Done|## Done when\n- [ ] first\n- [x] second\n- [ ] third|refuse
bulk|bulk-update|Todo|Done|## Done when\n- [ ] first\n- [x] second\n- [ ] third|refuse
bulk-custom|bulk-update|Verifying|Closed|## Done when\n- [ ] first\n- [x] second\n- [ ] third|refuse
bulk-attachment|bulk-update|Todo|Done|## Done when\n- [ ] first\n- [x] second\n- [ ] third|refuse
missing-evidence|update|Todo|Done|## Done when\n- [x] first\n- [x] second\n  Evidence: read\n- [X] third|evidence
blank-evidence|update|Todo|Done|## Done when\n- [x] first\n  Evidence:   \n- [x] second\n  Evidence: read\n- [X] third\n  Evidence:\t|evidence
bulk-evidence|bulk-update|Verifying|Closed|## Done when\n- [x] first\n- [x] second\n  Evidence: read\n- [x] third\n  Evidence:   |evidence
checked|update|Todo|Done|## Done when\n- [x] first\n  Evidence: read first\n- [X] second\n  Evidence: read second|pass
absent|update|Todo|Done|No checklist.\n- [ ] unrelated|pass
other-section|update|Todo|Done|## Done when\n- [x] first\n  Evidence: read\n## Notes\n- [ ] unrelated|pass
bulk-checked|bulk-update|Todo|Closed|## Done when\n- [x] first\n  Evidence: read|pass
bulk-absent|bulk-update|Todo|Done|No checklist.|pass
started|update|Todo|Verifying|## Done when\n- [ ] first|pass
started-without-evidence|update|Todo|Verifying|## Done when\n- [x] first|pass
cancel-child|update|Todo|Canceled|No checklist.|children|open
cancel-alias|update|Todo|Duplicate|No checklist.|children|open
cancel-attachment|update|Todo|Canceled|No checklist.|children|open
cancel-grandchild|update|Todo|Canceled|No checklist.|children|grandchild
cancel-closed|update|Todo|Canceled|## Done when\n- [ ] obsolete|pass|closed
cancel-empty|update|Todo|Canceled|No checklist.|pass
cancel-unreadable|update|Todo|Canceled|No checklist.|unreadable|unreadable
bulk-cancel|bulk-update|Todo|Canceled|No checklist.|children|open
bulk-cancel-unreadable|bulk-update|Todo|Canceled|No checklist.|unreadable|unreadable
ordinary-open-child|update|Todo|Verifying|No checklist.|pass|open
ROWS
