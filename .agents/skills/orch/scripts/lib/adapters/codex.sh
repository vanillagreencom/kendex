# shellcheck shell=bash
#
# The Codex adapter reads tokens from the rollout and resolves the compaction
# point using the actual launch overrides inherited by the hook. The rollout
# window alone cannot establish that point for an unverified configuration.
# lib/lane-launch.sh owns the launch policy. references/skill-rules.md,
# Compaction, describes its usable-window cap and remaining compaction paths.
#
# Sourced by lib/lane-context.sh, never run.

# One reading from a Codex rollout on stdin: `<tokens>\t<window>\t<model>`, `$1`
# where the last token count carries no `last_token_usage.total_tokens`, and
# nothing where the rollout holds no token count yet. Codex writes a
# `token_count` event after each response, whose `info` names the tokens the
# last response left in the window and `model_context_window`, the window it
# judges them against; the model is the one the last `turn_context` names.
lane_adapter_codex_reading() { # UNREAD
  jq -Rnr --arg unread "$1" --arg overrides "${ORCH_COMPACTION_OVERRIDES:-}" '
    # Codex 0.157.1: body_after_prefix keeps the separate usable-window cap.
    # A smaller body threshold needs prefix usage telemetry we do not have.
    # Complete executed overrides replace stored settings. Missing evidence
    # cannot establish the effective point, but it never discards token use.
    def point($window):
      (try ($overrides | fromjson | if type == "object" then . else {} end) catch {}) as $o
      | ($o.settings | if type == "object" then . else {} end) as $s
      | if $o.harness == "codex" and ($window | type) == "number"
           and $s.model_auto_compact_token_limit_scope == "body_after_prefix"
           and $s.model_post_turn_compact_threshold_percent == "0"
           and ($s.model_auto_compact_token_limit // "" | tostring | test("^[0-9]+$"))
           and ((try ($s.model_auto_compact_token_limit | tonumber) catch 0) >= $window)
        then $window else "" end;

    reduce (inputs | fromjson? | objects) as $l ({};
      if $l.type == "turn_context" then .model = ($l.payload.model? // .model)
      elif $l.type == "event_msg" and $l.payload.type? == "token_count"
           and ($l.payload.info | type) == "object"
      then ($l.payload.info) as $i
           | if ($i.last_token_usage.total_tokens? | type) == "number"
             then .reading = "\($i.last_token_usage.total_tokens)\t\(point($i.model_context_window))"
             else .reading = $unread end
      else . end)
    | if .reading == null then empty
      elif .reading == $unread then $unread
      else "\(.reading)\t\(.model // "")" end'
}

# The hook cannot call the session's collaboration tools. Codex 0.163.0
# persists their calls and results in its rollout; read that ordered history
# instead. A snapshot or named completion observes returned agents. Later
# launches and followups put them out again. /root is the lead, never its child.
# The caller bounds the full read and discards output on a parse failure.
# PreToolUse.tool_use_id names the invocation being judged, which is not an
# earlier launch even where its call is already in the rollout:
# https://learn.chatgpt.com/docs/hooks#pretooluse
# AgentStatus and agent/status.rs in Codex 0.163.0 define the states below.
# Interrupted releases the reserve until a followup puts the agent out again.
# A later full list replaces uncertain observations,
# but cannot settle a call that has not returned yet.
# Codex dispatch scheduling can differ from result recording order. A list
# that overlaps a launch or followup cannot establish the roster after it.
lane_adapter_codex_agents() { # [CURRENT_CALL_ID]
  jq -Rnr --arg current_call "${1:-}" '
    def decoded: if type == "string" then fromjson else . end;
    def status:
      if type == "object" then
        if keys == ["completed"] and (.completed == null or (.completed | type) == "string") then "completed"
        elif keys == ["errored"] and (.errored | type) == "string" then "errored"
        else "unknown" end
      else . end
      | if . == "idle" or . == "completed" then "completed"
        elif . == "errored" or . == "shutdown" or . == "not_found" or . == "interrupted" then "completed"
        elif . == "running" or . == "pending_init" then "running"
        else "unknown" end;
    def name: if type == "string" and test("^/root(/[A-Za-z0-9_-]+)*$") then .
      else error("invalid agent name") end;
    reduce (inputs | fromjson | objects
        | select(.type == "response_item" or (.type == "event_msg"
            and .payload.type == "item_completed" and .payload.item.type == "SubAgentActivity"
            and .payload.item.kind == "completed")) | .payload
        | select($current_call == "" or .call_id != $current_call)) as $r
      ({calls: {}, agents: {}, observed: false, unread: false};
        if $r.type == "function_call" then
          ($r.name | split(".") | last | sub("^collaboration"; "")) as $tool
          | if $tool == "list_agents" or $tool == "spawn_agent" or $tool == "followup_task" then
              ($r.arguments | decoded) as $args
              | .calls[$r.call_id] = {tool: $tool,
                  full: (($args.path_prefix // "") == "" or $args.path_prefix == "/root"),
                  overlap: any(.calls[]; .tool != "list_agents")}
              | if $tool != "list_agents" then
                  .calls |= with_entries(if .value.tool == "list_agents" then .value.overlap = true else . end)
                else . end
              | if $tool == "followup_task" then
                  ($args.target | if startswith("/") then . else "/root/" + . end | name) as $target
                  | .calls[$r.call_id].target = $target
                else . end
            else . end
        elif $r.type == "function_call_output" and .calls[$r.call_id] != null then
          .calls[$r.call_id] as $call
          | . as $before
          | try (
              # PreToolUse refuses before dispatch. Other plain text, including
              # a tool failure after dispatch, proves no such absence of work.
              if ($r.output | type) == "string"
                  and ($r.output | startswith("Tool call blocked by PreToolUse hook: ")) then .
              elif $call.tool == "list_agents" then
                if $call.full and ($call.overlap | not) then
                  ($r.output | decoded) as $out
                  | if ($out.agents | type) != "array" then error("agent list is unreadable") else . end
                  | .agents = (reduce $out.agents[] as $agent ({}; ($agent.agent_name | name) as $id
                      | if $id == "/root" then . else .[$id] = ($agent.agent_status | status) end))
                  | .unread = false | .observed = true
                elif $call.full then .unread = true else . end
              elif $call.tool == "spawn_agent" then
                ($r.output | decoded | .task_name | name) as $id
                | .agents[$id] = "running" | .observed = true
              else
                # The V2 followup producer returns an empty string on success.
                .agents[$call.target] = (if $r.output == "" then "running" else "unknown" end)
                | .observed = true
              end
            ) catch ($before | .unread = true)
          | del(.calls[$r.call_id])
        elif $r.type == "item_completed" then
          ($r.item.agent_path | name) as $id
          | if .agents[$id] != null then .agents[$id] = "completed" else . end
        else . end)
    | (.agents | to_entries[] | if .value == "unknown" then ["?", "agent-status"]
        else [.key, .value] end | @tsv),
      (select((.observed | not) or .unread) | ["?", "unread"] | @tsv),
      (.calls[] | ["?", "pending"] | @tsv)'
}

# lane_adapter_codex_transcript_owned PATH SESSION HOME — whether PATH is the
# rollout Codex writes for the session SESSION under the launch home HOME, the
# directory CODEX_HOME carries: `HOME/sessions/<year>/<month>/<day>/rollout-
# <time>-SESSION.jsonl`, the id being the one its `session_meta` line names.
# 0 where it is; 1 with `session-mismatch` in LANE_ADAPTER_OWNED_REASON where
# the file is not named for SESSION, and `home-mismatch` where it sits outside
# HOME's sessions tree. A private launch home holds its own sessions tree, so
# HOME is the home and never the account it was built under.
lane_adapter_codex_transcript_owned() { # PATH SESSION HOME
  LANE_ADAPTER_OWNED_REASON=""
  case "$1" in
    */rollout-*-"$2".jsonl) ;;
    *) LANE_ADAPTER_OWNED_REASON=session-mismatch; return 1 ;;
  esac
  case "$1" in
    "${3%/}"/sessions/*/rollout-*-"$2".jsonl) ;;
    *) LANE_ADAPTER_OWNED_REASON=home-mismatch; return 1 ;;
  esac
}
