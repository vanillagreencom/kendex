# shellcheck shell=bash
# The rules a mailbox obeys wherever the file sits: the lane's own disk through
# `lane-mail`, a provider's host through `lane-host append`, and the fixture
# that models a provider. One owner for each, because a drift in where a line
# ends glues two envelopes together or hands over half of one, and a drift in
# the lock loses a line whenever two writers meet.
#
# Sourced, never executed, after lib/file-lock.sh, whose orch_take_lock and
# orch_release_lock this uses. Bash 3.2-safe, like its callers.

# Whether FILE ends on a complete line: 0 when its last byte is a newline and
# when it is empty, 1 when a writer left a fragment there, 2 when it could not
# be read. Both sides of a mailbox ask this, the writer before it appends and
# the reader before it hands lines over, and a one-sided answer is how the two
# come apart: the writer glues two envelopes together, or the reader emits a
# partial line or drops a whole one.
mailbox_line_complete() { # FILE
  local last
  [ -s "$1" ] || return 0
  # `&&`, not `;`: a substitution reports its last command, so `tail; printf x`
  # reports the printf, and a read that failed would answer as a fragment.
  # The `printf x` guard stays, because the substitution strips the very
  # newline this compares against.
  last="$(tail -c 1 -- "$1" && printf x)" || return 2
  [ "$last" != "$(printf '\nx')" ] || return 0
  return 1
}

# A writer killed inside its write leaves a line with no newline of its own.
# Closing it makes it a line the reader counts and does not parse, so the
# envelope that follows lands whole instead of being glued to it and both lost.
# The caller holds the lock on FILE; the append here is its own open, which the
# kernel places at the end exactly as the caller's descriptor would.
mailbox_terminate() { # FILE
  local complete=0
  mailbox_line_complete "$1" || complete=$?
  [ "$complete" -ne 0 ] || return 0
  [ "$complete" -eq 1 ] || return 1
  printf '\n' >>"$1" || return 1
}

# Add stdin's bytes to FILE under a lock on FILE itself, which every writer of
# it on that disk opens. A lock anywhere else is one writer's own: two writers
# holding separate locks both read the file and the second write loses the
# first one's line. FILE is created when it is not there, under whatever umask
# the caller set, and an unterminated last line is closed first.
#
# Exit 3 when the lock could not be taken within WAIT_SECONDS, 2 when a write
# failed. The two are different repairs, a writer holding the mailbox against a
# disk or permission failure, so every caller turns the number into its own
# word before anyone reads it: lane-mail into lock-failed and write-failed, the
# provider and the fixture into lock-timeout and write-failed.
mailbox_append_locked() { # FILE WAIT_SECONDS — bytes on stdin
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
