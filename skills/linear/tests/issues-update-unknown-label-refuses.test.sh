#!/usr/bin/env bash
# `issues update --labels` replaces the whole label set, so a requested name
# that resolves to nothing must refuse the update: silently dropping it ships
# a partial set — the same wipe class as a lookup failure.

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

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
ERR_FILE="$TMP_ROOT/stderr.txt"

cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query="$(jq -r '.query' <<<"$payload")"
case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"team-uuid","name":"TestTeam"}]}}}___HTTP_CODE___200'
  ;;
*"issueLabels(filter:"*)
  name="$(jq -r '.variables.name // empty' <<<"$payload")"
  if [ "$name" = "ghost-label" ]; then
    printf '%s' '{"data":{"issueLabels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"issueLabels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"lbl-1","name":"real-label"}]}}}___HTTP_CODE___200'
  fi
  ;;
*"issue(id:"*|*"issues(filter:"*)
  printf '%s' '{"data":{"issue":{"id":"iss-uuid","identifier":"ISS-1","team":{"id":"team-uuid","name":"TestTeam"}}}}___HTTP_CODE___200'
  ;;
*"issueUpdate"*)
  printf '%s' '{"data":{"issueUpdate":{"success":true,"issue":{"id":"iss-uuid","identifier":"ISS-1"}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

run_update() {
  ( cd -- "$PROJECT" \
    && env -i HOME="$TMP_ROOT" \
       CURL_LOG="$CURL_LOG" PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=stub LINEAR_TEAM=ISS \
       "$LINEAR" issues update ISS-1 --labels "$1" ) >"$TMP_ROOT/out.txt" 2>"$ERR_FILE"
}

# Unknown label → refuse before any mutation.
: >"$CURL_LOG"
run_status refuse_rc run_update "real-label,ghost-label"

assert_ne "unknown label refuses the update" "$refuse_rc" 0
assert_file_contains "the refusal names the unknown label" "$ERR_FILE" "ghost-label"
assert_jq "the refusal names the issue team" "$(cat "$ERR_FILE")" '.error | contains("TestTeam")'
assert_file_lacks "no mutation was sent for the refused update" "$CURL_LOG" "issueUpdate"

# Unknown label + --attach → refuse BEFORE the upload, so no asset is
# stranded in Linear storage (labels resolve ahead of upload_attach_paths).
: >"$CURL_LOG"
printf 'x' >"$TMP_ROOT/asset.bin"
attach_rc=0
( cd -- "$PROJECT" \
  && env -i HOME="$TMP_ROOT" \
     CURL_LOG="$CURL_LOG" PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY_OVERRIDE=stub LINEAR_TEAM=ISS \
     "$LINEAR" issues update ISS-1 --labels "ghost-label" --attach "$TMP_ROOT/asset.bin" ) \
     >"$TMP_ROOT/out.txt" 2>"$ERR_FILE" || attach_rc=$?

assert_ne "unknown label with --attach refuses the update" "$attach_rc" 0
assert_not "no upload was sent before the refusal" grep -qiE "fileUpload|attachment" "$CURL_LOG"

# Control: all labels resolve → the update proceeds and mutates.
: >"$CURL_LOG"
run_status valid_rc run_update "real-label"

assert_eq "a fully-resolved label set still updates" "$valid_rc" 0
assert_file_contains "the valid update sends its mutation" "$CURL_LOG" "issueUpdate"

install_label_team_fixture "$PROJECT"
run_status live_rc run_label_team_request "$PROJECT" live "" update KEN-2413 --labels "harness,agent:runtime,baseline"
assert_eq "recorded update succeeds across the configured team boundary" "$live_rc" 0
assert "update uses live issue-team and workspace label IDs" \
  jq -s -e '[.[] | select(.query | contains("issueUpdate")) | .variables.input.labelIds]
    == [["19771d95-12c6-47fe-8f09-a820ec98b927", "469598a4-6a78-4ff9-be12-25b92244b2c2", "e308b7eb-1c70-4d3f-bd86-9cb359f2b088"]]' \
  "$TMP_ROOT/live.jsonl"
assert_file_lacks "update never sends the cached fleet label ID" \
  "$TMP_ROOT/live.jsonl" "e79890c4-77ea-414a-9c92-b41ca6de4501"

# Linear can return no label, fail a lookup, or fail the issue read. Each
# refusal must leave both the issue and attachment storage unchanged.
while IFS='|' read -r name fail labels needle; do
  run_status rc run_label_team_request "$PROJECT" "$name" "$fail" \
    update KEN-2413 --labels "$labels" --attach "$TMP_ROOT/asset.bin"
  assert_ne "$name: update refuses" "$rc" 0
  assert_file_contains "$name: refusal names its cause" "$TMP_ROOT/$name.err" "$needle"
  assert_not "$name: no mutation or upload is sent" \
    grep -qiE 'issueUpdate|fileUpload|attachmentCreate' "$TMP_ROOT/$name.jsonl"
done <<'ROWS'
foreign||harness,secrets|secrets
unknown||harness,ghost-label|ghost-label
lookup-failed|labels|harness|label service unavailable
issue-failed|issue|harness|issue service unavailable
team-missing|team|harness|KEN-2413
ROWS
assert_jq "a foreign-only label refusal names the actual issue team" \
  "$(cat "$TMP_ROOT/foreign.err")" '.error | contains("kendex") and contains("secrets")'
