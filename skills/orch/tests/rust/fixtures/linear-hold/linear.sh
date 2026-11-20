#!/usr/bin/env bash
# A tracker stand-in that blocks: the first call
# writes its arguments to $LINEAR_HOLD_LOG, then waits for the test's line
# on $LINEAR_HOLD_FIFO, and
# marks the hold spent in $LINEAR_HOLD_FIFO.spent so every later call
# answers at once; each call then answers as the linear-fixture would from
# $LINEAR_FAKE_REPLIES. A row holds the whole tracker duty in one real read
# while it drives the clock and counts the mail duty's runs; no sleep
# orders the row.
# With the names unset, the log, the FIFO and the map are `linear-hold.log`,
# `linear.fifo` and `linear.json` beside the invoked path, as for the
# linear-fixture.
set -u
here="$(dirname "${BASH_SOURCE[0]}")"
: "${LINEAR_HOLD_LOG:=$here/linear-hold.log}"
: "${LINEAR_HOLD_FIFO:=$here/linear.fifo}"
export LINEAR_FAKE_REPLIES="${LINEAR_FAKE_REPLIES:-$here/linear.json}"
export LINEAR_FAKE_LOG="${LINEAR_FAKE_LOG:-$here/linear.log}"
printf '%s\n' "$*" >> "$LINEAR_HOLD_LOG"
if [ ! -e "$LINEAR_HOLD_FIFO.spent" ]; then
  # The read-write open never blocks and the read gives up after
  # HOLD_BOUND_SECS, so a row that dies before its release leaves no reader.
  [ -p "$LINEAR_HOLD_FIFO" ] || { echo "linear-hold: hold-not-fifo path=$LINEAR_HOLD_FIFO" >&2; exit 2; }
  exec 9<>"$LINEAR_HOLD_FIFO"
  read -r -t "${HOLD_BOUND_SECS:-120}" -u 9 _ \
    || { echo "linear-hold: hold-unreleased path=$LINEAR_HOLD_FIFO bound=${HOLD_BOUND_SECS:-120}" >&2; exit 124; }
  exec 9<&-
  : > "$LINEAR_HOLD_FIFO.spent"
fi
exec "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../linear-fixture/linear.sh" "$@"
