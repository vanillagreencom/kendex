# Agent Runtime

A command and Rust library that starts one AI coding-agent session, watches it, hands it work and stops it. It is for people and packages that run coding agents on a machine and need every session started, found and stopped exactly.

## Features

- Turns one launch intent into the command line for Claude Code, Codex, Copilot CLI or Pi.
- Records each session's process as a pid with its start time, and stops exactly that process tree.
- Runs the session in a tmux pane on a private server it confirms before every read and write.
- Judges a screen as idle, working, asking, walled, exited or unjudged with one reader.
- Finds the session file each harness writes for a working directory.
- Keeps launch records as locked, revisioned JSON that preserves fields it does not know.
- Answers every command with one versioned JSON reply, `agent-runtime-v1`.
- Builds itself once into a user cache keyed by its own sources, and refuses to run until that build exists.

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

You write a small JSON file that names the harness, the directory, the permission posture and the file holding the first instruction. The runtime opens a window on a tmux server, starts the harness in it and writes a record of what it started. Later commands read that record to see whether the session is waiting, paste new work into it only when it is, and stop the process they started and nothing else. Each harness's own session file is read as data for its identity.

## Harnesses

| Harness | Support | Tested on |
|---|---|---|
| Claude Code | first-class | 2.1.310, 2026-10-26, Linux 7.3.0-5-cachyos, private tmux server with pane paste |
| Codex | first-class | 0.164.0, 2026-10-26, Linux 7.3.0-5-cachyos, private tmux server with pane paste |
| Copilot CLI | first-class | 1.0.103, 2026-10-26, Linux 7.3.0-5-cachyos, private tmux server with pane paste |
| Pi | first-class | 1.4.0, 2026-10-26, Linux 7.3.0-5-cachyos, private tmux server with pane paste |

Any other harness is untested. The runtime refuses a harness name it does not know.

## Platforms

| Platform | Route |
|---|---|
| Linux | Supported: build, tmux host, process identity from `/proc`. |
| macOS | Supported: build, tmux host, process identity from `ps`. |
| Windows | Pure logic and protocol only. The tmux route is unproved. |

## Licence

MIT, in the repository's LICENSE file.
