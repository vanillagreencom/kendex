# pi-session-bridge — development notes

Implementation details for contributors and custom client authors. End-user setup, commands, settings, and security guidance live in [`README.md`](./README.md).

## Raw protocol

Connect to the advertised Unix socket and exchange one JSON object per LF-delimited record. Requests may include `id`; responses use `type:"response"` with the same `id`.

Example requests:

```json
{"id":"1","type":"get_state"}
{"id":"2","type":"prompt","message":"Run tests","deliverAs":"auto"}
{"id":"3","type":"steer","message":"Focus on errors"}
{"id":"4","type":"follow_up","message":"Summarize when done"}
{"id":"5","type":"abort"}
```

Example response and event:

```json
{"type":"response","id":"1","command":"get_state","success":true,"data":{}}
{"type":"event","event":"input","timestamp":"...","data":{"source":"extension","streamingBehavior":"followUp","textBytes":42,"textLength":42,"textPreview":"summarize when done"},"truncated":true,"originalBytes":96,"rawEventPath":"/tmp/pi-session-bridge-1000/raw/12345.jsonl","rawEventRef":"6"}
{"type":"event","event":"message_update","timestamp":"...","data":{"role":"assistant","contentIndex":0,"deltaLength":50000,"deltaBytes":50000,"deltaPreview":"Hello..."},"truncated":true,"originalBytes":50012,"rawEventPath":"/tmp/pi-session-bridge-1000/raw/12345.jsonl","rawEventRef":"7"}
{"type":"event","event":"vstack_activity","timestamp":"...","data":{"type":"agent.task_completed","source":"pi-agents","severity":"success","importance":"normal","summary":"agent done"}}
```

Clients receive events by default. Send `{"type":"subscribe","enabled":false}` to mute them. `vstack_activity` rows are bridge events, not `sendMessage()` chat entries, so they do not render in the conversation.

## Compact event envelopes

`pi-bridge history` and the `stream` channel both default to compact event envelopes:

- `input` -> `{ source, streamingBehavior, imagesCount, textBytes, textLength, textPreview, textTruncated }`.
- `message_update` -> `{ role, type, contentIndex, deltaLength, deltaBytes, deltaPreview }`.
- `tool_execution_*` -> `{ toolName, toolUseId, status, isError, *Bytes, *Preview, artifactPath, logPath, detailPath }`.
- `agent_end` -> `{ status, stopReason, usage, messagesCount, finalTextBytes, finalTextLength, finalTextPreview }`.

When a payload is shrunk, the envelope adds `truncated: true`, `originalBytes`, `rawEventPath`, and `rawEventRef`. Raw spills live in per-session JSONL files under `<bridgeDir>/raw/<pid>.jsonl`.

The sidecar size is bounded by `maxRawSpillBytes`: each spill checks the current file size, lazily compacts to live slots when needed, and refuses the spill with `rawError` if it would still overflow. Sidecars are cleaned up on `session_shutdown` and process exit, and stale files belonging to dead pids are removed on bridge start.

## Activity broker

`pi-session-bridge` exposes an in-process broker at `globalThis[Symbol.for("vstack.pi.activity")]` for local Pi extensions:

```ts
interface PiActivityBroker {
  publish(event: PiActivityEvent): void;
  subscribe(listener: (event: PiActivityEvent) => void): () => void;
  recent(limit?: number): PiActivityEvent[];
}
```

`publish()` is best-effort and fail-open. The broker keeps a 100-event ring buffer; `recent(limit)` returns newest-first validated events for in-process replay. `pi-bridge stream` emits live broker publications as `event:"vstack_activity"` only while the bridge is connected.

## Slash command delivery

`pi-bridge send` uses a hybrid slash dispatch path:

- Plain text keeps the normal `sendUserMessage` path.
- `/skill:<name> ...` expands client-side from the loaded skill's `sourceInfo.path`.
- Repeated skill sends in the same Pi session skip the `SKILL.md` body until the skill content hash changes, the session shuts down, or the bridge restarts.
- Prompt templates expand client-side with Pi-compatible `$1`, `$@`, `$ARGUMENTS`, `${@:N[:L]}`, and `${N:-default}` substitution.
- Extension/TUI commands are pasted into Pi's own tmux pane with `send-keys -l` after resolving the pane by walking parent processes from `process.pid`.
