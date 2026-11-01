#!/usr/bin/env bash
# Attached launches and child state at the context mark. The hook is installed
# in lib/lane-mail-world.sh's real lane and fleet layouts. Only Claude's
# measured Agent, SendMessage and TaskStop calls, their launch and spawn
# results, ListAgents observations, and task and teammate idle notifications
# are transcript inputs.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

# Claude's measured tool call and its result. A launched child with no
# terminal notification after it is still out.
append_call() { # TOOL INPUT RESULT [IS_ERROR] [STRUCTURED_RESULT]
  CALL_SEQUENCE=$((${CALL_SEQUENCE:-0} + 1))
  local call_id="call-fixture-$CALL_SEQUENCE"
  jq -nc --arg c "$call_id" --arg t "$1" --argjson i "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:$c,name:$t,input:$i}]}}' >> "$TRANSCRIPT"
  jq -nc --arg c "$call_id" --arg r "$3" --argjson e "${4:-false}" --argjson s "${5:-null}" \
    '{type:"user",toolUseResult:$s,message:{role:"user",content:[{type:"tool_result",tool_use_id:$c,content:$r,is_error:$e}]}}' >> "$TRANSCRIPT"
}
append_agent() { # INPUT RESULT [IS_ERROR]
  append_call Agent "$@"
}
append_launch() { append_agent '{"run_in_background":true}' 'Async agent launched successfully. agentId: a1'; }
# The teammate spawn Claude Code writes for a named Agent call.
append_teammate() {
  append_agent '{"name":"reviewer"}' "$(printf 'Spawned successfully. (This tool result is internal metadata.)\nagent_id: areviewer-t1\nname: reviewer\nThe agent is now running and will receive instructions via mailbox.')"
}
# The measured control-VM probe on KEN-4273 resumes a TaskStop-ended teammate.
append_stopped_resume() { # [RESULT] [NOTIFICATION]
  append_teammate
  append_call TaskStop '{"task_id":"reviewer"}' '{"message":"Successfully stopped task: areviewer-t1","task_id":"areviewer-t1","task_type":"in_process_teammate"}'
  local text result='{"success":true,"message":"Teammate \"reviewer\" was not running; resumed it as an in-process teammate with 10 prior messages and your message as its next prompt.","pin":{"id":"areviewer-t1","name":"reviewer","ref":"43802f"}}'
  result="${1:-$result}"
  text=$(printf '%s\n%s' "$result" "${2:-}")
  append_call SendMessage '{"to":"reviewer","message":"Recheck the head."}' "$text" false "$result"
}
# HT-2212, Claude Code 2.1.302: ListAgents returns these structured teammate
# rows after the report. A report alone can also be a mid-task message.
append_listed() { # STATUS [NAME] [IS_ERROR]
  local name="${2:-reviewer}" listing result
  listing=$(printf 'Teammates (1):\n  %s [64914e]  ·  reviewer-correctness  ·  %s  ·  started 49m ago' "$name" "$1")
  result=$(jq -nc --arg n "$name" --arg s "$1" --arg l "$listing" \
    '{listing:$l,sections:[{kind:"teammates",total:1,rows:[{name:$n,ref:"64914e",type:"reviewer-correctness",status:$s}]}],notes:[]}')
  append_call ListAgents '{}' "$listing" "${3:-false}" "$result"
}
append_report() {
  jq -nc '{type:"user",message:{role:"user",content:"Another Claude session sent a message:\n<teammate-message teammate_id=\"reviewer\" color=\"green\" summary=\"Correctness review complete\">\nThe report has returned.\n</teammate-message>"}}' >> "$TRANSCRIPT"
}
# Claude Code 2.1.302 captures a list before awaited peer reads. A send or
# completion during those reads is newer than the returned snapshot.
append_overlapping_list() { # list-first|send-first|queued-idle|queued-task|result-idle|result-block-idle
  local mode="$1" status=idle note=''
  jq -nc --arg order "$1" '{type:"assistant",message:{role:"assistant",content:
    ([{type:"tool_use",id:"call-list",name:"ListAgents",input:{}},
      {type:"tool_use",id:"call-send",name:"SendMessage",input:{to:"reviewer",message:"Recheck the head."}}]
      | if $order == "send-first" then reverse elif $order == "list-first" then . else .[:1] end)}}' >> "$TRANSCRIPT"
  case "$mode" in
    list-first | send-first)
      jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"call-send",content:"{\"success\":true}"}]}}' >> "$TRANSCRIPT" ;;
    queued-idle) status=running; append_queued "$(idle_text reviewer)" ;;
    queued-task) status=running; append_queued "$(notice_text areviewer-t1 completed)" ;;
    result-idle | result-block-idle) status=running; note=$(idle_text reviewer) ;;
  esac
  jq -nc --arg s "$status" --arg n "$note" --arg mode "$mode" \
    '{type:"user",toolUseResult:{sections:[{kind:"teammates",rows:[{name:"reviewer",status:$s}]}]},
      message:{role:"user",content:[{type:"tool_result",tool_use_id:"call-list",
        content:(if $mode == "result-block-idle" then [{type:"text",text:("reviewer is " + $s)},{type:"text",text:$n}]
          else "reviewer is " + $s + "\n" + $n end)}]}}' >> "$TRANSCRIPT"
}
notice_text() { # ID STATUS
  printf '<task-notification><task-id>%s</task-id><status>%s</status></task-notification>' "$1" "$2"
}
append_notice() { # ID STATUS
  jq -nc --arg n "$(notice_text "$1" "$2")" '{type:"user",message:{role:"user",content:$n}}' >> "$TRANSCRIPT"
}
# The idle notification Claude Code delivers after each teammate report.
idle_text() { # NAME [IDLE_REASON [COMPLETED_STATUS]]
  local reason="${2-available}" fields=''
  if [ -n "$reason" ]; then fields=',"idleReason":"'"$reason"'"'; fi
  if [ -n "${3:-}" ]; then fields="$fields"',"completedStatus":"'"$3"'"'; fi
  printf 'Another Claude session sent a message:\n<teammate-message teammate_id="%s" color="blue">\n{"type":"idle_notification","from":"%s"%s}\n</teammate-message>' "$1" "$1" "$fields"
}
append_idle() { # NAME [IDLE_REASON [COMPLETED_STATUS]]
  jq -nc --arg n "$(idle_text "$@")" '{type:"user",message:{role:"user",content:$n}}' >> "$TRANSCRIPT"
}
# Claude Code appends a notification that arrives during a tool call to that
# call's result, as its string or as a text block.
append_tool_note() { # string|block TEXT
  jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"call-bash",name:"Bash",input:{command:"true"}}]}}' >> "$TRANSCRIPT"
  jq -nc --arg f "$1" --arg n "$2" '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"call-bash",
    content:(if $f == "string" then "done\n" + $n else [{type:"text",text:"done"},{type:"text",text:$n}] end),is_error:false}]}}' >> "$TRANSCRIPT"
}
# One turn's Agent call beside a Bash call, both results in one record; the
# child's first notification arrives during the Bash call, on its result.
append_shared() { # INPUT LAUNCH_RESULT TEXT
  jq -nc --argjson i "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"call-agent",name:"Agent",input:$i},
    {type:"tool_use",id:"call-bash",name:"Bash",input:{command:"true"}}]}}' >> "$TRANSCRIPT"
  jq -nc --arg l "$2" --arg n "$3" '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"call-agent",content:$l,is_error:false},
    {type:"tool_result",tool_use_id:"call-bash",content:("done\n" + $n),is_error:false}]}}' >> "$TRANSCRIPT"
}
# The entry Claude Code 2.1.302 writes for a notification queued while the
# model works, and the remove entry that repeats it once a turn absorbs it.
append_queued() { # TEXT
  jq -nc --arg n "$1" '{type:"queue-operation",operation:"enqueue",timestamp:"2026-10-17T13:20:00.000Z",sessionId:"s1",content:$n}' >> "$TRANSCRIPT"
}
append_absorbed() { # TEXT
  jq -nc --arg n "$1" '{type:"queue-operation",operation:"remove",timestamp:"2026-10-17T13:20:01.000Z",sessionId:"s1",content:$n,
    reason:"absorbed_mid_turn",commandUuid:"c1",deliveryId:"d1"}' >> "$TRANSCRIPT"
}

