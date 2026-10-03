# @vanillagreen/pi-hooks

A Pi extension that runs hooks installed by kendex. It checks tool calls, hands hook output to the agent after a tool call, at the end of a turn and at session start, and can report Rust errors and installation drift to the agent. It also starts a turn in an idle session that the lane-mail hooks hand mail to: an orch lane when its overseer's mail lands, or a session reading its checkout's overseer mailbox.

## Install

- npm: `pi install npm:@vanillagreen/pi-hooks`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-hooks"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation. Install the hooks separately with kendex, for example `kendex add --hook block-bare-cd --hook block-repo-copy --hook pre-commit-check`.

## Features

- Run installed PreToolUse hooks before Pi tool calls and give their additionalContext to the agent in interactive and headless sessions.
- Stop a tool call when a hook refuses it or cannot complete.
- Run installed PostToolUse, Stop, TaskCompleted and SessionStart hooks and give the agent what they say.
- Run installed StopFailure hooks when a run ends on an error, and SessionEnd hooks when a session ends, and show you what they say.
- Run configured custom hooks.
- Report clippy errors after Rust edits.
- Report installation drift through the native check's `kendex-drift` message in lead sessions, not delegated children. Registered `SessionStart` hook output (`kendex-hook`) remains unchanged.
- In a lane, report installation-repair suggestions as item counts and send a worktree notice even when the install is current. The overseer refreshes the base checkout after merge. A refresh lane, one whose launch wrote orch's refresh record, gets a notice that `kendex refresh` and `kendex apply` run there only with `--lane-refresh`, and its report whole. If lane detection fails, report the unknown status without drift details.
- Wake an idle session the lane-mail hooks hand mail to.

## How it works

- kendex installs the hook scripts, and a registry: the list of which hook runs on which event.
- Before Pi runs a tool, this extension reads the registry for your user account, and the project's own registry once Pi has marked the workspace trusted.
- It gives each hook whose matcher fits the tool's name and the arguments it was called with, and stops at the first refusal.
- Pi runs the tool only once every one of those hooks has allowed the call.
- A hook that allows the call can also send context. The agent receives it before the next model request, even when a later hook refuses the call. Error output beside an allowed call remains a UI notice only.

The other hook events cannot stop anything in Pi, so the extension delivers what a hook says instead:

| Hook event | Pi listener | What happens with the hook's output |
| --- | --- | --- |
| `PostToolUse` | `tool_result` | Appended to the tool result the agent reads. |
| `Stop`, `TaskCompleted` | `turn_end`, read once per response on `agent_before_settle` | Added to the session, and Pi runs one more model request inside the same run so the agent answers it. At the end of that request the hooks run again with `stop_hook_active: true`, and what they say then is recorded without another request, so a response runs them at most twice. |
| `SessionStart` | `session_start` | Added to the session's opening context. |
| `StopFailure` | `agent_before_settle`, read only when Pi says the run ended on an error, after the `Stop` and `TaskCompleted` hooks, which still run | Shown to you. The agent does not read it. |
| `SessionEnd` | `session_shutdown`, which Pi waits for before the session ends | Shown to you. The agent does not read it. |

- Every hook whose matcher fits runs on those events.
- On `PostToolUse`, `Stop`, `TaskCompleted` and `SessionStart`, a hook that exits `2` hands the agent what it wrote to its error output, and one that exits `0` hands over what it wrote to its normal output. Any other exit status is reported to the agent as a hook that reached no verdict; a hook that ran out of time, or whose script is missing, is reported as one that did not run.
- On `StopFailure` and `SessionEnd`, the same words and reports go to you instead: as a notification, or on Pi's error output where no notification can be shown, which is a session without a UI and the end of a session you quit.
- A `PostToolUse` matcher is matched against the tool's name, a `SessionStart` matcher against why the session started: `startup`, `resume` or `clear`, and a `SessionEnd` matcher against why it ended: `prompt_input_exit` when you quit Pi, `clear` when a new or forked session follows, and `resume` when a resumed or reloaded one does.
- `Stop`, `TaskCompleted` and `StopFailure` hooks take no matcher, so they always run. Pi does not name the kind of error a run ended on.
- What the hooks on one event say to the agent is kept to Pi's own limit for a tool's output, 2000 lines or 50 KB, whichever comes first, and the end is kept. Past that limit, the whole text goes to a file in the system temporary directory that only its owner can read, and a `hook-output-truncated=<file>` line leads what the agent reads. A file that cannot be written is named as `hook-output-unsaved=<cause>` instead.
- `Stop`, `TaskCompleted` and `StopFailure` hooks need Pi 0.87.0 or later. On an older Pi they do not run, and each fresh session starts with a `hook-host-unsupported=pi <version>` message that says so, and a session with a UI also gets it as a notification.

## Lane mail wake

- The extension watches every mailbox under the checkout's `tmp/lane-mail`, the overseer mailbox included, and checks again each time the session settles.
- A checkout with no `tmp/lane-mail` yet is watched from the nearest directory above it, `tmp` or the checkout root. The first mail makes that directory, and that mail wakes an idle session too.
- While the session is idle it runs the installed `lane-mail-deliver` hook, the hook that hands mail over after a tool call. That hook decides which mailbox this session reads and what in it is unread: an orch lane's own mailbox, or, for a lead session that is no lane, the checkout's overseer mailbox where the hook names it.
- What the hook hands over starts one turn, and the hook marks that mail read. An answer is left to the `lane-mail wait` that asked for it.
- A session that is busy gets its mail from the lane-mail hooks at its next tool call or turn end.
- A subagent is never woken, and the `enabled` setting turns the wake off with the hooks.

## Settings

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-hooks"]`.

Open `/extensions:settings`; settings appear under the **Hooks** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: package toggle; a custom hook has no toggle of its own and rides this one.
- `blockBareCd`, `blockRepoCopy`, `preCommitCheck`: one toggle per shipped guard.
- `taskCompletedCheck`, `sessionDriftCheck`: the end-of-turn clippy advisory and the session-start drift report. These two run natively and are not in the registry; the same setting also turns off a registered `task-completed-check` or `session-drift-check` hook.
- `clippyTimeoutMs`, `driftCheckTimeoutMs`: the time budgets of the two native checks. The end-of-turn clippy check runs beside Pi, so typing and other extensions keep working while it compiles, and ending the turn stops it; the next turn's check covers the edits of the turn that was ended. One clippy run at a time runs for each user on a host: a Pi session that finds another session's run in progress waits for it inside its own budget. A registered hook runs to the `timeout` its registration declares, 60 seconds where it declares none, and one past its budget refuses the call.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
