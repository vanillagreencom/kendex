# Development

## Protocol

The bridge uses `codex app-server` over standard input and output. App server supports dynamic client tools, streamed events, durable thread IDs, multi-turn resume, interruption, and account-specific model listing.

The bridge does not use `codex exec --json`. That command emits JSON Lines and can resume a session, but it has no bidirectional dynamic-tool result channel. Pi could not execute Codex tool calls through that surface.

The package supports Codex CLI 0.154.0. The protocol is experimental. The runtime refuses another version before it starts an app-server request.

## Message flow

The client sends `initialize` with `experimentalApi: true` and `requestAttestation: false`. It then sends `initialized`.

The provider calls `model/list` for the model menu. It creates a durable thread with Pi tools in `dynamicTools`. It saves `thread.id` in the Pi assistant message `responseId`.

An `item/tool/call` request stays open while Pi executes the matching tool. The bridge answers the request's JSON-RPC ID after Pi returns the matching call ID. Missing, duplicate, unknown, and name-mismatched results fail before the bridge answers any call in the batch.

## Credential boundary

`auth-presence.ts::hasCodexLogin` checks only whether `CODEX_HOME/auth.json` exists. It never opens the file.

`codex-environment.ts::codexChildEnvironment` passes the exact resolved `CODEX_HOME`. It removes ambient environment variables whose names identify credentials, tokens, secrets, passwords, or authentication sockets.

The bridge does not call a Codex login method. It rejects app-server requests that ask the client to refresh authentication tokens.

## Tool boundary

The bridge disables the app-server feature-backed execution tools that Codex CLI 0.154.0 exposes. It also disables web search and uses the read-only sandbox with approvals disabled.

App server has no global MCP disable in this version. An empty `mcp_servers` table does not clear inherited servers. Do not replace the per-server security decision with that ineffective override.

## Tests

`npm run test:ci` builds the published bundle, checks TypeScript, and runs the unit suite. The provider test proves the two-call Pi tool cycle and the exact app-server request ID response.

`tests/int-smoke.sh` runs Pi 0.86 against the real Codex login. It is active only when `PI_CODEX_BRIDGE_LIVE=1`.
