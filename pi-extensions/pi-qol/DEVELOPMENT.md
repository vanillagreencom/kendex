# pi-qol development

For maintainers. What it does for a consumer is [README.md](README.md); mechanics live as doc comments on the modules under `extensions/qol/`, and this file holds the invariants that span them.

## Invariants

- The budget guard is a two-phase protocol built on Pi's post-agent order, which is `agent_end`, then Pi's own compaction check (which may emit `session_compact`), then `agent_settled`. `agent_end` stages a trigger without calling `ctx.compact()`; a same-session `session_compact` satisfies it, so Pi's built-in compaction gets first refusal; `agent_settled` dispatches only a still-pending trigger and awaits the owned compaction's terminal callback, which keeps session shutdown and `pi-agents-tmux` one-shot teardown behind an active compaction. `extensions/qol/budget-guard-runtime.ts::BudgetGuardDriver`; `tests/qol-agent-end.test.ts` holds the ordering.
- Trigger state is owned by a generation. Every reset mints a non-reusable generation, and a callback changes state only when both its generation and its in-flight object identity still match; `extensions/qol.ts` binds the active generation to the current session manager, so a delayed event from a replaced session can neither consume nor satisfy a newer session's trigger. The `Already compacted` error is benign only when the current generation saw a later `session_compact` after its own dispatch; otherwise it stays visible and clears suppression so the next cycle retries.
- A satisfied threshold key suppresses repeat work until usage drops or advances to the next bucket; a transient failure suppresses nothing. `extensions/qol/budget-guard.ts::computeBudgetTrigger` owns the key.
- Budget-guard dispatch marks its custom instructions with `extensions/qol/budget-guard.ts::QOL_BUDGET_GUARD_SENTINEL`, and `extensions/qol/compaction.ts::handleQolCompaction` routes a request carrying it through the bounded summarizer even when `compaction.customEnabled` is off. Manual and idle compactions take that path only when the setting is on. Both write the handoff artifact only under `compaction.handoffArtifactEnabled`.
- `session_before_tree` is a separate path: `extensions/qol/compaction.ts::handleQolBranchSummary` uses the same chunked summarizer under `compaction.branchSummaryEnabled` and never writes a handoff artifact.
- Every summarization request, chunk and reduce pass alike, is bounded by `compaction.maxInputChars`; `extensions/qol/budget-guard.ts::orchestrateChunkedSummary` chunks and tree-reduces, and `tests/budget-guard.test.ts` holds every request under the cap.
- The handoff artifact lands under the shared per-session kendex tree, `<Pi root>/kendex/sessions/<session>/pi-qol/handoff/`, as a stamped file plus `latest.json`; `extensions/qol/compaction-handoff.ts::handoffBaseDir`. A write failure is a warning notification and a `handoffArtifactError` field, never a silent skip. `pi-session-manager` deletes that tree with the session.
- The permission gate fails closed: a matched command with no UI to ask is blocked, not allowed. `extensions/qol/permission-gate.ts::permissionGateMatch` is the one matcher.
- Scheduled prompts persist as `qol-schedule` custom session entries and are re-armed from the session branch on load; `extensions/qol/schedule.ts::createScheduleController`.
- Sibling extensions are reached only through the `Symbol.for` keys in `extensions/qol/constants.ts` and the interfaces in `extensions/qol/bridges.ts`; a missing sibling disables the feature, never throws.
- `/context` reports a failed transcript-risk estimate as a sanitized error block rather than omitting the warning; `extensions/qol/transcript-risk.ts::transcriptRiskState`.

## Tests

```bash
bun test ./tests
```

`bunfig.toml` preloads `tests/preload.ts`, which stubs the `@earendil-works/*` peers so the suite runs from a fresh checkout without `bun install`; a suite needing more of a peer overrides the stub with `mock.module` for itself. `tests/budget-guard-runtime.test.ts` covers key deduplication, ownership, resets and delayed callbacks; `tests/qol-agent-end.test.ts` covers the event wiring, including a delayed `session_compact` from a replaced session while the next one is pending or in flight.
