# Agent Runtime

A command and Rust library that starts one AI coding-agent session, watches it, hands it work and stops it. It is for people and packages that run coding agents on one machine and must start, find and stop each session exactly.

## Features

- Turns one launch request into the command line for Claude Code, Codex, Copilot CLI or Pi.
- Records which process each session runs, and stops exactly that process tree.
- Runs the session in a tmux pane on a private server, which it confirms before every read and write.
- Runs a worker's session in a sandbox on Linux.
- Tells whether a session is idle, working, asking, stopped by an account limit or exited, and says so when it cannot tell.
- Finds the session file each harness writes for a working directory.
- Reads from a session's file what it loaded into its context: the tokens its first turn left, the context by source and each rule section it read, each figure marked measured, attributed, unclear or unsupported.
- Reads how much use each account has left and picks the account a launch uses.
- Keeps launch records as JSON that another package can add its own fields to.
- Answers most commands with one versioned JSON reply, `agent-runtime-v1`.
- Builds into a user cache through its setup command, once per source revision. Where cargo is installed, the first command after a source change builds it. Without cargo, it refuses to run before that build exists.
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

- Rust 1.96 or later.
- The build lands in the user cache `setup --help` names, never in the installed files.
- Offline, run `setup --offline` with a populated cargo cache, or reuse a runtime already built from the same sources.

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
| Linux | Supported. |
| macOS | Sessions run outside the sandbox. |
| Windows | Sessions are unsupported. |

- On Linux, a launch whose grants ask for the sandbox runs in it.
- [SKILL.md § Confinement](SKILL.md#confinement) names the launches that run outside it.
- On Windows, only the library's logic builds and is tested.

## Setup

- Settings live under `[env]` in `kendex.settings.toml` or `.kendex/settings.toml`.
- A personal value goes in `.env.local`.
- `agent-runtime <verb> --help` names the settings each command reads.
- To look up defaults, start with the orch skill's `references/settings.md`.

| Setting | What it changes |
| --- | --- |
| `AGENT_RUNTIME_ACCOUNT_DIRS` | The account folders a launch may pick from, separated by `:`. |
| `AGENT_RUNTIME_LAUNCH_PERMISSION` | Whether a launch runs unattended or keeps the harness's own prompts. |
| `AGENT_RUNTIME_HARNESS_BINARIES` | Where a harness is installed when it is not on `PATH`, as `harness=/absolute/path` pairs. |
| `AGENT_RUNTIME_ACCOUNT_STATE_DIR` | Where account usage and limit records live: an absolute or `~/` path. |
| `AGENT_RUNTIME_ACCOUNT_TOKEN_FILES` | The token file each Claude account signs in with, as `<account dir>=<token file>` pairs. |

- `AGENT_RUNTIME_LAUNCH_PERMISSION=bypass` runs every launch unattended.
- `AGENT_RUNTIME_LAUNCH_PERMISSION=native` keeps the harness's own prompts.
- `AGENT_RUNTIME_ACCOUNT_TOKEN_FILES` names paths, never a token.
- The account walk and a hand-over judge a declared account by its file alone, and any other account by its stored login.
- A hand-over's, an orch local lane's or `agent-runtime launch`'s launch on a declared account exports the file's text as `CLAUDE_CODE_OAUTH_TOKEN`. An orch cloud session exports no file and signs in by its account's stored login.
- A launch on a named Claude account, a Pi `pi-claude/` seat among them, clears the Claude credentials its window inherits, so it signs in as that account alone.
- A hand-over's, an orch local lane's or `agent-runtime launch`'s launch on an account holding no sign-in refuses `successor-not-signed-in` before any window opens.
- Declare `AGENT_RUNTIME_ACCOUNT_TOKEN_FILES` in `kendex.settings.toml` `[env]`, `.env.local` or the tmux server's environment, which every new session inherits.

## Licence

MIT, in the repository's LICENSE file.
