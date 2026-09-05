# @vanillagreen/pi-qol

Quality-of-life extension for Pi: a compact statusline and prompt editor, multiline input, session naming and search, scheduled prompts, handoff drafts, notifications, a permission gate for risky shell commands, and bounded compaction for long sessions.

![QOL extension settings panel](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-qol/assets/settings-panel.png) ![Session search popup](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-qol/assets/session-search.gif) ![/context usage breakdown](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-qol/assets/context-usage.png)

## Install

Requires Pi 0.80.4 or newer. Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-qol"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-qol):

```bash
pi install npm:@vanillagreen/pi-qol
```

Restart Pi after installation.

## What it does

- Statusline with repo, branch, dirty marker, model, thinking level and context percent, replacing Pi's footer; a compact π prompt editor; a session-name title above the prompt and in the tmux pane or window name.
- Newline on shift+enter with a fallback key for terminals that cannot send it; styled pending-queue previews and `[Image #N]` chips; image paths in a submitted prompt attach as images.
- Sessions auto-name from the first prompt. `/rename [name]` sets or shows the name; `/qol:rename` and `/qol:rename:full` regenerate it from the first prompt or the whole conversation.
- `/search [query]` opens previous-session search with snippet previews and context import, reading session files line by line so large sessions never load whole; `/search:refresh` rebuilds the cache.
- `/schedule <delay> <message>` sends a user message after a timer (`1h45m`, bare numbers are minutes); `/schedule list` and `/schedule cancel <id|all>` manage pending ones. Schedules live in the session and re-arm on resume; an overdue one sends when the session next loads.
- `/handoff <goal>` drafts a focused prompt for a new session, with an optional review step.
- `/context` shows a context-window usage breakdown by category and warns when the serialized request payload crosses the transcript-risk budget.
- Optional auto-resume after a provider rate limit resets, sending a configured continuation.
- Permission gate: prompts before a `bash` command matching a configured list; without a UI the command is blocked rather than allowed.
- Notifications for ready, direction needed, question popups, task completion and critical states, over the terminal bell, native OSC notifications, tmux messages and window marks; `/qol notify-test` checks the setup.
- Custom compaction summaries, `/tree` branch summaries, idle compaction, and a long-session budget guard that compacts in bounded chunks when context usage crosses a threshold and writes a pre-compaction handoff artifact.
- Thinking timer beside collapsed `Thinking...` labels; a Caveman badge and alt+c mode cycling when `pi-caveman` is loaded; a subagent badge in `pi-agents-tmux` child panes.
- `/qol` opens the settings editor, or prints status when `pi-extension-manager` is not installed.

## How it works

Every feature is a Pi event handler or a registered command in `extensions/qol.ts`, gated by its own setting, so a disabled feature registers nothing. Sibling kendex extensions are reached through shared global symbols rather than imports, so each works alone. The budget guard compacts in bounded chunks only when nothing else has compacted the session, so each summarization call stays under the provider's limits.

## Customise

Open `/extensions:settings`; settings appear under the **QOL** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted. `glyphStyle` picks `unicode` or `ascii` chrome, and `@vanillagreen/pi-tool-renderer`'s `globalGlyphStyleOverride` wins when set.

- `enabled`: master toggle for everything below.
- Statusline and editor: `statusline.enabled`, `replaceFooter`, `compactPrompt`, `showSessionNameTitle`, `showSessionNameWindow`, `inputBottomPaddingLines`, `gitRefreshTimeoutMs`, `showDirtyMarker`, `newlineOnShiftEnter`, `newlineFallbackKey`, `pendingQueue.asciiGreen`, `showImageChips`, `showAttachmentCountInStatus`.
- Commands: `enableSessionNameCommand`, `enableHandoffCommand`, `enableScheduleCommand`, `enableContextCommand`, `handoffReviewPrompt`.
- Session naming: `sessionAutoRename.*` (model, fallback model, deterministic fallback, prefix, prompt, limits, notify, debug).
- Session search: `sessionSearch.*` (shortcut, result and row limits, snippets, overlay width, cache TTL, summary model and limits).
- Rate limits: `rateLimitAutoResume.*`.
- Permission gate: `permissionGate.enabled`, `permissionGate.commands` (comma-separated literal fragments or `/regex/flags`), `permissionGate.previewLines`, `permissionGate.previewChars`.
- Notifications: `notification.*` (triggers, channels, tmux options, protocol, cooldown, title and body).
- Compaction and budget guard: `compaction.*` (custom summaries, model, profile, remote endpoint, branch summaries, idle trigger, budget guard thresholds, chunk input cap, handoff artifact, transcript-risk budget).
- Thinking: `thinkingLabel.text`, `thinkingTimer.enabled`, `workingIndicator.mode` (`static` if the animated indicator flashes).

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
