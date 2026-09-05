# @vanillagreen/pi-extension-manager

A package browser for Pi and oh-my-pi (OMP). It includes a settings editor for kendex Pi packages and for the manager itself on OMP.

![Extension Manager browser and settings editor](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-extension-manager/assets/extension-manager.gif)

## Install

- Pi: `pi install npm:@vanillagreen/pi-extension-manager`.
- OMP 18.1.11 or later: `omp plugin install @vanillagreen/pi-extension-manager`.
- kendex, for Pi only: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-extension-manager"]
source = "kendex"
```

Restart the host after installation.

## Features

- Browse installed Pi packages or native OMP plugins, including disabled plugins.
- Enable or disable packages. On OMP this controls the whole plugin, including its non-extension contributions.
- Update or uninstall Pi packages and notify you about available updates.
- Edit kendex package settings on Pi, or the manager's own settings on OMP.

## How it works

Open `/extensions` on Pi or `/kendex:extensions` on OMP. OMP keeps its built-in `/extensions` command. The manager reads Pi's package settings or OMP's installed plugin records, then displays each package's declared extension entrypoints. OMP keeps user and project entrypoints separate and offers manager settings only for its active installation. Restart the host after toggling a package.

OMP module toggles, updates, uninstall, and other extensions' settings are unavailable in this manager. Use OMP's native controls for those actions, optional plugin features, or project plugin overrides that block enabling a plugin. The manager does not run Pi package commands or Pi append-system scripts on OMP.

## Settings

Open `/extensions:settings` on Pi or `/kendex:extensions:settings` on OMP. Values are stored under `kendex.extensionManager.config["@vanillagreen/pi-extension-manager"]`.

Pi uses user and project `settings.json` files. OMP uses the active agent directory's `config.yml`, retaining `config.yaml` when that is the existing file. OMP project settings come from the current directory's `.omp/settings.json` and `.omp/config.yml`; YAML overrides JSON when both exist. The first project-scoped edit creates `.omp/config.yml` in a trusted OMP project when neither file exists. Host directory resolvers determine the active user paths, including OMP profiles and XDG storage. Settings writes preserve unknown fields, but YAML formatting and comments are not retained.

- `enabled`: a global-only setting, even for a project-installed manager. Display, edits and resets use the global value; project values are ignored. If disabled, the host-specific manager command's `:enable` action restores it; restart or reload afterward.
- `defaultSaveScope`: where an edit is written when the scope is ambiguous.
- `notifyOnUpdates`: Pi's session-start update notification; unavailable on OMP.
- `glyphStyle`: Unicode or ASCII symbols. On Pi, the Tool Renderer tab's `globalGlyphStyleOverride` can override this setting.

On Pi, editing a value supplied by a package's own config file writes a manager override. Resetting that value names its source file instead, because no manager override exists to delete. See [DEVELOPMENT.md](DEVELOPMENT.md) for the external config resolver contract and host integration boundaries.
