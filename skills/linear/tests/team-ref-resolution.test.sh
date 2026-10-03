#!/usr/bin/env bash
# The --team reference of cycles list, cycles create, issues create, labels
# create, statuses list and get, and the issues, projects and labels list
# filters, and the reference of teams get, resolve through resolve_team_id,
# which matches a team's key or its name: KEN and kendex send the same team id
# on each call site, a reference matching no team refuses as not found, and
# one team's key that is another team's name refuses as ambiguous. A team
# filter given an empty or dash-led value refuses before any request.

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
KENDEX_TEAM_ID=5c2e9f71-a4b8-4d36-91e0-7f3d6b2c8a15

# The stub answers a team lookup from the filter branches its query carries.
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload=$(sed -n 's/^data = //p' <<<"$(cat)" | jq -r)
query=$(jq -r '.query' <<<"$payload")
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
teams='[{"id":"5c2e9f71-a4b8-4d36-91e0-7f3d6b2c8a15","key":"KEN","name":"kendex"},
  {"id":"b81d4c95-2e6f-4a3b-8d17-c9e0a5f3b264","key":"ENG","name":"Platform"},
  {"id":"3f6b2a1e-8c4d-4e7a-9b05-6d2c1f8e4a73","key":"ENX","name":"ENG"}]'
case "$query" in
*"teams(filter:"*)
  key=false name=false
  [[ "$query" != *'{key: {eq: $name}}'* ]] || key=true
  [[ "$query" != *'{name: {eq: $name}}'* ]] || name=true
  jq -cj --argjson p "$payload" --argjson key "$key" --argjson name "$name" \
    '{data: {teams: {nodes: [.[] | select(($key and .key == $p.variables.name) or ($name and .name == $p.variables.name))]}}}' <<<"$teams"
  ;;
*"cycles(filter:"*) printf '%s' '{"data":{"cycles":{"nodes":[]}}}' ;;
*"cycleCreate("*) printf '%s' '{"data":{"cycleCreate":{"success":true,"cycle":{"id":"c1","number":1,"name":null,"startsAt":"","endsAt":"","team":{"name":"kendex"}}}}}' ;;
*"issueLabelCreate("*) printf '%s' '{"data":{"issueLabelCreate":{"success":true,"issueLabel":{"id":"l1","name":"n","color":"","isGroup":false,"parent":null}}}}' ;;
*"issueCreate("*) jq -cj '{data: {issueCreate: {success: true, issue: .issue}}}' "$FIXTURE_DIR/label-team-issue.json" ;;
*"issueUpdate("*) jq -cj '{data: {issueUpdate: {success: true, issue: .issue}}}' "$FIXTURE_DIR/label-team-issue.json" ;;
*"issue(id:"*)
  jq -cj --argjson team '{"id":"3f6b2a1e-8c4d-4e7a-9b05-6d2c1f8e4a73","name":"ENG"}' \
    '{data: {issue: (.issue + {team: $team})}}' "$FIXTURE_DIR/label-team-issue.json"
  ;;
*"workflowStates(filter:"*) printf '%s' '{"data":{"workflowStates":{"nodes":[{"id":"state-in-progress"}]}}}' ;;
*"issues(filter:"*) printf '%s' '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}' ;;
*"projects(filter:"*) printf '%s' '{"data":{"projects":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}' ;;
*"issueLabels(filter:"*) printf '%s' '{"data":{"issueLabels":{"nodes":[]}}}' ;;
*"team(id:"*) printf '%s' '{"data":{"team":{"id":"5c2e9f71-a4b8-4d36-91e0-7f3d6b2c8a15","name":"kendex","key":"KEN"}}}' ;;
*) printf '%s' '{"errors":[{"message":"unexpected fixture query"}]}' ;;
esac
printf '%s' '___HTTP_CODE___200'
SH
chmod +x "$PROJECT/bin/curl"

# Usage: run_team_ref NAME LINEAR-ARGS...
run_team_ref() {
  local name="$1"
  shift
  : >"$TMP_ROOT/$name.jsonl"
  (cd -- "$PROJECT" && env -i HOME="$TMP_ROOT" PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=stub LINEAR_TEAM=vsys KENDEX_USER_EMAIL= LINEAR_CACHE_ROOT="$PROJECT" \
    FIXTURE_DIR="$SKILL_DIR/tests/lib/fixtures" CURL_LOG="$TMP_ROOT/$name.jsonl" \
    "$BASH" "$PROJECT/.agents/skills/linear/scripts/linear.sh" "$@") \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
}

