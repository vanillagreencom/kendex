# pi-qol

![QOL extension settings panel](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-qol/assets/settings-panel.png)

![Session search popup](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-qol/assets/session-search.gif)
![/context usage breakdown](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-qol/assets/context-usage.png)

Quality-of-life extension for Pi: compact statusline, multiline input, session naming and search, notifications, and a permission gate.

## Highlights

- Compact statusline with repo, branch, model, thinking level, and context percent.
- Newline-insert in the editor (multi-line drafts without auto-submit), with a fallback binding for terminals that can't distinguish the primary key.
- Sessions auto-name from your first prompt. `/rename` overrides anytime.
- `/search` browses previous sessions with snippet previews; the configured shortcut opens it instantly.
- `/context` shows a Claude-style context-window breakdown.
- `/handoff <goal>` drafts a focused prompt for a new session.
- Permission gate prompts before risky `bash` commands. Default match: `rm -Rf`.
- Notifications for ready, questions, blocked states, and task completion.
- Thinking timer next to collapsed `Thinking...` labels.
- Caveman badge and a mode-cycling shortcut when `pi-caveman` is loaded.
- Subagent-name badge in `pi-agents-tmux` child panes.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-qol):

```bash
pi install npm:@vanillagreen/pi-qol
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-qol --harness pi -y
```

Restart Pi after installation.

## Commands

| Command | Action |
| --- | --- |
| `/qol` | Open settings (or print status if extension-manager isn't installed). |
| `/qol notify-test` | Send a test notification. |
| `/rename [name]` | Set or show the current session's name. |
| `/qol:rename` | Regenerate the session name from the first prompt. |
| `/qol:rename:full` | Regenerate from the full conversation. |
| `/context` | Show context-window usage with category breakdown. |
| `/search [query]` | Open previous-session search. |
| `/search:refresh` | Refresh the session search cache. |
| `/handoff <goal>` | Draft a handoff prompt for a new session. |

Arguments support autocomplete.

## Settings

Open `/extensions:settings`; settings appear under the **QOL** tab. Names below match the labels shown there.

Glyph style: each package exposes `glyphStyle` (`unicode` default, `ascii` for terminal-safe chrome). `@vanillagreen/pi-tool-renderer.globalGlyphStyleOverride=ascii` forces ASCII chrome across vstack Pi extensions while leaving tool/model/user content unchanged.

### Statusline

| Setting | What it does |
| --- | --- |
| Enable QOL editor helpers | Master toggle for QOL statusline, commands, notifications, search, compaction, and editor helpers. |
| Replace built-in footer | Hide Pi's default footer while the QOL statusline is active. |
| Use π prompt editor | Use the compact prompt editor. |
| Show session name title | Show the session name above the prompt and in the tmux pane title. |
| Sync session name to tmux window name | Rename the tmux window to `π <session>`. |
| Input bottom padding | Blank lines below the prompt. |
| Show dirty marker | Append `*` to the branch when the worktree is dirty. |

### Input

| Setting | What it does |
| --- | --- |
| Newline-insert binding | Insert a newline instead of submitting. |
| Fallback newline binding | Alternate binding for terminals that can't send the primary one. |
| Style pending queue preview | Highlight Pi's pending-queue preview with a green left bar. |
| Style image chips | Render `[Image #N]` placeholders as distinct chips. |
| Show attachment count | Show a status badge when the draft has image placeholders. |

### Session naming

| Setting | What it does |
| --- | --- |
| Enable /rename command | Register the `/rename` command. |
| Auto-name new sessions | Generate a friendly session name from the first prompt. |
| Auto-rename model | Model used for title generation. |
| Auto-rename fallback model | Model tried when the primary fails. |
| Deterministic fallback | Title-case words, truncated prompt, or none if all model calls fail. |
| Auto-rename prefix | Optional static prefix on every generated name. |
| Notify on auto-rename | Show a notification when auto-renaming. |

Advanced: input cap, title length, output tokens, timeout, custom prompt template, and debug logging.

### Handoff

| Setting | What it does |
| --- | --- |
| Enable /handoff command | Register the `/handoff` command. |
| Review handoff prompt | Open an editor to edit the generated prompt before creating the session. |

### Context window

| Setting | What it does |
| --- | --- |
| Enable /context command | Register `/context`. |

### Session search

| Setting | What it does |
| --- | --- |
| Enable session search | Register `/search` and the overlay. |
| Session search shortcut | Configurable; set to `none` to disable. |
| Result limit | Max matching prompts returned. |
| Visible session rows | Rows shown before scrolling. |
| Preview snippets | Matching snippets shown on the preview screen. |
| Session cache TTL | Seconds before the session list refreshes; `0` keeps it until you run `/search:refresh`. |

Summary settings (model, max tokens, input cap) tune the summarizer when you import context from a previous session.

### Notifications

Master toggle: **Enable notifications**.

Triggers (notify when): ready, direction needed, question popups, all tasks complete, critical/blocked.

Channels: terminal bell, native terminal notifications (OSC 777/99 or Windows toast), tmux `display-message`, tmux window marking, OSC passthrough, and an optional in-Pi UI notice.

Tuning: cooldown seconds, title, ready message, body length, tmux durations.

Notes:

- **Terminal notification protocol** picks between OSC 99 (Kitty) and OSC 777 automatically.
- **Bell when tmux window active** is off so you don't get bells while looking at Pi.
- **tmux native via client TTY** sends OSC notifications to attached tmux clients so notifications still appear when the Pi window is inactive.

Use `/qol notify-test` to verify your terminal/tmux setup.

### Permission gate

| Setting | What it does |
| --- | --- |
| Prompt before risky bash commands | Ask before bash commands matching the command list. |
| Commands to prompt for | Comma-separated literal fragments or `/regex/flags`. |
| Approval preview lines | Cap the approval-prompt preview height. |
| Approval preview characters | Cap the approval-prompt preview width. |

Off by default. When enabled, non-interactive matches are blocked.

### Compaction

| Setting | What it does |
| --- | --- |
| Custom compaction summaries | Use QOL summaries instead of Pi's default. |
| Compaction model | Summarizer model. Defaults to `current`, meaning Pi's active model; set a provider/model when you want a dedicated larger-context summarizer. |
| Compaction detail profile | `concise`, `balanced`, or `exhaustive`. |
| Include previous summary | Pass the previous summary for iterative continuity. |
| Fallback to Pi default compaction | Run Pi's default compaction if QOL's fails. |
| Show compaction notifications | Notify on compaction start/fail/complete. |
| Custom branch summaries | Use the QOL summarizer for `/tree` branch summaries. |
| Remote compaction endpoint | Call a remote HTTP summarizer instead of a model. |
| Idle compaction trigger | Auto-compact after the session sits idle above a token threshold. |

Idle thresholds (token threshold, idle delay, fixed token limit, percent limit) tune when idle compaction fires.

### Thinking

| Setting | What it does |
| --- | --- |
| Hidden thinking label | Label shown when thinking blocks are hidden. |
| Show thinking timer | Show elapsed time next to collapsed `Thinking...` labels. |
| Working indicator mode | `animated` ticks every 80ms; switch to `static` if you see flashes when the chat overflows. |
