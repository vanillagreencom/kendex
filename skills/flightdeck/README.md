# Flightdeck

Flightdeck supervises AI agent sessions in tmux windows. It can track generic panes, run Linear issue cycles, or run GitHub issue cycles while routing prompts, showing progress, and summarizing completion.

> AI agents using Flightdeck: read [`SKILL.md`](./SKILL.md). Contributors changing Flightdeck internals: read [`DEVELOPMENT.md`](./DEVELOPMENT.md).

## Features

- Start or attach tracked agent panes in their own tmux windows.
- Watch multiple sessions at once and route prompts back to the right pane.
- Run generic sessions with no issue tracker.
- Run Linear issue workflows with planning, PR checks, merge ordering, and closeout summaries.
- Run GitHub issue workflows with PR/CI/review handling and verified issue closeout.
- Pause for humans on risky choices: scope creep, force-merge, issue aborts, domain mismatch, or novel prompt shapes.
- Launch a terminal dashboard by default so sessions, prompts, PRs, activity, and costs stay visible.
- Recover from common stalls with watchdogs for missing child completions, idle panes, edit loops, and rate limits.

## Install

```bash
cd /path/to/your/project
vstack add vanillagreencom/vstack --skill flightdeck -y
```

Requirements:

- tmux 3.x; Flightdeck no-ops outside tmux.
- bash 4+, jq, flock, bun.
- One supported harness adapter for each tracked pane: Pi bridge, OpenCode HTTP, Claude Channels, Codex app-server, or tmux fallback.
- Linear issue mode: Linear auth plus GitHub auth for PR helpers.
- GitHub issue mode: `gh` authenticated against the target repo.
- macOS: GNU coreutils for `sha256sum` and GNU date.

## Commands quick reference

Run commands by asking your agent for `flightdeck <command>`.

### Session lane

| Command | Use when | Main args |
|---------|----------|-----------|
| `flightdeck session start` | Launch a new tracked pane. | `--session-id <ID> --title <T> --cwd <path> --harness <H> (--cmd <cmd> \| --prompt <text>)` |
| `flightdeck session attach` | Track an existing pane. | `--pane <%PANE_ID> --harness <H> --title <T>` |
| `flightdeck session watch` | Resume supervision for generic sessions. | `[ENTRY_ID...]` |
| `flightdeck session status` | Print tracked session state. | none |
| `flightdeck session stop` | Teardown a tracked entry. | `<ENTRY_ID>` |
| `flightdeck session remove` | Remove a tracked entry from state. | `<ENTRY_ID>` |

### Linear lane

| Command | Use when | Main args |
|---------|----------|-----------|
| `flightdeck linear start` | Start one Linear issue or choose one from main. | `[ISSUE_ID]` |
| `flightdeck linear start new` | Create a Linear issue, then start it. | `[title]` |
| `flightdeck linear start self` | Initialize master Linear issue session only. | none |
| `flightdeck linear parallel-check` | Check whether issues are safe to run together. | `[ISSUE_IDS]` |
| `flightdeck linear watch` | Resume Linear issue supervision. | `[ISSUE_IDS]` |
| `flightdeck linear merge-plan` | Recompute PR merge order. | none |
| `flightdeck linear close-issue` | Verify and close one issue workflow. | `<ISSUE_ID>` |
| `flightdeck linear terminate` | Summarize and unwind the Linear session. | none |

### GitHub lane

| Command | Use when | Main args |
|---------|----------|-----------|
| `flightdeck github start` | Start a numeric GitHub issue. | `<N> [--repo OWNER/REPO]` |
| `flightdeck github start new` | Create a GitHub issue, then start it. | `[title] [--repo OWNER/REPO]` |
| `flightdeck github watch` | Resume GitHub issue supervision. | `[N...]` |
| `flightdeck github close-issue` | Verify merged PR state, then close/no-op issue. | `<N>` |
| `flightdeck github terminate` | Summarize and unwind the GitHub session. | none |

## Settings users actually set

Most sessions work with defaults. These are the knobs users most often change.

