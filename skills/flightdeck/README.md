# Flightdeck

Flightdeck supervises AI harness sessions in tmux windows. In core session mode it launches or attaches panes, tracks stable ids, routes prompts, and summarizes completion. Issue orchestration is a built-in domain mode layered on top: GitHub/Linear/worktree decisions, merge planning, and next-cycle recommendations.

> Agents reading this: you want `SKILL.md` instead. Hacking on flightdeck itself: see [`DEVELOPMENT.md`](./DEVELOPMENT.md).

## The problem

Running one agent at a time is fine. Running five at once is chaos — each one keeps stopping to ask questions, background tasks finish at odd times, and issue-mode merge order can turn into a guessing game. Flightdeck handles the supervisory layer so you can track generic sessions or spawn a whole issue cycle and walk away.

Activates only inside tmux and only when you ask for it (`flightdeck session start|attach` for core sessions, `flightdeck start` for issue workflows). Outside tmux it's a no-op.

## How it works

Flightdeck launches generic sessions with `flightdeck-session` or issue agents with `open-terminal`, always into their own tmux windows, then watches them in parallel. For each tracked pane it picks the cleanest available communication channel:

| Harness | How flightdeck talks to that agent |
| --- | --- |
| Claude Code | Localhost HTTP channel server (MCP push) + transcript tailing |
| OpenCode | Direct HTTP session API |
| Pi | Unix-socket bridge speaking JSON line by line |
| Codex | JSON-RPC over WebSocket against `codex app-server` |

When a channel isn't available, flightdeck falls back to reading the agent's terminal text via tmux and typing replies as keystrokes. It works, but native channels are always preferred.

A small background daemon polls the agent panes a few times a second, detects when an agent has something to ask, classifies the prompt against a library of known shapes, and wakes the master agent. The master either auto-answers (most prompts have a learned default) or pauses for the human.

The watch layer is split into two modes:

- **Generic session mode** (`workflows/session-watch.md` + `session-handle-prompt.md`) tracks any tmux-window entry and handles only domain-neutral prompts such as structured questions, bash permission prompts, safe bounded choices, terminal completion, and Pi background-task exits.
- **Issue mode** (`workflows/watch.md` + `handle-prompt.md`) extends the generic loop with GitHub/Linear/worktree decisions: cleanup, rebase, force-push, bot-review/CI recovery, audit relations, merge planning, scope creep, and descope actions.

Issue-only prompt tags on ad-hoc sessions are guarded as `domain-mismatch`: Flightdeck logs a warning, takes no destructive action, and asks the master/user how to proceed. Missing kind now fails closed by default, and lookup misses should pass `--entry-kind-unknown`; legacy issue callers must explicitly opt in with `--allow-missing-kind` while they migrate.

When tracked entries are terminal, Flightdeck writes a summary and hands control back. Generic-only sessions get a local session summary. Sessions with any issue entries keep the issue/PR/new-issue recommendation summary; mixed sessions include both.

## Activation and termination

- **Activates** on `flightdeck session start|attach` for generic tracked sessions, or `flightdeck start` for issue workflows, from inside tmux.
- **Pauses** for you on: scope creep that wants reverting, force-merging against a real content conflict, an issue abort, a `main` mutation that needs human OK, domain mismatch, or a novel prompt shape no rule covers. Sets `paused_for_user` in state and stops polling. Resume by running `session watch` or issue `watch` again.
- **Terminates** automatically when every tracked entry is terminal for the relevant mode. Generic-only sessions write a session summary with no GitHub/Linear/worktree calls. Issue sessions write the issue summary, archive the state file, and hand control back.

## Ad-hoc sessions

Existing issue workflows (`start`, `start new`, `parallel-check`) are unchanged; ad-hoc sessions are additive.

Use `flightdeck-session` when you need Flightdeck to track a tmux window that is not tied to an issue/worktree workflow.

Launch a managed ad-hoc Pi session:

```bash
skills/flightdeck/scripts/flightdeck-session start \
  --session-id scratch-pi \
  --title "Scratch Pi" \
  --cwd "$PWD" \
  --harness pi \
  --prompt "Investigate this repo and report risks" \
  --kind adhoc
```

Launch any command in a new tracked tmux window:

```bash
skills/flightdeck/scripts/flightdeck-session start \
  --session-id logs-1 \
  --title "Log watcher" \
  --cwd "$PWD" \
  --harness shell \
  --cmd "tail -f tmp/app.log"
```

Attach an existing Pi pane without launching a new window:

```bash
skills/flightdeck/scripts/flightdeck-session attach \
  --pane %33 \
  --harness pi \
  --title "Manual Pi"
```

All starts use `tmux new-window` (never split panes), set `FLIGHTDECK_MANAGED=1` and `FLIGHTDECK_CHILD_PANE=1` in the launched command environment, capture stable `pane_id`/`window_id` metadata, and register through `pane-registry init-entry`. `pane-registry list --format json` returns normalized entries for both ad-hoc sessions and legacy issue rows. `session watch` uses the generic session loop; issue `watch` layers merge/PR workflow logic on top.

## Issue workflows

