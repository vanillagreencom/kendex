# Flightdeck session-management reframe plan

Date: 2026-05-13

## Goal

Reframe Flightdeck from "multi-issue dev orchestration" into a generic tmux session manager for AI harness sessions. Issue/workflow management remains a first-class mode, but it becomes one domain plugin on top of generic session tracking, not the core abstraction.

Flightdeck should supervise any harness session in a tmux window: launch it, track its stable pane id, communicate through the best harness adapter, surface prompts/questions, wake the owner master, and render owner-scoped dashboard state. When the tracked session is tied to an issue/PR/worktree, Flightdeck additionally enables the existing GitHub/Linear/worktree/merge workflows.

## Status update: 2026-05-13

Merged baseline on `origin/main` now includes the following relevant work:

### Delivered

- **PR #20 / issue #19 / commit `9f40b87`** — Issue-mode GitHub auth hardening is delivered outside the core reframe phases. `skills/orchestration/scripts/lib/gh-auth.sh` now provides the shared four-step auth ladder, `skills/orchestration/scripts/ci-wait` and `skills/orchestration/scripts/bot-review-wait` source it, and `skills/orchestration/tests/run-all.sh` was added.
- **PR #22 / issue #16 / commit `7045946`** — Safe terminal teardown is delivered. `skills/flightdeck/scripts/pane-registry.bash` and `skills/flightdeck/lib/flightdeck-core/src/bin/pane-registry.ts::cmdTeardownWindow` use stable `pane_id` liveness instead of deriving a window from `pane_target`; `pane-registry teardown-entry <ENTRY_ID>` is a TrackedEntry-aligned alias for `teardown-window`. Exit codes are now explicit: `4` force required, `5` kill failed, `6` registry read failed. Reconcile backfill uses `window_name` plus `worktree`/`cwd`, with deterministic coverage in the tmux shim tests.
- **PR #21 / issue #18 / commit `6a10e4d`** — Managed-mode safety is delivered for existing spawners and issue cleanup. `skills/orchestration/scripts/flightdeck-mode` exposes `managed|unmanaged|unknown` and fails closed; `skills/flightdeck/scripts/open-terminal` exports `FLIGHTDECK_MANAGED=1` for Claude, Codex, OpenCode serve/run/attach, and Pi panes; `skills/orchestration/workflows/merge-pr.md` § 5 is scoped to the registered issue branch/worktree in Flightdeck mode. `stale-no-pr-branch` and `stale-orphan-worktree` are canonical in `skills/flightdeck/scripts/flightdeck-daemon.bash::CANONICAL_TAGS`, `skills/flightdeck/lib/flightdeck-core/src/daemon/events.ts`, `skills/flightdeck/scripts/prompt-classify.bash`, and `skills/flightdeck/lib/flightdeck-core/src/classifier/rules.ts`, with `skills/flightdeck/tests/canonical-tags-parity.sh` coverage.
- **PR #23 / issue #17 / commit `1fbed75`** — Terminated-state preservation and Pi render seams are delivered. `flightdeck-state archive` is implemented in `skills/flightdeck/scripts/flightdeck-state.bash` and `skills/flightdeck/lib/flightdeck-core/src/state/master-state.ts::archiveState`; `pi-extensions/pi-flightdeck/extensions/state.ts::buildSnapshotFromInputs` falls back to the newest valid terminated archive through `readArchiveStrict`; `pi-extensions/pi-flightdeck/extensions/state.ts::readTrackedEntries` is now the render normalization seam. `pi-extensions/pi-flightdeck/extensions/state-archive.ts`, `state-normalizers.ts`, and `render-terminated.ts` were split out, and destructive `pane-registry remove-merged` was removed from `skills/flightdeck/workflows/terminate.md`. PR #23 explicitly deferred Phase 0 owner gating.
- **PR #24 / issue #15 / commit `41ef1a5`** — Canonical Pi background-task wake routing is delivered. Bash and TS daemons emit `pi-bg-task-exit` via `skills/flightdeck/scripts/lib/daemon-bg-task-events.sh`, `skills/flightdeck/scripts/flightdeck-daemon.bash`, `skills/flightdeck/lib/flightdeck-core/src/daemon/loop.ts`, and the shared contract in `skills/flightdeck/lib/flightdeck-core/src/events/bg-task-exit.ts` (`BG_TASK_EVENT_CUSTOM_TYPE`, `BG_TASK_EXIT_EVENT_TYPE`, `BG_TASK_EXIT_CLASSIFIER_TAG`, `BgTaskExitWakeRow`). `pi-extensions/pi-background-tasks/extensions/persistence.ts`, `lifecycle.ts`, `registrations.ts`, and `orphan-watcher.ts` persist `exitNotified`/`procIdent` and recover restored running tasks with PID-reuse safety. `skills/flightdeck/workflows/watch.md` and `handle-prompt.md` route the new tag.

