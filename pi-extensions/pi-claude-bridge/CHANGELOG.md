# Changelog

## Consumer-impacting changes

### 2.0.1

- Claude Code's in-process meta-tools (`ToolSearch`, `ListMcpResources`, `ReadMcpResource`, `ScheduleWakeup`) are now classified as child-executed (`isChildExecutedTool`), matched by exact name. They no longer appear as Pi tool calls, no longer end the Pi turn, and no longer produce a `pendingResults` entry that the reaper later drops — the "dropped 1 tool result(s) whose handler never matched (ToolSearch)" warnings, the phantom failed tool calls, and the spurious pi-turn boundaries they caused are gone (vstack#980).
- These built-ins are also excluded from the connector-call audit trail: `claude-bridge-connector-call` entries (and host audit sinks) now record claude.ai connector calls only, as the trail was always documented to. Connector calls under `mcp__claude_ai_*` audit exactly as before.
- New exports: `isConnectorTool(name)` (narrow claude.ai connector-namespace test) and `isChildInternalTool(name)` (exact-match child built-in test). `isChildExecutedTool(name)` is now the union of the two; consumers that used it as a connector test should switch to `isConnectorTool`.
