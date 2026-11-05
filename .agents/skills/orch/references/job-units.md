# Job units

Load when starting, naming, finding or stopping an orch job through `scripts/lib/job-unit.sh`: run it with `--help` for its subcommands, or source it for the same functions. Its callers are `dev-validate-run`'s run, every job [waiter-launch.md](waiter-launch.md) launches (`approval-wait`, `copilot-wait`, `queue-wait`, `lane-mail wait` and each `verify-pr` call), the fleet watch (the runtime's `start-controller` launches it for an overseer `oversee launch` opened; a registered session starts it with the block in [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance)), and the `oversee-watch` entry's relaunch of itself out of a retired repeat loop's pass (`oversee-watch --help`). These launches use their own mechanism, not this one: `lane_run_detached` in `scripts/lib/lane-launch.sh`, which `open-terminal` uses for a terminal emulator and a woken lane turn, and the preparing-job stop in `lane-close` and `open-terminal`.

`job-unit.sh attach RECORD -- ARGV` is the one start that is not detached: it runs the job as the caller's own child, leading a process group of its own in the caller's session, and waits for it. The child forks through the github skill's group-leader prefix, `scripts/lib/group-leader.sh`, so an install without the github skill beside orch refuses the start as `group-leader-missing`, exit 2, and starts nothing. That prefix runs perl, so a host without perl refuses the start as `missing-command commands=perl`, exit 2, and starts nothing. `dev-validate-run --attached` starts its run this way. A host whose agent warden kills detached jobs needs it: the job stays inside the calling agent's process tree, where a unit or a `setsid` job does not.

