#!/usr/bin/env bash
# Under a declared label taxonomy (the project-management JSON contract under
# `### Project taxonomy`, plus LINEAR_AGENT_LABELS), every path that applies a
# label (issues create, update --labels, activate, block) refuses a name the
# taxonomy does not declare, before any write; a name the issue already carries
# is kept. `labels create` refuses an undeclared name, and a team label whose
# name a workspace label uses. `labels audit` lists undeclared labels on the
# team's open issues and same-name team/workspace pairs. A repository with no
# taxonomy keeps the behaviour it had, and one it cannot read refuses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P)
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

# make_project DIR KIND — a repository with this skill and, by KIND, the
# rendered project-management SKILL.md beside it: declared, none (no file),
# no-heading, no-json (the heading with no JSON block), json-in-next-section
# (the only JSON block sits under a later heading) or invalid-json.
make_project() {
  local project="$1" kind="$2" taxonomy
  mkdir -p "$project/.agents/skills/project-management"
  git -C "$project" init -q -b main
  git -C "$project" config gc.auto 0
  git -C "$project" config maintenance.auto false
  cp -R "$SKILL_DIR" "$project/.agents/skills/linear"
  taxonomy="$project/.agents/skills/project-management/SKILL.md"
  case "$kind" in
  declared)
    printf '%s\n' '# Project Management' '<!-- kendex:project-instructions:start -->' \
      '### Project taxonomy' '' 'Prose before the contract.' '' '```json' \
      '{"categories": {"agent": {"required": true, "match": {"prefix": "agent:"}},' \
      ' "surface": {"labels": ["skills"]}, "classification": {"labels": ["bug"]}}}' \
      '```' '<!-- kendex:project-instructions:end -->' >"$taxonomy"
    ;;
  none) ;;
  no-heading)
    printf '%s\n' '<!-- kendex:project-instructions:start -->' '### Other' '```json' '{}' '```' \
      '<!-- kendex:project-instructions:end -->' >"$taxonomy"
    ;;
  no-json)
    printf '%s\n' '<!-- kendex:project-instructions:start -->' '### Project taxonomy' \
      'Labels are prose here.' '<!-- kendex:project-instructions:end -->' >"$taxonomy"
    ;;
  json-in-next-section)
    printf '%s\n' '<!-- kendex:project-instructions:start -->' '### Project taxonomy' \
      'Labels are prose here.' '### Other' '```json' '{"categories": {}}' '```' \
      '<!-- kendex:project-instructions:end -->' >"$taxonomy"
    ;;
  invalid-json)
    printf '%s\n' '<!-- kendex:project-instructions:start -->' '### Project taxonomy' '```json' \
      '{"categories": {"surface": {"labels": ["skills", 7]}}}' '```' \
      '<!-- kendex:project-instructions:end -->' >"$taxonomy"
    ;;
  *) assert_stop "make_project: unknown kind $kind" ;;
  esac
}

PROJECT="$TMP_ROOT/project"
make_project "$PROJECT" declared
install_label_team_fixture "$PROJECT"
TAXONOMY="$PROJECT/.agents/skills/project-management/SKILL.md"
AGENTS=LINEAR_AGENT_LABELS=agent:runtime

# The private fixture adds workspace `agent:rust` and `blocked` labels, so an
# undeclared label the rows below apply exists in Linear: only the taxonomy
# stands between it and the write.
FIXTURES="$TMP_ROOT/fixtures"
mkdir -p "$FIXTURES"
cp -- "$SKILL_DIR/tests/lib/fixtures/label-team-issue.json" "$FIXTURES/"
jq '.issueLabels.nodes += [{id: "0d6f3b8e-2a41-4c97-b5e2-8f1a7c3d9e60", name: "agent:rust", team: null},
      {id: "5b9e2c71-8d3a-4f06-a1e4-7c2b9d5f3a18", name: "blocked", team: null}]' \
  "$SKILL_DIR/tests/lib/fixtures/issue-team-labels.json" >"$FIXTURES/issue-team-labels.json"

