#!/usr/bin/env bash
# bash-runtime: 4
# Tests for completion validation of bundle children.
#
# validate_completion() must expand --include-children-of with the filter
#   select(.state_type | IN("completed", "canceled") | not)
# which DROPPED completed (and canceled) children and kept only pending ones.
# Because bundle children are validated with the "bundle-child" role — which
# expects state "Done" — the exact children that should pass (completed ones)
# were silently omitted. A fully-Done bundle expanded to an EMPTY child list and
# validate-completion returned only the session-root result.
#
# The fix expands every non-canceled child: completed children ARE included and
# validate as Done/pass, still-pending children are included and fail, and
# canceled children are excluded (abandoned work can never be "Done").
#
# This drives the real linear.sh end-to-end with curl mocked (offline). It
# exercises three scenarios:
#   A. All children completed  -> children present + passing, all_ok true.
#   B. One child still pending -> child present + failing, all_ok false.
#   C. A canceled child        -> excluded from the expansion entirely.
#
# unguarded, scenario A fails (children CC-901/CC-902 omitted), scenario B fails
# (CC-912 omitted rather than reported failing), and scenario C's canceled child
# was already excluded (unchanged).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
git -C "$TMP_ROOT" init -q
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false
# Each command reads project configuration. Use the fixture's empty project
# instead of reloading the caller's settings for every issue and comment.
cd "$TMP_ROOT"

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
# Minimal Linear GraphQL mock. Dispatches on query kind + the issue identifier
# carried in variables. Emits "<json>___HTTP_CODE___200" like the real API.
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
vid="$(jq -r '.variables.id // .variables.issueId // ""' <<<"$payload")"

emit() { printf '%s___HTTP_CODE___200' "$1"; }

# A single-issue (non-bundle) GetIssue node.
# Args: identifier state_name state_type parent_identifier
single_issue() {
  local id="$1" sname="$2" stype="$3" parent="$4" parent_json="null" branch
  local description=null
  if [[ ( "$id" == CC-912 || "$id" == CC-942 ) && -n "${CHILD_CHECKLIST_FILE:-}" ]]; then
    description="$(jq -Rs . "$CHILD_CHECKLIST_FILE")"
    sname="${CHILD_STATE:-In Progress}"
    stype=started
    [[ "$sname" != Done ]] || stype=completed
  fi
  if [[ "$id" == CC-930 || "$id" == CC-940 ]]; then
    description='"## Done when\n- [x] Shared outcome\n  Evidence: holder read passed"'
  fi
  if [[ "$id" == CC-930 && -n "${CONTAINER_CHECKLIST_FILE:-}" ]]; then
    description="$(jq -Rs . "$CONTAINER_CHECKLIST_FILE")"
  fi
  branch="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  if [[ -n "$parent" ]]; then
    parent_json="{\"id\":\"uuid-$parent\",\"identifier\":\"$parent\",\"title\":\"parent\"}"
  fi
  emit "{\"data\":{\"issue\":{\"id\":\"uuid-$id\",\"identifier\":\"$id\",\"title\":\"$id\",\"description\":$description,\"state\":{\"name\":\"$sname\",\"type\":\"$stype\"},\"assignee\":null,\"project\":null,\"projectMilestone\":null,\"cycle\":null,\"team\":{\"name\":\"Claude\"},\"labels\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]},\"priority\":3,\"estimate\":null,\"sortOrder\":1.0,\"url\":\"https://linear.app/test/issue/$id\",\"branchName\":\"$branch\",\"createdAt\":\"2026-07-14T00:00:00Z\",\"updatedAt\":\"2026-07-14T00:00:00Z\",\"archivedAt\":null,\"trashed\":null,\"parent\":$parent_json,\"children\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]},\"relations\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]},\"inverseRelations\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]}}}}"
}