# A transcript scan needs the host's timeout command; without it the roster
# is unknown, which keeps the reserve but observes no return, so a refusal
# that names the wait where the scan reads an agent out names none there.
SCAN_AVAILABLE=0
if command -v timeout >/dev/null 2>&1; then SCAN_AVAILABLE=1; fi
scan_key() { # KEY
  if [ "$SCAN_AVAILABLE" -eq 1 ]; then printf '%s\n' "$1"; else printf '%s\n' "${1/agent-reserve=/agent-unobserved=}"; fi
}
handoffs_named() { grep -c 'set .* handoff ' "$ERR_FILE" || true; }
# workflow-state consumes the shell argument emitted by handoff_instruction.
# Decode that argument without running the emitted command, then parse JSON.
handoff_context() {
  local line record=''
  while IFS= read -r line; do
    case "$line" in *' set '*' handoff '*) record=${line#* handoff }; break ;; esac
  done < "$ERR_FILE"
  "$BASH" -c 'eval "set -- $1"; printf "%s\n" "$1"' _ "$record" | jq -c '.context'
}

launch() { # TOKENS TOOL [ENV...] — AGENTS names the earlier Agent call, if any
  local tokens="$1" tool="$2"
  shift 2
  write_transcript "$TRANSCRIPT" "$tokens"
  case "${AGENTS:-}" in
    out) append_launch ;;
    teammate) append_teammate ;;
    returned) append_teammate; append_idle reviewer ;;
    # A plain-text send starts the idle teammate's next turn.
    resumed) append_teammate; append_idle reviewer; append_call SendMessage '{"to":"reviewer","message":"Recheck the head."}' '{"success":true}' ;;
    shutdown) append_teammate; append_call SendMessage '{"to":"reviewer","message":{"type":"shutdown_request"}}' '{"success":true}' ;;
    tool-string) append_launch; append_tool_note string "$(notice_text a1 completed)" ;;
    tool-block) append_launch; append_tool_note block "$(notice_text a1 completed)" ;;
    tool-idle) append_teammate; append_tool_note block "$(idle_text reviewer)" ;;
    queued) append_launch; append_queued "$(notice_text a1 completed)" ;;
    # A notification on a sibling result of its own launch's record.
    shared-launch) append_shared '{"run_in_background":true}' 'Async agent launched successfully. agentId: a1' "$(notice_text a1 completed)" ;;
    shared-spawn) append_shared '{"name":"reviewer"}' "$(printf 'Spawned successfully. (This tool result is internal metadata.)\nagent_id: areviewer-t1\nname: reviewer\nThe agent is now running and will receive instructions via mailbox.')" "$(idle_text reviewer)" ;;
    # An idle appended to the resuming send's own result reports the turn
    # that ended before the message reached the teammate.
    resume-noted) append_teammate
      append_call SendMessage '{"to":"reviewer","message":"Recheck the head."}' "$(printf '{"success":true}\n%s' "$(idle_text reviewer)")" ;;
    # A remove entry repeats an idle the resume already followed.
    requeued) append_teammate; append_queued "$(idle_text reviewer)"
      append_call SendMessage '{"to":"reviewer","message":"Recheck the head."}' '{"success":true}'
      append_absorbed "$(idle_text reviewer)" ;;
    stopped) append_teammate; append_call TaskStop '{"task_id":"reviewer"}' '{"message":"Successfully stopped task: areviewer-t1","task_id":"areviewer-t1","task_type":"in_process_teammate"}' ;;
    stopped-resumed) append_stopped_resume ;;
    stopped-resumed-returned) append_stopped_resume; append_idle reviewer ;;
    stopped-unknown) append_stopped_resume '{"success":true}' ;;
    stopped-unknown-returned) append_stopped_resume '{"success":true}'; append_idle reviewer ;;
    stopped-resume-noted) append_stopped_resume '' "$(idle_text other)" ;;
    reported) append_teammate; append_report ;;
    listed-idle) append_teammate; append_report; append_listed idle ;;
    # api-request-blob repeats calls; it is not another pending launch.
    listed-replay) append_teammate; append_report
      jq -nc '{type:"api-request-blob",message:{role:"assistant",content:[{type:"tool_use",id:"call-replay",name:"Agent",input:{name:"reviewer"}}]}}' >> "$TRANSCRIPT"
      append_listed idle ;;
    listed-running) append_teammate; append_listed running ;;
    listed-resumed) append_teammate; append_listed idle
      append_call SendMessage '{"to":"reviewer","message":"Recheck the head."}' '{"success":true}' ;;
    # SendMessage acknowledges the inbox write before the teammate's next
    # poll clears isIdle. That sequential idle snapshot ends no sent turn.
    listed-sent-idle | listed-sent-running-idle | listed-sent-unknown-idle | listed-sent-notified | listed-resent-idle | listed-sent-unknown-running-idle)
      append_teammate; append_idle reviewer
      append_call SendMessage '{"to":"reviewer","message":"Recheck the head."}' '{"success":true}'
      case "$AGENTS" in
        listed-sent-running-idle) append_listed running ;;
        listed-sent-unknown-idle) append_listed unavailable ;;
        listed-sent-unknown-running-idle) append_listed unavailable; append_listed running ;;
        listed-resent-idle) append_listed running
          append_call SendMessage '{"to":"reviewer","message":"Recheck again."}' '{"success":true}' ;;
      esac
      append_listed idle
      [ "$AGENTS" != listed-sent-notified ] || append_idle reviewer ;;
    stopped-unknown-listed-idle) append_stopped_resume '{"success":true}'; append_listed idle ;;
    # Qe's interrupted notice precedes its inbox read. Its missing reason and
    # nonterminal failed reason can continue the next prompt. An active
    # turn's available notice can also precede consumption of a newer send.
    notified:*)
      local notice_kind notice_phase notice_reason notice_status=''
      IFS=: read -r notice_kind notice_phase notice_reason <<< "$AGENTS"
      case "$notice_phase" in
        resumed) append_stopped_resume ;;
        unknown) append_stopped_resume '{"success":true}' ;;
        ended) append_teammate
          append_call TaskStop '{"task_id":"reviewer"}' '{"message":"Successfully stopped task: areviewer-t1","task_id":"areviewer-t1","task_type":"in_process_teammate"}' ;;
        active | idle | unsent)
          append_teammate
          if [ "$notice_phase" = idle ]; then append_idle reviewer; fi
          if [ "$notice_phase" != unsent ]; then
            append_call SendMessage '{"to":"reviewer","message":"Recheck the head."}' '{"success":true}'
          fi ;;
      esac
      if [ "$notice_phase" != ended ]; then append_listed running; fi
      case "$notice_reason" in
        task) append_notice areviewer-t1 completed ;;
        *)
          case "$notice_reason" in
            terminal) notice_reason=failed; notice_status=failed ;;
            missing) notice_reason='' ;;
          esac
          append_idle reviewer "$notice_reason" "$notice_status"
          if [ "$notice_phase" != unsent ] && [ "$notice_phase" != ended ] && [ -z "$notice_status" ]; then append_listed idle; fi ;;
      esac ;;
    listed-error) append_teammate; append_listed idle reviewer true ;;
    listed-unknown) append_teammate; append_listed unavailable ;;
    listed-unknown-returned) append_teammate; append_listed unavailable; append_idle reviewer ;;
    listed-unrelated) append_teammate; append_listed idle other ;;
    listed-absent) append_teammate; append_call ListAgents '{}' 'Listing is unavailable.' ;;
    listed-absent-returned) append_teammate; append_call ListAgents '{}' 'Listing is unavailable.'; append_idle reviewer ;;
    listed-overlap-first) append_teammate; append_overlapping_list list-first ;;
    listed-overlap-last) append_teammate; append_overlapping_list send-first ;;
    listed-queued-idle | listed-queued-task | listed-result-idle | listed-result-block-idle)
      append_teammate; append_overlapping_list "${AGENTS#listed-}" ;;
    # A refused stop ended nothing.
    stop-refused) append_teammate; append_call TaskStop '{"task_id":"reviewer"}' '<tool_use_error>No task found with ID: reviewer</tool_use_error>' true ;;
    # A foreground call's result is its finished child's output.
    foreground) append_agent '{}' 'The review found no defects.' ;;
    # A background call whose result neither measured launch form matches.
    unclassified) append_agent '{"run_in_background":true}' 'The review found no defects.' ;;
    # A refused call launched nothing.
    refused) append_agent '{"run_in_background":true}' 'PreToolUse:Agent hook error: refused' true ;;
  esac
  ARM_ARGS=(halt)
  run_payload "$(jq -nc --arg t "$tool" --arg p "$TRANSCRIPT" \
    '{session_id:"s1",transcript_path:$p,tool_name:$t,tool_input:{}}')" "$@"
  ARM_ARGS=()
}

