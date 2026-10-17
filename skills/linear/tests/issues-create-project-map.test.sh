#!/usr/bin/env bash
# bash-runtime: 4
# The project map refusals the Routing section of the project-management
# skill's references/project-map.md states, driven against recorded Linear
# replies: under a declared map a create names a map
# project, and create, update --project and bulk-update --project place an
# issue only in a map project with one live Linear project in the team. With
# no map the commands keep their behaviour.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P)
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

KENDEX=5c2e9f71-a4b8-4d36-91e0-7f3d6b2c8a15
OTHER=3f6b2a1e-8c4d-4e7a-9b05-6d2c1f8e4a73
DELIVERABLE=00000000-0000-4000-8000-000000000201
AREA=00000000-0000-4000-8000-000000000202
OFF_MAP=00000000-0000-4000-8000-000000000203

# Linear's projects, in the row shape of lib/fixtures/recorded/projects-list.json:
# both map projects and one off the map in the kendex team, and the one map
# project kendex lacks in another team, so only the team filter keeps it out.
PROJECTS="$TMP_ROOT/projects.json"
cat >"$PROJECTS" <<JSON
[{"id": "$DELIVERABLE", "name": "Fixture Deliverable", "state": "started", "targetDate": null, "teams": {"nodes": [{"id": "$KENDEX"}]}},
 {"id": "$AREA", "name": "Fixture Area", "state": "started", "targetDate": null, "teams": {"nodes": [{"id": "$KENDEX"}]}},
 {"id": "$OFF_MAP", "name": "Fixture Off Map", "state": "started", "targetDate": null, "teams": {"nodes": [{"id": "$KENDEX"}]}},
 {"id": "00000000-0000-4000-8000-000000000204", "name": "Fixture Missing", "state": "started", "targetDate": null, "teams": {"nodes": [{"id": "$OTHER"}]}}]
JSON

MAP='{"initiatives": [{"name": "Fixture Initiative", "outcome": "Fixture outcome.", "projects": ["Fixture Deliverable"]}],
 "projects": [
  {"name": "Fixture Deliverable", "kind": "deliverable", "initiative": "Fixture Initiative", "ends_when": "Fixture release ships.", "admits": "Fixture work."},
  {"name": "Fixture Area", "kind": "standing", "role": "area", "admits": "Fixture area work."},
  {"name": "Fixture Missing", "kind": "standing", "role": "concern", "admits": "Fixture concern work."}]}'

# make_project DIR KIND — a repository with this skill and, by KIND, the
# rendered project-management SKILL.md: declared (the map above), none (no
# map heading), no-json (the heading with no JSON block), invalid (a standing
# project with an ends_when) or differ (the map in .agents/skills and none in
# .claude/skills). Its curl answers ProjectMap and
# GetProject from the projects above, applying only the filters the request
# sends, and every other request from the recorded issue and labels.
make_project() {
  local project="$1" kind="$2" render
  mkdir -p "$project/.agents/skills/project-management"
  git -C "$project" init -q -b main
  git -C "$project" config gc.auto 0
  git -C "$project" config maintenance.auto false
  cp -R "$SKILL_DIR" "$project/.agents/skills/linear"
  install_label_team_fixture "$project"
  mv -- "$project/bin/curl" "$project/bin/curl-recorded"
  cat >"$project/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
query=$(jq -r '.query' <<<"$payload")
case "$query" in
*"ProjectMap"* | *"GetProject"*)
  printf '%s\n' "$payload" >>"${CURL_LOG:?}"
  scoped=false
  [[ "$query" != *'accessibleTeams: {some: {id: {eq: $teamId}}}'* ]] || scoped=true
  jq -cj --argjson payload "$payload" --argjson scoped "$scoped" '
    {data: {projects: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [.[]
      | select(.name | IN(($payload.variables.names // [$payload.variables.name])[]))
      | select(($scoped | not) or any(.teams.nodes[]; .id == $payload.variables.teamId))
      | {id, name, state, targetDate}]}}}' "$PROJECTS"
  printf '%s' '___HTTP_CODE___200'
  ;;
*) exec "${0%/*}/curl-recorded" "$@" <<<"$config" ;;
esac
SH
  chmod +x "$project/bin/curl"
  render="$project/.agents/skills/project-management/SKILL.md"
  case "$kind" in
  declared | differ)
    printf '%s\n' '# Project Management' '<!-- kendex:project-instructions:start -->' \
      '### Project map' '' 'Prose before the contract.' '' '```json' "$MAP" '```' \
      '<!-- kendex:project-instructions:end -->' >"$render"
    ;;
  none)
    printf '%s\n' '# Project Management' '<!-- kendex:project-instructions:start -->' \
      '### Other' '```json' '{}' '```' '<!-- kendex:project-instructions:end -->' >"$render"
    ;;
  no-json)
    printf '%s\n' '<!-- kendex:project-instructions:start -->' '### Project map' \
      'Projects are prose here.' '<!-- kendex:project-instructions:end -->' >"$render"
    ;;
  invalid)
    printf '%s\n' '<!-- kendex:project-instructions:start -->' '### Project map' '```json' \
      "$(jq -c '.projects[1].ends_when = "Never."' <<<"$MAP")" '```' \
      '<!-- kendex:project-instructions:end -->' >"$render"
    ;;
  *) assert_stop "make_project: unknown kind $kind" ;;
  esac
  if [[ "$kind" == differ ]]; then
    mkdir -p "$project/.claude/skills/project-management"
    printf '%s\n' '# Project Management' >"$project/.claude/skills/project-management/SKILL.md"
  fi
}

