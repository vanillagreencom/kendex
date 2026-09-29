# @vanillagreen/pi-qol

A Pi extension for session controls, prompt editing and notifications. Users can configure each feature separately.

![QOL extension settings panel](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-qol/assets/settings-panel.png) ![Session search popup](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-qol/assets/session-search.gif) ![/context usage breakdown](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-qol/assets/context-usage.png)

## Install

- npm: `pi install npm:@vanillagreen/pi-qol`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-qol"]
source = "kendex"
```

Requires Pi 0.86.0 or newer. Restart Pi after installation. Use `kendex update-pi --check` to preview the installation.

## Features

- Show repository, model and context information beside the editor, with the working spinner before the project name.
- Name and search sessions.
- Schedule prompts and prepare handoff drafts.
- Ask before configured shell commands run.
- Send terminal and desktop notifications.
- Configure summaries and compaction for long sessions.

## How it works

The extension reads your enabled features when Pi starts. It adds their editor controls, commands and event handlers. Session actions update the session or queue messages for the agent. Notifications report events through your selected channels. Compaction settings control when long conversations are summarized.

## Settings

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-qol"]`.

Open `/extensions:settings`; settings appear under the **QOL** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted. `glyphStyle` picks `unicode` or `ascii` symbols, and `@vanillagreen/pi-tool-renderer`'s `globalGlyphStyleOverride` wins when set.

- `enabled`: package toggle for everything below.
- Statusline and editor: `statusline.enabled`, `statusline.showProvider`, `statusline.showAccount`, `replaceFooter`, `compactPrompt`, `showSessionNameTitle`, `showSessionNameWindow`, `inputBottomPaddingLines`, `gitRefreshTimeoutMs`, `showDirtyMarker`, `newlineOnShiftEnter`, `newlineFallbackKey`, `pendingQueue.asciiGreen`, `showImageChips`, `showAttachmentCountInStatus`.
- Commands: `enableSessionNameCommand`, `enableHandoffCommand`, `enableScheduleCommand`, `enableContextCommand`, `handoffReviewPrompt`.
- Session naming: `sessionAutoRename.*` (model, fallback model, deterministic fallback, prefix, prompt, limits, notify, debug).
- Session search: `sessionSearch.*` (shortcut, result and row limits, snippets, overlay width, cache TTL, summary model and limits).
- Rate limits: `rateLimitAutoResume.*`.
- Permission gate: `permissionGate.enabled`, `permissionGate.commands` (comma-separated literal fragments or `/regex/flags`), `permissionGate.previewLines`, `permissionGate.previewChars`.
- Notifications: `notification.*` (triggers, channels, tmux options, protocol, cooldown, title and body).
- Compaction and budget guard: `compaction.*` (custom summaries, model, profile, remote endpoint, branch summaries, idle trigger, budget guard thresholds, chunk input cap, handoff artifact, transcript-risk budget).
  - Pi's own `compaction.enabled` (the top-level `compaction` object in the same settings files, not a QOL key) turns off every automatic compaction: when it is `false`, neither the budget guard nor the idle trigger starts one, and `/qol` reports both as disabled by that key. A manual `/compact` still runs. While it is `true` or absent, both keep the defaults and thresholds above: the budget guard on at `compaction.budgetPercent` 85, the idle trigger off until `compaction.idleEnabled` is set.
- Thinking: `thinkingLabel.text`, `thinkingTimer.enabled`, `workingIndicator.mode` (`static` if the animated indicator flashes).

**Show model provider** displays a readable provider name before the model, such as `Copilot / GPT 6 Astra`. It is on by default; changes apply on the next render without reloading. Disabling the QOL statusline leaves Pi's standalone working indicator in place.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
