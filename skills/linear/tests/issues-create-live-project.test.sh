#!/usr/bin/env bash
# bash-runtime: 4
# An issue write places its issue in any live project Linear resolves in the
# issue's team, driven against recorded Linear replies: create, update
# --project and bulk-update --project into a project no repository file
# names, and a create with no project. The rendered project-management
# SKILL.md still carries a `### Project map` block that lists another project,
# as a consumer's render does until its next kendex refresh, so a write that
# read that block would refuse every row.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P)
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

KENDEX=5c2e9f71-a4b8-4d36-91e0-7f3d6b2c8a15
NEW=00000000-0000-4000-8000-000000000301

# Linear's projects, in the row shape of lib/fixtures/recorded/projects-list.json:
# the project created in Linear today, holding its admission lines, and the
# one the stale render's block lists.
PROJECTS="$TMP_ROOT/projects.json"
cat >"$PROJECTS" <<JSON
[{"id": "$NEW", "name": "Fixture New", "state": "planned", "content": "Admits: Fixture new work.\nKind: standing", "teams": {"nodes": [{"id": "$KENDEX"}]}},
 {"id": "00000000-0000-4000-8000-000000000302", "name": "Fixture Listed", "state": "started", "content": null, "teams": {"nodes": [{"id": "$KENDEX"}]}}]
JSON

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills/project-management"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
install_label_team_fixture "$PROJECT"
mv -- "$PROJECT/bin/curl" "$PROJECT/bin/curl-recorded"
# The curl answers GetProject from the projects above, applying only the
# filters the request sends, and every other request from the recorded issue
# and labels.
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
query=$(jq -r '.query' <<<"$payload")
case "$query" in
*"GetProject"*)
  printf '%s\n' "$payload" >>"${CURL_LOG:?}"
  scoped=false
  [[ "$query" != *'accessibleTeams: {some: {id: {eq: $teamId}}}'* ]] || scoped=true
  jq -cj --argjson payload "$payload" --argjson scoped "$scoped" '
    {data: {projects: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [.[]
      | select(.name == $payload.variables.name)
      | select(($scoped | not) or any(.teams.nodes[]; .id == $payload.variables.teamId))
      | {id, state, teams: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [{name: "kendex"}]}}]}}}' "$PROJECTS"
  printf '%s' '___HTTP_CODE___200'
  ;;
*) exec "${0%/*}/curl-recorded" "$@" <<<"$config" ;;
esac
SH
chmod +x "$PROJECT/bin/curl"
printf '%s\n' '# Project Management' '<!-- kendex:project-instructions:start -->' \
  '### Project map' '```json' \
  '{"projects": [{"name": "Fixture Listed", "kind": "standing", "role": "area", "admits": "Fixture listed work."}]}' \
  '```' '<!-- kendex:project-instructions:end -->' >"$PROJECT/.agents/skills/project-management/SKILL.md"

# Each row runs one issues command, its arguments split on `;`, and names the
# mutation it sends and the project id each one carries (empty: none).
while IFS='|' read -r name mutation project_id args; do
  IFS=';' read -ra argv <<<"$args"
  run_status rc run_label_team_request "$PROJECT" "$name" "" PROJECTS="$PROJECTS" "${argv[@]}"
  log="$TMP_ROOT/$name.jsonl"
  assert_eq "$name: accepted" "$rc" 0
  assert "$name: the write carries the live project" jq -se --arg m "$mutation" --arg id "$project_id" '
    map(select(.query | contains($m + "(")) | .variables.input.projectId // "")
    | length > 0 and all(. == $id)' "$log"
done <<ROWS
create-unnamed|issueCreate|$NEW|create;--title;T;--no-agent-label;--project;Fixture New
create-unnamed-uuid|issueCreate|$NEW|create;--title;T;--no-agent-label;--project;$NEW
create-no-project|issueCreate||create;--title;T;--no-agent-label
update-unnamed|issueUpdate|$NEW|update;KEN-2413;--project;Fixture New
bulk-unnamed|issueUpdate|$NEW|bulk-update;KEN-2413;KEN-2414;--project;Fixture New
ROWS

assert_eq "bulk-unnamed: every issue is written" "$(grep -c issueUpdate "$TMP_ROOT/bulk-unnamed.jsonl" || :)" 2
assert_eq "bulk-unnamed: the project resolves once" "$(grep -c GetProject "$TMP_ROOT/bulk-unnamed.jsonl" || :)" 1
