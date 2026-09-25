# Job units

Load when starting, naming, finding or stopping an orch job through `scripts/lib/job-unit.sh`: run it with `--help` for its subcommands, or source it for the same functions. Its callers are `dev-validate-run`'s run, every job [waiter-launch.md](waiter-launch.md) launches (`approval-wait`, `ci-wait`, `queue-wait`, `lane-mail wait` and the repeat watch), and `oversee-succeed`'s watch handover helper and the watch it restarts. These launches use their own mechanism, not this one: `lane_run_detached` in `scripts/lib/lane-launch.sh`, which `open-terminal` uses for a terminal emulator and a woken lane turn, and the preparing-job stop in `lane-close` and `open-terminal`.

The runner bounds a job's lifetime and nothing else; it sets no memory, CPU or task limit and no slice. Under a unit, the job and everything it forks end when the job ends or reaches its bound. Under `setsid` see [Runner line](#runner-line) for what escapes.

## Unit name

A job runs as the transient systemd user unit `orch-NAME-PID.service` where a user manager answers and lingers (`loginctl enable-linger`). A manager that does not linger is stopped when the user's last login session ends, an SSH disconnect included, and every unit in it with it, while tmux and the lanes in that session run on; there the job runs under `setsid`.

| Component | Meaning | Example |
|---|---|---|
| `orch` | The runner that owns the unit | `orch` |
| `NAME` | The job, as its caller names it; `dev-validate-run` names `validate-` and the worktree directory's name, which is a lane's item in lower case; a waiter launch names the run path's last word and `[RUN_ID]`; `oversee-succeed` names `watch-handover-` or `watch-restart-` and the UTC second | `validate-ken-1784`, `watch-Bj3g6I` |
| `PID` | The launching process's own pid, so two runs of one job are two units | `180993` |

Every character outside `A-Za-z0-9_.-` in the name becomes `_`. Example: `orch-validate-ken-1784-180993.service`. `job-unit.sh name NAME PID` prints a name.

## Unit properties

| Property | Value |
|---|---|
| `RuntimeMaxSec` | The launch's `--cap`, from the timeout the caller already has, set above that bound plus the kill grace so the job's own bound ends it first. `dev-validate-run` passes `DEV_VALIDATE_TIMEOUT_SECS` + kill grace + one poll interval. A launch with no `--cap` sets none: a waiter ends on its own budget, and the repeat watch runs for the overseer session until it is stopped or taken over. |
| `TimeoutStopSec` | `JOB_UNIT_KILL_GRACE`: the seconds between SIGTERM and SIGKILL for what the unit still holds when it stops. A `setsid` job's `end` gives its group the same grace, and `dev-validate-run`'s own bound gives its command the same. |
| `IgnoreSIGPIPE` | `no`, so the job takes SIGPIPE at its default, as a process the caller starts does; a service ignores it otherwise |
| `LimitNOFILE` | The launching process's own soft and hard open-file limits (`unlimited` as `infinity`) |
| Environment | Every variable the launching process exports, `TMUX`, `TMUX_PANE` and a lane's account variable among them |
| `WorkingDirectory` | The launching process's own directory |

## Runner line

The launch prints the runner line and records it. `dev-validate-run` and a waiter launch write it as the first line of the job's log, and `oversee-succeed` puts it at the end of its `watch-handover` and `watch-restarted` lines.

| Line | Meaning |
|---|---|
| `runner=systemd unit=UNIT` | The job is the unit `UNIT` |
| `runner=setsid reason=no-systemd-run` | No `systemd-run` is installed |
| `runner=setsid reason=no-linger` | `loginctl` reports that the user manager does not linger |
| `runner=setsid reason=linger-unread detail=TEXT` | `loginctl` could not report whether it lingers; `TEXT` is its first line of output. Unread is no linger. |
| `runner=setsid reason=probe-failed detail=TEXT` | `systemd-run` could not start the probe unit; `TEXT` is its first line of stderr |
| `runner=setsid reason=unit-launch-failed detail=TEXT` | The probe unit started, the job's `systemd-run` failed, and the manager has no unit of that name. A failed call for a unit the manager does have leaves the job as that unit; a manager that does not answer fails the launch. |

A unit holds every process the job starts, and systemd kills what remains when the job's main process exits or reaches `RuntimeMaxSec`. Under `setsid` nothing bounds the job: it leads its own process group and calls `job-unit.sh end` when it finishes, which tears that group down as § Stopping says. A job killed before `end`, and a process that starts its own session, escape it.

## Stopping

A job unit is stopped by the exact name its launch recorded, never by a pattern: two repositories' lanes for one item share every prefix, so a glob stops the other repository's units. A unit the manager reports `not-found` has already ended. A manager that cannot be reached is a failure, never a unit found stopped. A `setsid` job is stopped by its process group, only while its pid still runs the argv its caller expects. Every `setsid` teardown, `end` and `stop-job` alike, sends the group SIGTERM, waits up to the kill grace (`JOB_UNIT_KILL_GRACE`) for its members to exit, and sends SIGKILL only if one still runs, as a unit's stop does over `TimeoutStopSec`.