for kind in declared none no-json invalid differ; do
  make_project "$TMP_ROOT/$kind" "$kind"
done
RENDER=.agents/skills/project-management/SKILL.md

# Each row runs one command, its arguments split on `;`; a leading NAME=VALUE
# argument sets that variable for the run. A refused row sends no issue write;
# an accepted one sends its mutation with the project id the row names, or
# none, and WANT_READS ProjectMap reads (`-` skips the count).
while IFS='|' read -r name kind want key mutation project_id reads args; do
  IFS=';' read -ra argv <<<"$args"
  run_status rc run_label_team_request "$TMP_ROOT/$kind" "$name" "" PROJECTS="$PROJECTS" "${argv[@]}"
  log="$TMP_ROOT/$name.jsonl"
  if [[ "$want" == refused ]]; then
    assert_ne "$name: refused" "$rc" 0
    assert_file_contains "$name: the refusal is keyed" "$TMP_ROOT/$name.err" "$key"
    assert_not "$name: no write is sent" grep -qE 'issueCreate|issueUpdate|fileUpload' "$log"
  else
    assert_eq "$name: accepted" "$rc" 0
    assert "$name: the write carries the map project" jq -se --arg m "$mutation" --arg id "$project_id" '
      map(select(.query | contains($m + "(")) | .variables.input.projectId // "")
      | length > 0 and all(. == $id)' "$log"
  fi
  if [[ "$reads" != - ]]; then
    assert_eq "$name: map reads" "$(grep -c ProjectMap "$log" || :)" "$reads"
  fi
done <<ROWS
create-no-project|declared|refused|linear-projects: project-missing map=$TMP_ROOT/declared/$RENDER|||0|create;--title;T;--no-agent-label
create-off-map|declared|refused|linear-projects: off-map project=Fixture Off Map map=$TMP_ROOT/declared/$RENDER|||0|create;--title;T;--no-agent-label;--project;Fixture Off Map
create-off-map-uuid|declared|refused|linear-projects: off-map project=$OFF_MAP map=$TMP_ROOT/declared/$RENDER|||1|create;--title;T;--no-agent-label;--project;$OFF_MAP
create-deliverable|declared|accepted||issueCreate|$DELIVERABLE|1|create;--title;T;--no-agent-label;--project;Fixture Deliverable
create-standing|declared|accepted||issueCreate|$AREA|1|create;--title;T;--no-agent-label;--project;Fixture Area
create-standing-uuid|declared|accepted||issueCreate|$AREA|1|create;--title;T;--no-agent-label;--project;$AREA
create-missing|declared|refused|linear-projects: declared-missing project=Fixture Missing map=$TMP_ROOT/declared/$RENDER|||1|create;--title;T;--no-agent-label;--project;Fixture Missing
update-off-map|declared|refused|linear-projects: off-map project=Fixture Off Map map=$TMP_ROOT/declared/$RENDER|||0|update;KEN-2413;--project;Fixture Off Map
update-off-map-uuid|declared|refused|linear-projects: off-map project=$OFF_MAP map=$TMP_ROOT/declared/$RENDER|||1|update;KEN-2413;--project;$OFF_MAP
update-on-map|declared|accepted||issueUpdate|$AREA|1|update;KEN-2413;--project;Fixture Area
update-no-project|declared|accepted||issueUpdate||0|update;KEN-2413;--title;T
bulk-off-map|declared|refused|linear-projects: off-map project=Fixture Off Map map=$TMP_ROOT/declared/$RENDER|||0|bulk-update;KEN-2413;KEN-2414;--project;Fixture Off Map
bulk-off-map-uuid|declared|refused|linear-projects: off-map project=$OFF_MAP map=$TMP_ROOT/declared/$RENDER|||1|bulk-update;KEN-2413;KEN-2414;--project=$OFF_MAP
bulk-on-map|declared|accepted||issueUpdate|$AREA|1|bulk-update;KEN-2413;KEN-2414;--project=Fixture Area
bulk-on-map-space|declared|accepted||issueUpdate|$AREA|1|bulk-update;KEN-2413;KEN-2414;--project;Fixture Area
bulk-no-team-on-map|declared|accepted||issueUpdate|$AREA|1|LINEAR_TEAM=;bulk-update;KEN-2413;KEN-2414;--project;Fixture Area
bulk-no-team-missing|declared|refused|linear-projects: declared-missing project=Fixture Missing map=$TMP_ROOT/declared/$RENDER|||1|LINEAR_TEAM=;bulk-update;KEN-2413;KEN-2414;--project;Fixture Missing
no-json|no-json|refused|linear-projects: map-unreadable map=$TMP_ROOT/no-json/$RENDER|||0|create;--title;T;--no-agent-label;--project;Fixture Area
invalid|invalid|refused|linear-projects: map-unreadable map=$TMP_ROOT/invalid/$RENDER|||0|create;--title;T;--no-agent-label;--project;Fixture Area
differ|differ|refused|linear-projects: map-unreadable map=$TMP_ROOT/differ/$RENDER differs=$TMP_ROOT/differ/.claude/skills/project-management/SKILL.md|||0|create;--title;T;--no-agent-label;--project;Fixture Area
none-create|none|accepted||issueCreate||0|create;--title;T;--no-agent-label
none-update|none|accepted||issueUpdate|$OFF_MAP|0|update;KEN-2413;--project;Fixture Off Map
ROWS

assert "create-no-project: refused before any request" test ! -s "$TMP_ROOT/create-no-project.jsonl"
assert "create-off-map: refused before any request" test ! -s "$TMP_ROOT/create-off-map.jsonl"
assert_eq "bulk-on-map: every issue is written" "$(grep -c issueUpdate "$TMP_ROOT/bulk-on-map.jsonl" || :)" 2

# Two live projects of one map name: the map cannot say which it means.
TWIN="$TMP_ROOT/projects-twin.json"
jq '. + [.[1] | .id = "00000000-0000-4000-8000-000000000205"]' "$PROJECTS" >"$TWIN"
run_status rc run_label_team_request "$TMP_ROOT/declared" create-twin "" PROJECTS="$TWIN" \
  create --title T --no-agent-label --project "Fixture Area"
assert_ne "create-twin: refused" "$rc" 0
assert_file_contains "create-twin: the refusal is keyed" "$TMP_ROOT/create-twin.err" \
  "linear-projects: ambiguous project=Fixture Area map=$TMP_ROOT/declared/$RENDER"
assert_not "create-twin: no write is sent" grep -q issueCreate "$TMP_ROOT/create-twin.jsonl"
