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
- Codex CLI 0.163.0 on `PATH`. The bridge refuses any other version.
- A Codex login under the active `CODEX_HOME` (default `~/.codex`), stored in `CODEX_HOME/auth.json`.

A login kept in the system keyring (`cli_auth_credentials_store = "keyring"`) has no `auth.json`, so the bridge treats it as absent. Sign in with file storage to use the bridge.

## Features

- Lists the models `codex app-server` reports for the current account.
- Offers Pi's active tools to Codex and runs each call in Pi.
- Continues the same Codex thread across Pi turns, and starts a new thread when Pi's tools or history no longer match it.
- Maps Pi's thinking levels to the efforts each Codex model lists.
- Keeps every configured MCP server stopped.
- Refuses Codex's native tools: shell, exec, file edits, browsers and sub-agents.

## Settings

| Setting | Default | Effect |
|---|---|---|
| `enabled` | `true` | Register the `pi-codex` provider. Takes effect after `/reload`. |

## How it works

The extension starts one `codex app-server` child for the Pi session. Codex owns its login, token refresh, thread state and rollouts in `CODEX_HOME`. The bridge does not read, copy or write a credential file. It writes nothing to Pi settings or Pi `auth.json`.

DEVELOPMENT.md describes the protocol and each guard.

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

Live acceptance uses the existing `CODEX_HOME` login:

```sh
PI_CODEX_BRIDGE_LIVE=1 PI_CODEX_BRIDGE_MODEL=<model> npm test
```
