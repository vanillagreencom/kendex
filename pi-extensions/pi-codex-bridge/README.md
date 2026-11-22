# Pi Codex bridge

Pi Codex bridge adds `pi-codex` models to Pi. Each model runs through the Codex CLI app server and the login that Codex already owns. Pi's tools run in Pi: the bridge offers them to Codex and returns their results.

## Features

- Lists the models `codex app-server` reports for the current account.
- Offers Pi's active tools to Codex and runs each call in Pi.
- Continues the same Codex thread across Pi turns, and starts a new thread when Pi's tools, system prompt or history no longer match it.
- Maps Pi's thinking levels to the efforts each Codex model lists.
- Keeps every configured MCP server stopped.
- Refuses Codex's native tools: shell, exec, file edits, browsers and sub-agents.

## Install

- npm: `pi install npm:@vanillagreen/pi-codex-bridge`.
- kendex:
  - Add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope.
  - Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-codex-bridge"]
source = "kendex"
```

Restart Pi after installation.

## Requirements

- Pi 0.86 or later.
- Node 22.19 or later.
- Codex CLI 0.163.0 or 0.166.0 on `PATH`.
  - The bridge refuses any other release and offers no model.
  - `package.json` lists the supported releases as its optional `@openai/codex` peer range.
- A Codex login in the bridge home, stored in `<bridge home>/auth.json`.
  - The bridge home is `PI_CODEX_BRIDGE_HOME` when set, else `CODEX_HOME`, else `~/.codex`; a blank value counts as unset.
  - `PI_CODEX_BRIDGE_HOME` gives the bridge a home apart from the one a `codex` run in Pi's tool shell reads.
  - Without `PI_CODEX_BRIDGE_HOME`, sign in with `codex login`.
  - For a home `PI_CODEX_BRIDGE_HOME` names:
    1. Create that folder.
    2. Run `codex login` with `CODEX_HOME` set to it.

A login kept in the system keyring (`cli_auth_credentials_store = "keyring"`) has no `auth.json`, so the bridge treats it as absent. Sign in with file storage to use the bridge.

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

The bridge releases its thread records, queued events and pending tool calls on `session_shutdown`. [src/bridge.ts](src/bridge.ts) declares and enforces their limits.

## Settings

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-codex-bridge"]`.

Open `/extensions:settings`; settings appear under the **Pi Codex** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: registers the `pi-codex` provider. On (`true`) by default. Takes effect after `/reload`.

## Licence

[MIT](https://github.com/vanillagreencom/kendex/blob/main/LICENSE)
