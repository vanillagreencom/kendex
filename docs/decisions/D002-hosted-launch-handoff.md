# D002: A hosted launch hands its wait to a background job after the host accepts the item

[← Decision Index](INDEX.md)

**Date**: 2026-09-24

**Status**: Active

**Research**: —

**Applies to**: `skills/orch/scripts/open-terminal`, `skills/orch/scripts/oversee-watch`, `skills/orch/schemas/lane-host.md`

**Context**: A hosted `open-terminal` launch blocked its caller, the overseer's own session, for the whole provider `create`, about five minutes per lane, because the protocol defined `create` as synchronous.

**Decision**: `create` may return once it has accepted the item, printing `state=preparing`, and the new `wait` verb reports the preparation's outcome. Under a fleet state the launcher opens the window and its lane claim, records the lane `preparing`, and hands `wait` and the rest of the launch to a background job. The job records `running` or `stopped` with a reason, and `oversee-watch` reports `lane-ready`, `lane-prepare-failed` or `lane-prepare-stuck` from that record.

**Rationale**:

- Backgrounding a synchronous `create` was rejected. The launcher would record the lane before the provider had judged ownership, so an item another session owns (`create` exit 75) would have its live record overwritten.
- The window and claim open before the hand-off, so the next item in a batch picks its account knowing this one is in flight.
- A provider that keeps the synchronous `create` prints no `state` and needs no `wait`, so no existing provider breaks.
- The job leaves the caller's process group for the reason `run_detached` in `open-terminal` and `references/waiter-launch.md` detach their children: a harness kills the group of the command it ran. `run_detached` execs a command, and the job runs the launcher's own functions, so job control gives it a group of its own. The record carries that group's id, and `lane-close` stops it when it closes a `preparing` lane.
- A hosted codex relaunch waits in the foreground. It resumes with no continuation line, and the `resume-lineless` notice must reach the caller rather than a job log.

**Revisit When**: a provider cannot claim ownership before preparing, or the launcher must return before `create` answers at all.

**Verification**: `skills/orch/tests/open-terminal-record.sh` § a host still preparing the item hands the launch to a background job; `skills/orch/tests/oversee_watch_prepare.sh`.

**References**: KEN-1644, KEN-1553
