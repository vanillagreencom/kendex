#!/usr/bin/env bash
# bash-runtime: 4
# Surface: native dueDate in create, update, bulk-update and complete payloads.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"
assert_tmpdir TMP_ROOT
mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SCRIPT_DIR/.." "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IFS= read -r -d '' config || true
if [[ "$config" == *'upload-file = '* ]]; then
  printf '200'
  exit 0
fi
data="${config#*$'\n'data = }"
reply=$(jq -j '
  def connection($items): {nodes:$items, pageInfo:{hasNextPage:false,endCursor:null}};
  {id:"team-uuid", key:"CC", name:"Claude"} as $team
  | . as $sent | fromjson | .query as $query | .variables as $v
  | ($v.id // "CC-1") as $id
  | {id:$id, identifier:$id, title:"item", team:$team, dueDate:"2026-12-31",
     description:(if $id == "CC-1" then env.STORED_BODY else "No checklist." end),
     state:{name:"Verifying",type:"started"}, labels:connection([]), children:connection([]),
     relations:connection([]), inverseRelations:connection([]),
     syncedWith:(if env.SYNCED == "yes" then [{metadata:{owner:"Test",repo:"Test",number:1}}] else [] end)} as $issue
  | (if ($query | test("^\\s*mutation")) then $sent + "\n" else empty end),
    ((if ($query | contains("teams(filter:")) then {teams:connection([$team])}
      elif ($query | contains("workflowStates(filter:")) then
        {workflowStates:connection([{id:$v.name,type:(if $v.name == "Done" then "completed" else "started" end)}])}
      elif ($query | contains("issue(id:")) then {issue:$issue}
      elif ($query | contains("issueCreate(input:")) then {issueCreate:{success:true,issue:$issue}}
      elif ($query | contains("issueUpdate(id:")) then {issueUpdate:{success:true,issue:$issue}}
      elif ($query | contains("fileUpload(")) then {fileUpload:{success:true,
        uploadFile:{uploadUrl:"https://uploads.linear.app/put",assetUrl:"https://uploads.linear.app/shot.png",headers:[]}}}
      elif ($query | contains("commentCreate(input:")) then {commentCreate:{success:true,comment:{id:"comment-uuid",issue:{identifier:$id}}}}
      else error("unexpected operation: " + $query) end) | {data:.} | tojson), "___HTTP_CODE___200"
' <<<"${data%%$'\n'*}")
if [[ "$reply" == *$'\n'* ]]; then
  printf '%s\n' "${reply%%$'\n'*}" >>"${LOG:?}"
  reply="${reply#*$'\n'}"
fi
printf '%s' "$reply"
SH
chmod +x "$TMP_ROOT/bin/curl"

prefix=$'> **Story:** The owner checks a change.\n\n> **Why this matters:** The due date shows when it ends.\n\n## Done when'
check='Post-merge: Check usage; Where: service; Why after merge: live use'
absolute="$prefix"$'\n'"- [ ] $check; Deadline: 2026-10-03T01:00:00Z"
anchored="$prefix"$'\n'"- [ ] $check; Trigger: 2026-10-02T23:00:00Z; Deadline: +2h"
release_box="- [ ] $check; Trigger: release test/test v*; Deadline: +1h"
release="$prefix"$'\n'"$release_box"
release_image="$release"$'\n\n![shot.png](https://uploads.linear.app/shot.png)'
release_owner=$'**Owner, what you do:** Review the change.\n\n'"$release"
relative="$prefix"$'\n'"- [ ] $check; Trigger: merge; Deadline: +2h"$'\n'"- [ ] $check; Deadline: +1h"
materialized="$prefix"$'\n'"- [ ] $check; Trigger: merge; Deadline: 2026-10-02T01:30:00Z"$'\n'"- [ ] $check; Deadline: 2026-10-02T00:30:00Z"
earliest="- [ ] $check; Deadline: 2026-10-02T02:00:00Z"
checked_earlier="- [x] $check; Deadline: 2026-10-02T00:30:00Z"$'\n  Evidence: already read'
mixed="$absolute"$'\n'"$earliest"$'\n'"$checked_earlier"
mixed_release="$mixed"$'\n'"$release_box"
ticked_mixed="$absolute"$'\n'"${earliest/\[ \]/[x]}"$'\n  Evidence: observed result\n'"$checked_earlier"
ordinary="$prefix"$'\n- [ ] Read the branch output.'
ticked="${absolute/\[ \]/[x]}"$'\n  Evidence: observed result'
waived="${absolute/\[ \]/Waived:}"$'\n  Reason: observed result'
printf '%s\n' '1: observed result' '2: observed result' >"$TMP_ROOT/evidence"
printf 'PNGDATA' >"$TMP_ROOT/shot.png"
log="$TMP_ROOT/requests"

# A single write per issue must hold the expected body/state and dueDate.
while IFS='|' read -r name verb stored body after state date other_date; do
  : >"$log"
  args=(issues "$verb")
  synced=no
  case "$verb" in
    create) args+=(--title item --no-agent-label) ;;
    bulk-update) args+=(CC-1 CC-2) ;;
    *) args+=(CC-1) ;;
  esac
  if [[ "$verb" == complete ]]; then
    args+=(--post-merge-at 2026-10-01T23:30:00Z)
    case "$name" in
      tick-earliest) args+=(--done-when-met 2 --evidence-file "$TMP_ROOT/evidence") ;;
      waive-final) args+=(--done-when-waived 1 --evidence-file "$TMP_ROOT/evidence") ;;
      synced-materialization) synced=yes; args+=(--summary proof) ;;
    esac
  elif [[ "$body" == image ]]; then
    args+=(--attach "$TMP_ROOT/shot.png")
  elif [[ "$body" == omitted ]]; then
    args+=(--title changed)
  else
    args+=(--description "${!body}")
  fi
  rc=0
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=CC LINEAR_REQUIRE_REACH= \
    LOG="$log" STORED_BODY="${!stored}" SYNCED="$synced" \
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" "${args[@]}") >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?
  if [[ "$synced" == yes ]]; then
    assert_ne "$name refuses" "$rc" 0
    assert_file_contains "$name names the description guard" "$TMP_ROOT/err" 'linear: refused=synced-description'
    assert_not "$name writes neither summary nor update" test -s "$log"
    continue
  fi
  assert_eq "$name succeeds" "$rc" 0
  count=1
  [[ "$verb" != bulk-update ]] || count=2
  expected_body=''
  [[ "$after" == omitted ]] || expected_body="${!after}"
  assert "$name writes the checklist and native date together" jq -se \
    --arg verb "$verb" --arg date "$date" --arg other_date "$other_date" --arg state "$state" \
    --arg after "$after" --arg body "$expected_body" --argjson count "$count" '
    def due($expected): if $expected == "omitted" then has("dueDate") | not
      elif $expected == "null" then has("dueDate") and .dueDate == null else .dueDate == $expected end;
    map(select(.query | contains("fileUpload(") | not))
    | length == $count and all(.[];
      (.query | contains(if $verb == "create" then "issueCreate(" else "issueUpdate(" end))
      and (.variables.id as $id | .variables.input
           | due(if $id == "CC-2" then $other_date else $date end)
             and (.stateId // "") == $state
             and (if $after == "omitted" then has("description") | not else .description == $body end)))' "$log"
done <<'ROWS'
create-minimum|create|ordinary|mixed_release|mixed_release||2026-10-02
create-undated|create|ordinary|release|release||omitted
update-date|update|mixed|anchored|anchored||2026-10-03
update-unanchored|update|absolute|relative|relative||null
update-ticked|update|absolute|ticked|ticked||null
update-independent|update|ordinary|ordinary|ordinary||omitted
update-release-attachment|update|release|image|release_image||omitted
update-release-owner|update|release|release_owner|release_owner||omitted
update-fields|update|mixed|omitted|omitted||omitted
bulk-date|bulk-update|mixed|anchored|anchored||2026-10-03|2026-10-03
bulk-removal|bulk-update|absolute|ordinary|ordinary||null|omitted
bulk-historical|bulk-update|ticked|ordinary|ordinary||omitted|omitted
complete-unchanged|complete|absolute|omitted|omitted|Verifying|2026-10-03
complete-unchanged-release|complete|release|omitted|omitted|Verifying|omitted
complete-materializes|complete|relative|omitted|materialized|Verifying|2026-10-02
tick-earliest|complete|mixed|omitted|ticked_mixed|Verifying|2026-10-03
waive-final|complete|absolute|omitted|waived|Done|null
synced-materialization|complete|relative|omitted|omitted||omitted
ROWS
