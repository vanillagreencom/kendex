# pi-qol — development notes

Implementation details for contributors. End-user setup, commands, settings, and behavior live in [`README.md`](./README.md). Consumer-visible changes live in [`CHANGELOG.md`](./CHANGELOG.md).

## Long-session budget guard

Core implementation:

- `extensions/qol.ts` — Pi event wiring, active-session ownership, status, and settings.
- `extensions/qol/budget-guard.ts` — threshold evaluation, trigger keys, bounded summarization, and sentinel detection.
- `extensions/qol/budget-guard-runtime.ts` — staged, satisfied, and in-flight state machine.
- `extensions/qol/compaction.ts` — bounded compaction handler.

### Lifecycle ordering

Pi awaits extension event handlers. Its post-agent order is:

1. Extension `agent_end` handlers run.
2. Pi performs its built-in compaction check and may emit `session_compact`.
3. Pi emits `agent_settled`.

QOL uses that order as a two-phase protocol:

- `agent_end` computes and stages a budget trigger without calling `ctx.compact()`.
- A same-session `session_compact` satisfies the staged trigger, so Pi's built-in compaction gets first refusal.
- `agent_settled` dispatches only a still-pending trigger.

`BudgetGuardDriver.dispatchPending()` returns both the immediate dispatch outcome and a completion promise. The `agent_settled` handler awaits that promise until the owned `ctx.compact()` `onComplete` or `onError` callback runs. This keeps terminal settlement and `pi-agents-tmux` one-shot shutdown behind active QOL compaction. Supported Pi hosts always route terminal compaction success or failure to one callback, so no timeout fallback is needed.

### State and session ownership

The driver owns three trigger states:

- pending — threshold crossed, waiting for settled-time dispatch;
- in flight — QOL called `ctx.compact()` and awaits its terminal callback;
- satisfied — the current threshold key completed and remains suppressed until usage drops or advances to a new key.

Every reset increments a non-reusable generation. Pending, satisfied, and in-flight records carry that generation. Callback effects require both generation ownership and in-flight object identity before changing state, status, or notifications.

`extensions/qol.ts` associates the active generation with the current `ctx.sessionManager`. Event handlers resolve their context back to that active session before staging, dispatching, resetting, changing budget-guard status, or accepting `session_compact`. Stale callbacks and delayed host events from replaced sessions therefore cannot consume or satisfy a newer session's trigger.

The exact `Already compacted` error is benign only when the current generation observed a later `session_compact` after QOL dispatched. Without that same-session evidence, the error remains visible and clears suppression so a later cycle can retry.

### Bounded-handler routing

Budget-guard dispatch adds `QOL_BUDGET_GUARD_SENTINEL` to its custom instructions. `session_before_compact` detects that sentinel and routes the request through QOL's bounded summarizer and handoff-artifact path even when the general custom-compaction setting is off. Manual, idle, and tree compactions use that path only when their corresponding custom settings are enabled.

### Regression coverage

`tests/budget-guard-runtime.test.ts` covers trigger-key deduplication, completion/error ownership, generation resets, duplicate-compaction evidence, and delayed callbacks.

`tests/qol-agent-end.test.ts` covers Pi event wiring and ordering, including:

- built-in compaction between `agent_end` and `agent_settled`;
- settled handler completion/error awaiting;
- session A dispatch, reset to session B, then a delayed A `session_compact` while B is pending;
- the same delayed event while B is in flight, proving it cannot suppress B's `Already compacted` error.

Run:

```bash
cd pi-extensions/pi-qol && bun test ./tests
```