# Columns: call site | its arguments, REF standing for the team reference |
# the path of the team id in the request that follows the lookup.
while IFS='|' read -r site args path; do
  for ref in KEN kendex ghost; do
    # shellcheck disable=SC2086 # the arguments column is several words
    run_status rc run_team_ref "$site-$ref" ${args//REF/$ref}
    if [[ "$ref" == ghost ]]; then
      assert_file_contains "$site: ghost refuses as not found" "$TMP_ROOT/$site-$ref.err" "Team not found: ghost"
      assert_ne "$site: ghost exits nonzero" "$rc" 0
      assert "$site: ghost sends nothing past the team lookup" \
        jq -s -e 'length == 1 and (.[0].query | contains("teams(filter:"))' "$TMP_ROOT/$site-$ref.jsonl"
      continue
    fi
    assert_eq "$site: $ref succeeds" "$rc" 0
    assert "$site: $ref sends the kendex team id" \
      jq -s -e --arg team "$KENDEX_TEAM_ID" "last | $path == \$team" "$TMP_ROOT/$site-$ref.jsonl"
  done
done <<'ROWS'
cycles list|cycles list --team REF|.variables.filter.team.id.eq
cycles create|cycles create --team REF --start 2026-10-05 --end 2026-10-18|.variables.input.teamId
issues create|issues create --team REF --title Ref|.variables.input.teamId
labels create|labels create --team REF --name ref-label|.variables.input.teamId
teams get|teams get REF|.variables.id
statuses list|statuses list --team REF|.variables.filter.team.id.eq
statuses get|statuses get --team REF --name Todo|.variables.filter.team.id.eq
issues list|issues list --team REF|.variables.filter.team.id.eq
projects list|projects list --team REF|.variables.filter.accessibleTeams.some.id.eq
labels list|labels list --team REF|.variables.filter.team.id.eq
ROWS

# The team id merges into the state-name filter rather than replacing it.
assert "statuses get: KEN keeps the state name beside the team" \
  jq -s -e 'last | .variables.filter.name.eq == "Todo"' "$TMP_ROOT/statuses get-KEN.jsonl"

# A --team read filter given no team refuses before any request: an empty value
# would read every team, and a dash-led one is the next flag standing where the
# value belongs. Columns: call site | its arguments, VALUE standing for the
# --team value.
while IFS='|' read -r site args; do
  for value in "" --state; do
    case "$value" in
    "") kind=empty refusal="--team requires a non-empty team key or name" ;;
    *) kind=dash-led refusal='"--team requires a value"' ;;
    esac
    read -r -a argv <<<"$args"
    for i in "${!argv[@]}"; do
      [[ "${argv[$i]}" != VALUE ]] || argv[i]=$value
    done
    run_status rc run_team_ref "$site-$kind" "${argv[@]}"
    assert_ne "$site: $kind --team exits nonzero" "$rc" 0
    assert_file_contains "$site: $kind --team refuses naming the missing team" "$TMP_ROOT/$site-$kind.err" "$refusal"
    assert "$site: $kind --team sends no request" test ! -s "$TMP_ROOT/$site-$kind.jsonl"
  done
done <<'ROWS'
issues list|issues list --team VALUE
projects list|projects list --team VALUE
labels list|labels list --team VALUE
statuses list|statuses list --team VALUE
statuses get|statuses get --team VALUE --name Todo
ROWS

# The issue's team is named ENG, which is another team's key: its state
# resolves under the id the issue read carries, with no team lookup at all.
ENX_TEAM_ID=3f6b2a1e-8c4d-4e7a-9b05-6d2c1f8e4a73
run_status rc run_team_ref update-state issues update KEN-2413 --state "In Progress"
assert_eq "issues update --state: succeeds for a team named ENG" "$rc" 0
assert "issues update --state: sends no team lookup" \
  jq -s -e 'length > 0 and all(.query | contains("teams(filter:") | not)' "$TMP_ROOT/update-state.jsonl"
assert "issues update --state: resolves the state under the issue's own team id" \
  jq -s -e --arg team "$ENX_TEAM_ID" \
    'map(select(.query | contains("workflowStates(filter:"))) | length == 1 and .[0].variables.teamId == $team' \
    "$TMP_ROOT/update-state.jsonl"
assert "issues update --state: sends the resolved state id" \
  jq -s -e 'last | .variables.input.stateId == "state-in-progress"' "$TMP_ROOT/update-state.jsonl"

run_status rc run_team_ref ambiguous teams get ENG
assert_file_contains "ambiguous: ENG refuses naming both teams" "$TMP_ROOT/ambiguous.err" \
  "Ambiguous team: ENG matches Platform (key ENG) and ENG (key ENX)"
assert_ne "ambiguous: ENG exits nonzero" "$rc" 0
assert "ambiguous: ENG sends nothing past the team lookup" \
  jq -s -e 'length == 1 and (.[0].query | contains("teams(filter:"))' "$TMP_ROOT/ambiguous.jsonl"
