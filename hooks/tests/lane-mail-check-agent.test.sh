#!/usr/bin/env bash
# Attached launches and child state at the context mark. The hook is installed
# in lib/lane-mail-world.sh's real lane and fleet layouts. Only Claude's
# measured Agent id and task-notification status records are transcript inputs.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

launch() { # TOKENS TOOL [ENV...]
  local tokens="$1" tool="$2"
  shift 2
  write_transcript "$TRANSCRIPT" "$tokens"
  ARM_ARGS=(halt)
  run_payload "$(jq -nc --arg t "$tool" --arg p "$TRANSCRIPT" \
    '{session_id:"s1",transcript_path:$p,tool_name:$t,tool_input:{}}')" "$@"
  ARM_ARGS=()
}

new_lane agent_launch AGENT-1
mkdir -p "$LANE/tmp/lane-mail/AGENT-1"
TRANSCRIPT="$TMP_ROOT/agent-launch.jsonl"
while IFS='|' read -r tokens tool reserve rc key; do
  launch "$tokens" "$tool" "ORCH_HANDOFF_AGENT_RESERVE_TOKENS=$reserve"
  expect "$rc" "$key" "launch $tool at $tokens with reserve $reserve"
done <<'ROWS'
249999|Agent||0|-
250000|Agent||2|lane-mail-check: agent-launch=Agent tokens=250000 reserve=150000
250001|Agent||2|lane-mail-check: agent-launch=Agent tokens=250001 reserve=150000
100000|Agent|50000|0|-
250000|Bash||0|-
600000|TaskOutput||0|-
250000|Agent|nope|2|lane-mail-check: setting-range=ORCH_HANDOFF_AGENT_RESERVE_TOKENS=nope
250000|Agent|-1|2|lane-mail-check: setting-range=ORCH_HANDOFF_AGENT_RESERVE_TOKENS=-1
0|Agent|400000|2|lane-mail-check: agent-launch=Agent tokens=0 reserve=400000
ROWS
launch 250000 Agent
assert_eq "$(sed -n 's/^lane-mail-check: detached-route=//p' "$ERR_FILE")" orch-job-runner 'refusal names the existing detached route'
usage_line sonnet 100000 > "$TRANSCRIPT"
ARM_ARGS=(halt)
run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",transcript_path:$p,tool_name:"Agent"}')"
expect 2 'lane-mail-check: agent-input=context-unmeasured' 'an unknown capacity establishes no launch room'
run_payload '{"session_id":"s1","tool_name":"Agent"}'
expect 2 'lane-mail-check: agent-input=transcript-unnamed' 'an absent reading establishes no launch room'
ARM_ARGS=()

# An ordinary checkout, or a child caller, never inherits the lead's mark.
launch 250000 Agent 'LANE_MAIL_ITEM=AGENT-1'
ARM_ARGS=(halt)
run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",agent_id:"a1",transcript_path:$p,tool_name:"Agent"}')"
expect 0 - 'a child does not meet the lead launch mark'
ARM_ARGS=()
unmark_lanes
launch 600000 Agent
expect 0 - 'an ordinary session is outside the lane mark'

while IFS='|' read -r harness tool tokens window rc; do
  new_lane "agent_$harness-$tool-$tokens" AGENT-1
  mkdir -p "$LANE/tmp/lane-mail/AGENT-1"
  case "$harness" in
    codex) install_hook "$HOOK" "$LANE/.codex/hooks/lane-mail-check.sh" ;;
    pi) install_hook "$HOOK" "$LANE/.pi/kendex/hooks/lane-mail-check.sh" ;;
  esac
  usage_line "$harness" "$tokens" > "$TRANSCRIPT"
  ARM_ARGS=(halt)
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" --arg t "$tool" --argjson w "$window" \
    '{session_id:"s1",transcript_path:$p,tool_name:$t,context_window:$w}')" ORCH_HANDOFF_AGENT_RESERVE_TOKENS=10000
  assert_eq "$RC" "$rc" "$harness attached tool $tool at its reserve boundary"
  ARM_ARGS=()
done <<'ROWS'
codex|spawn_agent|119199|258400|0
codex|spawn_agent|119200|258400|2
codex|multi_agent_v2.spawn_agent|119200|258400|2
pi|subagent|89999|200000|0
pi|subagent|90000|200000|2
pi|delegate_subagent|90000|200000|2
ROWS

new_lane agent_copilot AGENT-1
mkdir -p "$LANE/tmp/lane-mail/AGENT-1"
install_hook "$HOOK" "$LANE/.github/hooks/lane-mail-check.sh"
CALL_ENV=("HOME=$COP_HOME")
cop_lead_start "$CASE_HOOK" s1
for tool in task Agent Task; do
  ARM_ARGS=(usage)
  run_payload "$(jq -nc --arg c "$LANE" '{session_id:"s1",cwd:$c,current_tokens:70000,token_limit:200000}')"
  expect 0 - 'the existing Copilot extension reading records context'
  ARM_ARGS=(halt)
  run_payload '{"sessionId":"s1","timestamp":1,"toolName":"'"$tool"'","toolArgs":{}}' ORCH_HANDOFF_AGENT_RESERVE_TOKENS=10000
  assert_eq "RC=$RC decision=$(jq -r '.permissionDecision' "$TMP_ROOT/stdout") first=$(first_line)" \
    "RC=2 decision=deny first=lane-mail-check: agent-launch=$tool tokens=70000 reserve=10000" 'Copilot camelCase names its attached launch and receives deny JSON'
