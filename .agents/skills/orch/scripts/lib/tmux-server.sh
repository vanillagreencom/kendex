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
# words in TMUX_SESSION_DETAIL. This is the one reading of that answer: a
# caller keys its missing-session and failed-call refusals off the status and
# never matches the text itself.
TMUX_SESSION_DETAIL=""
tmux_session_present() {
  if TMUX_SESSION_DETAIL="$(tmux has-session -t "=$1" 2>&1)"; then return 0; fi
  case "$TMUX_SESSION_DETAIL" in
    "can't find session"*) return 3 ;;
  esac
  return 1
}
