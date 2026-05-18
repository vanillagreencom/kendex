# pi-flightdeck

> **DEPRECATED for new sessions.** The Rust dashboard at `skills/flightdeck/lib/flightdeck-dashboard/` now has feature parity for everything this extension renders — structured activity rendering, rate-limit recovery surfacing, branch/entry binding, watchdog activity rows, the `(stale)` row annotation, responsive tabs, the Costs detail popup (`p`), Alt+M compact mode, theme picker swatch slots, conversations file-mode, and Unicode display-width — with native motion, file-watched live updates, and a daemon read-shim. Run `flightdeck-dashboard tui` (auto-launched by `workflows/linear/start.md`) instead. This extension remains supported for sessions that prefer in-pi mission control until parity is verified across all installs.

> ⚠️ **WIP — not production ready.** APIs, settings, and UI may change without notice.

Read-only, sessions-first dashboard for the [`flightdeck`](../../skills/flightdeck) skill. When Pi runs as the Flightdeck master agent in a tmux session, this extension surfaces the same owner-scoped on-disk tracked-session state the daemon and master maintain — without ever mutating it. The Live feed tab still tails the daemon log; the structured `flightdeck-activity-<session>.jsonl` sidecar is consumed by the Rust dashboard, which new sessions should prefer for the watchdog/branch/entry/recovery surfaces.

## Highlights

- **Pause banner** — yellow frame above the editor when flightdeck master pauses for the user. Clears on resume.
- **Persistent dashboard widget** — compact tree of tracked sessions with state, kind, harness, last decision, age, and per-pane cost/turns/tokens.
- **`/flightdeck` popup** — six tabs: Overview, Live feed, Conversations, Conflicts & merges, Decisions, Daemon.
- **Session-complete view** — keeps the completed session visible until you dismiss the widget.
- **Owner-scoped by default** — dashboard renders only in the flightdeck owner pane. Peer panes get a read-only observer popup. Child panes always suppressed. Visibility configurable.
- Optional terminal bell and auto-popup when master pauses.
- Participates in vstack's stable mini-dashboard stack order: Flightdeck → Tasks → Agents → BG tasks.

## Session rows

Rows use `title` first and fall back to `id`. Kind badges identify the tracked-session domain:

| Badge | Kind | Meaning |
| --- | --- | --- |
| `AH` | `adhoc` | Generic supervised harness session. |
| `ISS` | `issue` | Issue/PR/worktree session. |
| `WF` | `workflow` | Managed workflow session. |

PR, worktree, and merge metadata render only on `ISS` rows.

## Read-only by design

The flightdeck skill owns state mutation; the daemon owns wake delivery; `pane-respond` owns sending input to inner panes. pi-flightdeck only renders what's already on disk. The one exception is the explicit prune action on the Overview tab, which shells to `pane-registry remove <id>` for entries whose tmux pane is already gone. The skill works fine without this extension; it's purely additive UX for the Pi harness.

## Install

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
vstack add vanillagreencom/vstack --pi-extension pi-flightdeck --harness pi -y
```

Or globally:

```bash
vstack add vanillagreencom/vstack --global --pi-extension pi-flightdeck --harness pi -y
```

Restart Pi after installation.

## Commands

| Command | Action |
| --- | --- |
| `/flightdeck` | Open the session-control popup. |
| `/flightdeck watch [args]` | Legacy bridge workaround that dispatches the `flightdeck linear watch` workflow. The daemon now sends `/skill:flightdeck watch --from-daemon` through pi-session-bridge directly. |
| `/flightdeck:toggle` | Cycle the persistent dashboard widget. |

Peer panes get an observer view labelled with the owner pane id; the popup's own footer documents its keys.

## Settings

Open `/extensions:settings`; settings appear under the **Flightdeck Dashboard** tab.

### Dashboard

| Setting | What it does |
| --- | --- |
| Show dashboard widget | Render the persistent dashboard above the editor. |
| Dashboard visibility | Where the persistent dashboard may render: `owner` (default), `tmux-session` (any pane in the same tmux session), or `always`. Child panes remain suppressed in all modes. |
| Dashboard default state | Initial state: `hidden`, `compact`, or `expanded`. |
| Dashboard max sessions | Max tracked-session rows shown. The stored key remains `dashboardMaxItems`; old settings migrate automatically because only the label changed. |
| Dashboard stale-after (min) | Suppress the session tree with a one-line hint when the daemon is dead and the last poll is older than N minutes. `0` disables. |
| Tree connector style | `unicode` or `ascii`. |

### Pause banner

| Setting | What it does |
| --- | --- |
| Show pause banner | Render the pause-for-user banner. |
| Terminal bell on pause | Ring the bell when master first pauses. |
| Auto-open popup on pause | Open the popup once when master first pauses. |

### Keyboard

| Setting | What it does |
| --- | --- |
| Popup shortcut | Configurable. |
| Dashboard cycle shortcut | Configurable. |

### Popup

| Setting | What it does |
| --- | --- |
| Live feed lines | Daemon log + decisions retained in Live feed. |
| Conversation excerpt chars | Max chars of last assistant text per pane after duplicate streaming partials are collapsed. |
| Conversations turns kept | Recent assistant turns retained per pane; each pane renders as a tracked-session mini timeline. |

### Refresh

| Setting | What it does |
| --- | --- |
| Refresh interval | Poll rate for state files (ms). |
| Daemon state dir override | Override `FD_STATE_DIR` resolution. Leave empty for the default. |
| Master state dir (project-relative) | Directory inside the project root holding the master state file. Matches `FLIGHTDECK_STATE_DIR` (default `tmp`). |

If your project uses a non-default `FLIGHTDECK_STATE_DIR` or `FD_STATE_DIR`, set the matching extension setting so the dashboard reads the right files. Daemon tuning env vars (e.g. `FD_OC_BACKOFF_MAX_SEC`) are owned by the flightdeck skill — see its README.

## Out of scope

- No write actions. Forwarded user decisions go to master via normal Pi chat.
- No daemon control. Use `flightdeck-daemon start|stop|status|health` from the skill.
- No multi-tmux-session aggregation. Scope is the current `$TMUX` session.
