# @vanillagreen/pi-tool-renderer

Compact renderers for Pi's built-in tools, an optional `tool_batch` composite tool, and an optional rich diff view for edits, writes and patches. It changes how tool calls and messages look in the terminal; execution stays with Pi's own tools.

![tool_batch composite result with Read/grep/Bash rows](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-tool-renderer/assets/tool-batch.png) ![Edit tool with side-by-side diff renderer](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-tool-renderer/assets/edit-diff.png)

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-tool-renderer"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-tool-renderer):

```bash
pi install npm:@vanillagreen/pi-tool-renderer
```

Restart Pi after installation.

## What it does

- One-line rows for `read`, `bash`, `grep`, `find` and `ls`, with file paths as `file://` hyperlinks where the terminal supports OSC 8.
- Bash output that appears only after a short delay, so a fast command does not flash, and keeps its last lines flush-left so copied text carries no gutter.
- `tool_batch`: one tool call that runs several independent `read`, `grep`, `find`, `ls` or read-only `bash` calls and renders one combined result. Not for mutating, order-dependent or streaming commands.
- Rich diffs for `edit` and `write`, side by side on a wide terminal, with syntax highlighting and word-level highlights. Off by default; Pi's built-in renderers stay until `renderMutationTools` is on.
- Diff rendering for `apply_patch` calls and for diff output from read-only bash commands, each behind its own setting.
- Compact user, assistant, compaction-summary and skill-invocation messages, and styled fenced code blocks in assistant output.
- Renderers for tools Pi has no view of its own for: OpenAI-style `web_search`, `webfetch`, `Agent` and `Task*` tools, MCP tools, and unknown tools.
- Optional chrome: outlines around every tool row, a right-margin guard against tmux wrap flashes, and a choice of working indicator.

## How it works

The extension registers replacement renderers for Pi's built-in tools; each replacement delegates execution to the built-in tool and only draws the call and result. Message components are patched the same way. Terminal text is normalised the way Pi normalises it before any line is counted or previewed, so line counts match what Pi shows. A settings change from the extension manager re-renders the tool rows already on screen.

## Customise

Open `/extensions:settings`; settings appear under the **Tool Renderer** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: master toggle.
- `glyphStyle`, `globalGlyphStyleOverride`, `treeStyle`: Unicode or ASCII chrome. The global override forces one style across every kendex Pi extension and leaves tool, model and user content alone.
- `registerBatchTool`, `batchMaxCalls`, `batchCallTimeoutMs`: the `tool_batch` tool and its limits.
- `readOutputMode`, `searchOutputMode`, `bashOutputMode`, `mcpOutputMode`, and the `*PreviewLines` and `bashLiveOutputDelayMs`, `bashLiveTailLines`, `bashCollapsedLines`, `commandPreviewChars` budgets: how much of each result shows collapsed and expanded.
- `showReadImages`: images in `read` results; needs Pi's own `terminal.showImages` off.
- `renderMutationTools`, `splitDiffs`, `diffPreviewLines`, `diffExpandedLines`, `mutationCallPreview`, `mutationCallPreviewLines`, `shikiDiffs`, `wordDiffHighlights`, `diffBackgrounds`, `showDiffHunkMeta`: the edit and write diff view.
- `renderBashDiffs`, `renderGitDiffCommandDiffs`, `applyPatchRenderer`, `applyPatchPreview`, `applyPatchPreviewLines`, `genericToolRenderers`: diffs and views for tools other than edit and write.
- `compactUserMessages`, `userMessageTrailingBlankLine`, `compactCompactionMessages`, `compactSkillMessages`, `alignAssistantMessages`, `styledCodeBlocks`: message rendering.
- `toolChrome`, `rightMarginGuard`, `pendingStatusAnimation`, `workingIndicator`, `maxLineWidth`: chrome and the hard cap on one rendered line.
- `stackToolCalls`, `stackChildDisplay`, `hideStackChildRows`: the older stacking of consecutive native tool calls; `tool_batch` is the preferred form.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
