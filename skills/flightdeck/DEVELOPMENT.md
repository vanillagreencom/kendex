# Flightdeck — development notes

This file is for agents and humans hacking on flightdeck itself. End users should read [`README.md`](./README.md) instead.

## Implementation

Most scripts under `scripts/` are bash trampolines that exec the TypeScript implementation under `lib/flightdeck-core/src/bin/`. `flightdeck-dashboard` is the Rust/ratatui trampoline under `lib/flightdeck-dashboard/`: it prefers a prebuilt release binary and falls back to `cargo run --release`. `bun` is a hard runtime dependency for the TypeScript scripts. Functional + integration tests live under `lib/flightdeck-core/tests/`. The live-wake suite (`tests/live-wake.sh`) is the smoke test for the daemon `start` run-loop.

## Reliability watchdogs

Four watchdogs sit between the daemon, the canonical TS subscriber, and the `pi-agents-tmux` extension. SKILL.md and README.md describe behavior and env vars; this section is the parity contract.

| Watchdog | Canonical decision module | Activity types | Parity rule |
| --- | --- | --- | --- |
| agent-end | `pi-extensions/pi-agents-tmux/extensions/subagent/agent-end-watchdog.ts` | `agent.needs_completion` | Synthesizes a `needs_completion` outbox when `agent_end` fires without `complete_subagent` within `VSTACK_AGENT_END_WATCHDOG_GRACE_SEC`. The synthetic outbox is byte-equivalent to a legitimate outbox so parents cannot tell them apart. |
| idle-stall | `pi-extensions/pi-agents-tmux/extensions/subagent/idle-stall-watchdog.ts` | `agent.idle_stalled` | Polls bridge-idle subagent panes on `VSTACK_STALL_WATCHDOG_INTERVAL_SEC` and synthesizes a `blocked` outbox after `VSTACK_STALL_WATCHDOG_THRESHOLD_SEC`. Bridge-idle is the canonical signal; never substitute pane bell or tmux capture. |
| edit-loop | `skills/flightdeck/lib/flightdeck-core/src/daemon/edit-loop-detector.ts` | `agent.edit_loop_blocked` | Counts edit-tool failures within `VSTACK_EDIT_LOOP_WINDOW_SEC`; trips on `VSTACK_EDIT_LOOP_THRESHOLD_N`. Failure classification uses the tool-renderer's structured error path — never substring matches against assistant text. |
| rate-limit | `skills/flightdeck/lib/flightdeck-core/src/daemon/rate-limit-watchdog.ts` plus `pi-extensions/pi-agents-tmux/extensions/subagent/rate-limit-decision.ts` + `rate-limit-watchdog.ts` | `agent.rate_limit_skipped`, `agent.rate_limited`, `agent.rate_limit_retry`, `agent.rate_limit_resolved`, `agent.rate_limit_exhausted`, `daemon.warning` for decider failures | Decision module is the source of truth. The Pi subscriber routes rate-limit events through it (`flightdeck-core/src/daemon/rate-limit-watchdog.ts` for the in-daemon path; the `subagent/` siblings for the inline subagent path). Backoff ladder is `VSTACK_RATE_LIMIT_BACKOFF_LADDER`, clamped to `VSTACK_RATE_LIMIT_MAX_ATTEMPTS`. Any change to the decision module must keep both sides in lock-step. |

All four emit activity-only rows for soft signals (skipped, detection, retry). Pi subscriber rate-limit exhaustion is also activity/advisory only: `pi-rate-limit-exhausted` does not wake master or fall through to completion/blocking; later independent events or daemon polls handle that state. Watchdogs wake master only when they synthesize a terminal outbox.

## Daemon hygiene

- **Bell wake per-tag rate-limit** (`FD_BELL_WAKE_INTERVAL_SEC`, default `60`). Implemented in `src/daemon/wake-filter.ts`. Suppresses successive bell wakes for the same `(pane_id, classifier_tag)` within the window. Storms on a single tag therefore collapse to one wake; multiple distinct tags still wake independently.
- **Mid-session reconcile** (`FD_RECONCILE_INTERVAL_SEC`, default `5`). Implemented in `src/daemon/reconcile.ts` (called from `src/daemon/loop.ts`). Each tick: spawn subscribers for tracked entries whose pane is alive but missing a subscriber, reap subscribers whose pane is gone, and drop stale `.entries` rows whose pane id is no longer in `tmux list-panes`. The reap is conservative — it never removes a tracked entry while its pane is alive even if the subscriber is dead, since master may still want to receive a follow-up wake.
- **Window-name refresh** piggybacks on mid-session reconcile. The daemon calls `pane-registry refresh-window-names`, which records live `tmux display-message -p -t <pane> '#W'` output in `entry.window_name_current` without mutating the original spawn `title`. As of vstack#214 the same pass also recomputes `entry.pane_target` and `entry.window_index` from the live pane snapshot whenever the entry's `%pane_id` is alive at different tmux coords — so a window renumber (close, swap, move) heals within one reconcile tick instead of leaving every cached target pointing at whichever pane currently occupies the original slot. `entry.window` is refreshed only when its stored value is purely numeric (the form `flightdeck-session` writes — `--window <window_index>`); legacy entries that stored a window-name string keep it because tmux renumbers don't change window names. The refresh also pushes structured `warnings[]` rows whenever an entry that should have a resolvable `%pane_id` doesn't (missing `pane_id`, or a `pane_id` that isn't in the live snapshot) so daemon refresh + operator-log capture can correlate the drift. `pane-registry reconcile` runs the same refresh before its liveness pass, and `flightdeck-session start` / `attach` invoke it after `register_entry` so sibling-entry coords heal within one spawn (the daemon tick remains the durable repair). Callers that already hold a `%pane_id` (`pane-respond`, `pane-poll`) prefer a direct `tmux display-message -p -t <%pane_id>` lookup over the cached `pane_target` — `%pane_id` is the source of truth, `pane_target` is a cached view. `pane-clear-bell` takes a window-target string and does not resolve a `%pane_id` itself; the renumber safety it inherits comes from `pane-respond` deriving that window-target off its already-live target.
- **Heartbeat cgroup memory probe** (`FD_HEARTBEAT_OWNER_CGROUP`, default `1`). Implemented in `src/daemon/owner-cgroup-mem.ts`. Reads `MemoryCurrent` and `MemoryPeak` from the owner harness's cgroup when available; failures are silent so the probe never blocks a heartbeat. Set the env var to `0` to skip the probe entirely (containers / non-systemd hosts).
- **Master-gone recovery hint**. Implemented in `src/daemon/recovery-hint.ts`. On `master-gone` exit the daemon writes `fd-daemon-recovery-<SESSION_KEY>.json` under `FD_STATE_DIR` with `{reason, session_id, owner_pid, owner_pane_id, exited_at, next_steps[], state_file, events_file}`. Write failure is warn-logged and must NEVER block the master-gone exit — the file is a breadcrumb, not a barrier.

