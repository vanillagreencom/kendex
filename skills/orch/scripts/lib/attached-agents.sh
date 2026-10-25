#!/usr/bin/env bash
# Shared Claude attached-work interpretation. Consumers supply native registry
# input (or {}), the bound caller transcript, scratch and their existing scan
# deadline. AGENT_ROSTER holds active {id,name,status,output} rows; AGENT_STATE
# is none, out or unknown. AGENT_ROWS preserves the hook diagnostic protocol.
# No child process is started, stopped or adopted here.
set -euo pipefail

ATTACHED_AGENTS_SCAN_SECONDS=30

attached_agents_claude_history() { # TRANSCRIPT [BOUND_ARGV...]
  local transcript="$1"
  shift
  "$@" jq -Rnr '

      def text: if type == "string" then . elif type == "array" then
        [.[] | select(.type == "text") | .text] | join("\n") else "" end;
      def said: text,
        (if type == "array" then .[] | select(.type == "tool_result") | .content | text else empty end);
      def launched: (select(startswith("Async agent launched successfully"))
          | capture("agentId: (?<id>[A-Za-z0-9_-]+)")?),
        (select(startswith("Spawned successfully"))
          | capture("\nagent_id: (?<id>[A-Za-z0-9_-]+)\nname: (?<name>[^\n]+)")?);
      def results: .content | if type == "array" then .[] else empty end | select(.type == "tool_result");
      def changed($id; $status): .generation += 1 | .agents[$id] = $status;
      def awaiting: . == "queued-active" or . == "unconfirmed-active";
      def queued: awaiting or . == "queued" or . == "unconfirmed";
      def terminal: . == "completed" or . == "failed" or . == "killed";
      def uncertain: if terminal then . elif awaiting then "unconfirmed-active" elif queued then "unconfirmed" else "unknown" end;
      def settled($prior; $notice):
        if $prior | terminal then $prior
        elif $notice.completedStatus == "failed" then "failed"
        elif $notice.idleReason == "available" then
          if $prior | awaiting then ($prior | uncertain) else "completed" end
        elif $notice.idleReason == "interrupted" and (($prior | queued) == false) then "completed"
        else $prior | uncertain end;
      def noted($m): reduce ($m.content | said
            | scan("<task-notification>[\\s\\S]*?<task-id>([A-Za-z0-9_-]+)</task-id>[\\s\\S]*?<status>([a-z_]+)</status>[\\s\\S]*?</task-notification>")) as $n
            (. ; if .agents | has($n[0]) then
                changed($n[0]; if $n[1] | terminal then $n[1] else (.agents[$n[0]] | uncertain) end)
              else . end)
          | reduce ($m.content | said
            | scan("<teammate-message teammate_id=\"([^\"]+)\"[^>]*>\\s*(\\{\\s*\"type\"\\s*:\\s*\"idle_notification\"[\\s\\S]*?)\\s*</teammate-message>")) as $n
            (. ; if .names | has($n[0]) then .names[$n[0]] as $t
                | ([$n[1] | fromjson? | objects][0]) as $notice
                | changed($t; if $notice == null then (.agents[$t] | uncertain) else settled(.agents[$t]; $notice) end)
              else . end);
      reduce (inputs | fromjson | objects
          | select(.type == "assistant" or .type == "user" or .type == "queue-operation") | . as $record
          | if .type == "queue-operation" then select(.operation == "enqueue") | {role: "user", content: (.content | strings)}
            else .message? | objects | . + {result: $record.toolUseResult} end) as $m
          ({calls: {}, agents: {}, names: {}, generation: 0, unknown_calls: {}};
        if $m.role == "assistant" then
          reduce ($m.content | if type == "array" then .[] else empty end
            | select(.type == "tool_use" and (.id | type) == "string")) as $c
            (. ; if $c.name == "Agent" or $c.name == "Task" then
                .generation += 1 | .calls[$c.id] = {pending: true, name: $c.input.name, sync: (($c.input.run_in_background | tostring) != "true"
                  and (($c.input.name | type) != "string" or $c.input.name == ""))}
              elif $c.name == "SendMessage" and ($c.input.to | type) == "string" then
                .generation += 1
                | if ($c.input.message | type) == "string" then .calls[$c.id] = {pending: true, to: $c.input.to, status: "running"}
                elif ($c.input.message | type) == "object"
                  and $c.input.message.type == "shutdown_request" then .calls[$c.id] = {pending: true, to: $c.input.to, status: "completed"}
                else . end
              elif $c.name == "TaskStop" and ($c.input.task_id | type) == "string" then
                .generation += 1 | .calls[$c.id] = {pending: true, to: $c.input.task_id, status: "killed"}
              elif $c.name == "ListAgents" then
                .calls[$c.id] = {list: .generation, overlap: any(.calls[]; .pending == true)}
              else . end)
        elif $m.role == "user" then . as $state
          | reduce ($m | results | . as $r | [.content | text | launched][0] | objects
            | . + {name: (.name // $state.calls[$r.tool_use_id].name)}) as $l
            (. ; changed($l.id; "running")
              | if $l.name != null then .names[$l.name] = $l.id else . end)
          | noted($m)
          | reduce ($m | results) as $r
            (. ; .calls[$r.tool_use_id | if type == "string" then . else "" end] as $c
              | if $c != null then .calls[$r.tool_use_id].pending = false
                  | .generation += (if $c.pending then 1 else 0 end) else . end
              | if [$r.content | text | launched][0] != null or $c == null or $r.is_error == true then .
                elif $c | has("list") then
                  if $c.overlap or $c.list != .generation then .
                  elif ([$m | results] | length) != 1 or ($m.result.sections | type) != "array" then
                    reduce (.agents | to_entries[] | select(.value == "running" or (.value | queued))) as $a
                      (. ; changed($a.key; ($a.value | uncertain)))
                  else reduce ($m.result.sections[] | select(.kind == "teammates") | .rows[]) as $a
                    (. ; if .names | has($a.name) then .names[$a.name] as $t
                        | if .agents[$t] | queued then
                            if $a.status == "idle" or $a.status == "running" then .
                            else changed($t; (.agents[$t] | uncertain)) end
                          elif $a.status == "idle" then changed($t; "completed")
                          elif $a.status == "running" then changed($t; "running")
                          else changed($t; (.agents[$t] | uncertain)) end
                      else . end)
                  end
                elif $c | has("to") then (.names[$c.to] // $c.to) as $t
                  | if (.agents | has($t)) == false then .
                    elif $c.status == "running" and .agents[$t] == "killed" then
                      (if ([$m | results] | length) == 1 and ($m.result | type) == "object" then $m.result
                        else [$r.content | text | fromjson?][0] end
                        | if type == "object" then . else {} end) as $sent
                      | if $sent.success == true
                          and ((($sent.message | strings) // "") | test("^Teammate \"[^\"]+\" was not running; resumed it as an in-process teammate with [0-9]+ prior messages and your message as its next prompt\\.$"))
                        then changed($t; "queued")
                        else changed($t; "unconfirmed") end
                    else changed($t; if $c.status != "running" then $c.status
                        elif .agents[$t] | terminal then "queued"
                        elif .agents[$t] == "unknown" or .agents[$t] == "unconfirmed" or .agents[$t] == "unconfirmed-active" then "unconfirmed-active"
                        else "queued-active" end) end
                elif $c.sync then .
                else .unknown_calls[$r.tool_use_id] = ($c.name // "unmapped") end)
        else . end)
      | . as $state
      | (.agents | to_entries[] | .key as $id | [.key,
          (if .value == "queued" or .value == "queued-active" then "running"
            elif .value == "unconfirmed" or .value == "unconfirmed-active" then "unknown" else .value end),
          ([$state.names | to_entries[] | select(.value == $id) | .key][0] // "unmapped")] | @tsv),
        (.unknown_calls[] | ["unknown", "unknown", .] | @tsv)
  ' <"$transcript"
}

attached_agents_claude() { # INPUT TRANSCRIPT WORK_DIR DEADLINE EMIT_SECONDS TIMEOUT [emergency STATE_FILE]
  local INPUT="$1" TRANSCRIPT="$2" WORK_DIR="$3" HOOK_AGENT_DEADLINE="$4" AGENT_EMIT_SECONDS="$5"
  local NL=$'\n' TAB=$'\t' BOUND_BY=()
  [ -z "$6" ] || BOUND_BY=("$6")
  shift 6
  local agents row id status output name meta meta_name candidate matches history="" native=0 scan_seconds scan_rc=0 unclassified=""
  local scan_bound=()
  AGENT_ROWS=""
  AGENT_ROSTER='[]'
  AGENT_STATE=unknown
  if jq -e 'has("background_tasks")' <<<"$INPUT" >/dev/null; then
    native=1
    # https://code.claude.com/docs/en/hooks#stop-input names the task types.
    # A type outside both lists below may be an agent and is unclassified.
    agents=$(jq -r '
      .background_tasks | if type != "array" then error("task list is not an array") else . end
      | .[] | if type != "object" or (.type | type) != "string" then error("task type is invalid") else . end
      | select(.type != "shell" and .type != "monitor" and .type != "MCP task")
      | if .type != "subagent" and .type != "teammate" then ["?", "task-type"] | @tsv
        elif ((.id | type) == "string" and (.id | test("^[A-Za-z0-9_-]+$"))
          and (.status | type) == "string" and (.status | test("^[a-z_]+$")))
        then [.id, .status] | @tsv else error("subagent id or status is invalid") end
    ' <<<"$INPUT" 2>"$WORK_DIR/agents.err") || {
      AGENT_ROWS="lane-mail-check: agents=unknown$NL$(cat -- "$WORK_DIR/agents.err")"
      return 0
    }
  elif [ "${1:-}" = emergency ]; then
    # PostModelSwitch does not promise Stop's task registry. A full transcript
    # scan can delay the emergency stop. Preserve the durable child roster;
    # output paths still use the same measured layout below.
    if [ ! -f "${2:-}" ]; then AGENT_ROWS='lane-mail-check: agents=unknown'; return 0; fi
    agents=$(jq -r '
      (.child_sessions // {}) as $children
      | (($children | to_entries | map(select((.value.status // "active") != "closed")
          | .value.agent_id)) + [(.review_agent_ids // {} | to_entries[]
          | select(($children[.key].status // "active") != "closed") | .value)])
      | unique[] | select(type == "string" and length > 0) | [., "running"] | @tsv
    ' "$2" 2>"$WORK_DIR/agents.err") || {
      AGENT_ROWS="lane-mail-check: agents=unknown$NL$(cat -- "$WORK_DIR/agents.err")"
      return 0
    }
  elif [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # The parent Stop omits native task data on older versions or when the
    # registry cannot answer. This ordered history cannot be replaced by the
    # usage tail: an earlier launch can remain unfinished outside that tail.
    if [ "${#BOUND_BY[@]}" -eq 0 ]; then
      AGENT_ROWS="lane-mail-check: agents=unknown${NL}lane-mail-check: agent-scan=timeout-unavailable"
      return 0
    fi
    scan_seconds=$((HOOK_AGENT_DEADLINE - SECONDS - AGENT_EMIT_SECONDS))
    if [ "$scan_seconds" -le 0 ]; then
      AGENT_ROWS="lane-mail-check: agents=unknown${NL}lane-mail-check: agent-scan=budget-exhausted"
      return 0
    fi
    scan_bound=("${BOUND_BY[0]}" --kill-after=1 "$scan_seconds")
    # Each measured record moves one child: an async launch or a teammate
    # spawn puts it out; a task-notification ends an async child, and a
    # teammate's terminal idle notification ends a teammate; a plain-text
    # SendMessage to either puts it out again, and a
    # sent shutdown_request ends it, since the lead's transcript never
    # receives the approval and the lead is owed no further result. A
    # TaskStop call that did not fail ends the child it names by id or name.
    # SendMessage can resume that stopped child as an in-process teammate;
    # only its measured resume result proves the stopped run started again.
    # ListAgents (2.1.302) records teammate states in toolUseResult.sections;
    # its idle rows end the named turn even when no idle notification arrived.
    # Every roster transition invalidates an earlier pending list. Claude
    # Code 2.1.302 captures list state before its awaited peer reads, so even
    # a completion appended to that result is newer than the snapshot.
    # SendMessage writes the inbox before the teammate consumes it. No list
    # snapshot proves consumption. A send from an ended turn has no earlier
    # turn whose available notice could arrive afterward. A send to an
    # active turn does: even its available notice can follow an empty drain
    # that preceded the send. Keep that work unknown until the task ends.
    # In 2.1.302, interrupted notices precede the inbox read, missing reasons
    # continue the next prompt, and failed reasons can also continue. Only
    # completedStatus=failed proves the latter ended the teammate task.
    # A foreground Agent call (no run_in_background, no name) returns its
    # child's finished output, so its result puts nothing out. Any other
    # result of an async or named call is unclassified. Claude Code appends a
    # notification that arrives during a tool call to that call's result, and
    # records one queued while the model works as a queue-operation enqueue
    # entry (2.1.302), so task and idle notifications are read there as well;
    # the later remove entry repeats the enqueued text and is skipped. A
    # notification in a record arrived before or during the calls whose
    # results it carries, so it describes a turn that ended before their
    # message reached the child: a record's notifications apply before its
    # call results. A launch or spawn result in the same record may carry
    # that child's first notification on a sibling result, so the record's
    # launches register first.
    agents=$(attached_agents_claude_history "$TRANSCRIPT" "${scan_bound[@]}" 2>"$WORK_DIR/agents.err") || scan_rc=$?
    if [ "$scan_rc" -ne 0 ]; then
      # A failed command can print partial rows before it exits. None are a
      # complete roster, so only the cause survives the failed evaluation.
      AGENT_ROWS="lane-mail-check: agents=unknown${NL}lane-mail-check: agent-scan=$scan_rc$NL$(cat -- "$WORK_DIR/agents.err")"
      return 0
    fi
  else
    AGENT_ROWS='lane-mail-check: agents=unknown'
    return 0
  fi
  if [ "$native" -eq 1 ] && [ -n "$agents" ] && [ -f "$TRANSCRIPT" ] && [ "${#BOUND_BY[@]}" -gt 0 ]; then
    scan_seconds=$((HOOK_AGENT_DEADLINE - SECONDS - AGENT_EMIT_SECONDS))
    if [ "$scan_seconds" -gt 0 ]; then
      history=$(attached_agents_claude_history "$TRANSCRIPT" "${BOUND_BY[0]}" --kill-after=1 "$scan_seconds" 2>"$WORK_DIR/agents.err") || history=""
    fi
    agents=$(jq -Rnr --arg history "$history" '
      ($history | split("\n") | map(split("\t"))) as $names
      | inputs | split("\t") | . as $agent
      | . + ([$names[] | select(.[0] == $agent[0]) | .[2]][:1]) | @tsv' <<<"$agents") || return 1
  fi
  AGENT_STATE=none
  while IFS="$TAB" read -r id status name; do
    [ -n "$id" ] || continue
    if [ "$id" = '?' ]; then
      unclassified=$status
      AGENT_ROSTER=$(jq -c '. + [{id:"unknown",name:"unmapped",status:"unknown",output:"unknown"}]' <<<"$AGENT_ROSTER") || return 1
      continue
    fi
    case "$status" in completed | failed | killed) continue ;; esac
    name="${name:-unmapped}"
    meta="${TRANSCRIPT%.jsonl}/subagents/agent-$id.meta.json"
    if [ "$name" = unmapped ] && [ -f "$meta" ]; then
      name=$(jq -er '.name | strings | select(test("^[A-Za-z0-9_.-]+$"))' "$meta" 2>"$WORK_DIR/agents.err") || name=unmapped
    fi
    case "$status" in running | unknown) ;; *) status=unknown ;; esac
    if [ "$name" = unmapped ]; then status=unknown; fi
    case "$status" in unknown) unclassified=agent-status ;; esac
    AGENT_STATE=out
    output=unknown
    # Native Stop has no output path. Read only measured child metadata beside
    # this transcript; a name must resolve uniquely before its output is used.
    if [ -n "$TRANSCRIPT" ] && [ -f "${TRANSCRIPT%.jsonl}/subagents/agent-$id.jsonl" ]; then
      output="${TRANSCRIPT%.jsonl}/subagents/agent-$id.jsonl"
    elif [ "$name" != unmapped ] && [ -n "$TRANSCRIPT" ]; then
      matches=0
      for meta in "${TRANSCRIPT%.jsonl}"/subagents/agent-*.meta.json; do
        [ -f "$meta" ] || continue
        meta_name=$(jq -er '.name | strings' "$meta" 2>"$WORK_DIR/agents.err") || continue
        [ "$meta_name" = "$name" ] || continue
        candidate="${meta%.meta.json}.jsonl"
        [ -f "$candidate" ] || continue
        matches=$((matches + 1)); output="$candidate"
      done
      [ "$matches" -eq 1 ] || output=unknown
    fi
    row="lane-mail-check: attached-agent=$name id=$id status=$status output=$output"
    AGENT_ROSTER=$(jq -c --arg id "$id" --arg name "$name" --arg status "$status" --arg output "$output"       '. + [{id:$id,name:$name,status:$status,output:$output}]' <<<"$AGENT_ROSTER") || return 1
    AGENT_ROWS="${AGENT_ROWS:+$AGENT_ROWS$NL}$row"
  done <<<"$agents"
  if [ -n "$unclassified" ]; then
    AGENT_STATE=unknown
    AGENT_ROWS="lane-mail-check: agents=unknown${NL}lane-mail-check: agent-unclassified=$unclassified${AGENT_ROWS:+$NL$AGENT_ROWS}"
  fi
}