Issue orchestration remains first-class when the session is tied to a Linear/GitHub/worktree domain. It uses the same tracked-session underlay, then adds issue selection, worktree launch, PR prompt handling, merge planning, and recommendation summaries.

Start one issue session:

```bash
flightdeck start CC-123
```

Check and launch a safe parallel issue group:

```bash
flightdeck parallel-check CC-123 CC-456 CC-789
flightdeck start CC-123 CC-456 CC-789
```

Resume issue supervision or recompute merge order:

```bash
flightdeck watch
flightdeck merge-plan
```

## Install

```bash
cd /path/to/your/project
vstack add vanillagreencom/vstack --skill flightdeck -y
```

Core mode requires tmux only at the workflow/skill-dependency layer, plus the harness adapter you choose for a tracked pane (`pi-bridge`, OpenCode HTTP, Claude Channels, Codex app-server, or tmux fallback). It does not require GitHub, Linear credentials, project-management, or worktree setup.

Issue mode adds the optional `github`, `linear`, `worktree`, and `project-management` skills on demand for `flightdeck start <ISSUE>`, `start new`, `parallel-check`, `merge-plan`, `close-issue`, and issue termination/recommendation workflows.

Runtime requirements for the shipped core scripts remain `bash` 4+, `tmux` 3.x, `jq`, `flock`, and `bun` (https://bun.sh). Issue mode additionally needs the GitHub/Linear CLIs or auth wrappers used by those skills, plus normal git worktree support. Mac users: install GNU coreutils for `sha256sum` and GNU date.

## Pi dashboard (optional)

If your master agent runs in Pi, install the [`pi-flightdeck`](../../pi-extensions/pi-flightdeck/README.md) extension for a live mission-control overlay — pause banner, persistent dashboard above the editor, `/flightdeck` popup with six tabs. It's read-only; the skill works identically with or without it.

```bash
vstack add vanillagreencom/vstack --pi-extension pi-flightdeck --harness pi -y
```

## Settings worth knowing

Most users never touch these. The ones that occasionally matter:

| Variable | What it does |
| --- | --- |
| `FLIGHTDECK_AUTO_MERGE` | Set to `0` to require a human OK on every merge instead of auto-handling the obvious case. Useful for compliance-sensitive repos or big-blast-radius PRs. |
| `FLIGHTDECK_FORCE_MERGE_AFTER_SECS` | How long flightdeck waits before force-merging a PR that's approved + green but stuck in GitHub's `UNKNOWN` merge state (default 4 minutes). |
| `FLIGHTDECK_LAUNCH_MODEL` / `FLIGHTDECK_LAUNCH_EFFORT` | Default model + thinking level for spawned agents when the user doesn't pass them explicitly. |
| `FLIGHTDECK_STATE_DIR` | Where flightdeck writes its session state file inside the project. Defaults to `tmp/`. |

Daemon-private files live outside your project under `$XDG_RUNTIME_DIR/flightdeck` (fallback `/tmp/flightdeck-$UID`) so they don't show up in commits.

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

## Patterns

The `patterns/` directory documents the decisions the master agent makes — *when* to skip a bot review, *how* to handle a rebase prompt, *when* to force-merge — so future maintainers (human or AI) understand the reasoning, not just the code.

| Pattern | What it covers |
| --- | --- |
| `tmux-monitoring.md` | How flightdeck reads panes and the per-harness native channels. |
| `prompt-handlers.md` | The library of prompt shapes and how each gets answered. |
| `conflict-detection.md` | How merge order is planned around file-level conflicts. |
| `decision-biases.md` | Judgment heuristics: smaller-first, scope creep detection, rule of three. |
| `claude-channels.md` | Claude Code's MCP channel adapter. |
| `opencode-questions.md` | OpenCode's structured question API. |
| `pi-questions.md` | Pi's structured question API. |

## Scripts

You don't run any of these by hand in normal use — the skill calls them.

- `open-terminal` — launches issue worktree tmux windows with the chosen harness.
- `flightdeck-session` — launches or attaches generic tracked tmux sessions without fake issue ids.
- `flightdeck-state` — reads/writes the session's master state file, including schema `1.1` tracked-entry normalization (`tracked-entries`, `write-entry`).
- `flightdeck-daemon` — background poller; wakes the master.
- `pane-registry`, `pane-poll`, `pane-respond` — pane tracking and IO.
- `prompt-classify` — pattern-matches agent output against known prompt shapes and guards issue-only tags on non-issue entries as `domain-mismatch`.
- `pr-conflict-graph`, `parallel-groups` — issue-mode merge-order planning.
- `codex-app-server-spawn` / `-stop` — Codex bridge server lifecycle.

See [`DEVELOPMENT.md`](./DEVELOPMENT.md) for the full script list with descriptions.

## Out of scope

- Flightdeck does not abort issues for you — only you can.
- Flightdeck does not respawn dead panes.
- Flightdeck operates within one tmux session at a time. Multiple sessions are independent.
- Flightdeck does not bypass the parallel-safety check that orchestration runs before spawn. If that check says no, flightdeck doesn't override.
