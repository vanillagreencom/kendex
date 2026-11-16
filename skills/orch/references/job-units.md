# Job units

Read when starting, naming, finding or stopping an orch job. One launcher, agent-runtime's `effects/job.rs`, starts every detached job and writes its record. `orch-runtime launch-job` starts a caller's command through it, and `orch-runtime stop-job --record [PATH]` stops what a record names.

## Callers

- `orch-runtime launch-job`: every waiter [waiter-launch.md](waiter-launch.md) launches, and the Codex watchdogs and process-owned reviewers [codex-runtime.md](codex-runtime.md) starts.
- The validation run: `orch-runtime validate entry` and the round's admitted start.
- The fleet watch a controller start or transfer launches beside the controller, recorded in `oversee-watch.runner` beside the fleet state.
- A lane's wall relaunch and model recovery, and a controller's transfer or stop job.

## Runner choice

The launcher runs a job as a transient systemd user unit where the user manager answers and lingers. A manager that does not linger stops every unit when the user's last login session ends, an SSH disconnect included, while tmux and the lanes run on. Elsewhere the job runs as a `setsid` child, its pid and kernel start read and recorded before the launch returns. The launcher takes `setsid` (`effects/job.rs` `probe_manager`):

1. inside a lane's confinement wrapper (`AGENT_RUNTIME_CONFINED=1`), where a unit would run outside the wrapper;
2. with no `systemd-run` on `PATH`;
3. where `loginctl` reports no linger, or cannot report it;
4. where `systemd-run --user` cannot start a probe unit;
5. where the job's own `systemd-run` exited before it asked the manager anything.

## Unit name

A unit is `orch-NAME-STAMP.service`. Every character outside `A-Za-z0-9_.-` becomes `_` (`unit_name`).

| Component | Meaning | Example |
|---|---|---|
| `orch` | The runner that owns the unit | `orch` |
| `NAME` | The job as its caller names it: a waiter `[WORD]-[RUN_ID]` (`launch-job --name`); an admitted validation run `validate-` and the worktree directory's name, an ad-hoc one `validate`; the fleet watch `watch-` and the launch's UTC time in compact form | `wait-a1B2c3`, `validate-ken-1784`, `watch-20260301T120000Z` |
| `STAMP` | The last `:` field of the launch's key: for `launch-job` the launching process's pid, for a validation run its run directory's id, for a controller's job the last field of its intent id | `180993` |

Two launches of one name never share a unit.

## Unit properties

| Property | Value |
|---|---|
| `TimeoutStopSec` | 10: the seconds between SIGTERM and SIGKILL for what the unit still holds when it stops |
| `IgnoreSIGPIPE` | `no`, so the job takes SIGPIPE at its default, as a process the caller starts does |
| `MemoryMax`, `MemorySwapMax`, `OOMPolicy` | Set only for a validation run with a memory bound: the bound in bytes, `0`, and `continue`, so the cap holds all of the job's memory and an OOM kill leaves the unit running to record the kill as its verdict. The bound is the room the host gives the start, or `ORCH_VALIDATE_MEMORY_MAX` within it. |
| `LimitNOFILE` | The launching process's own soft and hard open-file limits (`unlimited` as `infinity`) |
| `WorkingDirectory` | The launching process's own directory |
| Environment | Every variable the launching process exports whose name is a shell name and whose value is UTF-8 text with no Unicode noncharacter, `TMUX`, `TMUX_PANE` and a lane's account variable among them. Values travel in the client's environment, never on its command line. |
| `Slice` | The innermost slice in the launching process's cgroup v2 path under this user's manager: `agents.slice` for a lane the agent warden placed. None, so the manager's default slice, where the launching process runs outside the user manager (a login session scope) or has no cgroup v2 path. |
| `TasksMax` | The launching process's own cgroup `pids.max` where it holds a number |
| `MemoryHigh` | The launching process's own cgroup `memory.high` where it holds a number, for a job with no memory bound |
| `StandardError` | `append:` the job's error file where its caller names one: `[RUN].err` for `launch-job`, `job.err` in a validation run's directory |

No property bounds the job's time: each job ends on its own budget.

