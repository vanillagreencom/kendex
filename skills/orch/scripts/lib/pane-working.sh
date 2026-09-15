# shellcheck shell=bash
#
# The one answer to "is this pane's harness running a turn right now", shared
# by every script that has to tell a working lane from a parked one.
#
# Sourced, never run.

# A turn in flight: the interrupt hint (both harnesses), the hint shown while
# a foreground shell runs, or the streaming token counter of the status line.
# Measured off running sessions of both harnesses.
#
# Deliberately NOT a spinner glyph. Claude Code animates one frame set
# (`· ✢ * ✶ ✻ ✽`) across every long-running screen, its OAuth sign-in
# included, so a spinner reads a lane parked at a login prompt as working;
# `·` is also its separator character and `*` is in its startup banner. `✻`
# additionally spells the idle end-of-turn line (`✻ Churned for 6s · done`),
# so it survives the turn that drew it exactly as `●` does. The token counter
# and the interrupt hint are drawn only while a turn is actually running.
#
# The counter appears a second or two INTO a turn, after streaming starts, so
# a turn caught in its first moments reads as not working. Callers that poll
# see it on a later pass; callers that must not act on a false negative say so
# where they read it.
#
# One more, measured off live Claude Code lanes. `Jump to bottom` ends the
# frame of a pane scrolled up: the live turn is drawn below what is visible,
# so nothing on that screen can classify the lane, and an unclassifiable frame
# must never come back idle.
WORKING_RE='to interrupt|to run in background|↓ [0-9][0-9.]*[kKmM]? tokens|Jump to bottom'

# pane_working SCREEN — the predicate over one captured pane.
pane_working() { grep -Eq -- "$WORKING_RE" <<<"$1"; }
