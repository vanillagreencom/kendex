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

The same never-mirror rule covers a second, smaller class: Claude Code's own in-process meta-tools (`ToolSearch` and `ScheduleWakeup` — `isChildInternalTool`, matched by **exact name**, never by prefix). The two MCP-resource built-ins (`ListMcpResources`/`ReadMcpResource`, which the SDK renames to `ListMcpResourcesTool`/`ReadMcpResourceTool` on the stream side) are deliberately NOT in this class: a resource read is a real account-surface access and both consumer hosts audit it through the Pi mirror, so it stays mirrored (vstack#1007). They surface when connectors are enabled, because connector tools are deferred behind `ToolSearch`. Mirroring one made Pi dispatch a tool it does not have and deliver an error result for an id no MCP handler ever claimed; the result queued in `pendingResults` until the reaper dropped it — a "dropped 1 tool result(s) whose handler never matched (ToolSearch)" warning and a phantom failed tool call per discovery, plus a spurious pi-turn boundary (vstack#980). Unlike connectors, these calls are tool plumbing rather than account-data access, so they are also excluded from the connector-call audit below; connector-only concerns key on the narrow `isConnectorTool`.

Mirroring one used to make Pi's agent loop look the name up in `context.tools`, miss, and write a synthetic `Tool <name> not found` error result into the transcript — for a call that had **succeeded**, next to an answer built from its real payload. That reads as a fabricating model, and a rebuild (`syncSharedSession`) projected the false result back into the child's session, turning a wrong mirror into a wrong conversation of record. Found in two host apps at once (drovr#311, memsira#320).

Two places used to hand the model a SECOND name for a connector tool, and a second name is a name that can be wrong:

- `mapPiToolNameToSdk` PascalCased anything it could not map, so a connector call projected back into the child's session became `McpClaudeAiSlackSlackSearchChannels`. The model imitated that alias on the next turn and got a real `Tool ... not found` from the MCP dispatcher before retrying the canonical name — one wasted round-trip per affected call. Connector names now pass through unchanged; the fix above stops them reaching this path at all, but LEGACY Pi history recorded before it still carries them.
- `resolveMcpTools` re-offered every `context.tools` entry under the bridge's own MCP prefix, including one sitting on the connector namespace. Such a tool is uncallable anyway (a `tool_use` there is treated as child-executed and never handed to Pi), so it is now filtered out and the two halves agree end to end.

The classifier is namespace-based (connectors) plus an exact-name set (child built-ins) on purpose. "Any name Pi cannot resolve" would also swallow a genuine Pi↔child tool-name mismatch, which should stay a loud dispatcher error.

Two consequences worth knowing:

- The child's real result is **observed, never re-delivered** (`noteChildExecutedToolResults`, fed from the SDK's `user` message). It already reached the model inside the child. The debug line records the tool name, error flag, and payload byte size — never the payload, which is live account data and the bridge's debug log sits outside a host app's redaction boundary.
- A connector call still produces **no tool card**. Pi's assistant content is `text | thinking | toolCall`, and any `toolCall` block is dispatched by its agent loop, so there is no way to say "a call happened, someone else ran it" as content — the honest options were "absent" or "present and wrong". Rendering one needs a Pi-side representation for delegated calls, which is an upstream ask.

### The audit trail

What the transcript *can* carry is a record that is not content. Each child-executed **connector** call (never a child-internal built-in) appends a session `CustomEntry` of type `claude-bridge-connector-call` (`src/connector-audit.ts`), which pi documents as *"Does NOT participate in LLM context (ignored by `buildSessionContext`)"*: it is never a content block, so the agent loop cannot dispatch it, and `convertPiMessages` reads messages rather than entries, so it is never projected back into the child's session. **Never use `CustomMessageEntry`** for this — the sibling type DOES enter context, which is the whole bug again.

Each record is `{ name, toolUseId, outcome, byteSize?, childSessionId?, reason? }` — enough to pair it to the child's own transcript by `tool_use_id`, and no payload.

Two things the shape is deliberate about:

