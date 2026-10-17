#!/usr/bin/env bash
# bash-runtime: 4
# `projects audit` against recorded Linear replies: each project map finding
# the Audit section of project-management references/project-map.md lists,
# one planted defect per row in a copy of a clean team that yields none, and
# its refusal of a map project Linear lacks or has twice live.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P)
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

# The clean team: a deliverable under its initiative and a standing area, both
# started, with every open kendex item in the deliverable. A closed item and
# another team's item, both outside the map, and another team's label named
# like the area reach a reply only when a filter is dropped. Project rows have
# the shape of lib/fixtures/recorded/projects-list.json.
CLEAN="$TMP_ROOT/clean-team.json"
cat >"$CLEAN" <<'JSON'
{"map": {"initiatives": [{"name": "Fixture Initiative", "outcome": "Fixture outcome.", "projects": ["Fixture Deliverable"]}],
  "projects": [
   {"name": "Fixture Deliverable", "kind": "deliverable", "initiative": "Fixture Initiative", "ends_when": "Fixture release ships.", "admits": "Fixture work."},
   {"name": "Fixture Area", "kind": "standing", "role": "area", "admits": "Fixture area work."}]},
 "taxonomy": {"categories": {"surface": {"labels": ["skills"]}, "classification": {"labels": ["bug"]}}},
 "projects": [
  {"id": "proj-deliverable", "name": "Fixture Deliverable", "state": "started", "targetDate": "2026-12-01", "teams": {"nodes": [{"id": "team-kendex"}]}},
  {"id": "proj-area", "name": "Fixture Area", "state": "started", "targetDate": null, "teams": {"nodes": [{"id": "team-kendex"}]}},
  {"id": "proj-off-map", "name": "Fixture Off Map", "state": "started", "targetDate": null, "teams": {"nodes": [{"id": "team-kendex"}]}}],
 "issues": [
  {"identifier": "KEN-1", "team": "team-kendex", "state": "started", "project": "Fixture Deliverable"},
  {"identifier": "KEN-2", "team": "team-kendex", "state": "unstarted", "project": "Fixture Deliverable"},
  {"identifier": "KEN-3", "team": "team-kendex", "state": "completed", "project": "Fixture Off Map"},
  {"identifier": "OTHER-1", "team": "team-other", "state": "started", "project": null},
  {"identifier": "KEN-4", "team": "team-kendex", "state": "backlog", "project": "Fixture Deliverable"}],
 "labels": [
  {"name": "skills", "team": {"id": "team-kendex"}},
  {"name": "bug", "team": null},
  {"name": "fixture-area", "team": {"id": "team-other"}}]}
JSON

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills/project-management" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
RENDER="$PROJECT/.agents/skills/project-management/SKILL.md"

# The stub applies each filter its request sends and serves two open issues
# per page.
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload=$(sed -n 's/^data = //p' | jq -r)
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query=$(jq -r '.query' <<<"$payload")
has() { [[ "$query" == *"$1"* ]] && echo true || echo false; }
case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"team-kendex"}]}}}' ;;
*"ProjectMap"*)
  jq -cj --argjson payload "$payload" --argjson scoped "$(has 'accessibleTeams: {some: {id: {eq: $teamId}}}')" '
    {data: {projects: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [.projects[]
      | select(.name | IN($payload.variables.names[]))
      | select(($scoped | not) or any(.teams.nodes[]; .id == $payload.variables.teamId))
      | {id, name, state, targetDate}]}}}' "$DATA" ;;
