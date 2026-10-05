# D012: A lane's parked and walled time is kept on its fleet record as pauses

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: KEN-1955

**Decision**: The lane record carries `pauses`, one `{from, to, cause}` per stretch the lane could not work, kept by every later launch, relaunch or wake. The writer of each entry is the step that sees the stretch end: `open-terminal` writes a `parked` entry as it drops `parked` at the relaunch, and `oversee-watch` writes a `walled` entry at the pass that sees the usage banner gone. `oversee-cycle` merges overlapping pauses and takes that time out of whichever wait it falls in.

**Why**: A wall waited out in the lane's own window has no relaunch, so a relaunch stamp alone misses it and the time reads as thread-fix time. The watch already stamps a wall's first sighting and notices its end, and one field with a cause gives the cycle one list to merge.

**Rejected**: A stop stamp closed at the relaunch: it sees only walls recovered on another account. Wall intervals read from the fleet log: the log holds rulings in prose and no wall row.

**Revisit when**: Lanes gain harness usage-limit rows that date a wall from the harness rather than from a watch pass.
