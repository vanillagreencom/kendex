---
name: agent-runtime
description: "Load to launch, inspect, deliver to or stop one coding-harness session through the agent-runtime CLI or Rust library."
summary: "Shared agent execution: launch, observe, deliver to and stop one Claude Code, Codex, Copilot CLI or Pi session, with every process and session identity held exactly."
license: MIT
user-invocable: true
dependencies:
  commands:
    - command: cargo
      purpose: Build the runtime from source
      floor: "1.96"
    - command: tmux
      purpose: Host a session in a pane on a private server
      optional: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [automation]
---

# Agent Runtime

```bash
.agents/skills/agent-runtime/scripts/setup                       # once per source revision, into the user cache
.agents/skills/agent-runtime/scripts/setup --detach --hold PATH  # from a caller that must answer while it builds
.agents/skills/agent-runtime/scripts/agent-runtime <verb> --help
```

This package owns launch, account selection under the caller's policy, session identity, delivery, handoff and stop for one harness session. It holds no GitHub policy, issue classification, report format, personal task or fleet schedule. A caller supplies its intent and policy and reads typed results.

## Rules

- Start, read, hand work to and stop a session through `launch`, `inspect`, `deliver` and `stop`. `probe`, `judge`, `session-file`, `rows` and `process` are the reads behind them; `accounts`, `controller`, `session` and `subagent` hold the account judge, the controller's hand-over, the calling session's own record and subagent spawns. Write no harness flag, process classifier or stop sequence of your own.
- Every verb prints one JSON reply on stdout. `protocol` is `agent-runtime-v1`; `ok` is true with a `result`, or false with a `refusal` of `key`, `fields` and `text`. A refusal also prints `agent-runtime: <key> field=value ...` on stderr and exits 1; a malformed command line prints `agent-runtime: usage` and exits 2. Route on the key, never the text, and refuse a reply whose protocol you do not know.
- An effect reports an outcome: `not-started`, `confirmed`, `failed` or `unconfirmed`. Reconcile an `unconfirmed` effect before asking for the same effect again.
- `deliver` types text only where the judge reads the pane `idle`, and presses a `--key` only where it reads a dialog, `asking` or `rate-limit-switch`; a refusal names the state it read. A receipt confirms only equal text after the cursor, with CR and CRLF normalized to LF and trailing whitespace removed per line and at the end; Claude Code's `<pasted_content>` wrapper of a long paste is read as its inner text; other new rows answer `unconfirmed cause=turn-unmatched`. `--no-paste` checks `--line`, `--file` or the normalized text's `--line-digest` checksum after `--turns-before` without typing; with no text it reads the state and count. `--force` is for a probe that knows better, never for a workflow.
- Stop by recorded identity. `stop` signals the pid and start time the launch record holds, and the harness processes below it, each only while its start still matches. Never stop a session by process name or by a pid alone.
- `launch` writes the launch record, a locked, revisioned JSON file; `inspect` heals it as the harness comes up. Pass the same file to every later verb. Fields the runtime does not know survive every write.
- Charge a worker that runs outside an orch lane to its account. Start it with no controlling terminal as `agent-runtime process lead --file <root>/workers/<name> --account <config dir> -- <program>`, where `<root>` is the account records root, `AGENT_RUNTIME_ACCOUNT_STATE_DIR`. Every account pick charges that account while the worker's group runs. A file outside `workers/` refuses `group-file-uncounted`. The caller owns the file: lead again under the same name, or remove it after the worker ends.

## Confinement

A launch intent that names `grants` runs the harness inside a kernel boundary. On Linux the line runs it under `bwrap`: the whole tree read-only, a private `/tmp`, the user's runtime folder hidden, and only the granted paths bound back writable. Every process the harness starts is inside too. A controller's intent names no grants and runs unconfined.

Inside, `TMPDIR` and each harness's own temporary-folder variable name the private `/tmp`, whatever the pane inherited (`TEMP_VARS` in `runtime/src/confine.rs`).

An account seat a confined lane runs on is read-only except the session folders its harness writes, named per harness by `Harness::home_writes` in `runtime/src/harness.rs`; a folder that is a link is granted where it leads, and one that leads nowhere refuses the launch. A Codex home and a Pi root are granted whole, with the settings file read-only, and each of Pi's `extensions/`, `hooks/` and `packages/` read-only where it stands. The launch makes none that is absent, so the lane can make one.

- Copilot CLI runs unconfined on every host, `cause=token-on-session-bus`.
- Every harness runs unconfined on a host other than Linux, `cause=macos-profile-unbuilt`.
- The launch record names the answer, `confined` or `unconfined` with its cause. No setting changes it.

Inside the boundary:

- `AGENT_RUNTIME_CONFINED` is `1`, and `AGENT_RUNTIME_GRANTS` names the grants file. Read it before writing outside the working tree: the kernel refuses a write outside the grants.
- `TMPDIR` is `/tmp`, a folder private to the session.
- The tmux and session-bus sockets are out of reach. `GH_TOKEN` is set where the grants hand a token file.
- A job the runtime starts from inside runs under `setsid`, never a systemd unit, so it stays inside.

## Build and run

`scripts/setup` builds the runtime with `cargo build --release --locked` into the user cache: `$AGENT_RUNTIME_CACHE`, else `$XDG_CACHE_HOME/kendex/agent-runtime`, else `~/.cache/kendex/agent-runtime`. The key is one sha256 over `runtime/Cargo.toml`, `Cargo.lock`, every file under `src/` and the same inputs of every path dependency. The binary lands at `<cache>/bin/agent-runtime-<key>` in one rename. A dirty tree builds its own key, and a key already built builds nothing. Nothing is built into the installed files.

- Offline, pass `--offline`. The build then needs every locked dependency in the cargo cache.
- `setup --runtime DIR --name NAME` builds another skill's runtime crate that depends on this one, at `<cache>/bin/NAME-<key>`. That skill's wrapper computes the key through `scripts/lib/key.sh`. orch's `scripts/setup` and `scripts/orch-runtime` are that pair.
- Inside a confined orch lane, `AGENT_RUNTIME_CACHE` names the lane's own cache, and the shared cache is read-only.

`scripts/agent-runtime` runs the binary for the sources beside it. Without that binary it builds nothing: it prints `agent-runtime: setup-required key=<key> run=<path to scripts/setup>` on stderr and exits 69. Run setup before a hook or caller needs the binary.

A caller that must answer while the binary is missing, such as a harness hook, runs `setup --detach`. It starts at most one build per key and answers at once with `key=<key> binary=<path>`, `runtime-building` or `runtime-unbuilt cause=<cause>`. With `--hold PATH`, while PATH exists, a running build exits 3 every time and an unbuilt key exits 3 once per PATH and cause. A key that ended unbuilt is not started again by `--detach`; a setup without `--detach` is the remedy. `setup --help` states every answer and cause.

## Reading routes

- A person installing or choosing the package: [README.md](README.md).
- A maintainer building, testing or probing it: the package's `DEVELOPMENT.md` in the catalog.
- Flags, defaults and each verb: `agent-runtime <verb> --help`.
