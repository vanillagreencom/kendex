# Changelog

## Consumer-impacting changes

### 2.1.0

- Delivering multiple queued Pi follow-ups in one call (steer-queue drain, `followUpMode="all"`) no longer forces a Claude session rebuild: the REUSE path now recognizes an unbounded trailing run of user messages, combines them into one prompt, and resumes the existing session — no session-file rewrite and no prompt-cache flush (vstack#963).
- Mid-query queued follow-ups are no longer silently dropped: when Pi injects several user messages during an active query, the entire trailing run is captured for replay after the query instead of only the last message, and the session cursor only advances over messages actually captured. Anything skipped now emits a `deferred_user_replay_skipped` diagnostic instead of vanishing (vstack#967).
- New exports: `planIncrementalPromptBatch(messages, cursor)` (REUSE-path prompt-batch planner) and `planDeferredUserReplay(messages)` (mid-query trailing-user-run capture plan).
- `cc-session-io` dependency floor raised to 0.3.2 (content-block `addUserMessage` with empty-content guard; `importMessages` keeps non-tool_result blocks alongside tool results).

### 2.0.1

- Claude Code's in-process meta-tools (`ToolSearch`, `ListMcpResources`, `ReadMcpResource`, `ScheduleWakeup`) are now classified as child-executed (`isChildExecutedTool`), matched by exact name. They no longer appear as Pi tool calls, no longer end the Pi turn, and no longer produce a `pendingResults` entry that the reaper later drops — the "dropped 1 tool result(s) whose handler never matched (ToolSearch)" warnings, the phantom failed tool calls, and the spurious pi-turn boundaries they caused are gone (vstack#980).
- These built-ins are also excluded from the connector-call audit trail: `claude-bridge-connector-call` entries (and host audit sinks) now record claude.ai connector calls only, as the trail was always documented to. Connector calls under `mcp__claude_ai_*` audit exactly as before.
- New exports: `isConnectorTool(name)` (narrow claude.ai connector-namespace test) and `isChildInternalTool(name)` (exact-match child built-in test). `isChildExecutedTool(name)` is now the union of the two; consumers that used it as a connector test should switch to `isConnectorTool`.
