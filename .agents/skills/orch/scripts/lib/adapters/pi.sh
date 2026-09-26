# shellcheck shell=bash
#
# The Pi adapter: the context a session has used, read from the session file Pi
# writes, and the window, which Pi keeps in its model registry and never in
# that file: the pi-hooks carrier puts it on the turn-end payload as
# `context_window`, from the session's own `getContextUsage()`.
#
# Pi has no launch word for compaction. Its switch is `compaction.enabled` in
# its settings file, so open-terminal reads that value before a Pi launch
# instead (lane_adapter_pi_compaction_on) and refuses one Pi would compact.
#
# Sourced by lib/lane-context.sh, never run.

# One reading from a Pi session file on stdin: `<tokens>\t<window>\t<model>`
# for the last assistant message carrying a usage object, `$1` where that usage
# carries none of Pi's field names, and nothing where no message carries usage.
# The context is the message's input plus the cache it was read from and
# written to (`Usage`, @earendil-works/pi-ai). `$2` is the window the payload
# named, empty where it named none.
lane_adapter_pi_reading() { # UNREAD WINDOW
  jq -Rnr --arg unread "$1" --arg window "${2:-}" '
    [inputs | fromjson? | .message? | objects
     | select((.usage | type) == "object") | .model as $model | .usage
     | if has("input") or has("cacheRead") or has("cacheWrite")
       then "\((.input // 0) + (.cacheRead // 0) + (.cacheWrite // 0))\t\($window)\t\($model // "")"
       else $unread end]
    | last // empty'
}

# Whether Pi would compact a session started in DIR: 0 where it may, 1 where
# the user settings file turns `compaction.enabled` off and the project file does
# not turn it back on, 2 where a settings file could not be read. An absent key
# is Pi's default, true. The project file counts only against the switch: Pi
# applies it only in a workspace it trusts, so a project `false` may be ignored
# where a project `true` may not. PI_CODING_AGENT_DIR moves the user file.
lane_adapter_pi_compaction_on() { # DIR
  local agent="${PI_CODING_AGENT_DIR:-${LANES_HOME:-$HOME}/.pi/agent}" user="" project=""
  if [ -e "$agent/settings.json" ]; then
    user=$(lane_adapter_pi_enabled "$agent/settings.json") || return 2
  fi
  if [ -e "$1/.pi/settings.json" ]; then
    project=$(lane_adapter_pi_enabled "$1/.pi/settings.json") || return 2
  fi
  [ "$user" = false ] && [ "$project" != true ] && return 1
  return 0
}

# The `compaction.enabled` a settings file sets, empty where it sets none.
lane_adapter_pi_enabled() { # FILE
  jq -r 'if (.compaction? | type) == "object" and (.compaction | has("enabled"))
         then (.compaction.enabled | tostring) else "" end' "$1" 2>/dev/null
}