### In `fd-reframe-p1`

- **Phase 1** adds core `TrackedEntry` normalization helpers, `flightdeck-state tracked-entries`, `flightdeck-state write-entry`, additive `schema_version: 1.1`, additive `.entries`, issue compatibility projection back to `.issues`, `.issues`-under-`.entries` merge semantics, schema/id guards (including `domain.issue.id` and `phase`), and bash/TS parity coverage.

### Partially delivered

- **Phase 2** has the `teardown-entry` alias from PR #22 and the `FLIGHTDECK_MANAGED=1`/`flightdeck-mode` managed-session signal from PR #21, but generic `init-entry`, `--kind adhoc`, `session-terminal`/`flightdeck-session`, and manual attach behavior remain.
- **Phase 3** has canonical `pi-bg-task-exit` handling from PR #24 and stale cleanup tags from PR #21 in both daemon paths, but the `session-watch.md` vs issue `watch.md` split remains.
- **Phase 5** has render normalization, terminated archive fallback, and extracted terminated render helpers from PR #23 plus owner-aware persistent-widget behavior from PR #25, but type renames, sessions-first UI copy, and kind badges remain.

### Remaining unchanged in scope

- **Phase 0 follow-up remains**: short repo guidance in `AGENTS.md` is still pending because the Phase 0 implementation change only touched `skills/flightdeck/`, `pi-extensions/pi-flightdeck/`, and this plan doc.
- Official ad-hoc session start/attach, full schema-v2 registry/launcher migration, generic watch split, issue-mode isolation, and full docs refresh remain in this plan.

## Why this is needed

A live ad-hoc test showed the current model can mostly supervise a raw Pi session once manually wired into the registry, but the model leaks because every surface assumes a tracked entry is an issue:

- `pane-registry init FD-... --harness pi ...` created a fake issue entry for an ad-hoc session.
- `pane-respond` and the Pi bridge successfully answered structured questions via the registry.
- `flightdeck-daemon` successfully subscribed to the Pi session, emitted `pi-question`, and woke the master via `pi-bridge`.
- `pi-flightdeck` rendered the dashboard in every Pi process in the same repo/tmux session because state is keyed by project root + tmux session name and has no owner gate.
- The dashboard labels everything as issues and showed `daemon dead` until a daemon was started, even though the tracked thing was an ad-hoc session.

So the low-level mechanics are already close to generic session supervision. The schema, command vocabulary, workflows, docs, and Pi UI are still issue-centric.

## Current architecture findings

### Already generic enough to keep

- `pane-respond` is a harness IO adapter: payloads, option picks, structured questions, and tmux fallback already work across Claude Code, OpenCode, Pi, Codex, and tmux fallback.
- `pane-poll` and `flightdeck-daemon` operate on pane ids, harnesses, adapter metadata, hashes, and wake events. Their core loop is session/pane-based, not inherently issue-based.
- `patterns/tmux-monitoring.md` already documents the right durable targeting primitive: persist immutable `%pane_id`; window names auto-rename and are not reliable.
- Pi question routing is generic: daemon emits `pi-question`, `pane-respond --harness pi --question ...` routes to `pi-bridge answer|reject`.
- Daemon state is already scoped by tmux session id (`s<N>`) and tracks subscribers by pane id.

### Issue assumptions to isolate

- `skills/flightdeck/SKILL.md` description, dependencies, commands, mode rules, schema, and workflow list all frame Flightdeck as issue/PR lifecycle management.
- `skills/flightdeck/README.md` describes issue spawning, merge order, PR handling, and new Linear issue recommendations as core behavior.
- `workflows/start.md`, `start-new.md`, `parallel-check.md`, `merge-plan.md`, `close-issue.md`, and `terminate.md` all assume Linear/GitHub/worktree/PR metadata.
- `workflows/watch.md` is partly generic, but registry init, status dashboard, merge planning, terminal states, and handler invocation use `ISSUE_ID` everywhere.
- `workflows/handle-prompt.md` mixes generic prompt handling with issue/PR-specific decision logic.
- `flightdeck-state` initializes `.issues`, `.merge_queue`, and `.conflict_graph`; `phase` reads `workflow-state-<ISSUE>.json`.
- `pane-registry` CRUD keys entries by issue id and stores issue-specific fields (`worktree`, `pr_number`, `scope_files_*`, `orchestration_started`).
- Adapter spawn files are named by issue id (`oc-spawn-<issue>.json`, `pi-spawn-<issue>.json`, etc.).
- `open-terminal` requires issue-like IDs and uses the worktree skill before launching.
- `pi-flightdeck` types and render code use `IssueRecord`, `.issues`, `merge_queue`, `PR`, `worktree`, and "issues" labels throughout.
- `pi-flightdeck` suppresses in child panes only via `PI_SUBAGENT_CHILD_AGENT` or `FLIGHTDECK_CHILD_PANE`; it has no owner identity check.

