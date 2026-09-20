# Changelog

## Consumer-impacting changes

### Unreleased

- Streaming events no longer freeze the Pi TUI. Pi fires `message_update` once per token and `tool_execution_update` once per partial tool result, and each payload carries the whole value so far, so the bridge was writing the entire assistant message to the raw sidecar on every token and rewriting the 16 MB sidecar once the cap was reached. These two events now publish delta-only envelopes: the descriptor keeps the delta and the identity fields, `originalBytes` counts the delta, and nothing spills. Whole payloads still reach the sidecar on `message_end` and `tool_execution_end`, so `pi-bridge history --raw` still rehydrates a finished message. A `tool_execution_update` envelope no longer carries `*Bytes` counts or previews of the partial result.
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
