# pi-prompt-stash

![Prompt Stash popup](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-prompt-stash/assets/stash-popup.png)

Per-session prompt stash. Save a draft, write something else, restore later.

## Highlights

- Dedicated stash shortcut: stashes the current draft when the editor has text, opens the popup when the editor is empty.
- Searchable popup with restore, delete, and clear-all.
- Stashes are per-session and survive Pi restarts within the session.
- Optional deduplication discards older entries with identical text.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-prompt-stash):

```bash
pi install npm:@vanillagreen/pi-prompt-stash
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-prompt-stash --harness pi -y
```

Restart Pi after installation.

## Commands

| Command | Action |
| --- | --- |
| `/prompt-stash` | Open the stash popup. |

The stash shortcut both stashes (when the editor has text) and opens the popup (when the editor is empty). The popup itself documents its own keys in the footer — search, select, restore, delete, delete-all, close.

## Settings

Glyph style: each package exposes `glyphStyle` (`unicode` default, `ascii` for terminal-safe chrome). `@vanillagreen/pi-tool-renderer.globalGlyphStyleOverride=ascii` forces ASCII chrome across vstack Pi extensions while leaving tool/model/user content unchanged.

Open `/extensions:settings`; settings appear under the **Prompt Stash** tab.

| Setting | What it does |
| --- | --- |
| Stash shortcut | Configurable. |
| Store file | File name inside the per-session stash directory. |
| Deduplicate prompts | Remove older entries with identical text when stashing. |
| Popup width | Preferred popup width. |
| Popup max height | Maximum overlay height. |
| Visible stash rows | Rows shown before scrolling. |