done
ARM_ARGS=()
CALL_ENV=()

# The identified fleet overseer meets the same launch check and keeps its
# existing explicit handoff escape.
overseer_transcript
new_overseer agent_overseer
judge_says "$CONTEXT_MARK_LINE"
# shellcheck disable=SC2046
launch 250000 Agent $(overseer_env)
expect 2 'lane-mail-check: agent-launch=Agent tokens=250000 reserve=150000' 'the identified overseer meets the reserve'
record_overseer_handoff
# shellcheck disable=SC2046
launch 600000 Agent $(overseer_env)
expect 0 - 'a standing handoff retains its escape'

new_overseer agent_children
judge_says "$CONTEXT_MARK_LINE"
write_transcript "$TRANSCRIPT" 600000
agent_stop() { # BACKGROUND_FIELDS
  # shellcheck disable=SC2046
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" --argjson extra "$1" \
    '{session_id:"s1",transcript_path:$p,stop_hook_active:false} + $extra')" $(overseer_env)
}
agent_rows() { sed -n 's/^lane-mail-check: attached-agent=//p' "$ERR_FILE"; }
while IFS='|' read -r fields want; do
  agent_stop "$fields"
  expect 2 'lane-mail-check: context=612000' 'a reached mark retains its refusal'
  assert_eq "$(agent_rows)" "$want" 'native child list'
done <<'ROWS'
{"background_tasks":[]}|
{"background_tasks":[{"id":"a1","type":"subagent","status":"running"}]}|a1 status=running output=unknown
{"background_tasks":[{"id":"a1","type":"subagent","status":"completed"},{"id":"s1","type":"shell","status":"running"}]}|
ROWS
agent_stop '{"background_tasks":null}'
assert_eq "$(sed -n 's/^lane-mail-check: agents=//p' "$ERR_FILE")" unknown 'malformed native state is unknown'

append_launch() {
  jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"call-agent",content:"Async agent launched successfully. agentId: a1"}]}}' >> "$TRANSCRIPT"
}
append_notice() { # ID STATUS
  jq -nc --arg id "$1" --arg s "$2" '{type:"user",message:{role:"user",content:("<task-notification><task-id>"+$id+"</task-id><status>"+$s+"</status></task-notification>")}}' >> "$TRANSCRIPT"
}
append_launch
agent_stop '{}'
assert_eq "$(agent_rows)" 'a1 status=running output=unknown' 'fallback names the launched child'
agent_stop '{"background_tasks":[]}'
assert_eq "$(agent_rows)" '' 'a valid native empty list takes priority over old transcript state'
append_notice monitor completed
agent_stop '{}'
assert_eq "$(agent_rows)" 'a1 status=running output=unknown' 'a monitor notification clears no child'
append_notice a1 completed
agent_stop '{}'
assert_eq "$(agent_rows)" '' 'the matching terminal notification ends the child hold'
append_launch
mkdir -p "${TRANSCRIPT%.jsonl}/subagents"
: > "${TRANSCRIPT%.jsonl}/subagents/agent-a1.jsonl"
agent_stop '{}'
assert_eq "$(agent_rows)" "a1 status=running output=${TRANSCRIPT%.jsonl}/subagents/agent-a1.jsonl" 'a later launch replaces completion and names existing output'
printf '{broken\n' >> "$TRANSCRIPT"
agent_stop '{}'
assert_eq "$(sed -n 's/^lane-mail-check: agents=//p' "$ERR_FILE")" unknown 'an unreadable fallback never reports no child'

if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  for mutation in launch input children native completion; do
    case "$mutation" in
      launch) variant agent-no-launch -e 's/^  attached_launch_check$/  :/' ;;
      input) variant agent-no-input -e 's/\*) refuse_handoff agent-input context-unmeasured ;;/\*) return 0 ;;/' ;;
      children) variant agent-no-children -e 's/^    claude_attached_agents$/    AGENT_ROWS=""/' ;;
      native) variant agent-no-native -e 's/^  if jq -e '\''has("background_tasks")'\'' <<<"\$INPUT" >\/dev\/null; then$/  if false; then/' ;;
      completion) variant agent-no-completion -e 's/if has(\$n\[0\]) then .\[\$n\[0\]\] = \$n\[1\] else . end/. /' ;;
    esac
    control_rc=0
    env "HOOK_UNDER_TEST=$VARIANT_PATH" "$BASH" "$TEST_DIR/lane-mail-check-agent.test.sh" \
      > "$TMP_ROOT/$mutation.control.log" 2>&1 || control_rc=$?
    assert_eq "$control_rc" 1 "control $mutation makes the real hook assertions fail"
  done
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
