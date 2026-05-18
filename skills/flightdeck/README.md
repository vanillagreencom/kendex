# Flightdeck

Flightdeck supervises AI harness sessions in tmux windows. In core session mode it launches or attaches panes, tracks stable ids, routes prompts, and summarizes completion. Issue orchestration is a built-in domain mode layered on top: GitHub/Linear/worktree decisions, merge planning, and next-cycle recommendations.

> Agents reading this: you want `SKILL.md` instead. Hacking on flightdeck itself: see [`DEVELOPMENT.md`](./DEVELOPMENT.md).

## The problem

Running one agent at a time is fine. Running five at once is chaos — each one keeps stopping to ask questions, background tasks finish at odd times, and issue-mode merge order can turn into a guessing game. Flightdeck handles the supervisory layer so you can track generic sessions or spawn a whole issue cycle and walk away.

Activates only inside tmux and only when you ask for it (`flightdeck session start|attach` for core sessions, `flightdeck start` for issue workflows). Outside tmux it's a no-op.

## How it works

Flightdeck launches generic sessions with `flightdeck session start` (or `attach`) or issue agents with `flightdeck start`, always into their own tmux windows, then watches them in parallel. Each Flightdeck session launches/verifies the Rust dashboard by default; set `FLIGHTDECK_DASHBOARD=0` to opt out. Each agent talks to flightdeck through its native channel (Claude Code MCP, OpenCode HTTP, Pi bridge, Codex app-server) and falls back to tmux when a channel isn't available.

A background daemon detects when an agent has a question, the master agent classifies the prompt, auto-answers when there's a learned default, and pauses for the human when there isn't.

There are two modes per tracked entry:

- **Generic session mode** — structured questions, bash permission prompts, safe bounded choices, Pi background-task exits.
- **Issue mode** — adds GitHub/Linear/worktree decisions: cleanup, rebase, force-push, bot-review/CI recovery, merge planning, scope creep.

When all tracked entries are terminal, flightdeck writes a summary and hands control back.

## Reliability

Four watchdogs sit between the daemon and the spawned agents and recover from the most common failure modes without waking you:

- **agent-end watchdog** — if a subagent emits its end-of-turn event but never writes a completion outbox (an `agent_end` race), flightdeck synthesizes a `needs_completion` outbox after a short grace window so the parent agent is never left hanging on a phantom child.
- **idle-stall watchdog** — if a subagent has been bridge-idle for several minutes without producing an outbox, flightdeck synthesizes a `blocked` outbox so the parent agent moves on instead of polling forever.
- **edit-loop detector** — if a child agent fails the same edit tool repeatedly within a short window (default 5 failures in 120s), flightdeck synthesizes a `blocked` outbox so a stuck retry loop surfaces as an explicit failure.
- **rate-limit watchdog** — if the upstream Claude API rate-limits a child agent, flightdeck steers it to retry with exponential backoff (default ladder `60s → 120s → 300s → 600s → 1800s`, up to 5 attempts). Each retry surfaces as a `rate_limit_retry` activity row; an exhausted retry budget shows as `rate_limit_exhausted`.

Each watchdog is independently toggleable via its `VSTACK_*` env var. Daemon hygiene knobs (`FD_BELL_WAKE_INTERVAL_SEC`, `FD_RECONCILE_INTERVAL_SEC`, `FD_HEARTBEAT_OWNER_CGROUP`) similarly default to safe values and only need tuning in unusual setups. See `SKILL.md` for the full table and `DEVELOPMENT.md` for canonical decision modules and parity rules.

If the daemon's master pane disappears (master agent crash, accidental window kill), the daemon writes a structured `fd-daemon-recovery-<session>.json` breadcrumb under `FD_STATE_DIR` before exiting. Re-launch the master from the same cwd and run `flightdeck session watch` to resume; `flightdeck-state archive` rolls the state file if you want to abandon the session instead.

## Activation and termination

