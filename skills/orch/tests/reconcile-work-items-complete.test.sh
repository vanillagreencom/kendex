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
for id in T-1 T-2; do
  printf '%s' "$desc" >"$TMP_ROOT/descriptions/$id"
done
for id in T-1 T-2; do
  jq -n --arg d "$desc" --arg id "$id" \
    '{id: ("uuid-" + $id), identifier: $id, title: "t", state: {name: "In Review", type: "started"}, updatedAt: "2026-07-14T00:00:00Z", parent: null, description: $d, trashed: false, archivedAt: null}' \
    >"$TMP_ROOT/state/$id.json"
done

# The issue read answers with the issue's description file; the update
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
*"workflowStates(filter:"*)
  printf '%s' '{"data":{"workflowStates":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"state-done"}]}}}'
  ;;
*"issue(id:"*)
  jq -cjn --rawfile d "$DESCRIPTIONS/$id" --arg id "$id" '{data:{issue:{id:("uuid-" + $id),identifier:$id,title:"t",description:$d,state:{name:"In Review",type:"started"},team:{id:"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47",name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},project:null,parent:null,children:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}'
  ;;
*"issueUpdate(id:"*)
  response="$(jq -c --rawfile d "$DESCRIPTIONS/$id" --arg id "$id" '{data:{issueUpdate:{success:true,issue:{id:("uuid-" + $id),identifier:$id,title:"t",description:(.variables.input.description // $d),state:{name:"Done",type:"completed"},parent:null,team:{name:"Claude"},labels:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},updatedAt:"2026-07-14T00:00:01Z",archivedAt:null,trashed:null,relations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]},inverseRelations:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}}}}}' <<<"$payload")"
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

complete() { # ID MET
  (cd "$R" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam DESCRIPTIONS="$TMP_ROOT/descriptions" STATE="$TMP_ROOT/state" \
    "$BASH" "$R/.agents/skills/linear/scripts/linear.sh" issues complete "$1" --done-when-met "$2")
}

RC=0
complete T-1 all >"$TMP_ROOT/t1.out" 2>"$TMP_ROOT/t1.err" || RC=$?
assert_eq "$RC" 0 "the fully met item completes" "$TMP_ROOT/t1.err"
RC=0
complete T-2 1 >"$TMP_ROOT/t2.out" 2>"$TMP_ROOT/t2.err" || RC=$?
assert_eq "$RC" 0 "the partly met item completes" "$TMP_ROOT/t2.err"
assert_eq "$(jq -rs '[.[] | select(.state.type == "completed") | .identifier] | sort | join(",")' "$TMP_ROOT"/state/*.json)" \
  "T-1,T-2" "both completions reach the tracker the sweep reads"

OUT=""
RC=0
OUT="$(cd "$R" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" LINEAR_API_KEY_OVERRIDE=test-token \
  DESCRIPTIONS="$TMP_ROOT/descriptions" STATE="$TMP_ROOT/state" "$RW" 2>&1)" || RC=$?
assert_eq "$RC" 1 "the sweep reports a finding"
assert_not_contains "$OUT" "issue=T-1" "a fully met completion leaves no done-unchecked finding"
assert_contains "$OUT" "done-unchecked issue=T-2" "a partly met completion is still done-unchecked"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
