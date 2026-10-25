# shellcheck shell=bash
# Native Agent launch and task-notification events shared by the hook and succession fixtures.
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
append_launch() { append_agent '{"name":"a1","run_in_background":true}' 'Async agent launched successfully. agentId: a1'; }
# The teammate spawn Claude Code writes for a named Agent call.
append_teammate() {
  append_agent '{"name":"reviewer"}' "$(printf 'Spawned successfully. (This tool result is internal metadata.)\nagent_id: areviewer-t1\nname: reviewer\nThe agent is now running and will receive instructions via mailbox.')"
}

notice_text() { # ID STATUS
  printf '<task-notification><task-id>%s</task-id><status>%s</status></task-notification>' "$1" "$2"
}
append_notice() { # ID STATUS
  jq -nc --arg n "$(notice_text "$1" "$2")" '{type:"user",message:{role:"user",content:$n}}' >> "$TRANSCRIPT"
}
