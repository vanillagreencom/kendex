# Job units

Load when starting, naming, finding or stopping a long-lived orch job. `scripts/lib/job-unit.sh` starts and stops every one; run it with `--help` for its subcommands, or source it for the same functions. `dev-validate-run` is its first caller.

## Unit name

A job runs as the transient systemd user unit `orch-CLASS-NAME-PID.service` where a user manager answers.

| Component | Meaning | Example |
|---|---|---|
| `orch` | The runner that owns the unit | `orch` |
| `CLASS` | A row of the bounds table | `validate` |
| `NAME` | The job; for `dev-validate-run`, the worktree directory's name, which is a lane's item in lower case | `ken-1784` |
| `PID` | The launching process's own pid, so two runs of one job are two units | `180993` |

Every character outside `A-Za-z0-9_.-` in the name becomes `_`. Example: `orch-validate-ken-1784-180993.service`. `job-unit.sh name CLASS NAME PID` prints a name.

## Bounds table

`JOB_UNIT_TABLE` in `job-unit.sh` holds one row per class, and `job-unit.sh check` prints each as `class=CLASS tasks-max=N runtime-max-sec=VALUE kill-grace-sec=N`.

| Field | Meaning |
|---|---|
| `tasks-max` | The unit's `TasksMax`: processes and threads together |
| `runtime-max-sec` | The unit's `RuntimeMaxSec`. `caller` is the launch's `--cap`, which the caller sets above its own bound plus the kill grace, so a job at its bound ends by that bound first. `dev-validate-run` passes `DEV_VALIDATE_TIMEOUT_SECS` + kill grace + one poll interval, a setting no constant stays above. |
| `kill-grace-sec` | `JOB_UNIT_KILL_GRACE`: the unit's `TimeoutStopSec`, and the grace `dev-validate-run`'s own bound gives |

Every unit also gets the launching process's soft and hard open-file limits as `LimitNOFILE` (`unlimited` as `infinity`) and every variable it exports. No memory cap is set.

## Runner line

The launch prints the runner line and records it; `dev-validate-run` writes it as the first line of its log.

| Line | Meaning |
|---|---|
| `runner=systemd unit=NAME` | The job is the unit `NAME` |
| `runner=setsid reason=no-systemd-run` | No `systemd-run` is installed |
| `runner=setsid reason=probe-failed detail=TEXT` | `systemd-run` could not start the probe unit; `TEXT` is its first line of stderr |
| `runner=setsid reason=unit-launch-failed detail=TEXT` | The probe unit started and the job's unit did not |

A unit holds every process the job starts, and systemd kills what remains when the job's main process exits. Under `setsid` the job leads its own process group and calls `job-unit.sh end` before it exits, which kills that group; a process that starts its own session escapes it.

## Stopping

A job unit is stopped by the exact name its launch recorded, never by a pattern: two repositories' lanes for one item share every prefix, so a glob stops the other repository's units. A unit the manager reports `not-found` has already ended. A manager that cannot be reached is a failure, never a unit found stopped. A `setsid` job is stopped by its process group, only while its pid still runs the argv its caller expects.