## Cross-source activity binding

The spawn path and tool wrappers cooperate to thread a stable identity through every activity row originated by a tracked pane.

- `flightdeck-session start` exports `FLIGHTDECK_ENTRY_ID=<id>` into the child environment so subsequent `github.sh` / `linear.sh` / `label-*` wrappers can attach `refs.entry_id` without further plumbing. The wrappers fall back to legacy `FLIGHTDECK_ISSUE_ID` for issue-mode panes when the entry id is not available.
- `entry.branch` is captured at spawn via `git rev-parse --abbrev-ref HEAD` against the worktree cwd. Stored on `entries[id].branch` and surfaced in the Rust dashboard right rail and the Sessions table PR/path column (`<branch> · PR #N` for non-default branches).
- Generic `adhoc` / `workflow` entries that create PRs store `entry.pr_number` and optional `entry.worktree` at top level. Linear issue-mode entries keep the canonical PR/worktree fields under `entry.domain.issue`; GitHub issue-mode entries use `entry.domain.github_issue`. Renderers and workflow refs prefer the matching issue-domain values and fall back to the generic top-level fields.
- `refs.branch` is enriched on `pr.*` activity rows by querying `gh pr view --json headRefName` in `workflow-emit.ts`. Failures degrade silently — the row still emits without `refs.branch`.
- Child Pi sessions advertise a unique `<parent>:c<pid>` session id (see `pi-extensions/pi-session-bridge/extensions/child-session-id.ts`) by exporting `PI_BRIDGE_PARENT_SESSION_ID` and `PI_BRIDGE_CHILD_ROLE` into the child environment before spawn. Activity rows from the child therefore disambiguate from the parent in dashboards and post-mortems.

## bg-task lifecycle accounting

`BackgroundTaskSnapshot.terminationReason` is the canonical post-mortem hint for any terminated bg-task. The enum is defined in `pi-extensions/pi-background-tasks/extensions/types.ts`:

- `self-exit` — child exited under its own steam.
- `extension-stop` — `bg_task action: "stop"`.
- `session-shutdown` — Pi session unloaded.
- `timeout` — `timeoutSeconds` elapsed.
- `external` — unexpected exit (OOM, external SIGKILL, etc.).
- `reconcile-on-restart` — task finalized at session restore because the recorded pid was gone or recycled.
- `orphaned-pid-gone` / `orphaned-pid-reused` — the orphan-watcher polled a previously-restored alive task and found the pid gone or recycled (kernel start-time mismatch).

The reason flows through `lifecycle.ts` into the snapshot consumed by `bg_status list`, the dashboard widget, and wake payloads. Wake suppression honors `notifyOnExit: false` and `notifyMode: "first-match-only"` against the same enum; suppressed wakes carry a `WakeDropReason` so post-mortems can tell genuine drops from races.

## tool_batch hardening

`pi-extensions/pi-tool-renderer/extensions/tool-renderer/batch.ts` exposes the `batchCallTimeoutMs` setting (default `120000`). Each inner tool call inside a `tool_batch` is wrapped in a per-call timeout; on timeout the inner result reports `tool_batch inner call <tool> timed out after <ms>ms` instead of hanging the outer batch. Set the value in extension settings to tune for long-running inner tools.

## Session model and schema boundary

Flightdeck core is the generic tmux-session manager. It owns `TrackedEntry` lifecycle, owner metadata, daemon wake routing, generic prompt handling, and stable pane/window ids for any harness session. Issue/plan orchestration is a domain layer on top: Linear adds GitHub/Linear/worktree metadata under `entry.domain.issue`; GitHub issue mode adds numeric GitHub issue metadata under `entry.domain.github_issue`; plan-file mode adds per-item metadata under `entry.domain.plan_item`. These domains are mutually exclusive. PR-owning lanes use lifecycle states (`merge-ready` / `merged` / `aborted`), while Linear alone owns PR conflict graphs, merge queues, and next-cycle Linear recommendations.

`flightdeck-state init` writes `entries`, `merge_queue`, `conflict_graph`, and `owner`. All readers go through `readTrackedEntries(state)` for the canonical `TrackedEntry` view; `writeTrackedEntry` validates `entry.id`, optional `entry.domain.issue.id`, optional `entry.domain.github_issue`, rejects unknown `entry.domain.*` sub-keys, and stores the entry under `entries[id]`. Pi owner discovery first checks explicit env, then `pi-bridge list --pid <owner-pid>`, then falls back to a cwd match; `flightdeck-state init` often runs under a helper process, so code must not treat helper PID mismatch as `Master unknown` while cwd metadata is available.

Use the TrackedEntry seam everywhere new code reads tracked sessions. Core helpers (`readTrackedEntries`, `writeTrackedEntry`, `entryIdForIssue`, `issueIdForEntry`) live under `lib/flightdeck-core/src/state/`; `pane-registry list --format json` and `flightdeck-state tracked-entries` expose the same normalized view to scripts, including flattened PR/worktree fields from `domain.plan_item`. The Rust dashboard (`lib/flightdeck-dashboard/`) is the canonical read-only consumer for active state and durable history. Live startup uses `flightdeck-state run active` only to validate/label the active run for the requested tmux session, then reads the canonical project-local state file; it must not use durable `runs/<id>/state.json` as the live mutation source unless core mirrors every live write. History/`--run-id`/`--archive` are explicit read-only archive paths. Any new dashboard work goes through that path — don't add a parallel reader.

