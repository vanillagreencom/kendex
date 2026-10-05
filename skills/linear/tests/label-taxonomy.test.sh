#!/usr/bin/env bash
# The label-taxonomy refusals ../SKILL.md § Issue Creation Routing states,
# driven against recorded Linear replies; that section is the one list of the
# commands that refuse. The rows also pin which project-management renders the
# CLI reads: every project skills directory a delivery writes in one project,
# the nearest one above the working directory up to the project holding a
# project install or else the git top level, never one past that bound, the
# one beside a global install or another project's, and two renders that
# differ as unreadable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P)
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

# make_project DIR KIND [ROOT] — a repository with this skill under ROOT
# (default .agents/skills) and, by KIND, the rendered project-management
# SKILL.md beside it: declared, none (no file),
# no-heading, no-json (the heading with no JSON block), empty-json (an empty
# block), unclosed-json (a block with no closing fence), json-in-next-section
# (the only JSON block sits under a later heading) or invalid-json.
make_project() {
  local project="$1" kind="$2" root="${3:-.agents/skills}" taxonomy
  mkdir -p "$project/$root/project-management"
  git -C "$project" init -q -b main
  git -C "$project" config gc.auto 0
  git -C "$project" config maintenance.auto false
  cp -R "$SKILL_DIR" "$project/$root/linear"
  taxonomy="$project/$root/project-management/SKILL.md"
  case "$kind" in
  declared)
    printf '%s\n' '# Project Management' '<!-- kendex:project-instructions:start -->' \
      '### Project taxonomy' '' 'Prose before the contract.' '' '```json' \
      '{"categories": {"agent": {"required": true, "match": {"prefix": "agent:"}},' \
      ' "platform": {"match": {"parent": "Platform"}, "labels": ["macos"]},' \
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
  empty-json)
    printf '%s\n' '<!-- kendex:project-instructions:start -->' '### Project taxonomy' \
      '```json' '```' '<!-- kendex:project-instructions:end -->' >"$taxonomy"
    ;;
  unclosed-json)
    printf '%s\n' '<!-- kendex:project-instructions:start -->' '### Project taxonomy' \
      '```json' '{"categories": {}}' '<!-- kendex:project-instructions:end -->' >"$taxonomy"
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
# `macos` is declared but absent from Linear. A refused row sends no write and
# no upload; an accepted one sends exactly its mutation.
: >"$TMP_ROOT/asset.bin"
while IFS='|' read -r name want key mutation args; do
  # shellcheck disable=SC2086 # args is the row's word list
  run_status rc run_label_team_request "$PROJECT" "$name" "" "$AGENTS" FIXTURE_DIR="$FIXTURES" $args
  if [[ "$want" == refused ]]; then
    assert_ne "$name: refused" "$rc" 0
    assert_file_contains "$name: the refusal names the label and the taxonomy" "$TMP_ROOT/$name.err" "$key"
    assert_not "$name: no write is sent" grep -qE 'issueCreate|issueUpdate|fileUpload' "$TMP_ROOT/$name.jsonl"
  else
    assert_eq "$name: accepted" "$rc" 0
    assert "$name: the write is sent" grep -q "$mutation" "$TMP_ROOT/$name.jsonl"
  fi
done <<ROWS
create-undeclared|refused|linear-labels: undeclared labels=baseline taxonomy=$TAXONOMY||create --team kendex --title T --labels skills,agent:runtime,baseline
create-declared|accepted||issueCreate|create --team kendex --title T --labels skills,agent:runtime,bug
create-missing|refused|linear-labels: declared-missing label=macos taxonomy=$TAXONOMY||create --team kendex --title T --labels skills,agent:runtime,macos
create-missing-attach|refused|linear-labels: declared-missing label=macos taxonomy=$TAXONOMY||create --team kendex --title T --labels skills,agent:runtime,macos --attach $TMP_ROOT/asset.bin
update-undeclared|refused|linear-labels: undeclared labels=baseline taxonomy=$TAXONOMY||update KEN-2413 --labels harness,agent:runtime,baseline
update-kept|accepted||issueUpdate|update KEN-2413 --labels harness,agent:runtime,bug
activate-undeclared|refused|linear-labels: undeclared labels=agent:rust taxonomy=$TAXONOMY||activate KEN-2413 --agent rust
activate-kept|accepted||issueUpdate|activate KEN-2413 --agent runtime
block-undeclared|refused|linear-labels: undeclared labels=blocked taxonomy=$TAXONOMY||block KEN-2413 --by KEN-1
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
empty-json|refused
unclosed-json|refused
json-in-next-section|refused
invalid-json|refused
ROWS