## Target model

Use two layers:

1. Core session manager — always available.
2. Issue/workflow domain — optional layer for tracked sessions that represent implementation issues.

### Core tracked session

Use a neutral internal term in code: `TrackedEntry` or `TrackedSession`. User-facing UI can say "sessions". Prefer `TrackedEntry` in schema/code to avoid confusion with tmux session and Pi session ids.

Draft schema shape:

```json
{
  "schema_version": 2,
  "session_id": "VS",
  "started_at": "<ISO8601>",
  "terminated": false,
  "owner": {
    "harness": "pi|claude|opencode|codex|unknown",
    "pane_id": "%25",
    "pane_target": "VS:3.1",
    "cwd": "/repo",
    "pid": 1752875,
    "pi_session_id": "...",
    "pi_bridge_socket": "/tmp/pi-session-bridge-1000/pi-1752875.sock"
  },
  "entries": {
    "fd-adhoc-1778630553": {
      "id": "fd-adhoc-1778630553",
      "title": "Adhoc Flightdeck Smoke",
      "kind": "adhoc|issue|workflow",
      "state": "waiting|prompting|submitting|ready|complete|cancelled|dead",
      "substate": null,
      "harness": "pi",
      "cwd": "/repo",
      "window": "6",
      "pane_target": "VS:6.1",
      "pane_id": "%33",
      "launch": { "model": "openai-codex/gpt-5.5", "effort": "medium", "cmd": "pi ..." },
      "adapter": {
        "pi_bridge_pid": 2725883,
        "pi_bridge_socket": "/tmp/pi-session-bridge-1000/pi-2725883.sock",
        "pi_session_id": "...",
        "oc_url": null,
        "oc_session_id": null,
        "cc_url": null,
        "cc_transcript": null,
        "cx_ws": null,
        "cx_thread_id": null
      },
      "domain": {
        "issue": {
          "id": "CC-123",
          "worktree": "/repo/trees/cc-123",
          "pr_number": 123,
          "scope_files_declared": 5,
          "scope_files_actual": 8,
          "orchestration_started": true
        }
      },
      "last_capture_hash": "sha256:...",
      "last_response_at": "<ISO8601>",
      "spawned_at": "<ISO8601>",
      "last_polled_at": "<ISO8601>",
      "decisions_log": []
    }
  },
  "issue_mode": {
    "merge_queue": ["CC-123"],
    "conflict_graph": { "edges": [], "computed_at": null }
  },
  "paused_for_user": null
}
```

Compatibility requirement: read old `.issues` state as `kind: "issue"` entries. During migration, either keep writing `.issues` as a projection or keep old CLI commands as aliases until workflows are fully moved.

## Implementation plan

### Phase 0 — Immediate operational guidance and owner safety

Purpose: stop the exact class of mistakes seen in the ad-hoc test while the larger reframe is built.

Status (2026-05-13): **PARTIAL**. Owner metadata, owner-scoped `pi-flightdeck` rendering, `dashboardVisibility`, and child-pane suppression are done in PR #25. The only remaining Phase 0 item is the short `AGENTS.md` operational guidance, deferred because that file was outside this worker's edit scope.

1. **[REMAINING]** Add short repo guidance to `AGENTS.md` after implementation is ready:
   - When user asks for a new tmux tab/window for testing, create a new tmux window in the existing session, never split the current pane.
   - Use Flightdeck session tools/skill for harness launch and IO; persist `%pane_id`/`#{window_id}`; do not rely on window names.
2. **[DONE]** Add owner metadata to current Flightdeck state init/watch path before broad schema work:
   - `owner.pane_id`
   - `owner.pane_target`
   - `owner.harness`
   - `owner.cwd`
   - `owner.pid` as the owner harness PID (`FLIGHTDECK_OWNER_PID`, fallback parent PID)
   - Pi owner bridge metadata when master harness is Pi, plus `owner.discovery_error` on lookup failure.
