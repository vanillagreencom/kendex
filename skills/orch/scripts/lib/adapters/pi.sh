# shellcheck shell=bash
#
# The Pi adapter: the context a session has used, read from the session file Pi
# writes, and the window, which Pi keeps in its model registry and never in
# that file: the pi-hooks carrier puts it on the turn-end and tool-call
# payloads as `context_window`, from the session's own `getContextUsage()`.
# A read with no payload window, the pre-panel check a lane runs from its own
# shell or a hook payload from a pi-hooks carrier that sends no
# `context_window`, takes the window the session's record holds or reads Pi's
# registry itself (lane_adapter_pi_reading).
#
# Pi has no launch word for compaction. Its switch is `compaction.enabled` in
# its settings file, so open-terminal reads that value before a Pi launch
# instead (lane_adapter_pi_compaction_on, or lane_adapter_pi_compaction_judge
# on a hosted lane's files) and refuses one Pi would compact. pi-qol's budget
# guard and idle trigger read the same key and never compact while it is off,
# so this one key covers every automatic compaction in a kendex Pi install.
#
# Sourced by lib/lane-context.sh, never run.

# One reading from a Pi session file on stdin: `<tokens>\t<window>\t<model>`
# for the last assistant message carrying a usage object, the model as pi's
# `--model` spells it, `provider/id`, where the message names its provider;
# `$1` where that usage carries none of Pi's field names, and nothing where no
# message carries usage. The provider is what names the account a pi session
# spends (lib/overseer-launch.sh § ol_account).
# The context is the message's input plus the cache it was read from and
# written to, and its output, which the next request sends back: the sum Pi's
# own `totalTokens` is (`Usage`, @earendil-works/pi-ai).
#
# The window is a verified point only while effective settings disable
# compaction, and is then the first of: WINDOW, the one a hook payload named;
# the window BOX's record holds for the same SESSION and model
# (lane_adapter_pi_record_window); Pi's own registry for the reading's model
# (lane_adapter_pi_registry_window). With none it is empty, which the judge
# refuses as unmeasured. A number a caller types is no source: the pre-panel
# command passes no WINDOW. Settings errors are reported without discarding
# the token count.
lane_adapter_pi_reading() { # UNREAD WINDOW [DIR] [SESSION] [BOX]
  local off=false rc=0 reading tokens window model
  lane_adapter_pi_compaction_on "${3:-$PWD}" || rc=$?
  case "$rc" in
    0) ;; # Enabled compaction has no verified point in this reader.
    1) off=true ;;
    *) printf 'pi-settings=%s\n%s\n' "$LANE_ADAPTER_PI_FILE" "$LANE_ADAPTER_PI_CAUSE" >&2 ;;
  esac
  reading=$(jq -Rnr --arg unread "$1" '
    [inputs | fromjson? | .message? | objects
     | select((.usage | type) == "object")
     | (if (.provider // "") != "" and (.model // "") != "" then "\(.provider)/\(.model)" else .model end) as $model
     | .usage
     | if has("input") or has("output") or has("cacheRead") or has("cacheWrite")
       then "\((.input // 0) + (.output // 0) + (.cacheRead // 0) + (.cacheWrite // 0))\t\t\($model // "")"
       else $unread end]
    | last // empty') || return
  case "$reading" in
    '') return 0 ;;
    *$'\t'*) ;;
    *) printf '%s\n' "$reading"; return 0 ;;
  esac
  tokens=${reading%%$'\t'*}
  model=${reading##*$'\t'}
  window=""
  if [ "$off" = true ]; then
    window=${2:-}
    [ -n "$window" ] || window=$(lane_adapter_pi_record_window "${5:-}" "${4:-}" "$model")
    [ -n "$window" ] || window=$(lane_adapter_pi_registry_window "$model")
  fi
  printf '%s\t%s\t%s\n' "$tokens" "$window" "$model"
}

# The window BOX's context record holds for a Pi reading of SESSION on MODEL,
# and nothing where BOX or SESSION is empty, no record stands or it is another
# session's, model's or harness's, or a gap record. Read through
# lane_context_record_fields, which owns the record's shape. Any read of the
# same session through this chain may have written it, a turn end, an
# attached-launch check or the pre-panel command, with the window that read
# found: its payload's, an earlier record's or the registry's. A model
# switched since names another window.
lane_adapter_pi_record_window() { # BOX SESSION MODEL
  local record
  { [ -n "$1" ] && [ -n "$2" ] && [ -r "$1/$LANE_CONTEXT_RECORD" ]; } || return 0
  record=$(cat -- "$1/$LANE_CONTEXT_RECORD" 2>/dev/null) || return 0
  lane_context_record_fields "$record" || return 0
  [ "$LANE_CTX_HARNESS" = pi ] && [ "$LANE_CTX_SESSION" = "$2" ] && [ "$LANE_CTX_MODEL" = "$3" ] || return 0
  printf '%s\n' "$LANE_CTX_WINDOW"
}

# The context window Pi's model registry holds for MODEL, `provider/id`, read
# through the SDK of the `pi` on PATH by pi-registry-window.mjs beside this
# file, offline and against the Pi user directory the settings above are read
# from; nothing where MODEL names no provider, no `pi` or `node` is on PATH,
# or the registry names no window. The read takes about a second, so it runs
# only where no payload or record named one.
lane_adapter_pi_registry_window() { # MODEL
  local pi
  case "$1" in */*) ;; *) return 0 ;; esac
  pi=$(command -v pi) || return 0
  command -v node >/dev/null || return 0
  PI_OFFLINE=1 PI_CODING_AGENT_DIR="$(lane_adapter_pi_agent_dir)" \
    node "${BASH_SOURCE[0]%/*}/pi-registry-window.mjs" "$pi" "${1%%/*}" "${1#*/}" 2>/dev/null || :
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
  lane_adapter_pi_compaction_judge "$(lane_adapter_pi_agent_dir)/settings.json" "$1/.pi/settings.json"
}

# The same answer over the user settings file USER and the project file
# PROJECT, wherever they were read from: open-terminal judges a hosted lane on
# copies of its host's files.
lane_adapter_pi_compaction_judge() { # USER PROJECT
  local user
  lane_adapter_pi_enabled "$1" || return 2
  user="$LANE_ADAPTER_PI_ENABLED"
  lane_adapter_pi_enabled "$2" || return 2
  # The file whose value decides: the project one where it turns compaction
  # back on, the user one otherwise.
  LANE_ADAPTER_PI_FILE="$2"
  [ "$LANE_ADAPTER_PI_ENABLED" = true ] && return 0
  LANE_ADAPTER_PI_FILE="$1"
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
# deciding, wherever they were read from: open-terminal judges a hosted lane on
# copies of its host's carrier.
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
# does or its package.json does not read. open-terminal refuses a fleet launch
# without the wake; Pi lanes arm no mailbox monitor.
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
