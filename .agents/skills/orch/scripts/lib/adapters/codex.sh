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
