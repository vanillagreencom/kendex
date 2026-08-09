# Changelog

## Consumer-impacting changes

### 2.7.1

- Pi 0.84.0 parity: the failed-bg-agent transcript flush now rebuilds the partial assistant message from streamed deltas. Pi's JSON/RPC `message_update` became delta-only (`toJsonEvent()` strips the cumulative `message` and `assistantMessageEvent.partial`), so flushing the newest event alone preserved a single delta instead of the answer-so-far — and the task-summary backfill, dashboard activity, and transcript display all read the assistant text from the event's `message`, so they recovered nothing from a bg agent that died mid-answer. The flushed `buffered: true` record now restores the rebuilt message onto the event's `message` field, where those readers already look, and repeats it in a record-level `partialMessage` field for direct inspection; both are omitted when the event still carries its own snapshot. Rebuilt blocks use Pi's own content shapes (`{ type: "text", text }` / `{ type: "thinking", thinking }`). When updates were seen but nothing could be rebuilt, the flush now emits a result diagnostic naming the unrecognized `assistantMessageEvent` types instead of writing an empty forensic record. New exports from `extensions/subagent/transcripts.ts`: `PartialAssistantMessageState`, `PartialAssistantContentBlock`, `createPartialAssistantMessageState()`, `applyPartialAssistantMessage()`, `partialAssistantMessage()`, `partialAssistantMessageDiagnostic()`, `resetPartialAssistantMessage()`.
- Bg one-shot tasks now complete promptly after Pi emits `agent_settled`; the runner accepts settlement only after the latest low-level run ends, transfers timeout ownership while shutdown is active, permits continuation cancellation only before termination delivery succeeds, bounds failed termination attempts, and reports forced completion only for a matching signal or exit status.
- Provider rate-limit retry remains scoped to persistent pane children so bg one-shot settlement cannot terminate a child with an advertised retry still pending.
- Dashboard usage parsing now streams transcripts, refreshes terminal tasks through their final transcript update, evicts fingerprints when tasks leave the retained dashboard set, and drains completion usage writes before session shutdown.

### 2.7.0

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
