#!/usr/bin/env bash
# Regression test for #552: issues activate --agent must apply the exclusive
# agent:<name> label (same issueUpdate as the state change) or fail loudly
# before any state change when the label does not exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# Isolate CACHE_DIR resolution (git rev-parse --show-toplevel) to this
# throwaway root — without this, cache writes land in the real project's
# `.cache/linear` (kendex#43).
git -C "$TMP_ROOT" init -q -b main

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
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"workflowStates(filter:"*)
  printf '%s' '{"data":{"workflowStates":{"nodes":[{"id":"state-in-progress"}]}}}___HTTP_CODE___200'
  ;;
*"issue(id:"*)
  printf '%s' '{"data":{"issue":{"id":"issue-uuid","identifier":"CC-760","title":"t","description":null,"state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"team":{"name":"Claude"},"labels":{"nodes":[{"name":"agent:old"},{"name":"backend"}]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/test/issue/CC-760","branchName":"cc-760","createdAt":"2026-07-14T00:00:00Z","updatedAt":"2026-07-14T00:00:00Z","archivedAt":null,"trashed":null,"parent":null,"children":{"nodes":[]},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}___HTTP_CODE___200'
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
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    CURL_PAYLOAD_LOG="$payload_log" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues activate "$@")
}

# --- activate --agent applies the label in the same issueUpdate as the state change
agent_payload="$TMP_ROOT/agent-payloads.jsonl"
out="$(run_activate "$agent_payload" CC-760 --agent rust 2>"$TMP_ROOT/agent.err")" || true

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
assert_file_contains "the refusal names the missing agent label" \
  "$TMP_ROOT/bogus.err" "Agent label not found: 'agent:bogus'"
assert_not "an unknown agent label mutates no issue state" \
  jq -s -e 'any(.[]; .query | contains("issueUpdate"))' "$bogus_payload"

# --- activate without --agent keeps prior behavior (state only, no labels touched)
plain_payload="$TMP_ROOT/plain-payloads.jsonl"
out="$(run_activate "$plain_payload" CC-760 2>"$TMP_ROOT/plain.err")" || true

assert_jq "plain activate reports no agent" \
  "$out" '.success == true and .action == "activated" and (has("agent") | not)'
assert "plain activate sends the state change without labelIds" \
  jq -s -e 'any(.[]; (.query | contains("issueUpdate"))
    and .variables.input.stateId == "state-in-progress"
    and (.variables.input | has("labelIds") | not))' "$plain_payload"
