# Flightdeck rich activity events plan

Originally drafted 2026-05-14. Updated 2026-05-15 to reflect the Rust dashboard ship (`flightdeck-dashboard-rust` branch) — see [Baseline](#baseline) below.

## Baseline

This plan executes against the post-purge codebase. Load-bearing facts:

- **`.entries` is the canonical tracked-session map.** Issue-mode metadata lives under `entry.domain.issue` (`pr_number`, `worktree`, `merge_commit`, `scope_files_*`, `orchestration_started`). Producers read these from `entry.domain.issue.<field>`, never top-level.
- **TypeScript is canonical for the daemon and state plane.** `flightdeck-daemon start` is TS-only; subscriber bodies live in `skills/flightdeck/scripts/lib/subscribers.bash` but are sourced by the TS daemon — no parallel implementations.
- **`pane-registry log-decision` writes only to `.entries[ENTRY_ID].decisions_log`.** The activity plan's per-entry decision logging hook is a single append-call at the existing log-decision site.
- **`pane-registry remove <id>` and `teardown-entry` accept the full lifecycle vocabulary** (`complete | cancelled` alongside `merged | aborted | dead`). Phase 2 emits the matching `entry.completed | entry.cancelled | entry.dead` activity events at both mutation points.
- **`pane-respond` accepts `%pane_id` stable ids.** Activity producers can reference `pane_id` directly without resolving to `pane_target`.
- **`master-state.ts::archiveState` is the canonical archive flow.** Activity archival in Phase 1 hooks into the same call site so a `*.json.archive` and its matching `*.jsonl.archive` always land together.
- **`FLIGHTDECK_MANAGED` is a tri-state signal** (`skills/orchestration/scripts/flightdeck-mode`). Phase 5 GitHub/Linear wrapper instrumentation gates on `FLIGHTDECK_MANAGED=1` or `FLIGHTDECK_SESSION_ID`.
- **Daemon emits a canonical `daemon-exited` event** to `EVENTS_FILE` with `reason ∈ {master-gone, signal-term, signal-int, other}`. Phase 3 maps it to `daemon.stopped` with severity derived from `reason` (`master-gone | signal-term` → `warning`, `signal-int` → `info`, `other` → `error`). The `start --master` exit code `4` (stale master) maps to `daemon.warning` with `details.exit_code = 4`.
- **Pi subscriber drain semantics** (initial drain + `bridge_hello` re-drain + `seen_qids` dedupe) mean Pi `question.opened` activity events MUST dedupe by `requestId`, not by drain attempt.
- **`pi-extensions/pi-background-tasks/extensions/wake-events.ts` already defines wake metadata fields** (`eventAt`, monotonic `sequence`, `notifyMode ∈ {always, transition, first-match-only}`, `dedupeKey`, `pendingWakes`, `voidedWakes` / `voidedWakeSequences`, `cleared-on-task-exit` diagnostics). Activity `id` composes with these — see [Activity event schema](#activity-event-schema).
- **`pi-extensions/pi-agents-tmux/extensions/subagent/` is split** into `index.ts` (wiring), `runner.ts` (spawn/process supervision; compact-then-empty `agent_end` detector — vstack#38), `dispatch.ts` (single/parallel/chain), `sessions.ts` (lane minting), `wait.ts` (`wait_for_subagent_idle` with `waitFor: idle | completion`). Activity producers attach in `runner.ts` / `dispatch.ts`. `wait_for_subagent_idle` is the canonical pane-idle observation point — never infer from transcript text.
- **Rust dashboard shipped** (`skills/flightdeck/lib/flightdeck-dashboard/`, branch `flightdeck-dashboard-rust` as of 2026-05-15). The plan's Phase 6 ("Activity UI") is now Rust-dashboard-primary; pi-flightdeck remains as a deprecated secondary reader. The dashboard already defines an `EventSource` trait at `src/events/mod.rs` designed for exactly this swap — Phase 6 ships a `JsonlActivitySource` impl, not a restructure. See [Phase 6](#phase-6--activity-ui-rust-dashboard-primary).
- **Worktree convention**: scratch (engineer task briefs, intermediate result JSONs, parity-test fixtures) goes in `<worktree>/tmp/`, never at worktree root or `/tmp/`. `WORKTREE_MKDIRS` auto-creates `tmp/`.

## Goal

Make Flightdeck's Live feed useful as a user-facing activity stream, not a raw daemon-log tail. It should answer: what changed, which managed session changed, whether user attention is needed, and where to inspect the full details.

Target examples:

- session/entry started, attached, resumed, completed, cancelled, dead
- agent pane spawned, task queued, task started, task completed, task failed/blocked/needs completion
- background task started, output matched, task finished, task failed/timed out/stopped
- structured question asked, answered, rejected
- Flightdeck decision recorded
- PR opened/updated/commented, CI/checks started/passed/failed, PR merged/auto-merge queued/merge blocked
- Linear issue created/updated/linked/finished/cancelled
- daemon/subscriber warnings and errors

This plan keeps Decisions as a focused decision/audit view while making Live feed (likely renamed Activity) the chronological, filtered stream that can include decision events.

## Current-state audit

### pi-flightdeck surfaces

Relevant files:

- `pi-extensions/pi-flightdeck/extensions/flightdeck.ts`
- `pi-extensions/pi-flightdeck/extensions/state.ts`
- `pi-extensions/pi-flightdeck/extensions/agents-bridge.ts`
- `pi-extensions/pi-flightdeck/README.md`

Current popup tabs:

- Overview renders normalized tracked sessions from `readTrackedEntries(snapshot.master)`.
- Live feed currently aggregates four ad-hoc sources:
  - daemon log tail: `snapshot.daemon.logTail`
  - per-entry decision logs: `flatDecisionsLog(snapshot.master, max)`
  - durable pending wake events: `snapshot.pendingEvents`
  - recent adapter wake stream: `snapshot.wakeEvents`
- Live feed now labels rows with tracked session names/ids and defaults to an important-only filter, with `ctrl+n` toggling noisy rows.
- Conversations is built in-memory from `wakeEvents` rows with `last_assistant_text`; Pi streaming partials are folded.
- Decisions reads only `decisions_log` from tracked entries and provides detail popups.
- Daemon tab is intentionally closer to raw log output, with heartbeat folding.

Limitations:

- Live feed is still string-parsing daemon logs and wake-event JSON rather than rendering a stable activity schema.
- Event identity/dedup is best-effort per source. There is no durable activity id.
- Rich lifecycle events are not persisted in one place.
- Decisions are duplicated into Live feed but not modeled as a formal subtype of activity.
- Conversations are not archived beyond the in-memory popup cache.
- Full-stream inspection exists only as detail popups; there is no export/open-in-editor path.

### Flightdeck master state and registry

Relevant files:

- `skills/flightdeck/lib/flightdeck-core/src/state/types.ts`
- `skills/flightdeck/lib/flightdeck-core/src/state/master-state.ts`
- `skills/flightdeck/lib/flightdeck-core/src/bin/flightdeck-state.ts`
- `skills/flightdeck/lib/flightdeck-core/src/bin/pane-registry.ts`

Current model (post-purge):

- `.entries` is the single tracked-session map. Issue-mode metadata lives under `entry.domain.issue`.
- `flightdeck-state tracked-entries` and `pane-registry list --format json` are the canonical read seam.
- `pane-registry init-entry` creates a tracked entry with `kind`, `title`, pane metadata, adapter metadata, and `decisions_log: []`.
- `pane-registry log-decision` appends to `.entries[ENTRY_ID].decisions_log`.

Limitations:

- There is no top-level or per-session `activity_log`.
- `decisions_log` is the only durable audit stream, and it only captures prompt/answer decisions.
- State changes (`set-state`, `set-substate`, `teardown-entry`, `reconcile` drift) do not emit structured activity records.
- Writing large event history into the master JSON would bloat the file and complicate locking; JSONL sidecar is better.

### Flightdeck daemon and subscribers

Relevant files:

- `skills/flightdeck/lib/flightdeck-core/src/daemon/events.ts`
- `skills/flightdeck/lib/flightdeck-core/src/daemon/loop.ts`
- `skills/flightdeck/lib/flightdeck-core/src/daemon/wake.ts`
- `skills/flightdeck/lib/flightdeck-core/src/daemon/subscribers/spawn.ts`
- `skills/flightdeck/scripts/lib/subscribers.bash` (subscriber bodies sourced from the TS daemon)
- `skills/flightdeck/lib/flightdeck-core/src/events/bg-task-exit.ts`
- `skills/flightdeck/scripts/lib/daemon-bg-task-events.sh` (Pi subscriber's bg-task helper)

Current model:

- Subscribers write raw JSONL into `fd-wake-events-<session>.log` for adapter-originated events.
- Daemon drains that log, classifies canonical wake tags, appends durable wake rows to `fd-daemon-events-<session>.jsonl`, and wakes the master.
- Canonical tags include questions, subagent completion failures, `pi-bg-task-exit`, domain mismatch, issue prompt tags, and terminal signals.
- `appendEvent` dedupes by `pane_id|hash|tag` and writes wake-specific records with optional `details`.
- `flightdeck-daemon` log is line-oriented text with tags such as `[start]`, `[heartbeat]`, `[classify]`, `[wake]`, `[subscriber-dead]`.

Limitations:

- Wake events are not the same thing as user-visible activity. Some activity should not wake the master; some wake records are implementation details.
- The daemon log is useful for debugging but too raw for Live feed.
- Pi subscriber currently reads many `pi-session-bridge` events but only forwards a small set:
  - questions opened
  - subagent completions only when failed/blocked/needs completion
  - background-task exit
  - assistant message completion text
- Background-task starts and successful subagent completions are not surfaced to Flightdeck unless inferred from raw transcript/logs.

### pi-session-bridge

Relevant file:

- `pi-extensions/pi-session-bridge/extensions/session-bridge.ts`

Current model:

- Publishes structured stream events for Pi sessions:
  - `bridge_start`, `bridge_stop`, `input`
  - `agent_start`, `agent_end`, `turn_start`, `turn_end`
  - `message_start`, `message_update`, `message_end`
  - `tool_execution_start`, `tool_execution_end`, `tool_execution_error`
  - model/thinking changes, session tree
  - question-service events
- Provides `questions`, `answer`, `reject`, `history`, and `stream` commands.

Opportunity:

- This is the best transport for observing inner Pi sessions. Do not parse terminal text when a bridge event exists.
- Add or document a small `vstack_activity` bridge event channel so other Pi extensions can publish curated activity without creating user-visible chat messages.

### pi-background-tasks

Relevant files (post-PR #24 + PR #34):

- `pi-extensions/pi-background-tasks/extensions/types.ts`
- `pi-extensions/pi-background-tasks/extensions/wake-events.ts` — wake metadata: `eventAt`, per-task monotonic `sequence`, `notifyMode` (`always | transition | first-match-only`), `dedupeKey`, `pendingWakes`, `voidedWakes` / `voidedWakeSequences`. `clearTaskTimers` records `cleared-on-task-exit` diagnostics for dropped output wakes.
- `pi-extensions/pi-background-tasks/extensions/lifecycle.ts` — finalize + replay-missed-exits on `session_start`; durable `exitNotified` flag.
- `pi-extensions/pi-background-tasks/extensions/persistence.ts` — atomic snapshot persistence + sidecar.
- `pi-extensions/pi-background-tasks/extensions/orphan-watcher.ts` — PID-reuse-safe orphan detection via pid + startToken; comm is diagnostic only.
- `pi-extensions/pi-background-tasks/extensions/registrations.ts`

Current model:

- Tasks persist snapshots with status, command, cwd, PID, log file, notify config, output bytes, exit code, and wake diagnostics.
- `sendTaskWake` emits a `vstack-background-tasks:event` custom message for output/exit wakeups.
- Flightdeck consumes only the exit branch via the Pi subscriber and routes it as `pi-bg-task-exit`.
- Every wake (exit + output) already carries `eventAt`, `sequence`, `taskStatusAtEmit`, and `deliveredAt` on emit. The activity stream should reuse these fields directly instead of inventing parallel ones.

Limitations:

- Spawn/start events are visible to the local UI/tool result but not as bridge-visible curated activity for Flightdeck.
- Output-match events are wake-capable, but Flightdeck currently ignores them unless they become user-visible in assistant output.
- Exit events wake the master; richer activity should record all terminal states but only wake when configured or failed.
- Orphan-running task transitions (`pid-gone` / `pid-reused`) are local diagnostics and not surfaced as Flightdeck activity yet.

### pi-agents-tmux

Relevant files (post-PR #35 split):

- `pi-extensions/pi-agents-tmux/extensions/subagent/index.ts` — wiring/tool registration.
- `pi-extensions/pi-agents-tmux/extensions/subagent/runner.ts` — launch/spawn/process supervision; context-overflow retry. (vstack#38 adds a sibling "compact-then-empty `agent_end`" detector here.)
- `pi-extensions/pi-agents-tmux/extensions/subagent/dispatch.ts` — single/parallel/chain orchestration, inventory guard, auto-batching.
- `pi-extensions/pi-agents-tmux/extensions/subagent/sessions.ts` — one-shot lane minting + budget guard for reused `sessionKey` lanes.
- `pi-extensions/pi-agents-tmux/extensions/subagent/wait.ts` — `wait_for_subagent_idle` + `waitFor: "idle" | "completion"`.
- `pi-extensions/pi-agents-tmux/extensions/subagent/pane.ts`, `tasks.ts`, `types.ts` — pane lifecycle and task records.

Current model:

- Emits local Pi events: `subagents:queued`, `subagents:started`, `subagents:completed`, `subagents:failed`, `subagents:needs_completion`, `subagents:steered`.
- Persists task records in `tasks.json` with agent, task id, status, pane id, transcript path, summary, files changed, validation, diagnostics, and usage.
- Exposes `globalThis[Symbol.for("vstack.pi.agents")]` for per-pane stats; `pi-flightdeck` already reads this for cost/turn/token summaries.
- Child pane completion uses `complete_subagent`, then parent emits/polls completion state. Pi subscriber currently emits Flightdeck wake only for bad completions.
- `wait_for_subagent_idle` reports `idle-after-busy` only after observing the pane leave idle first; `never-busy` is returned distinctly. Activity producers should use this as the pane-idle event source, not transcript inference.

Limitations:

- Local `pi.events` are not visible to Flightdeck when the agent work happens inside a tracked inner Pi process unless session-bridge relays them or the extension publishes curated activity.
- Successful subagent completions are useful activity but should not wake the master unless policy says so.
- Context-overflow retry attempts (PR #35) are not currently surfaced as activity — a retry-once is invisible unless the second attempt also fails.
- Inventory-guard rejections (unknown agent name) currently surface as tool errors but not as Flightdeck activity, even though they are useful audit signal.

### Workflows and issue-domain actions

Relevant files:

- `skills/flightdeck/workflows/shared/session-watch.md`
- `skills/flightdeck/workflows/linear/watch.md`
- `skills/flightdeck/workflows/shared/session-handle-prompt.md`
- `skills/flightdeck/workflows/linear/handle-prompt.md`
- `skills/flightdeck/workflows/linear/merge-plan.md`
- `skills/flightdeck/workflows/linear/close-issue.md`
- `skills/flightdeck/workflows/linear/terminate.md`

Current model:

- Generic watch loop routes prompt-like events and ack/yield.
- Issue watch layer owns PR/Linear/worktree behavior.
- `session-handle-prompt.md` handles structured questions, generic multi-choice, terminal signals, and bg-task exit.
- `handle-prompt.md` handles issue-only decisions such as CI/bot review, rebase, force push, audit relations, merge prompts, fix suggestions, and descoping.
- `merge-plan.md` computes conflict graph and merge ordering.
- `close-issue.md` marks issue merged/aborted and tears down pane.
- `terminate.md` writes summary and archives state.

Limitations:

- Many high-value events happen in markdown workflow steps and never become structured state except indirectly through `decisions_log`, `state`, `merge_queue`, or summary file.
- PR/CI/Linear events require explicit instrumentation at workflow/helper boundaries or wrappers, not UI-side inference.

## Target architecture

### Separate activity from wake routing

Do not overload `fd-daemon-events-<session>.jsonl`. Wake events answer: "should the master run?" Activity events answer: "what happened?"

Add a new Flightdeck activity stream:

- Project/master sidecar: `<FLIGHTDECK_STATE_DIR>/flightdeck-activity-<TMUX_SESSION>.jsonl`
- Archive sidecar on terminate: `<FLIGHTDECK_STATE_DIR>/flightdeck-activity-<TMUX_SESSION>-<terminated_at>.jsonl.archive`. Archive must be produced by the same `flightdeck-state archive` flow already used for terminated session state (PR #23) so a `*.json.archive` and its matching `*.jsonl.archive` always land together.
- Master state fields:
  - `activity_path`
  - `activity_archive_path` after termination
  - optional `activity_schema_version`

Reasons:

- Keeps master JSON compact.
- Preserves full stream for post-completion dashboard and editor export.
- Lets daemon, workflow helpers, and Pi extensions append without read-modify-writing the master JSON.
- Allows tail reads in `pi-flightdeck` without parsing raw daemon logs.

### Activity event schema

Use additive JSONL. One line per event.

```ts
interface FlightdeckActivityEventV1 {
  schema_version: 1;
  id: string;                 // stable sha256/idempotency key
  ts: string;                 // ISO8601
  session_id?: string;         // tmux session name or stable session key when known
  source: "flightdeck" | "daemon" | "subscriber" | "pi-session" | "pi-agents" | "pi-bg-task" | "workflow" | "github" | "linear";
  entry_id?: string;
  entry_title?: string;
  entry_kind?: string;
  pane_id?: string;
  harness?: string;

  type:
    | "session.started" | "session.completed" | "session.cancelled"
    | "entry.registered" | "entry.attached" | "entry.resumed" | "entry.state_changed" | "entry.completed" | "entry.dead"
    | "daemon.started" | "daemon.stopped" | "daemon.warning" | "daemon.error" | "subscriber.started" | "subscriber.dead"
    | "question.opened" | "question.answered" | "question.rejected"
    | "decision.recorded"
    | "agent.spawned" | "agent.task_queued" | "agent.task_started" | "agent.task_completed" | "agent.task_failed" | "agent.task_blocked" | "agent.needs_completion" | "agent.steered" | "agent.empty_after_compact"
    | "bg_task.started" | "bg_task.output_matched" | "bg_task.completed" | "bg_task.failed" | "bg_task.timed_out" | "bg_task.stopped"
    | "pr.opened" | "pr.updated" | "pr.comments_left" | "pr.checks_started" | "pr.checks_passed" | "pr.checks_failed" | "pr.merge_queued" | "pr.merged" | "pr.merge_blocked"
    | "linear.issue_created" | "linear.issue_updated" | "linear.issue_finished" | "linear.issue_cancelled" | "linear.relation_created"
    | string;

  severity: "debug" | "info" | "success" | "warning" | "error";
  importance: "critical" | "important" | "normal" | "noisy";
  summary: string;            // one-line user-facing text
  body?: string;               // wrapped detail text / raw payload summary
  links?: Array<{ label: string; url?: string; path?: string }>;
  refs?: {
    task_id?: string;
    agent?: string;
    bg_task_id?: string;
    question_id?: string;
    pr_number?: number;
    issue_id?: string;
    linear_id?: string;
    commit?: string;
    check_name?: string;
  };
  details?: Record<string, unknown>; // bounded, scrubbed, not huge raw logs
  noisy?: boolean;             // derived convenience for UI
}
```

Dedup/id rule:

- Producers should pass a natural idempotency key.
- Helper computes `id = sha256([session, entry_id, type, natural_key].join("\0"))` when caller omits `id`.
- Append helper should keep a tiny recent-id cache per process where practical; UI also dedupes by `id`.
- When a producer already has a stable per-event identifier (notably `pi-background-tasks` wake-event `sequence` and `dedupeKey`, or `pi-agents-tmux` `taskId`), the natural key should include it so activity dedup matches the producer's own dedup. Activity `id` and producer `sequence` are *complementary*: the producer dedupes its own emit; activity `id` dedupes across consumers and idempotent re-reads.

Retention:

- Default full activity JSONL cap: 5000 events or 10 MB per session.
- `pi-flightdeck` tail default: 300 events.
- Details cap per event: 16 KiB unless explicitly linked to artifact file.

## Worktree setup (first action)

**Always create the activity-plan worktree via the worktree skill, not raw `git worktree add`.**

```bash
cd /mnt/Tertiary/dev/vstack/main
skills/worktree/scripts/worktree create flightdeck-rich-activity --from main
cd /mnt/Tertiary/dev/vstack/trees/flightdeck-rich-activity
ls -la tmp/                                  # WORKTREE_MKDIRS auto-created scratch dir
git status --short                           # clean
```

The worktree skill wires `.env.local`, harness mirror symlinks (`.agents`, `.pi`, `.opencode`, `.codex`, `.cursor`, `.claude/agents`), bot identity, `WORKTREE_MKDIRS` (defaults to `tmp/`), and adds proper `info/exclude` entries so `git status` is clean.

All scratch (engineer task briefs, intermediate result JSONs, parity-test fixtures) goes in `<worktree>/tmp/` — not at worktree root, not `/tmp/`.

The Rust dashboard work shipped to `flightdeck-dashboard-rust`; this plan branches off `main` once that branch merges. If `flightdeck-dashboard-rust` has not merged when this plan starts, branch off `flightdeck-dashboard-rust` directly so the dashboard's `EventSource` trait is available for the Phase 6 impl.

## Review cycles (mandatory)

Use the same review cadence proven in PRs #41 and #44:

1. **Round 1 — architecture + error review in parallel** via `subagent` parallel dispatch of `reviewer-arch` + `reviewer-error` (add `reviewer-test` / `reviewer-structure` for phases that materially change test surface or module boundaries). Each returns a structured `<output_format>` JSON with `verdict: approve | changes-requested`, `findings: [{commit, severity: blocker|major|minor, summary, suggested_fix}]`, `notes`.
2. **Apply feedback as 1–3 grouped commits.** One commit per logical fix-cluster; reference the reviewer + finding in the commit body. Run `bun test && bun run typecheck` before each commit.
3. **Round 2 (only if any reviewer returned `changes-requested`).** Re-dispatch only the flagging reviewers against the round-1 fix commits. Continue until all return `approve` (typically 1–2 rounds; escalate if a third round opens new blockers).
4. **`reviewer-doc` runs LAST.** Doc review checks SKILL.md drift, README user-facing hygiene (no engineering jargon), AGENTS.md rules compliance, pattern docs reflect new behavior. Apply as a single docs commit before opening the PR.
5. **PR body summarizes the review chain.** Round counts, blocker/major/minor counts, files changed. The PR description is the audit trail.

## Implementation plan

### Phase 1 — Core activity writer/readers

1. Add shared activity helpers in `skills/flightdeck/lib/flightdeck-core/src/activity/`:
   - `types.ts`
   - `paths.ts`
   - `append.ts`
   - `read.ts`
   - `format.ts`
2. Add `flightdeck-state activity` subcommands in TS (`src/bin/flightdeck-state.ts` action dispatch):
   - `activity path [--session <name>]`
   - `activity append <json-event>`
   - `activity tail [--limit N] [--json]`
   - `activity export [--format jsonl|markdown] [--filter <expr>]`
4. `flightdeck-state init` writes `activity_path` if absent.
5. `terminate.md` / terminate helpers archive the activity file alongside the master state archive.
6. Tests:
   - JSON schema normalization
   - id generation/dedup
   - lock-held append under concurrent writers
   - CLI surface (`activity path|append|tail|export`)

Validation:

```bash
cd skills/flightdeck/lib/flightdeck-core
bun test
bun run typecheck
```

### Phase 2 — Instrument existing Flightdeck state transitions

Emit activity from existing mutation points first. This gives immediate value without waiting for every external integration.

Add events in `pane-registry` TS (no bash siblings post-purge):

- `init-entry` -> `entry.registered`
- `set-state` -> `entry.state_changed`
- `set-substate` -> `entry.state_changed` with substate
- `log-decision` -> `decision.recorded`
- `teardown-entry` / `remove` -> `entry.completed` / `entry.dead` / `entry.cancelled` depending on the terminal state passed in (accepts `complete | cancelled | merged | aborted | dead`)
- `reconcile` drift/drop/backfill -> `daemon.warning` or `entry.dead`

Decision logging is already canonical (`.entries[ENTRY_ID].decisions_log` after the legacy purge). Just mirror every `log-decision` call as `decision.recorded` in activity.

Tests:

- generic entry gets `.entries[ENTRY].decisions_log`
- activity records emitted exactly once
- existing callers remain compatible

### Phase 3 — Instrument daemon and subscriber lifecycle

Add activity append path to `flightdeck-daemon start` options/env and pass it to subscriber loops.

Emit curated daemon activity:

- daemon start/stop/max-lifetime successor
- subscriber spawn/reattach/dead/restart
- master gone/session gone
- wake delivery failure
- domain mismatch
- warnings/errors

Do not emit heartbeat to activity by default. If retained, mark `importance="noisy"` and hide by default.

Subscriber activity mapping:

- question opened -> `question.opened`
- assistant completion text -> do not emit by default; Conversations already handles this
- subagent completion:
  - completed -> `agent.task_completed`, no wake
  - failed/blocked/needs_completion -> `agent.task_failed|blocked|needs_completion`, wake as today
- background task exit -> terminal bg-task event by status, wake as today when configured
- output match -> `bg_task.output_matched` if `notifyOnOutput` event arrives; wake/steer semantics remain owned by pi-background-tasks

Tests:

- activity append does not change wake behavior
- bad subagent completion still wakes
- successful subagent completion appears in activity but does not wake
- bg-task failed event is red/error and wakes when notify policy says so

### Phase 4 — Pi extension bridge for richer local events

Goal: avoid parsing chat/tool text when Pi extensions already know the structured event.

Add a small cross-extension activity broker for each Pi runtime:

- Symbol: `Symbol.for("vstack.pi.activity")`
- Methods:
  - `publish(event)`
  - `subscribe(listener)`
  - `recent(limit)`
- `pi-session-bridge` publishes broker events on `stream` as `event="vstack_activity"`.

Wire producers:

- `pi-background-tasks` publishes:
  - `bg_task.started`
  - `bg_task.output_matched`
  - `bg_task.completed|failed|timed_out|stopped`
- `pi-agents-tmux` publishes:
  - `agent.spawned`
  - `agent.task_queued`
  - `agent.task_started`
  - `agent.task_completed|failed|blocked|needs_completion`
  - `agent.steered`
  - `agent.empty_after_compact` (vstack#38 — synthetic, sourced from `pi-agents-tmux` event `subagents:needs_completion { reason: "compact-then-empty", cwdSnapshot: { head, dirty, lastCommit: { subject, ... } } }`; preserve those fields under `details`; surfaced as `severity: warning`, `importance: important`)
- `pi-questions` / question-service path publishes:
  - `question.opened`
  - `question.answered`
  - `question.rejected`

Flightdeck Pi subscriber then consumes `vstack_activity` from `pi-bridge stream`, maps it to Flightdeck activity schema, and appends to the session activity JSONL. Existing custom-message paths stay as compatibility fallback until one release after broker adoption.

Reachability check before coding:

- Confirm `pi.events` cannot already subscribe to arbitrary extension events through `pi-session-bridge` without new broker.
- Confirm `display:false` custom messages are either available or not needed.
- Confirm broker events do not create user-visible chat noise.

### Phase 5 — Instrument issue-domain workflow events

Add explicit activity emission in Flightdeck workflows and helper scripts where user-visible outcomes happen.

Gate every wrapper emission on `FLIGHTDECK_MANAGED=1` (PR #21) or an explicit `FLIGHTDECK_ACTIVITY_FILE` env. Standalone use of the `github`/`linear` skills outside Flightdeck must remain silent.

Workflow instrumentation points:

- `start.md`
  - `session.started`
  - `entry.registered` / launch decisions
  - research issue creation / bundle decomposition choices
- `session-watch.md`
  - cycle start/end optional noisy events
  - prompt routed
  - domain mismatch
- `handle-prompt.md`
  - force-push approved/blocked
  - rebase guidance sent
  - bot-review/CI continuation decisions
  - audit relation choices
  - descope/scope-creep events
- `merge-plan.md`
  - conflict graph computed
  - merge queue reordered
  - PR merge directed
  - auto-merge queued
  - merge blocked
- `close-issue.md`
  - terminal verification signals
  - PR merged/aborted
  - pane teardown result
- `terminate.md`
  - session completed
  - summary written
  - follow-up issue recommendations

For GitHub/Linear events, prefer wrappers over freeform markdown:

- Add or update helper commands in the `github` and `linear` skill wrappers only where Flightdeck invokes them.
- Emit activity when a wrapper performs a write or observes a terminal external state:
  - PR opened, comments left, checks failed/passed, PR merged
  - Linear issue created, updated, relation created, finished, cancelled
- Gate emission on `FLIGHTDECK_ACTIVITY_FILE` or `FLIGHTDECK_SESSION_ID` so normal standalone use of those skills does not write Flightdeck activity.

### Phase 6 — Activity UI (Rust dashboard primary)

The Rust dashboard at `skills/flightdeck/lib/flightdeck-dashboard/` is the primary read site. Its `src/events/mod.rs` defines an `EventSource` trait designed for this plug-in:

```rust
pub trait EventSource: Send + 'static {
    fn subscribe(&self) -> mpsc::UnboundedReceiver<Event>;
}
```

Existing impls: `DaemonTextLogSource` (text daemon log tail), `JsonlEventSource` (generic JSONL — already used for `fd-wake-events-<key>.log`), `CompositeSource` (fan-in).

**Ship `JsonlActivitySource` as a new impl** in `src/events/jsonl_activity.rs`. Wire it into the dashboard's default source composition order:

1. New `flightdeck-activity-<session>.jsonl` sidecar — primary.
2. Activity archive (`flightdeck-activity-<session>-*.jsonl.archive`) for completed sessions — newest-first iteration mirroring the existing `*.json.archive` fallback path.
3. Existing `JsonlEventSource(fd-wake-events-<key>.log)` + `DaemonTextLogSource(fd-daemon-<key>.log)` — kept as compatibility fallback until activity-emission is universal across producers.

No restructure required — Phase 3 of the rust-tui-plan was explicitly designed for this swap. The activity-events plan should land as a struct addition + one composition-line change.

The Live feed tab is renamed to Activity once the activity sidecar is the primary source. Until activity emission is wired across producers (Phases 1–5), the tab stays labelled Live feed to avoid overpromising. The dashboard's `src/app/labels.rs` (UX v3) gets the rename.

**pi-flightdeck (deprecated secondary)** continues to render activity for users who haven't switched to the Rust dashboard. Insert a thin reader through `state-archive.ts` (archive discovery) and `state-normalizers.ts` (shape normalization); add `activity.ts` next to `render-terminated.ts` / `session-ui.ts`. Do not grow `flightdeck.ts` past its existing baseline — wire from there but render in a focused module. The pi-flightdeck path is best-effort; new feature work goes into the Rust dashboard.

Data source order (both readers):

1. New `flightdeck-activity-<session>.jsonl` sidecar.
2. Activity archive (`flightdeck-activity-<session>-*.jsonl.archive`) for completed sessions, picked up by the same newest-first iteration the dashboard uses for `*.json.archive`.
3. Legacy fallback synthesis from daemon log + decisions + pending/wake events for older sessions.

Default table columns:

| Time | Session | Type | Status | Summary |
| --- | --- | --- | --- | --- |

Rendering rules — the dashboard already has all the substrate from UX v3 + the theme system; the Activity tab is a thin renderer on top:

- Session label first; no raw pane ids in normal rows.
- Type chips: `agent`, `bg`, `question`, `decision`, `pr`, `linear`, `daemon`, `session`. Render via the existing chip helpers in `src/app/view/`; use `Theme::palette().info` / `accent` / `secondary` for type-chip backgrounds (cycle by type).
- Severity colors read from the palette — NEVER hardcode `Color::Green` / `Color::Yellow` etc. Use `palette.success`, `palette.warning`, `palette.error`. For error rows, also add a `Modifier::BOLD` `ERR` token in the Status column for accessibility (already a pattern in the dashboard).
- Important-only default:
  - show critical/important/normal
  - hide noisy/debug unless toggled
- Plain-language event type labels live in `src/app/labels.rs` (e.g. `pr.checks_failed` → "PR checks failed", `agent.task_completed` → "Agent task completed"). Match the existing `state_label` / `kind_label` pattern; do NOT invent a parallel labels module.
- `enter` opens the detail popup. Use the existing `src/app/view/popup.rs` framework that UX v3 shipped — do not roll a new chrome. Activity detail popup gets title ("<type> · <session id>"), subtitle (severity + timestamp), body (summary + wrapped detail + links/refs), footer ("Esc close · ↑/↓ scroll").
- Mouse: each row is a click target via the HitMap registry from UX v3. Push `ClickAction::SelectRow(i)` on single-click, `ClickAction::OpenDetail` on double-click. Backdrop click on the detail popup closes per existing pattern.
- Search matches session, type, summary, refs, body.
- Filter controls extend the existing `/` filter popup and `Ctrl+N` noise toggle from UX v3:
  - `Ctrl+N` cycles noise mode (already present) — keep existing two-state toggle (hide noisy / show all)
  - `f` opens a filter-menu popup for type/severity (new popup, use the existing popup framework)
  - `s` opens a session-filter popup
  - `d` toggles decisions-only overlay or jumps to Decisions tab
- Popup keyboard contract (from UX v3 P1-G): any popup the Activity tab opens MUST capture all keys; arrow/vim keys do not leak to the base layer. Reuse the existing `handle_popup_key` dispatch.

Decisions interplay:

- Keep Decisions tab as a dedicated view for `decision.recorded` events; fall back to reading `.entries[].decisions_log` directly when the activity sidecar is missing (older archives).
- Use the same row/detail component as Activity.
- Activity includes decision rows by default because decisions are important chronological context.
- Decisions tab answers "why did Flightdeck choose this?" Activity answers "what happened when?"

Editor/export:

- Add `e` in Activity and Decisions detail/list views:
  - writes current filtered stream to `tmp/flightdeck-activity-view-<SESSION>-<ts>.md`
  - if `$VISUAL`/`$EDITOR` is set and running inside tmux, open in a new tmux window named `fd-activity` or print the command/path if automatic open is unsafe
  - also support CLI: `flightdeck-state activity export --format markdown --filter ...`
- Export includes full JSON refs/details collapsed under each event.
- Tracked-entry filter and event-type filter persist via env vars (`FLIGHTDECK_ACTIVITY_FILTER_TYPES`, `FLIGHTDECK_ACTIVITY_FILTER_SESSIONS`) so users can pin a preferred view across launches.

### Phase 7 — Documentation and migration

Docs to update with implementation:

- `skills/flightdeck/SKILL.md`
- `skills/flightdeck/README.md`
- `skills/flightdeck/DEVELOPMENT.md`
- `skills/flightdeck/lib/flightdeck-dashboard/` README and `DEVELOPMENT.md` — document the `JsonlActivitySource` impl, the Activity tab rename, and the activity sidecar paths
- `skills/orchestration/DEVELOPMENT.md` (if Phase 5 GitHub/Linear wrappers add activity emission)
- `pi-extensions/pi-flightdeck/README.md` — keep deprecation banner; document Activity tab presence in pi-flightdeck's render with a pointer at the Rust dashboard
- `pi-extensions/pi-background-tasks/README.md` + `DEVELOPMENT.md` if broker events added
- `pi-extensions/pi-agents-tmux/README.md` + `DEVELOPMENT.md` if broker events added
- `pi-extensions/pi-session-bridge/README.md` if `vstack_activity` stream event added

Migration:

- Pre-purge sessions (state files with `.issues` but no `.entries`) are auto-archived by `flightdeck-session start` and by the pi-flightdeck reader's explicit error path. Activity does not need a legacy synth.
- Keep `decisions_log` as the durable audit source; activity mirrors it for filtering convenience, it does not replace it.
- Keep wake-event routing unchanged until tests prove activity append cannot interfere.

## UX proposal

Rename tab from `Live feed` to `Activity` once the structured event source lands. Until then, keep `Live feed` label to avoid overpromising.

Default Activity view:

```text
filter: important · all sessions · 18 noisy hidden

Time      Session           Type        Status   Summary
14:14:08  CC-503            session     ok       session started (pi)
14:14:08  CC-503            daemon      ok       subscriber started
15:10:45  CC-503            question    wait     pi-question opened: Restore market data regression history?
22:12:58  CC-503            decision    ok       selected: Tighten read_symbol_limit_from_env visibility
23:17:31  CC-503            decision    ok       selected: Create related follow-up issue
23:25:04  CC-503            bg          ERR      ci-wait failed exit=1
23:28:19  CC-503            pr          ok       PR #812 checks passed
23:31:02  CC-503            pr          ok       PR #812 merged abc1234
```

Footer:

```text
tab next · ↑/↓ select · enter details · f filters · s sessions · ctrl+n all/noisy · e editor · esc close
```

Detail view should show:

- session/title/kind
- event type/severity/time
- summary/body
- refs and links
- raw JSON details behind a collapsed/expanded section if TUI supports it; otherwise at bottom

## Event importance defaults

| Type | Severity | Importance | Wake? |
| --- | --- | --- | --- |
| `daemon.started` | info | noisy | no |
| `daemon.warning` | warning | important | maybe no |
| `daemon.error` | error | important | maybe yes if daemon cannot continue |
| `subscriber.started` | info | noisy | no |
| `subscriber.dead` | warning | important | yes if no fallback |
| `question.opened` | warning | important | yes |
| `question.answered` | success | normal | no |
| `decision.recorded` | info/success | important | no |
| `agent.task_completed` | success | normal | no |
| `agent.task_failed` | error | important | yes |
| `agent.needs_completion` | warning | important | yes |
| `agent.empty_after_compact` | warning | important | yes |
| `bg_task.started` | info | normal | no |
| `bg_task.completed` | success | normal | no unless notifyOnExit |
| `bg_task.failed` | error | important | yes if notifyOnExit |
| `pr.checks_failed` | error | important | yes if blocking |
| `pr.merged` | success | important | no |
| `linear.issue_created` | success | normal | no |
| `session.completed` | success | critical | no |

## Validation plan

Core (TS):

```bash
cd skills/flightdeck/lib/flightdeck-core
bun test
bun run typecheck
```

Rust dashboard (after Phase 6 activity source lands):

```bash
cd skills/flightdeck/lib/flightdeck-dashboard
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
cargo insta test
```

Pi extension package checks after UI/broker changes:

```bash
cd pi-extensions/pi-flightdeck
npx tsc --noEmit --target ES2022 --module NodeNext --moduleResolution NodeNext --types node --skipLibCheck extensions/*.ts
npm pack --dry-run

cd ../pi-background-tasks
npx tsc --noEmit --target ES2022 --module NodeNext --moduleResolution NodeNext --types node --skipLibCheck extensions/*.ts
npm pack --dry-run

cd ../pi-agents-tmux
npx tsc --noEmit --target ES2022 --module NodeNext --moduleResolution NodeNext --types node --skipLibCheck extensions/subagent/*.ts
npm pack --dry-run

cd ../pi-session-bridge
npx tsc --noEmit --target ES2022 --module NodeNext --moduleResolution NodeNext --types node --skipLibCheck extensions/*.ts
npm pack --dry-run
```

End-to-end smoke:

1. Start Flightdeck with two tracked Pi sessions.
2. Spawn one successful and one failing background task inside a tracked session.
3. Ask and answer a Pi structured question.
4. Run a pane subagent that completes successfully and one that reports blocked/failed.
5. Trigger a mocked PR/check event through helper fixtures.
6. Verify Activity:
   - shows session labels for every row
   - hides noisy daemon/subscriber rows by default
   - shows red `ERR`/error styling for failures
   - detail popup wraps and scrolls
   - editor export contains the same filtered rows with full refs/details
7. Verify Decisions tab still shows existing decision history from earlier sessions.
8. Terminate Flightdeck and reopen popup; activity archive still renders.

## Risks and guardrails

- Activity must not create extra wakes by itself. Wake routing remains explicit.
- Activity must not become raw transcript storage. Store summaries and bounded details; link to logs/transcripts for large payloads.
- Multi-process append must use the same flock discipline as state updates.
- Do not inspect or edit harness mirror directories (`.agents/`, `.claude/`, `.opencode/`, `.pi/`, `.codex/`).

## Proposed delivery order

1. Core activity sidecar + `flightdeck-state activity` CLI.
2. Registry/state transition instrumentation (`pane-registry init-entry / set-state / set-substate / log-decision / teardown-entry`).
3. Rust dashboard `JsonlActivitySource` impl + Activity tab rename. pi-flightdeck secondary reader follows in the same phase (lower priority).
4. Daemon/subscriber curated events (daemon lifecycle, subscriber lifecycle, classified wake mappings).
5. Pi activity broker through session-bridge; then background-task / agent / question producers publish to it.
6. Issue-domain workflow instrumentation for PR / CI / Linear lifecycle.
7. Editor/export shortcut and docs polish.

This order makes the UI useful early, keeps wake behavior stable, and gives every later producer one canonical append path.
