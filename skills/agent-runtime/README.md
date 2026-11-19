# Agent Runtime

A command and Rust library that starts one AI coding-agent session, watches it, hands it work and stops it. It is for people and packages that run coding agents on one machine and must start, find and stop each session exactly.

## Features

- Turns one launch intent into the command line for Claude Code, Codex, Copilot CLI or Pi.
- Records each session's process as a pid with its start time, and stops exactly that process tree.
- Runs the session in a tmux pane on a private server, which it confirms before every read and write.
- Runs a worker's session inside a kernel boundary on Linux, writable only where its launch grants.
- Judges a screen as idle, working, asking, walled, exited or unjudged, with one reader.
- Finds the session file each harness writes for a working directory.
- Reads each account's plan room and picks the account a launch spends.
- Keeps launch records as locked, revisioned JSON that preserves fields it does not know.
- Answers every command with one versioned JSON reply, `agent-runtime-v1`.
- Builds itself once into a user cache keyed by its own sources, and refuses to run before that build exists.
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

| Harness | Support | Runs inside the boundary | Tested on |
|---|---|---|---|
| Claude Code | first-class | on Linux | 2.1.310, 2026-10-26, Linux 7.3.0-5-cachyos, private tmux server with pane paste |
| Codex | first-class | on Linux | 0.164.0, 2026-10-26, Linux 7.3.0-5-cachyos, private tmux server with pane paste |
| Copilot CLI | first-class | never: it reads its login over the session bus the boundary hides | 1.0.103, 2026-10-26, Linux 7.3.0-5-cachyos, private tmux server with pane paste |
| Pi | first-class | on Linux | 1.4.0, 2026-10-26, Linux 7.3.0-5-cachyos, private tmux server with pane paste |

Any other harness is untested. The runtime refuses a harness name it does not know.

## Platforms

| Platform | Route |
|---|---|
| Linux | Supported: build, tmux host, process identity from `/proc`, the boundary through `bwrap`. |
| macOS | Supported: build, tmux host, process identity from `ps`. Every session runs outside the boundary. |
| Windows | Pure logic and protocol only. The tmux route is unproved. |

## Setup

Settings live under `[env]` in `kendex.settings.toml` or `.kendex/settings.toml`. A personal value goes in `.env.local`. `agent-runtime <verb> --help` names the settings each command reads. orch's `references/settings.md` holds each default.

| Setting | What it changes |
| --- | --- |
| `AGENT_RUNTIME_ACCOUNT_DIRS` | The account folders a launch may pick from, separated by `:`. |
| `AGENT_RUNTIME_LAUNCH_PERMISSION` | `bypass` runs every launch unattended. `native` keeps the harness's own prompts. |
| `AGENT_RUNTIME_HARNESS_BINARIES` | Where a harness is installed when it is not on `PATH`, as `harness=/absolute/path` pairs. |
| `AGENT_RUNTIME_ACCOUNT_STATE_DIR` | Where account usage and wall records live: an absolute or `~/` path. |

## Licence

MIT, in the repository's LICENSE file.
