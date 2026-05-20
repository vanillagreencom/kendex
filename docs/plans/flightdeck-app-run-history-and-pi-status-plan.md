# Flightdeck App, Run History, and Pi Status Plan

## Pre-execution context (updated 2026-05-19 after cleanup/dashboard and issue #152 follow-up)

This plan was drafted before the flightdeck v2 architecture refactor, v3 plan-file orchestration lane, and cleanup/dashboard handoff landed in main. Most of the plan is still accurate; this section captures the deltas the executing agent must know before starting this next plan.

**Architecture state in main now:**

- Flightdeck has four explicit lanes after PR #128 / #134 / #137 / #138 / #139:
  - `flightdeck linear *` (Linear issue lifecycle, `workflows/linear/`)
  - `flightdeck github *` (GitHub issue lifecycle, `workflows/github/`)
  - `flightdeck session *` (generic, `workflows/shared/` + `flightdeck-session`)
  - `flightdeck plan start <path>` (plan-file orchestration; `workflows/plan/`). This plan document is itself a valid phase-style plan file under `skills/flightdeck/PLAN-FILE.md`: allowlisted top-level context sections are shared context, master-only orchestration sections are omitted from child briefs, and `### Phase ...` sections under `## Implementation phases` plus `## Additional workstream ...` are the work items. `flightdeck plan start docs/plans/flightdeck-app-run-history-and-pi-status-plan.md` is a viable execution path.
