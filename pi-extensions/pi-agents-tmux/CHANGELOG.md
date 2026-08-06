# Changelog

## Consumer-impacting changes

### 2.7.1

- Bg one-shot tasks now complete promptly after Pi emits `agent_settled`; the runner accepts settlement only after the latest low-level run ends, transfers timeout ownership while shutdown is active, permits continuation cancellation only before termination delivery succeeds, bounds failed termination attempts, and reports forced completion only for a matching signal or exit status.
- Provider rate-limit retry remains scoped to persistent pane children so bg one-shot settlement cannot terminate a child with an advertised retry still pending.
- Dashboard usage parsing now streams transcripts, refreshes terminal tasks through their final transcript update, evicts fingerprints when tasks leave the retained dashboard set, and drains completion usage writes before session shutdown.

### 2.7.0

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