new_lane agent_launch AGENT-1
mkdir -p "$LANE/tmp/lane-mail/AGENT-1"
TRANSCRIPT="$TMP_ROOT/agent-launch.jsonl"
# The reserve applies only while an attached agent may be out; with none out
# the launch meets the plain mark, 400000 tokens or strictly past the
# percentage, the one mark that names a handoff. Below it the reserve refuses
# as agent-reserve with an agent out, naming no handoff, and as
# agent-unobserved where the roster is unknown, naming the lane's handoff.
# Rows a scan reads as none are skipped where the scan is unavailable.
while IFS='|' read -r agents tokens tool reserve rc key; do
  case "$agents" in out | teammate | resumed | resume-noted | requeued | unclassified | stop-refused | stopped-resumed | stopped-unknown | stopped-resume-noted | reported | listed-running | listed-resumed | listed-error | listed-unknown | listed-unrelated | listed-absent | listed-overlap-first | listed-overlap-last | listed-sent-idle | listed-sent-running-idle | listed-sent-unknown-idle | listed-sent-unknown-running-idle | listed-resent-idle | stopped-unknown-listed-idle) ;; *) [ "$SCAN_AVAILABLE" -eq 1 ] || continue ;; esac
  key=$(scan_key "$key")
  AGENTS=$agents launch "$tokens" "$tool" "ORCH_HANDOFF_AGENT_RESERVE_TOKENS=$reserve"
  expect "$rc" "$key" "launch $tool at $tokens with reserve $reserve and agents $agents"
  case "$key" in
    *agent-reserve=*) assert_eq "$(handoffs_named)" 0 "the reserve refusal at $tokens with agents $agents names no handoff" ;;
    *agent-unobserved=* | *agent-launch=*)
      assert_eq "$(handoffs_named)" 1 "the refusal at $tokens with agents $agents names the lane handoff"
      case "$key" in *agent-launch=*) applied=false; amount=0 ;; *) applied=true; amount=${reserve:-150000} ;; esac
      assert_eq "$(handoff_context | jq -c '[.decision.tokens,.decision.cap,.decision.mark_pct,.decision.reserve_applied,.decision.reserve_tokens,.source.harness,.source.session_id,.source.transcript]')" \
        "[$tokens,400000,50,$applied,$amount,\"claude\",\"s1\",\"$TRANSCRIPT\"]" \
        "parsed handoff decision for $agents at $tokens"
      ;;
  esac