3. **[DONE]** Update `pi-flightdeck` to render the mini dashboard only for the owner by default.
   - New setting: `dashboardVisibility = owner | tmux-session | always`.
   - Default: `owner`.
   - Popup can show read-only observer info if opened manually, but persistent widget should not appear in peer Pi sessions.
4. **[DONE]** Preserve child-pane suppression (`PI_SUBAGENT_CHILD_AGENT`, `FLIGHTDECK_CHILD_PANE`) as an additional guard.

Validation:

- Start one owner Pi session and at least two peer Pi sessions in the same repo/tmux session.
- Create a tracked ad-hoc entry.
- Verify mini dashboard appears only in owner, unless setting is changed.
- Verify `/flightdeck` popup in peer either hides persistent widget or clearly says `Observed Flightdeck owned by %pane`.

### Phase 1 — Normalize state model with backward compatibility

Purpose: introduce generic entries without breaking issue workflows.

Status (2026-05-13): **DONE in `fd-reframe-p1`**. PR #23 / commit `1fbed75` delivered the Pi render-side normalization seam; this phase adds the core state helpers, `schema_version: 1.1`, additive `.entries`, compatibility projection back to `.issues`, and bash/TS parity coverage.

1. **[DONE]** Add state normalization helpers in `skills/flightdeck/lib/flightdeck-core/src/state/`:
   - **[DONE]** `readTrackedEntries(state)` projects `.issues` to `TrackedEntry` records, then overlays valid `.entries` records by id so entries are authoritative without hiding legacy issue-only writes.
   - **[DONE]** `writeTrackedEntry(...)` writes `.entries[id]` and projects `kind: "issue"` entries to `.issues[issueId]` for compatibility.
   - **[DONE]** `entryIdForIssue(issueId)` and `issueIdForEntry(entry)` helpers, with blank/invalid entry ids rejected on writes.
   - **[DONE]** Core helper mirrors the pi-flightdeck render seam contract instead of reintroducing direct renderer/core `.issues` reads; pi-flightdeck remains read-only and package-local.
2. **[DONE]** Add `schema_version` and `owner` to `flightdeck-state init`. `owner` was delivered additively in PR #25; `schema_version: 1.1` and `.entries: {}` are now backfilled additively by init.
3. **[DONE]** Keep existing `.issues`, `.merge_queue`, `.conflict_graph` in v1 compatibility path.
4. **[DONE]** Add tests for:
   - **[DONE]** v1 `.issues` read compatibility in the core state helpers.
   - **[DONE]** v2 `.entries` read path.
   - **[DONE]** dual-write/projection behavior.
   - **[DONE]** bash/TS parity for `tracked-entries` plus `write-entry` round trip, including v2-only entries, mixed `.issues`/`.entries`, malformed entry/id warnings, unknown schema guard (including `phase` fallback reads), and id validation. Archive/stale-state parsing remains covered by PR #23's pi-flightdeck tests and existing `flightdeck-state archive` parity coverage.

Validation:

```bash
cd skills/flightdeck/lib/flightdeck-core
bun test tests/parity/flightdeck-state.test.ts
bun run typecheck
```

### Phase 2 — Generalize registry and launch APIs

Purpose: make official ad-hoc session management possible without fake issue IDs.

Status (2026-05-13): **PARTIAL**. PR #22 / commit `7045946` delivered the `teardown-entry` alias and safe pane-id teardown; PR #21 / commit `6a10e4d` delivered the `FLIGHTDECK_MANAGED=1` signal and `skills/orchestration/scripts/flightdeck-mode` basis for managed detection. Phase 2 worker branch `fd-reframe-p2` adds generic registry init/list/find, `flightdeck-session start`, and Pi attach. Remaining work is mostly adapter spawn-file generalization, broader non-Pi adapter launch metadata, and Phase 3 watch split.

1. **[DONE]** Evolve `pane-registry` CLI:
   - **[DONE]** `pane-registry teardown-entry <ENTRY_ID>` is available as a TrackedEntry-aligned alias for `teardown-window` in `skills/flightdeck/scripts/pane-registry.bash` and `skills/flightdeck/lib/flightdeck-core/src/bin/pane-registry.ts::cmdTeardownWindow`. Delivered in PR #22.
   - **[DONE]** Add aliases or new commands using `entry` terminology:
     - **[DONE]** `pane-registry init-entry <ENTRY_ID> --title ... --kind ... --cwd ... --window ... --harness ...` writes through `flightdeck-state write-entry` / `writeTrackedEntry` and dual-writes `.issues[id]` for `kind=issue`.
     - **[DONE]** `pane-registry list --format json` returns normalized entries from `tracked-entries` while preserving legacy top-level issue fields for issue entries.
     - **[DONE]** `pane-registry find-by-pane` returns stable JSON `{id, kind}` and resolves both `.entries[*]` and legacy `.issues[*]` pane ids/targets.
   - **[DONE]** Keep current commands (`init <ISSUE>`, `set-state <ISSUE>`, etc.) as issue-mode aliases.
