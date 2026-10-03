#!/usr/bin/env bash
# `issues create --labels` resolves each name against the create's own team and
# workspace labels. Two teams can own a label of one name, and an unscoped
# lookup sends whichever the API lists first, which Linear refuses with
# "labelIds for incorrect team". The credential selects no label scope, so the
# app token and the personal key send the same ids. An --attach create resolves
# its agent labels before the upload, under the same scope.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P)
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
install_label_team_fixture "$PROJECT"

# The fixture lists the vsys `skills` label before the kendex one.
while IFS='|' read -r name credential; do
  : >"$TMP_ROOT/$name.jsonl"
  run_status rc env -i HOME="$TMP_ROOT" PATH="$PROJECT/bin:$PATH" "$credential" \
    LINEAR_TEAM=vsys LINEAR_CACHE_ROOT="$PROJECT" FIXTURE_FAIL= \
    FIXTURE_DIR="$SKILL_DIR/tests/lib/fixtures" CURL_LOG="$TMP_ROOT/$name.jsonl" \
    "$BASH" "$PROJECT/.agents/skills/linear/scripts/linear.sh" issues create \
    --team kendex --title "Team labels" --description "Reached by: this suite" \
    --labels "skills,agent:runtime" >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
  assert_eq "$name: create succeeds" "$rc" 0
  assert "$name: create sends the kendex team and its label ids" \
    jq -s -e '[.[] | select(.query | contains("issueCreate")) | .variables.input | {teamId, labelIds}]
      == [{teamId: "team-uuid", labelIds: ["ffe14296-09dd-4fa7-a53e-3da3515a3e0f", "469598a4-6a78-4ff9-be12-25b92244b2c2"]}]' \
    "$TMP_ROOT/$name.jsonl"
done <<'ROWS'
key|LINEAR_API_KEY_OVERRIDE=stub
app|LINEAR_APP_TOKEN=stub
ROWS

# A team UUID is one reference to both judges: resolve_team_id passes it
# through as the create's teamId, and the label lookups scope by that same id.
# Uppercase hex is a UUID to both, so no name lookup runs for it.
TEAM_UUID=9A1B2C3D-4E5F-4A6B-8C7D-0E1F2A3B4C5D
: >"$TMP_ROOT/uuid.jsonl"
run_status rc env -i HOME="$TMP_ROOT" PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=stub \
  LINEAR_TEAM=vsys LINEAR_CACHE_ROOT="$PROJECT" FIXTURE_FAIL= \
  FIXTURE_DIR="$SKILL_DIR/tests/lib/fixtures" CURL_LOG="$TMP_ROOT/uuid.jsonl" \
  "$BASH" "$PROJECT/.agents/skills/linear/scripts/linear.sh" issues create \
  --team "$TEAM_UUID" --title "Team UUID" --description "Reached by: this suite" \
  --labels "skills,agent:runtime" >"$TMP_ROOT/uuid.out" 2>"$TMP_ROOT/uuid.err"
assert_eq "uuid: create succeeds" "$rc" 0
assert "uuid: the create and its label lookups send the one team id" \
  jq -s -e --arg team "$TEAM_UUID" '
    ([.[] | select(.query | contains("teams(filter:"))] == [])
    and ([.[] | select(.query | contains("issueCreate")) | .variables.input.teamId] == [$team])
    and ([.[] | select(.query | contains("issueLabels")) | .variables.teamName] == [$team, $team])' \
  "$TMP_ROOT/uuid.jsonl"

# With --attach under a declared taxonomy, agent labels resolve before the
# upload, against the create's team. The private fixture gives vsys alone an
# agent:rust label, so a kendex create refuses with nothing uploaded.
FIXTURES="$TMP_ROOT/fixtures"
mkdir -p "$FIXTURES"
cp -- "$SKILL_DIR/tests/lib/fixtures/label-team-issue.json" "$FIXTURES/"
jq '.issueLabels.nodes += [{id: "5d0c4ac5-5b1e-4a5f-9d43-7c2b0f8e1a96", name: "agent:rust", team: {name: "vsys"}}]' \
  "$SKILL_DIR/tests/lib/fixtures/issue-team-labels.json" >"$FIXTURES/issue-team-labels.json"
printf 'x' >"$TMP_ROOT/asset.bin"
: >"$TMP_ROOT/attach.jsonl"
run_status rc env -i HOME="$TMP_ROOT" PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=stub \
  LINEAR_TEAM=vsys LINEAR_AGENT_LABELS=agent:rust LINEAR_CACHE_ROOT="$PROJECT" FIXTURE_FAIL= \
  FIXTURE_DIR="$FIXTURES" CURL_LOG="$TMP_ROOT/attach.jsonl" \
  "$BASH" "$PROJECT/.agents/skills/linear/scripts/linear.sh" issues create \
  --team kendex --title "Foreign agent label" --description "Reached by: this suite" \
  --labels "skills,agent:rust" --attach "$TMP_ROOT/asset.bin" >"$TMP_ROOT/attach.out" 2>"$TMP_ROOT/attach.err"
assert_ne "attach: another team's agent label refuses the create" "$rc" 0
assert_file_lacks "attach: no upload is sent for another team's agent label" \
  "$TMP_ROOT/attach.jsonl" "fileUpload"
