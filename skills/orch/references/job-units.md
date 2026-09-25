# Job units

Load when starting, naming, finding or stopping a long-lived orch job. `scripts/lib/job-unit.sh` starts and stops every one; run it with `--help` for its subcommands, or source it for the same functions. `dev-validate-run` is its first caller.

The runner bounds a job's lifetime and nothing else: a job and everything it forks end when the job ends or reaches its bound. It sets no memory, CPU or task limit and no slice.

## Unit name

A job runs as the transient systemd user unit `orch-NAME-PID.service` where a user manager answers.

| Component | Meaning | Example |
|---|---|---|
| `orch` | The runner that owns the unit | `orch` |
| `NAME` | The job, as its caller names it; `dev-validate-run` names `validate-` and the worktree directory's name, which is a lane's item in lower case | `validate-ken-1784` |
| `PID` | The launching process's own pid, so two runs of one job are two units | `180993` |

Every character outside `A-Za-z0-9_.-` in the name becomes `_`. Example: `orch-validate-ken-1784-180993.service`. `job-unit.sh name NAME PID` prints a name.

## Unit properties

| Property | Value |
|---|---|
| `RuntimeMaxSec` | The launch's `--cap`, from the timeout the caller already has, set above that bound plus the kill grace so the job's own bound ends it first. `dev-validate-run` passes `DEV_VALIDATE_TIMEOUT_SECS` + kill grace + one poll interval. |
| `TimeoutStopSec` | `JOB_UNIT_KILL_GRACE`, the grace `dev-validate-run`'s own bound also gives |
| `LimitNOFILE` | The launching process's own soft and hard open-file limits (`unlimited` as `infinity`) |
| Environment | Every variable the launching process exports |

## Runner line

The launch prints the runner line and records it; `dev-validate-run` writes it as the first line of its log.

| Line | Meaning |
|---|---|
| `runner=systemd unit=UNIT` | The job is the unit `UNIT` |
| `runner=setsid reason=no-systemd-run` | No `systemd-run` is installed |
| `runner=setsid reason=probe-failed detail=TEXT` | `systemd-run` could not start the probe unit; `TEXT` is its first line of stderr |
| `runner=setsid reason=unit-launch-failed detail=TEXT` | The probe unit started and the job's unit did not |

A unit holds every process the job starts, and systemd kills what remains when the job's main process exits. Under `setsid` the job leads its own process group and calls `job-unit.sh end` before it exits, which kills that group; a process that starts its own session escapes it.

## Stopping

A job unit is stopped by the exact name its launch recorded, never by a pattern: two repositories' lanes for one item share every prefix, so a glob stops the other repository's units. A unit the manager reports `not-found` has already ended. A manager that cannot be reached is a failure, never a unit found stopped. A `setsid` job is stopped by its process group, only while its pid still runs the argv its caller expects.
