#!/usr/bin/env bash
# reconcile-work-items over items the linear CLI's `issues complete
# --done-when-met` closed: an item completed with every Done-when box met
# leaves no done-unchecked finding, and one completed with a box unmet still
# does. Offline: the real linear CLI against a stubbed Linear API, which keeps
# each issue's state as the updates leave it and answers the sweep's live
# issue read from that state.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
RW="$SKILL_DIR/scripts/reconcile-work-items"
LINEAR_SKILL="$SKILL_DIR/../linear/"

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

# The linear CLI's contract is Bash 4 or newer, and the macOS leg runs this
# battery under /bin/bash 3.2; the linear shard skips its own suites there
# for the same reason.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf 'skip: the linear CLI needs Bash 4 or newer, this shell is %s\n' "$BASH_VERSION"
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  exit 0
fi

TMP_ROOT="$(mktemp -d)" || { echo "reconcile-work-items-complete: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "reconcile-work-items-complete: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "reconcile-work-items-complete: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

R="$TMP_ROOT/repo"
mkdir -p "$R/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/home" "$TMP_ROOT/descriptions" "$TMP_ROOT/state"
git -C "$R" init -q
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false
cp -R "$LINEAR_SKILL" "$R/.agents/skills/linear"

desc='## Done when

- [ ] the first box
- [ ] the second box'
for id in T-1 T-2 T-3 T-4 T-5 T-6; do
  printf '%s' "$desc" >"$TMP_ROOT/descriptions/$id"
done
for id in T-1 T-2 T-3 T-4 T-5 T-6; do
  if [[ "$id" != T-1 && "$id" != T-2 ]]; then
    deadline=2026-10-02T00:00:00Z
    [[ "$id" != T-5 ]] || deadline=2026-10-03T00:00:00Z
    desc="## Done when"$'\n'"- [x] branch proof"$'\n'"- [ ] Post-merge: Read health; Where: service; Why after merge: needs deployment; Deadline: $deadline"
    printf '%s' "$desc" >"$TMP_ROOT/descriptions/$id"
  fi
  jq -n --arg d "$desc" --arg id "$id" \
    '{id: ("uuid-" + $id), identifier: $id, title: "t", state: {name: "In Review", type: "started"}, updatedAt: "2026-07-14T00:00:00Z", parent: null, description: $d, trashed: false, archivedAt: null}' \
    >"$TMP_ROOT/state/$id.json"
done

# The team read answers the cross-team guard's read of LINEAR_TEAM. The issue
# read answers with the issue's description file; the update
# answers Done with the description it was sent, or that file's when it was
# sent none, as Linear keeps a description an update leaves out, and records
# the issue so the list read answers it as the update left it.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
id="$(jq -r '.variables.id // empty' <<<"$payload")"
case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"team-uuid","key":"T","name":"Claude"}]}}}'
  ;;
*"workflowStates(filter:"*)
  state="$(jq -r '.variables.name' <<<"$payload")"
  if [[ "$state" == Verifying ]]; then state_id=state-verifying; else state_id=state-done; fi
  jq -cn --arg id "$state_id" '{data:{workflowStates:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:$id}]}}}'
  ;;
*"issue(id:"*)
  jq -cjn --argjson d "$(jq -r ' .description | tojson' "$STATE/$id.json")" --arg id "$id" '{data:{issue:{id:("uuid-" + $id),identifier:$id,title:"t",description:$d,state:{name:"In Review",type:"started"},team:{id:"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47",name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},project:null,parent:null,children:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}'
  ;;
*"issueUpdate(id:"*)
  response="$(jq -c --rawfile d "$DESCRIPTIONS/$id" --arg id "$id" '{data:{issueUpdate:{success:true,issue:{id:("uuid-" + $id),identifier:$id,title:"t",description:(.variables.input.description // $d),state:(if .variables.input.stateId == "state-verifying" then {name:"Verifying",type:"started"} else {name:"Done",type:"completed"} end),parent:null,team:{name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},updatedAt:"2026-07-14T00:00:01Z",archivedAt:null,trashed:null,relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}}' <<<"$payload")"
  jq -c '.data.issueUpdate.issue' <<<"$response" >"$STATE/$id.json"
  printf '%s' "$response"
  ;;
