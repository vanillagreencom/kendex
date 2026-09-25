# Job units

Load when starting, naming, finding or stopping an orch job through `scripts/lib/job-unit.sh`: run it with `--help` for its subcommands, or source it for the same functions. `dev-validate-run` is its first caller. These launches use their own mechanism, not this one: every job launched through [waiter-launch.md](waiter-launch.md), `lane_run_detached` in `scripts/lib/lane-launch.sh`, and the preparing-job stop in `lane-close` and `open-terminal`.

The runner bounds a job's lifetime and nothing else; it sets no memory, CPU or task limit and no slice. Under a unit, the job and everything it forks end when the job ends or reaches its bound. Under `setsid` see [Runner line](#runner-line) for what escapes.

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
| `TimeoutStopSec` | `JOB_UNIT_KILL_GRACE`: the seconds between SIGTERM and SIGKILL for what the unit still holds when it stops. A `setsid` job's `end` gives its group the same grace, and `dev-validate-run`'s own bound gives its command the same. |
| `LimitNOFILE` | The launching process's own soft and hard open-file limits (`unlimited` as `infinity`) |
| Environment | Every variable the launching process exports |

## Runner line

The launch prints the runner line and records it; `dev-validate-run` writes it as the first line of its log.

| Line | Meaning |
|---|---|
| `runner=systemd unit=UNIT` | The job is the unit `UNIT` |
| `runner=setsid reason=no-systemd-run` | No `systemd-run` is installed |
| `runner=setsid reason=probe-failed detail=TEXT` | `systemd-run` could not start the probe unit; `TEXT` is its first line of stderr |
| `runner=setsid reason=unit-launch-failed detail=TEXT` | The probe unit started, the job's `systemd-run` failed, and the manager has no unit of that name. A failed call for a unit the manager does have leaves the job as that unit; a manager that does not answer fails the launch. |

A unit holds every process the job starts, and systemd kills what remains when the job's main process exits or reaches `RuntimeMaxSec`. Under `setsid` nothing bounds the job: it leads its own process group and calls `job-unit.sh end` when it finishes, which sends that group SIGTERM, waits up to the kill grace for it to empty, then sends SIGKILL. A job killed before `end`, and a process that starts its own session, escape it.

## Stopping

A job unit is stopped by the exact name its launch recorded, never by a pattern: two repositories' lanes for one item share every prefix, so a glob stops the other repository's units. A unit the manager reports `not-found` has already ended. A manager that cannot be reached is a failure, never a unit found stopped. A `setsid` job is stopped by its process group, only while its pid still runs the argv its caller expects.
