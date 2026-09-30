# Changelog

## Consumer-impacting changes

### 3.0.0

- **Breaking**: raw history is saved only for events that fire while an event subscriber is attached and raw spill is enabled. Keep `pi-bridge stream` connected to retain future terminal payloads. A later `history --raw` request cannot recover events that had no subscriber.

### 2.3.0

- Raw append and disk compaction use an asynchronous queue capped at 64 events and 16 MiB, including in-flight work. `rawError` explains queue or retention refusals. Compact events can show `spill_pending=true`; `history --raw` waits for queued writes. Shutdown cancels pending work and waits for in-flight I/O before it removes the file.
- The bridge reuses each payload's JSON string for measurement and raw storage. It also reuses compact JSON for event delivery and history.

### 2.2.0

- A client that still leaves more than 8 MiB of bridge output unread when the next line is due is disconnected instead of growing the Pi process until it is killed. One response larger than 8 MiB still reaches a client that reads it. The session's user sees a `bridge-client-stalled=<bytes>` warning when the session has a UI.
- `pi-bridge stream` stops reading from the bridge while its own output is not yet written. When the bridge closes the stream (the session ended, or the reader was disconnected), it prints `bridge-stream-closed` and exits 1 instead of 0.
- The activity list keeps at most 100 events, 1,048,576 characters of serialized events (one larger event is still kept alone), and nothing older than one hour.

### 2.1.1

- Settings reads come from memory. A read is answered for one second without touching disk, then the settings files are read again. A change made in the extension manager, or a new session, applies at once; a hand edit to `settings.json` applies within one second. Before, every read went to disk.

### 2.1.0

- Streaming events no longer freeze the Pi TUI. Pi fires `message_update` once per token and `tool_execution_update` once per partial tool result, and each payload carries the whole value so far, so the bridge was writing the entire assistant message to the raw sidecar on every token and rewriting the 16 MB sidecar once the cap was reached. These two events now publish delta-only envelopes and spill nothing. A `message_update` envelope keeps the delta plus the identity fields and reports the delta's size as `originalBytes`. A `tool_execution_update` envelope keeps the tool name and call id alone, with `originalBytes` 0: it no longer carries `*Bytes` counts or previews of the partial result, and Pi's update payload has no delta to report. Whole payloads still reach the sidecar on `message_end` and `tool_execution_end`, so `pi-bridge history --raw` still rehydrates a finished message. A `pi-bridge history --raw` response now says in `rawError` why an envelope stayed compact, so a delta-only envelope no longer reads as a failed spill. That note counts against `--max-bytes` like a rehydrated payload, so a tight budget drops it and reports the response as truncated.
- A raw spill that does not fit the budget is refused without reading or rewriting the sidecar. The rewrite now happens only when it can reclaim the bytes of evicted envelopes.
- Messages sent through tmux now reach Pi while the pane is in copy mode.

### 2.0.1

- The extension uses `PI_CODING_AGENT_DIR` only when root-anchored — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`. The install helper is unchanged.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-session-bridge"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-session-bridge"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-questions.service`, `kendex.pi-session-bridge.installed`, `kendex.pi.activity`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.4.0

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
