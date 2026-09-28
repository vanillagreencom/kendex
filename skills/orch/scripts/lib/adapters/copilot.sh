# shellcheck shell=bash
#
# The Copilot adapter: the context a session has used, read from the session
# record its `statusLine` command writes (lib/copilot-session.sh), never from
# the transcript, which holds no live count, and never from the pane.
#
# Copilot has no switch that turns its automatic compaction off: its CLI starts
# compacting at about 80 percent of the window (GitHub's Copilot CLI context
# management documentation). The capacity this adapter hands the shared judge
# is that point, so the percentage mark fires with a margin before compaction
# on any window, and on the 1M window every launch selects (lib/lane-launch.sh,
# `--context long_context`) the 400000-token cap fires first.
#
# Sourced by lib/lane-context.sh, never run.

# shellcheck source=../copilot-session.sh
source "${BASH_SOURCE[0]%/*}/../copilot-session.sh"

# The share of the window at which Copilot starts compacting, from its
# documentation rather than a setting: nothing in the CLI reports or moves it.
LANE_ADAPTER_COPILOT_COMPACT_PCT=80

# One reading from a session record on stdin, as copilot_session_read accepted
# it: `<tokens>\t<capacity>\t<model>`, the capacity empty where the record names
# no window, and `$1` where the record carries no token count.
lane_adapter_copilot_reading() { # UNREAD
  local capacity=""
  copilot_session_fields "$(cat)" || return 1
  if [ -z "$CS_TOKENS" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  [ -z "$CS_WINDOW" ] || capacity=$((CS_WINDOW * LANE_ADAPTER_COPILOT_COMPACT_PCT / 100))
  printf '%s\t%s\t%s\n' "$CS_TOKENS" "$capacity" "$CS_MODEL"
}

# lane_adapter_copilot_transcript_owned PATH SESSION HOME — whether PATH is the
# transcript Copilot writes for the session SESSION under the account directory
# HOME: `HOME/session-state/SESSION/events.jsonl`. 0 where it is; 1 with
# `session-mismatch` in LANE_ADAPTER_OWNED_REASON where the file is not in the
# directory named for SESSION, and `home-mismatch` where it sits outside HOME.
lane_adapter_copilot_transcript_owned() { # PATH SESSION HOME
  LANE_ADAPTER_OWNED_REASON=""
  case "$1" in
    */session-state/"$2"/events.jsonl) ;;
    *) LANE_ADAPTER_OWNED_REASON=session-mismatch; return 1 ;;
  esac
  case "$1" in
    "${3%/}"/session-state/"$2"/events.jsonl) ;;
    *) LANE_ADAPTER_OWNED_REASON=home-mismatch; return 1 ;;
  esac
}

# Whether the account at HOME runs copilot-statusline as its status line, the
# one producer of the record this adapter reads: 0 where HOME/settings.json
# sets `statusLine` to a command whose first word is that script, by any path,
# 1 where it does not, the file is not there or jq cannot read it. A session on
# an account answering 1 writes no record, and its context is never measured.
lane_adapter_copilot_status_line() { # HOME
  local command
  [ -f "$1/settings.json" ] || return 1
  command=$(jq -r 'if (.statusLine | type) == "object" and .statusLine.type == "command"
    then (.statusLine.command | strings) // "" else "" end' "$1/settings.json" 2>/dev/null) || return 1
  command="${command%% *}"
  [ "${command##*/}" = copilot-statusline ]
}
