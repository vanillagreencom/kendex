# pi-claude-bridge — development notes

Implementation details for contributors. End-user setup, settings, and troubleshooting live in [`README.md`](./README.md).

## Stream and tool-result handling

- The bridge runs Claude Code through the Claude Agent SDK while Pi remains the owner of the visible TUI and tool execution.
- A tool-use turn ends at the stream's `message_stop`, not at the first early signal. The SDK yields the completed assistant message AND invokes the MCP tool handlers before `message_delta` arrives — and `message_delta` is what carries the message's real output-token count, so ending the pi stream at either early signal froze pi's per-turn output figures at the `message_start` placeholders (1–7 tokens; 2026-07-28 token test). The early signals now only arm a ~1.5s grace timer (`scheduleToolUseTurnEnd`) that force-finalizes the turn if the terminal events never arrive (the pi 0.80 steer-draining case), so the MCP handlers can never deadlock waiting on a stream pi will not end.
- An MCP handler claims its tool-call id by tool name + arguments; when no exact match exists but exactly ONE unclaimed call of that tool type does, it is claimed anyway (`argsMismatch` diag) — the handler receives the schema-VALIDATED input while the record holds the raw streamed input, and a stripped key must not strand the call. Nested schema objects also validate permissively (`.passthrough()`) unless the schema says `additionalProperties: false`, matching JSON Schema's default.
- Tool results whose IDs were never registered in the active assistant tool-use turn are refused instead of being queued against another pending call. Remaining handlers receive an internal-error result so the turn cannot report false success.
- Queued results that can no longer be consumed (their handler already gave up) are reaped at the next child message boundary with a `stale_queued_tool_results_dropped` diagnostic, instead of poisoning every later mismatch report for the query.
- If a query tears down while parallel tool results are still queued or unresolved, the bridge writes diagnostics, marks the Claude session for rebuild, and re-imports delivered results from Pi history on the next turn.
- Integrity events (mismatch, synthetic-result repair, stale-result reap, unmatched handler) are also appended to the pi session as `claude-bridge-integrity` custom entries — compact metadata only — so a post-mortem works from the session file alone.
- Unpaired tool_uses in a session rebuild are paired with an explicit `is_error` result telling the model the output was lost and to re-run the tool if needed, instead of cc-session-io's bare `[no tool result recorded]` placeholder that models read as real output.

## Child-executed tools (claude.ai connectors)

Tool calls in a bridge turn normally run in one direction: Pi hands its tool set to the bridge, the bridge re-offers it to the `claude` child over the in-process MCP server, and a `tool_use` coming back is the child asking **Pi** to execute something. claude.ai connectors run the other way — they are the child's own MCP servers, attached to the authenticated account and reachable only from inside that process.

So a `tool_use` under `mcp__claude_ai_` is **never mirrored into the Pi stream**: no `toolCall` block, no `toolUse` turn boundary, no entry in the turn's expected-result tracking (`isChildExecutedTool` in `src/connectors.ts`; the three emission sites in `src/assistant-stream.ts`). The child executes the call itself and keeps streaming, so the whole exchange lands in one Pi assistant message.

Mirroring one used to make Pi's agent loop look the name up in `context.tools`, miss, and write a synthetic `Tool <name> not found` error result into the transcript — for a call that had **succeeded**, next to an answer built from its real payload. That reads as a fabricating model, and a rebuild (`syncSharedSession`) projected the false result back into the child's session, turning a wrong mirror into a wrong conversation of record. Found in two host apps at once (drovr#311, memsira#320).

Two places used to hand the model a SECOND name for a connector tool, and a second name is a name that can be wrong:

- `mapPiToolNameToSdk` PascalCased anything it could not map, so a connector call projected back into the child's session became `McpClaudeAiSlackSlackSearchChannels`. The model imitated that alias on the next turn and got a real `Tool ... not found` from the MCP dispatcher before retrying the canonical name — one wasted round-trip per affected call. Connector names now pass through unchanged; the fix above stops them reaching this path at all, but LEGACY Pi history recorded before it still carries them.
- `resolveMcpTools` re-offered every `context.tools` entry under the bridge's own MCP prefix, including one sitting on the connector namespace. Such a tool is uncallable anyway (a `tool_use` there is treated as child-executed and never handed to Pi), so it is now filtered out and the two halves agree end to end.

The classifier is namespace-based on purpose. "Any name Pi cannot resolve" would also swallow a genuine Pi↔child tool-name mismatch, which should stay a loud dispatcher error.

Two consequences worth knowing:

- The child's real result is **observed, never re-delivered** (`noteChildExecutedToolResults`, fed from the SDK's `user` message). It already reached the model inside the child. The debug line records the tool name, error flag, and payload byte size — never the payload, which is live account data and the bridge's debug log sits outside a host app's redaction boundary.
- A connector call still produces **no tool card**. Pi's assistant content is `text | thinking | toolCall`, and any `toolCall` block is dispatched by its agent loop, so there is no way to say "a call happened, someone else ran it" as content — the honest options were "absent" or "present and wrong". Rendering one needs a Pi-side representation for delegated calls, which is an upstream ask.

### The audit trail

What the transcript *can* carry is a record that is not content. Each child-executed call appends a session `CustomEntry` of type `claude-bridge-connector-call` (`src/connector-audit.ts`), which pi documents as *"Does NOT participate in LLM context (ignored by `buildSessionContext`)"*: it is never a content block, so the agent loop cannot dispatch it, and `convertPiMessages` reads messages rather than entries, so it is never projected back into the child's session. **Never use `CustomMessageEntry`** for this — the sibling type DOES enter context, which is the whole bug again.

Each record is `{ name, toolUseId, outcome, byteSize?, childSessionId?, reason? }` — enough to pair it to the child's own transcript by `tool_use_id`, and no payload.

Two things the shape is deliberate about:

- `outcome` is `ok | error | **unobserved**`. A call whose result never came back (abort, stream-idle timeout, a query that just ended) is recorded at teardown naming the cause, beside the Pi-side `drainPendingToolCalls`. Silence there would leave an answer in the transcript as the only evidence a call was ever made — the same "can I trust this?" question the mirrored `Tool ... not found` answered wrongly.
- Recording is keyed on the `tool_use` id, not on the call site. The SDK can re-yield a `user` message, and either path (result or teardown) can reach a call first; one call is one record, whichever gets there.

The audit map is query-scoped and is NOT cleared by `resetToolTracking` — that runs at every child message boundary, and clearing it there would make a call abandoned in an earlier child message unrecordable at teardown, which is the one case the trail exists for.

Note that pi/core's `createBranchedSession` copies every non-label entry root→leaf, so a fork inherits the parent's connector-call records. Harmless for an audit trail, unlike the `claude-bridge-session` marker it sits beside, which needed a `piSessionId` guard for exactly that reason.

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
