# D017: Slack keeps bounded parent context and routes live replies at any age

[← Decision Index](INDEX.md)

**Date**: 2026-10-01

**Status**: Active

**Research**: KEN-2206

**Refines**: [D009](D009-slack-relay.md) and [D014](D014-slack-socket-mode.md), their identifiers-only journal storage and age-limited live replies only

**Decision**: The journal schema, `skills/slack/schemas/journal.md`, owns parent fields and retention. A live owner reply routes under any parent at any age. Reconnect reads and pruning stay bounded, and `Binding.bound_at` owns the retained channel and journal lifetime, not delivery progress.

**Why**: Identifiers alone lose the conversation an owner is continuing, and a live age limit drops an owner's reply in an ongoing conversation.

**Rejected**: Keeping the age limit and asking the owner to open a new thread: the owner replies where the question was asked.

**Revisit when**: Slack changes event delivery, or journal retention needs change.