# A child node embedded in a bundle's children.nodes.
# Args: identifier state_name state_type parent_identifier
bundle_child() {
  local id="$1" sname="$2" stype="$3" parent="$4"
  if [[ ( "$id" == CC-912 || "$id" == CC-942 ) && -n "${CHILD_CHECKLIST_FILE:-}" ]]; then
    sname="${CHILD_STATE:-In Progress}"
    stype=started
    [[ "$sname" != Done ]] || stype=completed
  fi
  printf '{"id":"uuid-%s","identifier":"%s","title":"%s","description":null,"state":{"name":"%s","type":"%s"},"assignee":null,"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"priority":3,"estimate":null,"parent":{"identifier":"%s"},"relations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"inverseRelations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"children":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}' \
    "$id" "$id" "$id" "$sname" "$stype" "$parent"
}

# A bundle (GetIssueWithBundle) for a parent, given a pre-rendered
# comma-joined children.nodes array body. State defaults to the single-PR
# bundle's pre-merge In Review; container scenarios pass Todo/unstarted.
bundle_parent() {
  local id="$1" children="$2" sname="${3:-In Review}" stype="${4:-started}" branch description=null
  branch="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  if [[ "$id" == CC-930 && -n "${CONTAINER_CHECKLIST_FILE:-}" ]]; then
    description="$(jq -Rs . "$CONTAINER_CHECKLIST_FILE")"
  fi
  emit "{\"data\":{\"issue\":{\"id\":\"uuid-$id\",\"identifier\":\"$id\",\"title\":\"$id\",\"description\":$description,\"state\":{\"name\":\"$sname\",\"type\":\"$stype\"},\"assignee\":null,\"project\":null,\"projectMilestone\":null,\"cycle\":null,\"team\":{\"name\":\"Claude\"},\"labels\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]},\"priority\":3,\"estimate\":null,\"sortOrder\":1.0,\"url\":\"https://linear.app/test/issue/$id\",\"branchName\":\"$branch\",\"createdAt\":\"2026-07-14T00:00:00Z\",\"updatedAt\":\"2026-07-14T00:00:00Z\",\"archivedAt\":null,\"trashed\":null,\"parent\":null,\"relations\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]},\"inverseRelations\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]},\"children\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$children]}}}}"
}

comments_with_summary() {
  local response
  response="$(jq -cn --arg heading "${1:-Completion Summary}" '{data:{issue:{comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:"c1",body:("## " + $heading + "\n\nShipped."),createdAt:"2026-07-14T00:00:00Z",updatedAt:"2026-07-14T00:00:00Z",user:{name:"Test"}}]}}}}')" || return 1
  emit "$response"
}

comments_empty() {
  emit '{"data":{"issue":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'
}

if [[ "$query" == *"GetIssueWithBundle"* ]]; then
  case "$vid" in
  CC-900) bundle_parent CC-900 "$(bundle_child CC-901 Done completed CC-900),$(bundle_child CC-902 Done completed CC-900)" ;;
  CC-910)
    # Multi-child expansion is covered before the checklist matrix. Each
    # matrix row varies one child, so omit the already-proved Done sibling.
    if [[ -n "${CHILD_CHECKLIST_FILE:-}" ]]; then
      bundle_parent CC-910 "$(bundle_child CC-912 'In Progress' started CC-910)"
    else
      bundle_parent CC-910 "$(bundle_child CC-911 Done completed CC-910),$(bundle_child CC-912 'In Progress' started CC-910)"
    fi ;;
  CC-920) bundle_parent CC-920 "$(bundle_child CC-921 Done completed CC-920),$(bundle_child CC-922 Canceled canceled CC-920)" ;;
  CC-930)
    # The parent-checklist matrix needs one Done child to reach --container.
    # The earlier multi-child scenario retains both children.
    if [[ -n "${CONTAINER_CHECKLIST_FILE:-}" ]]; then
      bundle_parent CC-930 "$(bundle_child CC-931 Done completed CC-930)" Todo unstarted
    else
      bundle_parent CC-930 "$(bundle_child CC-931 Done completed CC-930),$(bundle_child CC-932 Done completed CC-930)" Todo unstarted
    fi ;;
  CC-940)
    if [[ -n "${CHILD_CHECKLIST_FILE:-}" ]]; then
      bundle_parent CC-940 "$(bundle_child CC-942 'In Progress' started CC-940)" Todo unstarted
    else
      bundle_parent CC-940 "$(bundle_child CC-941 Done completed CC-940),$(bundle_child CC-942 'In Progress' started CC-940)" Todo unstarted
    fi ;;
  CC-901) bundle_parent CC-901 "" Done completed ;;
  *) emit '{"errors":[{"message":"unknown bundle"}]}' ;;
  esac
