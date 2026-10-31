#!/usr/bin/env bash
# bash-runtime: 4
# The cross-team guard: an issue create and a field change to an existing
# issue land only in the checkout's own team, LINEAR_TEAM. Every lane writes
# with one app token that Linear lets write in every team, so the guard in
# linear.sh is what keeps a lane out of another team's issues.
#
# One table. A row names the configured team, the command, and what it left
# behind, rendered as one line: the exit status, `calls=0` where nothing may
# be sent, the mutations sent in order, and the guard's first stderr line, `-`
# for none.
#
# Fixture teams: KEN (named kendex) and VGS (named vsys), each also reachable
# by its team UUID, and OPS, named VGS, so that a LINEAR_TEAM of VGS is one
# team's key and another's name. KEN-1 and VGS-1 are one issue in KEN and VGS,
# also reachable by their UUIDs. OWN-7 resolves to the current team named
# by ALIAS_TEAM, including OTHER after a move out of OWN.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P)
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
KEN_UUID=9c8d7e6f-5a4b-4c3d-9e2f-1a0b9c8d7e6f
VGS_UUID=0b5f6c1e-2d3a-4b7c-8e9f-1a2b3c4d5e6f
KEN_TEAM_UUID=1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d
VGS_TEAM_UUID=6a5b4c3d-2e1f-4a0b-9c8d-7e6f5a4b3c2d
# An issue whose read fails: Linear answers it with an error.
DEAD_UUID=ffffffff-ffff-4fff-8fff-ffffffffffff

cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload=$(sed -n 's/^data = //p' <<<"$(cat)" | jq -r)
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
jq -cj --arg alias_team "${ALIAS_TEAM:?}" '
  def page($nodes): {pageInfo: {hasNextPage: false, endCursor: null}, nodes: $nodes};
  def teams: [
    {id: "1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d", key: "KEN", name: "kendex"},
    {id: "6a5b4c3d-2e1f-4a0b-9c8d-7e6f5a4b3c2d", key: "VGS", name: "vsys"},
    {id: "4e3d2c1b-0a9f-4e8d-b7c6-5a4b3c2d1e0f", key: "OPS", name: "VGS"},
    {id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", key: "OWN", name: "own"},
    {id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", key: "OTHER", name: "other"}];
  def issue($ref):
    ($ref | ascii_upcase) as $r
    | (if $r == "OWN-7" then
         {team: (teams[] | select(.key == $alias_team)), identifier: ($alias_team + "-7"),
          id: "77777777-7777-4777-8777-777777777777"}
       elif ($r | startswith("VGS")) or $r == "0B5F6C1E-2D3A-4B7C-8E9F-1A2B3C4D5E6F"
       then {team: teams[1], identifier: "VGS-1", id: "0b5f6c1e-2d3a-4b7c-8e9f-1a2b3c4d5e6f"}
       else {team: teams[0], identifier: "KEN-1", id: "9c8d7e6f-5a4b-4c3d-9e2f-1a0b9c8d7e6f"} end) as $i
    | {id: $i.id, identifier: $i.identifier, title: "t", description: "", url: ("https://linear.app/x/issue/" + $i.identifier),
       branchName: "b", state: {name: "Todo", type: "unstarted"}, assignee: null, project: null,
       projectMilestone: null, cycle: null, parent: null, team: $i.team, priority: 3, estimate: null,
       sortOrder: 1.0, createdAt: "2026-10-05T00:00:00Z", updatedAt: "2026-10-05T00:00:00Z",
       archivedAt: null, trashed: null, labels: page([]), children: page([]), comments: page([]),
       relations: page([{id: "a7b6c5d4-e3f2-4a1b-9c0d-8e7f6a5b4c3d", type: "related",
         relatedIssue: {id: "x", identifier: (if $i.identifier == "KEN-1" then "VGS-1" else "KEN-1" end),
           title: "t", state: {name: "Todo", type: "unstarted"}}}]),
       inverseRelations: page([])};
  .query as $q | (.variables // {}) as $v
  | if ($q | test("^\\s*mutation")) then
      ($q | capture("\\{\\s*(?<f>[A-Za-z]+)").f) as $f
      | {data: {($f): ({success: true}
          + if $f == "issueUpdate" or $f == "issueCreate" then {issue: issue("KEN-1")}
            elif $f == "commentCreate" then {comment: {id: "c1", body: "b", createdAt: "2026-10-05T00:00:00Z", user: {name: "t"}}}
            elif $f == "issueRelationCreate" then {issueRelation: {id: "r1", type: "related"}}
            elif $f == "issueArchive" or $f == "issueDelete" then
              {entity: {id: "9c8d7e6f-5a4b-4c3d-9e2f-1a0b9c8d7e6f", identifier: "KEN-1", url: "u",
                archivedAt: "2026-10-05T00:00:00Z", trashed: true}}
            else {} end)}}
    elif ($q | contains("RelationBlocker")) then
      {data: {issueRelation: {type: "related", issue: issue("VGS-1"), relatedIssue: issue("KEN-1")}}}
    elif ($q | contains("ValidateBlocking")) then
      {data: {issue1: issue($v.id1), issue2: issue($v.id2)}}
    elif ($q | contains("teams(filter: {id: {eq:")) then
      {data: {teams: page([teams[] | select(.id == $v.name)])}}
    elif ($q | contains("teams(filter:")) then
      {data: {teams: page([teams[] | select(.key == $v.name or .name == $v.name)])}}
    elif ($q | contains("issue(id:")) and ($v.id == "ffffffff-ffff-4fff-8fff-ffffffffffff" or $v.id == "DEAD-7") then
      {errors: [{message: "issue service unavailable"}]}
    elif ($q | contains("issue(id:")) then {data: {issue: issue($v.id)}}
    elif ($q | contains("issueLabels(filter:")) then {data: {issueLabels: page([{id: "label-uuid"}])}}
    elif ($q | contains("workflowStates(filter:")) then {data: {workflowStates: page([{id: "state-uuid"}])}}
    else {errors: [{message: "unexpected fixture query"}]} end' <<<"$payload"
printf '%s' '___HTTP_CODE___200'
SH
chmod +x "$PROJECT/bin/curl"

# run TEAM CALLS ALIAS_TEAM ARGS...: one command, rendered as one line.
# TEAM is the LINEAR_TEAM the settings file declares, `-` for none. CALLS `-`
# leaves the call count out of the line.
run() {
  local team="$1" calls="$2" alias_team="$3" rc=0 writes guard
  shift 3
  if [[ "$team" == - ]]; then
    rm -f "$PROJECT/kendex.settings.toml"
  else
    printf '[env]\nLINEAR_TEAM = "%s"\n' "$team" >"$PROJECT/kendex.settings.toml"
  fi
  : >"$CURL_LOG"
  (cd -- "$PROJECT" && env -i HOME="$TMP_ROOT" PATH="$PROJECT/bin:$PATH" \
    ALIAS_TEAM="$alias_team" LINEAR_API_KEY_OVERRIDE=stub KENDEX_USER_EMAIL= LINEAR_REQUIRE_REACH= CURL_LOG="$CURL_LOG" \
    "$BASH" "$LINEAR" "$@") >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?
  writes=$(jq -r 'select(.query | test("^\\s*mutation")) | .query | capture("\\{\\s*(?<f>[A-Za-z]+)").f' "$CURL_LOG" | paste -sd, -)
  guard=$(grep -m1 -E '^linear: (refused=cross-team|cross-team-guard=)' "$TMP_ROOT/err" || true)
  [[ "$calls" == - ]] || calls=$(wc -l <"$CURL_LOG" | tr -d ' ')
  printf 'rc=%s calls=%s writes=%s guard=%s' "$rc" "$calls" "${writes:--}" "${guard:--}"
}

refused() { # ACTION ISSUE TEAM OWN — the keyed refusal line
  printf 'linear: refused=cross-team action=%s%s team=%s own-team=%s route=peer-mail' "$1" "${2:+ issue=$2}" "$3" "$4"
}

# label|team|calls|args|rc|writes|guard|alias_team
# calls is 0 where the command must refuse before any request, or `-` where
# the count is not asserted: how many reads a command spends is no result.
# alias_team sets OWN-7's current team, OTHER by default. guard is
# `-`, `inactive ACTION`, `unread ACTION ISSUE`, or `refused ACTION ISSUE
# TEAM OWN` (ISSUE `-` for a create), or `error TEXT` for no guard line and
# TEXT on stderr, the cause of a refusal before or inside the guard.
ROWS='
update of another team issue is refused before any write|KEN|-|issues update VGS-1 --state Done|1|-|refused update VGS-1 VGS KEN
a lowercase identifier is judged by its team key|KEN|-|issues update vgs-1 --title t|1|-|refused update vgs-1 VGS KEN
bulk-update with one foreign issue writes nothing|KEN|-|issues bulk-update KEN-1 VGS-1 --state Done|1|-|refused bulk-update VGS-1 VGS KEN
activate of another team issue is refused|KEN|-|issues activate VGS-1 --agent runtime|1|-|refused activate VGS-1 VGS KEN
block of another team issue is refused|KEN|-|issues block VGS-1 --by KEN-1|1|-|refused block VGS-1 VGS KEN
unblock of another team issue is refused|KEN|-|issues unblock VGS-1|1|-|refused unblock VGS-1 VGS KEN
complete of another team issue is refused|KEN|-|issues complete VGS-1|1|-|refused complete VGS-1 VGS KEN
archive of another team issue is refused|KEN|-|issues archive VGS-1|1|-|refused archive VGS-1 VGS KEN
trash of another team issue is refused|KEN|-|issues trash VGS-1|1|-|refused trash VGS-1 VGS KEN
delete of another team issue is refused as trash|KEN|-|issues delete VGS-1|1|-|refused trash VGS-1 VGS KEN
an issue named by UUID is read for its team and refused|KEN|-|issues update VGS_UUID --state Done|1|-|refused update VGS_UUID VGS KEN
an issue whose team cannot be read is refused|KEN|-|issues update DEAD_UUID --title t|1|-|unread update DEAD_UUID
a configured team that matches no team refuses the write|ghost|-|issues update VGS-1 --title t|1|-|error Team not found: ghost
a configured team that is one team key and another team name refuses an update with that prefix|VGS|-|issues update VGS-1 --title t|1|-|error Ambiguous team: VGS matches
an unreadable attach path refuses before the guard reads the team|kendex|0|issues update KEN-1 --attach /nonexistent/file.png|1|-|error --attach path not readable
bulk-update refuses an unreadable attach path before the guard reads the team|kendex|0|issues bulk-update KEN-1 KEN-2 --attach /nonexistent/file.png|1|-|error --attach path not readable
a team configured by name resolves to its key and refuses|kendex|-|issues update VGS-1 --state Done|1|-|refused update VGS-1 VGS KEN
create in another team is refused|KEN|-|issues create --team vsys --title t|1|-|refused create - VGS KEN
create in another team named by UUID is refused|KEN|-|issues create --team VGS_TEAM_UUID --title t|1|-|refused create - VGS KEN
update of an own team issue resolves the configured team and writes|KEN|-|issues update KEN-1 --title t|0|issueUpdate|-
an own team issue named by UUID passes|KEN|-|issues update KEN_UUID --title t|0|issueUpdate|-
an own team issue passes with the team configured by name|kendex|-|issues update KEN-1 --title t|0|issueUpdate|-
an own team issue passes with the team configured by UUID|KEN_TEAM_UUID|-|issues update KEN-1 --title t|0|issueUpdate|-
bulk-update of own team issues writes each|KEN|-|issues bulk-update KEN-1 KEN-2 --title t|0|issueUpdate,issueUpdate|-
bulk-update passes with the team configured by name|kendex|-|issues bulk-update KEN-1 KEN-2 --title t|0|issueUpdate,issueUpdate|-
archive of a moved identifier is refused|OWN|-|issues archive OWN-7|1|-|refused archive OWN-7 OTHER OWN
trash of a moved identifier is refused|OWN|-|issues trash OWN-7|1|-|refused trash OWN-7 OTHER OWN
archive of an unchanged identifier passes|OWN|-|issues archive OWN-7|0|issueArchive|-|OWN
an identifier whose team cannot be read is refused|OWN|-|issues archive DEAD-7|1|-|unread archive DEAD-7
bulk-update of a repeated identifier writes each time|KEN|-|issues bulk-update KEN-1 KEN-2 KEN-1 --title t|0|issueUpdate,issueUpdate,issueUpdate|-
archive of an own team issue passes|KEN|-|issues archive KEN-1|0|issueArchive|-
trash of an own team issue passes|KEN|-|issues trash KEN-1|0|issueDelete|-
create under the own team by another spelling passes|kendex|-|issues create --team KEN --title t|0|issueCreate|-
block of an own team issue by another team issue passes|KEN|-|issues block KEN-1 --by VGS-1|0|issueUpdate,issueRelationCreate,commentCreate|-
comments create on another team issue passes|KEN|-|comments create VGS-1 --body hello|0|commentCreate|-
add-relation from another team issue passes|KEN|-|issues add-relation VGS-1 --related KEN-1|0|issueRelationCreate|-
remove-relation from another team issue passes|KEN|-|issues remove-relation VGS-1 --related KEN-1|0|issueRelationDelete|-
get of another team issue passes|KEN|-|issues get VGS-1 --format raw|0|-|-
with no team configured the guard is inactive and the update passes|-|-|issues update VGS-1 --title t|0|issueUpdate|inactive update
'

while IFS='|' read -r label team calls args rc writes guard alias_team; do
  [ -n "$label" ] || continue
  cause=""
  alias_team=${alias_team:-OTHER}
  team=${team//KEN_TEAM_UUID/$KEN_TEAM_UUID}
  args=${args//VGS_UUID/$VGS_UUID}
  args=${args//KEN_UUID/$KEN_UUID}
  args=${args//DEAD_UUID/$DEAD_UUID}
  args=${args//VGS_TEAM_UUID/$VGS_TEAM_UUID}
  guard=${guard//VGS_UUID/$VGS_UUID}
  guard=${guard//DEAD_UUID/$DEAD_UUID}
  read -r -a argv <<<"$args"
  case "$guard" in
  refused\ *)
    read -r -a g <<<"${guard#refused }"
    [[ "${g[1]}" != - ]] || g[1]=""
    guard=$(refused "${g[@]}")
    ;;
  inactive\ *) guard="linear: cross-team-guard=inactive action=${guard#inactive } cause=no-team" ;;
  unread\ *)
    read -r -a g <<<"${guard#unread }"
    guard="linear: refused=cross-team-unread action=${g[0]} issue=${g[1]}"
    ;;
  error\ *) cause="${guard#error }" guard=- ;;
  esac
  expected="rc=$rc calls=$calls writes=$writes guard=$guard"
  assert_eq "$label" "$(run "$team" "$calls" "$alias_team" "${argv[@]}")" "$expected"
  [[ -z "$cause" ]] || assert_file_contains "$label" "$TMP_ROOT/err" "$cause"
done <<<"$ROWS"
