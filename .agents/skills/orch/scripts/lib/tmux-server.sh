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

# tmux_session_present NAME — whether the server this verb reaches holds the
# session NAME, matched exactly (`=`: tmux otherwise takes a prefix). Returns
# 0 where it does, 3 where tmux answers that it cannot find the session, and 1
# for any other failure, no server at the socket among them, with tmux's own
# words in TMUX_SESSION_DETAIL. This is the one reading of has-session's
# answer: a caller keys its missing-session and failed-call refusals off the
# status and never matches that text itself.
TMUX_SESSION_DETAIL=""
tmux_session_present() {
  if TMUX_SESSION_DETAIL="$(tmux has-session -t "=$1" 2>&1)"; then return 0; fi
  case "$TMUX_SESSION_DETAIL" in
    "can't find session"*) return 3 ;;
  esac
  return 1
}

# tmux_server_start PANE SERVER — prints the start time, in epoch seconds, of
# the tmux server holding PANE, the `start_time` a session record keeps beside
# SERVER so a later server that is handed the same pid is told apart from the
# one it names. Prints nothing and returns 1 where the pane cannot be read on
# the server this process reaches, or where that server's pid is not SERVER:
# a start read off another server binds the record to the wrong one.
tmux_server_start() { # PANE SERVER
  local out
  out="$(tmux display-message -p -t "$1" '#{pid} #{start_time}' 2>/dev/null)" || return 1
  [ "${out%% *}" = "$2" ] || return 1
  case "${out#* }" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "${out#* }"
}

# tmux_pane_live SERVER START PANE — whether the pane PANE on the tmux server
# whose process id is SERVER and whose start time is START still runs: the
# `<server pid> <pane id>` key the fleet record names its overseer by, since a
# pane id alone repeats on every server, bound to the server's start, since
# after a reboot or a server restart a new server may be handed the recorded
# pid and numbers its panes from %0 again. Returns 0 where the server this
# process reaches is SERVER, started at START, and lists PANE; 1 where SERVER
# runs no tmux, or that server started at another time or lists no PANE; and 2
# where SERVER runs a tmux that is not the server this process reaches, or
# the pane list could not be read: nothing here can judge a pane on a server
# it cannot ask. SERVER is read back off disk, so the pid may run anything;
# only a process named tmux can be the server it recorded. An empty START is
# a record carrying no start, which names the session in PANE on SERVER
# whatever that server's start: the pane is judged on SERVER alone. Which
# record carries no start is the caller's to ask of lib/overseer-launch.sh §
# OL_JQ_DEFS (ol_unstarted), the rule's one owner, never an empty field read
# here.
tmux_pane_live() { # SERVER START PANE
  local comm panes nl='
'
  comm="$(ps -o comm= -p "$1" 2>/dev/null)" || return 1
  case "${comm##*/}" in
    tmux*) ;;
    *) return 1 ;;
  esac
  panes="$(tmux list-panes -a -F '#{pid} #{start_time} #{pane_id}' 2>/dev/null)" || return 2
  if [ -n "$2" ]; then
    case "$nl$panes$nl" in
      *"$nl$1 $2 $3$nl"*) return 0 ;;
    esac
  elif awk -v s="$1" -v p="$3" '$1 == s && $3 == p { f = 1 } END { exit !f }' <<<"$panes"; then
    return 0
  fi
  [ "${panes%% *}" = "$1" ] || return 2
  return 1
}