| Variable | Default | Use when |
|----------|---------|----------|
| `FLIGHTDECK_AUTO_MERGE` | `1` | Set `0` to require human approval before merge or force-merge actions. |
| `FLIGHTDECK_AUTO_REBASE` | `0` | Set `1` in GitHub mode to allow safe auto-rebase/update-branch prompts. |
| `FLIGHTDECK_FORCE_MERGE_AFTER_SECS` | `240` | Change how long Flightdeck waits before considering force-merge for approved, green PRs stuck in GitHub `UNKNOWN` merge state. |
| `FLIGHTDECK_LAUNCH_MODEL` | unset | Default model for panes launched from `open-terminal` or `flightdeck-session --prompt`. |
| `FLIGHTDECK_LAUNCH_EFFORT` | unset | Default effort/thinking level for launched panes. |
| `FLIGHTDECK_OPENCODE_VALIDATE_MODEL` | `1` | Set `0` only when using local OpenCode shims that are not listed by `opencode models`. |
| `FLIGHTDECK_STATE_DIR` | `tmp` | Change where Flightdeck writes session state inside the project. |
| `FLIGHTDECK_DASHBOARD` | `1` | Set `0` to disable automatic dashboard launch. |
| `FLIGHTDECK_DASHBOARD_WINDOW` | `flightdeck` | Change the tmux window name used for the dashboard. |
| `FLIGHTDECK_DASHBOARD_THEME` | `moon` | Pick `moon`, `dawn`, `pantera`, or `system`. |
| `FLIGHTDECK_DASHBOARD_MOTION` | `full` | Pick `full`, `reduced`, or `off`; `NO_MOTION` and `NO_COLOR` also disable motion. |
| `FLIGHTDECK_DASHBOARD_BELL` | `1` | Set `0` to suppress terminal bell on pause-for-user. |
| `FLIGHTDECK_DASHBOARD_QUICK_FOCUS` | `0` | Set `1` to let dashboard `g` focus a tmux window without confirmation. |
| `FLIGHTDECK_DASHBOARD_PRICING_FILE` | bundled table | Point dashboard cost calculations at a custom pricing TOML. |
| `VSTACK_AGENT_END_WATCHDOG` / `VSTACK_STALL_WATCHDOG` / `VSTACK_EDIT_LOOP_DETECTOR` / `VSTACK_RATE_LIMIT_WATCHDOG` | `1` | Set any to `0` to disable that recovery watchdog. |

Full env reference: [`ENV.md`](./ENV.md).

## Dashboard

The terminal dashboard opens automatically when `FLIGHTDECK_DASHBOARD=1` (default). It shows tracked sessions, state, harness, PR/path, branch, age, last decision, activity, conversations, merge planning, daemon health, token/cost totals, and pause-for-user banners.

Useful commands:

```bash
flightdeck-dashboard tui                  # current tmux session, live
flightdeck-dashboard tui --session <name> # past or current session
flightdeck-dashboard tui --demo           # demo data
```

Useful keys:

- `?` — help.
- `T` — theme picker.
- `/` — filter.
- `Enter` — detail popup for selected row.
- `p` — pricing-source detail.
- `g` — focus selected pane, with confirmation unless quick focus is enabled.
- `D` — prune stale row, with confirmation.
- `Alt+M` — compact mode.

## High-level architecture

Flightdeck always runs inside one tmux session. The master agent owns the Flightdeck workflow and records tracked entries in a project-local state file. Each child agent runs in its own tmux window, never as a split of the active pane. Flightdeck talks to child panes through the best available native channel for that harness, with tmux as fallback. A daemon watches child panes and wakes the master only when there is work to do. The master classifies prompts, answers known safe shapes, pauses for risky or novel shapes, and updates state. Issue lanes add GitHub/Linear/worktree checks on top of the same session loop. The dashboard reads the same state and activity data the workflows already write; it does not replace the workflows.

```
user request
  -> master agent
  -> Flightdeck workflow
  -> tmux child windows
  -> daemon wake + prompt routing
  -> dashboard + final summary
```

## More docs

- AI agent operating rules: [`SKILL.md`](./SKILL.md)
- Full script reference: [`SCRIPTS.md`](./SCRIPTS.md)
- State and activity schema: [`SCHEMA.md`](./SCHEMA.md)
- Env reference: [`ENV.md`](./ENV.md)
- Watchdog reference: [`WATCHDOGS.md`](./WATCHDOGS.md)
- Prompt tag reference: [`PROMPT-TAGS.md`](./PROMPT-TAGS.md)
- Development and testing: [`DEVELOPMENT.md`](./DEVELOPMENT.md)
