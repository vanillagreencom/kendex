# @vanillagreen/pi-qol

A Pi extension for session controls, prompt editing and notifications. Users can configure each feature separately.

![QOL extension settings panel](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-qol/assets/settings-panel.png) ![Session search popup](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-qol/assets/session-search.gif) ![/context usage breakdown](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-qol/assets/context-usage.png)

## Features

- Show repository, model and context information beside the editor, with the working spinner before the project name.
- Name and search sessions.
- Schedule prompts and prepare handoff drafts.
- Ask before configured shell commands run.
- Send terminal and desktop notifications.
- Configure summaries and compaction for long sessions.

## Install

- npm: `pi install npm:@vanillagreen/pi-qol`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-qol"]
source = "kendex"
```

Requires Pi 0.86.0 or newer. Restart Pi after installation. Use `kendex update-pi --check` to preview the installation.

## How it works

The extension reads your enabled features when Pi starts. It adds their editor controls, commands and event handlers. Session actions update the session or queue messages for the agent. Notifications report events through your selected channels. Compaction settings control when long conversations are summarized.

## Memory use

- A session without a UI loads no session-search index. With a UI, the index is loaded shortly after start and kept for `sessionSearch.cacheTtlSeconds` (default 300 seconds; 0 keeps it until the session ends). A search after the index was released opens at once and fills in when the index has loaded again.
- The index keeps at most 32,768 characters of message text per session and 8,388,608 characters in total, newest session first. A session past the total is searched by name, path and first prompt only.
- Prepared user prompts have the same per-session and total character limits, measured in decoded UTF-16 code units. Indexing skips JSONL records above 2,097,152 decoded UTF-16 code units, not bytes. Copy and Fork read the complete selected prompt separately. Search waits 20 ms after the last edit and cancels an older query. Regex matching runs in a disposable worker with a 25 ms deadline and a separate 1 second startup deadline. A deadline error appears in the search popup.
- Submitted image paths and existing clipboard images share a 20 MiB raw-byte limit. The extension checks all file sizes before reading any image. A refusal blocks submission and reports an error. It restores the rejected prompt only if the editor is empty; a newer draft stays unchanged. Print and JSON callers receive the diagnostic on stderr.
- Where Pi cannot switch sessions directly, a chosen resume or fork waits as one `/search:resume-pending` command in the editor. Only the latest one is kept, and it is dropped when the session ends.
- The separate on-demand parsed-prompt cache keeps at most 64 sessions. The prepared search index uses the character limits above, not this session count. Finished thinking times are kept for at most 256 blocks. Thinking labels are released at the end of each agent run, and notification cooldown entries once their cooldown has passed and all of them when the session ends.

## Saved files

At session start, the extension deletes budget handoff files whose recorded working directory no longer exists. It also deletes files older than 5 days. Both timestamped snapshots and `latest.json` follow this rule.

## Setup

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-qol"]`.

Open `/extensions:settings`; settings appear under the **QOL** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted. `glyphStyle` picks `unicode` or `ascii` symbols, and `@vanillagreen/pi-tool-renderer`'s `globalGlyphStyleOverride` wins when set.

- `enabled`: package toggle for everything below.
- Statusline and editor: `statusline.enabled`, `statusline.showProvider`, `statusline.showAccount`, `replaceFooter`, `compactPrompt`, `showSessionNameTitle`, `showSessionNameWindow`, `inputBottomPaddingLines`, `gitRefreshTimeoutMs`, `showDirtyMarker`, `newlineOnShiftEnter`, `newlineFallbackKey`, `pendingQueue.asciiGreen`, `showImageChips`, `showAttachmentCountInStatus`.
- Commands: `enableSessionNameCommand`, `enableHandoffCommand`, `enableScheduleCommand`, `enableContextCommand`, `handoffReviewPrompt`.
- Session naming: `sessionAutoRename.*` (model, fallback model, deterministic fallback, prefix, prompt, limits, notify, debug). `sessionAutoRename.maxTokens` also counts the naming model's reasoning tokens: with `gpt-5.4-mini` naming 40 issue-sized first messages, 22 got a title at 96 and 29 at 128, the default. `sessionAutoRename.maxNameChars` stays 80 because no title in those runs was longer than 36 characters, so 70 and 80 give the same names.
- Session search: `sessionSearch.*` (shortcut, result and row limits, snippets, overlay width, cache TTL, summary model and limits).
- Rate limits: `rateLimitAutoResume.*`.
- Permission gate: `permissionGate.enabled`, `permissionGate.commands` (comma-separated literal fragments or `/regex/flags`), `permissionGate.previewLines`, `permissionGate.previewChars`.
- Notifications: `notification.*` (triggers, channels, tmux options, protocol, cooldown, title and body).
- Compaction and budget guard: `compaction.*` (custom summaries, model, profile, remote endpoint, branch summaries, idle trigger, budget guard thresholds, chunk input cap, handoff artifact, transcript-risk budget). `compaction.maxTokens` stays 8192, the cap on the budget-guard, custom and branch summaries. The fleet value considered was 10192, but no comparison was possible: the fleet's settings, Pi's `compaction.enabled` false with `compaction.customEnabled` and `compaction.branchSummaryEnabled` off, run none of these summaries.
  - Pi's own `compaction.enabled` (the top-level `compaction` object in the same settings files, not a QOL key) turns off every automatic compaction: when it is `false`, neither the budget guard nor the idle trigger starts one, and `/qol` reports both as disabled by that key. A manual `/compact` still runs. While it is `true` or absent, both keep the defaults and thresholds above: the budget guard on at `compaction.budgetPercent` 85, the idle trigger off until `compaction.idleEnabled` is set.
- Thinking: `thinkingLabel.text`, `thinkingTimer.enabled`, `workingIndicator.mode`. `workingIndicator.mode` defaults to `static`, a dot with no animation timer; `animated` restores Pi's spinner. In a scripted 100-second streaming session on Pi 1.0.1, `animated` drew 2050 and 2080 frames with 4.9 s of CPU, and `static` 867 and 873 frames with 3.2 to 3.4 s. `thinkingTimer.enabled` stays on because turning it off in the same session changed neither the frames (2056 and 2066) nor the CPU (4.8 to 4.9 s).

**Show model provider** displays a readable provider name before the model, such as `Copilot / GPT 6 Astra`. It is on by default; changes apply on the next render without reloading. Disabling the QOL statusline leaves Pi's standalone working indicator in place.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).

## Licence

[MIT](https://github.com/vanillagreencom/kendex/blob/main/LICENSE)