- **Activates** on `flightdeck session start|attach` for generic tracked sessions, or `flightdeck start` for issue workflows, from inside tmux.
- **Pauses** for you on: scope creep that wants reverting, force-merging against a real content conflict, an issue abort, a `main` mutation that needs human OK, domain mismatch, or a novel prompt shape no rule covers. Sets `paused_for_user` in state and stops polling. Resume by running `session watch` or issue `watch` again.
- **Terminates** automatically when every tracked entry is terminal for the relevant mode. Generic-only sessions write a session summary with no GitHub/Linear/worktree calls. Issue sessions write the issue summary, archive the state file, and hand control back.

## Ad-hoc sessions

Ask the agent to track an ad-hoc tmux window (a scratch Pi pane, a log tail, an extra worker) and it will call `flightdeck session start` or `flightdeck session attach` for you. Useful when you want supervision and a dashboard row but no issue/worktree wiring. See [`DEVELOPMENT.md`](./DEVELOPMENT.md) for the script flag reference.

Fresh LLM panes need an explicit launch profile. `flightdeck session start --prompt` accepts `--model` plus `--effort`/`--thinking` and translates them per harness: Pi uses `--model` + `--thinking`, Claude uses `--model` + `--effort`, Codex uses `-m` + `model_reasoning_effort`, and OpenCode validates `--model` with `opencode models` but records effort as unsupported because top-level `opencode` has no validated effort flag. If a custom command or attached pane cannot expose model/effort, the tracked entry records `launch.reasoning_status` and `launch.unsupported_reason` instead of pretending defaults were known.

## Issue workflows

Issue orchestration remains first-class when the session is tied to a Linear/GitHub/worktree domain. Ask the agent to start an issue, check a parallel group for safety, launch the group, watch the session, recompute merge order, or close out the session — it routes to the right flightdeck command for you.

The `github` skill ships `label-add` and `label-remove` wrappers around `gh pr edit` / `gh issue edit`. When flightdeck spawns a managed pane, those wrappers emit `pr.labeled` / `pr.unlabeled` / `issue.labeled` / `issue.unlabeled` activity rows alongside the existing `pr.*` events, so label-driven gates (`defer-ci`, custom workflow labels) show up in the activity sidecar and Rust dashboard.

The spawn path also auto-exports `FLIGHTDECK_ENTRY_ID` into every child pane and captures the worktree's current git branch as `entry.branch` (via `git rev-parse --abbrev-ref HEAD`). The Rust dashboard renders branch info in the right rail and Sessions table PR/worktree column (`<branch> · PR #N` for non-default branches), and `pr.*` activity rows are enriched with `refs.branch` via `gh pr view --json headRefName`. Child Pi sessions also advertise a unique `<parent>:c<pid>` session id (via `PI_BRIDGE_PARENT_SESSION_ID`) so cross-session activity does not collide with the parent.

## Install

```bash
cd /path/to/your/project
vstack add vanillagreencom/vstack --skill flightdeck -y
```

Core mode requires tmux only at the workflow/skill-dependency layer, plus the harness adapter you choose for a tracked pane (`pi-bridge`, OpenCode HTTP, Claude Channels, Codex app-server, or tmux fallback). It does not require GitHub, Linear credentials, project-management, or worktree setup.

Issue mode adds the optional `github`, `linear`, `worktree`, and `project-management` skills on demand for `flightdeck start <ISSUE>`, `start new`, `parallel-check`, `merge-plan`, `close-issue`, and issue termination/recommendation workflows.