*"AuditMapIssues"*)
  jq -cj --argjson payload "$payload" \
    --argjson open "$(has 'state: {type: {nin: ["completed", "canceled"]}}')" \
    --argjson team "$(has 'team: {id: {eq: $teamId}}')" '
    .projects as $projects
    | [.issues[] | select(($open | not) or (.state | IN("completed", "canceled") | not))
      | select(($team | not) or .team == $payload.variables.teamId)
      | .project as $name
      | {identifier, project: (first($projects[] | select(.name == $name) | {id, name, state}) // null)}] as $rows
    | (if $payload.variables.after == null then
        {pageInfo: {hasNextPage: ($rows | length > 2), endCursor: "c1"}, nodes: $rows[:2]}
      else {pageInfo: {hasNextPage: false, endCursor: "c2"}, nodes: $rows[2:]} end)
    | {data: {issues: .}}' "$DATA" ;;
*"AuditMapLabels"*)
  jq -cj --argjson payload "$payload" \
    --argjson scoped "$(has 'or: [{team: {id: {eq: $teamId}}}, {team: {null: true}}]')" '
    {data: {issueLabels: {pageInfo: {hasNextPage: false, endCursor: null},
      nodes: [.labels[] | select(($scoped | not) or .team == null or .team.id == $payload.variables.teamId) | {name}]}}}' \
    "$DATA" ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected fixture query"}]}' ;;
esac
printf '%s' '___HTTP_CODE___200'
SH
chmod +x "$PROJECT/bin/curl"

# audit NAME PLANT — render the planted copy's map and taxonomy (a null map
# renders none), then run `projects audit` against its replies.
audit() {
  local name="$1" plant="$2" data="$TMP_ROOT/$1.json"
  jq "$plant" "$CLEAN" >"$data"
  {
    printf '%s\n' '# Project Management' '<!-- kendex:project-instructions:start -->' \
      '### Project taxonomy' '```json'
    jq -c '.taxonomy' "$data"
    printf '%s\n' '```'
    if jq -e '.map != null' "$data" >/dev/null; then
      printf '%s\n' '### Project map' '```json'
      jq -c '.map' "$data"
      printf '%s\n' '```'
    fi
    printf '%s\n' '<!-- kendex:project-instructions:end -->'
  } >"$RENDER"
  : >"$TMP_ROOT/$name.jsonl"
  (cd -- "$PROJECT" && env -i HOME="$TMP_ROOT" PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=stub LINEAR_TEAM=kendex DATA="$data" CURL_LOG="$TMP_ROOT/$name.jsonl" \
    "$BASH" "$PROJECT/.agents/skills/linear/scripts/linear.sh" projects audit) \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
}

# Each row plants one defect and names the findings it yields, in the
# audit's order; `^` separates the fields, since a plant is a jq program.
while IFS='^' read -r name plant findings; do
  run_status rc audit "$name" "$plant"
  assert_eq "$name: succeeds" "$rc" 0
  assert "$name: yields its findings" jq -e --argjson want "$findings" '.findings == $want' "$TMP_ROOT/$name.out"
done <<ROWS
outside-map^.issues += [{identifier: "KEN-9", team: "team-kendex", state: "started", project: "Fixture Off Map"}]^[{"kind": "outside-map", "issue": "KEN-9", "project": "Fixture Off Map"}]
no-project^.issues += [{identifier: "KEN-9", team: "team-kendex", state: "started", project: null}]^[{"kind": "no-project", "issue": "KEN-9"}]
initiative-holds-issue^.projects += [{id: "proj-initiative", name: "Fixture Initiative", state: "started", targetDate: null, teams: {nodes: [{id: "team-kendex"}]}}] | .issues += [{identifier: "KEN-9", team: "team-kendex", state: "started", project: "Fixture Initiative"}]^[{"kind": "initiative-holds-issue", "issue": "KEN-9", "initiative": "Fixture Initiative", "project": "Fixture Initiative"}]
label-like-project^.labels += [{name: "Fixture_Area", team: null}]^[{"kind": "name-collision", "label": "Fixture_Area", "map": {"level": "project", "name": "Fixture Area"}, "declared": false}]
project-like-label^.map.projects += [{name: "Bug", kind: "standing", role: "concern", admits: "Fixture defects."}] | .projects += [{id: "proj-bug", name: "Bug", state: "started", targetDate: null, teams: {nodes: [{id: "team-kendex"}]}}] | .labels += [{name: "BUG", team: {id: "team-kendex"}}]^[{"kind": "name-collision", "label": "BUG", "map": {"level": "project", "name": "Bug"}, "declared": true}]
initiative-like-label^.taxonomy.categories.surface.labels += ["fixture initiative"]^[{"kind": "name-collision", "label": "fixture initiative", "map": {"level": "initiative", "name": "Fixture Initiative"}, "declared": true}]
standing-completed^(.projects[] | select(.name == "Fixture Area") | .state) = "completed"^[{"kind": "standing-closed", "project": "Fixture Area", "state": "completed"}]
standing-canceled^(.projects[] | select(.name == "Fixture Area") | .state) = "canceled"^[{"kind": "standing-closed", "project": "Fixture Area", "state": "canceled"}]
standing-target-date^(.projects[] | select(.name == "Fixture Area") | .targetDate) = "2026-12-01"^[{"kind": "standing-target-date", "project": "Fixture Area", "target_date": "2026-12-01"}]
deliverable-no-ends-when^del(.map.projects[0].ends_when)^[{"kind": "deliverable-no-ends-when", "project": "Fixture Deliverable"}]
deliverable-canceled^(.projects[] | select(.name == "Fixture Deliverable") | .state) = "canceled"^[{"kind": "closed-project-item", "issue": "KEN-1", "project": "Fixture Deliverable", "state": "canceled"}, {"kind": "closed-project-item", "issue": "KEN-2", "project": "Fixture Deliverable", "state": "canceled"}, {"kind": "closed-project-item", "issue": "KEN-4", "project": "Fixture Deliverable", "state": "canceled"}, {"kind": "deliverable-canceled", "project": "Fixture Deliverable"}]
closed-project-item^.map.projects += [{name: "Fixture Done", kind: "deliverable", ends_when: "Fixture shipped.", admits: "Fixture done work."}] | .projects += [{id: "proj-done", name: "Fixture Done", state: "completed", targetDate: null, teams: {nodes: [{id: "team-kendex"}]}}] | .issues += [{identifier: "KEN-9", team: "team-kendex", state: "started", project: "Fixture Done"}]^[{"kind": "closed-project-item", "issue": "KEN-9", "project": "Fixture Done", "state": "completed"}]
map-absent^.map = null^[{"kind": "map-absent", "map": "$RENDER"}]
ROWS

run_status rc audit clean .
assert_eq "clean: succeeds" "$rc" 0
assert "clean: yields no finding" jq -e '.findings == []' "$TMP_ROOT/clean.out"
assert "clean: skips closed issues" jq -e 'all(.findings[]; .issue != "KEN-3")' "$TMP_ROOT/clean.out"
assert "clean: reads only the team's issues" jq -e 'all(.findings[]; .issue != "OTHER-1")' "$TMP_ROOT/clean.out"
assert "clean: reads only the team's and workspace labels" \
  jq -e 'all(.findings[]; .label != "fixture-area")' "$TMP_ROOT/clean.out"
assert "clean: lists each map project's id" \
  jq -e '[.projects[] | {name, id}] == [{name: "Fixture Deliverable", id: "proj-deliverable"}, {name: "Fixture Area", id: "proj-area"}]' \
  "$TMP_ROOT/clean.out"
assert "map-absent: names the render it read" jq -e --arg render "$RENDER" '.map == $render' "$TMP_ROOT/map-absent.out"
assert_not "map-absent: no request is sent" test -s "$TMP_ROOT/map-absent.jsonl"

# A map project with no Linear project in the team, or with two live ones,
# leaves the map unjudgeable: the audit refuses, keyed, and prints nothing.
while IFS='^' read -r name plant key; do
  run_status rc audit "$name" "$plant"
  assert_ne "$name: refused" "$rc" 0
  assert_file_contains "$name: the refusal is keyed" "$TMP_ROOT/$name.err" "$key"
  assert_not "$name: prints no findings" test -s "$TMP_ROOT/$name.out"
done <<ROWS
declared-missing^.projects |= map(select(.name != "Fixture Area"))^linear-projects: declared-missing project=Fixture Area map=$RENDER
ambiguous^.projects += [.projects[] | select(.name == "Fixture Area") | .id = "proj-area-twin"]^linear-projects: ambiguous project=Fixture Area map=$RENDER
ROWS
