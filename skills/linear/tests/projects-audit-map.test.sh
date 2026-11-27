#!/usr/bin/env bash
# bash-runtime: 4
# `projects audit` against recorded Linear replies: each finding the Audit
# section of project-management references/project-map.md lists, one planted
# defect per row in a copy of a clean team that yields none, each judged from
# the admission lines that open a Linear project's content, read live. Then the
# audit pass's team inventory its readers share (`issues list`, as orch's
# reconciliation and the project-management workflows run it, `labels audit`
# and `projects audit` given --inventory): each answers what its live read does,
# the pass lists the team once, and a file a reader cannot use refuses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P)
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

# The clean team: a started deliverable and a standing area, each opening its
# content with its admission lines (the area's with a blank line and CRLF line
# ends between them, as an editor may write them), and every open kendex item
# in the deliverable. A completed project that admits nothing holds the
# completed and duplicate items; it, another team's project, another team's
# item and another team's label named like the area reach a finding only when
# a filter is dropped. Project rows have the shape of
# lib/fixtures/recorded/projects-list.json, whose `content` is null where a
# project has none; content lines are as Linear returns a project holding them.
CLEAN="$TMP_ROOT/clean-team.json"
cat >"$CLEAN" <<'JSON'
{"taxonomy": {"categories": {"surface": {"labels": ["skills"]}, "classification": {"labels": ["bug"]}}},
 "initiatives": [{"name": "Fixture Initiative"}],
 "projects": [
  {"id": "proj-deliverable", "name": "Fixture Deliverable", "state": "started", "targetDate": "2026-12-01", "teams": {"nodes": [{"id": "team-kendex"}]},
   "content": "Admits: Fixture work.\nKind: deliverable\nEnds when: Fixture release ships.\n\n## Why\n\nFixture prose."},
  {"id": "proj-area", "name": "Fixture Area", "state": "started", "targetDate": null, "teams": {"nodes": [{"id": "team-kendex"}]},
   "content": "Admits: Fixture area work.\r\n\r\nKind: standing\r\n"},
  {"id": "proj-done", "name": "Fixture Done", "state": "completed", "targetDate": null, "teams": {"nodes": [{"id": "team-kendex"}]}, "content": null},
  {"id": "proj-elsewhere", "name": "Fixture Elsewhere", "state": "started", "targetDate": null, "teams": {"nodes": [{"id": "team-other"}]}, "content": null}],
 "issues": [
  {"identifier": "KEN-1", "team": "team-kendex", "state": "started", "project": "Fixture Deliverable"},
  {"identifier": "KEN-2", "team": "team-kendex", "state": "unstarted", "project": "Fixture Deliverable"},
  {"identifier": "KEN-3", "team": "team-kendex", "state": "completed", "project": "Fixture Done"},
  {"identifier": "KEN-5", "team": "team-kendex", "state": "duplicate", "project": "Fixture Done"},
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

# The stub applies each filter its request sends and serves two issues per
# page, open ones only where the request filters on state type, with a
# project's state only where the request selects it. An
# issue's state name defaults to its type's usual one; a fixture issue may name
# another, and lists its label names.
cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload=$(sed -n 's/^data = //p' | jq -r)
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query=$(jq -r '.query' <<<"$payload")
has() { [[ "$query" == *"$1"* ]] && echo true || echo false; }
# issue_rows OP — the team's issues an issue listing named OP selects, paged.
issue_rows() {
  jq -cj --arg op "$1" --argjson payload "$payload" \
    --argjson open "$(has 'state: {type: {nin: ["completed", "canceled"]}}')" \
    --argjson team_filter "$(has 'team: {id: {eq: $teamId}}')" \
    --argjson project_state "$(has 'project { id name state }')" '
    {started: "In Progress", unstarted: "Todo", backlog: "Backlog", completed: "Done", canceled: "Canceled", duplicate: "Duplicate"} as $names
    | .projects as $projects | ($payload.variables.filter // {}) as $filter
    | (if $team_filter then $payload.variables.teamId else $filter.team.id.eq // null end) as $team
    | {pageInfo: {hasNextPage: false, endCursor: null}} as $closed
    | [.issues[] | . + {state_name: (.state_name // $names[.state])}
      | select($team == null or .team == $team)
      | select(($open | not) or (.state | IN("completed", "canceled") | not))
      | select(($filter.state.name // null) as $s
          | $s == null or .state_name == $s.eq or (.state_name | IN(($s.in // [])[])))
      | .project as $name | (first($projects[] | select(.name == $name)) // null) as $project
      | ($closed + {nodes: [(.labels // [])[] | {name: .}]}) as $labels
      | if $op == "AuditIssues" then {id: ("id-" + .identifier), identifier, labels: $labels}
        else {id: ("id-" + .identifier), identifier, title: .identifier, description: "",
          state: {name: .state_name, type: .state}, assignee: null,
          project: (if $project == null then null elif $project_state then $project | {id, name, state}
            else $project | {id, name} end),
          projectMilestone: null, cycle: null, parent: null, labels: $labels, priority: 0, estimate: null,
          sortOrder: 0, url: "", createdAt: "2026-11-01T00:00:00Z", updatedAt: "2026-11-01T00:00:00Z",
          archivedAt: null, trashed: null, relations: ($closed + {nodes: []}), inverseRelations: ($closed + {nodes: []})}
        end] as $rows
    | (($payload.variables.after // "0") | tonumber) as $at
    | {data: {issues: {pageInfo: {hasNextPage: ($rows | length > $at + 2), endCursor: ($at + 2 | tostring)},
        nodes: $rows[$at:$at + 2]}}}' "$DATA"
}
case "$query" in
*"InventoryIssues"*)
  if [[ -n "${FAIL_INVENTORY:-}" ]]; then
    printf '%s' '{"errors":[{"message":"fixture refusal"}]}'
  else
    issue_rows InventoryIssues
  fi ;;
*"ListIssues"*) issue_rows ListIssues ;;
*"AuditIssues"*) issue_rows AuditIssues ;;
*"AuditLabels"*)
  jq -cj --argjson payload "$payload" '
    {data: {issueLabels: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [.labels[]
      | select(.team == null or .team.id == $payload.variables.teamId) | {id: ("label-" + .name), name, team}]}}}' "$DATA" ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"team-kendex"}]}}}' ;;
*"AuditProjects"*)
  jq -cj --argjson payload "$payload" --argjson scoped "$(has 'accessibleTeams: {some: {id: {eq: $teamId}}}')" '
    {data: {projects: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [.projects[]
      | select(($scoped | not) or any(.teams.nodes[]; .id == $payload.variables.teamId))
      | {id, name, state, targetDate, content}]}}}' "$DATA" ;;
*"AuditInitiatives"*)
  jq -cj '{data: {initiatives: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .initiatives}}}' "$DATA" ;;
*"AuditMapIssues"*)
  jq -cj --argjson payload "$payload" \
    --argjson open "$(has 'state: {type: {nin: ["completed", "canceled", "duplicate"]}}')" \
    --argjson team "$(has 'team: {id: {eq: $teamId}}')" '
    .projects as $projects
    | [.issues[] | select(($open | not) or (.state | IN("completed", "canceled", "duplicate") | not))
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

# render DATA — render DATA's taxonomy.
render() {
  local data="$1"
  {
    printf '%s\n' '# Project Management' '<!-- kendex:project-instructions:start -->' \
      '### Project taxonomy' '```json'
    jq -c '.taxonomy' "$data"
    printf '%s\n' '```' '<!-- kendex:project-instructions:end -->'
  } >"$RENDER"
}

# linear NAME DATA ARGS... — run linear.sh ARGS against DATA's replies, keeping
# NAME's output, errors and request log. FAIL_INVENTORY passes through.
linear() {
  local name="$1" data="$2"
  shift 2
  : >"$TMP_ROOT/$name.jsonl"
  (cd -- "$PROJECT" && env -i HOME="$TMP_ROOT" PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=stub LINEAR_TEAM=kendex DATA="$data" CURL_LOG="$TMP_ROOT/$name.jsonl" \
    ${FAIL_INVENTORY:+FAIL_INVENTORY=1} \
    "$BASH" "$PROJECT/.agents/skills/linear/scripts/linear.sh" "$@") \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
}

# audit NAME PLANT — run `projects audit` against the planted copy of the
# clean team.
audit() {
  local name="$1" data="$TMP_ROOT/$1.json"
  jq "$2" "$CLEAN" >"$data"
  render "$data"
  linear "$name" "$data" projects audit
}

# A live project of the kendex team, by name and content.
live='def live($name; $content): {id: ("proj-" + $name), name: $name, state: "started", targetDate: null, teams: {nodes: [{id: "team-kendex"}]}, content: $content};'

# Each row plants one defect and names the findings it yields, in the
# audit's order; `^` separates the fields, since a plant is a jq program.
while IFS='^' read -r name plant findings; do
  run_status rc audit "$name" "$live $plant"
  assert_eq "$name: succeeds" "$rc" 0
  assert "$name: yields its findings" jq -e --argjson want "$findings" '.findings == $want' "$TMP_ROOT/$name.out"
done <<'ROWS'
unadmitted^.projects += [live("Fixture Bare"; null)] | .issues += [{identifier: "KEN-9", team: "team-kendex", state: "started", project: "Fixture Bare"}]^[{"kind": "no-admits", "project": "Fixture Bare"}, {"kind": "no-kind", "project": "Fixture Bare"}, {"kind": "unadmitted", "issue": "KEN-9", "project": "Fixture Bare"}]
other-team-project^.issues += [{identifier: "KEN-9", team: "team-kendex", state: "started", project: "Fixture Elsewhere"}]^[{"kind": "unadmitted", "issue": "KEN-9", "project": "Fixture Elsewhere"}]
admits-after-prose^.projects += [live("Fixture Prose"; "## Why\nAdmits: Fixture hidden.\nKind: standing")]^[{"kind": "no-admits", "project": "Fixture Prose"}, {"kind": "no-kind", "project": "Fixture Prose"}]
no-kind^(.projects[] | select(.name == "Fixture Area") | .content) = "Admits: Fixture area work.\nKind: area"^[{"kind": "no-kind", "project": "Fixture Area"}]
repeated-field^(.projects[] | select(.name == "Fixture Area") | .content) = "Admits: Fixture area work.\nKind: standing\nAdmits: Fixture old.\nKind: deliverable"^[]
no-project^.issues += [{identifier: "KEN-9", team: "team-kendex", state: "started", project: null}]^[{"kind": "no-project", "issue": "KEN-9"}]
initiative-holds-issue^.projects += [live("Fixture Initiative"; "Admits: Fixture.\nKind: standing")] | .issues += [{identifier: "KEN-9", team: "team-kendex", state: "started", project: "Fixture Initiative"}]^[{"kind": "initiative-holds-issue", "issue": "KEN-9", "initiative": "Fixture Initiative", "project": "Fixture Initiative"}]
label-like-project^.labels += [{name: "Fixture_Area", team: null}]^[{"kind": "name-collision", "label": "Fixture_Area", "entry": {"level": "project", "name": "Fixture Area"}, "declared": false}]
project-like-label^.projects += [live("Bug"; "Admits: Fixture defects.\nKind: standing")] | .labels += [{name: "BUG", team: {id: "team-kendex"}}]^[{"kind": "name-collision", "label": "BUG", "entry": {"level": "project", "name": "Bug"}, "declared": true}]
initiative-like-label^.taxonomy.categories.surface.labels += ["fixture initiative"]^[{"kind": "name-collision", "label": "fixture initiative", "entry": {"level": "initiative", "name": "Fixture Initiative"}, "declared": true}]
standing-target-date^(.projects[] | select(.name == "Fixture Area") | .targetDate) = "2026-12-01"^[{"kind": "standing-target-date", "project": "Fixture Area", "target_date": "2026-12-01"}]
deliverable-no-ends-when^(.projects[] | select(.name == "Fixture Deliverable") | .content) = "Admits: Fixture work.\nKind: deliverable"^[{"kind": "deliverable-no-ends-when", "project": "Fixture Deliverable"}]
closed-project-item^(.projects[] | select(.name == "Fixture Deliverable") | .state) = "canceled"^[{"kind": "closed-project-item", "issue": "KEN-1", "project": "Fixture Deliverable", "state": "canceled"}, {"kind": "closed-project-item", "issue": "KEN-2", "project": "Fixture Deliverable", "state": "canceled"}, {"kind": "closed-project-item", "issue": "KEN-4", "project": "Fixture Deliverable", "state": "canceled"}]
ROWS

assert "repeated-field: keeps each line's first value" \
  jq -e 'first(.projects[] | select(.name == "Fixture Area")) | .admits == "Fixture area work." and .kind == "standing"' \
  "$TMP_ROOT/repeated-field.out"

run_status rc audit clean .
assert_eq "clean: succeeds" "$rc" 0
assert "clean: yields no finding" jq -e '.findings == []' "$TMP_ROOT/clean.out"
assert "clean: skips closed issues" jq -e 'all(.findings[]; .issue != "KEN-3")' "$TMP_ROOT/clean.out"
assert "clean: skips duplicate issues" jq -e 'all(.findings[]; .issue != "KEN-5")' "$TMP_ROOT/clean.out"
assert "clean: reads only the team's issues" jq -e 'all(.findings[]; .issue != "OTHER-1")' "$TMP_ROOT/clean.out"
assert "clean: reads only the team's and workspace labels" \
  jq -e 'all(.findings[]; .label != "fixture-area")' "$TMP_ROOT/clean.out"
assert "clean: lists each live project's admission lines" \
  jq -e '.projects == [
    {name: "Fixture Deliverable", id: "proj-deliverable", state: "started", kind: "deliverable", admits: "Fixture work.", ends_when: "Fixture release ships."},
    {name: "Fixture Area", id: "proj-area", state: "started", kind: "standing", admits: "Fixture area work.", ends_when: null}]' \
  "$TMP_ROOT/clean.out"

# --- one audit pass's team inventory -----------------------------------------
# The batch is the heartbeat full audit's team reads (orch
# references/heartbeat-audit.md), in order and in their command forms: the
# team and issue runs' orch-runtime reconcile-items every-state lists (the form
# skills/orch/tests/rust/reconcile_items.rs pins), then the TPM's team-mode
# reads (label audit, team-mode list, all-open-states comparison, project
# audit) and its issue-mode reads (the same less the team-mode list). The
# issue run's targeted bulk-get and closed-row searches take no inventory and
# stay out. Its world adds an undeclared label on an
# open, a completed and a duplicate issue, In Review and Verifying issues, an
# open item in a project that admits nothing and one in a completed project.
BATCH="$TMP_ROOT/batch.json"
jq '.projects += [{id: "proj-off-map", name: "Fixture Off Map", state: "started", targetDate: null, teams: {nodes: [{id: "team-kendex"}]}, content: null}]
  | (.issues[] | select(.identifier | IN("KEN-1", "KEN-3", "KEN-5"))) += {labels: ["skills", "legacy"]}
  | .issues += [
      {identifier: "KEN-6", team: "team-kendex", state: "started", state_name: "In Review", project: "Fixture Deliverable", labels: ["bug"]},
      {identifier: "KEN-7", team: "team-kendex", state: "started", state_name: "Verifying", project: "Fixture Deliverable"},
      {identifier: "KEN-8", team: "team-kendex", state: "started", project: "Fixture Off Map"},
      {identifier: "KEN-9", team: "team-kendex", state: "started", project: "Fixture Done"}]' "$CLEAN" >"$BATCH"
render "$BATCH"
mkdir -p "$TMP_ROOT/pass" "$TMP_ROOT/split" "$TMP_ROOT/failed"
INVENTORY="$TMP_ROOT/pass/inventory.json"

# Each step: its name, then its arguments separated by `|`.
STEPS='reconcile^issues|list|--max|--team|kendex|--format=safe
issue-reconcile^issues|list|--max|--team|kendex|--format=safe
labels-audit^labels|audit
team-mode^issues|list|--team|kendex|--all-projects|--state|Backlog,Todo,In Progress,In Review|--max
open-states^issues|list|--team|kendex|--all-projects|--state|Backlog,Todo,In Progress,In Review,Verifying|--max
projects-audit^projects|audit|--team|kendex
issue-labels-audit^labels|audit
issue-open-states^issues|list|--team|kendex|--all-projects|--state|Backlog,Todo,In Progress,In Review,Verifying|--max
issue-projects-audit^projects|audit|--team|kendex'

# The request kinds the count separates: whole-team issue-list collections
# (a listing's first page), every page of them, the continuation reads of one
# issue's open connection, and every other read.
request_counts() {
  jq -cs '["ListIssues", "AuditIssues", "AuditMapIssues", "InventoryIssues"] as $listings
    | [.[] | {op: (try (.query | capture("query (?<op>[A-Za-z]+)").op) catch "unnamed"), after: .variables.after}]
    | {collections: map(select(.op | IN($listings[])) | select(.after == null)) | length,
       pages: map(select(.op | IN($listings[]))) | length,
       targeted: map(select(.op | startswith("Continue"))) | length,
       metadata: map(select((.op | IN($listings[])) or (.op | startswith("Continue")) | not)) | length,
       listings: (map(select(.op | IN($listings[])) | .op) | unique)}' "$@"
}

# Each step runs live, then given the one pass inventory, then as the
# heartbeat ran it with a separate reconciliation and an inventory per run:
# the first reconciliation live, each run's reads given its own file.
live_logs=() pass_logs=() split_logs=()
while IFS='^' read -r name argv; do
  IFS='|' read -r -a args <<<"$argv"
  run_status rc linear "live-$name" "$BATCH" "${args[@]}"
  assert_eq "live: $name succeeds" "$rc" 0
  run_status rc linear "pass-$name" "$BATCH" "${args[@]}" --inventory "$INVENTORY"
  assert_eq "inventory: $name succeeds" "$rc" 0
  assert "inventory: $name prints what the live read prints" \
    cmp -s "$TMP_ROOT/live-$name.out" "$TMP_ROOT/pass-$name.out"
  live_logs+=("$TMP_ROOT/live-$name.jsonl")
  pass_logs+=("$TMP_ROOT/pass-$name.jsonl")
  case "$name" in
  reconcile) split_logs+=("$TMP_ROOT/live-$name.jsonl") split=team ;;
  issue-*) split=issue ;;
  *) split=team ;;
  esac
  run_status rc linear "split-$name" "$BATCH" "${args[@]}" --inventory "$TMP_ROOT/split/$split.json"
  assert_eq "split: $name succeeds" "$rc" 0
  split_logs+=("$TMP_ROOT/split-$name.jsonl")
done <<<"$STEPS"

assert "inventory: the reconciliation read collects the inventory once" \
  jq -e '.collections == 1 and .listings == ["InventoryIssues"]' <(request_counts "$TMP_ROOT/pass-reconcile.jsonl")
assert "inventory: the reconciliation read publishes the file" test -s "$INVENTORY"
while IFS='^' read -r name _; do
  [[ "$name" == reconcile ]] && continue
  assert "inventory: $name lists no issues" \
    jq -e '.pages == 0' <(request_counts "$TMP_ROOT/pass-$name.jsonl")
done <<<"$STEPS"
assert "inventory: holds the team's every state and no other team" \
  jq -e '[.nodes[].identifier] | sort == ["KEN-1", "KEN-2", "KEN-3", "KEN-4", "KEN-5", "KEN-6", "KEN-7", "KEN-8", "KEN-9"]' "$INVENTORY"
assert "inventory: reconciliation keeps every state" \
  jq -e '[.[].id] | sort == ["KEN-1", "KEN-2", "KEN-3", "KEN-4", "KEN-5", "KEN-6", "KEN-7", "KEN-8", "KEN-9"]' "$TMP_ROOT/pass-reconcile.out"
assert "inventory: team-mode keeps its state filter" \
  jq -e '[.[].id] == ["KEN-1", "KEN-2", "KEN-4", "KEN-6", "KEN-8", "KEN-9"]' "$TMP_ROOT/pass-team-mode.out"
assert "inventory: labels audit keeps duplicate-state issues" \
  jq -e '.undeclared == [{label: "legacy", issues: ["KEN-1", "KEN-5"]}]' "$TMP_ROOT/pass-labels-audit.out"
assert "inventory: projects audit leaves out closed and duplicate issues" \
  jq -e '.findings == [{kind: "closed-project-item", issue: "KEN-9", project: "Fixture Done", state: "completed"},
    {kind: "no-admits", project: "Fixture Off Map"}, {kind: "no-kind", project: "Fixture Off Map"},
    {kind: "unadmitted", issue: "KEN-8", project: "Fixture Off Map"}]' "$TMP_ROOT/pass-projects-audit.out"

before=$(request_counts "${live_logs[@]}")
split=$(request_counts "${split_logs[@]}")
after=$(request_counts "${pass_logs[@]}")
printf 'projects-audit-map: listing-counts before=%s split=%s after=%s\n' "$before" "$split" "$after"
assert "batch: each live step lists the team once" \
  jq -e --argjson steps "${#live_logs[@]}" '.collections == $steps' <<<"$before"
assert "batch: a separate reconciliation and an inventory per run list the team three times" \
  jq -e '.collections == 3' <<<"$split"
assert "batch: the inventory pass makes one issue-list collection" jq -e '.collections == 1' <<<"$after"
assert "batch: the inventory pass keeps every other read" \
  jq -e --argjson before "$before" '.metadata == $before.metadata and .targeted == $before.targeted' <<<"$after"

# A format whose rows carry the project prints no project state the live read
# lacks.
run_status rc linear live-raw "$BATCH" issues list --team kendex --state "In Progress" --max --format=raw
run_status rc linear pass-raw "$BATCH" issues list --team kendex --state "In Progress" --max --format=raw --inventory "$INVENTORY"
assert "inventory: raw prints what the live read prints" cmp -s "$TMP_ROOT/live-raw.out" "$TMP_ROOT/pass-raw.out"
assert "inventory: raw is not empty" jq -e '.issues.nodes | length > 0' "$TMP_ROOT/pass-raw.out"

# A supplied inventory the reader cannot use refuses, keyed by its cause, with
# no listing in its place. Every cause reaches the list; the audits share its
# reader.
while IFS='^' read -r cause name plant; do
  bad="$TMP_ROOT/pass/$cause-$name.json"
  case "$cause" in
  unreadable) mkdir "$bad" ;;
  malformed) printf 'not json\n' >"$bad" ;;
  *) jq "$plant" "$INVENTORY" >"$bad" ;;
  esac
  IFS='|' read -r -a args <<<"$(sed -n "s/^$name\^//p" <<<"$STEPS")"
  run_status rc linear "$cause-$name" "$BATCH" "${args[@]}" --inventory "$bad"
  assert_ne "$cause: $name refused" "$rc" 0
  assert_file_contains "$cause: $name refuses inventory-unread" "$TMP_ROOT/$cause-$name.err" \
    "inventory-unread file=$bad cause=$cause"
  assert_not "$cause: $name prints nothing" test -s "$TMP_ROOT/$cause-$name.out"
  assert "$cause: $name lists no issues" jq -e '.pages == 0' <(request_counts "$TMP_ROOT/$cause-$name.jsonl")
done <<'ROWS'
unreadable^team-mode^
malformed^team-mode^
insufficient^team-mode^.fields = "id identifier"
other-team^team-mode^.team = "team-other"
other-team^labels-audit^.team = "team-other"
other-team^projects-audit^.team = "team-other"
ROWS

# A collection Linear refuses publishes nothing, so the next reader reads again.
FAIL_INVENTORY=1 run_status rc linear failed-read "$BATCH" issues list --team kendex --max \
  --inventory "$TMP_ROOT/failed/inventory.json"
assert_ne "failed read: refused" "$rc" 0
assert "failed read: refused by its one collection" \
  jq -e '.collections == 1 and .listings == ["InventoryIssues"]' <(request_counts "$TMP_ROOT/failed-read.jsonl")
assert_eq "failed read: publishes nothing" "$(find "$TMP_ROOT/failed" -mindepth 1 | wc -l | tr -d ' ')" 0

# The list answers from an inventory only what it can filter there; any other
# option refuses before a request.
while IFS='^' read -r option argv; do
  IFS='|' read -r -a args <<<"$argv"
  run_status rc linear "unsupported$option" "$BATCH" "${args[@]}" --inventory "$INVENTORY"
  assert_ne "$option: refused" "$rc" 0
  assert_file_contains "$option: names the option" "$TMP_ROOT/unsupported$option.err" \
    "inventory-unsupported option=$option"
  assert_not "$option: refused before any read" test -s "$TMP_ROOT/unsupported$option.jsonl"
done <<'ROWS'
--project^issues|list|--team|kendex|--max|--project|Fixture Deliverable
--label^issues|list|--team|kendex|--max|--label|skills
--search^issues|list|--team|kendex|--max|--search|legacy
--select^issues|list|--team|kendex|--max|--select|owed
--with-relations^issues|list|--team|kendex|--max|--with-relations
--limit^issues|list|--team|kendex|--limit|5
--max^issues|list|--team|kendex
--team^issues|list|--max
ROWS
