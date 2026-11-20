# Job units

Read when starting, naming, finding or stopping an orch job. One launcher, agent-runtime's `effects/job.rs`, starts every detached job and writes its record. `orch-runtime launch-job` starts a caller's command through it, and `orch-runtime stop-job --record [PATH]` stops what a record names.

## Runner choice

The launcher runs a job as a transient systemd user unit where the user manager answers and lingers. Otherwise the job runs as a `setsid` child, and the launcher records its pid and kernel start before the launch returns. `effects/job.rs` `probe_manager` holds the checks that choose `setsid`, and sets each unit's properties.

A unit holds every process the job starts. Under `setsid` or `attached` nothing bounds the job: a process that starts its own session escapes its group, and no memory bound holds.

## Unit name

A unit is `orch-NAME-STAMP.service` (`unit_name`). `NAME` is the job as its caller names it, a waiter's `launch-job --name` among them; `STAMP` is the last `:` field of the launch's key. Two launches of one name never share a unit.

## Runner line

Each launch's record file holds `key=value` lines: `runner=`, `unit=` or `pid=` and `start=`, and `line=`, the runner line. `launch-job` replies with the line in its JSON answer, and the job's log opens with it ([waiter-launch.md § Run files](waiter-launch.md#run-files)). A validation run's record is `runner` in its run directory; the fleet watch's is `oversee-watch.runner`.

A `start-unconfirmed` runner line means the job's `systemd-run` failed after the manager may have acted. Hold the job as that unit until its claim or a reconcile reads it. `--collect` unloads an ended unit, so a `not-found` is never a reason to launch again.

`orch-runtime launch-job --help` states its exit codes, and [waiter-launch.md § Launch](waiter-launch.md#launch) step 3 routes them.

## Stopping

Stop a job by the record its launch wrote, never by a name pattern, which can match another repository's units for the same item.

```bash
.agents/skills/orch/scripts/orch-runtime stop-job --record [RUN].runner
```

`orch-runtime stop-job --help` states its reply.

## Agent warden

The host's agent warden is a systemd user timer that keeps agent work inside `agents.slice`. Consult that host's warden installation for its source and configuration. It leaves in place a unit that matches `AGENT_WARDEN_JOB_UNITS`.

A job unit started in the manager's default slice is outside `agents.slice`. A warden with no job-unit exemption moves the whole job into a scope, and can later stop that scope as an orphan; the run then reads as lost. A unit started in the launching lane's slice is inside `agents.slice`, and the warden stops only scopes, never a service.

For a run lost with no host or low-memory kill on record, read `journalctl --user -u agent-warden` at the time the run ended. A reaped job's scope shows as a line that opens `reaped orphan scope agent-warden-PID-START.scope: stopped N process(es)`.
