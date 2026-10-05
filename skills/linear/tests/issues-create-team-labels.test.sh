#!/usr/bin/env bash
# `issues create --labels` resolves the create's team once, then resolves each
# label name against that team's id and the workspace labels. Two teams can own
# a label of one name, and an unscoped lookup sends whichever the API lists
# first, which Linear refuses with "labelIds for incorrect team". The credential
# selects no label scope, so the app token and the personal key send the same
# ids. An --attach create resolves its agent labels before the upload, under
# the same scope, and an unknown team refuses before any label lookup.

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

KENDEX_TEAM_ID=5c2e9f71-a4b8-4d36-91e0-7f3d6b2c8a15
WORKSPACE_RUNTIME=469598a4-6a78-4ff9-be12-25b92244b2c2

# The fixture lists the vsys `skills` label before the kendex one.
while IFS='|' read -r name credential; do
  # shellcheck disable=SC2086 # the credential column is zero or more NAME=VALUE words
  run_status rc run_label_team_request "$PROJECT" "$name" "" $credential \
    create --team kendex --title "Team labels" --labels "skills,agent:runtime"
  assert_eq "$name: create succeeds" "$rc" 0
  assert "$name: create sends the kendex team and its label ids" \
    jq -s -e --arg team "$KENDEX_TEAM_ID" --arg runtime "$WORKSPACE_RUNTIME" '
      [.[] | select(.query | contains("issueCreate")) | .variables.input | {teamId, labelIds}]
      == [{teamId: $team, labelIds: ["ffe14296-09dd-4fa7-a53e-3da3515a3e0f", $runtime]}]' \
    "$TMP_ROOT/$name.jsonl"
done <<'ROWS'
key|
app|LINEAR_API_KEY_OVERRIDE= LINEAR_APP_TOKEN=stub
ROWS

# A team UUID is one reference to both judges: resolve_team_id passes it
# through as the create's teamId, and the label lookups scope by that same id.
# Uppercase hex is a UUID to resolve_team_id, so no name lookup runs for it.
# The fixture has no team of this id, so only the workspace label resolves.
# The UUID is also the configured team, so the cross-team guard reads nothing.
TEAM_UUID=9A1B2C3D-4E5F-4A6B-8C7D-0E1F2A3B4C5D
run_status rc run_label_team_request "$PROJECT" uuid "" LINEAR_TEAM="$TEAM_UUID" \
  create --team "$TEAM_UUID" --title "Team UUID" --labels "skills,agent:runtime"
assert_eq "uuid: create succeeds" "$rc" 0
assert "uuid: no team lookup, and the create and its label lookups send the one team id" \
  jq -s -e --arg team "$TEAM_UUID" '
    ([.[] | select(.query | contains("teams(filter:"))] == [])
    and ([.[] | select(.query | contains("issueCreate")) | .variables.input.teamId] == [$team])
    and ([.[] | select(.query | contains("issueLabels")) | .variables.teamId] == [$team, $team])' \
  "$TMP_ROOT/uuid.jsonl"
assert "uuid: create sends only workspace labels for a team that owns none" \
  jq -s -e --arg runtime "$WORKSPACE_RUNTIME" '
    [.[] | select(.query | contains("issueCreate")) | .variables.input.labelIds] == [[$runtime]]' \
  "$TMP_ROOT/uuid.jsonl"

printf 'x' >"$TMP_ROOT/asset.bin"

# The team resolves before the label lookups: a team that matches nothing
# refuses as itself, with no label lookup and no upload. It is also the
# configured team, so the create's own resolution, not the cross-team guard,
# meets it.
run_status rc run_label_team_request "$PROJECT" unknown-team "" LINEAR_AGENT_LABELS=agent:runtime LINEAR_TEAM=ghost \
  create --team ghost --title "Unknown team" --labels "agent:runtime" --attach "$TMP_ROOT/asset.bin"
assert_file_contains "unknown-team: the refusal names the team" \
  "$TMP_ROOT/unknown-team.err" "Team not found: ghost"
assert_not "unknown-team: no label lookup or upload is sent" \
  grep -qE 'issueLabels|fileUpload' "$TMP_ROOT/unknown-team.jsonl"

# A failed label lookup leaves the label's existence unknown, so the create
# refuses rather than skipping the label as absent.
run_status rc run_label_team_request "$PROJECT" lookup-failed labels \
  create --team kendex --title "Lookup failed" --labels "skills"
assert_file_contains "lookup-failed: the create refuses rather than dropping the label" \
  "$TMP_ROOT/lookup-failed.err" "refusing the create rather than dropping"
assert_file_lacks "lookup-failed: no issueCreate is sent" \
  "$TMP_ROOT/lookup-failed.jsonl" "issueCreate"

# With --attach under a declared taxonomy, agent labels resolve before the
# upload, against the create's team. The private fixture gives vsys alone an
# agent:rust label, so a kendex create refuses with nothing uploaded.
FIXTURES="$TMP_ROOT/fixtures"
mkdir -p "$FIXTURES"
cp -- "$SKILL_DIR/tests/lib/fixtures/label-team-issue.json" "$FIXTURES/"
jq '.issueLabels.nodes += [{id: "60cc6fb0-773f-4279-9015-86940d812d8e", name: "agent:rust",
      team: first(.issueLabels.nodes[].team | select(. != null and .name == "vsys"))}]' \
  "$SKILL_DIR/tests/lib/fixtures/issue-team-labels.json" >"$FIXTURES/issue-team-labels.json"
run_status rc run_label_team_request "$PROJECT" attach "" LINEAR_AGENT_LABELS=agent:rust FIXTURE_DIR="$FIXTURES" \
  create --team kendex --title "Foreign agent label" --labels "skills,agent:rust" \
  --attach "$TMP_ROOT/asset.bin"
assert_file_contains "attach: the label resolution refuses, naming the agent label" \
  "$TMP_ROOT/attach.err" "Agent label failed to resolve in Linear: agent:rust - refusing to create"
assert_file_lacks "attach: no upload is sent for another team's agent label" \
  "$TMP_ROOT/attach.jsonl" "fileUpload"
