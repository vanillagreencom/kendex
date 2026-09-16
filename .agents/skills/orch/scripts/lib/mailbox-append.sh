# shellcheck shell=bash
# The two rules every mailbox append obeys, wherever the file sits: the lane's
# own disk through `lane-mail`, a provider's host through `lane-host append`,
# and the fixture that models a provider. One owner, because a drift in the
# termination rule glues two envelopes together and loses both, and a drift in
# the lock loses a line whenever two writers meet.
#
# Sourced, never executed, after lib/file-lock.sh, whose orch_take_lock and
# orch_release_lock this uses. Bash 3.2-safe, like its callers.

# A writer killed inside its write leaves a line with no newline of its own.
# Closing it makes it a line the reader counts and does not parse, so the
# envelope that follows lands whole instead of being glued to it and both lost.
# The caller holds the lock on FILE; the append here is its own open, which the
# kernel places at the end exactly as the caller's descriptor would.
mailbox_terminate() { # FILE
  local last terminated
  [ -s "$1" ] || return 0
  last="$(tail -c 1 -- "$1"; printf x)" || return 1
  terminated="$(printf '\nx')"
  [ "$last" != "$terminated" ] || return 0
  printf '\n' >>"$1" || return 1
}

# Add stdin's bytes to FILE under a lock on FILE itself, which every writer of
# it on that disk opens. A lock anywhere else is one writer's own: two writers
# holding separate locks both read the file and the second write loses the
# first one's line. FILE is created when it is not there, under whatever umask
# the caller set, and an unterminated last line is closed first.
#
# Exit 3 when the lock could not be taken within WAIT_SECONDS, 2 when a write
# failed. The caller names the failure; this reports which of the two it was.
mailbox_append_locked() { # FILE WAIT_SECONDS — bytes on stdin
  : >>"$1" || return 2
  exec 9>>"$1" || return 2
  if ! orch_take_lock 9 "$1" "$2"; then
    exec 9>&-
    return 3
  fi
  if ! mailbox_terminate "$1" || ! cat >&9; then
    exec 9>&-
    orch_release_lock
    return 2
  fi
  exec 9>&-
  orch_release_lock
}