## Activity stream architecture

TypeScript activity code lives under `lib/flightdeck-core/src/activity/`: `types.ts` defines `FlightdeckActivityEventV1`, refs, severity, and importance; `paths.ts` resolves live/archive sidecar paths; `append.ts` locks, dedupes, truncates, and rotates the JSONL; `read.ts` tails and filters; `format.ts` renders text/Markdown/JSONL; `emit.ts` is the generic best-effort appender; `workflow-emit.ts` owns issue-workflow/github/linear helpers. Event ids are deterministic from `session_id`, `entry_id`, `type`, and the natural key (`natural_key`, `details.dedup_key`, selected refs, or timestamp). Duplicate ids are skipped in memory and under the activity file lock.

The activity sidecar is `flightdeck-activity-<session>.jsonl` next to the master state. Archive uses the state lock and activity lock together, writes `<activity>.archived` as the append-side sentinel, then moves the live JSONL to `*-<terminated_at>.jsonl.archive`. Appenders check the sentinel before touching the live file, so a late activity write cannot recreate an archived sidecar. Live retention is capped at 5,000 events and 10 MiB; oversized details are collapsed to `{original_bytes,truncated}`.

Daemon/subscriber emission map: daemon start/stop, subscriber start/death/reattach, max-lifetime handoff, and wake-delivery failures emit daemon rows. `pi-bg-task-exit` remains a wake signal and then emits bg-task activity; non-exit bg-task output, successful subagent completions, question open rows, and `pi-activity-broker` rows are activity-only and do not wake master. Failed/blocked subagent completions and terminal bg-task exits still wake through the canonical wake path first.

Pi broker contract: `pi-session-bridge` installs `globalThis[Symbol.for("vstack.pi.activity")]` with `publish(event)`, `subscribe(listener)`, and `recent(limit)`. Producers publish best-effort, the broker holds a 100-event newest-first ring for in-process consumers, and `pi-bridge stream` forwards live publications as `event:"vstack_activity"` bridge rows. Flightdeck's Pi subscriber consumes those rows unless `FLIGHTDECK_PI_ACTIVITY_BROKER=0`.

Dashboard activity: the Rust dashboard reads structured JSONL through `JsonlActivitySource`, not the legacy daemon/wake sources. It validates `schema_version: 1`, skips malformed lines with diagnostics, bounds per-poll reads and pending partial records, tracks device/inode for same-path rotation, rejects symlink/non-regular activity files before opening, falls back to newest activity archive filename when the live activity file is gone, and file-watches live activity sidecars for debounced reloads. Durable history views may bind directly to a run-store `activity.jsonl` path only after confirming the metadata path stays inside the expected run directory.

Conversations file-mode rendering: when the dashboard runs without a live tmux session (`tui --state-file` / `tui --session <name>` from a foreign shell), the Conversations tab is populated from activity events instead of from live tmux capture. The render path joins `entry.message_appended` and `entry.tool_call` rows by `entry_id`, formats them through the same view module as live mode, and trims each pane's history to `dashboardConversationTurns`-equivalent depth so file-mode output stays comparable to live captures.

Workflow emitter table:

| Seam | Event types |
| --- | --- |
| `flightdeck-state init/archive` | `session.started`, `session.completed` |
| `pane-registry log-decision` | `decision.recorded` |
| `flightdeck-state set .merge_queue/.conflict_graph` | `daemon.warning` for merge-plan updates, warning when conflicts exist |
| `pane-registry set-state merge-ready/merged/aborted` | `pr.merge_queued`, `pr.merged`, `pr.merge_blocked` |
| `pane-registry teardown-entry` | `entry.completed`, `entry.cancelled`, `entry.dead` |
| `github.sh` wrappers | `pr.comments_left`, `pr.merged`, `pr.merge_queued`, `pr.merge_blocked`, `pr.checks_passed`, `pr.checks_failed` |
| `label-add` / `label-remove` wrappers | `pr.labeled`, `pr.unlabeled`, `issue.labeled`, `issue.unlabeled` |
| `linear.sh` wrappers | `linear.issue_created`, `linear.issue_updated`, `linear.issue_finished`, `linear.issue_cancelled`, `linear.relation_created` |
| `daemon/rate-limit-watchdog.ts` (Pi subscriber + pi-agents-tmux subagent watchdog) | Pi subscriber `pi-rate-limit-skipped`, `pi-rate-limit-retry`, `pi-rate-limit-resolved`, `pi-rate-limit-exhausted`, `pi-rate-limit-decider-error` rows; pi-agents-tmux broker events `subagents:rate_limit_skipped`, `subagents:rate_limited`, `subagents:rate_limit_retry`, `subagents:rate_limit_resolved`, `subagents:rate_limit_exhausted` (all mirrored into the activity sidecar) |

`workflow-emit.ts` resolves `FLIGHTDECK_ACTIVITY_FILE` first. Without it, it emits only when `FLIGHTDECK_MANAGED=1` and a state or explicit activity path resolves. Appends use `nonblocking: true`; failures warn once per `(file,type,reason)` and never fail the workflow mutation.

## `flightdeck-session` flag reference

The README points users at natural-language invocation; this is the underlying script's actual surface for contributors and AI callers. All `start` invocations use `tmux new-window` (never split panes), set `FLIGHTDECK_MANAGED=1` + `FLIGHTDECK_CHILD_PANE=1` in the launched environment, capture stable `pane_id`/`window_id`, and register through `pane-registry init-entry`.

```bash
# Managed ad-hoc Pi session.
skills/flightdeck/scripts/flightdeck-session start \
  --session-id scratch-pi \
  --title "Scratch Pi" \
  --cwd "$PWD" \
  --harness pi \
  --model openai-codex/gpt-5.5 \
  --effort xhigh \
  --prompt "Investigate this repo and report risks" \
  --kind adhoc

# Arbitrary shell command in a tracked tmux window.
skills/flightdeck/scripts/flightdeck-session start \
  --session-id logs-1 \
  --title "Log watcher" \
  --cwd "$PWD" \
  --harness shell \
  --cmd "tail -f tmp/app.log"

# Attach an existing pane without launching a new window.
skills/flightdeck/scripts/flightdeck-session attach \
  --pane %33 \
  --harness pi \
  --title "Manual Pi"
```

