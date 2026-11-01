#!/usr/bin/env bash
# A tracker stand-in that blocks (step5-map § B row 6): the first call
# writes its arguments to $LINEAR_HOLD_LOG, then opens $LINEAR_HOLD_FIFO
# for reading, which blocks until the test opens the writing end, and
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
  : < "$LINEAR_HOLD_FIFO"
  : > "$LINEAR_HOLD_FIFO.spent"
fi
exec "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../linear-fixture/linear.sh" "$@"
