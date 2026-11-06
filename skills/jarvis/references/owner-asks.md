# Owner asks

Read when a console lists owner asks or sends Reply, Done or Later through `jarvis-session`.

```bash
.agents/skills/jarvis/scripts/jarvis-session owner-asks list --home HOME --view active|snoozed [--cursor CURSOR]
.agents/skills/jarvis/scripts/jarvis-session owner-asks reply|done|later --home HOME --id ID
```

Actions read one JSON object from stdin. Each object carries `requestId` and `expectedRevision`. Reply requires `text`. Done accepts optional evidence in `text`. Later requires `until`, a future absolute ISO time with an offset. Pass the page's opaque row identity and revision unchanged.

## Sources and authority

The [main and satellite binding](agent-reach.md#main-and-satellites) selects the authority. A satellite calls the main synchronously through the existing SSH transport. The main alone reads the canonical sources and owns action deltas and receipts in its home runtime directory. A selected main configured as a satellite refuses the call.

The main reads the registered projects on its declared destinations through the existing project discovery owner. Mailbox `pending --to owner` supplies open asks. The public mailbox events supply exact posting, delivery and closure evidence. The public Slack `ask-links` projection supplies a confirmed original conversation permalink when an exact tracker comment supplies none. An unposted conversation or an unread source makes the list unavailable.

The main home's mailbox `owner-tracker-settings` command supplies the existing posting configuration judgement. An unconfigured tracker adds no tracker requests. A configured tracker uses Linear `comments owner-requests` with that judgement's email and label. This reader uses the existing assigned-issue filters and exact-email resolver. Each comment mentioning the resolved owner's canonical profile URL is a separate request. Its immutable comment identity, author, creation time, parent and server URL remain the original request metadata. No owner, team, account, profile URL or view name is a package default.

Cross-source suppression requires confirmed tracker posting and equality of workspace, issue UUID and request comment identity. Distinct mailbox asks and distinct comments on one issue remain distinct. A closed mailbox ask's exact tracker mirror stays suppressed while canonical closure evidence remains.

## Pages

`scripts/lib/owner_asks.py` declares the page row and encoded byte bounds. A successful page contains `v`, `homeId`, `revision`, `observedAt`, canonical `activeCount` and `snoozedCount`, `rows`, `nextCursor` and `complete`. Each row carries its stable identity, revision, kind, request text, original author and time, HTTP conversation link, opaque thread reference, current state, snooze time and allowed actions.

The main requires two identical complete canonical evidence collections before computing counts and the common revision. It retains no source snapshot. Its revision binds that observed evidence and its own action deltas; it is not an upstream transaction identifier. A changed or incomplete read, an unread configured source, the command deadline or an oversized individual row returns structured unavailability with no counts. There is no added backlog cardinality cutoff or guarantee that an unrestricted backlog completes before the caller's existing deadline.

Rows sort by original asked-at time, then identity. A cursor binds the home, revision, view and next position. A revision change invalidates an earlier cursor. Refresh from the first pages after a stale-cursor result. Next replaces the visible page; final pages alone have `complete=true` and a null next cursor. Both views share the same metadata when their source and action evidence match.

## Actions and recovery

An action receipt contains `v`, `requestId`, `kind` (`accepted` or `refused`), `state` and a plain `cause`. A stale revision refuses with the current request state. Reusing an identity with another payload refuses. An identical confirmed retry returns the saved receipt before testing its old revision.

Reply sends through the original mailbox or tracker thread and leaves the ask open. Done records checking and sends a claim for the delegate to verify. It calls no closure route and removes no tracker label. Later changes only main-owned visibility until the main clock reaches `until`, retaining the original request and any checking claim.

The main saves delivery intent before an external append. An uncertain result stays unconfirmed. An identical deliberate retry reads positive canonical evidence; it never blindly resends. Mailbox recovery requires the exact delivery identity and ask reference. Tracker recovery requires the exact posting actor, original parent and body with its action marker. An empty read proves no failed delivery. Retained receipts survive source compaction, but an uncertain append whose positive evidence disappeared cannot be settled automatically.

The delegate's canonical mailbox close removes its ask after a complete source read. An acted-on mailbox ask that disappears without that evidence makes the list unavailable for delegate verification. The configured tracker view alone owns tracker-only membership: a request remains open while a complete read returns it. A later complete read that omits it closes it and removes any checking or snooze delta, including after a label or assignee change. Failed or incomplete reads change no action state and report unavailable. Listing retains no untouched request identities or historical membership.

Failures return `{v:1,kind:"unavailable",cause:string}` and a nonzero exit. A transport timeout or missing receipt proves neither acceptance nor refusal. Retain the request identity and reply draft until the delegate or a deliberate identical retry confirms the result.