`pane-registry list --format json` returns normalized entries for ad-hoc, workflow, and issue rows. Adapter-arg commands (`pi-bridge-args`, `oc-attach-args`, etc.) accept entry ids, `find-by-pane` JSON, pane ids, or pane targets so daemon reconcile can spawn subscribers from the pane identity it has in hand. `session watch` uses the generic session loop; issue `watch` layers merge/PR workflow logic on top. Issue-only prompt tags on ad-hoc sessions trigger a `domain-mismatch` guard; lookups that cannot determine `kind` must pass `--entry-kind-unknown` to fail closed.

Pi idle terminal semantics are generic for `adhoc` and `workflow` entries: `isIdle == true` with no pending messages emits `terminal-state-reached` through the Pi subscriber so the daemon wakes the master. Issue-mode Pi panes stay on their issue prompt/classifier path, but adapter text whose final non-empty line is a GitHub pull URL is also `terminal-state-reached`; `pane-poll` exposes `detected_pr_number` / `detected_pr_url` so GitHub and plan lanes can persist PR metadata before authoritative merge checks.

`flightdeck-session start --prompt` supports `--model` and `--effort` / `--thinking` for LLM harnesses. Prompt launches translate model/effort into harness argv and persist launch metadata on the entry: requested/resolved model, requested/resolved effort or thinking, source (`explicit`, `env`, `auto`), resolved argv, `reasoning_status`, and `unsupported_reason` when model/effort cannot be known. Prompt tempfiles are removed by the launched child after handoff and by the parent on pre-window failure paths, including dashboard launch failure before the child window exists. Harness mappings: Pi `--model` + `--thinking`; Claude `--model` + `--effort` (`minimal`/`off` are rejected before tmux mutation); Codex `-m` + `-c model_reasoning_effort=...`; OpenCode validates the configured provider/model via exact token match in `opencode models` and passes `--model` only because top-level OpenCode has no validated effort flag. Custom `--cmd` launches are not rewritten; pass matching harness argv in the command and use `--model` / `--effort` for metadata.

Issue launches may pass `--tracker linear|github`. Linear is the default and writes `entry.domain.issue`. GitHub requires numeric `--session-id` plus `--github-url` and writes `entry.domain.github_issue`; `open-terminal --tracker github` is the intended caller and supplies those fields after `gh issue view`.

## Durable run store

`src/state/run-store.ts` owns the run history layer. vstack#227: live state, activity, and snapshots all live under `~/.vstack/flightdeck/projects/<project-id>/runs/<run-id>/`; project-local `tmp/flightdeck-state-<TMUX_SESSION>.json` is no longer a live target — it is migrated to `.migrated` on first contact and never read or written again. The project id is `<safe-project-name>-<16 hex>` where the hash material is `remote.origin.url` when present, otherwise the first configured remote, plus the absolute project-root hash; without remotes it uses the absolute project-root hash alone. `project.json` stores display fields (`name`, `root_path`, `remote_url`, `root_hash`, `created_at`, `last_seen_at`) so UIs do not have to reverse-engineer the id. `flightdeckRunStoreRoot()` honors `FLIGHTDECK_RUN_STORE_ROOT` for tests/sandboxes; production callers leave it unset and use `$HOME/.vstack/flightdeck`.

Each run directory contains `metadata.json`, `state.json`, `activity.jsonl`, optional `summary.md`, and `snapshots/`. Active pointers are per tmux session under `active-runs/<tmux-session>.json`; legacy `active-run.json` is compatibility-only. `flightdeck-state run create` initializes run files and sets the session pointer. `run ensure --tmux-session <name>` is the session lifecycle entry point used by `flightdeck-session start` / `attach` (it passes `checkStale: true` so tmux-liveness rotates orphan runs). Helper invocations (`get`/`set`/`tracked-entries`/`activity` …) call into `ensureActiveRun` with `checkStale: false`, so an idle helper does not surprise-rotate a run when no tmux session is up. `run ensure` reuses only that tmux session's active run, creates one when absent, finalizes that session's stale run only when recorded pane ids are proven absent, and fails closed on missing same-session metadata, same-session pointer mismatch, or tmux liveness failure. Other tmux sessions in the same project can keep their own active runs. `run terminate` marks metadata and state terminated, writes a timestamped snapshot pair (`<TS>.json` + `<TS>.activity.jsonl`) under `snapshots/`, copies the summary into `summary.md` when the referenced file is under the project root, clears only the active pointer for the terminated run, and renames any surviving legacy project-local files to `.migrated` so dashboards never re-read them. `run terminate-active` targets the requested tmux session. `flightdeck-state archive` is a thin wrapper around `terminateActiveRun` plus the `session.completed` activity append and the daemon-stop call. Dashboard self-launch still passes `FLIGHTDECK_SKIP_ACTIVE_RUN=1`, but helper CLIs auto-ensure on first write, so the dashboard's pane-registry entry lands in the same active run as subsequent linear/github entries (vstack#227 unified state).

`flightdeck-state run import-legacy [--state-dir <dir>]` scans `flightdeck-state-*.json.archive`, copies matching state/activity archives into durable run directories, and never deletes the legacy files. Imported run ids are deterministic from project id, session id, termination time, and archive filename so repeat imports skip existing runs. Legacy activity archives are accepted only from the same state directory with the expected basename, regular-file type, and size cap; malformed legacy state archives are skipped with diagnostics while corrupt durable project/run JSON fails loud with the path. No retention process deletes durable run directories by default.

`vstack flightdeck migrate-permissions [--scope user|project|all] [--dry-run]` is the one-time post-vstack#227 repair path for legacy run stores. It walks `projects/` under `$HOME/.vstack/flightdeck` and/or `FLIGHTDECK_RUN_STORE_ROOT`, changes safe directories to `0700` and safe files to `0600`, and refuses symlinks, foreign uid ownership, group/other write bits, or non-file/non-directory paths. The strict read path must continue to fail closed; do not add auto-chmod-on-read.

## Daemon tuning (`FD_*` env vars)

The background daemon (`flightdeck-daemon`) is configurable but defaults are fine for normal use. Listed for advanced setups:

