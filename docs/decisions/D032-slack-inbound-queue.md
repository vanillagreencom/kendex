# D032: A hosted Slack receiver delivers through an explicit queue mode

[← Decision Index](INDEX.md)

**Date**: 2026-11-08

**Status**: Active

**Research**: [KEN-4983](https://linear.app/vanillagreen/issue/KEN-4983), owner Slack 1794110289

**Refines**: [D014](D014-slack-socket-mode.md), adding hosted delivery beside Socket Mode

**Decision**: `SLACK_INBOUND` selects one inbound source at startup. Socket Mode remains the standard mode, with one app per machine. Queue mode uses a hosted receiver and one app per workspace. Its worker calls `slack deliver`; the listener sends queued events through the existing message handler. Queue mode opens no socket and reads no channel history. Neither mode falls back to the other. Both keep the existing journal and `channel:ts` mailbox keys, without migration code or shims.

**Why**: A single hosted receiver must route workspace events to the machine that owns each mailbox. Sharing a Socket Mode app across machines lets Slack choose a connection whose relay cannot reach the target mailbox. An explicit source keeps the receiver responsible for retries and prevents a second connection from taking its events.

**Rejected**: Socket Mode as a queue fallback: it creates a competing event receiver and hides hosted delivery failures. A new journal format: both sources deliver the same Slack events to the same mailbox owner.

**Revisit when**: A hosted receiver needs events beyond the relay's message handler, or the workspace needs more than one authoritative delivery route for a channel.
