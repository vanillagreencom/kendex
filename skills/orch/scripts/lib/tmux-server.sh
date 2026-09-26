# shellcheck shell=bash
#
# The one rule for which tmux server a lane verb reaches, and whether it has
# one to reach at all. `open-terminal`, `oversee-watch` and `oversee launch`
# each drive tmux windows and once required `$TMUX`, so a verb run from
# outside tmux, a job unit or another runtime's session, refused although the
# person's tmux server was running. `ORCH_TMUX_SESSION` names the fleet's
# session, and with it set the verb reaches that session on the person's own
# server, the one tmux itself opens when `$TMUX` is unset: the socket it
# derives from their uid. Every tmux call the verb then makes goes to that
# server with no option added, because that is tmux's own default, so the
# rule here is what a verb reports and refuses on, never a second routing.
# The section at the end is oversee-watch's alone.
#
# Sourced, never run. Bash 3.2 syntax throughout.

# tmux_server_named — 0 when this process has a tmux server to reach: `$TMUX`
# names one, or `ORCH_TMUX_SESSION` names a session on the person's own.
tmux_server_named() {
  [ -n "${TMUX:-}" ] || [ -n "${ORCH_TMUX_SESSION:-}" ]
}

# tmux_server_socket — prints the socket path the verb's tmux calls reach: the
# first field of `$TMUX` where it is set, else the person's own default,
# `$TMUX_TMPDIR/tmux-<uid>/default` as tmux spells it. Prints nothing and
# returns 1 where tmux_server_named is false, so a caller never names a server
# it will not reach.
tmux_server_socket() {
  local uid
  if [ -n "${TMUX:-}" ]; then
    printf '%s\n' "${TMUX%%,*}"
    return 0
  fi
  [ -n "${ORCH_TMUX_SESSION:-}" ] || return 1
  uid="$(id -u)" || return 1
  printf '%s/tmux-%s/default\n' "${TMUX_TMPDIR:-/tmp}" "$uid"
}

# ---------------------------------------------------------------------------
# oversee-watch's own reads of that rule: the session its bare lane window
# names are read in and the server it reaches, resolved once at start, and
# the refusal of a lane carried with no session to read it in. They live in
# this library and not in the watch because the watch sits at its byte
# ceiling; like the rest of its lib/ they read that script's globals (LANES,
# STATE_FILE, REPEAT_CHILD, OVERSEE_WATCH_SESSION) and call its `die` and
# `ow_message`, so no other sourcer calls them.
# ---------------------------------------------------------------------------

# The session every bare lane window name belongs to, resolved ONCE, while the
# pane that started this watch still exists: tmux resolves a target with no
# session through the calling pane, and once that pane is gone it picks a
# session of its own, so a watch outliving its launcher would read every bare
# lane in some other session and report it window-gone. A repeat pass is handed
# the wrapper's answer in OVERSEE_WATCH_SESSION and never asks tmux itself.
# Empty off tmux, or where tmux named none; check_lane_set refuses a bare name
# then, with tmux's own words in WATCH_SESSION_DETAIL.
# ORCH_TMUX_SESSION outranks the pane, as for `open-terminal`, and needs no
# $TMUX: the watch then reaches the person's own server, named on the
# session-resolved line. A name tmux does not hold is refused, never read as a
# session with no windows, which would report every lane gone.
WATCH_SESSION=""
WATCH_SESSION_DETAIL=""
WATCH_SESSION_MISSING=""
WATCH_SERVER=""
watch_session_resolve() {
  local out target=()
  tmux_server_named || return 0
  WATCH_SERVER="$(tmux_server_socket)" || WATCH_SERVER=none
  if [[ "$REPEAT_CHILD" -eq 1 ]]; then
    WATCH_SESSION="${OVERSEE_WATCH_SESSION:-}"
    return 0
  fi
  if [[ -n "${ORCH_TMUX_SESSION:-}" ]]; then
    if out="$(tmux has-session -t "=$ORCH_TMUX_SESSION" 2>&1)"; then
      WATCH_SESSION="$ORCH_TMUX_SESSION"
    else
      WATCH_SESSION_MISSING="$ORCH_TMUX_SESSION"
      WATCH_SESSION_DETAIL="$out"
    fi
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
  # Only tmux's own "can't find session" is a missing session; any other
  # answer is the call failing.
  if [[ ${#LANES[@]} -gt 0 && -n "$WATCH_SESSION_MISSING" ]]; then
    [[ "$WATCH_SESSION_DETAIL" == "can't find session"* ]] \
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
