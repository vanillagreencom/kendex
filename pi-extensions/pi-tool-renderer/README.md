# @vanillagreen/pi-tool-renderer

Tool and message displays for Pi. It provides compact output, optional file diffs and a tool for grouped read operations.

![tool_batch composite result with Read/grep/Bash rows](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-tool-renderer/assets/tool-batch.png) ![Edit tool with side-by-side diff renderer](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-tool-renderer/assets/edit-diff.png)

## Install

- npm: `pi install npm:@vanillagreen/pi-tool-renderer`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-tool-renderer"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation.

## Features

- Show compact tool rows with expandable output.
- Display file changes with side-by-side and word-level diffs.
- Group independent read operations into one result.
- Configure message layout and terminal symbols.

## How it works

Pi runs a tool and gives its call and result to the display extension. The extension formats those values using your settings. It shows a compact preview that you can expand. Optional diff views show changed files, and grouped read calls share one result display.

## Settings

The settings editor writes user values to `~/.pi/agent/settings.json` and project values to `.pi/settings.json`. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-tool-renderer"]`.

Open `/extensions:settings`; settings appear under the **Tool Renderer** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: package toggle.
- `glyphStyle`, `globalGlyphStyleOverride`, `treeStyle`: Unicode or ASCII symbols. The global override forces one style across every kendex Pi extension and leaves tool, model and user content alone.
- `registerBatchTool`, `batchMaxCalls`, `batchCallTimeoutMs`: the `tool_batch` tool and its limits.
- `readOutputMode`, `searchOutputMode`, `bashOutputMode`, `mcpOutputMode`, and the `*PreviewLines` and `bashLiveOutputDelayMs`, `bashLiveTailLines`, `bashCollapsedLines`, `commandPreviewChars` budgets: how much of each result shows collapsed and expanded.
- `showReadImages`: images in `read` results; needs Pi's own `terminal.showImages` off.
- `renderMutationTools`, `splitDiffs`, `diffPreviewLines`, `diffExpandedLines`, `mutationCallPreview`, `mutationCallPreviewLines`, `shikiDiffs`, `wordDiffHighlights`, `diffBackgrounds`, `showDiffHunkMeta`: the edit and write diff view.
- `renderBashDiffs`, `renderGitDiffCommandDiffs`, `applyPatchRenderer`, `applyPatchPreview`, `applyPatchPreviewLines`, `genericToolRenderers`: diffs and views for tools other than edit and write.
- `compactUserMessages`, `userMessageTrailingBlankLine`, `compactCompactionMessages`, `compactSkillMessages`, `alignAssistantMessages`, `styledCodeBlocks`: message rendering.
- `toolChrome`, `rightMarginGuard`, `pendingStatusAnimation`, `workingIndicator`, `maxLineWidth`: borders and the hard cap on one rendered line.
- `stackToolCalls`, `stackChildDisplay`, `hideStackChildRows`: the stacking of consecutive native tool calls.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
