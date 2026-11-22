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
.agents/skills/agent-runtime/scripts/agent-runtime <verb> --help # each verb's flags and defaults; --help alone lists the verbs
```

This package owns launch, account selection under the caller's policy, session identity, delivery, handoff and stop for one harness session. It holds no GitHub policy, issue classification, report format, personal task or fleet schedule. A caller supplies its intent and policy and reads typed results.

## Rules

- Start, read, hand work to and stop a session through `launch`, `inspect`, `deliver` and `stop`. Write no harness flag, process classifier or stop sequence of your own.
- Every verb prints one JSON reply on stdout, except `session model`, `process lead`, which becomes its program, and `accounts pick --env`. Each one's `--help` states its output. A reply's `protocol` is `agent-runtime-v1`. `ok` is true with a `result`, or false with a `refusal` of `key`, `fields` and `text`. A refusal also prints `agent-runtime: <key> field=value ...` on stderr and exits 1. A malformed command line prints `agent-runtime: usage` and exits 2. Route on the key, never the text. Refuse a reply whose protocol you do not know.
- An effect reports one outcome: `not-started`, `confirmed`, `failed` or `unconfirmed`. Reconcile an `unconfirmed` effect before you ask for the same effect again. For `deliver`, run `deliver --no-paste` with the same text and the reply's `turns_before` as `--turns-before`.
- `deliver --force` is for a probe that knows better, never for a workflow.
- Stop a session with `stop`, by its recorded identity. Never stop a session by process name or by a pid alone.
- `launch --intent` reads a JSON object whose members are the fields of `LaunchIntent` in `runtime/src/launch.rs`. `grants` takes the fields of `Grants` in `runtime/src/confine.rs`. `launch` ignores a member it does not know.
- `launch` writes the launch record, and `inspect` heals it as the harness comes up. Pass the same file to every later verb.
- Charge a worker that runs outside an orch lane to its account: start it with `agent-runtime process lead --file <root>/workers/<name> --account <config dir> -- <program>`. `<root>` is the account records root, `AGENT_RUNTIME_ACCOUNT_STATE_DIR`.

## Confinement

A launch intent that names `grants` runs the harness inside a kernel boundary. On Linux the runtime runs it under `bwrap`: the whole tree read-only, a private `/tmp`, the user's runtime folder hidden, and only the granted paths bound back writable. Every process the harness starts runs inside too. A controller's intent names no grants, so a controller runs unconfined.

- Copilot CLI runs unconfined on every host.
- A launch whose grants name an `unconfined` cause runs unconfined under it.
- Every harness runs unconfined on a host other than Linux.
- The launch record names the answer and its cause. No setting changes it.

A misspelled `grants` member launches the harness unconfined, with no refusal. After a launch that must run confined, read the record's `confinement`: its `state` is `confined`, or `unconfined` with a `cause`. A record with no `confinement` comes from an intent that named no grants.

In the account seat it runs on, a confined Claude Code lane writes only the session folders `Harness::home_writes` in `runtime/src/harness.rs` names. A confined Codex or Pi lane writes its whole home, except its settings file and the code entries `home_writes` names.

Inside the boundary, `AGENT_RUNTIME_CONFINED` is `1`, and `AGENT_RUNTIME_GRANTS` names the grants file. Read that file before you write outside the working tree: the kernel refuses a write outside the grants.

## Build and run

`scripts/agent-runtime` runs the binary built from the sources beside it. Without that binary it builds nothing. It prints `agent-runtime: setup-required key=<key> run=<path to scripts/setup>` on stderr and exits 69. `setup --help` states every answer and cause of `setup` and `setup --detach`.

`setup --runtime DIR --name NAME` builds another skill's runtime crate that depends on this one. That skill's wrapper computes the key through `scripts/lib/key.sh`. orch's `scripts/setup` and `scripts/orch-runtime` are that pair.

## Reading routes

- A person installing or choosing the package: [README.md](README.md).
- A maintainer building, testing or probing it: the package's `DEVELOPMENT.md` in the catalog.
