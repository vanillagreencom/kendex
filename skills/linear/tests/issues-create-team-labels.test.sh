#!/usr/bin/env bash
# `issues create --labels` resolves each name against the create's own team and
# workspace labels. Two teams can own a label of one name, and an unscoped
# lookup sends whichever the API lists first, which Linear refuses with
# "labelIds for incorrect team". The credential selects no label scope, so the
# app token and the personal key send the same ids.

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
