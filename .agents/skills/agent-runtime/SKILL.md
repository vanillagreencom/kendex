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
.agents/skills/agent-runtime/scripts/agent-runtime <verb> --help # each verb's flags and defaults; --help alone lists the verbs
```

This package owns launch, account selection under the caller's policy, session identity, delivery, handoff and stop for one harness session. It holds no GitHub policy, issue classification, report format, personal task or fleet schedule. A caller supplies its intent and policy and reads typed results.

## Rules

- Start, read, hand work to and stop a session through `launch`, `inspect`, `deliver` and `stop`.
- Write no harness flag, process classifier or stop sequence of your own.
- The reply:
  - Every verb prints one JSON reply on stdout, except `session model`, `process lead`, which becomes its program, and `accounts pick --env`.
  - Each exception's `--help` states its output.
  - A reply's `protocol` is `agent-runtime-v1`.
  - `ok` is true with a `result`, or false with a `refusal` of `key`, `fields` and `text`.
  - A refusal also prints `agent-runtime: <key> field=value ...` on stderr and exits 1.
  - A malformed command line prints `agent-runtime: usage` and exits 2.
  - Route on the key, never the text.
  - Refuse a reply whose protocol you do not know.
- An effect:
  - An effect reports one outcome: `not-started`, `confirmed`, `failed` or `unconfirmed`.
  - Reconcile an `unconfirmed` effect before you ask for the same effect again.
  - For `deliver`, run `deliver --no-paste` with the same text and the reply's `turns_before` as `--turns-before`.
- `deliver --force` is for a probe that knows better, never for a workflow.
- Stop a session with `stop`, by its recorded identity.
- Never stop a session by process name or by a pid alone.
- The launch intent:
  - `launch --intent` reads a JSON object whose members are the fields of `LaunchIntent` in `runtime/src/launch.rs`.
  - `grants` takes the fields of `Grants` in `runtime/src/confine.rs`.
  - `launch` ignores a member it does not know.
- The launch record:
  - `launch` writes the launch record.
  - `inspect` heals it as the harness comes up.
  - Pass the same file to every later verb.
- A worker that runs outside an orch lane:
  - Charge it to its account: start it with `agent-runtime process lead --file <root>/workers/<name> --account <config dir> -- <program>`.
  - `<root>` is the account records root, `AGENT_RUNTIME_ACCOUNT_STATE_DIR`.

## Confinement

A launch intent that names `grants` runs the harness inside a kernel boundary. On Linux the runtime runs it under `bwrap`:

- The whole tree is read-only, with a private `/tmp`.
- Every process the harness starts runs inside too.
- A controller's intent names no grants, so a controller runs unconfined.

The wrapper applies each `Grants` member only as the intent spells it:

- `writable`: each path is bound back writable.
- `read_only`: each path is bound read-only after the writable binds, so it stays read-only inside a writable path.
- Each `read_only` path must exist; the wrapper refuses a missing one.
- `runtime_dir`: the user's runtime folder is hidden, and with it the tmux and session-bus sockets. With no `runtime_dir`, the folder stays in reach.
- `seats`: the launch record names them. The wrapper binds nothing for them, so a seat stays read-only unless `writable` names it.
- `Grants` in `runtime/src/confine.rs` names the other members.

When a launch runs unconfined:

- Copilot CLI runs unconfined on every host.
- A launch whose grants name an `unconfined` cause runs unconfined under it.
- Every harness runs unconfined on a host other than Linux.
- The launch record names the answer and its cause.
- No setting changes it.

Check the answer after a launch that must run confined:

- A misspelled top-level `grants` member launches the harness unconfined, with no refusal.
- Read the record's `confinement`.
- Its `state` is `confined`, or `unconfined` with a `cause`.
- A record with no `confinement` comes from an intent that named no grants.
- `confined` says only that the wrapper runs. A member omitted or misspelled inside `grants` is ignored, and the record still reads `confined`.
- The record's `command_line` shows the binds the wrapper applies.

An account seat:

- An opener reads `Harness::home_writes` in `runtime/src/harness.rs` for a seat's entries. The runtime applies only what the grants list.
- For Claude Code, `home_writes` names the session folders to list in `writable`. The rest of the home stays read-only.
- For Codex and Pi, the whole home goes in `writable`, and `home_writes` names the code entries to list in `read_only`.
- orch's grants also list the seat's settings file in `read_only`.

Inside the boundary:

- `AGENT_RUNTIME_CONFINED` is `1`.
- `AGENT_RUNTIME_GRANTS` names the grants file.
- Read that file before you write outside the working tree: the kernel refuses a write outside the grants.

## Build and run

- `scripts/agent-runtime` runs the binary built from the sources beside it.
- Without that binary it builds nothing. It prints `agent-runtime: setup-required key=<key> run=<path to scripts/setup>` on stderr and exits 69.
- `setup --help` states every answer and cause of `setup` and `setup --detach`.
- `setup --runtime DIR --name NAME` builds another skill's runtime crate that depends on this one.
- That skill's wrapper computes the key through `scripts/lib/key.sh`.
- orch's `scripts/setup` and `scripts/orch-runtime` are that pair.

## Reading routes

- A person installing or choosing the package: [README.md](README.md).
- A maintainer building, testing or probing it: the package's `DEVELOPMENT.md` in the catalog.