done <<'ROWS'
out|249999|Agent||0|-
out|250000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=250000 reserve=150000
out|250001|Agent||2|lane-mail-check: agent-reserve=Agent tokens=250001 reserve=150000
out|400000|Agent||2|lane-mail-check: agent-launch=Agent tokens=400000
teammate|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
returned|260000|Agent||0|-
resumed|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
shutdown|260000|Agent||0|-
tool-string|260000|Agent||0|-
tool-block|260000|Agent||0|-
tool-idle|260000|Agent||0|-
queued|260000|Agent||0|-
shared-launch|260000|Agent||0|-
shared-spawn|260000|Agent||0|-
resume-noted|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
requeued|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
stopped|260000|Agent||0|-
stopped-resumed|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
stopped-resumed-returned|260000|Agent||0|-
stopped-unknown|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
stopped-unknown-returned|260000|Agent||0|-
stopped-resume-noted|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
reported|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
listed-idle|260000|Agent||0|-
listed-replay|260000|Agent||0|-
listed-running|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
listed-resumed|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
listed-sent-idle|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
listed-sent-running-idle|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
listed-sent-unknown-idle|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
listed-sent-unknown-running-idle|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
listed-sent-notified|260000|Agent||0|-
listed-resent-idle|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
stopped-unknown-listed-idle|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:active:available|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:active:interrupted|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:active:failed|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:active:missing|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:active:terminal|260000|Agent||0|-
notified:active:task|260000|Agent||0|-
notified:idle:available|260000|Agent||0|-
notified:idle:interrupted|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:idle:failed|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:idle:missing|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:idle:terminal|260000|Agent||0|-
notified:resumed:interrupted|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:unknown:interrupted|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:unsent:interrupted|260000|Agent||0|-
notified:unsent:failed|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:unsent:missing|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
notified:ended:missing|260000|Agent||0|-
listed-error|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
listed-unknown|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
listed-unknown-returned|260000|Agent||0|-
listed-unrelated|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
listed-absent|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
listed-absent-returned|260000|Agent||0|-
listed-overlap-first|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
listed-overlap-last|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
listed-queued-idle|260000|Agent||0|-
listed-queued-task|260000|Agent||0|-
listed-result-idle|260000|Agent||0|-
listed-result-block-idle|260000|Agent||0|-
stop-refused|260000|Agent||2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000
foreground|260000|Agent||0|-
unclassified|260000|Agent||2|lane-mail-check: agent-unobserved=Agent tokens=260000 reserve=150000
refused|260000|Agent||0|-
none|399999|Agent||0|-
none|400000|Agent||2|lane-mail-check: agent-launch=Agent tokens=400000
out|100000|Agent|50000|0|-
out|250000|Bash||0|-
out|600000|TaskOutput||0|-
out|250000|Agent|nope|2|lane-mail-check: setting-range=ORCH_HANDOFF_AGENT_RESERVE_TOKENS=nope
out|250000|Agent|-1|2|lane-mail-check: setting-range=ORCH_HANDOFF_AGENT_RESERVE_TOKENS=-1
out|0|Agent|400000|2|lane-mail-check: agent-reserve=Agent tokens=0 reserve=400000
none|0|Agent|400000|0|-
ROWS
# An unknown capacity is unmeasured at the plain mark, which is judged first,
# so no agent out turns it into a reserve-only hold.
for agents in none out; do
  [ "$agents" = out ] || [ "$SCAN_AVAILABLE" -eq 1 ] || continue
  usage_line sonnet 260000 > "$TRANSCRIPT"
  [ "$agents" = none ] || append_launch
  ARM_ARGS=(halt)
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",transcript_path:$p,tool_name:"Agent",tool_input:{}}')" DISABLE_AUTO_COMPACT=0
  ARM_ARGS=()
  expect 2 'lane-mail-check: agent-input=context-unmeasured' "an unknown capacity at 260000 with agents $agents is unmeasured"
