# Pi Codex bridge

Pi Codex bridge adds `pi-codex` models to Pi. Each model runs through the Codex CLI app server and the login that Codex already owns. Pi's tools run in Pi: the bridge offers them to Codex and returns their results.

## Install

```sh
pi install npm:@vanillagreen/pi-codex-bridge
```

The kendex catalog declaration is:

```toml
[pi-extensions."@vanillagreen/pi-codex-bridge"]
source = "kendex"
```

## Requirements

- Pi 0.86 or later.
- Node 22.19 or later.
- Codex CLI 0.163.0 or 0.166.0 on `PATH`. The bridge refuses any other release and offers no model. `package.json` lists the supported releases as its optional `@openai/codex` peer range.
- A Codex login in the bridge home, stored in `<bridge home>/auth.json`. The bridge home is `PI_CODEX_BRIDGE_HOME` when set, else `CODEX_HOME`, else `~/.codex`; a blank value counts as unset. `PI_CODEX_BRIDGE_HOME` gives the bridge a home apart from the one a `codex` run in Pi's tool shell reads.

A login kept in the system keyring (`cli_auth_credentials_store = "keyring"`) has no `auth.json`, so the bridge treats it as absent. Sign in with file storage to use the bridge.

## Features

- Lists the models `codex app-server` reports for the current account.
- Offers Pi's active tools to Codex and runs each call in Pi.
- Continues the same Codex thread across Pi turns, and starts a new thread when Pi's tools, system prompt or history no longer match it.
- Maps Pi's thinking levels to the efforts each Codex model lists.
- Keeps every configured MCP server stopped.
- Refuses Codex's native tools: shell, exec, file edits, browsers and sub-agents.

## Settings

| Setting | Default | Effect |
|---|---|---|
| `enabled` | `true` | Register the `pi-codex` provider. Takes effect after `/reload`. |

## How it works

At startup the extension runs a `codex app-server` child to list the models, then stops it. The first `pi-codex` turn starts one child, which serves the session until `session_shutdown`; a session that never selects a `pi-codex` model holds no child. The child runs with `CODEX_HOME` set to the bridge home, where Codex owns its login, token refresh, thread state and rollouts. The bridge does not read, copy or write a credential file. It writes nothing to Pi settings or Pi `auth.json`.

DEVELOPMENT.md describes the protocol and each guard.

## Usage records

Codex records each bridged turn's token usage in the thread's rollout, which is the store of record. Threads persist because a cold resume after a Pi restart reads the rollout. Pi's assistant messages whose `provider` is `pi-codex` hold a derived copy: the context size of the message's latest model request, with cost 0. A message that ends with a tool call holds none.

A usage reader counts each bridged turn once by this rule:

1. Read the rollouts under `<bridge home>/sessions/**/rollout-*.jsonl`. A rollout the bridge wrote carries `session_meta.payload.originator = "pi_codex_bridge"`.
2. Per rollout file, add up the increases in the `token_count` events' `info.total_token_usage`. Skip events whose `info` is null and events whose total did not change. A cold resume appends to the same rollout, and its total carries on.
3. Skip the Pi assistant messages whose `provider` is `pi-codex`.

## Memory bounds

The bridge releases everything below on `session_shutdown`.

| Collection | Bound |
|---|---|
| Thread table | 16 threads; the least recently used idle thread is dropped first |
| Queued server requests and notifications | 1024 per thread; a full queue refuses the turn |
| Tool calls waiting on Pi | 64 per turn; one more refuses the turn |

## Test

```sh
npm run test:ci
```

Live acceptance uses the existing `CODEX_HOME` login and ignores `PI_CODEX_BRIDGE_HOME`:

```sh
PI_CODEX_BRIDGE_LIVE=1 PI_CODEX_BRIDGE_MODEL=<model> npm test
```
