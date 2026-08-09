# Changelog

## Consumer-impacting changes

### 1.7.5

- Long-session budget guard now stages threshold crossings at `agent_end` and dispatches only after `agent_settled`, allowing Pi's built-in post-agent auto-compaction to complete first without a duplicate `Already compacted` failure.
- Successful `session_compact` events now satisfy the current trigger key. The same threshold bucket stays suppressed until usage falls below the guard or advances to a new trigger key; unrelated failures still surface and retry normally.
- Minimum supported Pi host is now 0.80.4 because the budget guard requires the `agent_settled` extension event introduced in that release.
- Budget-guard `agent_settled` handling now remains pending through the callback-based compaction lifecycle, preventing terminal settlement or one-shot pane shutdown from overtaking an active QOL compaction. Reset also invalidates delayed callbacks from prior sessions so they cannot mutate a newer dispatch.

### 1.7.4

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