done
if [ "$SCAN_AVAILABLE" -eq 1 ]; then
  # A terminal notification brings the child back, so the plain mark applies.
  write_transcript "$TRANSCRIPT" 260000
  append_launch
  append_notice a1 completed
  ARM_ARGS=(halt)
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",transcript_path:$p,tool_name:"Agent",tool_input:{}}')"
  ARM_ARGS=()
  expect 0 - 'a returned child leaves no reserve'
fi
AGENTS=out launch 400000 Agent
assert_eq "$(sed -n 's/^lane-mail-check: detached-route=//p' "$ERR_FILE")" orch-job-runner 'refusal names the existing detached route'
usage_line sonnet 100000 > "$TRANSCRIPT"
ARM_ARGS=(halt)
# An enabled-compaction session has no managed handoff budget.
run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",transcript_path:$p,tool_name:"Agent"}')" DISABLE_AUTO_COMPACT=0
expect 2 'lane-mail-check: agent-input=context-unmeasured' 'an unknown capacity establishes no launch room'
run_payload '{"session_id":"s1","tool_name":"Agent"}'
expect 2 'lane-mail-check: agent-input=transcript-unnamed' 'an absent reading establishes no launch room'
assert_eq "$(handoff_context | jq -c '[.decision,.source.session_id,.source.transcript]')" \
  '[null,"s1",null]' 'an absent reading leaves handoff decision unknown with its actual session binding'
ARM_ARGS=()

# A retained edited orch install can keep the released three-argument judge
# while this hook updates. Keep the released function here so this fixture
# does not change when origin/main advances. Other readers use the real lib.
new_lane agent_legacy AGENT-1
mkdir -p "$LANE/tmp/lane-mail/AGENT-1"
plant_install
LEGACY_LIB="$TMP_ROOT/retained-context-lib"
cp -R "$REPO_ROOT/skills/orch/scripts/lib" "$LEGACY_LIB"
cat >> "$LEGACY_LIB/lane-context.sh" <<'RELEASED_CONTEXT_JUDGE'
lane_context_handoff_due() { # TOKENS WINDOW PCT
  local pct
  pct=$(lane_context_handoff_pct "${3:-}") || return 2
  case "${1:-}" in '' | *[!0-9]*) return 2 ;; 0) ;; 0*) return 2 ;; esac
  if [ "$1" -ge 400000 ]; then
    printf 'due\n'
    return 0
  fi
  case "${2:-}" in '' | 0) return 1 ;; *[!0-9]* | 0*) return 2 ;; esac
  if [ $(($1 * 100)) -gt $(($2 * pct)) ]; then
    printf 'due\n'
  else
    printf 'room\n'
  fi
}
RELEASED_CONTEXT_JUDGE
rm "$LANE/.claude/skills/orch/scripts/lib"
ln -s "$LEGACY_LIB" "$LANE/.claude/skills/orch/scripts/lib"
write_transcript "$TRANSCRIPT" 600000
run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",transcript_path:$p,stop_hook_active:false}')"
expect 2 'lane-mail-check: context=600000' 'the released judge retains ordinary Stop behavior'
launch 250000 Agent
expect 2 'lane-mail-check: agent-input=reserve-unsupported' 'an installed older judge cannot admit a reserve launch'
# A retained edit can lower the old cap to the default launch boundary. Two
# boundary values alone cannot prove that it consumes a changed reserve.
sed 's/-ge 400000/-ge 250000/' "$LEGACY_LIB/lane-context.sh" > "$TMP_ROOT/lower-legacy-cap"
mv "$TMP_ROOT/lower-legacy-cap" "$LEGACY_LIB/lane-context.sh"
launch 249999 Agent ORCH_HANDOFF_AGENT_RESERVE_TOKENS=200000
expect 2 'lane-mail-check: agent-input=reserve-unsupported' 'a lower legacy cap cannot stand in for reserve support'
plant_install

# An ordinary checkout, or a child caller, never inherits the lead's mark.
launch 250000 Agent 'LANE_MAIL_ITEM=AGENT-1'
ARM_ARGS=(halt)
run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",agent_id:"a1",transcript_path:$p,tool_name:"Agent"}')"
expect 0 - 'a child does not meet the lead launch mark'
ARM_ARGS=()
unmark_lanes
launch 600000 Agent
expect 0 - 'an ordinary session is outside the lane mark'

while IFS='|' read -r harness tool tokens window rc key; do
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
  expect "$rc" "$key" "$harness attached tool $tool at its reserve boundary"
  # No roster is read on this harness, so the refusal says so and names the
  # lane's handoff rather than a wait.
  if [ "$rc" = 2 ]; then
    assert_eq "roster=$(sed -n 's/^lane-mail-check: agent-roster=//p' "$ERR_FILE") handoffs=$(handoffs_named)" \
      "roster=unread harness=$harness handoffs=1" "$harness attached tool $tool names no roster and its handoff"
  fi
  ARM_ARGS=()
