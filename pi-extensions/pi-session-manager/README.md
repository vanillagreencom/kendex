# @vanillagreen/pi-session-manager

A session browser for Pi. You can search saved conversations, resume them, rename them or delete them.

![Session Manager overlay and model-change confirmation](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-session-manager/assets/session-manager.gif)

## Install

- npm: `pi install npm:@vanillagreen/pi-session-manager`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-session-manager"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation.

## Features

- Browse sessions for the current project or all projects.
- Search by words, quoted phrases or regular expressions.
- View related sessions as a tree.
- Choose the saved or current model when resuming.
- Delete with confirmation and optional trash support.

## How it works

The browser reads Pi's saved session files and displays their names and details. You search or select a session. Resume opens that session through Pi. Delete tries the trash command when configured, then uses permanent deletion if trash is unavailable.

## Settings

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-session-manager"]`.

Open `/extensions:settings`; settings appear under the **Session Manager** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted. `glyphStyle` picks `unicode` or `ascii` symbols, and `@vanillagreen/pi-tool-renderer`'s `globalGlyphStyleOverride` wins when set.

- `enabled`: package toggle.
- `shortcutKey`: the opening shortcut; `none` disables it.
- `defaultScope`, `defaultSort`: the tab and sort the overlay opens with.
- `visibleRows`, `overlayWidth`: overlay size.
- `deleteUsesTrash`: try `trash` before a permanent unlink.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
