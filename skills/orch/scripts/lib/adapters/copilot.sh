# shellcheck shell=bash
#
# The Copilot adapter: the context a session has used, read from the session
# record its `statusLine` command writes (lib/copilot-session.sh), never from
# the transcript, which holds no live count, and never from the pane. It is the
# fallback reader: a turn end reads the reading the orch copilot-lane-context
# extension records from Copilot's own usage event first, and this record only
# where no such reading of the session stands.
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

# The share of the window at which Copilot starts compacting is
# LANE_CONTEXT_COPILOT_COMPACTION_PCT (lib/lane-context.sh), the one figure
# both Copilot readers judge against. A reading taken here is recorded under
# this capacity source, so a turn end tells it from the reading the orch
# copilot-lane-context extension records, which it reads first.
LANE_ADAPTER_COPILOT_CAPACITY_SOURCE="80% of context_window_size, from the Copilot statusLine session record"

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
  [ -z "$CS_WINDOW" ] || capacity=$((CS_WINDOW * LANE_CONTEXT_COPILOT_COMPACTION_PCT / 100))
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

# Whether the account at HOME runs copilot-statusline as its status line, often
# enough for its record to stay fresh: 0 where HOME/settings.json sets
# `statusLine` to a command whose first word is that script, by any path, an
# executable file there, with a `refreshInterval` in whole seconds above 0 and
# below COPILOT_SESSION_MAX_AGE_S. 1 otherwise, with LANE_ADAPTER_COPILOT_STATUS_REASON
# naming the first thing that failed: `settings-missing`, `settings-unreadable`
# (jq cannot read the file), `no-status-line` (no command statusLine),
# `other-command` (its command is not copilot-statusline), `command-missing`
# (not an executable file), `refresh-interval` (absent, not a whole number, 0,
# or at or above the bound). A session on an account answering 1 writes no record,
# or one its readers take as stale, and its context is never measured.
LANE_ADAPTER_COPILOT_STATUS_REASON=""
lane_adapter_copilot_status_line() { # HOME
  local fields command interval
  LANE_ADAPTER_COPILOT_STATUS_REASON=""
  [ -f "$1/settings.json" ] || { LANE_ADAPTER_COPILOT_STATUS_REASON=settings-missing; return 1; }
  fields=$(jq -r 'if (.statusLine | type) == "object" and .statusLine.type == "command"
    then [((.statusLine.command | strings) // ""),
          (.statusLine.refreshInterval | if type == "number" and . == floor then tostring else "" end)]
         | join("\t")
    else "" end' "$1/settings.json" 2>/dev/null) || { LANE_ADAPTER_COPILOT_STATUS_REASON=settings-unreadable; return 1; }
  [ -n "$fields" ] || { LANE_ADAPTER_COPILOT_STATUS_REASON=no-status-line; return 1; }
  command="${fields%%	*}"
  interval="${fields#*	}"
  command="${command%% *}"
  [ "${command##*/}" = copilot-statusline ] || { LANE_ADAPTER_COPILOT_STATUS_REASON=other-command; return 1; }
  case "$command" in
    */*) ;;
    *) command="$(command -v -- "$command" 2>/dev/null)" || command="" ;;
  esac
  { [ -n "$command" ] && [ -f "$command" ] && [ -x "$command" ]; } \
    || { LANE_ADAPTER_COPILOT_STATUS_REASON=command-missing; return 1; }
  case "$interval" in '' | *[!0-9]*) LANE_ADAPTER_COPILOT_STATUS_REASON=refresh-interval; return 1 ;; esac
  { [ "$interval" -gt 0 ] && [ "$interval" -lt "$COPILOT_SESSION_MAX_AGE_S" ]; } \
    || { LANE_ADAPTER_COPILOT_STATUS_REASON=refresh-interval; return 1; }
}