done <<'ROWS'
codex|spawn_agent|119199|258400|0|-
codex|spawn_agent|119200|258400|2|lane-mail-check: agent-unobserved=spawn_agent tokens=119200 reserve=10000
codex|multi_agent_v2.spawn_agent|119200|258400|2|lane-mail-check: agent-unobserved=multi_agent_v2.spawn_agent tokens=119200 reserve=10000
codex|collaborationspawn_agent|119200|258400|2|lane-mail-check: agent-unobserved=collaborationspawn_agent tokens=119200 reserve=10000
codex|followup_task|119199|258400|0|-
codex|followup_task|119200|258400|2|lane-mail-check: agent-unobserved=followup_task tokens=119200 reserve=10000
codex|collaborationfollowup_task|119200|258400|2|lane-mail-check: agent-unobserved=collaborationfollowup_task tokens=119200 reserve=10000
codex|multi_agent_v2.followup_task|119200|258400|2|lane-mail-check: agent-unobserved=multi_agent_v2.followup_task tokens=119200 reserve=10000
codex|send_message|119200|258400|0|-
pi|subagent|89999|200000|0|-
pi|subagent|90000|200000|2|lane-mail-check: agent-unobserved=subagent tokens=90000 reserve=10000
ROWS

# The first attached launch reads the environment built for a custom command.
mkdir -p "$TMP_ROOT/launch-bin"
cat > "$TMP_ROOT/launch-bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${ORCH_COMPACTION_OVERRIDES:-}"
STUB
chmod +x "$TMP_ROOT/launch-bin/codex"
custom_row=0
while IFS='|' read -r cmd rc key; do
  custom_row=$((custom_row + 1))
  new_lane "agent_codex_custom-$custom_row" AGENT-1
  mkdir -p "$LANE/tmp/lane-mail/AGENT-1"
  install_hook "$HOOK" "$LANE/.codex/hooks/lane-mail-check.sh"
  usage_line codex 1000 > "$TRANSCRIPT"
  evidence=$(PATH="$TMP_ROOT/launch-bin:$PATH" "$BASH" -euo pipefail -c '
    source "$1"
    line=$(lane_launch_line "$2" codex CODEX_HOME "$3" custom)
    "$BASH" -c "$line"
  ' _ "$REPO_ROOT/skills/orch/scripts/lib/lane-launch.sh" "$cmd" "$TMP_ROOT/launch-home")
  ARM_ARGS=(halt)
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" \
    '{session_id:"s1",transcript_path:$p,tool_name:"spawn_agent",tool_input:{}}')" \
    "ORCH_COMPACTION_OVERRIDES=$evidence" ORCH_HANDOFF_AGENT_RESERVE_TOKENS=10000
  expect "$rc" "$key" "first specialist from custom Codex command: $cmd"
  ARM_ARGS=()
done <<'ROWS'
codex -c model_auto_compact_token_limit=9223372036854775807 -c model_auto_compact_token_limit_scope=body_after_prefix -c model_post_turn_compact_threshold_percent=0|0|-
codex prompt|2|lane-mail-check: agent-input=context-unmeasured
env codex -c model_auto_compact_token_limit=9223372036854775807 -c model_auto_compact_token_limit_scope=body_after_prefix -c model_post_turn_compact_threshold_percent=0|2|lane-mail-check: agent-input=context-unmeasured
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
    "RC=2 decision=deny first=lane-mail-check: agent-unobserved=$tool tokens=70000 reserve=10000" 'Copilot camelCase names its attached launch and receives deny JSON'
done
ARM_ARGS=()
CALL_ENV=()

# The identified fleet overseer meets the same launch check and keeps its
# existing explicit handoff escape.
overseer_transcript
new_overseer agent_overseer
judge_says "$CONTEXT_MARK_LINE"
# shellcheck disable=SC2046
AGENTS=out launch 250000 Agent $(overseer_env)
expect 2 "$(scan_key 'lane-mail-check: agent-reserve=Agent tokens=250000 reserve=150000')" 'the identified overseer meets the reserve'
# Only a refusal at the plain mark names the succession, which oversee-succeed
# judges by that same mark; a reserve refusal, with the roster read or not,
# names none it would refuse.
named_judge() { sed -n 's/.*oversee-succeed \(.*\) -- \[THE PERMISSION.*/\1/p' "$ERR_FILE" | head -n 1; }
while IFS='|' read -r agents tokens rc key judge; do
  case "$agents" in out | unclassified) ;; *) [ "$SCAN_AVAILABLE" -eq 1 ] || continue ;; esac
  key=$(scan_key "$key")
  # shellcheck disable=SC2046
  AGENTS=$agents launch "$tokens" Agent $(overseer_env)
  expect "$rc" "$key" "overseer Agent launch at $tokens with agents $agents"
  [ "$rc" = 0 ] || assert_eq "$(named_judge)" "$judge" "overseer refusal at $tokens with agents $agents names its succession"
done <<'ROWS'
out|240000|0|-|
out|260000|2|lane-mail-check: agent-reserve=Agent tokens=260000 reserve=150000|
out|300000|2|lane-mail-check: agent-reserve=Agent tokens=300000 reserve=150000|
unclassified|300000|2|lane-mail-check: agent-unobserved=Agent tokens=300000 reserve=150000|
out|400000|2|lane-mail-check: agent-launch=Agent tokens=400000|--context 400000:1000000
returned|260000|0|-|
none|260000|0|-|
none|400000|2|lane-mail-check: agent-launch=Agent tokens=400000|--context 400000:1000000
ROWS
record_overseer_handoff
# shellcheck disable=SC2046
launch 600000 Agent $(overseer_env)
expect 0 - 'a standing handoff retains its escape'