Runtime requirements for the shipped core scripts remain `bash` 4+, `tmux` 3.x, `jq`, `flock`, and `bun` (https://bun.sh). Issue mode additionally needs the GitHub/Linear CLIs or auth wrappers used by those skills, plus normal git worktree support. Mac users: install GNU coreutils for `sha256sum` and GNU date.

## Rust dashboard

The Rust dashboard binary lives at `skills/flightdeck/lib/flightdeck-dashboard/`, with the user-facing trampoline at `skills/flightdeck/scripts/flightdeck-dashboard`. It is a ratatui view of the master state file: it renders tracked sessions, owner/observer status, pause/stale/archive/pre-purge banners, cross-harness cost/token totals, the Activity tab (formerly Live feed), conversations, decisions, merges, and daemon health. Live mode file-watches the state/archive/activity paths with debounced reloads; the optional Rust daemon adds a UDS JSON-RPC snapshot stream and Pi-only wake subscriber absorption. Mouse support covers tabs, rows, pause/banner chips, the daemon/theme/cost chips, footer hints, popup controls, and panel scrolling. The only write actions are confirmation-gated shells to canonical helpers: prune stale registry entries through `pane-registry remove` and focus a session through `tmux select-window`.

`flightdeck-dashboard launch` is the startup hook used by Flightdeck. It opens one tracked tmux window through `flightdeck-session start --kind workflow --harness shell`, registers `.entries.flightdeck-dashboard`, and skips cleanly outside tmux or when disabled. Idempotency is based on the live tracked dashboard pane; stale same-name windows no longer satisfy the launch check. Use `launch --theme moon|dawn|pantera|system` to forward a theme to the child TUI. It honors:

| Variable | Purpose |
| --- | --- |
| `FLIGHTDECK_DASHBOARD=0` | Exit `0` silently without launching the dashboard. |
| `FLIGHTDECK_DASHBOARD_WINDOW` | Tmux window name, default `flightdeck`. |
| `FLIGHTDECK_DASHBOARD_MOTION` | Motion level: `full`, `reduced`, or `off`; `NO_MOTION` / `NO_COLOR` force `off`. |
| `FLIGHTDECK_DASHBOARD_THEME` | Theme: `moon` (default Rose Pine Moon), `dawn`, `pantera` (Crush-inspired neon), or `system`; CLI `--theme` overrides it. |
| `FLIGHTDECK_DAEMON_RUST=1` | Opt into the Rust daemon wake side; default off keeps the canonical TypeScript daemon in charge of wake delivery. |
| `FLIGHTDECK_DASHBOARD_BELL=0` | Suppress the pause-edge terminal bell. |
| `FLIGHTDECK_DASHBOARD_COST_POLL_SECS` | Cost-source poll interval, default `5`. |
| `FLIGHTDECK_DASHBOARD_PRICING_FILE` | Override the bundled per-million-token pricing TOML; malformed files warn and fall back to bundled rates. |
| `FLIGHTDECK_DASHBOARD_QUICK_FOCUS=1` | Skip the focus confirmation popup for power users. Prune always requires confirmation. |
| `TMUX_PROBE_TTL` | Cached `tmux list-panes` stale-row probe TTL, default `5` seconds. |
| `FLIGHTDECK_DASHBOARD_STALE_WARN_SECS` / `FLIGHTDECK_DASHBOARD_STALE_DEAD_SECS` | Tune stale-chip thresholds. |

`flightdeck-dashboard tui --demo[=NAME]` runs compiled demo fixtures (`empty`, `one-adhoc`, `one-issue`, `mixed`, `terminated`, `paused`, `observer`, `conversations`, `no-issue`, `decisions`, `stale-mixed`). `tui --state-file <path>` reads a concrete master-state JSON file, and `tui --session <name>` resolves `<project-root>/<FLIGHTDECK_STATE_DIR>/flightdeck-state-<name>.json` (default state dir `tmp/`) with terminated-archive fallback. With neither flag inside tmux, the dashboard uses the current tmux session. Use `--theme moon|dawn|pantera|system` to select Rose Pine Moon, Rose Pine Dawn, Pantera neon, or terminal-system colors. `?` opens Help with the legend, `T` opens the theme picker (with `█bg █surface █accent █error` swatch slot labels), `/` opens the filter popup, `Enter` opens the selected session/decision/event detail popup, `p` opens the pricing-source detail popup from the Costs tab, `g` confirms focus for the selected pane, `D` confirms prune for stale rows, and `Alt+M` toggles compact mode. The tabs row collapses responsively at 140- and 110-column thresholds (full → shortened → narrow labels), and the base header drops `kind counts → uptime → cwd → daemon → master` in priority order before any mid-text clip. Stale rows render with a `(stale)` annotation when tmux reports the pane id is gone, and the right rail adds a `branch <name>` row plus a "Recent activity" panel for adhoc/workflow entries. File-mode (no live tmux session) populates the Conversations tab from activity events instead of leaving dead space, and Unicode display-width is honored across every view module so CJK and emoji rows align.

`flightdeck-state activity export --session <name> [--state-file <path>]` mirrors the existing `path` / `tail` / `append` source-of-truth resolution so post-mortem exports work without an active tmux session.

The legacy in-Pi dashboard extension remains documented in [`pi-extensions/pi-flightdeck/README.md`](../../pi-extensions/pi-flightdeck/README.md), but it is deprecated for new sessions. Prefer the Rust dashboard for new Flightdeck runs.

After `vstack add`, build the release binary with:

```bash
cd skills/flightdeck/lib/flightdeck-dashboard
cargo build --release
```

The script prefers `lib/flightdeck-dashboard/target/release/flightdeck-dashboard` and falls back to `cargo run --release` when the binary is absent.

## Pi dashboard (optional)

New sessions should prefer the Rust dashboard above. If your master agent runs in Pi and you still want in-editor mission control, the deprecated [`pi-flightdeck`](../../pi-extensions/pi-flightdeck/README.md) extension remains available as a read-only overlay — pause banner, persistent dashboard above the editor, `/flightdeck` popup with six tabs. The skill works identically with or without it.

```bash
vstack add vanillagreencom/vstack --pi-extension pi-flightdeck --harness pi -y
```

## Settings worth knowing

Most users never touch these. The ones that occasionally matter:

| Variable | What it does |
| --- | --- |
| `FLIGHTDECK_AUTO_MERGE` | Set to `0` to require a human OK on every merge instead of auto-handling the obvious case. Useful for compliance-sensitive repos or big-blast-radius PRs. |
| `FLIGHTDECK_FORCE_MERGE_AFTER_SECS` | How long flightdeck waits before force-merging a PR that's approved + green but stuck in GitHub's `UNKNOWN` merge state (default 4 minutes). |
| `FLIGHTDECK_LAUNCH_MODEL` / `FLIGHTDECK_LAUNCH_EFFORT` | Default model + thinking level for spawned agents / `flightdeck-session --prompt` when the user doesn't pass them explicitly. |
| `FLIGHTDECK_OPENCODE_VALIDATE_MODEL` | Keep `1` to require `opencode models` to list the selected OpenCode provider/model before launch; set `0` only for local smoke shims. |
| `FLIGHTDECK_STATE_DIR` | Where flightdeck writes its session state file inside the project. Defaults to `tmp/`. |
| `FLIGHTDECK_ACTIVITY_FILE` | Override the activity JSONL sidecar path for wrapper/workflow emitters and `flightdeck-state activity append`. |
| `FLIGHTDECK_DASHBOARD` | Set to `0` to disable the Rust dashboard launch hook silently. |
| `FLIGHTDECK_DASHBOARD_WINDOW` | Tmux window name for the Rust dashboard launch hook. Defaults to `flightdeck`. |
| `FLIGHTDECK_DASHBOARD_MOTION` | Rust dashboard motion level: `full`, `reduced`, or `off`. `NO_MOTION` and `NO_COLOR` also disable motion. |
| `FLIGHTDECK_DASHBOARD_THEME` | Rust dashboard theme: `moon` (default), `dawn`, `pantera`, or `system`. CLI `--theme` wins over the env var. |
| `FLIGHTDECK_DAEMON_RUST` | Set to `1` to let `flightdeck-dashboard launch` start the Rust daemon; unset/`0` defers daemon ownership to the canonical TypeScript path. |
| `FLIGHTDECK_DASHBOARD_BELL` | Set to `0` to suppress the terminal bell on a new pause-for-user edge. The dashboard never auto-focuses tmux windows. |
| `FLIGHTDECK_DASHBOARD_COST_POLL_SECS` | Rust dashboard cost-source poll interval (default `5`). |
| `FLIGHTDECK_DASHBOARD_PRICING_FILE` | Path to a pricing TOML override for dashboard cost calculations. |
| `FLIGHTDECK_DASHBOARD_QUICK_FOCUS` | Set to `1` to make `g` focus without confirmation. |
| `TMUX_PROBE_TTL` | Stale-pane probe cache TTL in seconds (default `5`). |
| `FLIGHTDECK_DASHBOARD_STALE_WARN_SECS` | Rust dashboard stale-warning threshold in seconds (default `30`). |
| `FLIGHTDECK_DASHBOARD_STALE_DEAD_SECS` | Rust dashboard stale/dead threshold in seconds (default `300`). |
| `FLIGHTDECK_PI_ACTIVITY_BROKER` | Set to `0` to disable `pi-session-bridge` `vstack_activity` broker consumption and rely on legacy Pi wake messages only. Default `1`. |
| `VSTACK_AGENT_END_WATCHDOG` / `VSTACK_STALL_WATCHDOG` / `VSTACK_EDIT_LOOP_DETECTOR` / `VSTACK_RATE_LIMIT_WATCHDOG` | Set any to `0` to disable that watchdog. Defaults are `1`. Tuning knobs (`*_GRACE_SEC`, `*_THRESHOLD_SEC`, `*_THRESHOLD_N`, `*_WINDOW_SEC`, `*_MAX_ATTEMPTS`, `*_BACKOFF_LADDER`) live in `SKILL.md`. |
| `FD_BELL_WAKE_INTERVAL_SEC` | Per-pane-per-tag bell-wake rate-limit window (default `60`). Lower it only if you genuinely want more bells per minute. |
| `FD_RECONCILE_INTERVAL_SEC` | Mid-session reconcile cadence in seconds (default `5`). The daemon spawns subscribers for newly tracked panes and reaps subscribers for departed panes on this interval. |
| `FD_HEARTBEAT_OWNER_CGROUP` | Set to `0` to skip the optional `MemoryCurrent`/`MemoryPeak` cgroup probe in heartbeat events. Default `1`. |
| `FLIGHTDECK_ENTRY_ID` | Auto-exported by `flightdeck-session start` to spawned panes; binds `refs.entry_id` on github/linear/label activity rows. Do not set by hand. |

Activity history lives beside the master state as `<FLIGHTDECK_STATE_DIR>/flightdeck-activity-<session>.jsonl`. `flightdeck-state activity path|append|tail|export` exposes the path, writes normalized activity rows, tails recent rows, or exports JSONL/Markdown. Event families include tracked entries (`entry.*`), agents (`agent.*`), background tasks (`bg_task.*`), PRs (`pr.*`), Linear writes (`linear.*`), questions, and daemon/subscriber lifecycle rows. Pi sessions also append activity-only rows from the `pi-session-bridge` activity broker (`vstack_activity`) when enabled. `flightdeck-state archive` archives the activity JSONL next to the master-state archive.

Daemon-private files live outside your project under `$XDG_RUNTIME_DIR/flightdeck` (fallback `/tmp/flightdeck-$UID`) so they don't show up in commits.

Daemon tuning (`FD_*` env vars) is documented in [`DEVELOPMENT.md`](./DEVELOPMENT.md). Defaults work for normal use.

## Out of scope

- Flightdeck does not abort issues for you — only you can.
- Flightdeck does not respawn dead panes.
- Flightdeck operates within one tmux session at a time. Multiple sessions are independent.
- Flightdeck does not bypass the parallel-safety check that orchestration runs before spawn. If that check says no, flightdeck doesn't override.
