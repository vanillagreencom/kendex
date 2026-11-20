# Agent Runtime

A command and Rust library that starts one AI coding-agent session, watches it, hands it work and stops it. It is for people and packages that run coding agents on one machine and must start, find and stop each session exactly.

## Features

- Turns one launch request into the command line for Claude Code, Codex, Copilot CLI or Pi.
- Records which process each session runs, and stops exactly that process tree.
- Runs the session in a tmux pane on a private server, which it confirms before every read and write.
- Runs a worker's session in a sandbox on Linux.
- Tells whether a session is idle, working, asking, stopped by an account limit or exited, and says so when it cannot tell.
- Finds the session file each harness writes for a working directory.
- Reads how much use each account has left and picks the account a launch uses.
- Keeps launch records as JSON that another package can add its own fields to.
- Answers every command with one versioned JSON reply, `agent-runtime-v1`.
- Builds itself once into a user cache, rebuilds when its sources change, and refuses to run before that build exists.
- Builds a dependent package's runtime, such as orch's, the same way.

## Install

```sh
kendex add vanillagreencom/kendex --skill agent-runtime
```

```sh
.agents/skills/agent-runtime/scripts/setup
```

```sh
.agents/skills/agent-runtime/scripts/agent-runtime --help
```

Rust 1.96 or later. The build lands in the user cache `setup --help` names, never in the installed files. Offline, run `setup --offline` with a populated cargo cache, or reuse a runtime already built from the same sources.

## How it works

You write a small JSON file. It names the harness, the folder, how far the harness may act without asking, and the file that holds the first instruction. The runtime opens a window on a tmux server, starts the harness there and records what it started. Later commands read that record. They paste new work only while the session waits, and they stop only the process the runtime started. A worker's file can also name the folders the worker may change. On Linux, that session can change nothing else.

## Harnesses

| Harness | Runs in the sandbox | Tested version |
|---|---|---|
| Claude Code | on Linux | 2.1.310 |
| Codex | on Linux | 0.164.0 |
| Copilot CLI | never: the sandbox would hide its sign-in | 1.0.103 |
| Pi | on Linux | 1.4.0 |

Each version was tested on Linux on 2026-10-26. The runtime refuses a harness name it does not know.

## Platforms

| Platform | Support |
|---|---|
| Linux | Supported, with the sandbox. |
| macOS | Supported. Every session runs outside the sandbox. |
| Windows | Sessions are unsupported; only the library's logic builds and is tested. |

## Setup

Settings live under `[env]` in `kendex.settings.toml` or `.kendex/settings.toml`. A personal value goes in `.env.local`. `agent-runtime <verb> --help` names the settings each command reads. orch's `references/settings.md` holds each default.

| Setting | What it changes |
| --- | --- |
| `AGENT_RUNTIME_ACCOUNT_DIRS` | The account folders a launch may pick from, separated by `:`. |
| `AGENT_RUNTIME_LAUNCH_PERMISSION` | `bypass` runs every launch unattended. `native` keeps the harness's own prompts. |
| `AGENT_RUNTIME_HARNESS_BINARIES` | Where a harness is installed when it is not on `PATH`, as `harness=/absolute/path` pairs. |
| `AGENT_RUNTIME_ACCOUNT_STATE_DIR` | Where account usage and limit records live: an absolute or `~/` path. |

## Licence

MIT, in the repository's LICENSE file.
