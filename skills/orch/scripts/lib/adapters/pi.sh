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

# The Pi user directory: PI_CODING_AGENT_DIR, else the home's `.pi/agent`.
lane_adapter_pi_agent_dir() {
  printf '%s\n' "${PI_CODING_AGENT_DIR:-${LANES_HOME:-$HOME}/.pi/agent}"
}

# Whether Pi would compact a session started in DIR: 0 where it may, naming in
# LANE_ADAPTER_PI_FILE the file that decides it, 1 where the user settings file
# turns `compaction.enabled` off and the project file does not turn it back on,
# 2 where a settings file could not be read, which it names in
# LANE_ADAPTER_PI_FILE with jq's words in LANE_ADAPTER_PI_CAUSE. An
# absent key is Pi's default, true. The project file counts only against the
# switch: Pi applies it only in a workspace it trusts, so a project `false` may
# be ignored where a project `true` may not.
LANE_ADAPTER_PI_FILE=""
LANE_ADAPTER_PI_CAUSE=""
lane_adapter_pi_compaction_on() { # DIR
  local user
  lane_adapter_pi_enabled "$(lane_adapter_pi_agent_dir)/settings.json" || return 2
  user="$LANE_ADAPTER_PI_ENABLED"
  lane_adapter_pi_enabled "$1/.pi/settings.json" || return 2
  # The file whose value decides: the project one where it turns compaction
  # back on, the user one otherwise.
  LANE_ADAPTER_PI_FILE="$1/.pi/settings.json"
  [ "$LANE_ADAPTER_PI_ENABLED" = true ] && return 0
  LANE_ADAPTER_PI_FILE="$(lane_adapter_pi_agent_dir)/settings.json"
  [ "$user" = false ] && return 1
  return 0
}

# The `compaction.enabled` FILE sets into LANE_ADAPTER_PI_ENABLED, empty where
# it sets none or is not there. Exit 1 where FILE is there and jq cannot read
# it, with FILE in LANE_ADAPTER_PI_FILE and jq's words in LANE_ADAPTER_PI_CAUSE.
LANE_ADAPTER_PI_ENABLED=""
lane_adapter_pi_enabled() { # FILE
  LANE_ADAPTER_PI_ENABLED=""
  [ -e "$1" ] || return 0
  if ! LANE_ADAPTER_PI_ENABLED=$(jq -r 'if (.compaction? | type) == "object" and (.compaction | has("enabled"))
       then (.compaction.enabled | tostring) else "" end' "$1" 2>&1); then
    LANE_ADAPTER_PI_FILE="$1"
    LANE_ADAPTER_PI_CAUSE="$LANE_ADAPTER_PI_ENABLED"
    LANE_ADAPTER_PI_ENABLED=""
    return 1
  fi
  return 0
}

# Whether the pi-hooks carrier Pi loads for a session started in DIR puts the
# model's `context_window` on its Stop payload, the one place a Pi window
# reaches the turn-end hook: 0 where the installed carrier, the project's or
# else the user's, names that field, 1 where none installed does. A carrier
# that predates the field leaves every Pi reading without a window.
lane_adapter_pi_window_read() { # DIR
  local root
  for root in "$1/.pi/packages" "$(lane_adapter_pi_agent_dir)/packages"; do
    [ -d "$root/@vanillagreen/pi-hooks/extensions" ] || continue
    grep -rqF -- context_window "$root/@vanillagreen/pi-hooks/extensions" && return 0
    return 1
  done
  return 1
}