2. **[PARTIAL]** Rename internal variable names from `issue` to `entryId` where code is generic. New `init-entry` paths use entry terminology, but legacy issue-mode commands and compatibility adapters intentionally keep `issue` names until Phase 3/4 split the watch and issue layers.
3. **[REMAINING]** Split adapter spawn metadata paths away from issue IDs:
   - New `adapter-spawn-<entryId>.json` helpers, or preserve per-harness files but pass `entryId` not issue id.
   - Old files still read for compatibility.
4. **[DONE]** Add first-class ad-hoc launch script/API:
   - Option A: extend `open-terminal` with `--session-id`, `--title`, `--cwd`, `--prompt`, and `--cmd` so it can launch without worktree creation.
   - **[DONE]** Option B: add `flightdeck-session` script and keep `open-terminal` as issue preset.
   - **[DONE]** Preferred: add a new script for clarity, then let `open-terminal` call it in issue mode for the tmux fallback path.
5. **[PARTIAL]** New launch behavior:
   - **[DONE]** Always use `tmux new-window`, not split panes, in the new generic launch path.
   - **[DONE]** Capture `#{window_id}`, `#{pane_id}`, `#{window_index}`, and pane cwd immediately for generic entries.
   - **[DONE]** Set `FLIGHTDECK_CHILD_PANE=1` and `FLIGHTDECK_MANAGED=1` in launched child sessions through the shared pane env helper.
   - **[PARTIAL]** Prefer harness adapters (`pi-bridge`, OpenCode HTTP attach, Claude channels, Codex bridge) over tmux fallback in the generic launch/attach path. Pi launch/attach bridge discovery is implemented; OpenCode/Claude/Codex generic adapter metadata remains tied to issue spawn files.
6. **[DONE]** Add attach behavior for sessions launched manually:
   - **[DONE]** `flightdeck-session attach --pane %33 --harness pi --title "..."`
   - **[DONE]** Discovers Pi adapter metadata via `pi-bridge list --pid` where possible.

Validation:

- Launch ad-hoc Pi session through the new official path.
- Attach an existing Pi pane by `%pane_id`.
- Verify registry lists entries with `kind=adhoc` and no issue metadata.
- Verify legacy issue launch still produces equivalent state.

### Phase 3 — Split generic watch loop from issue workflow logic

Purpose: keep the daemon/prompt loop generic, move PR/issue decisions behind domain guards.

Status (2026-05-13): **PARTIAL**. PR #24 / commit `41ef1a5` delivered the canonical `pi-bg-task-exit` wake event and handler routing; PR #21 / commit `6a10e4d` delivered canonical stale cleanup tags in both daemon paths. The `session-watch.md` vs issue `watch.md` split itself remains.

1. **[REMAINING]** Refactor `workflows/watch.md` into two conceptual parts:
   - Generic `session-watch.md`: init state, reconcile entries, spawn daemon, poll entries, route generic prompts, ack/yield.
   - Issue `watch.md` extension: merge planning, terminal issue states, PR conflict graph, workflow phase summaries.
2. **[REMAINING]** Generic states:
   - `waiting`
   - `prompting`
   - `submitting`
   - `ready`
   - `complete`
   - `cancelled`
   - `dead`
3. **[REMAINING]** Issue-mode state mapping:
   - `merge-ready` maps to generic `ready` + domain `issue.phase=merge-ready`.
   - `merged` maps to generic `complete` + domain `issue.outcome=merged`.
   - `aborted` maps to generic `cancelled` + domain `issue.outcome=aborted`.
4. **[REMAINING]** Keep existing states in compatibility until all issue workflows are updated.
5. **[PARTIAL]** Prompt handler split:
   - **[DONE]** `pi-bg-task-exit` is a canonical daemon wake and is routed in `skills/flightdeck/workflows/watch.md` and `skills/flightdeck/workflows/handle-prompt.md`. Delivered in PR #24.
   - **[DONE]** `stale-no-pr-branch` and `stale-orphan-worktree` are canonical tags in bash and TS daemon/classifier paths and route to safe keep handlers. Delivered in PR #21.
   - **[REMAINING]** Generic handlers: `oc-question`, `pi-question`, `bash-permission-prompt`, `awaiting-direction`, safe `generic-multi-choice`, `terminal-state-reached`/completion signal, plus `pi-bg-task-exit`, need to live behind a generic session handler surface.
   - **[REMAINING]** Issue handlers: cleanup worktree, bot-review, rebase, force-push, audit relation, merge, descope, review fix suggestions, scope creep.
