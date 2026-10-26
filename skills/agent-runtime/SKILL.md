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
.agents/skills/agent-runtime/scripts/setup                        # once per source revision, into the user cache
.agents/skills/agent-runtime/scripts/agent-runtime <verb> --help
```

This package owns reusable launch, account-selection mechanics under caller policy, session identity, delivery, handoff and stop. It holds no GitHub policy, issue classification, report formatting, personal tasks or fleet scheduling: a caller supplies its intent and policy and consumes typed results.

- One execution contract. A session is started, inspected, handed work and stopped through the CLI verbs `launch`, `inspect`, `deliver` and `stop`, or through the same operations in the `agent_runtime` library crate; `session`, `probe`, `judge` and `process` are the reads behind them. A caller writes no harness flag, process classifier or stop sequence of its own.
- Every verb prints one JSON reply on stdout: `protocol` is `agent-runtime-v1`, `ok` is true with a `result` or false with a `refusal` of `key`, `fields` and `text`, never both. A refusal also prints one line `agent-runtime: <key> field=value ...` on stderr and exits 1. Route on the key, never on the text, and refuse a reply whose protocol you do not know.
- An effect reports an `Outcome`: `not-started`, `confirmed`, `failed` or `unconfirmed`. Reconcile an `unconfirmed` effect before asking for the same effect again.
- `deliver` refuses unless the judge reads the pane `idle`; the refusal names the state it read. `--force` is for a probe that knows better, never for a workflow.
- Stop by recorded identity. `stop` signals the pid and start time the launch record holds, and the harness processes below it, each only while its start still matches. Never stop a session by process name or by a pid alone.
- The launch record is a locked, revisioned JSON file written by `launch` and healed by `inspect`; pass the same file to every later verb. Unknown fields in it survive every write.
- Build route: `scripts/setup` builds the runtime with `cargo build --release --locked` into the user cache, `$AGENT_RUNTIME_CACHE`, else `$XDG_CACHE_HOME/kendex/agent-runtime`, else `~/.cache/kendex/agent-runtime`, under a key that is one sha256 over `runtime/Cargo.toml`, `Cargo.lock` and every file under `src/`, and places the binary at `<cache>/bin/agent-runtime-<key>` in one rename. A dirty tree builds its own key; a repeated setup for an existing key builds nothing. Offline, pass `--offline`; the build then needs every locked dependency in the cargo cache. Nothing is built into the installed files.
- Run through `scripts/agent-runtime`, which runs the binary for the sources beside it. Without that binary it prints `agent-runtime: setup-required key=<key> run=<path to scripts/setup>` on stderr and exits 69, and builds nothing: run setup before a hook or caller needs the binary, since nothing compiles on a hook path or a status read.

## Reading routes

- A person installing or choosing the package: [README.md](README.md).
- A maintainer building, testing or probing it: the package's `DEVELOPMENT.md` in the catalog.
- Flags, defaults and verb descriptions: `agent-runtime <verb> --help`.
