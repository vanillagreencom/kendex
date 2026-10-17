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
    desc="## Done when"$'\n'"- [x] branch proof"$'\n'"  Evidence: branch tests passed"$'\n'"- [ ] Post-merge: Read health; Where: service; Why after merge: needs deployment; Deadline: $deadline"
    printf '%s' "$desc" >"$TMP_ROOT/descriptions/$id"
  fi
  jq -n --arg d "$desc" --arg id "$id" \
    '{id: ("uuid-" + $id), identifier: $id, title: "t", state: {name: "In Review", type: "started"}, updatedAt: "2026-07-14T00:00:00Z", parent: null, description: $d, trashed: false, archivedAt: null}' \
    >"$TMP_ROOT/state/$id.json"
done

# The guard reads LINEAR_TEAM and each issue's current team key. The issue
# read also supplies the issue's description; the update
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
  printf '%s\n' "$state" >>"$STATE/state.requests"
  case "$state" in
    Verifying) state_id=state-verifying ;;
    Done) state_id=state-done ;;
    Todo) state_id=state-todo ;;
    *) printf 'unsupported workflow state: %s\n' "$state" >&2; exit 2 ;;
  esac
  jq -cn --arg id "$state_id" '{data:{workflowStates:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:$id,type:(if $id == "state-done" then "completed" elif $id == "state-verifying" then "started" else "unstarted" end)}]}}}'
  ;;
*"issue(id:"*)
  jq -cjn --argjson d "$(jq -r ' .description | tojson' "$STATE/$id.json")" --arg id "$id" '{data:{issue:{id:("uuid-" + $id),identifier:$id,title:"t",description:$d,state:{name:"In Review",type:"started"},team:{id:"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47",key:"T",name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},project:null,parent:null,children:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}'
  ;;
*"issueUpdate(id:"*)
  response="$(jq -c --argjson prior_state "$(jq .state "$STATE/$id.json")" --rawfile d "$DESCRIPTIONS/$id" --arg id "$id" '{data:{issueUpdate:{success:true,issue:{id:("uuid-" + $id),identifier:$id,title:"t",description:(.variables.input.description // $d),state:(if .variables.input.stateId == "state-verifying" then {name:"Verifying",type:"started"} elif .variables.input.stateId == "state-done" then {name:"Done",type:"completed"} elif .variables.input.stateId == "state-todo" then {name:"Todo",type:"unstarted"} elif .variables.input.stateId == null then $prior_state else error("unsupported state id") end),parent:null,team:{name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},updatedAt:"2026-07-14T00:00:01Z",archivedAt:null,trashed:null,relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}}' <<<"$payload")"
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
  jq -nr --arg now "${VERIFY_NOW:-2026-10-02T12:00:00Z}" '$now | fromdateiso8601'
else
  exec "$REAL_DATE" "$@"
fi
SH
chmod +x "$TMP_ROOT/bin/date"

printf '%s\n' '1: branch source read' '2: live source read' >"$TMP_ROOT/evidence.txt"
linear() { # RESOURCE ACTION ARG...
  (cd "$R" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=T DESCRIPTIONS="$TMP_ROOT/descriptions" STATE="$TMP_ROOT/state" \
    "$BASH" "$R/.agents/skills/linear/scripts/linear.sh" "$@")
}
complete() { linear issues complete "$@"; }

RC=0
complete T-1 --done-when-met all --evidence-file "$TMP_ROOT/evidence.txt" >"$TMP_ROOT/t1.out" 2>"$TMP_ROOT/t1.err" || RC=$?
assert_eq "$RC" 0 "the fully met item completes" "$TMP_ROOT/t1.err"
RC=0
complete T-2 --done-when-met 1 --evidence-file "$TMP_ROOT/evidence.txt" >"$TMP_ROOT/t2.out" 2>"$TMP_ROOT/t2.err" || RC=$?
assert_eq "$RC" 1 "the partly met item refuses" "$TMP_ROOT/t2.err"
assert_eq "$(jq -rs '[.[] | select(.state.type == "completed") | .identifier] | sort | join(",")' "$TMP_ROOT"/state/*.json)" \
  "T-1" "only proved completion reaches Done"

