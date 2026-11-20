---
name: agent-runtime
description: "Load to launch, inspect, deliver to or stop one coding-harness session through the agent-runtime CLI or Rust library."
license: MIT
user-invocable: true
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
compatibility: "Requires these commands on PATH: cargo"
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->

Before changing this skill's scripts, runtime or tests, read DEVELOPMENT.md.
<!-- kendex:project-instructions:end -->

# Agent Runtime

```bash
.agents/skills/agent-runtime/scripts/setup                       # once per source revision, into the user cache
.agents/skills/agent-runtime/scripts/setup --detach --hold PATH  # from a caller that must answer while it builds
.agents/skills/agent-runtime/scripts/agent-runtime <verb> --help
```

This package owns launch, account selection under the caller's policy, session identity, delivery, handoff and stop for one harness session. It holds no GitHub policy, issue classification, report format, personal task or fleet schedule. A caller supplies its intent and policy and reads typed results.

## Rules

- Start, read, hand work to and stop a session through `launch`, `inspect`, `deliver` and `stop`. `probe`, `judge`, `session-file`, `rows` and `process` are the reads behind them. `accounts` holds the account judge, `controller` the controller's hand-over, `session` the calling session's own record, and `subagent` the subagent spawns. Write no harness flag, process classifier or stop sequence of your own.
- Every verb prints one JSON reply on stdout. Its `protocol` is `agent-runtime-v1`. `ok` is true with a `result`, or false with a `refusal` of `key`, `fields` and `text`. A refusal also prints `agent-runtime: <key> field=value ...` on stderr and exits 1. A malformed command line prints `agent-runtime: usage` and exits 2. Route on the key, never the text. Refuse a reply whose protocol you do not know.
- An effect reports one outcome: `not-started`, `confirmed`, `failed` or `unconfirmed`. Reconcile an `unconfirmed` effect before you ask for the same effect again.
- `deliver` types text only where the judge reads the pane `idle`. It presses a `--key` only where the judge reads a dialog, `asking` or `rate-limit-switch`.
- A `deliver` receipt confirms only equal text after the cursor. Any other new row answers `unconfirmed`.
- `deliver --no-paste` types nothing. It checks `--line`, `--file` or the `--line-digest` checksum of the normalized text after `--turns-before`. With no text, it reads the state and the turn count.
- `deliver --force` is for a probe that knows better, never for a workflow.
- Stop a session by its recorded identity. `stop` signals the pid and start time the launch record holds, and the harness processes below it, each only while its start time still matches. Never stop a session by process name or by a pid alone.
- `launch` writes the launch record, a locked, revisioned JSON file. `inspect` heals the record as the harness comes up. Pass the same file to every later verb. Every write keeps the fields the runtime does not know.
- Charge a worker that runs outside an orch lane to its account. Start it with no controlling terminal: `agent-runtime process lead --file <root>/workers/<name> --account <config dir> -- <program>`. `<root>` is the account records root, `AGENT_RUNTIME_ACCOUNT_STATE_DIR`. While the worker's group runs, every account pick charges that account. A file outside `workers/` is refused. The caller owns the file: lead again under the same name, or remove the file after the worker ends.

## Confinement

A launch intent that names `grants` runs the harness inside a kernel boundary. On Linux the runtime runs it under `bwrap`: the whole tree read-only, a private `/tmp`, the user's runtime folder hidden, and only the granted paths bound back writable. Every process the harness starts runs inside too. A controller's intent names no grants, so a controller runs unconfined.

Inside, `TMPDIR` and each harness's own temporary-folder variable name the private `/tmp`, whatever the pane inherited (`TEMP_VARS` in `runtime/src/confine.rs`).

The account seat a confined lane runs on is read-only, except the session folders its harness writes. `Harness::home_writes` in `runtime/src/harness.rs` names those folders per harness. The runtime grants a folder that is a link where the link leads, and refuses the launch for a link that leads nowhere. A Codex home and a Pi root are granted whole, with the settings file read-only. Each of Pi's `extensions/`, `hooks/` and `packages/`, and each of Codex's `hooks.json`, `hooks/`, `AGENTS.md` and `rules/`, stays read-only where it exists. The launch writes an absent Codex `hooks.json` in its empty form and makes an absent `rules/` empty. It creates no other absent entry, so the lane can create one.

- Copilot CLI runs unconfined on every host.
- A launch whose grants name an `unconfined` cause runs unconfined under it.
- Every harness runs unconfined on a host other than Linux.
- The launch record names the answer and its cause. No setting changes it.

Inside the boundary:

- `AGENT_RUNTIME_CONFINED` is `1`, and `AGENT_RUNTIME_GRANTS` names the grants file. Read that file before you write outside the working tree: the kernel refuses a write outside the grants.
- The tmux and session-bus sockets are out of reach.
- `GH_TOKEN` is set where the grants hand over a token file.
- A job the runtime starts from inside runs under `setsid`, never a systemd unit, so it stays inside.

## Build and run

`scripts/setup` builds the runtime with `cargo build --release --locked` into the user cache, under a key over its sources. `setup --help` names the cache, the key's inputs and the binary's path. A dirty tree builds under its own key. A key already built builds nothing. Setup builds nothing into the installed files.

- Offline, pass `--offline`. The build then needs every locked dependency in the cargo cache.
- `setup --runtime DIR --name NAME` builds another skill's runtime crate that depends on this one. That skill's wrapper computes the key through `scripts/lib/key.sh`. orch's `scripts/setup` and `scripts/orch-runtime` are that pair.
- Inside a confined orch lane, `AGENT_RUNTIME_CACHE` names the lane's own cache, and the shared cache is read-only.

`scripts/agent-runtime` runs the binary built from the sources beside it. Without that binary it builds nothing. It prints `agent-runtime: setup-required key=<key> run=<path to scripts/setup>` on stderr and exits 69. Run setup before a hook or caller needs the binary.

A caller that must answer while the binary is missing, such as a harness hook, runs `setup --detach`. `--detach` starts at most one build per key and answers at once. It does not start a key that ended unbuilt again; run setup without `--detach` for that key. `setup --help` states every answer and cause, and the exits `--hold PATH` gives while PATH exists.

## Reading routes

- A person installing or choosing the package: [README.md](README.md).
- A maintainer building, testing or probing it: the package's `DEVELOPMENT.md` in the catalog.
- Flags, defaults and each verb: `agent-runtime <verb> --help`.