- `outcome` is `ok | error | **unobserved**`. A call whose result never came back (abort, stream-idle timeout, a query that just ended) is recorded at teardown naming the cause, beside the Pi-side `drainPendingToolCalls`. Silence there would leave an answer in the transcript as the only evidence a call was ever made — the same "can I trust this?" question the mirrored `Tool ... not found` answered wrongly.
- Recording is keyed on the `tool_use` id, not on the call site. The SDK can re-yield a `user` message, and either path (result or teardown) can reach a call first; one call is one record, whichever gets there.

The audit map is query-scoped and is NOT cleared by `resetToolTracking` — that runs at every child message boundary, and clearing it there would make a call abandoned in an earlier child message unrecordable at teardown, which is the one case the trail exists for.

Note that pi/core's `createBranchedSession` copies every non-label entry root→leaf, so a fork inherits the parent's connector-call records. Harmless for an audit trail, unlike the `claude-bridge-session` marker it sits beside, which needed a `piSessionId` guard for exactly that reason.

## Optional account-router contract

The bridge remains usable by itself. A companion may publish `vstack.pi.claude-account-router.v1` on `globalThis` to supply a subscription profile for each fresh request. The bridge passes only an opaque profile id, display label, and optional `CLAUDE_CONFIG_DIR`; credentials remain owned by the official Claude CLI.

Account selection affects every account-scoped surface together:

- the Agent SDK child environment (with inherited API/provider-override env scrubbed);
- `cc-session-io` create/open/delete paths, resolved through the SAME rule as the child env (profile `configDir`, else the real `~/.claude` default — never the parent's `CLAUDE_CONFIG_DIR`);
- Claude session resume IDs;
- connector inventory/cache scope;
- structured `accountInfo()` and experimental `/usage` feedback.

A failed pre-output attempt is buffered (`RetryEventBuffer`) so protocol setup frames do not leak into Pi, then retried with the failed profile excluded (16-attempt cap per request). Text/thinking deltas, Pi tool calls, and child-executed connector dispatches commit the request permanently; failures after that point are surfaced and never replayed, but are still recorded for the next request's routing decision. `rate_limit_event` reset timestamps are sent back to the router before reranking. The commit flag is stamped on the query context CAPTURED at buffer creation — never the live `ctx()`, which can be a pushed reentrant subagent context at commit time — and rotation additionally checks the buffer's own committed flag.

Pi session persistence stores only the opaque `accountProfileId`; the config dir is re-derived through the router's `resolveProfile` on restore (router absent → default rule), so account-identifying paths never travel with shared session archives.

The reciprocal `vstack.pi.claude-bridge.account-host.v1` service exposes a local `/usage` probe for account-management commands. Both symbols carry `version: 1`; incompatible future shapes must use a new symbol/version instead of mutating this contract in place.

## Provider registration — native pi ≥0.81 provider API (adopted in 2.0)

Since 2.0 the bridge registers a native `Provider` object (`native-provider.ts`) via
`pi.registerProvider(provider)`: registration is UNCONDITIONAL (once primary), and the provider's
own `auth.apiKey.check()/resolve()` report configured-ness from the same existence-only credential
probes as before (`auth-presence.ts`), so pi itself hides pi-claude models while no Claude
account is connected and shows them when one appears. The 1.x credential-gated
register/unregister state machine (`decideRegistration`) is gone. **Hosts must embed pi ≥0.81**
(peer range `>=0.81.0`); on an older host the extension declines loudly once
(`NATIVE_PROVIDER_UNSUPPORTED_MESSAGE`) instead of registering wrongly through the legacy overload.

This was first evaluated on 2026-07-28 and NOT adopted, then adopted the same day after the owner
lifted the pre-0.81 host-compat constraint (memsira/drovr upgrade their embedded pi in lockstep —
they are the only consumers). What the original evaluation flagged, and how each point resolved:

- **The symbol guards stay — by design, not oversight.** pi's `registerNativeProvider` is
  upsert-by-id that *replaces* the stored provider object; an unguarded subagent module reload
  re-registering the same id would swap in ITS `streamSimple` closure and split-brain the shared
  session. `PRIMARY_INSTANCE_KEY`/`ACTIVE_STREAM_SIMPLE_KEY` therefore survive into 2.x. If pi
  ever grows owner-aware provider dedupe, the guards can go.
- **The two-parallel-paths objection dissolved** with the host floor at 0.81: there is exactly one
  registration path in 2.x.
- **Mid-session credential timing is kept deterministic** rather than left to pi's refresh
  cadence: session_start and pre-spawn re-UPSERT the same provider object, which triggers pi's
  model-snapshot/availability recompute at exactly the boundaries 1.x re-checked — and the
  pre-spawn `hasClaudeCredentials()` fail-fast in `streamSimple` remains, so a logout is a clear
  actionable error at first use even if a picker snapshot is stale.
- The subscription-billing constraint is untouched: BOTH native stream entry points
  (`stream`/`streamSimple`) are the same Claude Code subprocess router — there is no raw-API path.

## Config channels

`loadConfig` layers three sources, lowest precedence first: `<piUserDir>/claude-bridge.json`, a trusted project's `.pi/claude-bridge.json`, then extension-manager config in `settings.json`. Isolated mode (`CLAUDE_BRIDGE_ISOLATED=1`) keeps only the first.

Two provider keys are exempt from project layering: `enableConnectors` and `connectorWriteMode` resolve from **user scope and the env vars only** (`USER_SCOPE_ONLY_PROVIDER_KEYS` in `src/config.ts`). Project trust covers ordinary options; a checked-in `.pi/settings.json` or `.pi/claude-bridge.json` must not be able to expose the account's live connectors or un-gate their writes by being the cwd — the same posture as the setting-source lockdown below.

Each `claude-bridge.json` is read by `legacyFileConfig`, which accepts both the nested legacy shape (`provider.*`, `promptContext.*`) and the manager's flat manifest keys; nested wins when a file carries both for one key. Provider values are normalized once over the merged result, so an invalid `forceEffort` in a higher layer still clears a valid one below it.

`resolveExternalConfigValue(key, cwd)` reports what those files — and only those files — resolve for one manifest key, plus the concrete file that supplied it. It shares `legacyLayers`/`mergeLayers` with `loadConfig` and applies the same normalization, so the two cannot drift. `registerExternalConfigResolver` publishes it under `Symbol.for("vstack.pi.extension-config-resolver")` keyed by `PACKAGE_ID`; the vstack extension manager calls it when neither of its own scopes holds a key, and renders the value with its source file. Registration happens before the `config.enabled === false` early return, because a bridge disabled by `claude-bridge.json` is precisely the case the settings editor has to explain. The contract itself is documented in [`pi-extension-manager/DEVELOPMENT.md`](../pi-extension-manager/DEVELOPMENT.md).

## Connector write enforcement

Write denial with `connectorWriteMode: "deny"` is two-layered:

- **Model context:** the known write tools are passed as `disallowedTools` (exact tool ids). The CLI's MCP permission matcher only supports exact tool names or a whole-server `mcp__server__*` glob — partial tool-segment globs are inert — so exact ids are what actually removes today's writes.
- **Runtime:** a `PreToolUse` hook blocks any connector tool classified as a write at call time, regardless of permission mode. Classification is fail-closed over the whole `mcp__claude_ai_<Server>__` space: a tool there is a write unless its name *begins* with a known read verb (`list`, `search`, `get`, `read`, `fetch`, …). The verb is matched as a word across naming styles — `search_threads` (Gmail), `slack_read_channel` (Slack, server-prefixed), and `getJiraIssue` (Atlassian, camelCase) are all reads; a leading word that merely repeats the server name is skipped first. A name that opens with a read verb but also names a mutation (`getOrCreateChannel`) is a write, and so is a name that does not parse as `<server>__<tool>`.

Independent of write mode, every connectors-mode child also carries a fail-closed **builtin allowlist** `PreToolUse` hook (`connectorBuiltinAllowlistHook` in `src/connectors.ts`): only `mcp__custom-tools__*`, `mcp__claude_ai_*`, and the discovery built-ins (`CONNECTOR_DISCOVERY_TOOLS`) may execute; everything else — including CLI built-ins that postdate `DISALLOWED_BUILTIN_TOOLS` — is denied, and a hook exception converts to a deny (the CLI treats a thrown hook as empty output, i.e. fail-open, so every catch path must deny). The account probe child gets the harsher `denyAllToolsHook` — a `/usage` probe executes nothing.

## Connector setting-source lockdown

The SDK treats `settingSources: undefined` as isolation (no filesystem settings), and isolation drops claude.ai cloud connectors even with `ENABLE_CLAUDEAI_MCP_SERVERS=1` — so connectors mode must pass some source list. That list is `["user"]` and nothing more (`settingSourcesForQuery` in `src/connectors.ts`; vstack#990). Connector state is user-scope (the account's config dir, `CLAUDE_CONFIG_DIR` for managed router profiles), so user scope is sufficient; `"project"`/`"local"` would let a checkout's `.claude/settings.json` use the settings-file `env`/`apiKeyHelper` channels to reintroduce exactly the provider-override env `subscriberProfileEnv` scrubs from managed children (`ANTHROPIC_BASE_URL` → traffic redirection) on any query whose cwd is a hostile repo. An explicit `provider.settingSources` in bridge config wins verbatim (that channel is user-scope/trust-gated via `loadConfig`); the README warns that adding project/local there reopens the surface.

## Connector inventory build artifacts

The `./connector-inventory` entry point is a separate build output. It cannot come from `bundle/index.js`, which exports only pi's extension registration and is tree-shaken against what `index.ts` itself calls — `connectorServerNamespace` was dropped from it entirely for that reason, which is why the root bundle explicitly re-exports the connector API. `tests/unit-connector-inventory-artifact.mjs` loads the built artifacts rather than `src/` so a source change without a rebuild fails.

## Diagnostics

- Rate-limit errors are deduplicated before user notification. The bridge emits `vstack:rate-limit` so `pi-qol` can opt into reset-time auto-resume.
- Stream-idle stalls close the stalled Claude Code subprocess and return a retryable assistant error. `CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT` accepts bare seconds or `ms`, `s`, and `m` suffixes.
- The watchdog deliberately monitors only PRE-first-output silence (`shouldMonitor` requires `!turnStarted && !turnSawStreamEvent`). Every observed stall class — spawn hang, rate-limit stall, steer-drain — happens before the first stream event, and those are covered. Once output has started, 90s SDK-message gaps have legitimate causes that must not be killed: a child-executed connector call blocks the SDK message flow while the Pi turn stays open (`currentPiStream` non-null, unlike Pi-executed tool waits), and a long extended-thinking stretch can be delta-sparse. A child that dies mid-message is not silent either — the SDK generator throws and the query `.catch` surfaces it — so mid-turn coverage would mostly convert slow-but-alive turns into spurious aborts. Revisit only with evidence of a mid-turn stall the generator did not turn into an error.
- Integrity diagnostics are written to `<piUserDir>/claude-bridge-diag.log` (`PI_CODING_AGENT_DIR` when set, else `~/.pi/agent`) with counts, affected tool names, and sampled tool-call IDs.
- `CLAUDE_BRIDGE_ISOLATED=1` (embedding hosts) disables all `AGENTS.md` discovery and all extension-manager/project config overlays, so bridge settings come only from `<piUserDir>/claude-bridge.json`. It also disables project `APPEND_SYSTEM.md` and the `$PATH` Claude executable search. This matters when an in-process host must share `PI_CODING_AGENT_DIR` with Pi but still needs an authoritative executable/connector policy. See `isolatedFromEnv` in `src/config.ts`.
- Startup preflight failures preserve the underlying `code`, `errno`, `syscall`, `path`, `cwd`, and detected executable file type before handing the error back to the SDK.
