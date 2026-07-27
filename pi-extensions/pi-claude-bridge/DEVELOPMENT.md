# pi-claude-bridge — development notes

Implementation details for contributors. End-user setup, settings, and troubleshooting live in [`README.md`](./README.md).

## Stream and tool-result handling

- The bridge runs Claude Code through the Claude Agent SDK while Pi remains the owner of the visible TUI and tool execution.
- If the SDK stream yields a completed assistant tool-use message before `message_stop`, the bridge treats that assistant message as the tool-turn boundary. Pi executes the tool calls immediately, and the matching tool results are delivered back before the turn continues.
- Tool results whose IDs were never registered in the active assistant tool-use turn are refused instead of being queued against another pending call. Remaining handlers receive an internal-error result so the turn cannot report false success.
- If a query tears down while parallel tool results are still queued or unresolved, the bridge writes diagnostics, marks the Claude session for rebuild, and re-imports delivered results from Pi history on the next turn.

## Connector write enforcement

Write denial with `connectorWriteMode: "deny"` is two-layered:

- **Model context:** the known write tools are passed as `disallowedTools` (exact tool ids). The CLI's MCP permission matcher only supports exact tool names or a whole-server `mcp__server__*` glob — partial tool-segment globs are inert — so exact ids are what actually removes today's writes.
- **Runtime:** a `PreToolUse` hook blocks any connector tool classified as a write at call time, regardless of permission mode. Classification is fail-closed over the whole `mcp__claude_ai_<Server>__` space: a tool there is a write unless its name *begins* with a known read verb (`list`, `search`, `get`, `read`, `fetch`, …). The verb is matched as a word across naming styles — `search_threads` (Gmail), `slack_read_channel` (Slack, server-prefixed), and `getJiraIssue` (Atlassian, camelCase) are all reads; a leading word that merely repeats the server name is skipped first. A name that opens with a read verb but also names a mutation (`getOrCreateChannel`) is a write, and so is a name that does not parse as `<server>__<tool>`.

## Connector inventory build artifacts

The `./connector-inventory` entry point is a separate build output. It cannot come from `bundle/index.js`, which exports only pi's extension registration and is tree-shaken against what `index.ts` itself calls — `connectorServerNamespace` was dropped from it entirely for that reason, which is why the root bundle explicitly re-exports the connector API. `tests/unit-connector-inventory-artifact.mjs` loads the built artifacts rather than `src/` so a source change without a rebuild fails.

## Diagnostics

- Rate-limit errors are deduplicated before user notification. The bridge emits `vstack:rate-limit` so `pi-qol` can opt into reset-time auto-resume.
- Stream-idle stalls close the stalled Claude Code subprocess and return a retryable assistant error. `CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT` accepts bare seconds or `ms`, `s`, and `m` suffixes.
- Integrity diagnostics are written to `<piUserDir>/claude-bridge-diag.log` (`PI_CODING_AGENT_DIR` when set, else `~/.pi/agent`) with counts, affected tool names, and sampled tool-call IDs.
- `CLAUDE_BRIDGE_ISOLATED=1` (embedding hosts) disables all `AGENTS.md` discovery and all extension-manager/project config overlays, so bridge settings come only from `<piUserDir>/claude-bridge.json`. It also disables project `APPEND_SYSTEM.md` and the `$PATH` Claude executable search. This matters when an in-process host must share `PI_CODING_AGENT_DIR` with Pi but still needs an authoritative executable/connector policy. See `isolatedFromEnv` in `src/config.ts`.
- Startup preflight failures preserve the underlying `code`, `errno`, `syscall`, `path`, `cwd`, and detected executable file type before handing the error back to the SDK.