# Recorded issue KEN-2413 carries `harness` (undeclared) and `agent:runtime`.
# A refused row sends no write; an accepted one sends exactly its mutation.
while IFS='|' read -r name want undeclared mutation args; do
  # shellcheck disable=SC2086 # args is the row's word list
  run_status rc run_label_team_request "$PROJECT" "$name" "" "$AGENTS" FIXTURE_DIR="$FIXTURES" $args
  if [[ "$want" == refused ]]; then
    assert_ne "$name: refused" "$rc" 0
    assert_file_contains "$name: the refusal names the label and the taxonomy" "$TMP_ROOT/$name.err" \
      "linear-labels: undeclared labels=$undeclared taxonomy=$TAXONOMY"
    assert_not "$name: no write is sent" grep -qE 'issueCreate|issueUpdate' "$TMP_ROOT/$name.jsonl"
  else
    assert_eq "$name: accepted" "$rc" 0
    assert "$name: the write is sent" grep -q "$mutation" "$TMP_ROOT/$name.jsonl"
  fi
done <<'ROWS'
create-undeclared|refused|baseline||create --team kendex --title T --labels skills,agent:runtime,baseline
create-declared|accepted||issueCreate|create --team kendex --title T --labels skills,agent:runtime,bug
update-undeclared|refused|baseline||update KEN-2413 --labels harness,agent:runtime,baseline
update-kept|accepted||issueUpdate|update KEN-2413 --labels harness,agent:runtime,bug
activate-undeclared|refused|agent:rust||activate KEN-2413 --agent rust
activate-kept|accepted||issueUpdate|activate KEN-2413 --agent runtime
block-undeclared|refused|blocked||block KEN-2413 --by KEN-1
ROWS
assert "create-undeclared: refused before any request" test ! -s "$TMP_ROOT/create-undeclared.jsonl"

# No taxonomy keeps today's create, undeclared label and all; a declared one
# the CLI cannot read refuses, since enforcing nothing would pass every label.
while IFS='|' read -r kind want; do
  make_project "$TMP_ROOT/$kind" "$kind"
  install_label_team_fixture "$TMP_ROOT/$kind"
  run_status rc run_label_team_request "$TMP_ROOT/$kind" "$kind" "" "$AGENTS" \
    create --team kendex --title T --labels skills,agent:runtime,baseline
  if [[ "$want" == accepted ]]; then
    assert_eq "$kind: create keeps today's behaviour" "$rc" 0
    assert "$kind: create sends the undeclared label" \
      grep -q e308b7eb-1c70-4d3f-bd86-9cb359f2b088 "$TMP_ROOT/$kind.jsonl"
  else
    assert_ne "$kind: refused" "$rc" 0
    assert_file_contains "$kind: the refusal names the unreadable taxonomy" "$TMP_ROOT/$kind.err" \
      "linear-labels: taxonomy-unreadable taxonomy=$TMP_ROOT/$kind/.agents/skills/project-management/SKILL.md"
  fi
done <<'ROWS'
none|accepted
no-heading|accepted
no-json|refused
json-in-next-section|refused
invalid-json|refused
ROWS

# `labels create` and `labels audit` against their own recorded replies. The
# audit's open issues come in two pages; FIXTURE_FAIL=pages drops pageInfo.
LABELS_PROJECT="$TMP_ROOT/labels"
make_project "$LABELS_PROJECT" declared
mkdir -p "$LABELS_PROJECT/bin"
cat >"$LABELS_PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload=$(sed -n 's/^data = //p' | jq -r)
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query=$(jq -r '.query' <<<"$payload")
case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-kendex"}]}}}' ;;
*"WorkspaceLabel"*)
  jq -cj '{data: {issueLabels: {nodes: (if .variables.name == "bug" then [{id: "ws-bug"}] else [] end)}}}' <<<"$payload" ;;
*"issueLabelCreate"*)
  printf '%s' '{"data":{"issueLabelCreate":{"success":true,"issueLabel":{"id":"new","name":"n","color":"#000000","isGroup":false,"parent":null}}}}' ;;
*"AuditIssues"*)
  if [[ "$(jq -r '.variables.after' <<<"$payload")" == null ]]; then
    page='{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[
      {"identifier":"KEN-1","labels":{"pageInfo":{"hasNextPage":false},"nodes":[{"name":"skills"},{"name":"legacy"}]}},
      {"identifier":"KEN-2","labels":{"pageInfo":{"hasNextPage":false},"nodes":[{"name":"legacy"},{"name":"agent:runtime"}]}}]}'
  else
    page='{"pageInfo":{"hasNextPage":false,"endCursor":"c2"},"nodes":[
      {"identifier":"KEN-3","labels":{"pageInfo":{"hasNextPage":false},"nodes":[{"name":"harness"}]}}]}'
  fi
  [[ "$FIXTURE_FAIL" != pages ]] || page=$(jq -c 'del(.pageInfo)' <<<"$page")
  jq -cj '{data: {issues: .}}' <<<"$page" ;;
