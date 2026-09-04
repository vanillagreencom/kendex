# @vanillagreen/pi-session-bridge

Controls a running interactive Pi session from outside its terminal. The Pi TUI stays visible while the `pi-bridge` CLI, or any local client on the socket, sends prompts, steering, follow-ups and question answers and watches the session's events. For anyone running several Pi sessions, or an agent that addresses peer sessions it did not spawn.

![Session bridge CLI flow](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-session-bridge/assets/session-bridge-cli.png)

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-session-bridge"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-session-bridge):

```bash
pi install npm:@vanillagreen/pi-session-bridge
```

Restart Pi after installation. kendex links the CLI into the scope's `bin/` directory (`.pi/bin/pi-bridge` for a project, `~/.pi/agent/bin/pi-bridge` globally); add that directory to `PATH` or run it by path.

## What it does

- Discovers running sessions through registry files and targets one by pid, socket, session, name or cwd; a lone session needs no target flag.
- Sends a prompt, steers the current turn, queues a follow-up, or aborts.
- Streams the session's events live, or returns recent history, as compact envelopes with the full payload available on request.
- Lists, answers and rejects pending `pi-questions` popups when that package is loaded.
- Expands `/skill:<name>` and prompt templates the way Pi's editor does, and delivers extension commands such as `/bridge:ping` to the session's own editor.
- Carries activity events other kendex extensions publish (agent progress, background tasks, questions) as a side channel that never enters the conversation.
- `/bridge:status` shows the socket and registry paths; `/bridge:ping [text]` emits a `bridge_pong` event without calling a model.

`pi-bridge --help` lists every command and target flag. The agent-facing rules ship in `instructions.md`, appended to the system prompt at install.

## How it works

Each session listens on a Unix socket under `PI_BRIDGE_DIR` (default `/tmp/pi-session-bridge-$UID`) and advertises itself in a registry file there, refreshed on a heartbeat. Clients exchange one JSON object per line: requests get a response with the same id, and subscribed clients receive the session's events as they happen. Oversized event payloads are reduced to previews in the stream and in history, and spilled to a per-session sidecar so `history --raw` can rehydrate them.

## Customise

Open `/extensions:settings`; settings appear under the **Session Bridge** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: master toggle for the socket, the registry entry and the status badge.
- `bridgeDir`: where sockets and registry files live; the `PI_BRIDGE_DIR` environment variable overrides it.
- History and payload bounds: `historyLimit`, `maxEventBytes`, `maxHistoryBytes`, `maxHistoryResponseBytes`, `eventPreviewBytes`, `spillRawEvents`, `maxRawSpillBytes`, `maxLineBytes`.
- `heartbeatMs`, `notifyOnStart`, `showStatus`.

The socket triggers real agent work in the owning Pi process. Keep `PI_BRIDGE_DIR` private to your user, and never expose it to other users or untrusted containers.

Protocol and broker details for client authors and maintainers are in [DEVELOPMENT.md](DEVELOPMENT.md).
