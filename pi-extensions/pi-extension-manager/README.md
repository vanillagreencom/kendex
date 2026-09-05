# @vanillagreen/pi-extension-manager

A package browser and settings editor for Pi. It manages installed packages and provides the settings tabs used by kendex Pi extensions.

![Extension Manager browser and settings editor](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-extension-manager/assets/extension-manager.gif)

## Install

- npm: `pi install npm:@vanillagreen/pi-extension-manager`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-extension-manager"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation.

## Features

- Browse installed packages and their update status.
- Enable, disable, update or uninstall packages.
- Edit package settings at user or project scope.
- Notify you when package updates are available.

## How it works

The manager reads the packages listed in Pi's settings files. It reads each package's settings definitions and displays a tab for them. Your edits go to the selected user or project settings file. Package actions run through the package's installation method. Reload Pi after an enable, disable or update action.

## Settings

The settings editor writes user values to `~/.pi/agent/settings.json` and project values to `.pi/settings.json`. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-extension-manager"]`.

Open `/extensions:settings`; settings appear under the **Extension Manager** tab.

- `enabled`: expose `/extensions` and the manager UI; `/extensions:enable` always works.
- `defaultSaveScope`: where an edit is written when the scope is ambiguous.
- `notifyOnUpdates`: the session-start notification.
- `glyphStyle`: Unicode or ASCII symbols for this package; `globalGlyphStyleOverride` on the Tool Renderer tab forces one style across every kendex Pi extension.

Editing a row whose value comes from a package's own config file writes Pi settings, which override that file; deleting such a row names the file instead, because nothing is stored in Pi settings to reset. Maintainer notes, including the contract a package implements to report such values, are in [DEVELOPMENT.md](DEVELOPMENT.md).
