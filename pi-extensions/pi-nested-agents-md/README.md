# @vanillagreen/pi-nested-agents-md

A Pi extension that loads instructions for project subdirectories. It adds local AGENTS.md files when the agent reads files in those directories.

## Install

- npm: `pi install npm:@vanillagreen/pi-nested-agents-md`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-nested-agents-md"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation.

## Features

- Load directory instructions when the agent needs them.
- Attach instructions in order from parent to child directory.
- Avoid repeating instructions already loaded in the session.
- Report instruction files that cannot be read.

## How it works

The agent reads a project file with Pi's read tool. The extension looks for AGENTS.md files between that file and the project root. It adds unread instructions to the tool result with their paths. The model then receives the local rules beside the file content.

## Settings

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-nested-agents-md"]`.

Open `/extensions:settings`; settings appear under the **Nested AGENTS.md** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: package toggle.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
