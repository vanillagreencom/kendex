# Agent Runtime

A command and Rust library that starts one AI coding-agent session, watches it, hands it work and stops it. It is for people and packages that run coding agents on a machine and need every session started, found and stopped exactly.

## Features

- Turns one launch intent into the command line for Claude Code, Codex, Copilot CLI or Pi.
- Records each session's process as a pid with its start time, and stops exactly that process tree.
- Runs the session in a tmux pane on a private server it confirms before every read and write.
- Runs a worker's session inside a kernel boundary on Linux, writable only where its launch grants.
- Judges a screen as idle, working, asking, walled, exited or unjudged with one reader.
- Finds the session file each harness writes for a working directory.
- Reads each account's plan room and picks the account a launch spends.
- Keeps launch records as locked, revisioned JSON that preserves fields it does not know.
- Answers every command with one versioned JSON reply, `agent-runtime-v1`.
- Builds itself once into a user cache keyed by its own sources, and refuses to run until that build exists. The same build route serves a package whose runtime depends on this one, such as orch.

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

Rust 1.96 or later. The build lands in `~/.cache/kendex/agent-runtime`, or under `$XDG_CACHE_HOME` or `$AGENT_RUNTIME_CACHE`, never in the installed files. Offline, run `setup --offline` with a populated cargo cache, or reuse a runtime already built from the same sources. A prebuilt binary ships through the kendex release feed only once one is published.

## How it works

You write a small JSON file that names the harness, the folder, the permission posture and the file holding the first instruction. The runtime opens a window on a tmux server, starts the harness in it and writes a record of what it started. Later commands read that record to see whether the session is waiting, paste new work into it only when it is, and stop the process they started and nothing else. A worker's file can also name the folders it may change; on Linux everything else stays read-only to that session.

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

Settings live under `[env]` in `kendex.settings.toml` or `.kendex/settings.toml`, or in `.env.local` for a personal value. `agent-runtime <verb> --help` names the ones each command reads.

| Setting | What it changes |
| --- | --- |
| `AGENT_RUNTIME_ACCOUNT_DIRS` | The account folders, separated by `:`, a launch may pick among. Unset, none. |
| `AGENT_RUNTIME_LAUNCH_PERMISSION` | `bypass`, the default, runs every launch unattended; `native` keeps the harness's own prompts. |
| `AGENT_RUNTIME_HARNESS_BINARIES` | Where a harness is installed when it is not on `PATH`, as `harness=/absolute/path` pairs. |
| `AGENT_RUNTIME_ACCOUNT_STATE_DIR` | Where account usage and wall records live: an absolute or `~/` path. Unset, `kendex/agent-runtime/accounts` under `$XDG_STATE_HOME`, else under `~/.local/state`. |

## Licence

MIT, in the repository's LICENSE file.
