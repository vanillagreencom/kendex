# Job units

Load when starting, naming, finding or stopping a long-lived orch job. `scripts/lib/job-unit.sh` starts and stops every one, and `dev-validate-run` is its first caller.

## Unit name

A job runs as the transient systemd user unit `KIND-ID-STAMP` where a user manager answers.

| Component | Meaning | Example |
|---|---|---|
| `KIND` | The job's kind, fixed by its caller | `validate` |
| `ID` | What the job belongs to; for `dev-validate-run`, the worktree directory's name, which is a lane's item in lower case | `ken-1784` |
| `STAMP` | The job's own run, unique per start | `20260925T041553Z-180993` |

Every character outside `A-Za-z0-9_.-` in the name becomes `_`. Example: `validate-ken-1784-20260925T041553Z-180993`.

## Runner line

The caller's record and the job's first log line say how it runs.

| Line | Meaning |
|---|---|
| `runner=systemd unit=NAME` | The job is the unit `NAME` |
| `runner=setsid reason=no-systemd-run` | No `systemd-run` is installed |
| `runner=setsid reason=probe-failed detail=TEXT` | `systemd-run` could not start the probe unit; `TEXT` is its first line of stderr |
| `runner=setsid reason=unit-launch-failed detail=TEXT` | The probe unit started and the job's unit did not |

A unit holds every process the job starts, and systemd kills what remains when the job's main process exits. Under `setsid` the job leads its own process group and ends it before it exits; a process that starts its own session escapes that group.

## Unit properties

| Property | Value |
|---|---|
| `TasksMax` | `JOB_UNIT_TASKS_MAX` |
| `TimeoutStopSec` | `JOB_UNIT_KILL_GRACE`, the same grace a caller's own bound uses |
| `RuntimeMaxSec` | The cap the caller passes, above its own bound plus that grace |
| `LimitNOFILE` | The caller's soft and hard open-file limits |
| Environment | Every variable the caller exports |

No memory cap is set.

## Stopping

A job unit is stopped by the exact name its caller recorded, never by a pattern: two repositories' lanes for one item share every prefix, so a glob stops the other repository's units. A unit the manager reports `not-found` has already ended. A manager that cannot be reached is a failure, never a unit found stopped.
