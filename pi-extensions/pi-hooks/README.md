# @vanillagreen/pi-hooks

The carrier that runs kendex's hooks under Pi. On every tool call it dispatches the `PreToolUse` hooks kendex rendered for Pi, and it adds an end-of-turn clippy advisory and a session-start drift report. Install it wherever kendex installs hooks for Pi; the hooks themselves come from `kendex add`.

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-hooks"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-hooks):

```bash
pi install npm:@vanillagreen/pi-hooks
```

The package ships the carrier, not the hooks. Nothing runs until kendex has rendered a hook registry for the project or for your global Pi root:

```bash
kendex add --hook block-bare-cd --hook block-repo-copy --hook pre-commit-check
```

## What it does

- Runs every `PreToolUse` hook kendex registered for Pi, the project's registry first and then the global one, in registry order; the first refusal stops the tool call and its reason reaches the model.
- Runs a `[[custom-hooks]]` command from your manifest the same way, as written.
- Refuses the tool call when a guard could not judge it: a missing rendered script, a timeout, a registry that exists but cannot be read, or an exit status that is neither allow nor refuse.
- Reads a project's registry and project settings only once Pi reports the workspace trusted; the global registry always answers.
- Runs workspace clippy once at the end of a turn that edited a `.rs` file and steers the next turn with the errors. Advisory only.
- On a fresh session start runs `kendex check` in the background and hands the model the drift report. Silent when the install is current; never blocks startup and never installs or removes anything.

Only `PreToolUse` hooks are dispatched. kendex registers hooks for other events in the same file, and this carrier does not run them. `block-unsafe-rm` has no Pi port and kendex reports it unsupported for Pi.

## How it works

kendex renders every hook it installs for Pi into `kendex/hooks.json` under `.pi/` in the project and under your global Pi root, keyed by the Pi listener that fires it. On a tool call the carrier reads those registries, hands each matching hook a payload in the shape Claude Code sends (`{tool_name, tool_input}`, tool names in Claude Code's vocabulary, a `path` argument renamed `file_path`), and reads the exit status: 0 allows, 2 refuses with stderr as the reason. Claude Code, Codex and Pi run the same hook scripts, so a change to a hook reaches all three at once.

## Customise

Open `/extensions:settings`; settings appear under the **Hooks** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: master toggle; a custom hook has no toggle of its own and rides this one.
- `blockBareCd`, `blockRepoCopy`, `preCommitCheck`: one toggle per shipped guard.
- `taskCompletedCheck`, `sessionDriftCheck`: the end-of-turn clippy advisory and the session-start drift report.
- `hookTimeoutMs`, `clippyTimeoutMs`, `driftCheckTimeoutMs`: the time budgets; a hook past its budget refuses the call.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
