# pi-claude-bridge — development notes

Implementation details for contributors. End-user setup, settings, and troubleshooting live in [`README.md`](./README.md).

## Stream and tool-result handling

- The bridge runs Claude Code through the Claude Agent SDK while Pi remains the owner of the visible TUI and tool execution.
- If the SDK stream yields a completed assistant tool-use message before `message_stop`, the bridge treats that assistant message as the tool-turn boundary. Pi executes the tool calls immediately, and the matching tool results are delivered back before the turn continues.
- Tool results whose IDs were never registered in the active assistant tool-use turn are refused instead of being queued against another pending call. Remaining handlers receive an internal-error result so the turn cannot report false success.
- If a query tears down while parallel tool results are still queued or unresolved, the bridge writes diagnostics, marks the Claude session for rebuild, and re-imports delivered results from Pi history on the next turn.

## Diagnostics

- Rate-limit errors are deduplicated before user notification. The bridge emits `vstack:rate-limit` so `pi-qol` can opt into reset-time auto-resume.
- Stream-idle stalls close the stalled Claude Code subprocess and return a retryable assistant error. `CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT` accepts bare seconds or `ms`, `s`, and `m` suffixes.
- Integrity diagnostics are written to `~/.pi/agent/claude-bridge-diag.log` with counts, affected tool names, and sampled tool-call IDs.
- Startup preflight failures preserve the underlying `code`, `errno`, `syscall`, `path`, `cwd`, and detected executable file type before handing the error back to the SDK.