6. **[PARTIAL]** Add handler guards:
   - **[PARTIAL]** Existing stale cleanup tags now avoid destructive out-of-scope cleanup in managed Flightdeck mode. Delivered in PR #21.
   - **[REMAINING]** If an issue-only tag appears on an ad-hoc session, escalate as `domain-mismatch` instead of applying PR/worktree assumptions.
   - **[REMAINING]** If a generic tag appears on an issue session, use generic handler then resume issue flow.

Validation:

- Existing issue workflow tests remain green.
- New ad-hoc session test can answer generic questions and complete without PR/Linear/GitHub calls.
- `generic-multi-choice` on ad-hoc session does not run PR conflict logic.

### Phase 4 — Preserve and isolate issue/workflow management

Purpose: no regression for current Flightdeck users.

Status (2026-05-13): **REMAINING**. The new generic plumbing delivered in PRs #21, #22, and #24 makes isolation safer, but the issue/workflow preservation layer has not been reframed yet.

1. **[REMAINING]** Keep `flightdeck start [ISSUE_ID]`, `start new`, `parallel-check`, merge planning, and termination summary as issue-mode workflows.
2. **[REMAINING]** Move required dependency language:
   - Core Flightdeck requires tmux and harness adapters only.
   - Issue mode requires `github`, `linear`, `project-management`, and `worktree` as applicable.
3. **[REMAINING]** In `SKILL.md`, change required setup:
   - Always verify `$TMUX`.
   - Load GitHub/Linear/project-management only when entering issue workflow commands.
4. **[REMAINING]** Keep issue commands in command table under `Issue workflows`.
5. **[REMAINING]** Add new generic commands under `Session management`:
   - `session start`
   - `session attach`
   - `session watch`
   - `session status`
   - `session stop` / `session remove`
6. **[REMAINING]** Update termination behavior:
   - Generic sessions end with a session summary, not merge summary.
   - Issue sessions still produce the current issue/PR/new-issue recommendation summary.
7. **[REMAINING]** Keep `pr-conflict-graph`, `parallel-groups`, and issue decision biases untouched except for namespacing/docs.

Validation:

- Run focused issue-mode tests and at least one live issue-mode smoke before any default flip.
- Run generic ad-hoc smoke without Linear/GitHub credentials to prove core mode does not require them.

### Phase 5 — Reframe Pi dashboard and UI language

Purpose: UI reflects sessions first, issue metadata second.

Status (2026-05-13): **PARTIAL**. PR #23 / commit `1fbed75` delivered the render normalization seam (`pi-extensions/pi-flightdeck/extensions/state.ts::readTrackedEntries`), terminated archive fallback (`buildSnapshotFromInputs` + `readArchiveStrict`), and extracted `pi-extensions/pi-flightdeck/extensions/render-terminated.ts`. PR #25 delivered owner-aware persistent-widget gating and observer popup header. Sessions-first naming and kind badges remain.

1. **[PARTIAL]** Rename TypeScript UI types:
   - **[REMAINING]** `IssueRecord` → `TrackedSession` or `TrackedEntry`.
   - **[REMAINING]** `IssueState` → `TrackedState`.
   - **[PARTIAL]** `MasterState.issues` access goes through normalized entries helper. Delivered in PR #23 for key render paths through `readTrackedEntries`; remaining work is full type rename and core schema alignment.
2. **[REMAINING]** UI copy changes:
   - `issues` → `sessions` / `tracked sessions`.
   - `Dashboard max issues` → `Dashboard max sessions`.
   - `Conflicts & merges` tab hides or renames when no issue-mode entries exist.
   - Rows render optional PR/worktree/scope metadata only when present.
3. **[DONE]** Add owner-aware render behavior:
   - Persistent widget shows only in owner by default.
   - Child panes remain suppressed.
   - Observer popup shows `Observed Flightdeck owned by <owner.pane_id>` in peer panes.
