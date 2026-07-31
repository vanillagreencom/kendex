# pi-extension-manager

![Extension Manager browser and settings editor](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-extension-manager/assets/extension-manager.gif)

Package manager and settings editor for Pi packages installed by vstack, npm, git, or local path.

## Highlights

- Browse, enable, disable, update, and uninstall packages from one popup.
- Separate settings editor with one tab per package that exposes vstack settings from user/global and project scopes.
- Diagnostics view shows status, source, install method, versions, and update state.
- Optional notification at session start when newer versions are available.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-extension-manager):

```bash
pi install npm:@vanillagreen/pi-extension-manager
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-extension-manager --harness pi -y
```

Restart Pi after installation.

## Commands

| Command | Action |
| --- | --- |
| `/extensions` | Open the package manager. |
| `/extensions:settings` | Open the settings editor. |
| `/extensions:enable` | Recovery command when the manager is disabled. |

Each popup documents its own keys in the footer.

Status icons: `●` active, `○` inactive, `×` broken. Packages with newer versions show `Update Needed`.

## Settings

Open `/extensions:settings`; settings appear under the **Extension Manager** tab.

Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, vstack Pi extensions read user/global settings only.

Some packages also keep a config file of their own. A row whose value comes from one of those files shows the value the package actually resolves, and names the file under the setting. Editing the row writes Pi settings, which override that file; `delete` reports the file instead of resetting, because the value is not stored in Pi settings.

| Setting | What it does |
| --- | --- |
| Enable manager UI | Expose `/extensions` and the manager UI. `/extensions:enable` is always available as recovery. |
| Default save scope | Where setting edits are written when scope is ambiguous (`project` or `user`). |
| Notify on extension updates | Post a one-line notification at session start listing extensions with newer versions. |

Glyph style: each package exposes `glyphStyle` (`unicode` default, `ascii` for terminal-safe chrome). `@vanillagreen/pi-tool-renderer.globalGlyphStyleOverride=ascii` forces ASCII chrome across vstack Pi extensions while leaving tool/model/user content unchanged.

## Notes

Package enable/disable and updates take effect after `/reload` or restart — Pi doesn't currently support unloading already-loaded extensions. Project-scope settings and packages are shown only when Pi reports the current project as trusted; untrusted projects use user/global settings only. npm update/uninstall actions run inside Pi's scope-local npm directory (`<scope>/npm`), matching Pi 0.75+ user package installs under `~/.pi/agent/npm/`. Command execution resolves Windows npm-family shims without requiring external runtime dependencies.

Git package entries are inspected only under Pi's managed clone root (`<scope>/git/<host>/<repo>`). Entries with unsafe host or path components are shown as broken instead of reading package metadata from outside that root.