# The real supplied-context result crosses the process boundary into the
# hook's existing workflow-state handoff argument, without a second judge.
new_overseer agent_native_decision
rm -- "$LANE/.claude/skills/orch/scripts/oversee-succeed"
ln -s "$REPO_ROOT/skills/orch/scripts/oversee-succeed" "$LANE/.claude/skills/orch/scripts/oversee-succeed"
write_transcript "$TRANSCRIPT" 600000
# shellcheck disable=SC2046
run_payload "$(jq -nc --arg p "$TRANSCRIPT" '{session_id:"s1",transcript_path:$p,stop_hook_active:false}')" $(overseer_env)
expect 2 'lane-mail-check: context=600000' 'the real native mark result retains its refusal'
assert_eq "$(handoff_context | jq -c '[.decision.tokens,.decision.cap,.decision.mark_pct,.decision.cap_mark,.decision.window_mark,.decision.reserve_applied,.decision.reserve_tokens,.source.session_id,.source.transcript]')" \
  "[600000,400000,50,400000,500000,false,0,\"s1\",\"$TRANSCRIPT\"]" \
  'the real native result reaches the parsed overseer handoff record'

new_overseer agent_children
judge_says "$CONTEXT_MARK_LINE"
write_transcript "$TRANSCRIPT" 600000
agent_stop() { # BACKGROUND_FIELDS
  local fields="$1"
  shift
  # shellcheck disable=SC2046
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" --argjson extra "$fields" \
    '{session_id:"s1",transcript_path:$p,stop_hook_active:false} + $extra')" $(overseer_env) "$@"
}
agent_rows() { sed -n 's/^lane-mail-check: attached-agent=//p' "$ERR_FILE"; }
# A host without the existing timeout command cannot safely read old Claude
# history. Its native-list cases still run; its fallback must report unknown.
expect_fallback() { # EXPECTED_ROWS CASE
  if [ "$SCAN_AVAILABLE" -eq 1 ]; then
    assert_eq "$(agent_rows)" "$1" "$2"
  else
    assert_eq "$(sed -n 's/^lane-mail-check: agents=//p' "$ERR_FILE")" unknown "$2: bound unavailable"
    assert_eq "$(agent_rows)" '' "$2: no unverified rows"
  fi
}
# The native registry names subagents and teammates; a task type outside the
# documented agent and non-agent lists is unclassified, so the roster is
# unknown. The turn-end judge takes the reading alone, whatever is out.
while IFS='|' read -r fields want unknown; do
  rm -f -- "${JUDGE_DIR:?}/args"
  agent_stop "$fields"
  expect 2 'lane-mail-check: context=612000' 'a reached mark retains its refusal'
  assert_eq "rows=$(agent_rows) unknown=$(sed -n 's/^lane-mail-check: agent-unclassified=//p' "$ERR_FILE")" \
    "rows=$want unknown=$unknown" "native child list for $fields"
  assert_eq "$(judge_argv)" '--check-marks --context 600000:1000000' "turn-end judge arguments for $fields"
done <<'ROWS'
{"background_tasks":[]}||
{"background_tasks":[{"id":"a1","type":"subagent","status":"running"}]}|a1 status=running output=unknown|
{"background_tasks":[{"id":"a1","type":"subagent","status":"completed"},{"id":"s1","type":"shell","status":"running"}]}||
{"background_tasks":[{"id":"m1","type":"monitor","status":"running"},{"id":"p1","type":"MCP task","status":"running"}]}||
{"background_tasks":[{"id":"t1","type":"teammate","status":"running"}]}|t1 status=running output=unknown|
{"background_tasks":[{"id":"w1","type":"workflow","status":"running"}]}||task-type
ROWS
# A launch admitted with none out leaves its child running at the turn end,
# which the judge reads by the plain mark: no reserve, so no hand-over below
# 400000.
if [ "$SCAN_AVAILABLE" -eq 1 ]; then
  judge_says "$BELOW_MARK_LINE"
  # shellcheck disable=SC2046
  launch 260000 Agent $(overseer_env)
  expect 0 - 'the overseer launches at 260000 of 1000000 with none out'
  rm -f -- "${JUDGE_DIR:?}/args"
  agent_stop '{"background_tasks":[{"id":"a1","type":"subagent","status":"running"}]}'
  expect 0 - 'its turn end with that child running demands no hand-over below 400000'
  assert_eq "$(judge_argv)" '--check-marks --context 260000:1000000' 'the turn-end judge takes the reading alone'
  judge_says "$CONTEXT_MARK_LINE"
  write_transcript "$TRANSCRIPT" 600000
fi
agent_stop '{"background_tasks":null}'
assert_eq "$(sed -n 's/^lane-mail-check: agents=//p' "$ERR_FILE")" unknown 'malformed native state is unknown'

append_launch
agent_stop '{}'
expect_fallback 'a1 status=running output=unknown' 'fallback names the launched child'
# The usage tail cannot establish a roster. Keep the launch outside that
# window and add a recent usage line so only the full child scan can find it.
jq -nc '{message:{role:"assistant",content:("x" * 1048576)}}' >> "$TRANSCRIPT"
usage_line sonnet 600000 >> "$TRANSCRIPT"
agent_stop '{}'
expect_fallback 'a1 status=running output=unknown' 'complete history names a launch outside the usage window'
agent_stop '{"background_tasks":[]}'
assert_eq "$(agent_rows)" '' 'a valid native empty list takes priority over old transcript state'
append_notice monitor completed
agent_stop '{}'
expect_fallback 'a1 status=running output=unknown' 'a monitor notification clears no child'
append_notice a1 completed
agent_stop '{}'
expect_fallback '' 'the matching terminal notification ends the child hold'
append_launch
mkdir -p "${TRANSCRIPT%.jsonl}/subagents"
: > "${TRANSCRIPT%.jsonl}/subagents/agent-a1.jsonl"
agent_stop '{}'
expect_fallback "a1 status=running output=${TRANSCRIPT%.jsonl}/subagents/agent-a1.jsonl" 'a later launch replaces completion and names existing output'
append_teammate
agent_stop '{}'
expect_fallback "$(printf 'a1 status=running output=%s\nareviewer-t1 status=running output=unknown' "${TRANSCRIPT%.jsonl}/subagents/agent-a1.jsonl")" 'fallback names a spawned teammate'
printf '{broken\n' >> "$TRANSCRIPT"
agent_stop '{}'
assert_eq "$(sed -n 's/^lane-mail-check: agents=//p' "$ERR_FILE")" unknown 'an unreadable fallback never reports no child'