# Actual completion requests keep open live checks in Verifying. A final
# evidence tick takes T-6 from Verifying to Done. T-4 models a checked item
# whose tracker state did not complete, so the sweep must name it.
for id in T-3 T-4 T-5 T-6; do
  RC=0
  complete "$id" --post-merge-at 2026-10-01T00:00:00Z >"$TMP_ROOT/$id.out" 2>"$TMP_ROOT/$id.err" || RC=$?
  assert_eq "$RC" 0 "$id enters Verifying through completion" "$TMP_ROOT/$id.err"
done
RC=0
complete T-6 --post-merge-at 2026-10-01T00:00:00Z --done-when-met 2 --evidence-file "$TMP_ROOT/evidence.txt" >"$TMP_ROOT/t6-final.out" 2>"$TMP_ROOT/t6-final.err" || RC=$?
assert_eq "$RC" 0 "final verification completes T-6" "$TMP_ROOT/t6-final.err"
assert_eq "$(jq -r '.state.name' "$TMP_ROOT/state/T-6.json")" Done "the final box sets Done"
assert_eq "$(tail -1 "$TMP_ROOT/state/state.requests")" Done "final verification requests Done at the API boundary"
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

# A container outcome survives a failed or unread source read. Its holder's
# passing read writes its evidence without changing state. container_close.sh
# covers the following serialized child checks, summary and Done transition.
jq --arg d '## Done when
- [ ] Read the shared outcome at source' '.identifier = "T-10" | .id = "uuid-T-10" | .description = $d | .state = {name:"Todo",type:"unstarted"}' \
  "$TMP_ROOT/state/T-4.json" >"$TMP_ROOT/state/T-10.json"
printf '%s\n' '## Done when' '- [ ] Read the shared outcome at source' >"$TMP_ROOT/descriptions/T-10"
RC=0
complete T-10 >"$TMP_ROOT/parent-open.out" 2>"$TMP_ROOT/parent-open.err" || RC=$?
assert_eq "$RC" 1 "an unread or failed container outcome refuses completion without a merge time"
assert_eq "$(jq -r '.state.name' "$TMP_ROOT/state/T-10.json")" Todo "the failed outcome keeps its parent open"
RC=0
printf '%s\n' '## Done when' '- [x] Read the shared outcome at source' '  Evidence: holder source read passed' >"$TMP_ROOT/holder.md"
linear issues update T-10 --description-file "$TMP_ROOT/holder.md" >"$TMP_ROOT/parent-proved.out" 2>"$TMP_ROOT/parent-proved.err" || RC=$?
assert_eq "$RC" 0 "holder evidence writes without a merge time" "$TMP_ROOT/parent-proved.err"
assert_eq "$(jq -r '.state.name' "$TMP_ROOT/state/T-10.json")" Todo "the holder evidence update keeps its parent open"
assert_eq "$(jq -r '.description' "$TMP_ROOT/state/T-10.json")" "$(cat "$TMP_ROOT/holder.md")" "the holder description contains the tick and Evidence"

# Both readers resolve release publication. This release has not fired.
# Waiting retains the merge date without a deadline.
jq --arg d '## Done when
- [ ] Post-merge: Read health; Where: service; Why after merge: release; Trigger: release owner/repo v*; Deadline: +24h' '.identifier = "T-9" | .id = "uuid-T-9" | .description = $d' "$TMP_ROOT/state/T-4.json" >"$TMP_ROOT/state/T-9.json"