4. **[PARTIAL]** Update render details:
   - **[DONE]** Post-termination render fragments were extracted to `pi-extensions/pi-flightdeck/extensions/render-terminated.ts` and archive fallback now preserves completed-session context. Delivered in PR #23.
   - **[REMAINING]** Header counts: sessions by state, plus issue count when issue-mode entries exist.
   - **[REMAINING]** Row label: `title` first, fallback `id`.
   - **[REMAINING]** `kind` badge: `adhoc`, `issue`, `workflow`.
   - **[REMAINING]** Issue-specific PR/worktree details in child rows only.
5. **[REMAINING]** Update package settings, README, and extension manager descriptions.

Validation:

- Render tests/harness snapshots for:
   - no sessions
   - one ad-hoc session
   - one issue session
   - mixed ad-hoc + issue
   - owner vs peer Pi session
   - stale daemon

### Phase 6 — Documentation and repo guidance

Update all docs in the same code change that changes behavior:

Status (2026-05-13): **PARTIAL / BLOCKED**. Targeted workflow docs were refreshed by PR #21, PR #22, PR #23, and PR #24, but the sessions-first documentation pass is blocked on Phases 0-5.

- **[REMAINING]** `AGENTS.md`
  - Add 1-2 lines for "new tmux tab/window" requests.
- **[PARTIAL]** `skills/flightdeck/SKILL.md`
  - New framing: session manager first; issue/workflow mode second.
  - Dependencies split by mode.
  - Commands table split into core session commands and issue workflow commands.
  - Schema section updated for entries + issue domain metadata.
  - Existing partial refresh: PR #24 documented the `pi-bg-task-exit` canonical wake contract.
- **[REMAINING]** `skills/flightdeck/README.md`
  - Product framing: supervise AI harness sessions; issue orchestration is built-in domain mode.
  - Add ad-hoc examples.
  - Retain issue/PR examples.
- **[REMAINING]** `skills/flightdeck/DEVELOPMENT.md`
  - Explain schema v2 compatibility and generic/session vs issue plugin boundaries.
- **[PARTIAL]** `skills/flightdeck/patterns/tmux-monitoring.md`
  - Add explicit "new tmux tab/window" operational pattern.
  - Existing partial refresh: PR #22 documented `teardown-entry`/stable-pane teardown, and PR #24 documented `pi-bg-task-exit` monitoring.
- **[PARTIAL]** `skills/flightdeck/patterns/prompt-handlers.md`
  - Split generic vs issue-only handlers.
  - Existing partial refresh: PR #21 documented `stale-no-pr-branch` and `stale-orphan-worktree` safe keep handlers.
- **[PARTIAL]** `skills/flightdeck/workflows/*.md`
  - Add generic workflows and update issue workflows to call core session primitives.
  - Existing partial refresh: PR #21 scoped managed cleanup in `close-issue.md`/orchestration merge flow, PR #23 updated `terminate.md`, and PR #24 routed `pi-bg-task-exit` in `watch.md`/`handle-prompt.md`.
- **[REMAINING]** `pi-extensions/pi-flightdeck/README.md`
  - Dashboard owner scope and sessions-first language.
- **[REMAINING]** `pi-extensions/pi-flightdeck/package.json`
  - Settings descriptions from issue to session.
- **[REMAINING]** `docs/work-in-progress/flightdeck-dashboard-tui-plan.md`
  - If still active, align its `IssueCard` model with `TrackedEntry`.

Proposed short AGENTS.md wording once implementation supports it:

> When user asks to test in a "new tmux tab/window", create a new tmux window in the current session, never split the active pane. Use Flightdeck session tooling for launch/attach and harness IO; persist `%pane_id`/`#{window_id}` and communicate through the harness adapter (`pi-bridge`, OpenCode HTTP, Claude channels, Codex bridge) before tmux fallback.

## Suggested execution order

Some prerequisites are now satisfied by PRs #21-#25. Phase 0 implementation is functionally landed; finish the remaining `AGENTS.md` guidance before declaring Phase 0 fully closed, then continue with Phase 1.

1. Finish the remaining Phase 0 `AGENTS.md` operational guidance.
2. Complete Phase 1 core state normalization with v1 compatibility tests, reusing the PR #23 `readTrackedEntries` render seam instead of inventing a parallel read path.
3. Extend the Phase 2 registry API from the delivered PR #22 `teardown-entry` alias to `init-entry`, normalized `list`, and entry-aware `find-by-pane`, leaving existing issue API intact.
4. Add the official ad-hoc launch/attach path that uses `tmux new-window`, records immutable ids, and reuses the PR #21 `FLIGHTDECK_MANAGED=1` / `flightdeck-mode` managed-session signal.
5. Split generic session watch/handler logic from issue workflow logic, reusing the PR #24 `pi-bg-task-exit` contract and PR #21 stale cleanup tags.
6. Preserve and isolate issue/workflow management on top of the generic primitives.
7. Reframe Pi dashboard language/types and kind badges on top of the PR #23 archive/render seams and PR #25 owner gating.
8. Complete docs/guidance refresh once behavior lands.
9. Only after all tests and live smoke pass, consider updating skill dependencies from hard required to mode-specific.

