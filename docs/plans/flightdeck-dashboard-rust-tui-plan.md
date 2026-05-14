# Flightdeck Dashboard — Rust/ratatui Implementation Plan

Source main: `/mnt/Tertiary/dev/vstack/main`
Worktree: `/mnt/Tertiary/dev/vstack/trees/flightdeck-dashboard-rust` (recommended; create when work begins)
Branch: `flightdeck-dashboard-rust`
Date: 2026-05-14

Companion plan: [`flightdeck-rich-activity-events.md`](./flightdeck-rich-activity-events.md). The Activity tab in this dashboard is the host for that plan; it lands here, not in the Pi extension.

## Mission

Build a first-class, fast, polished standalone terminal dashboard for the `flightdeck` skill, in Rust with `ratatui`, that lives inside the flightdeck skill itself and is harness-agnostic. Long term, this app **absorbs every responsibility currently split across `pi-extensions/pi-flightdeck` and the bash/TS `flightdeck-daemon`**, leaving the skill with workflow markdown, helper scripts, and this binary. The TUI runs in its own tmux window alongside whatever harness the user is driving (Pi, Claude Code, OpenCode, Codex).

Engineering, not patching. Where existing bash/TS interfaces no longer fit the new architecture, rewrite or reshape them cleanly. Preserve user-visible Flightdeck behavior and cross-harness support.

## Status update (2026-05-14, post-reframe + #27 baseline)

`origin/main` already includes the work this plan must build on:

- **Schema 1.1 + TrackedEntry seam** (PR #26). Master state has `schema_version: 1.1`, `.entries` (kind-aware tracked sessions), `.issues` (legacy projection), an `owner` block, plus `merge_queue` / `conflict_graph` for issue-mode. `readTrackedEntries` (TS) is the normalization seam — the Rust reader produces the same shape.
- **Owner block + visibility** (PR #25). `owner` has `harness`, `pane_id`, `pane_target`, `cwd`, `pid`, `pi_session_id`, `pi_bridge_socket`, `discovery_error`. The Rust TUI is its own tmux window so the gating differs — see [Owner / observer awareness](#owner--observer-awareness).
- **Generic launcher** (PR #28). `skills/flightdeck/scripts/flightdeck-session start|attach` is the canonical entry for tracked tmux windows. The dashboard registers itself the same way when launched managed.
- **Generic watch + handler split** (PR #29). `workflows/session-watch.md` is the generic loop; `workflows/watch.md` is the issue-mode layer. The dashboard reflects both — generic sessions get a session summary, issue sessions get the full PR/Linear/worktree story.
- **Issue-mode dependency isolation** (PR #30). `terminate.md` routes by tracked-entry kinds; `session-summary.ts` handles generic vs issue summaries. The dashboard's termination panel mirrors that routing.
- **Sessions-first Pi UI** (PR #31). `pi-flightdeck` already migrated to kind badges (`AH`/`ISS`/`WF`), `readTrackedEntries`, and the `state-archive.ts` / `state-normalizers.ts` / `render-terminated.ts` / `session-ui.ts` / `dashboard-visibility.ts` modules. These are the reference for what the Rust UI must render.
- **TrackedEntry-aware set-state + teardown** (PR #33). `pane-registry teardown-entry` requires terminal state; `set-state` dual-updates `.entries` and `.issues`. The dashboard never mutates state directly in Phase 1; later phases shell to these.
- **bg-task wake metadata** (PR #34). `pi-extensions/pi-background-tasks` writes wake records with `eventAt`, monotonic `sequence`, `notifyMode`, `dedupeKey`, `voidedWakes` / `voidedWakeSequences`, and a `cleared-on-task-exit` diagnostic. The dashboard's event feed consumes these without re-deduping.
- **pi-agents-tmux split** (PR #35). `subagent/` is now `index.ts` (wiring), `runner.ts`, `dispatch.ts`, `sessions.ts`, `wait.ts`. Per-pane agent stats are exposed at `globalThis[Symbol.for("vstack.pi.agents")]` only when running inside Pi.
- **Per-skill DEVELOPMENT.md docs** exist for orchestration, flightdeck, pi-agents-tmux, pi-background-tasks. New dashboard developer notes belong in `skills/flightdeck/DEVELOPMENT.md`.
- **Adhoc/generic session lifecycle gaps closed** (PR #41, commit `a7f29e7`). `pane-respond` accepts `%pane_id` stable ids and surfaces specific failures (`registry_read | not_registered | missing_pane_target`); `pane-registry teardown-entry` accepts generic terminal states (`complete | cancelled` in addition to legacy `merged | aborted | dead`); `pane-registry remove` drops both `.issues[]` and `.entries[]`; Pi subscriber drains open `pi-questions` on attach + on `bridge_hello` re-drain to close the snapshot→subscribe race. The dashboard reads pane state via the same registry/state seam, so these behaviors are visible immediately; the Phase 2+ write paths use the now-symmetric teardown/remove vocabulary.
- **WORKTREE_MKDIRS env var** (PR #42, commit `1e98287`). `skills/worktree/scripts/worktree create` auto-creates project-relative dirs listed in `WORKTREE_MKDIRS` (default value in `.env.local.example`: `"tmp"`). Dashboard work uses `<worktree>/tmp/` for scratch (engineer task briefs, intermediate result JSONs, parity-test fixtures). Not at worktree root; not `/tmp/`.
- **Worktree info/exclude fix** (PR #43, commit `56b4990`). The harness-mirror symlinks (`.agents`, `.pi`, `.opencode`, `.codex`, `.cursor`, `.claude/agents`) the worktree skill lays down are now properly hidden via `<repo>/.git/info/exclude` (the common git-dir, not the per-worktree dir git ignores). `git status` is clean in a fresh worktree; `worktree remove` succeeds without `--force`. Earlier dashboard plan drafts that recommended `--force` cleanup are out of date.
- **Cross-shell launch + daemon lifecycle hardening** (PR #44, closes #39 + #40). Several pieces relevant to the dashboard's daemon absorption:
  - `flightdeck-session start --prompt` writes the prompt to a tempfile under `$XDG_RUNTIME_DIR/flightdeck/` and launches as `bash -c 'p=$(<tmp); rm tmp; exec env <kv> pi "$p"'`. No more `bash %q` `$'...'` quoting in user shells. The Rust dashboard's `launch` subcommand mirrors this approach when spawning the dashboard tmux window.
  - `tmux display-message -p '#{pane_id}'` is replaced everywhere with `${TMUX_PANE:-$(tmux display-message ...)}`. The Rust dashboard MUST read `$TMUX_PANE` from its own environment when self-registering as a tracked entry.
  - `flightdeck-daemon start` now validates `--master` via `pane_alive` and refuses a stale id with **exit code `4`** (distinct from generic usage/lock errors). The Rust daemon absorbs this contract.
  - On cleanup the bash/TS daemon writes a structured `daemon-exited` row to `EVENTS_FILE` (the file `flightdeck-daemon events` drains) with `reason` classification (`master-gone | signal-term | signal-int | other`). The Rust dashboard's Activity tab consumes this row as a canonical daemon-lifecycle event; the Rust daemon (Phase 5) MUST emit the same shape under `SESSION_LOCK`.
  - `--in-tmux-window` daemons are named `[fd] daemon-<session>` so operators don't accidentally close them. Rust daemon keeps the convention.
  - `pane-registry list --format inner-panes-live` filters to panes whose `pane_id` is currently in `tmux list-panes -a`. The Rust daemon's respawn-on-restart path uses this listing.
  - `workflows/session-watch.md` now documents the master respawn contract: on `flightdeck-daemon status` returning `no daemon` with live tracked entries, master MUST respawn with the `inner-panes-live` listing and handle exit codes (4 = retry with `$TMUX_PANE`; 1 = check status for raced-respawn; other = `daemon-respawn-failed`, no yield). The Rust dashboard's daemon-supervisor mode respects this contract.

The activity plan will add a `flightdeck-activity-<session>.jsonl` sidecar plus archive on terminate. The dashboard's Activity tab is the read site — scaffolded here, fully populated by the activity plan.

## Non-negotiable constraints

- **First action: create the worktree via the worktree skill, not raw `git worktree add`.** Run `skills/worktree/scripts/worktree create flightdeck-dashboard-rust` from the project root. This wires `.env.local`, harness mirror symlinks, bot identity, `WORKTREE_MKDIRS` (defaults to `tmp/`), and adds the proper `info/exclude` entries so `git status` and `worktree remove` work cleanly. Raw `git worktree add` skips all of it and will silently break agent tooling.
- Work in a vstack worktree. Do not touch `/mnt/Tertiary/dev/vstack/main` except to read.
- **Harness agnostic.** Flightdeck supports Claude Code, OpenCode, Pi, Codex. The dashboard works for all four. Pi-specific paths (`pi-bridge`, `pi.events`, `globalThis[Symbol.for("vstack.pi.agents")]`) are optional enrichment, never required.
- **Long-term goal: replace `pi-extensions/pi-flightdeck` entirely.** Until parity ships, the Pi extension stays installed. Once parity ships, it shrinks to a thin "focus dashboard window" shortcut or is removed.
- **Lives inside `skills/flightdeck/`.** No new top-level directory. The crate ships with the skill via `vstack add`.
- **One binary, all flightdeck runtime.** A single `flightdeck-dashboard` Rust binary owns the TUI, the daemon, the status CLI, and the launch helper. Workflow markdown and helper scripts (`pane-registry`, `pane-respond`, `flightdeck-session`, `flightdeck-state`) stay in the skill until they too can be cleanly absorbed.
- Spawn focused agents in new tmux windows for parallel work; manage from master via `pi-bridge` (or the master's harness adapter).
- Run autonomously through all phases; iterate with `reviewer-*` agents until clean.
- Do not stop until there is a working dashboard the user can look at.
- Do not delete `.bash` siblings under `lib/flightdeck-core/` while the legacy daemon is still canonical.
- Do not inspect or edit harness mirror directories (`.agents/`, `.claude/`, `.opencode/`, `.pi/`, `.codex/`).

## Crate selection

Architecture spine, all current as of 2026-05:

| Role | Crate(s) | Notes |
| --- | --- | --- |
| Terminal backend + render | `ratatui` (≥ 0.29) + `crossterm` (default backend) | Official `event-driven-async` template is the starting point. |
| Async runtime | `tokio` (`rt-multi-thread`, `macros`, `fs`, `signal`, `time`, `sync`, `process`, `net`) | Single multi-threaded runtime; mpsc for app events; broadcast for fan-out to listeners. |
| Input events | `crossterm::event::EventStream` via `tokio-stream` | Non-blocking, integrates with the same `select!` as everything else. |
| App architecture | Hand-rolled Elm-style: `Model`, `Msg`, `update(&mut Model, Msg) -> Vec<Cmd>` | Matches ratatui docs (The Elm Architecture page). Pure update, side effects out via `Cmd`. |
| Command dispatch | `tokio::sync::mpsc::UnboundedSender<Msg>` returned from effect futures | Standard pattern from the async-actions template. |
| File watching | `notify` + `notify-debouncer-full` | Debouncer collapses storms — no hand-rolled debounce needed. |
| CLI | `clap` v4 (derive) | Subcommands: `tui`, `daemon`, `status`, `supervise` (legacy alias), `launch`. |
| Serde | `serde`, `serde_json`, `serde_with` (for `chrono` interop) | Mirrors the TS schema 1.1 shape. |
| Time | `chrono` (`serde`, `clock`) | Already established in this repo's tooling; `jiff` is an option but unnecessary churn. |
| Errors | `color-eyre` for top-level binaries; `thiserror` for module errors | `unwrap` outside `main`/tests is a review blocker. |
| Logging | `tracing` + `tracing-subscriber` (env filter + `fmt`) + `tracing-appender` (rolling file) | TUI mode logs to file only (stderr would corrupt rendering). |
| Snapshots | `insta` + `cargo-insta`; `ratatui::backend::TestBackend` | Locked test terminal width (200×60) so snapshots aren't flaky. |
| Animation + motion | `tachyonfx` (ratatui org, 1.2k★) + lightweight progress widgets (`ratatui::widgets::Gauge`, `Sparkline`, custom braille spinners) | First-class, on by default. See [Animations and motion](#animations-and-motion). |
| Markdown rendering | `termimad` | Used only for decision detail / summary panels. |
| Daemonization | `nix` (`process`, `fs`, `signal`) for double-fork + setsid; or `daemonize` crate if the API stays minimal | Used when `flightdeck-dashboard daemon` is invoked with `--detach`. |
| Process supervision | `tokio::process::Command` with kill-on-drop and graceful `SIGTERM` then `SIGKILL` after grace | Mirrors existing daemon's child lifecycle. |
| IPC | Unix domain socket via `tokio::net::UnixListener`; JSON-RPC 2.0 line-delimited frames | TUI ↔ daemon. Simple, well-supported. |
| Sigwinch + signals | `tokio::signal::unix` (SIGTERM, SIGINT, SIGWINCH, SIGHUP) | Daemon traps SIGTERM for graceful shutdown; TUI re-renders on SIGWINCH. |

Frameworks deliberately not used:

- **No higher-level MVU wrapper** (`tui-realm`, `cursive`, etc.). Hand-rolled Elm-style state is ~300 lines and gives full control over performance and snapshot tests.
- **No GUI toolkits** (`iced`, `egui`). Deliverable is terminal.

## Architecture

### One process model, two modes, same binary

```text
flightdeck-dashboard tui          # render-only client
flightdeck-dashboard daemon       # long-lived poller + wake router (replaces flightdeck-daemon)
flightdeck-dashboard status       # one-shot health/version/info
flightdeck-dashboard supervise    # back-compat alias: spawn `daemon --detach` then exec `tui`
flightdeck-dashboard launch       # invoked by start.md; chooses the right mode and opens the tmux window
```

Single binary, multiple subcommands. Same Rust crate compiles into one executable.

Run-time topology in normal use:

```
              ┌──────────────────────────────────────────────────────┐
              │  flightdeck-dashboard daemon (detached, per-tmux)     │
              │   • polls panes via harness adapters                  │
              │   • drains subscriber JSONL streams                   │
              │   • appends master state mutations + wake events      │
              │   • exposes Unix socket: $FD_STATE_DIR/dashboard.sock │
              └─────────────────────────┬─────────────────────────────┘
                                        │  JSON-RPC over UDS
                                        │  (snapshot stream, control ops)
                                        ▼
              ┌──────────────────────────────────────────────────────┐
              │  flightdeck-dashboard tui (one per attached user)    │
              │   • renders the cockpit                              │
              │   • read-only in Phase 1; later writes shell to      │
              │     pane-registry / pane-respond / flightdeck-state  │
              └──────────────────────────────────────────────────────┘
```

Two TUIs can attach to the same daemon (e.g. user attached over SSH plus locally). Daemon survives every TUI exit. Daemon restart is idempotent — re-reads state from disk, re-subscribes adapters, re-arms watchers.

### Daemon absorption strategy (gated, reversible)

The existing `skills/flightdeck/scripts/flightdeck-daemon` (bash, ~2.5k lines) + `lib/flightdeck-core/src/daemon/*.ts` (TS port, ~4.5k lines) stays canonical until the Rust daemon proves out. Mirrors the existing `FLIGHTDECK_USE_TS` discipline:

- New env: `FLIGHTDECK_DAEMON_RUST=1` (default `0`) selects the Rust daemon. Default `0` means existing bash/TS daemon keeps starting; Rust daemon is opt-in until parity is proven.
- `flightdeck-dashboard launch` reads the env and picks the right daemon binary.
- Live wake parity tests (`skills/flightdeck/tests/live-wake.sh`) must pass under the Rust daemon before any default flip — same rule the TS port followed.
- Once parity is proven for one production cycle, flip the default to Rust, then deprecate bash/TS daemon a cycle later.

The Rust daemon is built up phase by phase: first a thin shim that watches state and republishes to TUI; then it absorbs subscriber loops one harness at a time (Pi first since the wake event surface is best documented post-PR #24); then wake routing; finally GC and the busy-state machine.

### Authority boundaries

Phase 1 TUI is **read-only**.

- `flightdeck` skill (workflow markdown) remains policy brain (spawn/watch/merge decisions).
- Rust daemon = poll/wake actuator (eventually replaces bash daemon).
- Rust TUI = render-only client.

Phase 2+ writes (gated behind explicit flags / confirmations):

- Respond to prompt → shell to `pane-respond`
- Resume master → send `/skill:flightdeck watch ...` through the master's harness adapter
- Restart daemon → daemon control over its own UDS socket
- Set terminal state → shell to `pane-registry set-state <id> <state>` (PR #33)
- Teardown window → shell to `pane-registry teardown-entry <id>` (PR #33; refuses non-terminal unless `--force`)
- Focus pane/window → `tmux select-window`

Write paths route through the same harness-neutral helpers the workflow markdown uses. No Pi-only write actions.

### Data sources

| Source | Path | Contract |
| --- | --- | --- |
| Master state (live) | `<project>/<FLIGHTDECK_STATE_DIR>/flightdeck-state-<TMUX_SESSION>.json` | `schema_version: 1.1`; `.entries` first, `.issues` folded in. Default `FLIGHTDECK_STATE_DIR=tmp`. |
| Master state (archive) | `<project>/<FLIGHTDECK_STATE_DIR>/flightdeck-state-<TMUX_SESSION>-*.json.archive` | Newest-first iteration; only `terminated: true` archives count. Mirror `readArchiveStrict`. |
| Daemon runtime state | `$FD_STATE_DIR`, default `$XDG_RUNTIME_DIR/flightdeck` (or `/tmp/flightdeck-$UID`) | Mode `0700`. Wake-event log, pending-events, daemon pid file, daemon log. |
| Daemon control socket | `$FD_STATE_DIR/dashboard.sock` (Rust daemon) | New IPC channel for TUI ↔ daemon. JSON-RPC line-delimited frames. |
| Pane registry | `pane-registry list --format json` | Same shape as `.entries` rows. |
| Activity sidecar (future) | `<FLIGHTDECK_STATE_DIR>/flightdeck-activity-<TMUX_SESSION>.jsonl` + matching `.archive` on terminate | Added by the activity plan. Live feed tab is the read site. |

Normalized snapshot exposed to the TUI render layer:

```rust
pub struct DashboardSnapshot {
    pub session_id: String,
    pub project_root: PathBuf,
    pub started_at: Option<DateTime<Utc>>,
    pub updated_at: DateTime<Utc>,
    pub terminated: bool,
    pub terminated_at: Option<DateTime<Utc>>,
    pub master_state_path: PathBuf,
    pub master_archive_error: Option<String>,
    pub owner: Option<OwnerBlock>,
    pub daemon: DaemonStatus,
    pub counts: KindCounts,
    pub sessions: Vec<TrackedSession>,
    pub merge_queue: Vec<String>,
    pub conflict_graph: ConflictGraph,
    pub paused_for_user: Option<PauseInfo>,
    pub recent_events: VecDeque<Event>,
    pub conversations: Vec<ConversationStream>,
    pub summary_path: Option<PathBuf>,
}

pub struct TrackedSession {
    pub id: String,
    pub title: String,
    pub kind: SessionKind,                  // Adhoc | Issue | Workflow
    pub state: SessionState,
    pub substate: Option<String>,
    pub harness: Option<String>,
    pub window: Option<String>,
    pub pane_target: Option<String>,
    pub pane_id: Option<String>,
    pub launch: LaunchInfo,
    pub adapter: AdapterMetadata,
    pub domain: Option<DomainBlock>,        // Issue: pr_number, worktree, scope, merge_commit, ...
    pub last_response_at: Option<DateTime<Utc>>,
    pub spawned_at: Option<DateTime<Utc>>,
    pub last_polled_at: Option<DateTime<Utc>>,
    pub decisions_log: Vec<DecisionEntry>,
    pub stats: PaneStats,                    // cost/turns/tokens — present where harness exposes them
}
```

Issue-domain fields live inside `DomainBlock::Issue { pr_number, worktree, scope_files_declared, scope_files_actual, merge_commit, … }`. Same shape `readTrackedEntries` returns.

### Crate layout

```text
skills/flightdeck/lib/flightdeck-dashboard/
  Cargo.toml                           # name = "flightdeck-dashboard"
  Cargo.lock
  src/
    main.rs                            # clap entry; routes to mode modules
    cli.rs                             # clap structs for each subcommand
    app/                               # Elm-style TUI
      mod.rs
      model.rs                         # AppState, Tab, UiFlags, modal state
      msg.rs                           # Msg enum (Tick, Key, Snapshot, Daemon, Error)
      update.rs                        # pure (model, msg) -> (model, Vec<Cmd>)
      command.rs                       # Cmd enum (RequestSnapshot, OpenDetail, RunShell, …)
      effects.rs                       # async runners for each Cmd
      view/
        mod.rs                         # tab routing + chrome
        overview.rs
        live_feed.rs                   # scaffolded for Activity plan
        conversations.rs
        merges.rs
        decisions.rs
        daemon.rs
        modals.rs                      # detail popups, help, filter, observer banner
      theme.rs                         # tokens (Color, Style, Modifier) + light/dark
      keymap.rs                        # central key bindings; help overlay reads from this
    state/                             # schema 1.1 readers
      mod.rs
      schema.rs                        # serde structs
      tracked_entries.rs               # readTrackedEntries equivalent
      archive.rs                       # newest-first valid-terminated archive iteration
      normalizers.rs                   # conflict_graph / decisions_log shape guards
    watcher/
      mod.rs                           # notify-debouncer-full glue
      coalesce.rs                      # in-flight reload guard
    daemon/                            # ABSORBED daemon (gated behind FLIGHTDECK_DAEMON_RUST)
      mod.rs
      lifecycle.rs                     # double-fork+setsid; pid file; restart-on-exit
      socket.rs                        # JSON-RPC over UDS
      subscribers/                     # one module per harness adapter
        mod.rs
        pi.rs
        claude.rs
        opencode.rs
        codex.rs
        tmux_fallback.rs
      wake.rs                          # canonical-tag classification + appendEvent
      busy.rs                          # master busy-lock state machine
      gc.rs                            # state file rotation / archive prune
    fixtures/                          # embedded demo snapshots
    tmux/                              # tmux helpers (window create, focus, list-panes)
    util/
      paths.rs                         # FLIGHTDECK_STATE_DIR / FD_STATE_DIR resolution
      logging.rs                       # tracing setup
  tests/
    snapshot_overview.rs               # insta snapshots: empty / one-adhoc / one-issue / mixed / terminated / pause-banner / observer
    snapshot_conversations.rs
    schema_round_trip.rs
    archive_fallback.rs

skills/flightdeck/scripts/flightdeck-dashboard   # bash trampoline: prefer prebuilt binary, fallback to cargo run --release
```

### Build / run / install

Trampoline rules (mirror existing flightdeck-core trampolines):

- Prefer a prebuilt binary at `lib/flightdeck-dashboard/target/release/flightdeck-dashboard`.
- Fall back to `cargo run --quiet --release --manifest-path lib/flightdeck-dashboard/Cargo.toml --` if cargo is on PATH.
- If neither path works, emit a clear stderr diagnostic and exit non-zero — failure is visible, not silent.

vstack install picks up the binary path the same way it picks up other skill scripts. `cargo build --release` after `vstack add` is the developer contract for v1. Release binary distribution is a follow-up if/when needed.

## TUI design (full pi-flightdeck parity)

The Rust TUI takes over every pi-flightdeck surface in its own tmux window. The mapping:

| pi-flightdeck surface | Rust TUI equivalent |
| --- | --- |
| Pause banner above editor | Status bar's pause chip + window-level border accent + optional terminal bell + optional `tmux select-window` auto-focus when master pauses |
| Persistent dashboard widget (compact tree) | The dashboard window itself is always "on"; an `Alt+M` collapsed view shrinks it to a compact tree if the user shares the pane |
| Six-tab popup (Overview / Live feed / Conversations / Conflicts & merges / Decisions / Daemon) | Six tabs in the TUI proper; same labels |
| Session-complete view (archive fallback) | Same `state-archive` semantics: newest-first iteration of `.json.archive` when live file is gone |
| Owner-scoped visibility | Owner block surfaced in status bar; observer banner if launched against a session with a different live owner pane |
| Kind badges (AH / ISS / WF) | Same badges, same colors |
| Conversations stream (newest-first, hides raw pane ids, folds Pi streaming partials) | Same |
| Conflicts & merges (issue mode) | Hidden when no `ISS` rows; auto-relabels to `Conflicts & merges (issue mode)` like the Pi popup |
| Decisions detail popup (Enter → wrapped answer, Esc/Backspace returns) | Same |
| Daemon tab with heartbeat folding | Same |
| Stable mini-dashboard stack order (Flightdeck → Tasks → Agents → BG tasks) | Not applicable (own window); the same vertical priority is used inside the Overview rail |
| Terminal bell + auto-popup on pause | Bell preserved; auto-popup becomes `tmux select-window` |

Tabs:

1. **Overview** — top status bar (session, owner pane, daemon health, elapsed, counts by kind+state, total cost/tokens). Left rail: groups by state. Center: session table with kind badge, state, harness, PR/worktree only on `ISS`, age, last decision, last activity. Right rail: selected session timeline / last prompt / last answer / worktree / PR / scope when applicable.
2. **Live feed → Activity** — daemon events, prompt detections, wake delivery, state changes, decisions. Bounded ring buffer. Phase 1 source: daemon log + pending wake events. Phase later: `flightdeck-activity-<session>.jsonl` from the activity plan.
3. **Conversations** — per-pane last prompt / assistant excerpts; newest-first; collapses Pi streaming partials; hides raw pane ids in normal view.
4. **Conflicts & merges** — merge queue, conflict graph, UNKNOWN-timer status, PR overlap hints. Auto-renamed `(issue mode)` and hidden when no `ISS` rows.
5. **Decisions** — `decisions_log` across all tracked sessions. Selectable; `Enter` opens wrapped answer detail; `Esc` / `Backspace` returns.
6. **Daemon** — daemon health, pid, event timestamps, stale indicators, restart hints. Heartbeat lines folded.

Keyboard (single keymap, surfaced by `?`):

| Key | Action |
| --- | --- |
| `Tab` / `Shift+Tab` | Switch tabs |
| `j` / `k` / `↑` / `↓` | Move selection |
| `-` / `=` | Page up / down |
| `Home` / `End` | First / last row |
| `Enter` | Expand detail |
| `/` | Filter sessions / events |
| `Ctrl+N` | Toggle noisy/important filter on Activity |
| `r` | Force refresh snapshot |
| `Alt+M` | Toggle compact / expanded layout |
| `?` | Help overlay |
| `q` / `Ctrl+C` | Quit TUI; daemon stays running |
| `e` (post-activity-plan) | Export current filtered view to `tmp/flightdeck-activity-view-<SESSION>-<ts>.md` |

Style:

- Full-screen alt-screen.
- Centralized theme tokens (`theme.rs`); no ad-hoc colors in views.
- Semantic state colors: green (merged/complete/healthy), yellow (prompting/paused/awaiting user), blue (waiting/running), red (dead/failed/stale, with a visible `ERR` token for accessibility), purple/cyan (harness/model accents).
- Borders and layout like mission control. Compact, dense, many sessions visible at once.
- Responsive layout — `≤ 100 cols` collapses the right detail rail; `≤ 80 cols` becomes single-column with header summary.
- Curated motion (on by default). Every transient state has a clear visual signal — see [Animations and motion](#animations-and-motion) for the catalog and reduced-motion policy.

Performance rules:

- TUI never polls tmux panes directly — that's the daemon's job.
- `notify-debouncer-full` debounces file events upstream (no hand-rolled debounce).
- Diff `DashboardSnapshot` before pushing render messages; equal → drop.
- Bounded ring buffers (default 500 events).
- View functions are pure; allocations stay outside the hot path.
- Snapshot tests run at fixed `TestBackend::new(200, 60)` so changes that ripple width-dependent text are caught.

## Animations and motion

Motion is curated, on by default, and uniformly cheap. Every transient state should have a visual signal so the cockpit feels live without making the user squint at static tables for changes.

Two budgets up front:

- **Per-frame cost.** All motion must fit inside a 16 ms render budget at 200×60 cells. The framerate target is 30 fps when something is animating; idle frames render only when the snapshot diff changes.
- **Token budget.** Animations only consume render cells they already own (badges, borders, status chip). They never repaint a full table just to animate one row.

Motion catalog (each is a small, named effect in `app/view/fx.rs` so it's a one-line add when a new surface needs it):

| Surface | Effect | When | Implementation |
| --- | --- | --- | --- |
| Spinners | Braille spinner (8-frame) on `working` / `submitting` / `prompting` rows | While a tracked session is in a transient state | Tick `Msg::AnimateTick` every 80 ms via `tokio::time::interval`; advance only animating rows. |
| Pause chip | Pulse the status-bar chip background between `Yellow` and `LightYellow` over 800 ms | Whenever `paused_for_user` is set | `tachyonfx::fx::hsl_shift` or hand-rolled `Style` lerp; pauses also fire the terminal bell once on entry. |
| Tab switch | 120 ms left/right slide-in plus 80 ms fade-in on the new tab body | On any `Tab` / `Shift+Tab` | `tachyonfx::fx::sequence(translate, fade_in)`; suppressed when reduced-motion is on. |
| Activity feed | New rows slide-in from below (60 ms) with a brief column-1 accent flash on importance ≥ `important` | New row arrives | Per-row enter effect; only the row's cells re-render. |
| State badge | Cross-fade between old and new color (200 ms) on `state_changed` | Detected via `DashboardSnapshot` diff | `tachyonfx::fx::fade_to`. |
| Selection cursor | Soft halo trail on j/k movement (90 ms decay) | Selection change | One-shot effect on the previously selected row. |
| Daemon health | Heartbeat blink on the daemon chip if `daemon.last_heartbeat_at` is fresh; solid otherwise | Live | 1 Hz blink only while the heartbeat is fresh; stale or dead states are static red with `ERR`. |
| Window dressing | Animated unicode border accents on the active tab (subtle moving caret) | Always while active tab focused | Single cell per frame; effectively free. |
| Terminate / archive | Fade-out (350 ms) on the status chip, then swap to a green `✔ session complete` chip with a sparkle effect | On `terminated: true` transition | Mirrors pi-flightdeck's session-complete chip from PR #23. |
| Wake delivery | Brief edge-glow on the master pane row when a wake event is delivered | On `daemon.wake_delivered` snapshot field bump | Single-row effect; one frame. |
| Long-running ops | `ratatui::widgets::Gauge` progress bar in modals for CI / bot review / archive operations when a known duration estimate is available; indeterminate "barber-pole" sparkline otherwise | While the modal is open | Two flavors of the same modal component; the daemon supplies progress info when it has it. |
| BG-task running | Per-row sparkline of recent output rate (bytes/sec, last 60 s) when notifyOnOutput is on | Live | Bounded ring buffer feeds `Sparkline`; ties directly into PR #34's wake metadata. |
| Errors | Red border flash (200 ms) + persistent red `ERR` token | On `Msg::Error` | One-shot effect plus persistent style; never blocks input. |
| Help overlay (`?`) | Crossfade in (120 ms) | On open | `tachyonfx::fx::fade_in`. |

Reduced-motion contract:

- `FLIGHTDECK_DASHBOARD_MOTION=full|reduced|off` selects intensity. Default `full`.
  - `full` — everything above.
  - `reduced` — spinners + state-badge cross-fade only; no slides, no halos, no pulses. Targets users on slow terminals, screen readers, or who just don't want movement.
  - `off` — disables every effect. Static rendering only.
- Honour `NO_COLOR` / `NO_MOTION` env vars as the system signal for reduced motion (treat either as `MOTION=off`).
- Reduced-motion mode must still surface the same information — pause is still visible as a yellow chip with text `PAUSED FOR USER`, even without the pulse. Motion enhances; it never replaces meaning.

Performance rules specific to motion:

- `Msg::AnimateTick` only fires when at least one effect is active. The runtime is idle (zero CPU) when nothing is animating.
- Effects use the same `Msg` channel as the rest of the app — no second runtime, no second render loop.
- All effects are deterministic functions of `(model, elapsed_since_started)` so snapshot tests stay reproducible by pinning the clock with a `now()` injection.
- Snapshot tests assert both `t=0` (effect starts) and `t=effect_duration + 16ms` (effect settles to the static end state). They never assert intermediate frames — too brittle.

## Owner / observer awareness

A standalone tmux-window TUI does not have the pi-flightdeck "render in every pane" problem. But the `owner` block still matters in two ways:

1. **Display.** Show `owner.harness · owner.pane_id · owner.cwd` in the status bar so a user joining via SSH or attaching to a different tmux session knows which pane is master.
2. **Observer mode.** If the dashboard is launched against a session that has a live owner pane different from the user's pane, the TUI runs read-only by default. Writes (Phase 2+) require `--owner` flag asserting "I am the owner pane", or routing the write through the daemon which checks owner identity.

The Rust TUI does *not* implement the `dashboardVisibility` setting — it is always on when launched.

## Workarounds the daemon owns (upstream Pi-core symptoms we don't wait on)

Upstream `@earendil-works/pi-coding-agent` issues we observed during the 2026-05 session that won't get fixed on our timeline. The Rust daemon is the right place to catch their symptoms because it already subscribes to `pi-bridge stream` for every tracked Pi inner-pane, regardless of what's running there.

- **Compact-then-empty `agent_end` (upstream print/json compaction races).** Tracked in vstack#38. Pi's `--mode json -p` runtime occasionally disposes the session after `session_compact` without persisting the post-compact assistant message. The bridge stream shows `session_compact → agent_end{content:[]}`. Work may have actually completed. The daemon detects this shape on tracked entries and emits a canonical wake tag `pi-empty-after-compact` (analogous to `pi-bg-task-exit` from PR #24). The Rust daemon's canonical wake MUST stay payload-compatible with `subagents:needs_completion { reason: "compact-then-empty", cwdSnapshot }` so master-loop handling does not need to distinguish source. Routed through the same domain-mismatch-style guard so it pauses for the user with a clear reason instead of silently appearing as a stall. Independent of — and complementary to — the pi-agents-tmux subagent-level workaround in vstack#38, which only sees bg subagent runs; the daemon variant catches any tracked Pi pane.
- **Late bg-task output wakes.** PR #34 already ships `voidedWakes` tracking in the extension. The daemon does not relay output wakes; it consumes `pi-bridge stream` directly. No additional workaround needed.
- **MCP-qualified tool name cold-start races.** The daemon does not call MCP tools, so unaffected. No workaround required at this layer.

## Daemon (absorbed) responsibilities

Final-state Rust daemon owns everything the bash/TS daemon owns today, plus the workarounds above:

- Subscriber lifecycles per harness adapter (Pi, Claude, OpenCode, Codex, tmux fallback) — including cold-start grace, exponential backoff after unchanged polls, subscriber restart on death.
- Drain `pi-bridge stream` (or each harness adapter's stream), classify canonical wake tags, append durable wake rows, wake master.
- `pi-bg-task-exit` canonical wake handling (PR #24).
- Domain-mismatch guard for issue-only tags on adhoc entries (PR #29).
- Master busy-lock state machine (`wake-pending`, `in-flight`, TTL-based revert).
- Cold-start grace, bell suppression during grace, pane fingerprint drift recovery.
- GC: rotate daemon log past size threshold, prune old `.archive` files past retention.
- Per-session pid file in `$FD_STATE_DIR` so restarts are idempotent.
- Control surface over the Unix socket (`status`, `restart`, `subscribe`, `tail`, `subscribe-snapshots`, `set-paused`).

The TUI consumes a `subscribe-snapshots` stream over the socket — every meaningful change ships a new `DashboardSnapshot` (or a diff frame, if profiling justifies it). No polling from the TUI side.

## Pi interplay

Long term: **the Rust dashboard replaces `pi-extensions/pi-flightdeck` entirely.**

Phased relationship:

1. **Now → parity.** Both ship. Users can disable `pi-flightdeck` via its extension manager setting once they trust the dashboard.
2. **Parity reached.** `pi-flightdeck` README marked deprecated; one-line hint at startup points at the Rust dashboard.
3. **Post-deprecation.** `pi-flightdeck` shrinks to a thin `/flightdeck` slash command that focuses the dashboard tmux window via `tmux select-window -t flightdeck`. Or it's removed and the skill points users straight at the binary.

`pi-bridge` remains useful as a subscriber transport for the daemon when the master harness is Pi. The dashboard does not require Pi. Cross-harness data plane is state files + daemon socket, never Pi APIs.

Enrichment hook (optional, best-effort): when the dashboard runs inside the same Pi session as the master, it can read `globalThis[Symbol.for("vstack.pi.agents")]` for richer per-pane stats. Absence does not degrade the dashboard.

## Launch integration

Update Flightdeck startup so the dashboard launches with a session.

- New env: `FLIGHTDECK_DASHBOARD=1` (default on inside tmux); `0` disables.
- `FLIGHTDECK_DASHBOARD_WINDOW=flightdeck` default window name.
- `FLIGHTDECK_DASHBOARD_MOTION=full|reduced|off` selects animation intensity (default `full`). See [Animations and motion](#animations-and-motion).
- `FLIGHTDECK_DAEMON_RUST=1` opts in to the Rust daemon. Default `0` keeps the existing bash/TS daemon canonical.

At session init:

1. `flightdeck-dashboard launch` is invoked from `workflows/start.md`.
2. It starts the appropriate daemon (Rust or legacy, per env). Daemon is detached, lives in `$FD_STATE_DIR`, idempotent on re-launch.
3. It opens a tmux window for `flightdeck-dashboard tui`, via `flightdeck-session start --kind workflow --harness shell --cmd '…'` so the dashboard window itself is a TrackedEntry and inherits `FLIGHTDECK_MANAGED=1` (PR #21).
4. Failure does not block Flightdeck — logs warning, continues.

The dashboard window is in the registry; it renders the registry too.

## Autonomous execution plan

The next session acts as master and runs this end-to-end.

Recommended agent split:

1. **Master agent (you)** — owns worktree, integration, task panel, commits, review cycles.
2. **Recon agent (one-shot)** — confirm Rust toolchain, inspect daemon CLI surface, dump exact JSON shapes the bash daemon writes today.
3. **Rust TUI agent (`rust` pane agent)** — crate skeleton, theme, Elm-style app, view modules, snapshot tests.
4. **State / watcher agent** — schema 1.1 readers, archive fallback, notify-debouncer-full glue.
5. **Daemon-port agent (later phases)** — port subscriber loops one harness at a time behind `FLIGHTDECK_DAEMON_RUST=1`.
6. **Integration agent** — script wrapper, launch integration, docs.
7. **Review agents** — `reviewer-arch`, `reviewer-test`, `reviewer-structure`, `reviewer-error`, `reviewer-doc`. Use distinct ephemeral `sessionKey` per dispatch (PR #35 default).

Autonomy rules:

- If a subagent stalls, steer once via `steer_subagent`, then continue or replace.
- If review finds issues, fix them; iterate until reviewers return `clean`.
- Local-fixture validation is primary; live tmux smoke is required; live Linear-connected smoke is optional.

## Phases

### Phase 0 — Setup and reconnaissance

Goals:

- Create worktree + branch via the worktree skill (mandatory — not raw `git worktree add`).
- Confirm Rust toolchain (`rustc ≥ 1.75`, `cargo`, `cargo install cargo-insta`).
- Inspect current daemon CLI (start/stop/status/events/health) so the Rust daemon mirrors the same surface — note the `daemon-exited` event shape in `EVENTS_FILE` (PR #44) and the `--master` exit-code `4` contract.
- Verify on-disk state shape against `lib/flightdeck-core/src/state/tracked-entry.ts`.
- Verify `<worktree>/tmp/` exists (auto-created by `WORKTREE_MKDIRS="tmp"`) and use it for any agent task briefs / result JSONs in subsequent phases.

Commands:

```bash
cd /mnt/Tertiary/dev/vstack/main
skills/worktree/scripts/worktree create flightdeck-dashboard-rust --from main
cd /mnt/Tertiary/dev/vstack/trees/flightdeck-dashboard-rust
ls -la tmp/                                  # confirm WORKTREE_MKDIRS materialized scratch dir
git status --short                           # should be empty (info/exclude fix from PR #43)
rustc --version
cargo --version
cargo install cargo-insta
find skills/flightdeck -maxdepth 3 -type f | sort
skills/flightdeck/scripts/flightdeck-daemon --help 2>&1 || true
```

Deliverables: confirmed crate path `skills/flightdeck/lib/flightdeck-dashboard/`, notes on daemon CLI parity.

### Phase 1 — Crate skeleton + demoable TUI

Goals:

- Create cargo crate.
- Wire `tokio` runtime + `crossterm` `EventStream` + ratatui's `event-driven-async` pattern.
- Elm-style app loop (`Model`, `Msg`, `update`, `view`).
- Theme tokens centralized.
- Six tabs scaffolded (Overview rendered first; the others show "coming soon" placeholders that still snapshot cleanly).
- `tui --demo` reads embedded fixtures: empty session, one-adhoc, one-issue, mixed, terminated, paused.
- Snapshot tests for every demo fixture at `TestBackend::new(200, 60)`.
- Script wrapper `skills/flightdeck/scripts/flightdeck-dashboard`.
- **Motion skeleton.** `Msg::AnimateTick`, effect registry in `app/view/fx.rs`, braille spinner + tab-switch slide-in landed and visible in the demo. `FLIGHTDECK_DASHBOARD_MOTION` env wired (full/reduced/off). Snapshot tests pin `t=0` and `t=settled` for every effect.

Success criteria:

```bash
cd skills/flightdeck/lib/flightdeck-dashboard
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
cargo insta test
cargo run --release -- tui --demo
```

The TUI is visually useful before any live integration.

### Phase 2 — State reader, normalizer, archive fallback

Goals:

- Serde types mirroring schema 1.1.
- `readTrackedEntries` equivalent: `.entries` first, project legacy `.issues`, fold into one map; never lose data.
- Archive fallback: newest-first iteration of `flightdeck-state-<session>-*.json.archive`; require `terminated: true` AND valid object root; mirror `readArchiveStrict`.
- Normalizers for `conflict_graph.edges` and `decisions_log` shapes.
- Fixtures covering: v1-only (`.issues`-only legacy), v2-only (`.entries`), mixed, malformed entry, blank archive, ENOENT archive dir, EACCES archive dir, every-candidate-malformed.

Success criteria:

```bash
cargo test --package flightdeck-dashboard --lib state::
flightdeck-dashboard tui --state-file <fixture>
```

### Phase 3 — File watcher + Live feed scaffolding

Goals:

- `notify-debouncer-full` on master state file and archive directory.
- Diff `DashboardSnapshot` before render; equal → drop.
- Bounded ring buffer for Live feed (Phase 1 source: daemon log tail + pending wake events).
- Stale indicators (configurable threshold; default 5 min for daemon).
- Activity-plan-ready: the Live feed view consumes a trait-shaped event source so swapping in the JSONL reader later is a struct addition, not a restructure.

Tests: rapid-edit no desync; stale indicator triggers; archive transition handled when live file disappears.

### Phase 4 — Daemon: read shim phase

Goals:

- `flightdeck-dashboard daemon --detach` runs a minimal daemon: reads master state, broadcasts `DashboardSnapshot` updates over UDS, exposes `status`/`health`/`tail` over the socket.
- Pid file in `$FD_STATE_DIR/dashboard-<TMUX_SESSION>.pid`.
- TUI talks to the daemon over the socket; falls back to direct file reads if no daemon is up.
- The bash/TS daemon keeps running as today — Rust daemon at this phase is *additive* and read-only.

Tests: socket round-trip, pid file lifecycle, daemon survives TUI exit, two TUIs attached to one daemon both render.

### Phase 5 — Daemon: subscriber absorption (gated)

Goals:

- Port Pi subscriber from `lib/flightdeck-core/src/daemon/subscribers/` to Rust (`subscribers/pi.rs`). Same canonical-tag set, same domain-mismatch guard (PR #29), same `pi-bg-task-exit` canonical wake (PR #24).
- Port Claude / OpenCode / Codex subscribers next.
- Tmux-fallback subscriber last.
- Wake routing (`appendEvent` semantics, dedup key, voided-wake handling per PR #34) ported with bash-parity tests.
- Busy-state machine and GC ported.

Gate: every flip of a subscriber to Rust requires the relevant `tests/live-wake.sh` (or its parity equivalent) green before merge. `FLIGHTDECK_DAEMON_RUST=1` is the opt-in; default stays off until the full subscriber set is green for one production cycle.

### Phase 6 — Launch integration

Goals:

- `flightdeck-dashboard launch` invoked from `workflows/start.md`.
- Reuses `flightdeck-session start --kind workflow --harness shell --cmd '…'` so the dashboard window is a TrackedEntry.
- Env toggles wired (`FLIGHTDECK_DASHBOARD`, `FLIGHTDECK_DASHBOARD_WINDOW`, `FLIGHTDECK_DASHBOARD_MOTION`, `FLIGHTDECK_DAEMON_RUST`).
- Daemon auto-starts when needed; idempotent across re-runs.
- Dashboard failure logs warning, does not block flightdeck startup.

### Phase 7 — Pi-flightdeck parity sign-off

Goals:

- Walk every pi-flightdeck surface from the parity table above; tick each off with a snapshot test or a live smoke screenshot under `docs/work-in-progress/`.
- Pause banner — verified visually.
- Auto-focus on pause — verified.
- Owner / observer banner — verified.
- Decisions detail popup — verified.
- Archive fallback render — verified.
- Conversations stream — verified.
- Conflicts & merges hide/show by kind — verified.

This phase explicitly does *not* remove `pi-extensions/pi-flightdeck`. It marks it deprecated in its README with a pointer at the Rust dashboard.

### Phase 8 — Local validation

```bash
cd skills/flightdeck/lib/flightdeck-dashboard
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
cargo insta test

cd skills/flightdeck/lib/flightdeck-core
bun test
bun run typecheck

bash skills/orchestration/tests/run-all.sh

cd cli && cargo test
```

### Phase 9 — Live tmux/Flightdeck smoke

- Spawn a real tmux session if not already inside one.
- Launch dashboard via the integrated path with `FLIGHTDECK_DASHBOARD=1`.
- Start a real Flightdeck adhoc session (`flightdeck-session start --kind adhoc --harness pi --prompt "stay idle"`).
- Confirm dashboard updates from real files; daemon-survives-TUI-exit holds.
- Master pauses → bell + auto-focus fire.
- `pane-registry set-state ... dead` → badge flips.
- `pane-registry teardown-entry ...` → row removed; window closed.
- Terminate flow archives state; dashboard switches to archive-read mode.

### Phase 10 — Optional cross-harness smoke

Repeat Phase 9 under at least one of: Claude Code master, OpenCode master, Codex master. Verify owner block harness rendering, kind badges, daemon subscriber lifecycles all work without Pi.

### Phase 11 — Reviews and hardening

`reviewer-arch` / `reviewer-test` / `reviewer-structure` / `reviewer-error` / `reviewer-doc` against the first live-working dashboard. Iterate until all return `clean`.

**Review cadence** (proven in PRs #41 and #44; use the same pattern here):

1. **Round 1 — architecture + error review in parallel.** Dispatch `reviewer-arch` and `reviewer-error` simultaneously (and `reviewer-test` / `reviewer-structure` if the surface warrants). Each returns a structured `<output_format>` JSON with `verdict`, `findings: [{commit, severity, summary, suggested_fix}]`, `notes`.
2. **Apply round-1 feedback as 1–3 grouped commits.** One commit per logical fix-cluster; reference the reviewer and finding in the commit body. Run `cargo test && cargo insta test && cargo fmt --check && cargo clippy --all-targets --all-features -- -D warnings` before each commit.
3. **Round 2 (if any review returned `changes-requested`).** Re-dispatch only the reviewers that flagged issues, against the round-1 fix commits. Continue until all return `approve` (typically 1–2 rounds; halt if a third round opens new blockers — escalate to master agent).
4. **`reviewer-doc` runs LAST.** Doc review checks SKILL.md drift, README user-facing hygiene (no engineering jargon), AGENTS.md rules still apply, pattern docs reflect new behavior. Apply its feedback as a single docs commit before opening the PR. Same `<output_format>` JSON shape.
5. **PR body summarizes the review chain.** Round counts, blocker/major/minor counts, files changed. The PR description is the audit trail.

Specific Rust review focuses (`reviewer-error`):

- No `unwrap`/`expect` outside `main`/tests.
- All `Result`s surfaced — no silent `let _ =`.
- Render path is panic-free; bounded buffers; no unbounded growth.
- Daemon lifecycle: SIGTERM → graceful close → SIGKILL after grace.

### Phase 12 — Docs and handoff

- `skills/flightdeck/README.md` — dashboard section + relation to pi-flightdeck.
- `skills/flightdeck/SKILL.md` — commands/env vars table.
- `skills/flightdeck/DEVELOPMENT.md` — new `## Rust dashboard` section: build, test, snapshot tests, fixtures, theme tokens, where to add a tab.
- `pi-extensions/pi-flightdeck/README.md` — repositioned as deprecated / optional.
- Root `README.md` — flightdeck blurb mentions the dashboard if catalog text changes.
- `cli/README.md` — if vstack install/refresh logic is touched.

Handoff includes: worktree path/branch, run commands (demo + live), validation summary, known limitations, follow-ups (activity tab from rich-activity plan, deprecation timeline for pi-flightdeck).

## Validation plan

Per-phase commands are in each phase block. Final validation chain:

```bash
# Rust dashboard
cd skills/flightdeck/lib/flightdeck-dashboard
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
cargo insta test

# Flightdeck core
cd skills/flightdeck/lib/flightdeck-core
bun test
bun run typecheck

# Orchestration shell tests
bash skills/orchestration/tests/run-all.sh

# Live wake parity (gated when Rust daemon subscribers come online)
FLIGHTDECK_DAEMON_RUST=1 bash skills/flightdeck/tests/live-wake.sh

# CLI
cd cli && cargo test
```

## Risks and guardrails

- **TUI must never panic.** Every fallible op in the render path is `Result<…>` or falls back to a clearly-rendered error chip.
- **File watcher event storms.** `notify-debouncer-full` upstream debouncing is non-optional.
- **Snapshot stability.** Lock `TestBackend::new(200, 60)`; no locale-dependent text.
- **Cross-platform notify.** macOS and Linux primary; document Mac inotify-equivalent caveats. Windows is best-effort, untested.
- **Cross-harness safety.** Nothing in this crate may `require!` pi-bridge / Pi state. Pi reads are `if let Some(…)` enrichment.
- **Daemon absorption is gated.** Do not default `FLIGHTDECK_DAEMON_RUST=1` until subscribers are parity-tested and `live-wake.sh` green for one production cycle.
- **No deletion of `.bash` siblings** while the legacy daemon is canonical.
- **Activity tab is scaffolded, not populated** in this plan — the JSONL reader comes with the activity-events plan.

## Proposed delivery order

1. Crate skeleton + theme + demo Overview + snapshot tests (Phase 1).
2. State reader + archive fallback + normalizers (Phase 2).
3. File watcher + Live feed scaffolding (Phase 3).
4. Daemon read shim + UDS snapshot stream + TUI ↔ daemon (Phase 4).
5. Daemon subscriber absorption (Pi → Claude → OpenCode → Codex → tmux fallback), gated (Phase 5).
6. Launch integration via `flightdeck-session start` (Phase 6).
7. Pi-flightdeck parity sign-off + Pi extension deprecation note (Phase 7).
8. Local validation + cross-harness smoke (Phases 8–10).
9. Review + hardening + docs (Phases 11–12).

## Motion delivery checklist

Does not need its own phase — each row is added alongside the surface it animates. Tracked here so reviewers can confirm none were skipped:

- [ ] Braille spinner on transient session states (Phase 1).
- [ ] Tab-switch slide+fade (Phase 1).
- [ ] Selection halo trail (Phase 1).
- [ ] State-badge cross-fade on `state_changed` (Phase 3, alongside file watcher).
- [ ] Pause-chip pulse + terminal bell (Phase 3).
- [ ] Activity feed row enter (Phase 3, scaffolded; populated by activity plan).
- [ ] Daemon-health heartbeat blink (Phase 4).
- [ ] Wake-delivery edge-glow (Phase 4).
- [ ] Terminate fade-out + `✔ session complete` swap (Phase 7 parity sign-off).
- [ ] BG-task output sparkline (alongside activity plan; uses PR #34 wake metadata).
- [ ] Long-running modal Gauge / indeterminate sparkline (Phase 6 or later, as modals are added).
- [ ] Error border flash (Phase 1 baseline; every modal/tab reuses it).
- [ ] Help overlay crossfade (Phase 1).
- [ ] Reduced-motion / `NO_MOTION` honoured for every effect.

## Definition of done

- Standalone ratatui dashboard binary at `skills/flightdeck/lib/flightdeck-dashboard/`.
- `flightdeck-dashboard tui --demo` runs and snapshot-matches across all six tabs and at least six demo fixtures.
- `flightdeck-dashboard tui` reads real Flightdeck master state with TrackedEntry-correct rendering, owner block awareness, archive fallback, and live updates within debounce.
- `flightdeck-dashboard daemon` runs detached; TUI talks to it over UDS; daemon survives TUI exit and is restart-idempotent. At minimum, the read-shim phase (Phase 4) is shipped; absorbed subscribers (Phase 5) may be gated and partial at v1 release.
- Flightdeck session startup opens the dashboard automatically when in tmux; failure to launch dashboard does not block Flightdeck.
- The dashboard does not depend on Pi. Verified by running with a non-Pi master in Phase 10 (or documented as deferred).
- Pi-flightdeck parity table fully ticked; pi-flightdeck README marked deprecated with a pointer at the dashboard.
- Snapshot + unit tests pass; clippy clean; cargo fmt clean; `reviewer-error` clean for panic/silent-failure surface.
- README / SKILL / DEVELOPMENT updated.
- The Live feed tab is structured so the activity-events plan can plug in its JSONL reader as a follow-up without restructure.
- Motion catalog from [Animations and motion](#animations-and-motion) is implemented per the delivery checklist; reduced-motion / `NO_MOTION` honoured; no animation pulls the idle loop above 0 % CPU.
- User has a concrete tmux window to look at.

## First commands for next session

```bash
cd /mnt/Tertiary/dev/vstack/main
.agents/skills/worktree/scripts/worktree create flightdeck-dashboard-rust --from main
cd /mnt/Tertiary/dev/vstack/trees/flightdeck-dashboard-rust
rustc --version && cargo --version
cargo install cargo-insta
cat docs/plans/flightdeck-dashboard-rust-tui-plan.md
```

Then create a task panel from the phases, spawn focused agents for the Rust + state + daemon workstreams, and start Phase 0 immediately.