cat >"$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'pr list') echo '[{"state":"MERGED","mergedAt":"2026-10-01T00:00:00.123Z","isCrossRepository":false,"mergeCommit":{"oid":"1111111111111111111111111111111111111111"},"url":"https://github.com/owner/repo/pull/1"}]' ;;
  'release list') cat "$RELEASES" ;;
  'api repos/owner/repo/compare/'*) echo ahead ;;
  *) exit 2 ;;
esac
SH
chmod +x "$TMP_ROOT/bin/gh"
printf '%s\n' '[]' >"$TMP_ROOT/releases.json"

OUT=""
RC=0
OUT="$(cd "$R" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" LINEAR_API_KEY_OVERRIDE=test-token \
  REAL_DATE="$REAL_DATE" RELEASES="$TMP_ROOT/releases.json" DESCRIPTIONS="$TMP_ROOT/descriptions" STATE="$TMP_ROOT/state" "$RW" 2>&1)" || RC=$?
assert_eq "$RC" 1 "the sweep reports a finding"
assert_not_contains "$OUT" "issue=T-1" "a fully met completion leaves no done-unchecked finding"
assert_not_contains "$OUT" "done-unchecked issue=T-2" "a refused branch tick stays open"
assert_contains "$OUT" 'verifying T-3 box=2 trigger="merge" status=overdue deadline=2026-10-02T00:00:00Z blocked_by=-' "past-deadline Verifying is reported"
assert_contains "$OUT" "verifying-empty issue=T-4" "Verifying with no open box is reported"
assert_not_contains "$OUT" "issue=T-5" "future Verifying has no stale development finding"
assert_not_contains "$OUT" "issue=T-6" "completed verification has no finding"
assert_contains "$OUT" 'verifying T-9 box=1 trigger="release owner/repo v*" status=waiting deadline=- merged=2026-10-01T00:00:00Z blocked_by=-' "an unfired release has no deadline and keeps its merge date"
assert_contains "$OUT" 'verifying-counts due=1 overdue=1 blocked=0 waiting=1 items=6' "the count line reports every fixture status"
assert_contains "$OUT" "verifying-invalid issue=T-7" "missing post-merge metadata is reported"
assert_contains "$OUT" "verifying-invalid issue=T-8" "open branch work in Verifying is reported"
# Controls mutate only disposable scripts outside the item worktree.
source "$TEST_DIR/lib/growth-state.sh"
mkdir -p "$TMP_ROOT/release-state"
while IFS='|' read -r name trigger deadline releases status due_at control; do
  jq --arg trigger "$trigger" --arg deadline "$deadline" '.description = ("## Done when\n- [ ] Post-merge: Read health; Where: service; Why after merge: release; Trigger: " + $trigger + "; Deadline: " + $deadline)' "$TMP_ROOT/state/T-9.json" >"$TMP_ROOT/release-state/T-9.json"
  printf '%s\n' "$releases" >"$TMP_ROOT/releases.json"
  ROW_OUT="$(cd "$R" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" LINEAR_API_KEY_OVERRIDE=test-token REAL_DATE="$REAL_DATE" VERIFY_NOW=2026-10-04T01:00:00Z RELEASES="$TMP_ROOT/releases.json" STATE="$TMP_ROOT/release-state" "$RW" 2>&1)" || true
  expected="verifying T-9 box=1 trigger=\"$trigger\" status=$status deadline=$due_at"
  [[ "$trigger" != release* ]] || expected+=' merged=2026-10-01T00:00:00Z'
  assert_contains "$ROW_OUT" "$expected blocked_by=-" "$name reports its clock and trigger"
  [[ "$status" != waiting ]] || assert_not_contains "$ROW_OUT" 'status=overdue' "$name never becomes overdue without a release"
  MUTANT_DIR="$TMP_ROOT/release-$name"
  MUTANT_RW="$(mutant_scripts "release-$name/orch" reconcile-work-items)/reconcile-work-items" || exit 1
  ln -s "$LINEAR_SKILL" "$MUTANT_DIR/linear"
  mutant_lib="${MUTANT_RW%/*}/lib/verifying.sh"
  rm -- "${mutant_lib:?}"
  cp "$SKILL_DIR/scripts/lib/verifying.sh" "$mutant_lib"
  case "$control" in
    waiting) mutate_file "$mutant_lib" 'if $fired == null then null' 'if $fired == null then $merged + 259200' ;;
    fired) mutate_file "$mutant_lib" '$fired + (.deadline_hours * 3600)' '$merged + 259200' ;;
    merge) mutate_file "$mutant_lib" '.deadline_epoch <= $now' 'false' ;;
    null) mutate_file "$mutant_lib" '.deadline_epoch != null and ' '' ;;
    merge-hours) mutate_file "$mutant_lib" 'then $merged else .trigger_epoch end' 'then null else .trigger_epoch end' ;;
    hours) mutate_file "$mutant_lib" 'if .deadline_hours != null then' 'if false then' ;;
  esac
  CONTROL_OUT="$(cd "$R" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" LINEAR_API_KEY_OVERRIDE=test-token REAL_DATE="$REAL_DATE" VERIFY_NOW=2026-10-04T01:00:00Z RELEASES="$TMP_ROOT/releases.json" STATE="$TMP_ROOT/release-state" "$MUTANT_RW" 2>&1)" || true
  assert_not_contains "$CONTROL_OUT" 'scan-failed' "control: $name reaches a complete judgement"
  assert_not_contains "$CONTROL_OUT" "$expected blocked_by=-" "control: $name rejects the restored defect"