elif [[ "$query" == *"ListComments"* ]]; then
  # Every issue except the canceled one carries a summary comment. Container
  # parents (CC-930/CC-940) have none: their summary is posted by `issues
  # complete` at completion time, after validation.
  case "$vid" in
  CC-912) if [[ "${CHILD_SUMMARY:-true}" == true ]]; then comments_with_summary; else comments_empty; fi ;;
  CC-922 | CC-930 | CC-940) comments_empty ;;
  CC-950) comments_with_summary 'Completion summary' ;;
  CC-951) comments_with_summary 'bUNDLE cOMPLETE' ;;
  *) comments_with_summary ;;
  esac
elif [[ "$query" == *"GetIssue"* ]]; then
  case "$vid" in
  CC-900) single_issue CC-900 'In Review' started "" ;;
  CC-901) single_issue CC-901 Done completed CC-900 ;;
  CC-902) single_issue CC-902 Done completed CC-900 ;;
  CC-910) single_issue CC-910 'In Review' started "" ;;
  CC-911) single_issue CC-911 Done completed CC-910 ;;
  CC-912) single_issue CC-912 'In Progress' started CC-910 ;;
  CC-920) single_issue CC-920 'In Review' started "" ;;
  CC-921) single_issue CC-921 Done completed CC-920 ;;
  CC-922) single_issue CC-922 Canceled canceled CC-920 ;;
  CC-930) single_issue CC-930 Todo unstarted "" ;;
  CC-931) single_issue CC-931 Done completed CC-930 ;;
  CC-932) single_issue CC-932 Done completed CC-930 ;;
  CC-940) single_issue CC-940 Todo unstarted "" ;;
  CC-941) single_issue CC-941 Done completed CC-940 ;;
  CC-942) single_issue CC-942 'In Progress' started CC-940 ;;
  CC-950 | CC-951) single_issue "$vid" 'In Review' started "" ;;
  *) emit '{"errors":[{"message":"unknown issue"}]}' ;;
  esac
else
  emit '{"errors":[{"message":"unexpected query"}]}'
fi
SH
chmod +x "$TMP_ROOT/bin/curl"

# The child table also exercises the supported compact display preference.
run_validate() {
  PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token \
    LINEAR_FORMAT="${RUN_FORMAT:-safe}" \
    "$BASH" "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" \
    issues validate-completion "$@"
}

check() {
  assert_jq "$1" "$2" "$3"
}

# --- Scenario A: all children completed ------------------------------
outA="$(run_validate CC-900 --include-children-of CC-900 2>/dev/null)"
check "A: three results (root + 2 completed children)" "$outA" \
  '(.results | length) == 3'
check "A: completed child CC-901 is PRESENT and passes as Done" "$outA" \
  '.results[] | select(.id == "CC-901") | .state == "Done" and .state_ok == true and .ok == true'
check "A: completed child CC-902 is PRESENT and passes as Done" "$outA" \
  '.results[] | select(.id == "CC-902") | .state == "Done" and .state_ok == true and .ok == true'
check "A: session-root CC-900 passes in its pre-merge In Review state" "$outA" \
  '.results[] | select(.id == "CC-900") | .state == "In Review" and .state_ok == true and .ok == true'
