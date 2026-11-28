# Owner asks

Read when a console lists owner asks or sends Reply, Done or Later through `jarvis-session`. These operations need no running controller session.

```bash
.agents/skills/jarvis/scripts/jarvis-session owner-asks list --home HOME --view active|snoozed [--cursor CURSOR]
.agents/skills/jarvis/scripts/jarvis-session owner-asks render --home HOME
.agents/skills/jarvis/scripts/jarvis-session owner-asks reply|done|later --home HOME --id ID
.agents/skills/jarvis/scripts/jarvis-session owner-asks present --home HOME --destination KEY --root ROOT --id ASK
.agents/skills/jarvis/scripts/jarvis-session owner-asks deliver --home HOME
```

Each action reads one JSON object from stdin with `requestId` and `expectedRevision`. Reply requires `text`. Done takes optional evidence in `text`. Later requires `until`, a future absolute ISO time with an offset.

- Pass the page's opaque row identity and revision unchanged.

## Sources and authority

The [main and satellite binding](agent-reach.md#main-and-satellites) selects the authority. A satellite gives the main its own remaining deadline less `TRANSPORT_SECONDS`, so the main answers first with its own page or cause. If the call times out after the main printed its reached line, the failure's key is `main-slow`. If it times out before that line, the key is `main-unreachable`. A trip slower than `TRANSPORT_SECONDS`, such as a link above about a 180 ms round trip or an SSH connect near its `CONNECT_SECONDS` bound, also reports `main-slow`. The main alone reads the canonical sources and owns action deltas and receipts in its home runtime directory. A selected main configured as a satellite refuses the call.

The main reads the registered projects on its declared destinations from `kendex project list --json`. A registration whose folder is missing, is not a folder or cannot be read makes the list unavailable.

- To recover, remove the stale registration with `kendex project remove PATH`.

A registered folder that is not a git work tree, outside any repository or git metadata with no work tree, holds no mailbox and adds no asks. A repository git cannot read makes the list unavailable.

Every read runs the main's own package code with the main home's settings, as the destination's account, the control account on the control host. Mailbox `pending --to owner` supplies open asks. The public mailbox events supply the tracker-posting records. Linear reads run on the main with its own credentials.

Jarvis's own questions enter the page when sent. An overseer's question enters when the originating mailbox records its first presenter. An owner answer or resolution removes the row. An answer without a recorded owner sender leaves the row visible. The originating mailbox keeps an answered ask open until its asker resolves it.

The main home's mailbox `owner-tracker-settings` command supplies the existing posting configuration judgement. An unconfigured tracker adds no tracker requests. A configured tracker uses Linear `comments owner-requests` with that judgement's email and label. Each comment mentioning the resolved owner's canonical profile URL is a separate request. Its immutable comment identity, author, creation time, parent and server URL remain the original request metadata. No owner, team, account, profile URL or view name is a package default.

Jarvis verifies approval links against the posting record of the bound Slack relay. It reads records at the mailbox's main checkout and its registered linked checkouts on each destination. It matches the relay's ask or notice, presenter and thread stamp. A delegated ask also matches the notice's destination, repository root and ask id. A presented ask stays accessible with an unconfirmed thread when that proof is unavailable. A reserved row says where approval counts. A tracker-only row links to its request comment. A mailbox ask links to its tracker mirror when it has no confirmed Slack thread and a mirror exists. An unread mailbox source makes the list unavailable.

Cross-source suppression requires confirmed tracker posting and equality of the request comment identity. Distinct mailbox asks and distinct comments on one issue remain distinct. A mailbox ask's exact tracker mirror stays suppressed while the ask's tracker-posting record remains in the mailbox events, open or closed.

## Pages

`scripts/lib/owner_asks.py` declares the page row and encoded byte bounds. A successful page contains `v`, `homeId`, `revision`, `observedAt`, canonical `activeCount` and `snoozedCount`, `rows`, `nextCursor` and `complete`. Each row carries its stable identity, revision, kind, request text, original author and time, HTTP conversation link or a null link, opaque thread reference, current state, snooze time and actions.

On a request without a cursor, the main reads each configured source in full once, unless its last complete collection is less than `COLLECTION_SECONDS`, 60 seconds, old. It looks up tracker comment links for open mailbox asks and uses retained mailbox evidence for closed and replaced asks. It computes the counts and public revision from that observation and its action deltas. Continuation pages reuse the saved rows, revision and counts. A change during collection may appear on the next refresh. An incomplete read, an unread configured source, the command deadline or an oversized individual row returns structured unavailability with no counts. There is no added backlog cardinality cutoff or guarantee that an unrestricted backlog completes before the caller's existing deadline.

A request without a cursor inside that window takes the last collection and reads no source. Consoles that poll an unchanged list therefore cost at most 60 collections an hour, about 240 Linear requests at 4 per collection, however many poll. A change can take up to 60 seconds to show.

- A request that waits on the home's lock while a collection runs takes that collection.
- An action's own complete read becomes the last collection, so a list the action refused as changed shows the revision the action judged.
- A Reply or Done ends the window once its send settles, so the next request reads the sources.

Rows sort by original asked-at time, then identity. A cursor binds the home, view, public revision and next position. The revision covers every row, so a walk reads on through any refresh that finds the same revision. A refresh that finds a different revision invalidates the earlier cursors in either view. An accepted Done or Later invalidates cursors in both views.

- Refresh from the first pages after a stale-cursor result.

Next replaces the visible page; final pages alone have `complete=true` and a null next cursor. Both views share the same metadata when their source and action evidence match.

## Slack rendering

`render` walks the active and set-aside pages at one revision. It prints the reading time, canonical counts and whole rows with the first sentence, age, asker, conversation link and approval status where present. The result begins with `kendex-owner-asks-v1` on its own line, followed by one JSON object for the Slack relay. A failed source or stale walk puts its cause in the result. A capture limit can omit whole rows while preserving their canonical counts.

## Reply and Done

An answer goes to the conversation the row was read from, so no credential crosses machines:

- A mailbox ask's answer is an owner answer in its own mailbox, `lane-mail send --re` with a delivery identity and `--sender owner`, run as for the reads. Writing it takes no credential. Whatever carries it further, that destination's own relay or tracker mirror, runs there with its own settings and credentials.
- A tracker item was read with the main's own Linear credential, so the reply is a comment under the exact question in the same workspace, posted with that credential. It holds the owner's text alone, with no agent attribution line. Its comment identity is a UUID the main mints.

Reply sends the text. Reply and Done carry the owner's words alone. An answer Jarvis gives under delegated authority does not go through them: send it with `lane-mail send --re` or `resolve --text` and `--sender jarvis`, so its ruling comment names Jarvis. If that lane-mail refuses `option-unknown=--sender`, keep the answer and send it again unchanged once that destination's orch and mailbox packages are both updated. Never send it without `--sender`, per orch's [communication-modes.md § Answers](../../orch/references/communication-modes.md#answers). A tracker-only row leaves the list when the configured owner's reply reaches its exact question comment, the runtime writes a ruling with the comment ID reserved for that question, or a replacement settles it. It also leaves when its item is in a closed state type: completed, canceled or duplicate. Done sends a claim line, then any evidence text, for the delegate to verify, and the row reports `checking`. It calls no closure route and removes no tracker label. The row stays `checking` until a complete read omits it. Later on a checking row hides it until `until`, then it reports `checking` again. Done on a snoozed row ends the snooze.

The main records the request before it sends. A send whose outcome is unknown, a lost connection or an unconfirmed tracker write, returns unavailable and keeps the request. An identical retry settles it by its own identity, whatever the revision is by then:

- A mailbox answer is sent again under the same delivery identity. lane-mail names the answer already standing and appends nothing.
- A tracker reply is read by its comment identity first, and sent again under that identity only where Linear has no such comment.

A Slack reply through a presentation already bound to an ask can arrive after closure. The mailbox includes the original question beside the owner's words. A Console Reply or Done received after closure is refused with state `closed`.

## Presenting an overseer's ask

New delegated presentations are on hold at every origin. Use the manual owner-ask route. The `present` command reads an existing receipt using the destination, repository root and ask id from the original mailbox event. An ask without a receipt returns `unavailable` and directs the caller to the manual route. A notice already waiting to post stays held.

The `present` receipt carries a confirmed thread or `delivery: unconfirmed` when the relay has yet to establish it. A second presenter sees the first presentation's state. `deliver` reads replies bound to presentation notices and writes the owner's words to their original mailboxes with the Slack event's delivery identity. Run it from the home watch alongside `lane-mail owner-answers`. It reports undelivered replies until each originating mailbox confirms its copy. Repeating the command resumes unconfirmed deliveries.

## Receipts and Later

An action receipt contains `v`, `requestId`, `kind` (`accepted` or `refused`), `state` and a plain `cause`. A new action checks membership and revision against two matching complete collections. A stale revision refuses with the current request state. Reusing an identity with another payload refuses. An identical retry returns the saved receipt before testing its old revision.

Later changes only main-owned visibility until the main clock reaches `until`. The row then returns with its original request time and link.

A complete read owns page membership. The mailbox view removes a row once it reads an owner answer, including a Done claim. The Done receipt still reports `checking` for the console. A later complete read that omits a row removes its checking or snooze state. Failed or incomplete reads preserve action state and report unavailable.

Failures return `{v:1,kind:"unavailable",cause:string}` and a nonzero exit. A transport timeout or missing receipt proves neither acceptance nor refusal.

- Retain the request identity until an identical retry returns its receipt.
