# Flightdeck — development notes

This file is for agents and humans hacking on flightdeck itself. End users should read [`README.md`](./README.md) instead.

## TypeScript port status

The scripts under `scripts/` ship as bash trampolines that exec the TypeScript port in `lib/flightdeck-core/` by default. Each trampoline checks `FLIGHTDECK_USE_TS_<SCRIPT>` first, then the global `FLIGHTDECK_USE_TS`. Both default to `1`. Set either to `0` to route back to the `.bash` sibling.

- **Default is TS.** `bun` is a hard runtime dependency; the trampoline execs `bun .../src/bin/<script>.ts` unless the operator opts out.
- **The `.bash` siblings remain in place** as the opt-out target for at least one full production cycle on TS defaults.
- **`flightdeck-daemon start` still defaults to the bash sibling.** The TS run-loop + subscriber lifecycle is fully ported and parity-tested, but the `start` sub-action keeps a separate gate (`FLIGHTDECK_USE_TS_DAEMON_START=1` or `FLIGHTDECK_USE_TS=1`) until one full production cycle. Other daemon CLI actions (`status`, `events`, `ack`, `health`, `stop`, `find-window`) run through TS by default.
- **Parity tests** under `lib/flightdeck-core/tests/parity/` are the baseline. Live wake (`tests/live-wake.sh`) under the same gate is the production gate before flipping a default.

## Session model and schema boundary

Flightdeck core is the generic tmux-session manager. It owns `TrackedEntry` lifecycle, owner metadata, daemon wake routing, generic prompt handling, and stable pane/window ids for any harness session. Issue orchestration is a domain layer on top: it adds GitHub/Linear/worktree metadata under `domain.issue`, legacy issue states, PR conflict graphs, merge queues, and next-cycle recommendations.

Master-state schema `1.1` is the compatibility bridge toward the v2 entries model. `flightdeck-state init` keeps v1 `.issues`, `.merge_queue`, and `.conflict_graph`, adds `schema_version: 1.1`, `owner`, and additive `.entries`, and projects `kind="issue"` writes back into `.issues` so older issue workflows continue to run. Future schema v2 makes `.entries` canonical and moves issue-only data under `domain.issue`, but readers must keep v1 projection until the compatibility window closes.

Use the TrackedEntry seam everywhere new code reads tracked sessions. Core helpers (`readTrackedEntries`, `writeTrackedEntry`, `entryIdForIssue`, `issueIdForEntry`) live under `lib/flightdeck-core/src/state/`; `pane-registry list --format json` and `flightdeck-state tracked-entries` expose the same normalized view to scripts. `pi-flightdeck` mirrors the seam with read-only `TrackedSession` / `TrackedState` render types, prefers schema-1.1 `.entries`, folds legacy `.issues`, and uses `owner.pane_id` for default owner-scoped rendering. Do not add fresh direct `.issues` reads outside compatibility code.

## Tests

### Bun parity suite

Unit + parity tests for every ported script. Each parity test runs both the bash and TS implementations against the same input and asserts equivalent output / on-disk state.

```bash
cd skills/flightdeck/lib/flightdeck-core
bun test
bun run typecheck
```

Parity green is necessary but not sufficient before flipping any `FLIGHTDECK_USE_TS*` default — the live wake suite must also pass under the same gate.

### Live wake

Exercises the full daemon wake path against a real Pi master. Useful after daemon or `pane-poll` changes. Takes ~2 minutes; requires tmux and a real `pi` binary.

```bash
tests/live-wake.sh
tests/live-wake.sh --no-tmux    # quick shape-check for CI
```

See `tests/README.md` for setup and cleanup.

## Debugging

The session state file lives at `tmp/flightdeck-state-<TMUX_SESSION_NAME>.json`:

```bash
.agents/skills/flightdeck/scripts/flightdeck-state get '.' | jq
```

If flightdeck seems stuck on a prompt, the usual cause is a novel prompt shape the classifier doesn't recognize. The skill escalates these as `generic-multi-choice` for human review. Add a sentinel to `prompt-classify` if it's worth automating.

## Operational caveats

