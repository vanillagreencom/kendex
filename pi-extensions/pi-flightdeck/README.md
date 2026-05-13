# pi-flightdeck

> ⚠️ **WIP — not production ready.** APIs, settings, and UI may change without notice.

Read-only, sessions-first dashboard for the [`flightdeck`](../../skills/flightdeck) skill. When Pi runs as the Flightdeck master agent in a tmux session, this extension surfaces the same owner-scoped on-disk tracked-session state the daemon and master maintain — without ever mutating it.

## Highlights

- **Pause banner** — high-contrast yellow frame above the editor when flightdeck master pauses for the user. Clears automatically on resume.
- **Persistent dashboard widget** — compact tree of tracked sessions with state badges, kind badges, harness, last decision, age, and per-pane cost/turns/tokens. Issue-mode PR metadata appears only when a session carries `domain.issue`.
- **Expanded dashboard tree** — session details render as proper child rows, with ASCII or Unicode connectors matching the Tree connector style setting.
- **`/flightdeck` popup** (F6) — session-control view with six tabs: Overview, Live feed, Conversations, Conflicts & merges (issue mode), Decisions, Daemon. Conversations render as a newest-first stream keyed by tracked-session titles/names, hide raw pane ids from normal view, and collapse Pi streaming partials into one finalized turn. Decisions are selectable; press Enter to open the full wrapped answer, then Esc or Backspace to return.
- **Session-complete view** — once `terminate.md` flips master state to `terminated: true`, the dashboard and popup keep rendering the completed session. `buildSnapshot` falls back to the newest `flightdeck-state-<SESSION>-*.json.archive` whenever the live file is missing (it's renamed by `flightdeck-state archive`), so Overview shows the terminated banner + summary file path, Decisions retains the full log, and Conflicts & merges (issue mode) adds a `Merge history` panel (PR + merge commit + age) that outlives the now-drained `merge_queue`. The daemon-health chip is swapped for a green `✔ session complete` so the user does not read the intentional shutdown as an alarming `daemon dead`. Dismiss with `Alt+M`.
- Dashboard defaults to the Flightdeck owner pane only, using `owner.pane_id` from master state. Child panes remain suppressed, and `dashboardVisibility` can opt back into same-tmux-session or always-on rendering for observer workflows. Peer panes can still open the popup; the header says `Observer view (owner: %pane · cwd)` so owner scope is explicit.
- Participates in vstack's stable mini-dashboard stack order: Flightdeck → Tasks → Agents → BG tasks.
- Optional terminal bell and auto-popup when master pauses.

## Session rows

Rows use `title` first and fall back to `id`. Kind badges identify the tracked-session domain:

| Badge | Kind | Meaning |
| --- | --- | --- |
| `AH` | `adhoc` | Generic supervised harness session. |
| `ISS` | `issue` | Issue/PR/worktree session with `domain.issue` metadata. |
| `WF` | `workflow` | Managed workflow session. |

PR, worktree, scope, and merge metadata render only for `ISS` rows that carry a `domain.issue` block. The old TypeScript names `IssueRecord` and `IssueState` remain exported as `@deprecated` aliases for one release cycle; new extension code should use `TrackedSession` and `TrackedState`.

## Read-only by design

The flightdeck skill owns state mutation; the daemon owns wake delivery; `pane-respond` owns sending input to inner panes. pi-flightdeck only renders what's already on disk through the same normalized tracked-session seam (`TrackedSession` / `TrackedState`, backed by `.entries` with legacy `.issues` folded in). The skill works fine without this extension; it's purely additive UX for the Pi harness.

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
| `/flightdeck` | Open the session-control popup (also F6). |
| `/flightdeck watch [args]` | Legacy bridge workaround that dispatches the `flightdeck watch` workflow. The daemon now sends `/skill:flightdeck watch --from-daemon` through pi-session-bridge directly. |
| `/flightdeck:toggle` | Cycle the persistent dashboard widget (also Alt+M). |

Inside the popup, use Tab / Shift+Tab to switch tabs, arrows to move or scroll, `-/=` to page, and type to filter. Selected rows brighten muted metadata for contrast. Conversations and Live feed use compact streams with a wrapped selected-item preview; Enter opens the full retained turn/event with scroll. Live feed labels each row by managed tracked session and defaults to important events; Ctrl+N toggles noisy info/heartbeat rows. In Decisions, Enter opens a detail popup for the selected decision; the detail view wraps the full answer and scrolls with arrows/page keys. Esc or Backspace returns to the main Flightdeck popup. In Daemon, heartbeat runs are folded into one summary row so real daemon events stay visible while the log remains scrollable.

The popup is always openable from peer panes in the same tmux session. When the current pane is not `owner.pane_id`, the header says `Observer view (owner: %pane · cwd)` and the popup acts as a read-only observer view.

## Settings

All settings live in the extension manager under **Flightdeck Dashboard**.

### Dashboard

| Setting | What it does |
| --- | --- |
| Show dashboard widget | Render the persistent dashboard above the editor. |
| Dashboard visibility | Where the persistent dashboard may render: `owner` (default), `tmux-session` (legacy same-session behavior), or `always`. Child panes remain suppressed in all modes. |
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
| Popup shortcut | Default `f6`. |
| Dashboard cycle shortcut | Default `alt+m`. |

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
