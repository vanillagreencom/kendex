# @vanillagreen/pi-hooks

A Pi extension that runs hooks installed by kendex. It checks tool calls and can report Rust errors and installation drift to the agent.

## Install

- npm: `pi install npm:@vanillagreen/pi-hooks`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-hooks"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation. Install the hooks separately with kendex, for example `kendex add --hook block-bare-cd --hook block-repo-copy --hook pre-commit-check`.

## Features

- Run installed PreToolUse hooks before Pi tool calls.
- Stop a tool call when a hook refuses it or cannot complete.
- Run configured custom hooks.
- Report clippy errors after Rust edits.
- Report installation drift when a session starts.

## How it works

kendex installs hook scripts and a hook registry for Pi. Before a tool call, this extension reads the applicable project and user registries. It gives each matching hook the tool name and arguments. Pi runs the tool only after the hooks allow the call.

## Settings

The settings editor writes user values to `~/.pi/agent/settings.json` and project values to `.pi/settings.json`. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-hooks"]`.

Open `/extensions:settings`; settings appear under the **Hooks** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: package toggle; a custom hook has no toggle of its own and rides this one.
- `blockBareCd`, `blockRepoCopy`, `preCommitCheck`: one toggle per shipped guard.
- `taskCompletedCheck`, `sessionDriftCheck`: the end-of-turn clippy advisory and the session-start drift report.
- `hookTimeoutMs`, `clippyTimeoutMs`, `driftCheckTimeoutMs`: the time budgets; a hook past its budget refuses the call.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).

The extension runs PreToolUse hooks only. Other hook events are not dispatched.
