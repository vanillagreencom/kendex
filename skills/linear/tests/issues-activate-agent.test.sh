#!/usr/bin/env bash
# issues activate --agent must apply the exclusive
# agent:<name> label (same issueUpdate as the state change) or fail loudly
# before any state change when the label does not exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P)
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# Isolate CACHE_DIR resolution (git rev-parse --show-toplevel) to this
# throwaway root — without this, cache writes land in the real project's
# `.cache/linear`.
git -C "$TMP_ROOT" init -q -b main
git -C "$TMP_ROOT" config gc.auto 0
git -C "$TMP_ROOT" config maintenance.auto false

cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
variables="$(jq -c '.variables' <<<"$payload")"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"

case "$query" in
*"issueLabels(filter:"*)
  case "$(jq -r '.name' <<<"$variables")" in
  "agent:rust")
    printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-agent-rust"}]}}}___HTTP_CODE___200'
    ;;
  "backend")
    printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-backend"}]}}}___HTTP_CODE___200'
    ;;
  *)
    printf '%s' '{"data":{"issueLabels":{"nodes":[]}}}___HTTP_CODE___200'
    ;;
  esac
  ;;
*"workflowStates(filter:"*)
  printf '%s' '{"data":{"workflowStates":{"nodes":[{"id":"state-in-progress"}]}}}___HTTP_CODE___200'
  ;;
*"issue(id:"*)
  printf '%s' '{"data":{"issue":{"id":"issue-uuid","identifier":"CC-760","title":"t","description":null,"state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"team":{"id":"7d1e4b2a-9c3f-4a68-b5e0-2f8c6d1a9e47","name":"Claude"},"labels":{"nodes":[{"name":"agent:old"},{"name":"backend"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-760","branchName":"cc-760","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:00Z","archivedAt":null,"trashed":null,"parent":null,"children":{"nodes":[]},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}___HTTP_CODE___200'
  ;;
*"issueUpdate(id:"*)
  printf '%s' '{"data":{"issueUpdate":{"success":true,"issue":{"id":"issue-uuid","identifier":"CC-760","title":"t","description":null,"state":{"name":"In Progress","type":"started"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Claude"},"labels":{"nodes":[{"name":"backend"},{"name":"agent:rust"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-760","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:01Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

run_activate() {
  local payload_log="$1"
  shift
  : >"$payload_log"
  (cd -- "$TMP_ROOT" && env -i HOME="$TMP_ROOT" PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_CACHE_ROOT="$TMP_ROOT" LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam KENDEX_USER_EMAIL= \
    CURL_PAYLOAD_LOG="$payload_log" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues activate "$@")
}

# --- activate --agent applies the label in the same issueUpdate as the state change
agent_payload="$TMP_ROOT/agent-payloads.jsonl"
agent_rc=0
out="$(run_activate "$agent_payload" CC-760 --agent rust 2>"$TMP_ROOT/agent.err")" || agent_rc=$?
assert_eq "activate --agent exits zero" "$agent_rc" 0

assert_jq "activate --agent reports the claimed agent" \
  "$out" '.success == true and .action == "activated" and .agent == "rust"'
assert "issueUpdate carries the state and the replaced agent label set in one mutation" \
  jq -s -e 'any(.[]; (.query | contains("issueUpdate"))
    and .variables.input.stateId == "state-in-progress"
    and .variables.input.labelIds == ["label-backend", "label-agent-rust"])' "$agent_payload"
assert_eq "activate --agent sends exactly one issueUpdate mutation" \
  "$(jq -s '[.[] | select(.query | contains("issueUpdate"))] | length' "$agent_payload")" "1"

# --- unknown agent fails before any state change
bogus_payload="$TMP_ROOT/bogus-payloads.jsonl"
rc=0
run_activate "$bogus_payload" CC-760 --agent bogus >"$TMP_ROOT/bogus.out" 2>"$TMP_ROOT/bogus.err" || rc=$?

assert_ne "activate --agent with an unknown agent fails" "$rc" 0
assert_jq "the refusal names the issue team and missing agent label" \
  "$(cat "$TMP_ROOT/bogus.err")" '.error | contains("Claude") and contains("agent:bogus")'
assert_not "an unknown agent label mutates no issue state" \
  jq -s -e 'any(.[]; .query | contains("issueUpdate"))' "$bogus_payload"

# --- activate without --agent keeps prior behavior (state only, no labels touched)
plain_payload="$TMP_ROOT/plain-payloads.jsonl"
plain_rc=0
out="$(run_activate "$plain_payload" CC-760 2>"$TMP_ROOT/plain.err")" || plain_rc=$?
assert_eq "plain activate exits zero" "$plain_rc" 0

assert_jq "plain activate reports no agent" \
  "$out" '.success == true and .action == "activated" and (has("agent") | not)'
assert "plain activate sends the state change without labelIds" \
  jq -s -e 'any(.[]; (.query | contains("issueUpdate"))
    and .variables.input.stateId == "state-in-progress"
    and (.variables.input | has("labelIds") | not))' "$plain_payload"

install_label_team_fixture "$TMP_ROOT"
run_status live_rc run_label_team_request "$TMP_ROOT" live "" activate KEN-2413 --agent runtime
assert_eq "recorded activation succeeds across the configured team boundary" "$live_rc" 0
assert "activation uses live issue-team and workspace label IDs" \
  jq -s -e '[.[] | select(.query | contains("issueUpdate")) | .variables.input]
    == [{stateId: "state-in-progress", labelIds: ["19771d95-12c6-47fe-8f09-a820ec98b927", "469598a4-6a78-4ff9-be12-25b92244b2c2"]}]' \
  "$TMP_ROOT/live.jsonl"
assert_file_lacks "activation never sends the cached fleet label ID" \
  "$TMP_ROOT/live.jsonl" "e79890c4-77ea-414a-9c92-b41ca6de4501"

run_status missing_rc run_label_team_request "$TMP_ROOT" missing "" activate KEN-2413 --agent bogus
assert_ne "recorded activation refuses an unresolved agent" "$missing_rc" 0
assert_jq "recorded activation refusal names the team and agent" \
  "$(cat "$TMP_ROOT/missing.err")" '.error | contains("kendex") and contains("agent:bogus")'
assert_file_lacks "recorded activation refusal sends no mutation" "$TMP_ROOT/missing.jsonl" "issueUpdate"