done <<'ROWS'
waiting|release owner/repo v*|+72h|[]|waiting|-|waiting
null|release owner/repo v*|+72h|[]|waiting|-|null
fired|release owner/repo v*|+72h|[{"tagName":"v1","publishedAt":"2026-10-02T00:00:00Z","isDraft":false}]|due|2026-10-05T00:00:00Z|fired
merge|merge|2026-10-04T00:00:00Z|[]|overdue|2026-10-04T00:00:00Z|merge
merge-relative|merge|+72h|[]|overdue|2026-10-04T00:00:00Z|merge-hours
time-relative|2026-10-03T12:00:00Z|+24h|[]|due|2026-10-04T12:00:00Z|hours
ROWS
printf '%s\n' '[]' >"$TMP_ROOT/releases.json"
for control in overdue empty stale fields branch; do
  MUTANT_DIR="$TMP_ROOT/reconcile-$control"
  MUTANT_RW="$(mutant_scripts "reconcile-$control/orch" reconcile-work-items)/reconcile-work-items" || exit 1
  ln -s "$LINEAR_SKILL" "$MUTANT_DIR/linear"
  case "$control" in
    overdue)
      mutant_lib="${MUTANT_RW%/*}/lib/verifying.sh"
      rm -- "${mutant_lib:?}"
      cp "$SKILL_DIR/scripts/lib/verifying.sh" "$mutant_lib"
      mutate_file "$mutant_lib" '.deadline_epoch <= $now' 'false'
      expected='status=overdue'
      ;;
    empty) mutate_file "$MUTANT_RW" 'if [ "$open_count" -eq 0 ]; then' 'if false; then'; expected='verifying-empty issue=T-4' ;;
    stale) mutate_file "$MUTANT_RW" 'and .state.name != "Verifying"' 'and true'; expected='started-stale issue=T-5' ;;
    fields)
      mutant_lib="${MUTANT_RW%/*}/lib/verifying.sh"
      rm -- "${mutant_lib:?}"
      cp "$SKILL_DIR/scripts/lib/verifying.sh" "$mutant_lib"
      mutate_file "$mutant_lib" "if (.errors | length) == 0 and all(.boxes[]; .checked or .post_merge)" "if all(.boxes[]; .checked or .post_merge)"; expected='verifying-invalid issue=T-7' ;;
    branch)
      mutant_lib="${MUTANT_RW%/*}/lib/verifying.sh"
      rm -- "${mutant_lib:?}"
      cp "$SKILL_DIR/scripts/lib/verifying.sh" "$mutant_lib"
      mutate_file "$mutant_lib" "if (.errors | length) == 0 and all(.boxes[]; .checked or .post_merge)" "if (.errors | length) == 0"; expected='verifying-invalid issue=T-8' ;;
  esac
  CONTROL_RC=0
  CONTROL_OUT="$(cd "$R" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" LINEAR_API_KEY_OVERRIDE=test-token \
    REAL_DATE="$REAL_DATE" RELEASES="$TMP_ROOT/releases.json" DESCRIPTIONS="$TMP_ROOT/descriptions" STATE="$TMP_ROOT/state" RECONCILE_STALE_HOURS=0 "$MUTANT_RW" 2>&1)" || CONTROL_RC=$?
  assert_eq "$CONTROL_RC" 1 "control: $control reaches findings"
  if [[ "$control" == stale ]]; then
    assert_contains "$CONTROL_OUT" "$expected" "control: removing the exclusion makes Verifying stale development"
  else
    assert_not_contains "$CONTROL_OUT" "$expected" "control: $control removes the required finding"
  fi