# Clock injection represents the account judgement spending its ceiling.
# Real timeout enforces the remaining budget. The fake jq emits a partial
# row before blocking, so a failed evaluation must discard actual stdout.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  SCAN_BIN="$TMP_ROOT/agent-scan-bin"
  mkdir -p "$SCAN_BIN"
  REAL_JQ=$(command -v jq)
  cat > "$SCAN_BIN/jq" <<SLOW_JQ
#!/usr/bin/env bash
if [ "\${1:-}" = -Rnr ] && [[ "\${2:-}" == *'capture("agentId:'* ]]; then
  printf 'ghost\\trunning\\n'
  sleep 10
  exit 0
fi
exec "$REAL_JQ" "\$@"
SLOW_JQ
  chmod +x "$SCAN_BIN/jq"
  if [ "$SCAN_AVAILABLE" -eq 1 ]; then
    REAL_TIMEOUT=$(command -v timeout)
    cat > "$SCAN_BIN/timeout" <<SCAN_TIMEOUT
#!/usr/bin/env bash
if [ "\${1:-}" = --kill-after=1 ]; then printf '%s\\n' "\$2" >> "$TMP_ROOT/scan-seconds"; fi
exec "$REAL_TIMEOUT" "\$@"
SCAN_TIMEOUT
    chmod +x "$SCAN_BIN/timeout"
  fi
  for scan_case in timeout unbounded-control unavailable exhausted native; do
    case "$scan_case" in
      # The budget is judged only once the host bound exists.
      timeout | unbounded-control | exhausted)
        [ "$SCAN_AVAILABLE" -eq 1 ] || continue ;;
    esac
    scan_edits=(-e 's/^  JUDGE_RC=0$/  HOOK_AGENT_DEADLINE=$((SECONDS + 30)); SECONDS=$((SECONDS + 20)); JUDGE_RC=0/')
    case "$scan_case" in
      unbounded-control) scan_edits+=(-e 's#^    agents=\$("\${scan_bound\[@\]}" jq -Rnr#    agents=$(jq -Rnr#') ;;
      unavailable | native) scan_edits+=(-e 's/^! command -v timeout.*$/BOUND_BY=()/') ;;
      exhausted) scan_edits=(-e 's/^  JUDGE_RC=0$/  SECONDS=$((SECONDS + 30)); JUDGE_RC=0/') ;;
    esac
    variant "agent-scan-$scan_case" "${scan_edits[@]}"
    install_hook "$VARIANT_PATH" "$CASE_HOOK"
    write_transcript "$TRANSCRIPT" 600000
    append_launch
    : > "$TMP_ROOT/scan-seconds"
    if [ "$scan_case" = native ]; then
      agent_stop '{"background_tasks":[]}' "PATH=$SCAN_BIN:$TMUX_BIN:$PATH"
      assert_eq "unknown=$(sed -n 's/^lane-mail-check: agents=//p' "$ERR_FILE") rows=$(agent_rows)" \
        'unknown= rows=' 'native empty tasks retain priority without a fallback bound'
    else
      agent_stop '{}' "PATH=$SCAN_BIN:$TMUX_BIN:$PATH"
      unknown=$(sed -n 's/^lane-mail-check: agents=//p' "$ERR_FILE")
      rows=$(agent_rows)
      checker_rc=0
      [ "$unknown" = unknown ] && [ -z "$rows" ] || checker_rc=1
      if [ "$scan_case" = unbounded-control ]; then
        assert_eq "$checker_rc" 1 'control: removing the bound fails the unknown/no-partial-roster assertion'
      else
        assert_eq "$checker_rc" 0 "$scan_case preserves unknown and discards partial rows"
        case "$scan_case" in
          timeout) cause=124 ;;
          unavailable) cause=timeout-unavailable ;;
          exhausted) cause=budget-exhausted ;;
        esac
        assert_eq "$(sed -n 's/^lane-mail-check: agent-scan=//p' "$ERR_FILE")" "$cause" "$scan_case reports its evaluation cause"
      fi
      if [ "$scan_case" = timeout ]; then
        scan_seconds=$(cat "$TMP_ROOT/scan-seconds")
        assert_eq "$([ "$scan_seconds" -gt 0 ] && [ "$scan_seconds" -le 7 ] && echo remaining || echo unbounded)" \
          remaining 'the parser receives only the remaining budget after the account cost'
      fi
    fi
    expect 2 'lane-mail-check: context=612000' "$scan_case retains the original context refusal"
  done
  install_hook "$HOOK" "$CASE_HOOK"
fi

# One control proves this suite can go red: without the attached launch check
# every refusal row passes, the Codex and Pi rows that read no roster among them.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  variant agent-no-launch -e 's/^  attached_launch_check$/  :/'
  control_rc=0
  env "HOOK_UNDER_TEST=$VARIANT_PATH" "$BASH" "$TEST_DIR/lane-mail-check-agent.test.sh" \
    > "$TMP_ROOT/launch.control.log" 2>&1 || control_rc=$?
  assert_eq "$control_rc" 1 'control launch makes the real hook assertions fail'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
