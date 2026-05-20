# pi-flightdeck

Optional Pi UI support for the [`flightdeck`](../../skills/flightdeck) skill. The Rust app (`flightdeck-dashboard`) is the canonical terminal dashboard; this Pi extension adds inline status near chat plus a Pi popup opened with `/flightdeck` or the popup shortcut.

The Flightdeck skill and Rust dashboard work without this extension.

## Highlights

- **Pause banner** — yellow frame above the editor when Flightdeck master pauses for the user. Clears on resume.
- **Persistent mini-dashboard widget** — compact tree of active tracked sessions with state, kind, harness, last decision, age, and per-pane cost/turns/tokens.
- **`/flightdeck` popup** — opens the Pi session-control popup for overview, conversations, decisions, conflicts/merges, and daemon details from on-disk Flightdeck state.
- **Owner-scoped by default** — dashboard renders only in the Flightdeck owner pane. Child panes remain suppressed. Visibility is configurable.
- **Stale-pane guard** — standby/watch hints ignore state files whose tracked entries only point at tmux pane ids that no longer exist.
- Optional terminal bell when master pauses.
- Participates in vstack's stable mini-dashboard stack order: Flightdeck → Tasks → Agents → BG tasks.

## Behavior boundary

The Flightdeck skill owns workflow state mutation; the daemon owns wake delivery; `pane-respond` owns sending input to inner panes. pi-flightdeck renders active status from on-disk state. Its only write affordance is the existing popup stale-row prune action, which shells to the canonical `pane-registry remove <entry_id>` helper after an explicit keypress.

Terminated archives are not shown as active mini-dashboard state. Use the Rust dashboard for durable run History browsing and explicit archive/session inspection.

Dependency note: PR #165/#166 lifecycle and status-shell work is not implemented on this branch head. This package currently keeps the Pi popup; Rust-app focus/open delegation is future reconciliation work, not PR #167 behavior.

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
| `/flightdeck` | Open the Pi Flightdeck session-control popup. |
| `/flightdeck watch ...` | Dispatch the legacy Flightdeck watch bridge workaround. |
| `/flightdeck:toggle` | Cycle the persistent Flightdeck mini-dashboard widget. |

## Settings

Open `/extensions:settings`; settings appear under the **Flightdeck Status** tab.

### Dashboard

| Setting | What it does |
| --- | --- |
| Show dashboard widget | Render the persistent mini-dashboard above the editor. |
| Dashboard visibility | Where the persistent mini-dashboard may render: `owner` (default), `tmux-session` (any pane in the same tmux session), or `always`. Child panes remain suppressed in all modes. |
| Dashboard default state | Initial state: `hidden`, `compact`, or `expanded`. |
| Dashboard max sessions | Max tracked-session rows shown. |
| Dashboard stale-after (min) | Suppress the session tree with a one-line hint when the daemon is dead and the last poll is older than N minutes. `0` disables. |
| Tree connector style | `unicode` or `ascii`. |

### Pause banner

| Setting | What it does |
| --- | --- |
| Show pause banner | Render the pause-for-user banner. |
| Terminal bell on pause | Ring the bell when master first pauses. |

### Keyboard

| Setting | What it does |
| --- | --- |
| Dashboard cycle shortcut | Configurable; defaults to `alt+m`. Use `none` to disable. |
| Popup shortcut | Configurable; defaults to `f6`. Use `none` to disable. |

### Refresh

| Setting | What it does |
| --- | --- |
| Refresh interval | Poll rate for state files (ms). |
| Daemon state dir override | Override `FD_STATE_DIR` resolution. Leave empty for the default. |
| Master state dir (project-relative) | Directory inside the project root holding the master state file. Matches `FLIGHTDECK_STATE_DIR` (default `tmp`). |

If your project uses a non-default `FLIGHTDECK_STATE_DIR` or `FD_STATE_DIR`, set the matching extension setting so the mini-dashboard reads the right files. Daemon tuning env vars are owned by the Flightdeck skill — see its README.

## Out of scope

- No durable run History browser in Pi; use the Rust dashboard History popup.
- No daemon control.
- No multi-tmux-session aggregation.
- No Rust app focus/open command on this branch head; that belongs to the PR #165/#166 lifecycle/status-shell reconciliation.