# A create with no labels is no label write: an unreadable taxonomy leaves it.
run_status rc run_label_team_request "$TMP_ROOT/no-json" label-less "" "$AGENTS" \
  create --team kendex --title T --no-agent-label
assert_eq "label-less: an unreadable taxonomy does not stop a create with no labels" "$rc" 0
assert "label-less: the create is sent" grep -q issueCreate "$TMP_ROOT/label-less.jsonl"


# `labels create`, `update` and `audit` against recorded labels and issues. The
# stub applies each filter its request sends, as install_label_team_fixture
# does: another team's labels and issues, and a completed issue, reach a reply
# only when a filter is dropped. It serves two open issues per page;
# FIXTURE_FAIL=pages drops pageInfo.
LABELS_PROJECT="$TMP_ROOT/labels"
make_project "$LABELS_PROJECT" declared
mkdir -p "$LABELS_PROJECT/bin"
LABELS_DATA="$TMP_ROOT/labels-data.json"
cat >"$LABELS_DATA" <<'JSON'
{"labels": [
  {"id": "team-harness", "name": "harness", "team": {"id": "team-kendex"}},
  {"id": "ws-harness", "name": "harness", "team": null},
  {"id": "team-skills", "name": "skills", "team": {"id": "team-kendex"}},
  {"id": "other-skills", "name": "skills", "team": {"id": "team-other"}},
  {"id": "ws-bug", "name": "bug", "team": null},
  {"id": "other-bug", "name": "bug", "team": {"id": "team-other"}}],
 "issues": [
  {"identifier": "KEN-1", "team": "team-kendex", "state": "started", "labels": ["skills", "legacy"]},
  {"identifier": "KEN-2", "team": "team-kendex", "state": "unstarted", "labels": ["legacy", "agent:runtime"]},
  {"identifier": "KEN-4", "team": "team-kendex", "state": "completed", "labels": ["ancient"]},
  {"identifier": "OTHER-1", "team": "team-other", "state": "started", "labels": ["foreign"]},
  {"identifier": "KEN-3", "team": "team-kendex", "state": "started", "labels": ["harness"]}]}
JSON
cat >"$LABELS_PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload=$(sed -n 's/^data = //p' | jq -r)
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query=$(jq -r '.query' <<<"$payload")
has() { [[ "$query" == *"$1"* ]] && echo true || echo false; }
case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-kendex"}]}}}' ;;
*"WorkspaceLabel"*)
  jq -cj --argjson payload "$payload" --argjson workspace "$(has 'team: {null: true}')" '
    {data: {issueLabels: {nodes: [.labels[] | select(.name == $payload.variables.name)
      | select(($workspace | not) or .team == null) | {id}]}}}' "$LABELS_DATA" ;;
*"issueLabelCreate"*|*"issueLabelUpdate"*)
  mutation=issueLabelCreate
  [[ "$query" != *issueLabelUpdate* ]] || mutation=issueLabelUpdate
  jq -cnj --arg m "$mutation" '{data: {($m): {success: true, issueLabel: {id: "new", name: "n", color: "#000000", isGroup: false, parent: null}}}}' ;;
*"AuditIssues"*)
  jq -cj --argjson payload "$payload" --arg fail "$FIXTURE_FAIL" \
    --argjson open "$(has 'state: {type: {nin: ["completed", "canceled"]}}')" \
    --argjson team "$(has 'team: {id: {eq: $teamId}}')" '
    [.issues[] | select(($open | not) or (.state | IN("completed", "canceled") | not))
      | select(($team | not) or .team == $payload.variables.teamId)
      | {identifier, labels: {pageInfo: {hasNextPage: false}, nodes: [{name: .labels[]}]}}] as $rows
    | (if $payload.variables.after == null then
        {pageInfo: {hasNextPage: ($rows | length > 2), endCursor: "c1"}, nodes: $rows[:2]}
      else {pageInfo: {hasNextPage: false, endCursor: "c2"}, nodes: $rows[2:]} end)
    | if $fail == "pages" then del(.pageInfo) else . end
    | {data: {issues: .}}' "$LABELS_DATA" ;;