*"issues(filter:"*)
  jq -cjs '{data:{issues:{pageInfo:{hasNextPage:false,endCursor:null},nodes:.}}}' "$STATE"/*.json
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}'
  ;;
esac
printf '___HTTP_CODE___200'
SH
chmod +x "$TMP_ROOT/bin/curl"
REAL_DATE="$(command -v date)"
cat >"$TMP_ROOT/bin/date" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == "-u +%s" ]]; then
  jq -nr '"2026-10-02T12:00:00Z" | fromdateiso8601'
else
  exec "$REAL_DATE" "$@"
fi
SH
chmod +x "$TMP_ROOT/bin/date"

complete() { # ID MET
  (cd "$R" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=T DESCRIPTIONS="$TMP_ROOT/descriptions" STATE="$TMP_ROOT/state" \
    "$BASH" "$R/.agents/skills/linear/scripts/linear.sh" issues complete "$@")
}

RC=0
complete T-1 --done-when-met all >"$TMP_ROOT/t1.out" 2>"$TMP_ROOT/t1.err" || RC=$?
assert_eq "$RC" 0 "the fully met item completes" "$TMP_ROOT/t1.err"
RC=0
complete T-2 --done-when-met 1 >"$TMP_ROOT/t2.out" 2>"$TMP_ROOT/t2.err" || RC=$?
assert_eq "$RC" 0 "the partly met item completes" "$TMP_ROOT/t2.err"
assert_eq "$(jq -rs '[.[] | select(.state.type == "completed") | .identifier] | sort | join(",")' "$TMP_ROOT"/state/*.json)" \
  "T-1,T-2" "both completions reach the tracker the sweep reads"

# Actual completion requests keep open live checks in Verifying. A final
# evidence tick takes T-6 from Verifying to Done. T-4 models a checked item
# whose tracker state did not complete, so the sweep must name it.
for id in T-3 T-4 T-5 T-6; do
  RC=0
  complete "$id" --post-merge-at 2026-10-01T00:00:00Z >"$TMP_ROOT/$id.out" 2>"$TMP_ROOT/$id.err" || RC=$?
  assert_eq "$RC" 0 "$id enters Verifying through completion" "$TMP_ROOT/$id.err"
done
RC=0
complete T-6 --post-merge-at 2026-10-01T00:00:00Z --done-when-met 2 >"$TMP_ROOT/t6-final.out" 2>"$TMP_ROOT/t6-final.err" || RC=$?
assert_eq "$RC" 0 "final verification completes T-6" "$TMP_ROOT/t6-final.err"
assert_eq "$(jq -r '.state.name' "$TMP_ROOT/state/T-6.json")" Done "the final box sets Done"
jq '.description |= sub("\\[ \\]"; "[x]")' "$TMP_ROOT/state/T-4.json" >"$TMP_ROOT/t4-checked.json"
mv -- "$TMP_ROOT/t4-checked.json" "$TMP_ROOT/state/T-4.json"

# A live tracker read can also contain an edited Verifying checklist that
# completion would refuse. The sweep names that error, not an empty check.
for id in T-7 T-8; do
  if [[ "$id" == T-7 ]]; then
    invalid_description="## Done when"$'\n'"- [ ] Post-merge: Read health"
  else
    invalid_description="## Done when"$'\n'"- [ ] branch proof"$'\n'"- [ ] Post-merge: Read health; Where: service; Why after merge: needs deployment; Deadline: 2026-10-03T00:00:00Z"
  fi
  jq --arg id "$id" --arg d "$invalid_description" '.identifier = $id | .id = ("uuid-" + $id) | .description = $d' \
    "$TMP_ROOT/state/T-4.json" >"$TMP_ROOT/state/$id.json"
done

# Release publication is read by the watch. Reconciliation cannot date an
# unfired release trigger and must not report its relative deadline overdue.
jq --arg d '## Done when
- [ ] Post-merge: Read health; Where: service; Why after merge: release; Trigger: release owner/repo v*; Deadline: +24h' '.identifier = "T-9" | .id = "uuid-T-9" | .description = $d' "$TMP_ROOT/state/T-4.json" >"$TMP_ROOT/state/T-9.json"

OUT=""
RC=0
OUT="$(cd "$R" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" LINEAR_API_KEY_OVERRIDE=test-token \
  REAL_DATE="$REAL_DATE" DESCRIPTIONS="$TMP_ROOT/descriptions" STATE="$TMP_ROOT/state" "$RW" 2>&1)" || RC=$?
assert_eq "$RC" 1 "the sweep reports a finding"
assert_not_contains "$OUT" "issue=T-1" "a fully met completion leaves no done-unchecked finding"
assert_contains "$OUT" "done-unchecked issue=T-2" "a partly met completion is still done-unchecked"
assert_contains "$OUT" "verifying-overdue issue=T-3 box=2 deadline=2026-10-02T00:00:00Z" "past-deadline Verifying is reported"
assert_contains "$OUT" "verifying-empty issue=T-4" "Verifying with no open box is reported"
assert_not_contains "$OUT" "issue=T-5" "future Verifying has no stale development finding"
assert_not_contains "$OUT" "issue=T-6" "completed verification has no finding"
assert_not_contains "$OUT" "issue=T-9" "an undated release deadline is not overdue"
assert_contains "$OUT" "verifying-invalid issue=T-7" "missing post-merge metadata is reported"
assert_contains "$OUT" "verifying-invalid issue=T-8" "open branch work in Verifying is reported"
# Controls mutate only disposable scripts outside the item worktree.
source "$TEST_DIR/lib/growth-state.sh"
for control in overdue empty stale fields branch release; do
  MUTANT_DIR="$TMP_ROOT/reconcile-$control"
  MUTANT_RW="$(mutant_scripts "reconcile-$control/orch" reconcile-work-items)/reconcile-work-items" || exit 1
  ln -s "$LINEAR_SKILL" "$MUTANT_DIR/linear"
  case "$control" in
    release) mutate_file "$MUTANT_RW" 'and .deadline_epoch != null' 'and true'; expected='verifying-overdue issue=T-9' ;;
    overdue) mutate_file "$MUTANT_RW" 'and .deadline_epoch <= $now' 'and false'; expected='verifying-overdue issue=T-3' ;;
    empty) mutate_file "$MUTANT_RW" 'if [ "$open_count" -eq 0 ]; then' 'if false; then'; expected='verifying-empty issue=T-4' ;;
    stale) mutate_file "$MUTANT_RW" 'and .state.name != "Verifying"' 'and true'; expected='started-stale issue=T-5' ;;
    fields) mutate_file "$MUTANT_RW" "'(.errors | length) == 0 and all(.boxes[]; .checked or .post_merge)'" "'all(.boxes[]; .checked or .post_merge)'"; expected='verifying-invalid issue=T-7' ;;
    branch) mutate_file "$MUTANT_RW" "'(.errors | length) == 0 and all(.boxes[]; .checked or .post_merge)'" "'(.errors | length) == 0'"; expected='verifying-invalid issue=T-8' ;;
  esac
  CONTROL_RC=0
  CONTROL_OUT="$(cd "$R" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" LINEAR_API_KEY_OVERRIDE=test-token \
    REAL_DATE="$REAL_DATE" DESCRIPTIONS="$TMP_ROOT/descriptions" STATE="$TMP_ROOT/state" RECONCILE_STALE_HOURS=0 "$MUTANT_RW" 2>&1)" || CONTROL_RC=$?
  assert_eq "$CONTROL_RC" 1 "control: $control reaches findings"
  if [[ "$control" == stale || "$control" == release ]]; then
    assert_contains "$CONTROL_OUT" "$expected" "control: removing the exclusion makes Verifying stale development"
  else
    assert_not_contains "$CONTROL_OUT" "$expected" "control: $control removes the required finding"
  fi
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
