# shellcheck shell=bash
#
# The Pi adapter: the context a session has used, read from the session file Pi
# writes, and the window, which Pi keeps in its model registry and never in
# that file: the pi-hooks carrier puts it on the turn-end and tool-call
# payloads as `context_window`, from the session's own `getContextUsage()`,
# and the hook records it with the reading. A read with no payload window,
# the pre-panel check a lane runs from its own shell, takes the window the
# session's record holds (lane_adapter_pi_reading); a carrier that sends no
# `context_window` is refused at launch.
#
# Pi has no launch word for compaction. Its switch is `compaction.enabled` in
# its settings file, so a launch reads that value instead and refuses one Pi
# would compact: the runtime's launch gate for a lane (effects/launch/gate.rs),
# lane_adapter_pi_compaction_on for an overseer succession. pi-qol's budget
# guard and idle trigger read the same key and never compact while it is off,
# so this one key covers every automatic compaction in a kendex Pi install.
#
# Sourced by lib/lane-context.sh, never run.

# The Pi user directory: PI_CODING_AGENT_DIR, else the home's `.pi/agent`.
lane_adapter_pi_agent_dir() {
  printf '%s\n' "${PI_CODING_AGENT_DIR:-${LANES_HOME:-$HOME}/.pi/agent}"
}

# Whether the pi-hooks carrier Pi loads for a session started in DIR puts the
# model's `context_window` on its payloads: 0 where the installed carrier, the
# project's or else the user's, names that field, 1 where none installed does.
# The payload window is the session's own, from its `getContextUsage()`, and
# the only one the overseer's tool-call judgement takes; a carrier that
# predates the field leaves those calls unjudged and every turn end judged on
# a record or registry window for the transcript's model instead. One that
# puts it on the Stop payload alone leaves the overseer's tool calls
# unjudged, and its turn ends judged.
lane_adapter_pi_window_read() { # DIR
  lane_adapter_pi_carrier_sends "$1/.pi/packages" "$(lane_adapter_pi_agent_dir)/packages"
}

# The same answer over the package roots ROOT..., the first holding a carrier
# deciding, wherever they were read from.
lane_adapter_pi_carrier_sends() { # ROOT...
  local root
  for root in "$@"; do
    [ -d "$root/@vanillagreen/pi-hooks/extensions" ] || continue
    grep -rqF -- context_window "$root/@vanillagreen/pi-hooks/extensions" && return 0
    return 1
  done
  return 1
}

# Whether the pi-hooks carrier Pi loads for a session started in DIR starts a
# turn in an idle lane when its overseer's mail lands: 0 where the installed
# carrier, the project's or else the user's, lists the lane mail wake among
# the extensions its package.json gives Pi to load, 1 where none installed
# does or its package.json does not read. The runtime's launch gate refuses a
# lane launch without the wake; Pi lanes arm no mailbox monitor.
lane_adapter_pi_mail_wake() { # DIR
  lane_adapter_pi_carrier_wakes "$1/.pi/packages" "$(lane_adapter_pi_agent_dir)/packages"
}

# The same answer over the package roots ROOT..., the first holding a carrier
# deciding, as lane_adapter_pi_carrier_sends reads them. The deciding
# carrier's package.json version lands in LANE_ADAPTER_PI_CARRIER_VERSION,
# `none` where no carrier is installed and `unread` where its package.json
# names none or does not read. LANE_ADAPTER_PI_CARRIER_ROOT names the deciding
# package root so the launch refusal repairs that install, not another scope.
LANE_ADAPTER_PI_CARRIER_VERSION=none
LANE_ADAPTER_PI_CARRIER_ROOT=""
lane_adapter_pi_carrier_wakes() { # ROOT...
  local root manifest
  LANE_ADAPTER_PI_CARRIER_VERSION=none
  LANE_ADAPTER_PI_CARRIER_ROOT=""
  for root in "$@"; do
    [ -d "$root/@vanillagreen/pi-hooks/extensions" ] || continue
    LANE_ADAPTER_PI_CARRIER_ROOT="$root"
    manifest="$root/@vanillagreen/pi-hooks/package.json"
    LANE_ADAPTER_PI_CARRIER_VERSION=$(jq -r '.version | strings' "$manifest" 2>/dev/null) || LANE_ADAPTER_PI_CARRIER_VERSION=""
    LANE_ADAPTER_PI_CARRIER_VERSION=${LANE_ADAPTER_PI_CARRIER_VERSION:-unread}
    jq -e '(.pi.extensions // []) | index("./extensions/lane-mail-wake.ts") != null' "$manifest" >/dev/null 2>&1 && return 0
    return 1
  done
  return 1
}