check "A: all_ok true when every child is Done" "$outA" '.all_ok == true'

# --- Scenario B: a still-pending child must still fail ----------------------
outB="$(run_validate CC-910 --include-children-of CC-910 2>/dev/null)"
check "B: three results (root + Done child + pending child)" "$outB" \
  '(.results | length) == 3'
check "B: Done child CC-911 passes" "$outB" \
  '.results[] | select(.id == "CC-911") | .ok == true'
check "B: pending child CC-912 is PRESENT and fails state_ok/ok" "$outB" \
  '.results[] | select(.id == "CC-912") | .state == "In Progress" and .state_ok == false and .ok == false'
check "B: all_ok false when a child is still pending" "$outB" '.all_ok == false'

# --- Scenario C: canceled children are excluded from the expansion ---------
outC="$(run_validate CC-920 --include-children-of CC-920 2>/dev/null)"
check "C: two results (root + only the Done child; canceled excluded)" "$outC" \
  '(.results | length) == 2'
check "C: Done child CC-921 passes" "$outC" \
  '.results[] | select(.id == "CC-921") | .ok == true'
check "C: canceled child CC-922 is NOT in results" "$outC" \
  '([.results[] | select(.id == "CC-922")] | length) == 0'
check "C: all_ok true (canceled child does not block)" "$outC" '.all_ok == true'

# --- Scenario D: container parent, all children Done (--container) ---------
# Containers close LAST: the parent never runs as a session, so at completion
# time it sits in an unstarted state with no pre-posted summary. With
# --container the root must validate cleanly on children-all-Done alone.
outD="$(run_validate CC-930 --include-children-of CC-930 --container 2>/dev/null)"
check "D: three results (container root + 2 Done children)" "$outD" \
  '(.results | length) == 3'
check "D: container root CC-930 passes in Todo without a summary" "$outD" \
  '.results[] | select(.id == "CC-930") | .state == "Todo" and .state_ok == true and .has_summary == false and .ok == true'
check "D: child CC-931 passes as Done" "$outD" \
  '.results[] | select(.id == "CC-931") | .ok == true'
check "D: child CC-932 passes as Done" "$outD" \
  '.results[] | select(.id == "CC-932") | .ok == true'
check "D: all_ok true — container may complete" "$outD" '.all_ok == true'

# --- Scenario E: container with a still-pending child must not complete ----
outE="$(run_validate CC-940 --include-children-of CC-940 --container 2>/dev/null)"
check "E: container root CC-940 itself passes state check" "$outE" \
  '.results[] | select(.id == "CC-940") | .state_ok == true'
check "E: pending child CC-942 fails" "$outE" \
  '.results[] | select(.id == "CC-942") | .state_ok == false and .ok == false'
check "E: all_ok false while a child is open" "$outE" '.all_ok == false'

# --- Scenario F: --container fails closed on misuse ------------------------
# The flag asserts "this bundle may complete now", so it must name exactly one
# target, pair with --include-children-of for that same target, and expand to
# at least one non-canceled child. A leaf or mismatched invocation is a caller
# error (nonzero exit), never a passing validation.
run_status rcF1 run_validate CC-901 --include-children-of CC-901 --container >/dev/null 2>&1
run_status rcF2 run_validate CC-930 --container >/dev/null 2>&1
run_status rcF3 run_validate CC-930 --include-children-of CC-910 --container >/dev/null 2>&1

assert_ne "F: leaf --container (bundle with no children) exits nonzero" "$rcF1" 0
assert_ne "F: --container without --include-children-of exits nonzero" "$rcF2" 0
assert_ne "F: --container with mismatched --include-children-of exits nonzero" "$rcF3" 0

# --- Preserve single-issue behavior (no --include-children-of) -------------
outS="$(run_validate CC-901 2>/dev/null)"
check "S: single-issue validate has exactly one result" "$outS" \
  '(.results | length) == 1 and .results[0].id == "CC-901"'