- `entry.domain` is a mutually-exclusive union of `issue` (linear) / `github_issue` (github) / `plan_item` (plan). Validator at `skills/flightdeck/lib/flightdeck-core/src/state/tracked-entry.ts` rejects multi-domain entries on both `write-entry` and raw `setEntryField` / `flightdeck-state set` paths (per PR #139 hardening commit `517fd332`).
- SKILL.md is now compact (currently 259 lines in `origin/main`, down from the old 453-line version). Reference docs live in `skills/flightdeck/` siblings: `SCHEMA.md`, `SCRIPTS.md`, `ENV.md`, `WATCHDOGS.md`, `PROMPT-TAGS.md`, `PLAN-FILE.md`.

**Cleanup/dashboard handoff status (completed before this plan):**

The active handoff at `docs/plans/flightdeck-cleanup-and-dashboard-settings-handoff.md` has already been executed. These PRs are merged on `origin/main` and should be treated as baseline, not pending work:

| PR | Merge commit | Result |
|----|--------------|--------|
| #142 | `f94ed1baaea5562c71bdf518dbfa17851f1839fc` | Flightdeck README keyhint trim |
| #143 | `11767919b3650298bac700db94d4405b4a007091` | #140 stale standby/awaiting-watch hint guard |
| #144 | `fe1e1cf7c1a37c6867a1706172884123df2542b5` | #129 pi-session-bridge skill cache eviction/bound |
| #145 | `6548e073f5aacd24ce820884747460036ae0cc99` | #130 pi-agents-tmux stale cwd handling |
| #146 | `d1cb9b1ce4681ecb39670e8d9055183aa0e4a1c6` | #136 daemon stale-pane handoff/respawn |
| #147 | `ae87aa0ccb9ff1dd9875c89c4a936acd907ab78f` | #126 rate-limit skipped/retry/resolved/exhausted activity |
| #148 | `26be898d730c5e406a5d47e3fad7165de6b0d366` | #133 tmux window-name sync (`window_name_current`) |
| #149 | `41f1e55116022c0daafe0c5c28357790db74dbf8` | #135 Pi subscriber binding validation/process-group reap |
| #150 | `6bd4bd6b21297339d921f5bc8b7929cb8020e6be` | Dashboard Settings popup |

Issue state now:

- **Closed:** #126, #129, #130, #133, #135, #136, #140, #141, #151, #155, #156, #157.
- **Recently fixed before this plan:** #152 — GitHub Pi launches no longer depend on Bash ANSI-C `$'...'` prompt quoting in arbitrary login shells. Keep launch-command construction portable across bash/zsh/fish; do not reintroduce Bash-only `%q` strings for commands pasted into tmux panes.

Additional post-handoff fixes now merged or landing before this plan executes:

| PR/Commit | Result |
|-----------|--------|
| PR #153 / merge `48221836` | #141 installed Pi package runtime dependency handling and tests. |
| PR #154 / merge `b6004a8c` | #151 daemon startup error diagnostics/lifecycle hardening. |
| commit `bc4a00d5` | Dashboard supervision UX refresh, Pi cost polling, `pane-poll` Pi history maxBuffer fix (#155), daemon reconcile active-without-subscriber fix (#156), and Pi shell output minimizer default-on. |
| commit `3b2e33f9` | `refresh-window-names` rechecks entry existence before mutating `window_name_current`, preventing ghost rows after cleanup (#157). |
| #152 fix | `open-terminal` GitHub/Pi launch command quoting is fish-compatible for multiline prompts under the brief-file threshold. |

Relevant merged deltas for this plan:

- **#140 is partly handled, not fully obsolete.** PR #143 makes `pi-flightdeck` awaiting-watch/standby hints ignore tracked entries whose pane ids are proven stale. PR #167 handles the Rust dashboard no-active/history split, and PR #166 makes `pi-flightdeck` a status shell with `/flightdeck` Rust app focus/open. Pi-native archive browsing remains out of scope; any legacy terminated-archive fallback in Pi must stay inactive/status-only, not active supervised work.
- **#133 is done.** PR #148 added `entry.window_name_current`, `pane-poll`/daemon refresh, dashboard current-title rendering, and `FLIGHTDECK_DISABLE_AUTO_RENAME`. Do not reimplement pane/window-name sync; build on these fields.
- **#149 is load-bearing.** Pi subscriber binding now validates cwd + recorded `adapter.pi_session_id`, malformed `pi-bridge state` preflight fails open to stream attach, mismatched subscribers are quarantined/reaped by process group, positive-PID signal fallback was removed, and mismatch respawn preserves the registry harness. Do not regress these daemon/subscriber safety properties when changing run lifecycle.
- **#150 added dashboard settings.** Rust dashboard has a Settings popup on `S` / `Alt+S`, with `skills/flightdeck/lib/flightdeck-dashboard/src/settings_catalog.rs` as catalog source, writes dashboard-scoped overrides to `<project-root>/tmp/flightdeck-settings.toml`, applies those overrides at dashboard command startup before logging/runtime thread creation, does not mutate the parent shell or live process env from popup actions, rejects NUL/invalid values, and uses path/symlink checks. Future dashboard env/default changes must update `settings_catalog.rs`, snapshots/tests, and `ENV.md`/README docs.
- **#151 is fixed, but daemon exits remain high-signal.** PR #154 added diagnostics for detached startup failures. If new daemon/run-history work sees `daemon-exited`, capture fresh events and file/update a new issue instead of assuming #151 still owns the failure.
- **#155/#156/#157 are fixed and should be treated as regression constraints.** Keep `pane-poll` adapter reads bounded with large-enough buffers, keep daemon reconcile spawning subscribers for active panes with missing subscribers, and keep window-name refresh from recreating removed entries.

**Standards from the v2/v3 session that this plan should follow (re-stated for clarity):**

- **Use the worktree skill**: `.agents/skills/worktree/scripts/worktree create <id>`. Never `git worktree add`.
- **Self-contained child prompts** when spawning panes (see PLAN-FILE.md and `workflows/plan/start.md`). No `/skill:flightdeck plan start`, `/skill:flightdeck linear start`, etc. as child prompts — those are master-side workflow names, not user-input commands.
- **Spawned pi panes use `openai-codex/gpt-5.5` model + `xhigh` thinking** (user directive from the v2/v3 session).
- **Backup wake timer is mandatory first action** when starting orchestration: `bg_task spawn command:'while true; do sleep 2700; echo "BACKUP-WAKE $(date -u +%FT%TZ)"; done' notifyOnOutput:true notifyPattern:'BACKUP-WAKE'`. Previous sessions hit daemon misfires (#135, #136) and a later daemon exit (#151, now fixed) where the backup timer was the only thing preventing silent stalls. On every BACKUP-WAKE, drain daemon events, check daemon status, run `pi-bridge state --socket <socket>` for every live tracked Pi pane, file/update a GitHub issue for any new daemon misfire or pane wedge, restart the daemon only after recording the diagnostic, and stop the timer in final cleanup.
- **5-reviewer fan-out per substantive PR** (arch / test / doc / error / safety). Light scope (2 reviewers: doc + arch) for text-only or docs-only PRs. Reviewer prompts MUST include: "Do NOT act as flightdeck master. Do NOT produce session/cycle/dashboard status. JSON-only output."
- **Recursion invariant for any new flightdeck lane/handler**: workflow files must NEVER emit `/skill:flightdeck <lane> (start|watch|close|terminate)` or `$flightdeck <lane> ...` or `/flightdeck <lane> ...` as a child-pane prompt. Add a parity test asserting zero hits (the v3 PR added `handler-guards.test.ts` lines 139-147 — use as template).
- **CLEAN merge gate + `FLIGHTDECK_AUTO_MERGE=0` honored across ALL merge-answering handlers** (merge-now, merge-ready-but-unknown, force-merge-confirm). Authoritative `gh pr view --json state,mergeStateStatus,mergeCommit` verification before any close-item / close-issue cleanup. Strict force-merge predicate (APPROVED + green + disjoint + UNKNOWN-timer expired); not the weaker "approved or no pending reviewers".
- **Docs ship with code in the same commit** (per CLAUDE.md): READMEs, SKILL.md, AGENTS.md, instruction payloads, `vstack.toml`, `.env.local.example`, `package.json` — every behavior change updates affected cross-referencing docs in the same commit.
- **READMEs are user-facing only** (CLAUDE.md): no implementation jargon, schema details, internal env vars. Move tech detail to `DEVELOPMENT.md` or v2 reference doc siblings.
- **No project-specific references** in `skills/`, `agents/`, `hooks/`, `pi-extensions/` shipped code/docs. Use `<N>`, `<REPO>`, `<ITEM_ID>` placeholders.
- **Mirror dirs are never edited** (`.agents/`, `.pi/`, `.claude/`, `.opencode/`, `.codex/`). They regenerate via `vstack refresh`.
- **Parity tests mandatory for `lib/flightdeck-core/`**: before commit, `cd skills/flightdeck/lib/flightdeck-core && bun test && bun run typecheck`. Both must pass.

**Order-of-execution recommendation:**

- The cleanup/dashboard handoff is already complete. Start this plan from `origin/main` after the #150 merge commit (`6bd4bd6b21297339d921f5bc8b7929cb8020e6be`) or later.
- The state-mode and run-identity scaffolding (Phases 1-4) are the load-bearing additions now in scope. PR #167 ships the Rust dashboard History popup/run-history UI from Phase 5; remaining Pi-native archive browsing stays out of scope. Phase 6.5 should be scoped to the remaining archive/history behavior because #143 already handled the stale awaiting-watch hint subset.
- Phase 7 (post-merge main sync) is independent and could land any time, but use the real current example as a regression case: after the cleanup session the primary `main` checkout was clean but `ahead 8, behind 9`; the helper must report that as blocked/diverged and must not reset, stash, or discard local commits.

## Problem

Before PR #167, Flightdeck treated the tmux session name as the primary live state key. When a Flightdeck session was terminated, the live state file (`tmp/flightdeck-state-<tmux-session>.json`) was archived. If the dashboard started later and no live state file existed, it fell back to the newest archive and rendered that completed snapshot.

That behavior was useful for post-mortem inspection, but confusing during continued work in the same Pi/tmux chat: the dashboard appeared to show a complete session even though the user was still working. The root issue was that Flightdeck conflated several concepts:

- The chat/harness session.
- The tmux session.
- A Flightdeck supervision run.
- An archived snapshot of a completed run.

The dashboard now clearly distinguishes active runs from archived runs and makes historical snapshots browsable without pretending they are still active.

PR #167's current branch head includes the PR #165 lifecycle helpers, the merged PR #166 status-shell/focus-open behavior, and the Rust dashboard active/history/archive behavior. On this branch, `/flightdeck` delegates to Rust app focus/open, the old Pi popup/prune UI is gone, and the Rust dashboard is the canonical full UI.

## Goals

- Separate Flightdeck run identity from tmux session identity.
- Preserve active state updates until a run is explicitly terminated.
- After termination, show a clear no-active-run/history view instead of silently presenting an archive as active.
- Allow browsing previous runs and snapshots from the dashboard.
- Store history in a durable location that survives worktree cleanup and project `tmp/` churn.
- Keep backwards compatibility with existing `tmp/flightdeck-state-*.json` and `.archive` files.
- Stop stale completed-session mini-dashboard banners from appearing as active supervised work in brand-new Pi sessions; any retained Pi legacy archive fallback must be inactive/status-only.
- Keep `@vanillagreen/pi-flightdeck` compatible with the Rust dashboard history/no-active split without claiming Pi-native History/run browsing.
- Preserve the merged PR #166 status-shell behavior: `/flightdeck` focuses or launches the Rust app, `/flightdeck:toggle` cycles the mini-dashboard, and the old Pi popup/prune UI stays removed.
- Automate post-merge local-main sync so Flightdeck workflows do not leave the operator's main checkout stale after merging PRs.

## Non-goals

- Do not change agent orchestration semantics for issue work in this plan.
- Do not remove project-local state files immediately; keep compatibility wrappers/pointers.
- Do not require GitHub/Linear/worktree dependencies for generic session history browsing.
- Do not delete `@vanillagreen/pi-flightdeck`.
- Do not make Pi extension UI the source of truth for durable history. The Rust app History popup owns run/snapshot browsing on this branch.

## Proposed model

### Concepts

- **Project**: a stable repository/workspace identity.
- **Run**: one Flightdeck supervision episode, with a unique `run_id` independent of tmux session name.
- **Snapshot**: immutable saved state for a run at a point in time.
- **Active pointer**: project-level pointer to the currently active run, if any.
- **Archive view**: read-only dashboard mode for past runs/snapshots.
- **Flightdeck app**: the Rust `flightdeck-dashboard tui` application. It owns full navigation, history, daemon details, conversations, decisions, conflicts, and archive inspection.
- **Pi extension**: optional `pi-flightdeck` inline status, pause banner, and `/flightdeck` focus/open integration for the Rust app. The Rust app remains the canonical full dashboard and History UI.

### Current implementation notes

These details were verified after merging PR #166 into this branch and should be treated as current behavior:

- PR #167 owns the Rust dashboard active/history/archive behavior on the current base.
- PR #166 status-shell/focus-open work is merged: `@vanillagreen/pi-flightdeck` registers `/flightdeck` for Rust app focus/open, keeps `/flightdeck:toggle` plus the `alt+m` mini-dashboard toggle, and no longer owns the old full popup UI.
- Rust dashboard no-active/history mode does not render terminated archives as active state; explicit History/`--archive`/`--run-id` views are read-only.
- The Pi mini-dashboard/status snapshot may still read legacy terminated archives for inactive fallback/diagnostics, but must not render them as active supervised work; Rust History owns archive browsing.
- The extension has no tool-output renderer registration and no `tool_call` / `tool_result` rendering logic. If future Pi tool renderers are added, keep only those renderer registrations and tests.
- `flightdeck-dashboard launch` no-ops outside tmux, starts the Rust app through `flightdeck-session start`, and records a `flightdeck-dashboard` tracked entry.
- `flightdeck-dashboard focus-or-launch` is the Pi `/flightdeck` integration target and reports path/command/stderr diagnostics on stale probe, focus, or launch failures.
- The app tmux window default is ` FD`, configurable through `--window-name`, `FLIGHTDECK_DASHBOARD_WINDOW`, and `FLIGHTDECK_DASHBOARD_WINDOW_ICON=0`; those env vars are exposed in the Rust dashboard Settings popup and `settings_catalog.rs`.

### Storage layout

Use a durable global store:

```text
~/.vstack/flightdeck/projects/<project-id>/
  project.json
  active-run.json                 # optional pointer
  runs/
    <run-id>/
      metadata.json
      state.json
      activity.jsonl
      summary.md                  # optional
      snapshots/
        <timestamp>.json
        <timestamp>.activity.jsonl
```

`<project-id>` should be stable and human-safe. Candidate algorithm:

1. Prefer git remote URL + absolute project root hash.
2. Fall back to absolute project root hash.
3. Store display fields in `project.json`: project name, root path, remote URL, created/last_seen.

Keep project-local compatibility:

```text
tmp/flightdeck-state-<tmux-session>.json       # symlink/copy/pointer to active run state
tmp/flightdeck-activity-<tmux-session>.jsonl   # symlink/copy/pointer to active run activity
```

Old archive files stay readable and can be lazily imported.

## Lifecycle changes

### Run creation

When `flightdeck-session start` or any issue-mode entry (`flightdeck linear start`, `flightdeck github start`) begins:

1. Resolve project id.
2. Load active pointer.
3. If no active run exists, create a run.
4. If active run is terminated, create a new run.
5. If active run has entries but zero live panes, finalize/archive old run and create a new run.
6. Write/refresh project-local compatibility state files.

### Run termination

When the lane-appropriate terminate completes (`flightdeck linear terminate`, `flightdeck github terminate`, `flightdeck plan terminate`, or generic session unwind via `flightdeck-state archive`):

1. Mark active run `terminated: true`.
2. Set `terminated_at`.
3. Write final snapshot.
4. Move/write summary into the run directory.
5. Clear active pointer.
6. Leave project-local compatibility archive files for old tooling.

### Dashboard startup

Dashboard load behavior should become:

1. If active run exists: load active run state as live.
2. If no active run exists: show the normal dashboard shell with a clear no-active-run empty state and a key hint to open history.
3. Rust dashboard only loads archives when the user explicitly chooses a run/snapshot from the History popup, or when launched with `--archive`/`--run-id`.
4. Persistent Pi mini-dashboard banners stay hidden, show a compact no-active hint, or show inactive legacy fallback text; they must not render the newest archived run as an active/completed supervised session on fresh Pi startup.
5. Archive mode is always read-only and visually distinct.

## Dashboard UX

### History popup, not a tab (shipped in PR #167)

PR #167 adds the `History` popup to the Rust dashboard. It is not a permanent tab. The main tab model stays focused on the active/current run; history is an overlay opened on demand for durable run/snapshot browsing, legacy archive import, and returning to the active run.

Keybinds:

- `H`: open/close History popup.
- `j`/`k` or arrows: move through runs/snapshots.
- `PageUp`/`PageDown`: scroll faster.
- `/`: focus filter input inside the popup.
- `Enter`: load selected run/snapshot read-only into the current dashboard view.
- `A`: return to active run if one exists.
- `S`: open/copy summary path for selected run if present.
- `I`: import legacy archives for this project.
- `Esc`: close popup without changing current view.

Popup layout:

- Title: `History`.
- Top filter row: branch/PR/run id/status/title text filter.
- Main list: scrollable runs, newest first.
- Optional expanded selected row: snapshots within selected run.
- Footer hints: `Enter load`, `A active`, `/ filter`, `Esc close`.

Rows:

- Status: active, terminated, stale, imported.
- Run id.
- Started/ended age.
- Entry count.
- PR numbers.
- Branch/worktree summary.
- Snapshot count.
- Summary path/status.

Selecting a run with multiple snapshots expands that run inline so the user can choose a specific snapshot without adding another tab/state mode.

### Active vs archived banners

Active:

```text
Live run · <run-id> · daemon <status> · <N> entries
```

No active run:

```text
No active Flightdeck run · choose a run from History or start a new session
```

Archived:

```text
Archived run · read-only · <run-id> · terminated <time>
```

Mutating actions must be disabled in archived view:

- remove stale entry
- focus live pane if pane gone
- daemon controls
- pane-response actions

### Current dashboard view changes

- Header includes run status (`live`, `archived`, `no active run`).
- Header/help overlay shows the History popup keybind.
- Daemon tab should say whether data comes from active run state, imported archive, or legacy project-local archive.
- Existing fallback-to-newest-archive is explicit, not automatic active view.
- Loading an archived snapshot from History replaces the current displayed snapshot until the user returns to active run or picks another snapshot.

## Pi extension scope after the Rust app

Keep `@vanillagreen/pi-flightdeck` as the thin Pi status integration delivered by PR #166 rather than a second dashboard application.

Keep:

- Persistent inline mini-dashboard via `setMiniDashboardWidget`.
- Pause banner / paused-for-user user messages near chat.
- Optional terminal bell and Pi notifications for pause/status events.
- Dashboard visibility rules (`owner`, `tmux-session`, `always`) and child-pane suppression.
- Mini-dashboard settings needed for refresh cadence, max rows, tree style, visibility, and toggle.
- Cross-extension usage stats from `pi-agents-tmux` if the mini-dashboard still displays cost/tokens/turns.
- `/flightdeck:toggle` and its shortcut for hidden/compact/expanded mini-dashboard cycling.
- `/flightdeck` Rust app focus/open delegation and diagnostics.

Removed or moved to the Rust app by PR #166:

- Pi custom popup framework and modal-lock usage for Flightdeck.
- Popup tab definitions and renderers for Overview, Live feed, Conversations, Conflicts & merges, Decisions, and Daemon.
- Popup search/scroll/detail/keymap state.
- Popup-only prune action (`p`/`del`). Live stale-entry pruning belongs in the Rust app, where read-only archive guards already live.
- Popup-only settings: `popupShortcut`, `autoOpenOnPause` if it only opens the popup, `liveFeedLines`, `conversationExcerptChars`, `conversationsHistory`.
- Legacy `/flightdeck watch` paste-to-editor workaround when no current daemon path depends on bare `/flightdeck watch`.

Mini-dashboard parity:

- Preserve the same information density the inline widget shows for active supervised entries: session count, state summary, merge queue, daemon/app health chip, row kind/title/state/harness, pane gone chip, PR/worktree/branch/model/effort/cost where already shown.
- Do not show terminated archive rows as active supervised work in fresh Pi sessions. Rust dashboard History owns archives on this branch; Pi may retain inactive legacy archive fallback text only as a status-shell limitation.
- Do not count the Rust app itself as a normal workflow session in the mini-dashboard. The app entry should be hidden/system or represented as app/header status so the widget does not self-report `WF flightdeck` as supervised work.

### `/flightdeck` app focus/open behavior (shipped in PR #166)

On this branch, `/flightdeck` focuses an existing Rust dashboard app window or launches it first. The old Pi custom popup is removed.

Behavior:

1. If `TMUX` is unset, no-op and show an error notification/message: `Flightdeck app requires tmux; /flightdeck only works inside tmux.`
2. If the Rust app is already running, focus its tmux window.
3. If the Rust app is not running, launch it in a new tmux window, then focus it.
4. If launch/focus fails, surface stderr in a Pi notification/message.

Implementation shape:

- Use the Rust dashboard `focus-or-launch` helper as the canonical integration target.
- The helper owns tmux probing, launch, and focus. The Pi extension shells to this helper instead of reimplementing tmux logic in TypeScript.
- Focus by stable `pane_id` when available: resolve `#{window_id}` from the pane id, then `tmux select-window -t <window_id>`.
- Fall back to the app's recorded window id/name only when stable pane id is missing and stale-target guards pass.
- Return structured JSON for the Pi extension: `status: focused|launched|blocked|failed`, `reason`, `pane_id`, `window_id`, `window_name`, `stderr`.

### Canonical app window name and tmux placement

Default app window name:

```text
 FD
```

Notes:

- `` is the Nerd Font / Font Awesome plane glyph (`U+F072`).
- Terminals cannot reliably advertise Nerd Font support. If unsupported, the glyph may render as tofu/blank. Provide explicit fallback controls instead of pretending to auto-detect perfectly.
- Keep `FLIGHTDECK_DASHBOARD_WINDOW` / `--window-name` as the strongest override.
- Add a simple opt-out such as `FLIGHTDECK_DASHBOARD_WINDOW_ICON=0` or `FLIGHTDECK_NERD_FONT=0` to use plain `FD`.
- Keep window title short and stable; detailed status belongs inside the app and mini-dashboard, not the tmux tab title.

Placement:

- Launch the app before launching child Flightdeck session windows.
- Capture the master window id before spawning children.
- Insert the app window immediately after the master window (`tmux new-window -a -t <master-window-id>` or equivalent), not merely wherever tmux's current insertion point happens to be.
- Keep launch idempotent: if a live app pane already exists, do not spawn another; just focus it when requested.
- Child session windows continue using their meaningful task titles; do not prefix every child window with ` FD`.

## CLI/script changes

### New or extended commands

`flightdeck-state run ...`:

```bash
flightdeck-state run active
flightdeck-state run create --project-root <path> --tmux-session <name>
flightdeck-state run list [--project-root <path>] [--json]
flightdeck-state run show <run-id> [--snapshot <timestamp>]
flightdeck-state run terminate <run-id>
flightdeck-state run import-legacy [--project-root <path>] [--state-dir tmp]
```

`flightdeck-dashboard`:

```bash
flightdeck-dashboard tui --session <tmux-session>          # active/named live-state read
flightdeck-dashboard tui --run-id <run-id>                 # read-only selected run
flightdeck-dashboard tui --archive <path>                  # read-only legacy archive
flightdeck-dashboard tui --run-id <run-id> --snapshot <timestamp>  # read-only selected snapshot
flightdeck-dashboard launch [--window-name <name>]         # ensure app window exists
flightdeck-dashboard focus-or-launch [--window-name <name>] # focus existing app or launch it
```

`flightdeck-session start`:

```bash
flightdeck-session start ... [--after-window-id <tmux-window-id>]
```

`--after-window-id` should be used by the dashboard launcher to place the app immediately after the master window. Existing callers can omit it and keep current tmux insertion behavior.

### Migration behavior

- On dashboard startup, detect legacy archives and offer import.
- On `run import-legacy`, copy metadata and snapshots into the global store.
- Do not delete legacy files during migration.

## Data model additions

Add to master state or run metadata:

```json
{
  "run_id": "2026-05-18T03-10-00Z-vs-a1b2c3",
  "project_id": "vstack-a1b2c3",
  "project_root": "/mnt/Tertiary/dev/vstack/main",
  "tmux_session": "VS",
  "state_mode": "active|archived|imported",
  "created_from": "new|legacy-archive|legacy-live",
  "schema_version": 2
}
```

Keep existing fields for compatibility.

## Implementation phases

### Phase 1 — Design and compatibility layer

- Add project/run path helpers in `flightdeck-core`.
- Define `ProjectIndex`, `RunMetadata`, active pointer schema, and migrations.
- Add tests for project id stability and path generation.
- Document storage contract in `SKILL.md`, `DEVELOPMENT.md`, and `README.md`.

### Phase 2 — State command support

- Implement `flightdeck-state run active/list/show/create/ensure/terminate/terminate-active/import-legacy`.
- Keep existing `path`, `init`, `archive`, and activity commands working.
- Add tests for active pointer creation/clearing and legacy archive import.

### Phase 3 — Session lifecycle integration

- Update `flightdeck-session start` and issue start path to create/reuse active run.
- Update terminate flow to mark run terminated and clear active pointer.
- Preserve project-local compatibility files.
- Add regression tests for same tmux session + terminated previous run + new delegation = new run.

### Phase 4 — Dashboard data loading

- Add dashboard snapshot source variants:
  - active run
  - no active run
  - archived run
  - legacy archive
- Stop automatic newest-archive-as-live behavior.
- Add read-only archive guard for mutating actions.
- Add snapshot tests for active, no-active, archived, and imported views.

### Phase 5 — History popup UI (shipped in PR #167)

- Add a History popup/modal opened by keybind (`H`), not a top-level tab.
- Implement scrollable run/snapshot list, filter input, inline snapshot expansion, open active, and open archived snapshot controls.
- Avoid global key conflicts with the Settings popup: `S` / `Alt+S` is already a dashboard-wide Settings key from #150. Any History action using `S` (for example summary-path copy/open) is modal-local only, documented in the History footer, and covered by key-handling tests.
- Add help text and keybind docs.
- Add tests/snapshots for popup closed/open, filtered history, empty history, selected archived run, expanded snapshot list, import flow, and active run return.

### Phase 6 — Migration and cleanup

- Add legacy archive import prompt/command.
- Add retention policy docs, but do not implement deletion by default.
- Ensure old project-local archives still load.

### Phase 6.5 — Startup stale-banner and prune policy

Legacy pi-flightdeck behavior intentionally kept completed sessions visible from the newest terminated archive and offered manual `p`/`del` prune for pane-gone live entries. That was useful for post-completion visibility, but wrong for the new run model because it makes a fresh Pi session look like Flightdeck is still supervising old pane-gone work. PR #143 already added a narrow stale-pane guard for never-started/awaiting-watch hints: if tmux proves every tracked pane id is dead, the extension no longer renders a misleading "start supervising" hint. PR #166 removes the old Pi popup/prune UI; PR #167 makes Rust History/archive browsing explicit.

Rust dashboard policy on this branch:

- Terminated runs move to Rust-app history/no-active mode instead of rendering as live state.
- The persistent Pi mini-dashboard renders active runs by default and may retain only inactive legacy archive fallback text for diagnostics/status, not active supervised rows.
- If there is no active run, show nothing, a compact no-active hint, or inactive fallback text; do not show old archived rows with `pane gone` prune guidance.
- `pane-registry remove` remains a manual action for stale entries in a live active run.
- Do not auto-prune entries inside archived/terminated runs; archives are historical records.
- On new Flightdeck run start, create/reuse a fresh active run and leave previous terminated runs browseable through `flightdeck-state run list/show` and the Rust History popup.
- If a live active run has zero live panes and is not marked terminated, archive/finalize it as stale before starting a new run rather than pruning rows one-by-one.

Pi limitation to keep explicit:

- Pi does not own a native History UI.
- Any legacy terminated archive fallback in Pi is inactive/status-only and must not replace the Rust History popup.
- Avoid old archived rows with `pane gone` prune guidance.

Implementation targets:

- Update pi-flightdeck state loading so terminated archive fallback does not feed the persistent active banner; Rust History/explicit archive views consume archives separately.
- Update Rust dashboard startup similarly: no automatic newest-archive-as-active rendering for active views.
- Keep direct archive/run launch (`tui --archive`, `tui --run-id`) read-only.
- Add tests for Pi startup after a terminated archive: no `Flightdeck 2 sessions · ✓ 2 · session complete` active persistent banner; durable history remains available through `flightdeck-state run list/show` and the Rust History popup.
- Add Rust dashboard tests for no-active startup after terminated state/history, read-only archive mutation guards, and explicit snapshot activity containment.
- Add tests for live active stale rows: `pane gone` chip and manual prune still appear only for active run state.

### Phase 6.6 — Trim `@vanillagreen/pi-flightdeck` to a status shell (shipped in PR #166)

Goal: keep the Pi extension as a lightweight inline status display while deleting the duplicated full-screen popup app.

Tasks completed by PR #166:

- Delete popup-only UI state, tab renderers, modal-lock usage, popup search/detail/key handling, and popup prune behavior from `pi-extensions/pi-flightdeck/extensions/flightdeck.ts`.
- Keep/refactor the mini-dashboard renderer so it still shows the current inline information for active supervised entries.
- Keep pause banner, notifications/bell, visibility policy, stacked-widget integration, settings reader, and `pi-agents-tmux` usage-stat bridge.
- Replace the `/flightdeck` popup handler with Rust app focus/open delegation.
- Keep `/flightdeck:toggle` for mini-dashboard hidden/compact/expanded cycling.
- Remove popup-only settings/resources, including the old `f6` popup shortcut.
- Verify no current daemon/session path still depends on `/flightdeck watch`; remove the legacy paste workaround if unused.
- Update user-facing docs and metadata to remove `pi-flightdeck` deprecation wording:
  - root `README.md` Pi extension catalog
  - `skills/flightdeck/README.md`
  - `pi-extensions/pi-flightdeck/README.md`
  - `pi-extensions/pi-flightdeck/package.json` extension-manager labels/resources
  - any active plan/docs files that act as current guidance (historical reports can keep historical wording if clearly archival)
- Current wording: `pi-flightdeck` is optional Pi UI support for Flightdeck. It provides inline mini-dashboard/status, pause/user messages, notifications, and `/flightdeck` Rust app focus/open integration. The Flightdeck skill and Rust app work without it.

Tests:

- Mini-dashboard renders active session rows with same key information as before.
- Fresh Pi sessions with only terminated history do not render archived runs as active mini-dashboard state.
- `/flightdeck` focuses or launches the Rust app and reports outside-tmux blocked errors.
- `/flightdeck:toggle` still cycles mini-dashboard state.
- No current user-facing README/catalog says `pi-flightdeck` is deprecated or required.

### Phase 6.7 — App focus/open helper, icon title, and launch order (shipped in PR #166)

Goal: make the Rust app the canonical full dashboard and ensure it appears in a predictable tmux location.

Tasks completed by PR #166:

- Add the Rust dashboard `focus-or-launch` command as the canonical focus/open path.
- Add stable focus logic: app pane id → window id → `tmux select-window -t <window-id>`.
- Keep launch idempotent: if the app entry/pane is alive, do not spawn a duplicate.
- Change default app window title from `flightdeck` to ` FD`.
- Keep `--window-name` / `FLIGHTDECK_DASHBOARD_WINDOW` override, and add `FLIGHTDECK_DASHBOARD_WINDOW_ICON=0` so plain `FD` is available. Because #150 made dashboard env vars editable from the Settings popup, this title/default work updates `settings_catalog.rs`, per-setting validation, Settings popup snapshots/help, `ENV.md`, and user-facing README text together.
- Extend `flightdeck-session start` with an insertion target such as `--after-window-id <tmux-window-id>` and pass it to `tmux new-window -a -t <window-id>`.
- Move automatic dashboard launch earlier in `flightdeck-session start`: after argument validation/stale-state archival, before the child window is created, and never when the requested entry is the dashboard itself.
- Capture the master window id before spawning children and use it so the app sits immediately after the master window.
- Ensure app-only launch does not create misleading active user-work rows. Prefer a hidden/system dashboard entry or separate app pointer if needed.
- Update docs for tmux ordering and Nerd Font title behavior.

Tests:

- Default app window title is ` FD`; env/flag/Settings override can produce plain `FD`.
- App launch outside tmux is a no-op/error, not a crash.
- Focus/open helper returns `focused` for an existing live app pane.
- Focus/open helper returns `launched` and focuses the new pane when missing.
- Stale dashboard entry does not block relaunch.
- First child launch creates tmux window order: master, app, child.
- Existing live app remains after master starts additional children; no duplicate app window appears.

### Phase 7 — Post-merge main sync automation

Add a Flightdeck post-merge sync step so successful merges always reconcile local main checkouts. This is complementary to existing issue-mode merge logic; it must hook into that flow rather than replace it.

Existing responsibilities stay unchanged:

- `merge-plan.md` builds the conflict graph, chooses merge order, and decides whether a PR is safe to merge.
- Per-issue agents normally run their own merge workflow; `merge-plan.md` only invokes `github pr-merge` directly when the pane is dead/absent.
- `watch.md` marks entries `merged`, recomputes graph state, and handles follow-on `BEHIND`/rebase cases.
- `close-issue.md` and `terminate.md` verify terminal outcomes and archive the run.

New responsibility:

- After a PR is observably merged into the remote default branch, run a safe local-main sync for the operator's primary checkout and report the result.

Hook points:

1. In `merge-plan.md` § 3 successful direct-merge path, run sync immediately after `pane-registry set-state <ISSUE_ID> merged` and `pr_number` recording.
2. In `watch.md` / `close-issue.md` path where a per-issue agent merged its own PR and Flightdeck later observes `PR state == MERGED`, run sync after recording the issue outcome as `merged`.
3. In generic PR-producing workflows, run sync when a tracked generic workflow has a bound PR number and that PR transitions to `MERGED`.
4. Do not run sync for `QUEUED FOR AUTO-MERGE` until a later poll observes the PR actually merged.

Behavior:

1. Run `git fetch origin --prune` in the primary project checkout.
2. If local `main` can fast-forward to `origin/main`, run `git checkout main && git pull --ff-only` or equivalent safe fast-forward update.
3. If local `main` has local commits ahead of `origin/main`, do not silently rewrite. Surface a clear Flightdeck prompt/status row:
   - local main ahead/behind counts
   - suggested action: merge origin/main into local main, rebase local commits, or leave divergent
   - require explicit operator choice for non-fast-forward updates
4. If local main has dirty/untracked files, do not overwrite. Surface dirty paths and require operator action.
5. Record the sync result in Flightdeck activity (`repo.main_synced`, `repo.main_sync_blocked`, or `repo.main_sync_failed`).
6. Add docs to the Flightdeck skill and GitHub merge workflow instructions: after PR merge, Flightdeck always attempts local main sync and reports the result.

Implementation approach:

- Add a focused `flightdeck-repo-sync main` helper under `flightdeck-core` rather than embedding git logic in workflow prose.
- Inputs: `--project-root <path>`, `--remote origin`, `--branch main`, optional `--json`.
- Output should be structured JSON with `status: synced|already-synced|blocked|failed`, `ahead`, `behind`, `dirty_paths`, `reason`, and `commands_suggested`.
- Workflow prose calls the helper and branches only on the helper's structured status.
- Helper emits/returns activity payload data; `workflow-emit.ts` records `repo.main_synced`, `repo.main_sync_blocked`, or `repo.main_sync_failed`.
- Keep this helper generic enough for non-issue PR-producing workflows.

Safety rules:

- Never hard reset local `main`.
- Never stash or discard user changes automatically.
- Never force-push.
- Fast-forward only when clean and unambiguous.
- If the current checkout is not `main`, prefer updating a separate local `main` ref/worktree safely; if checkout switching would disturb dirty files, block and report.

Tests:

- Fast-forward local main after a synthetic origin update.
- Clean no-op when already synced.
- Blocked result when local main is dirty.
- Blocked result when local main is ahead/diverged; include a regression matching the cleanup session state `main...origin/main [ahead 8, behind 9]`, where the worktree is clean but a fast-forward is unsafe.
- Queued auto-merge does not trigger sync until merged state is observed.
- Activity row emitted for success/block/failure.


## Additional workstream — Pi 0.75.1 extension follow-ups

Merged from `docs/plans/pi-0751-extension-followups-plan.md`; that standalone file should be removed after this merge so this document is the single execution plan.

### Context

Pi 0.75.1 landed mostly provider/runtime fixes:

- Config selectors now scale visible row count to terminal height.
- Anthropic-compatible API-key requests ignore unrelated `ANTHROPIC_AUTH_TOKEN` values.
- Bedrock message conversion skips unknown content blocks.
- Azure OpenAI Responses and OpenAI Responses error messages prefix HTTP status codes for retry classification.
- OpenCode Go Kimi reasoning replay normalizes streamed reasoning fields to `reasoning_content`.
- Xiaomi MiMo model metadata moved to OpenAI-compatible endpoints/API.
- Node 26 compressed fetch responses are fixed by installing undici fetch globals with Pi's global dispatcher.
- Npm-family package commands on Windows avoid shell argument splitting when install prefixes contain spaces.
- Non-working OpenAI Codex fast variants were removed.

Audit target: all `pi-extensions/*` plus the Flightdeck skill and dashboard/session code paths.

### Summary

No urgent deprecations are required.

Recommended changes are small hardening/UX improvements:

1. Prefix Codex Responses provider-shim errors with HTTP status.
2. Make `pi-skills-manager` browse list rows responsive to terminal height.
3. Optionally rename stale Codex `spark` / `fast` test fixture IDs to neutral text-only fixtures.
4. Reposition `pi-flightdeck` as optional Pi UI support for Flightdeck, not deprecated and not required by the Flightdeck skill.
5. Leave provider/runtime-only Pi fixes as no-op for vstack extensions, but add notes/tests where useful.

### Goals

- Keep vstack Pi extensions aligned with Pi 0.75.1 retry/runtime/UI behavior.
- Avoid deprecating healthy extension features based only on upstream internal fixes.
- Prefer small, testable compatibility patches over broad refactors.
- Preserve the Flightdeck Rust app as the canonical full Flightdeck UI.
- Preserve `pi-flightdeck` as optional Pi-native status/UI support.

### Non-goals

- Do not reimplement Pi's provider metadata fixes in vstack extensions.
- Do not replace Pi core package management or config selector UI.
- Do not remove `pi-codex-minimal-tools`; Pi 0.75 image APIs are general, while this package still owns Codex-specific OAuth/native-tool bridging plus `apply_patch`/`view_image` parity.
- Do not revive removed Codex fast model variants.
- Do not mark `pi-flightdeck` deprecated or required.

### Phase 8 — Codex provider-shim HTTP-status error prefix

#### Problem

Pi 0.75.1 fixed OpenAI/Azure Responses error formatting so `errorMessage` includes HTTP status codes. That helps Pi's agent-level retry classifier match transient `429` and `5xx` failures.

`pi-codex-minimal-tools` has its own Codex Responses shim in:

- `pi-extensions/pi-codex-minimal-tools/src/provider-shim.ts`

It already retries `429`, `500`, `502`, `503`, and `504` internally, but after the final failed attempt it throws a `NonRetryableProviderError` using only parsed/friendly message text. The resulting assistant `errorMessage` can lose the numeric HTTP status.

#### Change

Update final non-OK SSE response handling so thrown messages include status:

```text
HTTP 429: You have hit your ChatGPT usage limit (...)
HTTP 503: <provider message>
```

Implementation target:

- In `parseErrorResponse`, either return `status` or accept status in caller.
- In the final non-retry branch around `throw new NonRetryableProviderError(...)`, prefix with `HTTP ${response.status}:` if not already present.
- Preserve friendly usage-limit text after the prefix.
- Avoid double-prefix if upstream body already starts with `HTTP <n>`.

#### Tests

Add/adjust tests under `pi-extensions/pi-codex-minimal-tools/tests/`:

- Unit test for formatting helper if extracted.
- Integration-style provider-shim test where final HTTP 429 body becomes assistant `errorMessage` containing `HTTP 429`.
- Same for HTTP 503 or 500.
- Ensure successful retries still do not surface intermediate failures.

Likely commands:

```bash
cd pi-extensions/pi-codex-minimal-tools
npm test
```

If package scripts differ, inspect `package.json` first.

#### Risk

Low. User-visible error text changes only on terminal provider failure. Retry classifier compatibility improves.

### Phase 9 — Responsive row count for `pi-skills-manager`

#### Problem

Pi 0.75.1 fixed core config selector row counts to scale to terminal height. Several vstack overlays already do this, including `pi-extension-manager`, `pi-session-manager`, `pi-qol` session search, `pi-flightdeck`, and `pi-agents-tmux` browser views.

`pi-skills-manager` currently sets a fixed browse list budget from settings:

- `pi-extensions/pi-skills-manager/extensions/skills-manager/dialog.ts`
- `DEFAULT_LIST_ROWS = 14` in `constants.ts`

On short terminals, the list can consume too much overlay space.

#### Change

Clamp visible browse rows to available terminal height.

Implementation options:

1. Add `maxPopupRows()` / `responsiveListRows()` on `SkillsManagerDialog`, using `this.tui.terminal.rows` and the existing overlay max-height ratio/settings.
2. Keep configured `listRows` as an upper bound.
3. Let list collapse to at least 1 row on tiny terminals.
4. Use responsive row count for page up/down and render slice centering.

Pseudo-shape:

```ts
private responsiveListRows(): number {
  const terminalRows = Number(this.tui.terminal?.rows ?? process.stdout.rows ?? 30);
  const safeRows = Number.isFinite(terminalRows) && terminalRows > 0 ? terminalRows : 30;
  const chromeRows = /* frame + search + spacers + footer + headers budget */;
  return Math.max(1, Math.floor(safeRows * 0.86) - chromeRows);
}

private get visibleListRows(): number {
  return Math.min(this.listRows, this.responsiveListRows());
}
```

Then replace `this.listRows` in browse paging/render slicing with `this.visibleListRows`.

#### Tests

Add tests if current package has harnessable render tests. If not, add focused pure helper tests by extracting responsive row math.

Manual smoke:

```bash
# Launch Pi in short terminal or force tmux pane small.
/skills
# Verify browse list stays inside overlay and footer remains visible.
```

#### Risk

Low. Only reduces visible rows on short terminals. Large terminals preserve configured `listRows`.

### Phase 10 — Optional Codex fast/spark fixture cleanup

#### Problem

Pi 0.75.1 removed non-working OpenAI Codex fast variants. vstack code does not depend on those runtime model IDs.

One test fixture in `pi-codex-minimal-tools` uses a text-only Codex sample named `gpt-5.3-codex-spark`:

- `pi-extensions/pi-codex-minimal-tools/tests/capabilities.test.ts`

This is only a fixture for a text-only Codex model. It is not a runtime selection list.

#### Change

Optional cleanup only:

- Rename fixture variable `spark` to `textOnlyCodex`.
- Change fake ID to neutral future-proof value such as `codex-text-only-fixture` or `gpt-5.5-text-only-fixture`.
- Keep assertion intent: image generation/view image disabled when model lacks image input, while `apply_patch` remains enabled for Codex provider.

#### Tests

```bash
cd pi-extensions/pi-codex-minimal-tools
npm test
```

#### Risk

Very low. Test-only clarity improvement. Not required for runtime correctness.

### Phase 11 — Reposition `pi-flightdeck` docs/policy

#### Current state

Before Phase 11, stale docs said `pi-flightdeck` was deprecated for new sessions because the Rust dashboard in `skills/flightdeck/lib/flightdeck-dashboard/` has feature parity and is canonical.

That policy is superseded by this plan.

#### Change

Keep policy:

- `pi-flightdeck` is not deprecated.
- `pi-flightdeck` is not a dependency of the Flightdeck skill.
- `pi-flightdeck` is optional Pi UI support for Flightdeck.
- The Rust app remains the canonical full Flightdeck UI.
- On this branch, `pi-flightdeck` keeps Pi-native inline status features and `/flightdeck` Rust app focus/open integration.
- New full-dashboard feature work belongs in the Rust app / Flightdeck skill, not in a Pi popup.
- Bug fixes and compatibility work are allowed when the Pi inline status integration needs them.

#### Documentation follow-up

Update docs and metadata called out in Phase 6.6 so no current user-facing README/catalog says `pi-flightdeck` is deprecated or required.

#### Tests

Run the Pi extension tests and focus/open checks when changing the status-shell integration.

### Phase 12 — No-op confirmations for upstream-only fixes

These Pi 0.75.1 changes need no vstack code change now, but record why so future sessions do not churn.

#### Anthropic-compatible `ANTHROPIC_AUTH_TOKEN`

No action.

- `pi-claude-bridge` registers a custom `streamSimple` provider with `apiKey: "not-used"`.
- It drives Claude Code through Claude Agent SDK, not Pi's Anthropic-compatible API-key path.
- No `ANTHROPIC_AUTH_TOKEN` dependency found in vstack extensions.

#### Bedrock unknown content blocks

No action.

- No Bedrock message converter owned by vstack Pi extensions.
- Pi core owns provider conversion.

#### OpenCode Go Kimi `reasoning_content`

No action.

- Flightdeck treats OpenCode as harness adapter metadata and text/question source.
- No vstack code replays OpenCode Go reasoning fields.

#### Xiaomi MiMo metadata/endpoints

No action.

- No vstack extension owns Xiaomi/MiMo provider metadata.
- Pi model registry handles this.

#### Node 26 compressed fetch / undici globals

No action.

- `pi-web-tools` uses global `fetch` in provider/extract paths.
- Pi core fix should cover compressed fetch behavior at runtime.
- Do not vendor a second fetch/polyfill unless a reproducible extension-only failure appears.

Optional regression smoke for `pi-web-tools` on Node 26:

```bash
cd pi-extensions/pi-web-tools
npm test
```

And manual:

```text
web_fetch a compressed JSON/HTML URL and verify no JSON parse failure from compressed body.
```

#### Windows npm package command splitting

No action.

- `pi-extension-manager` already uses `spawnSync(command, args, { cwd })` for npm update/uninstall.
- It avoids shell string execution for actual process launch.
- Display strings use shell quoting only for UI descriptions.

Optional Windows smoke:

- Configure `npmCommand` path with spaces.
- Use `/extensions` update/uninstall flow on a test package.
- Verify process launches without argument splitting.

### Validation bundle if executing Pi 0.75.1 code changes

Run focused package tests:

```bash
cd pi-extensions/pi-codex-minimal-tools && npm test
cd ../pi-skills-manager && npm test
```

If package has no `npm test`, inspect `package.json` and run equivalent node/bun test command.

Run broader safety checks if touching shared Flightdeck or extension manager code:

```bash
cd cli && cargo test
```

For any change under `skills/flightdeck/lib/flightdeck-core/`:

```bash
cd skills/flightdeck/lib/flightdeck-core
bun test
bun run typecheck
```

For Rust dashboard changes:

```bash
cd skills/flightdeck/lib/flightdeck-dashboard
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
cargo insta test
```

### Documentation updates when implementing Pi 0.75.1 work

If Phase 8 changes user-visible Codex error output, update:

- `pi-extensions/pi-codex-minimal-tools/README.md` only if behavior needs user explanation.
- Tests are probably enough; no README change required for internal error-prefix hardening.

If Phase 9 changes skills manager sizing/settings behavior, update:

- `pi-extensions/pi-skills-manager/README.md` settings text only if `listRows` semantics are documented there.
- Otherwise tests/comments are enough.

If any Pi extension behavior changes:

1. Commit intended package changes.
2. Run `vstack refresh -g` after commit for global Pi install refresh.
3. Report commit hash and refresh result.

### Suggested Pi 0.75.1 execution order

1. Phase 8 Codex HTTP-status prefix — highest value, aligns with Pi retry classifier fix.
2. Phase 9 Skills Manager responsive rows — direct UX parity with Pi config selector fix.
3. Phase 10 fixture cleanup — optional, quick clarity cleanup.
4. Phase 11 docs/policy change travels with Phase 6.6 because it changes `pi-flightdeck` positioning.
5. Leave Phase 12 as documented no-op decisions unless new evidence appears.

## Acceptance criteria

- Terminating a Flightdeck run clears active state and dashboard shows no active run/history view.
- Continuing the same Pi/tmux chat after termination does not show an archived run as if it were active.
- Starting a new tracked delegation in the same tmux session creates a fresh run.
- Rust dashboard History UI can browse previous runs and snapshots from a keybind-opened popup; `flightdeck-state run list/show` remains durable CLI inspection.
- Archived views are clearly read-only and cannot perform live mutations.
- Existing `tmp/flightdeck-state-*.json.archive` files remain viewable/importable.
- Rust dashboard sessions with only terminated archives show no-active/history instead of active archived rows. Current Pi mini-dashboard/status shell may still render legacy terminated archive fallback as inactive/status-only data; it must not present those archives as active supervised work or Pi-native History UI.
- Manual prune remains available for pane-gone entries in active live runs, but archived runs are never auto-pruned.
- On PR #167 after the PR #166 merge, the Pi extension no longer contains the old `/flightdeck` popup/prune UI; `/flightdeck` delegates to Rust app focus/open and `/flightdeck:toggle` still cycles the mini-dashboard.
- Current pi-flightdeck has no Flightdeck-specific tool output renderer, so no tool renderer code must be preserved in this cleanup.
- Rust app focus/open command, app-window icon/default naming, and automatic app launch ordering are merged PR #166 behavior on this branch, not pending PR #167 work.
- Pi 0.75.1 extension follow-ups are either implemented with focused tests or explicitly left as documented no-op decisions.
- `pi-codex-minimal-tools` terminal provider errors preserve HTTP status codes for retry classification.
- `pi-skills-manager` browse rows clamp to terminal height without breaking large-terminal configured row counts.
- Optional Codex text-only fixture cleanup, if done, changes only test names/IDs and not runtime behavior.
- Tests cover lifecycle, migration, Rust dashboard rendering, History popup/import/active-return flows, Settings popup/catalog interactions when dashboard env defaults change, Pi status-shell focus/open behavior, tmux app placement, and read-only/settings-write safety. Pi-native History/archive browsing remains out of scope unless a later Pi feature implements it.
- After Flightdeck merges a PR, the primary local `main` checkout is either fast-forwarded to `origin/main` or Flightdeck clearly reports why sync was blocked and what operator choice is needed; never reset the kind of divergent local-main state observed after the cleanup session (`ahead 8, behind 9`).
- After any implementation PR is merged, local `main` is fetched and fast-forwarded or a blocking sync reason is recorded before the work is called complete.
- Closed daemon issue #151 stays treated as regression context: daemon/run-history work must capture fresh diagnostics and open/update a new issue if a similar daemon exit appears.

## Validation plan

Run at minimum:

```bash
git diff --check
cd skills/flightdeck/lib/flightdeck-core && bun test && bun run typecheck
cd skills/flightdeck/lib/flightdeck-dashboard && cargo fmt --check
cd skills/flightdeck/lib/flightdeck-dashboard && cargo clippy --all-targets --all-features -- -D warnings
cd skills/flightdeck/lib/flightdeck-dashboard && cargo test
cd skills/flightdeck/lib/flightdeck-dashboard && cargo insta test
cd pi-extensions/pi-flightdeck && bun test
cd skills/flightdeck && tests/live-wake.sh --no-tmux
```

For live validation when feasible:

```bash
cd skills/flightdeck && tests/live-wake.sh
```

## Execution workflow

Use the Flightdeck skill to run this plan. Treat this as required process, not suggestion:

1. Create every implementation worktree with the worktree skill script:
   ```bash
   skills/worktree/scripts/worktree create <id>
   ```
   Do not use raw `git worktree add`. Put scratch briefs, intermediate JSON, and handoffs under `<worktree>/tmp/`, not at the worktree root.
2. Start a tracked Flightdeck workflow pane in that worktree before implementation work.
3. Keep the local base in sync before work starts: fetch `origin`, verify branch ancestry, and record whether local `main` is clean/current. If local `main` is dirty, ahead, or diverged, resolve or record the blocker before claiming work is ready.
4. Implement phases in order unless a dependency requires reordering; record any reorder in the PR description.
5. Run reviewer cycles before final validation:
   - architecture review
   - test review
   - documentation review
   - security/performance review when touched code makes those relevant
6. For every valid reviewer finding, re-delegate the fix to the implementation pane or fix directly in the worktree when that is safer, then rerun the relevant tests.
7. Re-review fixes that address non-trivial findings. Do not stop at “fixed”; get the relevant reviewer/check to confirm no remaining blocker.
8. Run the final validation bundle and any package-specific tests from the affected phases.
9. Run docs checks: verify root README, affected package READMEs, `skills/flightdeck/README.md`, `SKILL.md`, `DEVELOPMENT.md`, and extension-manager metadata match behavior.
10. Open a PR with implementation summary, reviewer cycle summary, validation list, docs updates, and known no-op decisions.
11. Wait for CI and review results. Fix all valid CI/review findings, rerun relevant tests, and re-review as needed.
12. Merge the PR only after CI/reviews are green or explicitly waived by the operator.
13. Immediately after merge, keep local `main` in sync:
    - run `git fetch origin --prune`
    - fast-forward clean local `main` to `origin/main` when safe
    - never hard-reset, stash, discard changes, or force-push automatically
    - if local `main` is dirty/ahead/diverged/missing, stop and report the exact blocker plus suggested operator actions
14. Do not call the work complete until the merge is done and the local-main sync attempt has either succeeded or produced a clearly recorded blocker.
