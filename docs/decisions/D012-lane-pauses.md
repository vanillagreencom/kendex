# D012: A lane's parked and walled time is kept on its fleet record as `pauses`, written where each stretch ends

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: —

**Applies to**: `skills/orch/scripts/oversee-cycle`, `skills/orch/scripts/open-terminal`, `skills/orch/scripts/oversee-watch`

## Context

KEN-1955 splits the gate_green phase of `oversee-cycle record` into the waits it holds: a bot reviewing a push, the lane working the review threads, and the lane parked or walled. The first two come from `pr-timeline`: its bot-review times, and push times it reads from the head branch's activity log, since GitHub records no plain push on the pull request and a rebase rewrites every committer date. The third has no source. The lane record keeps `parked` only until the relaunch drops it, and nothing records a usage wall. A wall the overseer waits out in the lane's own window, the recovery `oversee-events.md` gives when no other account qualifies, writes nothing anywhere. The watch's usage-limit row holds when it first saw the banner, and it clears that row when the banner goes.

## Decision

1. The lane record carries `pauses`, `{from, to, cause}` per stretch the lane could not work, kept by every later launch, relaunch or wake.
2. The writer of each entry is the step that sees the stretch end. `open-terminal` writes a `parked` entry from the park's `at` as it drops `parked` at the relaunch. `oversee-watch` writes a `walled` entry from its usage-limit row's first sighting at the pass that sees the banner gone, replaced or its window gone.
3. `oversee-cycle` reads `pauses` and a `parked` still standing, merges overlaps, and takes that time out of whichever wait it falls in.

## Rationale

- A wall waited out in the window has no relaunch, so a relaunch stamp alone misses the walls the issue names. Those two lanes would read as thread-fix time.
- The watch already stamps a wall's first sighting and already notices its end, so the end write needs no new detection.
- One field with a cause, not a separate field per writer, gives `oversee-cycle` one list to merge. A wall and a stop that overlap count once.

## Alternatives Considered

- A stop stamp in `lane-close --keep-sandbox` closed at the relaunch: rejected. It sees only the walls recovered on another account, and the watch entry already covers the banner until the window goes.
- Wall intervals read from the fleet log: rejected. The log holds rulings in prose, and the watch writes no wall row to it.

**Revisit When**: KEN-1961 or a later change gives lanes harness usage-limit rows, which would date a wall from the harness rather than from a watch pass.

**Verification**: `bash skills/orch/tests/oversee_cycle.sh`; `bash skills/orch/tests/oversee_watch_usage_limit.sh`; `bash skills/orch/tests/open-terminal-record.sh`.

**References**: KEN-1955, KEN-1599, D010
