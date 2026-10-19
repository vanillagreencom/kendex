# Pi Codex bridge

Pi Codex bridge adds `pi-codex` models to Pi. It runs each model through the Codex CLI app server and the login that Codex already owns.

The bridge does not copy a credential into Pi. It checks only whether `CODEX_HOME/auth.json` exists.

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
- Codex CLI 0.154.0.
- An existing Codex login under the active `CODEX_HOME`.

## Features

- Lists the models that `codex app-server` reports for the current account.
- Keeps the Codex thread ID across Pi turns.
- Runs Codex dynamic tool calls through Pi tools.
- Removes ambient API keys and tokens from the Codex child process.
- Refuses a request when the selected Codex login is absent.

## How it works

The extension starts `codex app-server` over standard input and output. It declares Pi's active tools as Codex dynamic tools. A Codex tool request becomes a Pi tool call. The next Pi provider call returns that result to the same Codex request ID.

Codex remains responsible for its login and token refresh. Pi settings do not receive Codex credentials.

## Test

```sh
npm run test:ci
```

Live acceptance uses the existing `CODEX_HOME` login:

```sh
PI_CODEX_BRIDGE_LIVE=1 npm test
```
