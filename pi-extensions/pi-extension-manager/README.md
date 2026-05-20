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

| Setting | What it does |
| --- | --- |
| Enable manager UI | Expose `/extensions` and the manager UI. `/extensions:enable` is always available as recovery. |
| Default save scope | Where setting edits are written when scope is ambiguous (`project` or `user`). |
| Notify on extension updates | Post a one-line notification at session start listing extensions with newer versions. |

Glyph style: each package exposes `glyphStyle` (`unicode` default, `ascii` for terminal-safe chrome). `@vanillagreen/pi-tool-renderer.globalGlyphStyleOverride=ascii` forces ASCII chrome across vstack Pi extensions while leaving tool/model/user content unchanged.

## Notes

Package enable/disable and updates take effect after `/reload` or restart — Pi doesn't currently support unloading already-loaded extensions. npm update/uninstall actions run inside Pi's scope-local npm directory (`<scope>/npm`), matching Pi 0.75+ user package installs under `~/.pi/agent/npm/`. Command execution resolves Windows npm-family shims without requiring external runtime dependencies.
