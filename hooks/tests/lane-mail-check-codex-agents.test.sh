#!/usr/bin/env bash
# Codex attached-launch roster from ordered collaboration rollout records.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

codex_call() { # TOOL ARGUMENTS [OUTPUT]
  CALL_NUMBER=$((CALL_NUMBER + 1))
  jq -nc --arg n "$1" --arg a "$2" --arg id "call-$CALL_NUMBER" \
    '{type:"response_item",payload:{type:"function_call",name:$n,arguments:$a,call_id:$id}}' >> "$TRANSCRIPT"
  [ "$#" -eq 3 ] || return 0
  jq -nc --arg o "$3" --arg id "call-$CALL_NUMBER" \
    '{type:"response_item",payload:{type:"function_call_output",call_id:$id,output:$o}}' >> "$TRANSCRIPT"
}
snapshot() { # STATUS
  codex_call list_agents '{}' "$(jq -nc --argjson s "$1" \
    '{agents:[{agent_name:"/root",agent_status:"running"},
      {agent_name:"/root/runtime",agent_status:"idle"},
      {agent_name:"/root/reviewer",agent_status:$s}]}')"
}

new_lane codex_agents AGENT-1
mkdir -p "$LANE/tmp/lane-mail/AGENT-1"
install_hook "$HOOK" "$LANE/.codex/hooks/lane-mail-check.sh"
TRANSCRIPT="$TMP_ROOT/codex.jsonl"
ARM_ARGS=(halt)
codex_row() { # ROSTER RC KEY
  local roster="$1" rc="$2" key="$3" current_call
  CALL_NUMBER=0
  usage_line codex 119200 > "$TRANSCRIPT"
  case "$roster" in
    empty) codex_call list_agents '{}' '{"agents":[{"agent_name":"/root","agent_status":"running"}]}' ;;
    filtered) codex_call list_agents '{"path_prefix":"/root/reviewer"}' '{"agents":[]}' ;;
    returned | current-call) snapshot '"completed"' ;;
    returned-object) snapshot '{"completed":"Review complete."}' ;;
    out) snapshot '"running"' ;;
    spawned | spawned-returned) snapshot '"completed"'
      codex_call collaboration.spawn_agent '{"task_name":"reviewer"}' '{"task_name":"/root/reviewer"}'
      [ "$roster" != spawned-returned ] || snapshot '"idle"' ;;
    resumed | resumed-relative) snapshot '"completed"'
      target=/root/reviewer
      [ "$roster" != resumed-relative ] || target=reviewer
      codex_call collaborationfollowup_task "$(jq -nc --arg t "$target" '{target:$t,message:"Review again."}')" 'delivered' ;;
    waited) snapshot '"running"'
      codex_call wait_agent '{}' '{"summary":"agent updates available"}' ;;
    pending | prior-pending) snapshot '"completed"'; codex_call spawn_agent '{"task_name":"later"}' ;;
    concurrent) snapshot '"completed"'; codex_call spawn_agent '{"task_name":"pending"}'
      codex_call spawn_agent '{"task_name":"later"}' '{"task_name":"/root/later"}' ;;
    unknown-status) snapshot '"paused"' ;;
    malformed) snapshot '"completed"'; printf '{broken\n' >> "$TRANSCRIPT" ;;
    bad-result) codex_call list_agents '{}' '{"agents":null}' ;;
    history) snapshot '"running"'
      jq -nc '{type:"response_item",payload:{type:"message",content:("x" * 1048576)}}' >> "$TRANSCRIPT"
      usage_line codex 119200 >> "$TRANSCRIPT" ;;
  esac
  codex_call collaborationspawn_agent '{"task_name":"current"}'
  current_call="call-$CALL_NUMBER"
  if ! command -v timeout >/dev/null 2>&1; then rc=2; key=agent-unobserved; fi
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" --arg id "$current_call" \
    '{session_id:"s1",transcript_path:$p,tool_use_id:$id,tool_name:"collaborationspawn_agent",tool_input:{}}')" \
    ORCH_HANDOFF_AGENT_RESERVE_TOKENS=10000
  if [ "$rc" = 0 ]; then
    expect 0 - "Codex roster $roster admits the launch past the reserve"
  else
    expect 2 "lane-mail-check: $key=collaborationspawn_agent tokens=119200 reserve=10000" "Codex roster $roster holds the launch"
  fi
}
while IFS='|' read -r roster rc key; do
  codex_row "$roster" "$rc" "$key"