*"AuditLabels"*)
  jq -cj --argjson payload "$payload" \
    --argjson scoped "$(has 'or: [{team: {id: {eq: $teamId}}}, {team: {null: true}}]')" '
    {data: {issueLabels: {pageInfo: {hasNextPage: false, endCursor: "l1"},
      nodes: [.labels[] | select(($scoped | not) or .team == null or .team.id == $payload.variables.teamId)]}}}' \
    "$LABELS_DATA" ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected fixture query"}]}' ;;
esac
printf '%s' '___HTTP_CODE___200'
SH
chmod +x "$LABELS_PROJECT/bin/curl"

# A linear install outside the project, at global scope, beside a global
# project-management render that declares no taxonomy.
GLOBAL="$TMP_ROOT/global/.agents/skills"
mkdir -p "$GLOBAL/project-management"
cp -R "$SKILL_DIR" "$GLOBAL/linear"
printf '%s\n' '# Project Management' >"$GLOBAL/project-management/SKILL.md"

# The 20-second cap turns a taxonomy walk that never reaches its bound into
# the row's failure rather than a hung suite.
run_labels() { # NAME FAIL PROJECT INSTALL LABELS-ARGS...
  local name="$1" fail="$2" project="$3" install="$4"
  shift 4
  : >"$TMP_ROOT/$name.jsonl"
  (cd -- "$project" && timeout 20 env -i HOME="$TMP_ROOT" PATH="$LABELS_PROJECT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=stub LINEAR_TEAM=kendex LINEAR_CACHE_ROOT="$project" \
    LINEAR_AGENT_LABELS=agent:runtime FIXTURE_FAIL="$fail" CURL_LOG="$TMP_ROOT/$name.jsonl" \
    LABELS_DATA="$LABELS_DATA" "$BASH" "$install/scripts/linear.sh" labels "$@") \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
}

# Where kendex delivered project-management: with method = "copy", only under
# .claude/skills; in kendex projects below a git top level whose own render
# declares `legacy` and not `bug`, one delivering linear to .agents/skills and
# project-management only to .claude/skills; in a project below a git top
# level that installs linear and declares no taxonomy; and twice, in
# .agents/skills and .claude/skills, once agreeing and once not. A repository
# with no render sits in a directory whose render declares `legacy` and not
# `bug`, and runs linear from its source layout.
COPY="$TMP_ROOT/copy"
make_project "$COPY" declared .claude/skills
NESTED="$TMP_ROOT/nested"
make_project "$NESTED/sub" declared
make_project "$NESTED/copy" declared .claude/skills
mkdir -p "$NESTED/copy/.agents/skills" "$NESTED/sub/src" "$NESTED/.agents/skills/project-management"
mv -- "$NESTED/copy/.claude/skills/linear" "$NESTED/copy/.agents/skills/"
rm -rf -- "${NESTED:?}/sub/.git" "${NESTED:?}/copy/.git"
printf '%s\n' '<!-- kendex:project-instructions:start -->' '### Project taxonomy' '```json' \
  '{"categories": {"surface": {"labels": ["legacy"]}}}' '```' \
  '<!-- kendex:project-instructions:end -->' >"$NESTED/.agents/skills/project-management/SKILL.md"
git -C "$NESTED" init -q -b main
git -C "$NESTED" config gc.auto 0
git -C "$NESTED" config maintenance.auto false
TOP="$TMP_ROOT/top"
make_project "$TOP/sub" declared
rm -rf -- "${TOP:?}/sub/.git" "${TOP:?}/sub/.agents/skills/linear"
mkdir -p "$TOP/sub/src"
make_project "$TOP" no-heading
ABOVE="$TMP_ROOT/above"
make_project "$ABOVE/repo" none skills
mkdir -p "$ABOVE/.agents/skills"
cp -R -- "$NESTED/.agents/skills/project-management" "$ABOVE/.agents/skills/"
for twin in agree differ; do
  make_project "$TMP_ROOT/$twin" declared
  mkdir -p "$TMP_ROOT/$twin/.claude/skills"
  cp -R "$TMP_ROOT/$twin/.agents/skills/project-management" "$TMP_ROOT/$twin/.claude/skills/"
done
printf '%s\n' '# Project Management' >"$TMP_ROOT/differ/.claude/skills/project-management/SKILL.md"
# A catalog checkout runs the CLI from its source layout, beside the unrendered
# project-management source.
mkdir -p "$LABELS_PROJECT/skills/project-management"
cp -R "$SKILL_DIR" "$LABELS_PROJECT/skills/linear"
printf '%s\n' '# Project Management' >"$LABELS_PROJECT/skills/project-management/SKILL.md"

LABELS_TAXONOMY="$LABELS_PROJECT/.agents/skills/project-management/SKILL.md"
while IFS='|' read -r name want key project install args; do
  project="${project:-$LABELS_PROJECT}"
  # shellcheck disable=SC2086 # args is the row's word list
  run_status rc run_labels "$name" "" "$project" "${install:-$project/.agents/skills/linear}" $args
  if [[ "$want" == refused ]]; then
    assert_ne "$name: refused" "$rc" 0
    assert_file_contains "$name: the refusal is keyed" "$TMP_ROOT/$name.err" "$key"
    assert_not "$name: no label is written" grep -qE 'issueLabelCreate|issueLabelUpdate' "$TMP_ROOT/$name.jsonl"
  else
    assert_eq "$name: accepted" "$rc" 0
    assert "$name: the label is written" grep -qE 'issueLabelCreate|issueLabelUpdate' "$TMP_ROOT/$name.jsonl"
  fi
done <<ROWS
label-undeclared|refused|linear-labels: undeclared labels=legacy taxonomy=$LABELS_TAXONOMY|||create --name legacy
label-outside-install|refused|linear-labels: undeclared labels=legacy taxonomy=$LABELS_TAXONOMY||$GLOBAL/linear|create --name legacy
label-source-layout|refused|linear-labels: undeclared labels=legacy taxonomy=$LABELS_TAXONOMY||$LABELS_PROJECT/skills/linear|create --name legacy
label-copy-delivery|refused|linear-labels: undeclared labels=legacy taxonomy=$COPY/.claude/skills/project-management/SKILL.md|$COPY|$COPY/.claude/skills/linear|create --name legacy
label-copy-outside-install|refused|linear-labels: undeclared labels=legacy taxonomy=$COPY/.claude/skills/project-management/SKILL.md|$COPY|$GLOBAL/linear|create --name legacy
label-nested-project|refused|linear-labels: undeclared labels=legacy taxonomy=$NESTED/sub/.agents/skills/project-management/SKILL.md|$NESTED/sub||create --name legacy
label-nested-declared|accepted||$NESTED/sub||create --name bug
label-nested-from-top|refused|linear-labels: undeclared labels=legacy taxonomy=$NESTED/sub/.agents/skills/project-management/SKILL.md|$NESTED|$NESTED/sub/.agents/skills/linear|create --name legacy
label-nested-global|refused|linear-labels: undeclared labels=legacy taxonomy=$NESTED/sub/.agents/skills/project-management/SKILL.md|$NESTED/sub/src|$GLOBAL/linear|create --name legacy
label-nested-top-install|refused|linear-labels: undeclared labels=legacy taxonomy=$TOP/sub/.agents/skills/project-management/SKILL.md|$TOP/sub/src|$TOP/.agents/skills/linear|create --name legacy
label-above-global|accepted||$ABOVE/repo|$GLOBAL/linear|create --name bug
label-above-source-layout|accepted||$ABOVE/repo|$ABOVE/repo/skills/linear|create --name bug
label-nested-copy|refused|linear-labels: undeclared labels=legacy taxonomy=$NESTED/copy/.claude/skills/project-management/SKILL.md|$NESTED/copy||create --name legacy
label-renders-agree|accepted||$TMP_ROOT/agree||create --name bug
label-renders-differ|refused|linear-labels: taxonomy-unreadable taxonomy=$TMP_ROOT/differ/.agents/skills/project-management/SKILL.md differs=$TMP_ROOT/differ/.claude/skills/project-management/SKILL.md|$TMP_ROOT/differ||create --name bug
label-declared|accepted||||create --name bug
label-group|accepted||||create --name Platform --group
label-comma|refused|linear-labels: undeclared labels=skills,bug taxonomy=$LABELS_TAXONOMY|||create --name skills,bug
label-workspace-duplicate|refused|linear-labels: workspace-duplicate name=bug|||create --name bug --team kendex
label-team|accepted||||create --name skills --team kendex
label-rename-undeclared|refused|linear-labels: undeclared labels=legacy taxonomy=$LABELS_TAXONOMY|||update team-skills --name legacy
label-rename-comma|refused|linear-labels: undeclared labels=skills,bug taxonomy=$LABELS_TAXONOMY|||update team-skills --name skills,bug
label-rename-workspace-duplicate|refused|linear-labels: workspace-duplicate name=bug|||update team-skills --name bug
label-rename-self|accepted||||update ws-bug --name bug
label-rename|accepted||||update team-skills --name macos
ROWS

NO_TAXONOMY="$TMP_ROOT/labels-none"
make_project "$NO_TAXONOMY" none
run_status rc run_labels label-team-none "" "$NO_TAXONOMY" "$NO_TAXONOMY/.agents/skills/linear" create --name bug --team kendex
assert_eq "label-team-none: no taxonomy keeps today's team label create" "$rc" 0
assert_not "label-team-none: no workspace lookup is sent" grep -q WorkspaceLabel "$TMP_ROOT/label-team-none.jsonl"

run_status rc run_labels audit "" "$LABELS_PROJECT" "$LABELS_PROJECT/.agents/skills/linear" audit
assert_eq "audit: succeeds" "$rc" 0
assert "audit: lists each undeclared label with the open issues carrying it" \
  jq -e '.undeclared == [{label: "harness", issues: ["KEN-3"]}, {label: "legacy", issues: ["KEN-1", "KEN-2"]}]' \
  "$TMP_ROOT/audit.out"
assert "audit: reads the open issues past the first page" \
  jq -e '[.undeclared[].issues[]] | index("KEN-3") != null' "$TMP_ROOT/audit.out"
assert "audit: skips closed issues" jq -e '[.undeclared[].label] | index("ancient") == null' "$TMP_ROOT/audit.out"
assert "audit: reads only the team's issues" jq -e '[.undeclared[].label] | index("foreign") == null' "$TMP_ROOT/audit.out"
assert "audit: lists the same-name team and workspace pair" \
  jq -e '.same_name == [{name: "harness", workspace_label: "ws-harness", team_label: "team-harness"}]' \
  "$TMP_ROOT/audit.out"
assert "audit: ignores another team's same-name label" \
  jq -e '[.same_name[].name] | index("bug") == null' "$TMP_ROOT/audit.out"

run_status rc run_labels audit-pages pages "$LABELS_PROJECT" "$LABELS_PROJECT/.agents/skills/linear" audit
assert_ne "audit-pages: refused" "$rc" 0
assert_file_contains "audit-pages: a page with no pageInfo fails the audit" \
  "$TMP_ROOT/audit-pages.err" "linear-labels: audit-incomplete connection=issues"

run_status rc run_labels audit-absent "" "$NO_TAXONOMY" "$NO_TAXONOMY/.agents/skills/linear" audit
assert_ne "audit-absent: refused" "$rc" 0
assert_file_contains "audit-absent: no taxonomy has nothing to audit against" \
  "$TMP_ROOT/audit-absent.err" "linear-labels: taxonomy-absent taxonomy=$NO_TAXONOMY/.agents/skills/project-management/SKILL.md"
assert_not "audit-absent: no issue is read" grep -q AuditIssues "$TMP_ROOT/audit-absent.jsonl"

# `labels declared` splits by the declared set the refusals above read.
run_status rc run_labels declared "" "$LABELS_PROJECT" "$LABELS_PROJECT/.agents/skills/linear" declared "skills,legacy, bug,agent:runtime,harness"
assert_eq "declared: succeeds" "$rc" 0
assert "declared: keeps the declared names in list order and drops the rest" \
  jq -e '. == {kept: ["skills", "bug", "agent:runtime"], dropped: ["legacy", "harness"]}' "$TMP_ROOT/declared.out"
assert_not "declared: no request is sent" test -s "$TMP_ROOT/declared.jsonl"

run_status rc run_labels declared-none "" "$NO_TAXONOMY" "$NO_TAXONOMY/.agents/skills/linear" declared "legacy,bug"
assert_eq "declared-none: succeeds" "$rc" 0
assert "declared-none: no taxonomy keeps every name" \
  jq -e '. == {kept: ["legacy", "bug"], dropped: []}' "$TMP_ROOT/declared-none.out"

run_status rc run_labels declared-differ "" "$TMP_ROOT/differ" "$TMP_ROOT/differ/.agents/skills/linear" declared bug
assert_ne "declared-differ: refused" "$rc" 0
assert_file_contains "declared-differ: an unreadable taxonomy splits nothing" \
  "$TMP_ROOT/declared-differ.err" "linear-labels: taxonomy-unreadable"
