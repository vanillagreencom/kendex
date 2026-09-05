# @vanillagreen/pi-caveman

A Pi extension that asks the model to use shorter replies. Users can choose a response style for the session or set a default.

![/caveman command autocomplete](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-caveman/assets/command-autocomplete.png)

## Install

- npm: `pi install npm:@vanillagreen/pi-caveman`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-caveman"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation.

## Features

- Select lite, full, ultra or micro response styles.
- Toggle the style with the caveman command.
- Keep a session's selected style when it resumes.
- Configure which kinds of output use normal English.

## How it works

You select a style in the settings or with a session command. Before the next model turn, the extension adds that style's instructions to the system prompt. The model uses those instructions when it writes a reply. The extension saves the session choice for later resumes.

## Settings

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-caveman"]`.

Open `/extensions:settings`; settings appear under the **Caveman** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `mode`: the default mode for new sessions.
- `showStatusBadge`, `sessionOverrideAllowed`: the statusline badge and whether `/caveman` commands may override the default.
- `autoClarityEscape`, `resumeAfterClarityEscape`: the plain-English reply for destructive operations and the return to caveman afterwards.
- `boundaryNormalForCode`, `boundaryNormalForCommits`, `boundaryNormalForReviews`, `boundaryNormalForExternalWrites`: which outputs stay normal English.
- `customPromptSuffix`: project-specific guidance appended to the directive.

With `pi-claude-bridge` as the provider the directive reaches Claude only when the bridge's `includeCavemanHook` setting is on; it is off by default, and caveman warns once at session start while it is off. Native Pi providers need nothing.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