- **Worst-case wake latency on master crash**: `FD_WAKE_PENDING_TTL + FD_POLL_SEC` (default 302s). If master crashes between turn-start and ack-clear, the daemon waits one TTL before reverting in-flight state and re-firing.
- **State directory privacy**: `FD_STATE_DIR` (default `$XDG_RUNTIME_DIR/flightdeck`, fallback `/tmp/flightdeck-$UID`) must be user-owned and mode `0700`.
- **PID reuse race**: stranded `.draining.<pid>` files and stale `BUSY_FILE` recovery can be delayed if the kernel reuses a PID before the next startup GC. Acceptable in practice — startup GC sweeps within seconds of next daemon start.

## TS-default caveats

These tradeoffs apply on the default TS path:

- **Batch polling is timeout-bounded but still sequential.** Adapter reads honor `FD_ADAPTER_READ_TIMEOUT_SEC` so no single pane can wedge the tick, but panes are still polled one after the other. Full async parallelism arrives in a later iteration.
- **Daemon PID changes across `FD_MAX_LIFETIME` boundaries** (only when the TS daemon `start` is opted in via `FLIGHTDECK_USE_TS_DAEMON_START=1`). The TS daemon spawns a detached successor on max-lifetime rollover instead of `exec`-replacing itself in place. PID_FILE is updated by the successor; external watchers must re-read PID_FILE each call rather than caching the initial PID. The successor is invoked with the internal `--from-handoff` flag so it preserves the predecessor's wake-pending / events / wake-events.log instead of running the fresh-start wipe. The bash daemon preserves PID across the rollover. Master and pi-flightdeck dashboard contracts are unaffected (master uses `BUSY_FILE.pid` which is the master's own PID, not the daemon's; the dashboard re-reads PID_FILE each tick).
- **Session-lock hot path uses in-process `flock(2)`** via `bun:ffi` for per-tick session-lock decisions, avoiding a per-call `flock(1)` fork. Falls back to spawning `flock(1)` on runtimes where `bun:ffi` can't dlopen libc.
- **Subscribers carry a parent-watchdog.** Each subscriber polls the daemon's PID every 5s and exits cleanly when the daemon dies, so a crashed daemon doesn't orphan tail/jq processes.

## Adapter read divergence (TS vs bash)

`FD_ADAPTER_READ_TIMEOUT_SEC` caps each adapter read subprocess (`curl`/`pi-bridge`/`codex-bridge`/`gh`) in the TS `pane-poll`. Fractional seconds are honored.

When an adapter read times out or returns an empty body, the TS path clears the per-harness `*_used` flag and falls through to `tmux capture-pane` on the same tick. **This is a deliberate divergence from the bash sibling**, which marks the adapter as used as soon as fresh args exist and leaves the buffer empty when `curl` times out — a wedged opencode/pi/codex adapter classifies as idle in bash until the freshness probe expires; in TS the same tick recovers via tmux. The bash siblings (`FLIGHTDECK_USE_TS_PANE_POLL=0`) do not honor this knob.

## Scripts

Detailed list of what each script does, for debugging or porting work:

| Script | What it does |
| --- | --- |
| `open-terminal` | Launches a new tmux window with the chosen harness running on the chosen issue worktree. |
| `flightdeck-state` | Reads/writes the session's master state file, including schema `1.1` tracked-entry normalization (`tracked-entries`, `write-entry`). |
| `flightdeck-daemon` | Background poller. Wakes the master when an agent needs attention. |
| `pane-registry` | Tracks which tracked entry (issue or adhoc session) lives in which tmux pane and how to talk to its agent. |
| `pane-poll` | Reads an agent's current state (via native channel where possible). |
| `pane-respond` | Sends a reply or option pick into an agent. |
| `prompt-classify` | Pattern-matches an agent's last output against known prompt shapes. |
| `pr-conflict-graph` | Builds a file-overlap graph between PRs so flightdeck can pick a safe merge order. |
| `parallel-groups` | Reads parallel-execution groups for the current planning cycle. |
| `codex-app-server-spawn` / `-stop` | Brings up / tears down the shared Codex bridge server for codex-mode sessions. |
| `pane-clear-bell` | Clears the tmux bell flag without screen flicker after answering. |
