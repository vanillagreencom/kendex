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
