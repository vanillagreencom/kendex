# @vanillagreen/pi-extension-manager

A package manager and settings editor for the Pi packages kendex, npm, git or a local path installed. Every kendex Pi extension puts its settings in the editor this package provides, so install it first.

![Extension Manager browser and settings editor](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-extension-manager/assets/extension-manager.gif)

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-extension-manager"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-extension-manager):

```bash
pi install npm:@vanillagreen/pi-extension-manager
```

Restart Pi after installation.

## What it does

- `/extensions` browses every installed package with its status, source, install method, versions and update state, and enables, disables, updates or uninstalls it.
- `/extensions:settings` edits each package's kendex settings on one tab per package, at project or user scope.
- `/extensions:enable` brings the manager back when its own UI has been disabled.
- Notifies once at session start when installed packages have newer versions.
- Shows a value a package takes from a config file of its own with the file that supplies it, so the row reads what the package resolves rather than the schema default.

Each popup lists its keys in its footer. Enabling, disabling and updating a package take effect after `/reload` or a restart, because Pi cannot unload a loaded extension. Project-scope packages and settings appear only once Pi reports the workspace trusted.

## How it works

The manager reads Pi's `settings.json` at user and project scope and the `package.json` of every package they name, under Pi's own package roots. A package declares its settings schema under `kendex.extensionManager` in its manifest, and the editor writes values under `kendex.extensionManager.config[<package>]` in the chosen scope's `settings.json`, where the package reads them. npm actions run in the scope's own npm directory; git packages are read only under Pi's managed clone root, and an entry pointing outside it shows as broken.

## Customise

Open `/extensions:settings`; settings appear under the **Extension Manager** tab.

- `enabled`: expose `/extensions` and the manager UI; `/extensions:enable` always works.
- `defaultSaveScope`: where an edit is written when the scope is ambiguous.
- `notifyOnUpdates`: the session-start notification.
- `glyphStyle`: unicode or ASCII chrome for this package; `globalGlyphStyleOverride` on the Tool Renderer tab forces one style across every kendex Pi extension.

Editing a row whose value comes from a package's own config file writes Pi settings, which override that file; deleting such a row names the file instead, because nothing is stored in Pi settings to reset. Maintainer notes, including the contract a package implements to report such values, are in [DEVELOPMENT.md](DEVELOPMENT.md).