## Test matrix

### Unit/parity

```bash
cd skills/flightdeck/lib/flightdeck-core
bun test
bun run typecheck
```

Add/extend tests for:

- `flightdeck-state` v1/v2 init/read/archive.
- `pane-registry` generic entry init/list/find/remove.
- `pane-poll` batch rows with generic entries.
- `pane-respond` question routes for generic entries.
- `flightdeck-daemon` ad-hoc session wake.
- `pi-flightdeck` state normalization and owner gating.

### Live smokes

1. Ad-hoc Pi session:
   - Launch owner Pi in repo.
   - `flightdeck session start --harness pi --title "Smoke" --cwd "$PWD" --prompt "ask a question"`.
   - Confirm new tmux window created, not split.
   - Confirm dashboard only owner shows.
   - Answer `pi-question` through `pane-respond`.
2. Peer Pi suppression:
   - Start two other Pi sessions in same repo/tmux session.
   - Confirm no persistent Flightdeck dashboard in peers by default.
3. Legacy issue mode:
   - Launch or no-op dry-run an issue workflow.
   - Confirm `.issues` compatibility and existing prompt handlers still work.
4. Live wake:
   - Run `skills/flightdeck/tests/live-wake.sh` under the relevant gate when touching daemon/wake behavior.

## Compatibility policy

- Do not remove `.issues` support until at least one production cycle after v2 entries ship.
- Do not rename user commands without aliases.
- Do not require GitHub/Linear credentials for core ad-hoc session mode.
- Do not make Pi the only working path; all core abstractions must stay harness-neutral.
- Do not flip daemon `start` to TS default as part of this reframe unless `tests/live-wake.sh` is green under that same change.

## Risks and mitigations

- Risk: schema churn breaks existing issue workflow. Mitigation: normalized read layer, dual-write or projection, and parity tests before workflow edits.
- Risk: Phase 1+ duplicates newly merged primitives and creates parallel abstractions. Mitigation: explicitly reuse `pi-extensions/pi-flightdeck/extensions/state.ts::readTrackedEntries`, `pane-registry teardown-entry`, `skills/orchestration/scripts/flightdeck-mode` / `FLIGHTDECK_MANAGED=1`, and `skills/flightdeck/lib/flightdeck-core/src/events/bg-task-exit.ts` (`pi-bg-task-exit`) rather than adding competing seams.
- Risk: dashboard leaks into peer sessions again. Mitigation: owner metadata + default owner-only visibility + peer render tests.
- Risk: terminology confusion between tmux session, Pi session, and tracked session. Mitigation: code term `TrackedEntry`, UI term `session`, explicit fields for `tmux_session_id` and `pi_session_id`.
- Risk: issue-only handler mutates wrong ad-hoc session. Mitigation: domain guards on handler dispatch.
- Risk: launch paths duplicate panes after adapter discovery timeout. Mitigation: mirror current Pi/Codex post-open behavior: if window opened, never fall through to another spawn.
- Risk: one daemon per tmux session conflicts with multiple independent owners. Mitigation: keep one owner per tmux session as invariant for now; document that separate Flightdeck owners require separate tmux sessions.

## Definition of done

This still applies after PRs #20-#24; implementation should use the new code names and contracts called out above rather than adding parallel ones.

- Flightdeck can launch or attach at least one ad-hoc tracked entry/session in a new tmux window, track it without fake issue IDs, answer a structured question through the native adapter, and stop/remove it cleanly through the entry-aware registry path (`teardown-entry` or its successor).
- Existing issue mode still launches, tracks, responds, plans merges, handles canonical daemon wake tags (`pi-bg-task-exit`, stale cleanup tags), and terminates with the same user-visible behavior.
- Pi dashboard shows sessions-first UI, reads through the normalized tracked-entry seam, and renders persistently only in the owner Pi session by default.
- README, SKILL.md, workflow docs, Pi extension README/settings, and AGENTS.md guidance match behavior.
- `bun test` and `bun run typecheck` pass in `skills/flightdeck/lib/flightdeck-core`.
- Live ad-hoc smoke and relevant daemon wake smoke pass.