done <<'ROWS'
empty|0|-
filtered|2|agent-unobserved
returned|0|-
current-call|0|-
returned-object|0|-
out|2|agent-reserve
spawned|2|agent-reserve
spawned-returned|0|-
resumed|2|agent-reserve
resumed-relative|2|agent-reserve
waited|2|agent-reserve
pending|2|agent-unobserved
prior-pending|2|agent-unobserved
concurrent|2|agent-unobserved
unknown-status|2|agent-unobserved
malformed|2|agent-unobserved
bad-result|2|agent-unobserved
history|2|agent-reserve
ROWS
ARM_ARGS=()

# The same unknown-roster refusal must give the fleet overseer a route even
# below its plain handoff mark, where succession would refuse.
overseer_transcript
new_overseer codex_unknown_route
write_transcript "$TRANSCRIPT" 300000
ARM_ARGS=(halt)
# shellcheck disable=SC2046
run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",transcript_path:$p,tool_name:"Agent",
  background_tasks:[{type:"workflow",id:"w1",status:"running"}]}')" $(overseer_env)
expect 2 'lane-mail-check: agent-unobserved=Agent tokens=300000 reserve=150000' 'the overseer has an unknown roster below the plain mark'
assert_eq "$(sed -n 's/^lane-mail-check: detached-route=//p' "$ERR_FILE")" orch-job-runner 'the overseer refusal names the installed detached route'
ARM_ARGS=()

if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  for control in roster route; do
    case "$control" in
      roster) wake_mutant no-codex-roster '  elif [ "$HARNESS" = codex ]; then' '  elif false; then' ;;
      route) wake_mutant no-overseer-route '        [ "$ROLE" != overseer ] || printf '\''lane-mail-check: detached-route=orch-job-runner\n'\''' '        :' ;;
    esac
    control_rc=0
    env "HOOK_UNDER_TEST=$MUTANT_PATH" "$BASH" "$TEST_DIR/lane-mail-check-codex-agents.test.sh" \
      > "$TMP_ROOT/$control.control.log" 2>&1 || control_rc=$?
    if [ "$control" = roster ] && ! command -v timeout >/dev/null 2>&1; then
      printf 'skip: roster control needs timeout to observe Codex children\n'
      continue
    fi
    assert_eq "$control_rc" 1 "control $control fails the real hook assertions"
  done
  if command -v timeout >/dev/null 2>&1; then
    for control in current-call prior-pending; do
      case "$control" in
        current-call) wake_mutant no-current-exclusion '      lane_adapter_codex_agents "$2"' '      lane_adapter_codex_agents ""' ;;
        prior-pending) wake_mutant no-pending-guard "      if [ \"\$id\" = '?' ]; then" "      if [ \"\$id\" = '?' ]; then continue;" ;;
      esac
      new_lane "codex-$control-control" AGENT-1
      mkdir -p "$LANE/tmp/lane-mail/AGENT-1"
      install_hook "$MUTANT_PATH" "$LANE/.codex/hooks/lane-mail-check.sh"
      ARM_ARGS=(halt)
      control_rc=0
      (PASS=0; FAIL=0
        case "$control" in
          current-call) codex_row current-call 0 - ;;
          prior-pending) codex_row prior-pending 2 agent-unobserved ;;
        esac
        [ "$FAIL" -eq 0 ]) > "$TMP_ROOT/$control.control.log" 2>&1 || control_rc=$?
      assert_eq "$control_rc" 1 "control $control fails its own hook row"
    done
  fi
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