## Runner line

The launcher records each launch in its record file, `key=value` lines: `runner=`, `unit=` or `pid=` and `start=`, and `line=`, the runner line. `launch-job` replies with the line in its JSON answer, and `run-job` writes it as the first line of `[RUN].log`. A validation run's record is `runner` in its run directory. The fleet watch's is `oversee-watch.runner`.

| Line | Meaning |
|---|---|
| `runner=systemd unit=UNIT` | The job is the unit `UNIT`. |
| `runner=systemd unit=UNIT memory-max=BYTES` | A validation run under its memory bound of `BYTES`. |
| `runner=systemd unit=UNIT start-unconfirmed detail=TEXT` | The job's `systemd-run` failed after the manager may have acted, and the manager reads the unit in no ended state, `not-found` included. The job is held as the unit until its claim or a reconcile reads it; `--collect` unloads an ended unit, so a `not-found` is never a reason to launch again. |
| `runner=setsid reason=REASON pid=PID start=START` | The job leads its own `setsid` group. `REASON`: `confined`, `no-systemd-run`, `no-linger`, `linger-unread detail=TEXT` (unread is no linger), `probe-failed detail=TEXT`, or `unit-launch-failed detail=TEXT` (the job's `systemd-run` sent the manager nothing). |
| `runner=attached` | A validation run started with `--foreground` (also `--attached`): it runs inside the caller's own process tree through the github skill's group-leader prefix, and refuses `group-leader-missing` where that skill is absent. |

`launch-job` exits 0 when the job started, 75 when it may have started (keep the record and start nothing again), and 1 `job-launch-failed` with the cause when nothing started.

## Under setsid

A unit holds every process the job starts, and the manager ends what remains when the job's main process exits. Under `setsid` or `attached` nothing bounds the job: it leads its own process group, a process that starts its own session escapes it, and no memory bound holds. A validation run there says so on its start line.

## Stopping

Stop a job by the record its launch wrote, never by a name pattern: two repositories' lanes for one item share every prefix, so a glob stops the other repository's units.

```bash
.agents/skills/orch/scripts/orch-runtime stop-job --record [RUN].runner
```

The reply's `stopped` is `systemd` or `setsid`, or null where the job had already ended. A unit is stopped with `systemctl --user stop`; one the manager reports ended or `not-found` has already ended, and any other failed stop refuses `stop-failed`. A `setsid` job's group is stopped only while its leader still runs under the recorded start: SIGTERM, up to 10 seconds for its members to exit, then SIGKILL for any that still run. A stop it cannot confirm refuses `stop-unconfirmed`, and a record that cannot be read refuses `stop-unreadable`.

## Agent warden

The agent warden is a systemd user timer that [vsys](https://github.com/vanillagreencom/vsys) ships (`warden/agent-warden`). It keeps agent work inside `agents.slice`:

- It moves a process that runs outside `agents.slice` and carries `AGENT_CONFINE=1` in its environment, with its build and shell descendants, into a scope of its own, `agent-warden-PID-START.scope`. On a host with the warden, every lane pane starts through its launcher, which sets that variable, and a job unit receives it with the rest of the launching process's environment.
- It stops an `agents.slice` scope as an orphan when every process in it has lost its launcher and the scope stays heavy past a grace period. The thresholds are in the warden source.
- It leaves in place a unit that matches `AGENT_WARDEN_JOB_UNITS` (default `orch-*.service`), and treats a process already inside `agents.slice` as confined.

A job unit started in the manager's default slice is outside `agents.slice`. A warden with no job-unit exemption moves the whole job into a scope and can later stop that scope as an orphan, and the run then reads as lost. A unit started in the launching lane's slice is inside `agents.slice`, and the reaper stops only scopes, never a service. That unit shares the slice's task and memory pool with every lane, so it takes the launching scope's own `TasksMax` and `MemoryHigh`: a runaway job is held to what its lane may use, not the whole slice.

For a run lost with no host or low-memory kill on record, read `journalctl --user -u agent-warden` at the time the run ended. A reaped job's scope shows as a line that opens `reaped orphan scope agent-warden-PID-START.scope: stopped N process(es)`.
