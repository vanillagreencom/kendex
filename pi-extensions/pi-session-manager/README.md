# pi-session-manager

![Session Manager overlay and model-change confirmation](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-session-manager/assets/session-manager.gif)

Polished session manager overlay. Complements Pi's built-in `/resume` with search, lineage view, rename, and safe delete.

## Highlights

- Browse current-project sessions or all sessions.
- Search by tokens, quoted phrases, or `re:<regex>`.
- Threaded lineage view follows Pi `parentSession` relationships.
- Resume preserves the session's saved model. If your active model differs, a confirmation lets you pick either.
- Inline rename and delete with confirmation. Optional `trash` CLI fallback so deletes are recoverable.
- Deleting a session also clears its per-extension data.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-session-manager):

```bash
pi install npm:@vanillagreen/pi-session-manager
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-session-manager --harness pi -y
```

Restart Pi after installation.

## Commands

| Command | Action |
| --- | --- |
| `/sessions` | Open the manager. Switch Current/All with the tabs. |

The manager popup documents its own keys in the footer. Selection, rename, delete, scope toggle, sort cycle, and named-only filter are all available; bindings are configurable via `/extensions:settings`.

Session titles match Pi `/resume`: explicit session name, otherwise first user message, otherwise filename. Search filters the shown list; delete-all acts only on the currently shown sessions.

## Settings

Open `/extensions:settings`; settings appear under the **Session Manager** tab.

| Setting | What it does |
| --- | --- |
| Manager shortcut | Default `f1`. Set `none` to disable. |
| Default scope | Initial Current/All tab. |
| Default sort | `threaded`, `recent`, or `relevance`. |
| Visible rows | Rows shown before scrolling. |
| Overlay width | Preferred width in terminal columns. |
| Use trash for delete | Try `trash` before permanent unlink. |

Glyph style: each package exposes `glyphStyle` (`unicode` default, `ascii` for terminal-safe chrome). `@vanillagreen/pi-tool-renderer.globalGlyphStyleOverride=ascii` forces ASCII chrome across vstack Pi extensions while leaving tool/model/user content unchanged.

## Notes

Pi's built-in `/resume`, `/tree`, `/fork`, `/clone`, and `/name` remain available.
