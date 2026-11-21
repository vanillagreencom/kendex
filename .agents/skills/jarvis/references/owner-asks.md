# Owner asks

Read when a console lists owner asks or sends Later through `jarvis-session`.

```bash
.agents/skills/jarvis/scripts/jarvis-session owner-asks list --home HOME --view active|snoozed [--cursor CURSOR]
.agents/skills/jarvis/scripts/jarvis-session owner-asks later --home HOME --id ID
```

Later reads one JSON object from stdin with `requestId`, `expectedRevision` and `until`, a future absolute ISO time with an offset. Pass the page's opaque row identity and revision unchanged. Every row reports Reply and Done as not allowed, with a reason; KEN-5390 adds them.

## Sources and authority

The [main and satellite binding](agent-reach.md#main-and-satellites) selects the authority. A satellite calls the main synchronously through the existing SSH transport. The main alone reads the canonical sources and owns action deltas and receipts in its home runtime directory. A selected main configured as a satellite refuses the call.

The main reads the registered projects on its declared destinations from `kendex project list --json`. A registration whose folder is missing, is not a folder or cannot be read makes the list unavailable; remove the stale registration with `kendex project remove PATH` to recover. A registered folder outside any git repository holds no mailbox and adds no asks.

Every read runs the main's own package code with the main home's settings, as the destination's account, the control account on the control host. A destination supplies data alone: its registry and each root's mailbox files. Mailbox `pending --to owner` supplies open asks. The public mailbox events supply the tracker-posting records. Linear reads run on the main with its own credentials.

The main home's mailbox `owner-tracker-settings` command supplies the existing posting configuration judgement. An unconfigured tracker adds no tracker requests. A configured tracker uses Linear `comments owner-requests` with that judgement's email and label. This reader uses the existing assigned-issue filters and exact-email resolver. Each comment mentioning the resolved owner's canonical profile URL is a separate request. Its immutable comment identity, author, creation time, parent and server URL remain the original request metadata. No owner, team, account, profile URL or view name is a package default.

A row's link is the request comment's server URL. A mailbox ask's link is the URL of its exact tracker mirror. A mailbox ask with no tracker mirror has no confirmed link, and it makes the list unavailable. The cause names the ask, its mailbox root and destination, and the fix: post the ask to the tracker or close it. An unread source also makes the list unavailable.

Cross-source suppression requires confirmed tracker posting and equality of workspace, issue UUID and request comment identity. Distinct mailbox asks and distinct comments on one issue remain distinct. A mailbox ask's exact tracker mirror stays suppressed while the ask's tracker-posting record remains in the mailbox events, open or closed.

## Pages

`scripts/lib/owner_asks.py` declares the page row and encoded byte bounds. A successful page contains `v`, `homeId`, `revision`, `observedAt`, canonical `activeCount` and `snoozedCount`, `rows`, `nextCursor` and `complete`. Each row carries its stable identity, revision, kind, request text, original author and time, HTTP conversation link, opaque thread reference, current state, snooze time and actions.

The main requires two identical complete canonical evidence collections before computing counts and the common revision. It retains no source snapshot. Its revision binds that observed evidence and its own action deltas; it is not an upstream transaction identifier. A changed or incomplete read, an unread configured source, the command deadline or an oversized individual row returns structured unavailability with no counts. There is no added backlog cardinality cutoff or guarantee that an unrestricted backlog completes before the caller's existing deadline.

Rows sort by original asked-at time, then identity. A cursor binds the home, revision, view and next position. A revision change invalidates an earlier cursor. Refresh from the first pages after a stale-cursor result. Next replaces the visible page; final pages alone have `complete=true` and a null next cursor. Both views share the same metadata when their source and action evidence match.

## Later

An action receipt contains `v`, `requestId`, `kind` (`accepted` or `refused`), `state` and a plain `cause`. A stale revision refuses with the current request state. Reusing an identity with another payload refuses. An identical retry returns the saved receipt before testing its old revision.

Later changes only main-owned visibility until the main clock reaches `until`. The row then returns with its original request time and link.

A complete read alone owns membership. An ask stays open while a complete read returns it: mailbox `pending`, or the configured tracker view for a tracker-only request. A later complete read that omits it removes its snooze: after the delegate's mailbox close, compaction after that close, a root or host the main no longer reads, or a label or assignee change. Failed or incomplete reads change no action state and report unavailable. Listing retains no untouched request identities or historical membership.

Failures return `{v:1,kind:"unavailable",cause:string}` and a nonzero exit. A transport timeout or missing receipt proves neither acceptance nor refusal. Retain the request identity until an identical retry returns its receipt.