*"AuditLabels"*)
  printf '%s' '{"data":{"issueLabels":{"pageInfo":{"hasNextPage":false,"endCursor":"l1"},"nodes":[
    {"id":"team-harness","name":"harness","team":{"id":"team-kendex"}},
    {"id":"ws-harness","name":"harness","team":null},
    {"id":"team-skills","name":"skills","team":{"id":"team-kendex"}},
    {"id":"ws-bug","name":"bug","team":null}]}}}' ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected fixture query"}]}' ;;
esac
printf '%s' '___HTTP_CODE___200'
SH
chmod +x "$LABELS_PROJECT/bin/curl"

run_labels() { # NAME FAIL PROJECT LABELS-ARGS...
  local name="$1" fail="$2" project="$3"
  shift 3
  : >"$TMP_ROOT/$name.jsonl"
  (cd -- "$project" && env -i HOME="$TMP_ROOT" PATH="$LABELS_PROJECT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=stub LINEAR_TEAM=kendex LINEAR_CACHE_ROOT="$project" \
    LINEAR_AGENT_LABELS=agent:runtime FIXTURE_FAIL="$fail" CURL_LOG="$TMP_ROOT/$name.jsonl" \
    "$BASH" "$project/.agents/skills/linear/scripts/linear.sh" labels "$@") \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
}

while IFS='|' read -r name want key args; do
  # shellcheck disable=SC2086 # args is the row's word list
  run_status rc run_labels "$name" "" "$LABELS_PROJECT" create $args
  if [[ "$want" == refused ]]; then
    assert_ne "$name: refused" "$rc" 0
    assert_file_contains "$name: the refusal is keyed" "$TMP_ROOT/$name.err" "$key"
    assert_not "$name: no label is created" grep -q issueLabelCreate "$TMP_ROOT/$name.jsonl"
  else
    assert_eq "$name: accepted" "$rc" 0
    assert "$name: the label is created" grep -q issueLabelCreate "$TMP_ROOT/$name.jsonl"
  fi
done <<ROWS
label-undeclared|refused|linear-labels: undeclared labels=legacy taxonomy=$LABELS_PROJECT/.agents/skills/project-management/SKILL.md|--name legacy
label-declared|accepted||--name bug
label-workspace-duplicate|refused|linear-labels: workspace-duplicate name=bug|--name bug --team kendex
label-team|accepted||--name skills --team kendex
ROWS

NO_TAXONOMY="$TMP_ROOT/labels-none"
make_project "$NO_TAXONOMY" none
run_status rc run_labels label-team-none "" "$NO_TAXONOMY" create --name bug --team kendex
assert_eq "label-team-none: no taxonomy keeps today's team label create" "$rc" 0
assert_not "label-team-none: no workspace lookup is sent" grep -q WorkspaceLabel "$TMP_ROOT/label-team-none.jsonl"

run_status rc run_labels audit "" "$LABELS_PROJECT" audit
assert_eq "audit: succeeds" "$rc" 0
assert "audit: lists each undeclared label with the open issues carrying it" \
  jq -e '.undeclared == [{label: "harness", issues: ["KEN-3"]}, {label: "legacy", issues: ["KEN-1", "KEN-2"]}]' \
  "$TMP_ROOT/audit.out"
assert "audit: reads the open issues past the first page" \
  jq -e '[.undeclared[].issues[]] | index("KEN-3") != null' "$TMP_ROOT/audit.out"
assert "audit: lists the same-name team and workspace pair" \
  jq -e '.same_name == [{name: "harness", workspace_label: "ws-harness", team_label: "team-harness"}]' \
  "$TMP_ROOT/audit.out"

run_status rc run_labels audit-pages pages "$LABELS_PROJECT" audit
assert_ne "audit-pages: refused" "$rc" 0
assert_file_contains "audit-pages: a page with no pageInfo fails the audit" \
  "$TMP_ROOT/audit-pages.err" "linear-labels: audit-incomplete connection=issues"

run_status rc run_labels audit-absent "" "$NO_TAXONOMY" audit
assert_ne "audit-absent: refused" "$rc" 0
assert_file_contains "audit-absent: no taxonomy has nothing to audit against" \
  "$TMP_ROOT/audit-absent.err" "linear-labels: taxonomy-absent taxonomy=$NO_TAXONOMY/.agents/skills/project-management/SKILL.md"
assert_not "audit-absent: no issue is read" grep -q AuditIssues "$TMP_ROOT/audit-absent.jsonl"