| Variable | Default | Purpose |
| --- | --- | --- |
| `FD_POLL_SEC` | `2` | Inner-pane poll cadence. |
| `FD_OC_POLL_SEC` | `2` | OpenCode subscriber base poll cadence. |
| `FD_OC_BACKOFF_MAX_SEC` | `16` | Maximum OpenCode subscriber exponential backoff after unchanged polls; resets on new question ids, response hash change, or daemon bell marker. |
| `FD_GRACE_SEC` | `30` | Cold-start grace per pane; bells suppressed during this window. |
| `FD_WAKE_PENDING_TTL` | `300` | Wake-pending revert threshold when master crashes mid-turn. |
| `FD_MASTER_TURN_TTL` | `3600` | Maximum master turn duration before the busy lock is treated as stale. |
| `FD_ADAPTER_FRESHNESS_TTL` | `5` | Adapter freshness probe cache. Set `0` to disable during debugging. |
| `FD_ADAPTER_READ_TIMEOUT_SEC` | `2` | Per-adapter read subprocess timeout. Fractional seconds honored. |
| `FD_SPAWN_MODE` | `detach` | `detach` (setsid+nohup) or `tmux-window` (visible daemon window). Use `tmux-window` for codex/opencode/pi masters where backgrounding is unreliable. |
| `FD_MAX_LIFETIME` | `14400` | Seconds before daemon restarts itself for a fresh process (`0` disables). |
| `FD_STATE_DIR` | `$XDG_RUNTIME_DIR/flightdeck` (or `/tmp/flightdeck-$UID`) | Daemon-private state directory. Must be user-owned, mode `0700`. |
| `FD_PI_BIND_SKIP_LOG_INTERVAL_SEC` | `60` | Throttle window for `pi-subscriber-bind-skip` log rows. Tests tune this down. |
| `FD_PI_BIND_SKIP_STUCK_THRESHOLD` | `12` | Consecutive missed binds before the one-shot `pi-subscriber-bind-stuck` warning fires. |
| `FD_SUB_BIND_SKIP_LOG_INTERVAL_SEC` | `60` | Throttle window for `{claude,opencode,codex}-subscriber-bind-skip` log rows (vstack#216). |
| `FD_SUB_BIND_SKIP_STUCK_THRESHOLD` | `12` | Consecutive missed binds before `{claude,opencode,codex}-subscriber-bind-stuck` fires (vstack#216). |

### Subscriber binding observability (vstack#216)

`flightdeck-daemon health --session <S>` now reports per-pane `subscriber_status`. Values:

| Status | Meaning |
| --- | --- |
| `bound` | Subscriber process alive; events flowing. |
| `skipped` | Tracked entry registered but adapter metadata is missing (e.g. `cc_transcript` null) and the daemon hasn't yet hit the stuck threshold. |
| `stuck` | Same as `skipped` past `FD_SUB_BIND_SKIP_STUCK_THRESHOLD` consecutive ticks — one-shot warning has fired. |
| `dead` | Subscriber pid was tracked but is no longer alive; reconcile will respawn next tick. |

The daemon refreshes `<state_dir>/fd-daemon-<sessionKey>.subscribers.json` each heartbeat (and on startup) so health output is never older than `FD_HEARTBEAT_TICKS × FD_POLL_SEC` seconds. Health falls back to a `(missing — daemon hasn't written snapshot yet)` line if the file isn't yet present.

## Top-level scripts

Not run by hand in normal use — the skill calls them.

- `open-terminal` — launches issue worktree tmux windows with the chosen harness.
- `flightdeck-session` — launches or attaches generic tracked tmux sessions without fake issue ids.
- `flightdeck-state` — reads/writes the session's master state file, including tracked-entry normalization (`tracked-entries`, `write-entry`), the activity JSONL sidecar (`activity path|append|tail|export`), and durable run lifecycle helpers (`run ensure`, `run terminate-active`, import/list/show).
- `flightdeck-daemon` — background poller; wakes the master.
- `flightdeck-dashboard` — Rust/ratatui standalone dashboard; `launch` opens the tracked workflow dashboard window and optionally starts the Rust daemon, while `focus-or-launch` focuses an existing app or launches/focuses when missing and reports stale-probe path/command/stderr diagnostics on failure. Also supports demo fixtures plus `tui --state-file <path>`, `tui --session <name>` matching-active-pointer/live-file loading or no-active landing, `tui --run-id <id> [--snapshot <timestamp>]`, `tui --archive <path>`, debounced live file watching, History popup browsing/import, source-state banners, Activity feed scaffolding, cost/token totals, and confirmation-gated prune/focus actions that are blocked in read-only archive views.
- `pane-registry`, `pane-poll`, `pane-respond` — pane tracking and IO.
- `prompt-classify` — pattern-matches agent output against known prompt shapes; guards issue-only tags on non-issue entries as `domain-mismatch`.
- `pr-conflict-graph`, `parallel-groups` — issue-mode merge-order planning.
- `codex-app-server-spawn` / `-stop` — Codex bridge server lifecycle.

Full per-script descriptions follow in the [Scripts](#scripts) section below.

## Rust dashboard

The Rust dashboard crate lives in `skills/flightdeck/lib/flightdeck-dashboard/`; the trampoline at `scripts/flightdeck-dashboard` prefers `target/release/flightdeck-dashboard` and falls back to `cargo run --release`. The trampoline also runs a fast `find -newer` staleness check against `Cargo.{toml,lock}` and `src/` and triggers `cargo build --release --quiet` before exec when the prebuilt binary predates committed source (e.g. across vstack#234-class state-location changes). Set `FLIGHTDECK_DASHBOARD_NO_REBUILD=1` to suppress the staleness check on systems where the binary is intentionally pinned and cargo is unavailable.

Build and test from the crate root:

```bash
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
cargo insta test
```

Snapshot tests use `ratatui::backend::TestBackend::new(200, 60)`. The shared constants live in `tests/common/mod.rs` (`SNAPSHOT_WIDTH`, `SNAPSHOT_HEIGHT`); update intentional snapshot diffs with `INSTA_UPDATE=always cargo insta test`, then run `cargo insta review` before committing.

When adding a tab, wire the enum/state in `app/model.rs`, key handling in `app/keymap.rs`, update logic in `app/update.rs`, and render code under `app/view/<tab>.rs` plus `app/view/mod.rs`. Keep view modules render-only: write paths must be queued from update/effects, never performed from view code. Destructive or external writes must become `Cmd::Spawn` effects that shell to existing Flightdeck helpers. The Settings popup is the only direct-file exception: it may enqueue `SettingsSaveRequest::save()` to persist dashboard-scoped overrides to `~/.vstack/flightdeck/projects/<project-id>/settings.toml` (vstack#227; was `<project-root>/tmp/flightdeck-settings.toml`), after catalog validation plus store-dir/symlink checks, and it must surface visible status/error feedback without mutating the live process environment.

Popup chrome lives in `app/view/popup.rs`; individual popups live in `app/view/modals.rs`. Keep popups one-at-a-time and closeable via Esc, `[ ✕ ]`, or the backdrop. Confirm popups guard destructive/helper write affordances; settings persistence stays constrained to the Settings popup override file. Pending destructive actions must be data (`actions::WriteAction`), not closures hidden inside view code. Base-layer click zones must remain masked while a popup is open.

Display-width helpers live in `src/util/display_width.rs`. Every view module that lays out tabular content (Sessions table, right rail, popups, conversations) routes through these helpers so CJK and emoji rows align correctly. Never call `.chars().count()` or `len()` for visible width; use the helper and let it consult `unicode-width` for the right answer.

`app/theme.rs` is the single source of truth for colors and styles. Views must consume `Palette` style helpers (`theme.ok()`, `theme.warning()`, `theme.error()`, etc.) and never hard-code raw colors. The frame renderer paints `Palette::bg` once for non-system themes, panels use `Palette::surface`, and popups use `Palette::overlay`; keep System background reset so terminal palettes still win. Motion effects live in `app/view/fx.rs` and `app/motion.rs`; add new effects to the catalog, respect `MotionLevel::Off`, and keep semantic information visible without animation.

### Information hierarchy

Keep each dashboard fact in one canonical home:

- Header: session id, master harness/path, daemon chip, uptime, kind counts, freshness/observer/cost/theme chips. The theme chip is right-anchored on the trailing edge and never truncated; cost compacts before any other chip at narrow widths. Do not add per-state counts, owner pane ids, or a `paused` chip here — the pause state surfaces as a banner row directly below the header, not as a header chip.
- Left rail: status counts, merge queue glance, and conflict glance. The merge queue renders every queued entry (no per-rail truncation); the table column may abbreviate but the rail does not.
- Session table: scan-friendly row data only — kind badge, friendly state, harness, title, cost, PR/path, age, last decision, last activity, plus `(stale)` only when tmux says the pane id no longer exists.
- Right rail: selected-session summary grouped as Where, Issue, Paused, Cost, Recent decisions, and Actions. Keep low-level adapter/debug fields out of the rail.
- Detail popups: full wrapped decision/event/session text and debugging details that would crowd the main layout.
- Daemon tab: daemon/pane/debug metadata, including owner pane ids and socket/file-mode details. File/session snapshot reloads must preserve the `daemon: file-mode` chip; only socket-backed reads should show Rust daemon status.
- Help popup: the canonical legend for kind badges, state-count badges, status chips, spinners, and PR/path labels.

### Theme tokens

The Rust dashboard theme layer uses exactly 16 palette slots: four surfaces (`bg`, `surface`, `overlay`, `selected_bg`), three text tones (`text`, `subtle`, `muted`), five semantic colors (`accent`, `success`, `warning`, `error`, `info`), and four decoration colors (`secondary`, `border_active`, `border_inactive`, `chrome`). `Theme::Moon` and `Theme::Dawn` are Rose Pine truecolor palettes; `Theme::Pantera` is the Charmtone/Crush-inspired neon truecolor palette, and `Theme::System` uses reset/ANSI colors so terminal palettes control the final look. Add another theme by adding one 16-slot `Palette` const, one `Theme` variant, parser/display-name branches, theme-picker preview row, and snapshots/tests; do not add ad-hoc view colors or extend the slot set unless a new semantic category cannot be expressed with modifiers. Keep selected-row styling centralized in `Theme::row_style_selected`; use modifiers such as bold/reversed before changing source palette RGB values for contrast.

Cost tracking lives under `src/cost/`. The bundled `pricing.toml` is included at compile time, verified against vendor pricing pages in the file header, and can be overridden with `FLIGHTDECK_DASHBOARD_PRICING_FILE`. Claude transcripts are tailed incrementally from `adapter.cc_transcript`; Pi/OpenCode/Codex sources are metadata-aware stubs until stable external usage APIs are available. Cost read failures keep the last good value, warn on error transition, and surface an unhealthy-source chip instead of panicking.

Write affordances live under `src/actions.rs` plus confirmation handling in `app/update.rs`: prune shells to `pane-registry remove <entry_id>`, focus shells to `tmux select-window -t <pane_target>`. Settings persistence lives in `src/settings_catalog.rs` and is limited to validated writes of `~/.vstack/flightdeck/projects/<project-id>/settings.toml` (vstack#227); keep its path/symlink rejection, async save flow, visible status/error handling, and no-live-env-mutation behavior intact. Stale detection comes from `src/tmux/panes.rs` and caches `tmux list-panes -a -F '#{pane_id}'` for `TMUX_PROBE_TTL` seconds. History/imported/legacy archive views are read-only: prune/focus and future pane-response or daemon-control writes must be blocked there. Do not add new destructive dashboard writes without a confirm popup and a canonical script/helper owner; do not add new direct-file writes without explicitly documenting the target, safety checks, and user-visible failure path.

Daemon code lives under `src/daemon/`. The Pi subscriber is split by responsibility in `daemon/subscribers/pi/{lifecycle,bridge,stream_parse,classifier,wake_emitter}.rs`; keep future subscriber work similarly scoped and leave Claude/OpenCode/Codex/tmux fallback stubs explicit until implemented.

Snapshot fixtures are embedded through `src/fixtures.rs` from `src/fixtures/*.json`. Live-state and archive integration fixtures belong under `tests/fixtures/state/` when needed; avoid ad-hoc fixture paths in test bodies when a reusable state fixture fits.

Live wake parity testing uses `tests/live-wake.sh`. Run `tests/live-wake.sh --no-tmux` for a quick shape check, or `tests/live-wake.sh` against a real Pi/tmux session to verify daemon wake routing, subscriber behavior, and master resume semantics end to end.

## Tests

### Bun test suite

Functional + unit tests for every script. Run from the core package:

```bash
cd skills/flightdeck/lib/flightdeck-core
bun test
bun run typecheck
```

The live-wake suite (`tests/live-wake.sh`) must pass before shipping any change to the daemon run-loop, classifier, or pane I/O wiring.

### Rust dashboard

Run from the dashboard crate:

```bash
cd skills/flightdeck/lib/flightdeck-dashboard
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
cargo insta test
cargo run --release -- tui --demo
cargo run --release -- tui --state-file ../../tests/fixtures/state/entries-happy.json
```

`flightdeck-dashboard launch` is the Flightdeck startup hook. Outside tmux it prints `flightdeck-dashboard: not in tmux; skipping launch`, `FLIGHTDECK_DASHBOARD=0` exits silently, `--no-daemon` skips Rust daemon startup, and `FLIGHTDECK_DAEMON_RUST=1` opts into `daemon start --detach` before opening the tracked workflow window through `flightdeck-session start`. `focus-or-launch` is the interactive app entrypoint used by Pi `/flightdeck`: outside tmux it returns a blocked error (or JSON), a live `.entries.flightdeck-dashboard.pane_id` focuses by verified stable pane/window identity, and missing/stale entries launch then focus. Idempotency is live-entry based and protected by a per-tmux-session launch lock: a live `.entries.flightdeck-dashboard.pane_id` skips launch; malformed state, mismatched pane/window identity, probe failures, or an untracked same-name window return non-zero instead of focusing or spawning a duplicate app. Guard probes re-run while the lock is held, and launch registration is verified before the lock is released. Direct `flightdeck-dashboard launch` failures return non-zero so strict callers can fail the dashboard invariant, but `flightdeck-session start/attach` treats the dashboard hook as best-effort: it retries old dashboard CLIs without `--after-window-id`, then warns and continues if the hook still fails. The default app window title is ` FD`; set `FLIGHTDECK_DASHBOARD_WINDOW_ICON=0` for plain `FD`, or use `FLIGHTDECK_DASHBOARD_WINDOW` / CLI `--window-name` to override. The trampoline exports `FLIGHTDECK_SKILL_DIR` so installed `.agents/skills/flightdeck` projects can find sibling scripts. Use `FLIGHTDECK_DASHBOARD_MOTION` and `FLIGHTDECK_DASHBOARD_THEME` (or CLI `--motion` / `--theme`) for local launch smoke variants; `NO_MOTION`/`NO_COLOR` force `--motion off` for launched TUI children.

Snapshots live under `tests/snapshots/`; update intentionally with `INSTA_UPDATE=always cargo insta test`, then review the `.snap` diff before committing. Phase 7 parity smoke steps for terminal bell, no-auto-focus pause behavior, and live observer panes live in `docs/work-in-progress/flightdeck-dashboard-parity-smokes.md`. Watcher tests use `notify-debouncer-full` against temp dirs; if they fail locally, verify the filesystem supports native file notifications.

### Live wake

Exercises the full daemon wake path against a real Pi master. Useful after daemon or `pane-poll` changes. Takes ~2 minutes; requires tmux and a real `pi` binary.

```bash
tests/live-wake.sh
tests/live-wake.sh --no-tmux    # quick shape-check for CI
```

See `tests/README.md` for setup and cleanup.

## Debugging

The session state file lives at `~/.vstack/flightdeck/projects/<project-id>/runs/<run-id>/state.json` (vstack#227):

```bash
.agents/skills/flightdeck/scripts/flightdeck-state get '.' | jq
```

If flightdeck seems stuck on a prompt, the usual cause is a novel prompt shape the classifier doesn't recognize. The skill escalates these as `generic-multi-choice` for human review. Add a sentinel to `prompt-classify` if it's worth automating.

## Operational caveats

- **Worst-case wake latency on master crash**: `FD_WAKE_PENDING_TTL + FD_POLL_SEC` (default 302s). If master crashes between turn-start and ack-clear, the daemon waits one TTL before reverting in-flight state and re-firing.
- **State directory privacy**: `FD_STATE_DIR` (default `$XDG_RUNTIME_DIR/flightdeck`, fallback `/tmp/flightdeck-$UID`) must be user-owned and mode `0700`.
- **PID reuse race**: stranded `.draining.<pid>` files and stale `BUSY_FILE` recovery can be delayed if the kernel reuses a PID before the next startup GC. Acceptable in practice — startup GC sweeps within seconds of next daemon start.

## Operational caveats

- **Batch polling is timeout-bounded but still sequential.** Adapter reads honor `FD_ADAPTER_READ_TIMEOUT_SEC` so no single pane can wedge the tick, but panes are still polled one after the other. Full async parallelism arrives in a later iteration.
- **Daemon PID changes across `FD_MAX_LIFETIME` boundaries.** The daemon spawns a detached successor on max-lifetime rollover instead of `exec`-replacing itself in place. PID_FILE is updated by the successor; external watchers must re-read PID_FILE each call rather than caching the initial PID. The predecessor re-queries `pane-registry list --format inner-live-json` at handoff time so pane ids and harnesses come from one live registry/tmux snapshot and stale startup `--inner` snapshots are not replayed. A successful zero-row snapshot hands off an empty list; a failed live query is warn-logged and preserves the current in-memory inner set instead of treating failure as authoritative empty. The successor is invoked with the internal `--from-handoff` flag so it preserves the predecessor's wake-pending / events / wake-events.log instead of running the fresh-start wipe, and any pane that still goes stale between re-query and startup is warn-logged then dropped. Master and dashboard contracts are unaffected (master uses `BUSY_FILE.pid` which is the master's own PID, not the daemon's; the dashboard re-reads PID_FILE each tick).
- **Session-lock hot path uses in-process `flock(2)`** via `bun:ffi` for per-tick session-lock decisions, avoiding a per-call `flock(1)` fork. Falls back to spawning `flock(1)` on runtimes where `bun:ffi` can't dlopen libc.
- **Subscribers carry a parent-watchdog.** Each subscriber polls the daemon's PID every 5s and exits cleanly when the daemon dies, so a crashed daemon doesn't orphan tail/jq processes.

## Rate-limit watchdog (vstack#108)

`lib/flightdeck-core/src/daemon/rate-limit-watchdog.ts` is the canonical pure decision module. Two layered consumers wrap it: (a) the Pi subscriber's wake branch in `scripts/lib/subscribers.bash` invokes the TS CLI (`printf '%s' "$event_json" | bun rate-limit-watchdog.ts decide --pane <id> --attempt <n>`) so flightdeck-managed tracked panes get retry-with-backoff; (b) `pi-extensions/pi-agents-tmux/extensions/subagent/rate-limit-watchdog.ts` carries a vendored mirror plus a stateful per-pane wrapper for subagent panes (the two copies are parity-tested under `tests/parity/`). Classification is strict: only assistant `message_end` envelopes with `stopReason: "error"` and rate-limit prose in `errorMessage` or `content[].text` qualify; user/toolResult echoes and nested tool-output prose must stay ignored. Both layers gate the agent-end-watchdog's `needs_completion` synthetic outbox so a rate-limited pane recovers via `pi-bridge steer` instead of escalating.

Env knobs: `VSTACK_RATE_LIMIT_WATCHDOG=0` kills it, `VSTACK_RATE_LIMIT_MAX_ATTEMPTS` overrides the cap (default `5`), `VSTACK_RATE_LIMIT_BACKOFF_LADDER` overrides the ladder (default `60,120,300,600,1800`). Anthropic-provided `retry_after_ms` / `retryAfterMs` always wins. The Pi subscriber pipes event JSON to the decider on stdin, drops non-assistant skipped events before prompt classification, emits activity-only `pi-rate-limit-skipped` rows with reason `non-assistant` / `no-stopreason` / `stopreason-mismatch` / `no-prose`, emits `pi-rate-limit-retry` on scheduled retry, emits `pi-rate-limit-resolved` when a later healthy assistant turn resets the retry budget, emits `pi-rate-limit-exhausted` as an activity/advisory signal only when attempts are spent, and emits `pi-rate-limit-decider-error` as `daemon.warning` if the decider is unavailable or fails. The exhausted row itself does not wake master and does not fall through to normal completion/blocking; later independent events or daemon polls handle completion/blocking. The broker emits `subagents:rate_limit_skipped`, `subagents:rate_limited`, `subagents:rate_limit_retry`, `subagents:rate_limit_resolved`, and `subagents:rate_limit_exhausted` activity rows.

## Adapter read recovery

`FD_ADAPTER_READ_TIMEOUT_SEC` caps each adapter read subprocess (`curl`/`pi-bridge`/`codex-bridge`/`gh`) in `pane-poll`. Fractional seconds are honored. When an adapter read times out or returns an empty body, `pane-poll` clears the per-harness `*_used` flag and falls through to `tmux capture-pane` on the same tick. A wedged opencode/pi/codex adapter therefore recovers via tmux instead of classifying as idle until the freshness probe expires.

## Scripts

Detailed list of what each script does, for debugging or porting work:

| Script | What it does |
| --- | --- |
| `open-terminal` | Launches a new tmux window with the chosen harness running on the chosen issue worktree. |
| `flightdeck-state` | Reads/writes the session's master state file, including tracked-entry normalization (`tracked-entries`, `write-entry`), activity sidecar commands (`activity path|append|tail|export`), durable run commands (`run active|list|show|create|ensure|terminate|terminate-active|import-legacy`), and active-run finalization during `archive`. |
| `flightdeck-repo-sync` | Safe post-merge git helper for local default-branch reconciliation. It validates remote/branch ref components, checks the remote branch with `ls-remote`, fetches/prunes with `--no-tags`, `--refmap=`, and an explicit remote-tracking refspec instead of configured fetch refspecs or tag auto-follow, computes ahead/behind, fast-forwards clean unambiguous `main` only after a bounded ignored/untracked collision check against incoming tracked paths and index-aware existing local candidates, allows tracked-only dir→file fast-forwards, blocks missing-remote/dirty/ignored-collision/ahead/diverged cases, and emits `repo.main_*` activity rows when managed. |
| `flightdeck-daemon` | Background poller. Wakes the master when an agent needs attention. |
| `flightdeck-dashboard` | Rust/ratatui dashboard trampoline. `launch` registers and verifies `.entries.flightdeck-dashboard` via `flightdeck-session start --kind workflow`; `focus-or-launch` takes the same launch lock, focuses existing app panes, and includes stale-probe path/command/stderr diagnostics in JSON/plain errors. `--no-daemon` keeps file-mode behavior, while `FLIGHTDECK_DAEMON_RUST=1` starts the Rust daemon. `tui --demo[=NAME]` uses compiled fixtures; `tui --state-file <path>` reads a concrete master-state JSON; `tui --session <name>` reads the project-local live state only when the active pointer/metadata match that tmux session, otherwise shows a no-active landing; `tui --run-id <id> [--snapshot <timestamp>]` and `tui --archive <path>` load read-only history/legacy views. Live TUI mode watches state/archive paths with debounce, tails daemon/wake JSONL into the Activity tab, shows cost/source-state indicators, and shells confirmation-gated focus/prune writes to canonical helpers. |
| `pane-registry` | Tracks which tracked entry (issue or adhoc session) lives in which tmux pane and how to talk to its agent. |
| `pane-poll` | Reads an agent's current state (via native channel where possible). |
| `pane-respond` | Sends a reply or option pick into an agent. |
| `prompt-classify` | Pattern-matches an agent's last output against known prompt shapes. |
| `pr-conflict-graph` | Builds a file-overlap graph between PRs so flightdeck can pick a safe merge order. |
| `parallel-groups` | Reads parallel-execution groups for the current planning cycle. |
| `codex-app-server-spawn` / `-stop` | Brings up / tears down the shared Codex bridge server for codex-mode sessions. |
| `pane-clear-bell` | Clears the tmux bell flag without screen flicker after answering. |
