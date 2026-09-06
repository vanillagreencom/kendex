# @vanillagreen/pi-hooks

A Pi extension that runs hooks installed by kendex. It checks tool calls, hands hook output to the agent after a tool call, at the end of a turn and at session start, and can report Rust errors and installation drift to the agent.

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
- Run installed PostToolUse, Stop, TaskCompleted and SessionStart hooks and give the agent what they say.
- Run configured custom hooks.
- Report clippy errors after Rust edits.
- Report installation drift when a session starts.

## How it works

- kendex installs the hook scripts, and a registry: the list of which hook runs on which event.
- Before Pi runs a tool, this extension reads the registry for your user account, and the project's own registry once Pi has marked the workspace trusted.
- It gives each hook whose matcher fits the tool's name and the arguments it was called with, and stops at the first refusal.
- Pi runs the tool only once every one of those hooks has allowed the call.

The other hook events cannot stop anything in Pi, so the extension delivers what a hook says instead:

| Hook event | Pi listener | What happens with the hook's output |
| --- | --- | --- |
| `PostToolUse` | `tool_result` | Appended to the tool result the agent reads. |
| `Stop`, `TaskCompleted` | `turn_end`, read once per response on `agent_settled` | Sent to the agent once as a message that starts the next turn. A hook's answer to that message runs the hooks again with `stop_hook_active: true` and is not sent back, so a response runs them at most twice. |
| `SessionStart` | `session_start` | Added to the session's opening context. |

- Every hook whose matcher fits runs on those three events.
- A hook that exits `2` hands the agent what it wrote to its error output, and one that exits `0` hands over what it wrote to its normal output.
- Any other exit status is reported to the agent as a hook that reached no verdict; a hook that ran out of time, or whose script is missing, is reported as one that did not run.
- A `PostToolUse` matcher is matched against the tool's name, and a `SessionStart` matcher against why the session started: `startup`, `resume` or `clear`.
- `Stop` and `TaskCompleted` hooks take no matcher, so both always run.

## Settings

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-hooks"]`.

Open `/extensions:settings`; settings appear under the **Hooks** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: package toggle; a custom hook has no toggle of its own and rides this one.
- `blockBareCd`, `blockRepoCopy`, `preCommitCheck`: one toggle per shipped guard.
- `taskCompletedCheck`, `sessionDriftCheck`: the end-of-turn clippy advisory and the session-start drift report. These two run natively and are not in the registry; the same setting also turns off a registered `task-completed-check` or `session-drift-check` hook.
- `hookTimeoutMs`, `clippyTimeoutMs`, `driftCheckTimeoutMs`: the time budgets; a hook past its budget refuses the call.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