The runner bounds a job's lifetime, its memory when asked, and under a unit the tasks and memory the launching process's own cgroup caps; it sets no CPU limit. The unit starts in the launching process's user-manager slice where one exists, as the `Slice` row in [Unit properties](#unit-properties) says and [Agent warden](#agent-warden) explains, and there takes that process's task cap and memory soft cap. A launch with `--memory-max MIB` sets `MemoryMax=MIBM` on the unit in place of that memory soft cap; no process group holds a memory bound, so a launch that would run under `setsid` refuses it as `memory-max-unheld`, exit 5, with its runner line, and starts nothing. A launch without it sets no `MemoryMax`. Under a unit, the job and everything it forks end when the job ends or reaches its bound. Under `setsid` see [Runner line](#runner-line) for what escapes.

## Unit name

A job runs as the transient systemd user unit `orch-NAME-PID.service` where a user manager answers and lingers. A manager that does not linger stops when the user's last login session ends, an SSH disconnect included, and stops every unit in it, while tmux and the lanes in that session run on. Every launch, capped or not, runs under `setsid` where `loginctl` reports no linger or cannot read it. A capped launch, `dev-validate-run`'s, keeps its unit and `RuntimeMaxSec` where the manager lingers. On a non-lingering host validation gives up the unit's cleanup: a descendant that starts its own session can outlive the run, as with uncapped jobs there. The validation child's own bound and verdict record still apply under `setsid`.

| Component | Meaning | Example |
|---|---|---|
| `orch` | The runner that owns the unit | `orch` |
| `NAME` | The job, as its caller names it; `dev-validate-run` names `validate-` and the worktree directory's name, which is a lane's item in lower case; a waiter launch names the run path's last word and `[RUN_ID]`; the fleet watch's launch names `watch-` and the launch's UTC time in the compact form [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) defines as `[STAMP]`, the runtime's `start-controller`, the registered session's block and the entry's relaunch alike | `validate-ken-1784`, `watch-20260301T120000Z` |
| `PID` | The launching process's own pid, so two runs of one job are two units | `180993` |

Every character outside `A-Za-z0-9_.-` in the name becomes `_`. Example: `orch-validate-ken-1784-180993.service`. `job-unit.sh name NAME PID` prints a name.

## Unit properties

| Property | Value |
|---|---|
| `RuntimeMaxSec` | The launch's `--cap`, from the timeout the caller already has, set above that bound plus the kill grace so the job's own bound ends it first. `dev-validate-run` passes `DEV_VALIDATE_TIMEOUT_SECS` + kill grace + one poll interval. A launch with no `--cap` sets none: a waiter ends on its own budget, and the repeat watch runs for the overseer session until it is stopped or taken over. |
| `TimeoutStopSec` | `JOB_UNIT_KILL_GRACE`: the seconds between SIGTERM and SIGKILL for what the unit still holds when it stops. A `setsid` job's `end` gives its group the same grace, and `dev-validate-run`'s own bound gives its command the same. |
| `MemoryMax` | The launch's `--memory-max` in MiB; none without it |
| `IgnoreSIGPIPE` | `no`, so the job takes SIGPIPE at its default, as a process the caller starts does; a service ignores it otherwise |
| `LimitNOFILE` | The launching process's own soft and hard open-file limits (`unlimited` as `infinity`) |
| Environment | Every variable the launching process exports, `TMUX`, `TMUX_PANE` and a lane's account variable among them; the runtime's own launch leaves out a variable whose value is not UTF-8 text or holds a Unicode noncharacter |
| `WorkingDirectory` | The launching process's own directory |
| `Slice` | The innermost slice in the launching process's cgroup v2 path under this user's manager (`job-unit.sh`'s `job_unit_slice`): `agents.slice` for a lane the warden's launcher placed, or one the warden moved. None, so the manager's default slice, where the launching process runs outside the user manager (a login session scope) or has no cgroup v2 path (macOS). |
| `TasksMax` | The launching process's own cgroup `pids.max`, where the unit takes a `Slice` and that file holds a number. None, so the manager's `DefaultTasksMax`, otherwise. |
| `MemoryHigh` | The launching process's own cgroup `memory.high`, under the same conditions, and only for a launch with no `--memory-max` |

## Runner line

The launch prints the runner line and records it. `dev-validate-run` and a waiter launch write it as the first line of the job's log; the fleet watch's launch records it in `oversee-watch.runner` beside the fleet state, which the runtime reads for the record's `overseer.watch` and a registered session's block leaves on its stdout as well, and the `oversee-watch` entry's relaunch carries it in the `unit=` field of its `watch-relaunched` line.

| Line | Meaning |
|---|---|
| `runner=systemd unit=UNIT` | The job is the unit `UNIT` |
| `runner=setsid reason=no-systemd-run` | No `systemd-run` is installed |
| `runner=setsid reason=no-linger` | `loginctl` reports that the user manager does not linger |
| `runner=setsid reason=linger-unread detail=TEXT` | `loginctl` could not report whether it lingers; `TEXT` is its first line of output. Unread is no linger. |
| `runner=setsid reason=probe-failed detail=TEXT` | `systemd-run` could not start the probe unit; `TEXT` is its first line of stderr |
| `runner=setsid reason=unit-launch-failed detail=TEXT` | The probe unit started, the job's `systemd-run` failed, and the launch fell back to `setsid`: for `job-unit.sh`, a failure answered while the manager has no unit of that name; for the runtime's own launch, a `systemd-run` that could not be run at all. A failed call for a unit the manager does have leaves the job as that unit. A manager that cannot be asked about the unit leaves the launch possibly started under the unit's name: `job-unit.sh` exits 6, `launch-unconfirmed`. |
| `runner=systemd unit=UNIT start-unconfirmed detail=TEXT` | The runtime's own launch: the job's `systemd-run` ran and failed (an exit, a signal or its bound) and the manager reads the unit in no ended state, `not-found` included. The job is held as the unit until its claim or a reconcile reads the unit. `systemd-run`'s exit status does not tell a refusal the manager answered from a bus error or a client timeout after the manager acted, and `--collect` unloads a unit once it ends, so a `not-found` is never a reason to launch again under `setsid`. |
| `runner=attached` | The job ran through `attach`, as the caller's own child |

A unit holds every process the job starts, and systemd kills what remains when the job's main process exits or reaches `RuntimeMaxSec`. Under `setsid` or `attach` nothing bounds the job: it leads its own process group and calls `job-unit.sh end` when it finishes, which tears that group down as § Stopping says. A job killed before `end`, and a process that starts its own session, escape it.

## Stopping

A job unit is stopped by the exact name its launch recorded, never by a pattern: two repositories' lanes for one item share every prefix, so a glob stops the other repository's units. A unit the manager reports `not-found` has already ended. A manager that cannot be reached is a failure, never a unit found stopped. A `setsid` or attached job is stopped by its process group, only while its pid still runs the argv its caller expects. Every such teardown, `end` and `stop-job` alike, sends the group SIGTERM, waits up to the kill grace (`JOB_UNIT_KILL_GRACE`) for its members to exit, and sends SIGKILL only if one still runs, as a unit's stop does over `TimeoutStopSec`.

## Agent warden

The agent warden is a systemd user timer that [vsys](https://github.com/vanillagreencom/vsys) ships (`warden/agent-warden`). It keeps agent work inside `agents.slice`:

- It moves a process that runs outside `agents.slice` and carries `AGENT_CONFINE=1` in its environment, with its build and shell descendants, into a scope of its own, `agent-warden-PID-START.scope`. On a host with the warden, every lane pane starts through its launcher, which sets that variable, and a job unit receives it with the rest of the launching process's environment.
- It stops an `agents.slice` scope as an orphan when every process in it has lost its launcher and the scope stays heavy past a grace period. The thresholds are in the warden source.
- It leaves in place a unit that matches `AGENT_WARDEN_JOB_UNITS` (default `orch-*.service`), and treats a process already inside `agents.slice` as confined, never as escaped.

A job unit started in the manager's default slice is outside `agents.slice`. A warden with no job-unit exemption moves the whole job into a scope and can later stop that scope as an orphan, and the run then reads as lost. A unit started in the launching lane's slice is inside `agents.slice` whatever `AGENT_WARDEN_JOB_UNITS` says, and the reaper stops only scopes, never a service. The unit also shares that slice's task and memory pool with every lane, so it takes the launching scope's own `TasksMax` and `MemoryHigh` (§ Unit properties): a job whose process count or memory runs away is held to what its lane may use, not the whole slice.

A run lost with no host or low-memory kill on record: read `journalctl --user -u agent-warden` at the time the run ended. A reaped job's scope shows as a line that opens `reaped orphan scope agent-warden-PID-START.scope: stopped N process(es)`.