done

# An overdue box alone must cause exit 1, without another finding to hide
# a missing increment. Linear supplies the same T-3 row as the main fixture.
mkdir -p "$TMP_ROOT/overdue-state"
cp "$TMP_ROOT/state/T-3.json" "$TMP_ROOT/overdue-state/T-3.json"
OVERDUE_RC=0
OVERDUE_OUT="$(cd "$R" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" LINEAR_API_KEY_OVERRIDE=test-token \
  REAL_DATE="$REAL_DATE" RELEASES="$TMP_ROOT/releases.json" DESCRIPTIONS="$TMP_ROOT/descriptions" STATE="$TMP_ROOT/overdue-state" "$RW" 2>&1)" || OVERDUE_RC=$?
assert_eq "$OVERDUE_RC" 1 "an overdue box alone exits 1"
assert_contains "$OVERDUE_OUT" 'verifying-counts due=0 overdue=1 blocked=0 waiting=0 items=1' "the overdue-only fixture has no other finding"
MUTANT_DIR="$TMP_ROOT/reconcile-exit"
MUTANT_RW="$(mutant_scripts reconcile-exit/orch reconcile-work-items)/reconcile-work-items" || exit 1
ln -s "$LINEAR_SKILL" "$MUTANT_DIR/linear"
mutate_file "$MUTANT_RW" 'findings=$((findings + overdue_count))' 'findings=$((findings + 0))'
CONTROL_RC=0
CONTROL_OUT="$(cd "$R" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" LINEAR_API_KEY_OVERRIDE=test-token \
  REAL_DATE="$REAL_DATE" RELEASES="$TMP_ROOT/releases.json" DESCRIPTIONS="$TMP_ROOT/descriptions" STATE="$TMP_ROOT/overdue-state" "$MUTANT_RW" 2>&1)" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" 0 "control: dropping the overdue finding violates exit 1"

# The zero line also prints when the live tracker holds no Verifying item.
for file in "$TMP_ROOT/state/"*.json; do
  jq 'if .state.name == "Verifying" then .state = {name:"Done",type:"completed"} else . end' "$file" >"$TMP_ROOT/zero.json"
  mv -- "$TMP_ROOT/zero.json" "$file"
done
ZERO_RC=0
ZERO_OUT="$(cd "$R" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" LINEAR_API_KEY_OVERRIDE=test-token \
  REAL_DATE="$REAL_DATE" RELEASES="$TMP_ROOT/releases.json" DESCRIPTIONS="$TMP_ROOT/descriptions" STATE="$TMP_ROOT/state" "$RW" 2>&1)" || ZERO_RC=$?
assert_contains "$ZERO_OUT" 'verifying-counts due=0 overdue=0 blocked=0 waiting=0 items=0' "no Verifying item reports a zero count"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
