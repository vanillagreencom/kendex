# shellcheck shell=bash
#
# The Codex adapter reads tokens used and effective capacity from the rollout.
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
  jq -Rnr --arg unread "$1" '
    reduce (inputs | fromjson? | objects) as $l ({};
      if $l.type == "turn_context" then .model = ($l.payload.model? // .model)
      elif $l.type == "event_msg" and $l.payload.type? == "token_count"
           and ($l.payload.info | type) == "object"
      then ($l.payload.info) as $i
           | if ($i.last_token_usage.total_tokens? | type) == "number"
             then .reading = "\($i.last_token_usage.total_tokens)\t\($i.model_context_window // "")"
             else .reading = $unread end
      else . end)
    | if .reading == null then empty
      elif .reading == $unread then $unread
      else "\(.reading)\t\(.model // "")" end'
}
