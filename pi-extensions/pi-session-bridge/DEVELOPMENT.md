# pi-session-bridge development

For maintainers and authors of custom clients. What it does for a consumer is [README.md](README.md); the agent-facing CLI contract is `instructions.md`; the request handlers and event shapes are in `extensions/session-bridge.ts`, with the module header stating discovery and framing.

## Protocol

One JSON object per LF-delimited line, both directions. A request may carry an `id`; the response is `type: "response"` with the same `id`, the `command` it answered, `success`, and `data`. Events are `type: "event"` with `event`, `timestamp` and `data`; clients receive them by default and mute them with `{"type":"subscribe","enabled":false}`. `pi-bridge request` sends any raw request. The protocol name is `PROTOCOL` in `extensions/session-bridge.ts`, and the events republished to clients are `BRIDGE_STREAM_EVENT_NAMES`; the subset in `REGISTRY_REFRESH_EVENT_NAMES` also rewrites the registry file.

`prompt` takes `deliverAs` (`auto`, `steer`, `followUp`, `now`), and `steer`, `follow_up` and `abort` are their own request types. Question requests (`questions`, `question_reply`, `question_reject`) resolve the `pi-questions` service through `Symbol.for("kendex.pi-questions.service")` and fail with a plain error when it is not loaded.

## Invariants

- Nothing leaves the process unbounded. Every event is sanitized to a compact envelope (`extensions/event-sanitizer.ts::sanitizeBridgeEvent`): `input`, `message_update`, `tool_execution_*` and `agent_end` keep counts and previews, and a shrunk envelope carries `truncated`, `originalBytes`, `rawEventPath` and `rawEventRef`. `extensions/event-history.ts::BridgeHistory` evicts by count and by total bytes, caps each `history` response and reports `responseTruncated`, and spills raw payloads to `<bridgeDir>/raw/<pid>.jsonl` under `maxRawSpillBytes`, compacting live slots first and refusing with `rawError` rather than overflowing. Sidecars are removed at `session_shutdown` and process exit, and `cleanupStaleSpills` removes those of dead pids at start.
- The activity broker is fail-open and in-process. `extensions/activity-broker.ts` installs it at `globalThis[Symbol.for("kendex.pi.activity")]`; `publishPiActivity` swallows every error so a producer never fails because activity did, `recent` replays a bounded ring newest-first, and the bridge forwards live publications as `kendex_activity` events only while connected. Broker rows are never `sendMessage` chat entries.
- Slash dispatch matches Pi's editor. `pi-bridge send` expands `/skill:<name>` from the loaded skill's `sourceInfo.path` and prompt templates with Pi's substitution rules, and an extension or TUI command is pasted into the session's own tmux pane, resolved by walking parent processes from `process.pid` rather than the active tmux client. A repeated skill send in one session sends a short reminder until the `SKILL.md` hash changes; the cache is evicted per session at shutdown and bounded to `MAX_SKILL_EXPANSION_CACHE_SESSIONS`. A failed command delivery falls back to a plain message.
- Project settings are read only after Pi reports the workspace trusted (`recordProjectTrust`), the same rule every kendex Pi extension follows.
- A child session spawned with `PI_BRIDGE_PARENT_SESSION_ID` advertises a synthesized `<parent>:c<pid>` id (`extensions/child-session-id.ts::resolveSessionId`) so parents can tell their children apart in `pi-bridge list`.

## Tests

```bash
bun test tests/*.test.ts extensions/__tests__/*.test.ts
npm run check
```

`check` also parses `bin/pi-bridge.js`. History budgets, sanitizer shapes, the slash-dispatch matrix against Pi's editor outcomes, tmux pane resolution, the CLI's history flags, child session ids and the broker each have a suite. A new bound ships with the control that overruns it; a new dispatch shape ships with its row in the matrix.
