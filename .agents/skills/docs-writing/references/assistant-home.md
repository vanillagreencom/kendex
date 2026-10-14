# Assistant-home documents

Read when writing or rewriting an assistant home's policy, recurring procedures, memory or session records. A software-only document does not load this reference.

Use the home's own reading routes. Jarvis owns authority in `references/decisions.md` § Authority, evidence in `references/verification.md` § Sources, memory in `references/memory.md` § Notes, and session state in `references/long-session.md` § Handoff. Read those installed contracts for fields, storage and retention. These examples illustrate content; they add no contract or authority.

The records below are invented examples. Their source entries are included so the reader can check each rewrite.

## Dated authority reference

**Source grant, 2026-10-12, owner Mira**: "The assistant may close duplicate draft tasks in the session project after checking both records. Do not close tasks assigned to another person. Review this grant when the project changes. This replaces my earlier draft-task grant."

**Rewritten reference**: Under Mira's grant of 2026-10-12, the assistant may close duplicate draft tasks in the session project after checking both records. Tasks assigned to another person are excluded. Review the grant when the project changes. It supersedes Mira's earlier draft-task grant. Source: [source grant](#dated-authority-reference).

Use Jarvis `references/decisions.md` § Authority to decide whether the grant permits an action. The rewrite preserves the grant; it does not extend it to other actions.

## Recurring workflow

**Source procedure**: The assistant reviews draft requests at session start and on each request event. Read the request's original record before preparing a draft. If the record is unreadable, leave the check unresolved. At hand-over, identify the unread record and the next read before control transfers.

**Rewritten procedure**:

- Start: read each draft request's original record, then prepare its draft. Keep a check unresolved when its record is unreadable.
- Event: read the new request's original record before preparing its draft. Keep an unread record unresolved.
- Hand-over: identify each unread record and its next read before control transfers, using Jarvis `references/long-session.md` § Handoff.

Source: [source procedure](#recurring-workflow). This keeps the reading prerequisite in each mode. Jarvis `references/long-session.md` § Homes owns session prerequisites and record destinations.

## Sourced memory note

**Source observation, 2026-10-12**: The assistant opened the draft folder in the user's current browser session. Other sessions were not checked. The observation replaces the earlier unchecked folder note.

**Rewritten note**, using Jarvis `references/memory.md` § Notes:

### Draft folder access

The draft folder opened in the user's current browser session. Access from other sessions remains unchecked.

- Source: [source observation](#sourced-memory-note).
- Date: 2026-10-12.
- Supersedes: the earlier unchecked folder note.

The note's reading route names this subject. The observation establishes access only in the session checked; it grants no action.

## Handoff

**Source checkpoint, 2026-10-12**: Draft request TASK-DRAFT awaits a read of its original record. The service refused access. No draft is prepared. The user instruction TEMP-DRAFT says to hold the draft until access returns.

**Rewritten State entry**: TASK-DRAFT, checked 2026-10-12: original-record verification remains unresolved because the service refused access. Next action: read the original request record when access returns. Source: [source checkpoint](#handoff).

**Rewritten Instructions in force entry**: TEMP-DRAFT, recorded 2026-10-12: hold the draft until access returns. Source: [source checkpoint](#handoff).

These are entries within the handoff, not a complete handoff. Jarvis `references/long-session.md` § Handoff owns its sections, ids, times, checkpoint, progress records and succession. Link a durable ruling's memory home under Jarvis `references/memory.md` § Notes. Keep the unresolved read and the temporary instruction's end event when shortening these entries.