for summary_issue in CC-950 CC-951; do
  out="$(run_validate "$summary_issue" 2>/dev/null)"
  check "summary case: $summary_issue passes" "$out" \
    '.all_ok == true and (.results | length) == 1 and .results[0].has_summary == true'
done

# With every child Done, a container may close on its open child box, which
# the closer ticks, and on no holder read; any other open box keeps it open.
export CONTAINER_CHECKLIST_FILE="$TMP_ROOT/container-outcome.md"
while IFS='|' read -r name description expected child open; do
  printf '%b' "$description" >"$CONTAINER_CHECKLIST_FILE"
  out="$(run_validate CC-930 --include-children-of CC-930 --container 2>"$TMP_ROOT/outcome.err")"
  check "$name container outcome controls completion" "$out" ".all_ok == $expected and (.results[] | select(.id == \"CC-930\") | .child_box == $child and .container_open_boxes == $open and has(\"remedy\") == ($open != []))"
done <<'ROWS'
absent|No checklist|true|null|[]
empty|## Done when|true|null|[]
child-open|## Done when\n- [ ] Every child Done or cancelled|true|1|[]
child-proved|## Done when\n- [x] every child done or canceled.\n  Evidence: container-close read every child Done|true|1|[]
post-only|## Done when\n- [x] Post-merge: Read health; Where: service; Why after merge: deployment; Deadline: 2026-10-04T00:00:00Z\n  Evidence: holder read passed|true|null|[]
child-open-is|## Done when\n- [ ] Every child is Done or cancelled.|true|1|[]
child-words-continue|## Done when\n- [ ] Every child Done or cancelled and docs published|false|null|[1]
open|## Done when\n- [ ] Every child Done or cancelled\n- [ ] Shared outcome at source|false|1|[2]
missing-evidence|## Done when\n- [x] Shared outcome at source|false|null|[1]
proved|## Done when\n- [x] Shared outcome at source\n  Evidence: holder read passed|true|null|[]
ROWS

# The review audit's in-PR bundle root is one work item: --container refuses
# it from the safe read's in_pr_bundle, which its Filing record line sets.
printf '%b' '**In-PR bundle**: yes\n\n## Done when\n- [ ] Every child Done or cancelled' >"$CONTAINER_CHECKLIST_FILE"
run_status rcF4 run_validate CC-930 --include-children-of CC-930 --container >/dev/null 2>"$TMP_ROOT/in-pr.err"
assert_ne "F: --container on an in-PR bundle root exits nonzero" "$rcF4" 0
assert_jq "F: the in-PR refusal is the container fail-closed error" "$(cat "$TMP_ROOT/in-pr.err")" '.error | startswith("--container fail-closed:")'

# A template-produced child can finish its branch work before its shared PR
# merges. The parent accepts only qualified started children at that phase.
# Expansion above covers the command wiring. The state matrix calls its real
# result builder directly to avoid fetching the same parent for every row.
# Compact rows retain the CLI read, which must request the safe issue format.
# shellcheck source=../scripts/lib/issue-validation.sh
source "$SKILL_DIR/scripts/lib/issue-validation.sh"
export CHILD_CHECKLIST_FILE="$TMP_ROOT/child.md"
while IFS='|' read -r name format state description expected; do
  printf '%b' "$description" >"$CHILD_CHECKLIST_FILE"
  if [[ "$format" == compact ]]; then
    out="$(RUN_FORMAT="$format" CHILD_STATE="$state" run_validate CC-910 --include-children-of CC-910)"
    result="$(jq -c '.results[] | select(.id == "CC-912")' <<<"$out")"
    check "$name bundle aggregate follows child" "$out" ".all_ok == $expected"
  else
    state_type=started
    [[ "$state" != Done ]] || state_type=completed
    result="$(build_completion_validation_result CC-912 "$state" CC-910 true bundle-child "$state_type" "$(cat "$CHILD_CHECKLIST_FILE")")"
  fi
  check "$name child controls bundle acceptance" "$result" ".state == \"$state\" and .state_ok == $expected and .ok == $expected"
  if [[ "$state" != Done ]]; then
    result="$(build_completion_validation_result CC-942 "$state" CC-940 true container-child started "$(cat "$CHILD_CHECKLIST_FILE")")"
    check "$name started child keeps container open" "$result" '.state_ok == false and .ok == false'
  fi
