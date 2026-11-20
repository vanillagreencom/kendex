# D034: A Copilot CLI session no other reader measures is read from its own events.jsonl

[← Decision Index](INDEX.md)

**Date**: 2026-11-15

**Status**: Active

**Research**: [KEN-5196](https://linear.app/vanillagreen/issue/KEN-5196); a reading of one Copilot CLI 1.0.112 session record, member names and counts only

**Refines**: [D015](D015-copilot-compaction-handoff.md): a fallback source after the extension's reading and the status-line record; D015's rejection of the usage checkpoints stands.

**Decision**: Where the kendex extension recorded no reading of a Copilot CLI session and its status-line record does not answer, the turn end reads the session's own `events.jsonl`. The reading is the last `tool.execution_complete` row's `data.toolTelemetry.metrics.context_current_tokens` against `context_token_limit`, or a later `session.compaction_complete` row whose `data.success` is `true`, its `postCompactionTokens` against `tokenLimit`. It takes the same share of the limit as the extension's reading. A session whose record holds no such row is reported as `context-unmeasurable`; no figure is guessed.

**Why**: The record carries the CLI's own current count at every tool call and the count a successful compaction left. In the record read, 1,936 of 1,970 tool rows held the count: 32 had no `metrics` and 2 had `metrics` without `context_current_tokens`. A compaction that did not succeed left the context as it was. Without this source, a session whose extension and status line both fail runs unmeasured until Copilot compacts it with no hand-over.

**Rejected**: The 6 `session.usage_checkpoint` rows, as D015 rejects them: they hold running totals and no context figure. A `session.usage_record` row's `data.usage.inputTokens`: the last call's prompt size, below the CLI's own count.

**Revisit when**: Copilot CLI drops these members from its record, or the extension's reading stands for every session from its start.
