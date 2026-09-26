# shellcheck shell=bash
# The tmux session oversee-watch reads its bare lane window names in, and the
# server it reaches: resolved once at start, and refused where a lane is
# carried with no session to read it in. Sourced by oversee-watch after
# lib/tmux-server.sh, whose tmux_server_named, tmux_server_socket and
# tmux_session_present it reads, and like the rest of its lib/ it reads that
# script's globals (LANES, STATE_FILE, REPEAT_CHILD, OVERSEE_WATCH_SESSION)
# and calls its `die` and `ow_message`.

# The session every bare lane window name belongs to, resolved ONCE, while the
# pane that started this watch still exists: tmux resolves a target with no
# session through the calling pane, and once that pane is gone it picks a
# session of its own, so a watch outliving its launcher would read every bare
# lane in some other session and report it window-gone. A repeat pass is handed
# the wrapper's answer in OVERSEE_WATCH_SESSION and never asks tmux itself.
# Empty off tmux, or where tmux named none; check_lane_set refuses a bare name
# then, with tmux's own words in WATCH_SESSION_DETAIL. A setting tmux could not
# confirm is WATCH_SESSION_MISSING, with WATCH_SESSION_FAULT saying whether the
# server answered that the session is absent or the call itself failed.
# ORCH_TMUX_SESSION outranks the pane, as for `open-terminal`, and needs no
# $TMUX: the watch then reaches the person's own server, named on the
# session-resolved line. A name tmux does not hold is refused, never read as a
# session with no windows, which would report every lane gone.
WATCH_SESSION=""
WATCH_SESSION_DETAIL=""
WATCH_SESSION_MISSING=""
WATCH_SESSION_FAULT=""
WATCH_SERVER=""
watch_session_resolve() {
  local out probe target=()
  tmux_server_named || return 0
  WATCH_SERVER="$(tmux_server_socket)" || WATCH_SERVER=none
  if [[ "$REPEAT_CHILD" -eq 1 ]]; then
    WATCH_SESSION="${OVERSEE_WATCH_SESSION:-}"
    return 0
  fi
  if [[ -n "${ORCH_TMUX_SESSION:-}" ]]; then
    probe=0
    tmux_session_present "$ORCH_TMUX_SESSION" || probe=$?
    case "$probe" in
      0) WATCH_SESSION="$ORCH_TMUX_SESSION" ;;
      3) WATCH_SESSION_MISSING="$ORCH_TMUX_SESSION" WATCH_SESSION_FAULT=absent WATCH_SESSION_DETAIL="$TMUX_SESSION_DETAIL" ;;
      *) WATCH_SESSION_MISSING="$ORCH_TMUX_SESSION" WATCH_SESSION_FAULT=failed WATCH_SESSION_DETAIL="$TMUX_SESSION_DETAIL" ;;
    esac
    return 0
  fi
  [[ -z "${TMUX_PANE:-}" ]] || target=(-t "$TMUX_PANE")
  if out="$(tmux display-message -p ${target[@]+"${target[@]}"} '#S' 2>&1)" && [[ -n "$out" ]]; then
    WATCH_SESSION="$out"
  else
    WATCH_SESSION_DETAIL="$out"
  fi
}

# A lane is read through tmux, so a run naming one with no tmux server to
# reach is refused, and so is a bare name with no session to read it in. A
# single run and every repeat pass ask it of the lanes they carry.
# The session is named once, by the process that resolved it, the first time
# a bare name is read in it: after the argument checks, so a refusal is still
# the first line a refused run prints.
SESSION_NOTED=0
check_lane_set() {
  local lane
  [[ ${#LANES[@]} -eq 0 ]] || tmux_server_named || die tmux-missing "" "lanes=${LANES[*]}"
  # A setting tmux confirmed absent and a has-session call that failed for
  # another reason are two refusals: the second prescribes no session start.
  if [[ ${#LANES[@]} -gt 0 && -n "$WATCH_SESSION_MISSING" ]]; then
    [[ "$WATCH_SESSION_FAULT" == absent ]] \
      || die tmux-failed "$WATCH_SESSION_DETAIL" operation=has-session "server=$WATCH_SERVER" "lanes=${LANES[*]}"
    die session-missing "$WATCH_SESSION_DETAIL" "session=$WATCH_SESSION_MISSING" \
      source=ORCH_TMUX_SESSION "server=$WATCH_SERVER" "lanes=${LANES[*]}"
  fi
  for lane in ${LANES[@]+"${LANES[@]}"}; do
    [[ "$lane" != *:* ]] || continue
    [[ -n "$WATCH_SESSION" ]] \
      || die session-unresolved "$WATCH_SESSION_DETAIL" "lane=$lane" "path=${STATE_FILE:-none}"
    [[ "$SESSION_NOTED" -eq 0 && "$REPEAT_CHILD" -eq 0 ]] || continue
    ow_message session-resolved "session=$WATCH_SESSION" "server=$WATCH_SERVER" >&2
    SESSION_NOTED=1
  done
}