done <<'ROWS'
qualified|safe|In Progress|## Done when\n- [x] branch proof\n  Evidence: branch test passed\n- [ ] Post-merge: Read health; Where: service; Why after merge: deployed release; Trigger: release owner/repo v*; Deadline: +24h|true
branch-only|safe|In Progress|## Done when\n- [x] branch proof\n  Evidence: branch test passed|true
branch-only-open|safe|In Progress|## Done when\n- [ ] branch proof|false
branch-only-missing-evidence|safe|In Progress|## Done when\n- [x] branch proof|false
review|safe|In Review|## Done when\n- [x] branch proof\n  Evidence: branch test passed\n- [ ] Post-merge: Read health; Where: service; Why after merge: deployed release; Trigger: release owner/repo v*; Deadline: +24h|true
custom-started|safe|In QA|## Done when\n- [x] branch proof\n  Evidence: branch test passed\n- [ ] Post-merge: Read health; Where: service; Why after merge: deployed release; Trigger: release owner/repo v*; Deadline: +24h|true
open-branch|safe|In Progress|## Done when\n- [ ] branch proof\n- [ ] Post-merge: Read health; Where: service; Why after merge: deployed release; Trigger: release owner/repo v*; Deadline: +24h|false
missing-evidence|safe|In Progress|## Done when\n- [x] branch proof\n- [ ] Post-merge: Read health; Where: service; Why after merge: deployed release; Trigger: release owner/repo v*; Deadline: +24h|false
invalid-post|safe|In Progress|## Done when\n- [x] branch proof\n  Evidence: branch test passed\n- [ ] Post-merge: health|false
empty|safe|In Progress|No checklist|false
early-verifying|safe|Verifying|## Done when\n- [x] branch proof\n  Evidence: branch test passed\n- [ ] Post-merge: Read health; Where: service; Why after merge: deployed release; Trigger: release owner/repo v*; Deadline: +24h|false
done-open-branch|safe|Done|## Done when\n- [ ] branch proof|false
done-missing-evidence|safe|Done|## Done when\n- [x] branch proof|false
compact-qualified|compact|In Progress|## Done when\n- [x] branch proof\n  Evidence: branch test passed\n- [ ] Post-merge: Read health; Where: service; Why after merge: deployed release; Trigger: release owner/repo v*; Deadline: +24h|true
compact-branch-only|compact|In Progress|## Done when\n- [x] branch proof\n  Evidence: branch test passed|true
compact-done-open-branch|compact|Done|## Done when\n- [ ] branch proof|false
compact-done-missing-evidence|compact|Done|## Done when\n- [x] branch proof|false
ROWS
printf '%b' '## Done when\n- [x] branch proof\n  Evidence: branch test passed\n- [ ] Post-merge: Read health; Where: service; Why after merge: deployed release; Trigger: release owner/repo v*; Deadline: +24h' >"$CHILD_CHECKLIST_FILE"
out="$(CHILD_SUMMARY=false run_validate CC-910 --include-children-of CC-910)"
check "started child still needs its summary" "$out" '.all_ok == false and (.results[] | select(.id == "CC-912") | .state_ok == true and .has_summary == false and .ok == false)'
out="$(CHILD_STATE=Verifying run_validate CC-912)"
check "Verifying remains invalid for a session root" "$out" '.all_ok == false and .results[0].state_ok == false'
