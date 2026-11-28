# The relay's record

What one checkout keeps under `tmp/slack/`. The journal holds identifiers and bounded parent excerpts. Queue requests retain their event text until handled; full messages otherwise stay in Slack and the mailbox.

| File | Writer | Holds |
|------|--------|-------|
| `binding.json` | `setup`, and the relay when `SLACK_OWNERS` changes | The channel and the owners |
| `journal.jsonl` | The relay | The transport ledger, one JSON object per line |
| `status.json` | The relay, every poll | The record `listen --status` reads |
| `listen.lock` | The relay | The OS lock; its text is the holder's pid |
| `inbox/<attempt>.json` | `deliver` | A complete queued event, atomically published |
| `outcomes/<attempt>.json` | The queue listener | One terminal outcome per attempt |
| `jarvis-session.lock` | The relay | The per-root OS hold lock for current or retained Jarvis presence |
| `files/<file id>-<name>` | The relay | A file an owner sent, as Slack served it |

- The listener removes an `inbox/` request after writing its outcome.
- An outcome carries `key` and `value` for the keyed CLI line. It is retained for the worker to inspect.
- Explicit posts probe the `jarvis-session.lock` ownership without writing. Release or process exit ends ownership; a file alone holds nothing.
- The `files/` directory has mode 700, each file 600.
- Every character of `<file id>-<name>` outside `A-Z a-z 0-9 . _ -` is `_`, and `<file id>-<name>` is cut to its first 200 characters.

## The binding

| Field | Value |
|-------|-------|
| `channel` | The Slack channel id the relay reads and posts to |
| `channel_name` | The channel's name at binding time |
| `bound_at` | Channel/journal lifetime start |
| `owners` | The `SLACK_OWNERS` list the ids were resolved from |
| `owner_ids` | Email address to Slack user id, one entry per owner |

- Repeat setup and owner changes retain `bound_at`. Only a journal reset starts a new time.
- A relay whose `SLACK_OWNERS` differs from `owners` re-resolves the ids and rewrites the binding before it delivers anything more.
- `listen --presentation-threads` gives Jarvis the current presentation stamps and Slack permalinks for the configured channel. A missing thread has no entry. Jarvis matches a stamp and presenter to the mailbox receipt before using the relay's link.
- Direct asks use presentation receipts when the bound mailbox's installed compactor retains them. An older compactor keeps the pre-presentation direct Slack route until the mailbox package is upgraded.
- Delegated presentation is on hold. Previously posted notices can still be confirmed and their replies delivered.
- An established presentation keeps its original binding through a cleanup-check failure, including when Slack deletes its root and the overdue reminder replaces it. A bound reply advances its journal delivery and Slack read mark only after its mailbox accepts it.

## Queue delivery

`deliver` reads the inner Slack message event that `on_message` consumes. It accepts no outer callback envelope. The hosted receiver owns signature and workspace checks, challenge responses, `event_id` deduplication and callback unwrapping. The worker calls the verb from the bound checkout as that checkout's user. `slack --help` defines the stdin fields and keyed results.

- Each queue attempt has a unique name.
- The inbox and outcomes directories have mode 700; request and outcome files have mode 600.
- The receiver retries the same event with its original `channel:ts`.
- A threaded event can read its thread for parent context.

## Journal lines

Jarvis's delivered `owner-unread` event produces a top-level notice under `owner-unread:<original mailbox id>`.

- The notice keeps the original message's `at`, seed boundary and posting horizon.
- Duplicate batches share that notice id.
- The event must carry `destination=local` and the encoded full bound mailbox root; older events without that binding are not rebound.
- Only `owner-unread` supplies the deadline decision. `owner-unanswered` does not page.

The page uses the ordinary `out` outcomes below.

- Its final dispatch admission rechecks the original read receipt and the session hold after text preparation; Slack's internal 429 retries remain part of that dispatch.
- A later mailbox read is not atomic with the send.
- The installed mailbox reader must support strict receipts. A missing capability or unavailable canonical receipt retains the candidate and fails that root's poll/status until recovery. Other roots and inbound delivery continue.
- Reaction-only receipt reads retain their existing compatibility behavior.

Every line carries `t`, its kind. The relay replays the file at start; a line of another shape is refused `journal-invalid` with its line number.

| `t` | Fields | Meaning |
|-----|--------|---------|
| `seen` | `ts` | The channel's history is read past this stamp |
| `start` | `position` | The mailbox seed a start whose journal holds no `start` line writes |
| `hold` | `at` | `SLACK_JARVIS_SESSION_FILE` turned fresh |
| `resume` | `from_at`, `at`, `seen`, `skipped`, `asks` | The hold ended |
| `in` | `channel`, `ts`, `kind`, `id`, `thread`, `generation` | A Slack message delivered to the mailbox |
| `in` | `channel`, `ts`, `kind` = `ignored`, `reason` | A message answered once and not routed |
| `out` | `channel`, `id`, `kind`, `state`, `at`, `thread` | A mailbox envelope posted |
| `out` | `channel`, `id`, `kind` = `notice`, `state` = `file`, `at`, `file` | A report uploaded |
| `out` | `channel`, `id`, `kind`, `state` = `inflight`, `at` | Written and synced before sending a mailbox post or upload |
| `out` | `channel`, `id`, `kind`, `state` = `progress`, `at`, `thread`, `next`, `hash` | An acknowledged report or answer Markdown continuation prefix under the original envelope id |
| `out` | `channel`, `id`, `kind`, `state` = `unknown`, `at` | A post whose response was lost, including a truncated response |
| `out` | `channel`, `id`, `kind`, `state` = `retry`, `at`, `reason` | Slack refused the post or never received it |
| `out` | `channel`, `id`, `kind`, `state` = `refused`, `at`, `reason` | A post refused before sending |
| `resolved` | `id`, optional `source`, optional `reason` | The journal's ask thread with envelope `id` is closed |
| `bound` | `file`, `id`, `ts` | The share message Slack made for an uploaded file |
| `parent` | `ts`, `parent` | A retained parent |
| `thread` | `ts`, `seen` | The thread under `ts` is read past the reply stamp `seen` |
| `mark` | `ts`, `name` | The owner message at `ts` carries the reaction `name` |
| `connect` | `at` | The relay's first Socket Mode connection since it started is open |
| `disconnect` | `at`, `reason` | The connection closed at `at` |
| `reconnect` | `at` | A later connection is open |

**`seen`**

- `compact` keeps the last one.
- A message event never writes it: a history read does, and so does a start whose journal holds no `seen` line, which writes the binding moment.

**`start`**

- It is written after its `seen`, so connection lines alone never count as seeded.
- `position` is the mailbox store's committed position when it is written, before the first post: for `to-overseer` and `to-lane`, the `count` of complete lines, compacted rows included, and the `first` id.
- A notice or answer on a line at or below its box's `count` is never posted. An open ask still posts. Mail appended later posts, whatever second it is stamped in. A replaced box, one that opens with another `first`, is not passed over.
- While `start` is unwritten, each poll reads the position before its deliveries, and so does the first pass that drains queued owner messages, once. An owner message's own delivery never reads it.
- The position read validates no envelope. A read that refuses leaves `start` unwritten: owner messages are still delivered, mailbox posts wait, and the first poll whose read succeeds writes it.
- A journal written before positions holds `at` and `ids` instead. It keeps that clock floor: a notice or answer stamped before `at`, or in that second and named in `ids`, is never posted.

**`hold`**

- The relay holds mailbox posts except replies to messages the owner typed in the channel, which still post in their threads, a notice that names a `/report` directive, and a notice that names a forwarded directive, with its root.
- `at` is the file's mtime at the first held poll.
- It is written on the transition alone. `compact` drops it once a `resume` follows.

**`resume`**

- `from_at` is its `hold` line's `at`; `at` is the resume poll's UTC second.
- `seen` is the Jarvis session's mailbox line count from `to-overseer.seen`, clamped to the listed lines, or `"none"` for a missing, unreadable or invalid file.
- `skipped` is required, even when empty. It lists all not-yet-carried owner notice and ask ids, other than replies to an owner message, a `/report` directive or a forwarded directive, that the routes classify as seen at or below that count from the complete snapshot, including closed asks, even if a dead token stops an earlier post.
- Replay adds the `skipped` ids to the carried ids.
- `asks` lists open ask ids whose posts landed, never one refused or lost.
- It is written after the posts, even if a dead token stops them.
- `compact` keeps the skipped ids with this line and drops it once its `at` is older than `SLACK_THREAD_DAYS`.

**`in`, `kind` = `directive` or `answer`**

- `kind` is `directive` or `answer`, `id` the envelope it landed as, `thread` the parent stamp it belongs to.
- `generation` names the reader generation at delivery; it is absent on older lines.
- A directive marks every message through its `ts` as delivered to that generation. An answer marks only its own `ts`, so earlier unseen thread messages remain eligible.
- Replay keeps each generation's latest directive mark and the individually delivered answers beyond it.

**`in`, `kind` = `ignored`**

- `reason` is `not-owner`, or `no-text` for a message with no text and no file.

**`out`, `state` = `open` or `resolved`**

- `kind` is `ask`, `notice` or `answer`.
- `state` is `open` for an ask not yet closed, and `resolved` for a completed post, not question closure.
- `thread` is the stamp the post is under, the ask's own for an ask.
- `presenter` identifies an ask or presentation notice whose first receipt binds its replies. A delegated presentation remains a notice in the journal and uses the notice id in the parent pointer.
- A later `out` line with `permalink` records the link Slack returned for that presentation's channel and thread stamp.
- A forwarded directive's root is a `notice` line under the directive's own `id`. Its `thread` is the root's stamp, which the directive's notices post under.

**`out`, `state` = `file`**

- A later `bound` line binds its thread.

**`out`, `state` = `inflight`**

- Replay treats it as `unknown` until a later outcome line for the same id.
- An append failure sends nothing.
- Compaction drops redundant settled pre-send lines; lone in-flight lines stay unknown.

**`out`, `state` = `progress`**

- New and overdue questions must fit one message and write no continuation progress.
- `thread` is the original root, `next` the zero-based index of the next part, and `hash` the SHA-256 of the prepared sequence and its requested thread.
- No message bodies are stored.
- Replay clears the preceding in-flight state and leaves the envelope eligible for its suffix.
- A changed sequence is refused; an ambiguous write stays unknown.
- A fully acknowledged sequence finalizes without another post.
- The ordinary terminal outcome removes progress. Compaction drops settled progress and expires incomplete progress by the envelope's `at`.

**`out`, `state` = `unknown`**

- `--status` shows it. It is never repeated.
- An ask or presentation notice carries its envelope id in Slack message metadata. A history read, bot event or targeted read of a reply's parent can confirm the root. Replay binds it as the original ask or notice. That readback supplies the thread link for the mailbox.
- A replacement root for a deleted approval thread follows the same rule. The new binding replaces the confirmed permalink and keeps the original ask and presenter.

**`out`, `state` = `retry`**

- `reason` is the refusal key.
- Replay clears `unknown` and makes the envelope postable again, retaining any acknowledged continuation prefix.
- A token refusal writes this line before stopping the relay.

**`out`, `state` = `refused`**

- `reason` is the refusal key: `secret-value`, `file-unreadable`, `text-too-long`, `text-not-literal` or `continuation-changed`.

**`resolved`**

- `source` names the consumed mailbox close under [Owner asks](../../orch/references/communication-modes.md#owner-asks); it is absent on older journal lines.
- Replay remembers each source while its thread mapping survives compaction.
- `reason=thread_not_found` marks a deleted thread and excludes it from later catch-ups and outbound targets; later answers and referenced notices post to the channel.
- The mailbox ask stays open until resolve closes it, the watch's deadline close included where lane-mail's owner-channel contract gives the ask one.
- Closure reads have no outbound posting horizon.
- Live later replies become directives; reconnect reads remain bounded.

**`bound`**

- Its thread now carries the notice's envelope.

**`parent`**

- It is retained from channel history, including reply-free parents within `SLACK_THREAD_DAYS`, or from the `conversations.replies` page that supplies a reply's thread context.
- Catch-up reuses its thread page; a live reply reads the whole thread or the messages after its generation's delivery mark.
- Replay caches the pointer for later replies.

**`thread`**

- Only a history read writes it.

**`mark`**

- `name` is `eyes` once an answer or directive lands, and `white_check_mark` once the overseer's `to-lane.cursor` passes the answer or directive.
- Each delivery and each poll marks `eyes` an `in` line for an answer or directive with no `mark` line.
- An `eyes` line with no later `white_check_mark` line is checked every poll.
- `compact` keeps the `in` and `mark` lines for unread deliveries and for each generation's latest directive mark and individually delivered answers beyond it. Other read deliveries and marks expire after `SLACK_THREAD_DAYS`.

**`connect`**

- Slack's `hello` arrived at the UTC second `at`.
- The next poll reads the channel's history.

**`disconnect`**

- `reason` is `slack-<reason>` for Slack's own `disconnect` envelope, such as `slack-refresh_requested`, the client's cause, such as `connection ended` or `no frame in 60s`, or `reload` when the relay closed it to re-execute onto updated code.

**`reconnect`**

- The next poll reads the channel's history, which delivers what was sent while the relay was disconnected.

Stamps (`ts`, `thread`, `seen`) are Slack message stamps, seconds with six decimals; `at` is the UTC second `lane-mail` writes, or the relay's clock on a connection line.

- `compact` drops a connection line once its `at` is older than `SLACK_THREAD_DAYS`.
- The connection lines of one relay are written to the journal of every root it serves, and replay reads nothing from them.
- Every owner message the relay delivers hands `lane-mail` the key `channel:ts`. A `/report` directive's key is `command:<trigger_id>`, which only `lane-mail`'s locked check judges, with no journal line.
- Every `out` line carries its envelope's `at`.
- An envelope whose `at` is older than `SLACK_THREAD_DAYS` is never posted, and `compact` judges an `out` line by that same `at`, never by its `thread`, so a line it drops is one whose envelope can never post again.

### Parent pointers

| Field | Value |
|-------|-------|
| `thread_ts` | Root stamp on a threaded directive |
| `parent.ts` | The same root stamp |
| `parent.author` | `owner` for a user message, `bot` for a message carrying `bot_id` |
| `parent.excerpt` | The parent's first 300 characters, with newlines collapsed to one line |
| `parent.envelope` | The envelope id only when the relay posted the parent |
| `parent.thread` | Every thread message up to and including the reply, root and both sides, that the reader generation has not been delivered, oldest first |

- `thread_ts` is absent on a top-level message or an ask's answer.
- Each `parent.thread` entry is `{ts, author, text}`: `author` is `owner` or `app`, and another person's message is left out.
- A generation's first directive carries all earlier messages except answers already delivered to that generation.
- `parent.thread` is read from Slack with the reply, never journaled.

A root `out` line carries `parent` for a relay-posted ask or notice. A `bound` line carries it for an uploaded file's share. Other roots get one `parent` line from the API.

- `compact` keeps presented threads so a late live reply can reach the original asker. It keeps other thread mappings while the ask is open or its root, read position or last delivered or posted message is within `SLACK_THREAD_DAYS`.
- Generation delivery knowledge and its receipt marks survive that horizon.
- Live events have no thread-age gate; the horizon bounds reconnect thread reads and other journal history.
- Catch-up reads every open ask and every thread whose parent or latest relay activity is within the horizon, including parents absent from the channel history read.

Catch-up can discover a report continuation's root before its final part lands. The terminal `out` outcome promotes that generic parent to the original envelope and kind. Its accumulated delivery and read marks remain attached to the same root.

## Thread read failures

```text
slack: thread-read-failed=ts=TS id=ID reason=KEY VALUE
```

One thread read was refused.

- `TS` is the parent stamp; `ID` is its envelope, empty for a parent with no known envelope. `KEY VALUE` names the refusal.
- Catch-up continues with other threads and outbound mail; a temporary refusal keeps catch-up due next poll, for known threads and parent discovery.
- A token refusal still stops the relay, and `slack-rate-limited` ends the catch-up until Slack's Retry-After passes, in place of this line.
- A deleted open ask writes `resolved` with `reason=thread_not_found`.
- A retained live event whose parent is deleted is dropped on poll with this line, not retried on every poll.

## The status record

`status.json` is rewritten after every poll.

| Field | Value |
|-------|-------|
| `pid` | The relay's process id |
| `code` | The fingerprint of the code the relay runs |
| `channel` | The bound channel id |
| `bound_at` | The binding's `bound_at`, which `setup --take` restores from when `binding.json` is lost beside its journal |
| `poll_seconds` | The `SLACK_POLL_SECONDS` the relay runs with |
| `inbound` | The source selected at startup, `socket` or `queue` |
| `compacted_day` | The UTC day the journal was last compacted, or first seen |
| `last_poll` | The clock at the last poll |
| `last_poll_ok` | Whether the last poll succeeded |
| `last_error` | The keyed refusal of the last failed poll |
| `last_delivered_ts` | The last stamp delivered |
| `seen_ts` | The history position |
| `open_asks` | Envelope ids of asks not yet closed |
| `unknown` | Envelope ids of posts with a lost response |
| `refused` | Envelope ids of posts refused |
| `calls_last_minute` | Slack Web API calls made with the bot token in the last minute |
| `connection` | The Socket Mode connection state |
| `connection_since` | The UTC second the state began |
| `connection_error` | The keyed refusal of the last refused connect or drop while `reconnecting` |
| `held_by` | `jarvis` while a hold stands, empty otherwise |

- A re-execution onto updated code keeps `pid`.
- `code` is 12 hex characters of one sha256 over `scripts/slack`, sorted `scripts/lib/*.py`, and the mailbox store, projection definitions and common-root resolver from the mailbox package installed beside Slack.
- `last_error` is empty after a successful poll.
- `connection` is `connected` while the Socket Mode connection is open, `reconnecting` while the relay tries to open one, and `disconnected` for a `--once` run or the unused socket default in queue mode.
- The reader uses `inbound` to choose its output, including for `--once` records.
- `connection_error` is empty once a connection opens.

`listen --status` prints per root:

- `state`:
  - `ok` inside two poll intervals plus five seconds of a successful poll.
  - `failing` inside two poll intervals plus five seconds of a refused poll, or of a poll with a `connection_error` after 120 seconds `reconnecting`.
  - `stale` past two poll intervals plus five seconds of the last poll.
  - `never` with no record.
- `channel`.
- `code`, `-` for a record without one.
- `last_poll_age`.
- `inbound`.
- `connection` and `connection_since`:
  - `connection=none` without `connection_since` whenever the record's `inbound` is `queue`, fresh or stale, regardless of its stored socket fields.
  - Otherwise:
    - For a `stale` record, `disconnected` since its `last_poll`, since its relay is gone.
    - For a record an older relay wrote without the connection fields, `unknown` since its `last_poll`, its state read from freshness and `last_poll_ok` alone.
- `last_delivered_ts`, `open_asks`, `oldest_unknown`, `refused`, `calls_last_minute`.
- `held-by=jarvis` while a hold stands.
- `fix=` when the state is not `ok`: `last_error` for a refused poll, else `connection_error` for `failing`, a restart for `stale`, the start command for `never`.

A `never` line carries `fix=` alone, with no other field.

## The Jarvis session hold

The relay pages an unread owner message from Jarvis's delivered `owner-unread` event in this root's mailbox. It waits for the session hold to end and checks the original message's read receipt before sending. A read message produces no page, even if it remains unanswered. A definite send refusal stays eligible for retry; an accepted page or an unknown send is not repeated. An unavailable relay cannot deliver a page, and a stopped producer emits no new event. Recovery handles retained events within the relay's existing history limit. [§ Journal lines](#journal-lines) define the event and receipt requirements and the limits of the send-time check.

The hold stands while the file `SLACK_JARVIS_SESSION_FILE` names is younger than `SLACK_JARVIS_SESSION_MAX_AGE`. The README's Setup gives the settings.

While held, ordinary mailbox posts wait and `--mention` posts without mentions, with a `mention-held` diagnostic. `slack listen --status` shows `held-by=jarvis`.

Owner messages still reach the overseer. Replies to messages the owner typed in Slack still post in their threads. A notice answering `/report` posts as a new channel message; a notice answering a forwarded request posts under its root, creating that root when needed.

Presence setting changes take effect at the next poll without a restart. Emptying or removing the file setting ends the hold. A stale or missing presence file also ends it, except that a running relay retains a renamed file's hold until the replacement is fresh or the retained file is stale. A failed settings read keeps that checkout's hold and fails its post step; other checkouts continue. The retired presence keys stay readable until kendex 2.0.0 with a `setting-renamed` warning; an explicitly set new key takes precedence, including an empty value.

The Jarvis watch marks the session's view read with `lane-mail events --item overseer --box to-overseer --mark-read --count N`. It saves the count its passes read only once the session drains the batch that carried them, never when a pass captures the mail. On resume, ordinary notices and questions the session marked read are skipped without a post or mention, including closed questions. Replies to Slack-origin messages, `/report` and forwarded requests still post. Later notices/questions and held answers continue to post. A missing, unreadable or invalid read marker skips nothing; hold times do not decide which messages were read.

The oldest supported mailbox producer is orch 3.0.0. Producers without usable position metadata still route, but cannot supply Jarvis-read suppression or position-based answer read marks.

A notice that answers the `/report` request with `lane-mail notice --ref` reaches the channel even during a hold. An ordinary `orch-runtime report write` notice has no request reference: it is held, skipped on resume if the session read it, and not sent during `ORCH_REPORT_QUIET_HOURS`.

## Reconnects and history

Socket Mode reconnects after a dropped connection. `SLACK_THREAD_DAYS` bounds reconnect history; live replies have no thread-age limit. Queue mode receives messages from a hosted receiver and reads no channel history. The hosted receiver owns retries. A first run starts after the last line in the mailbox, so it does not replay old posts. Open questions within the history limit still post.

## Lost responses

Posts whose response was lost are not repeated. Explicit refusals can retry after their cause is fixed.

## Slash command limits

- `/report` avoids duplicate delivery only when Slack resends the same request id; stable ids on resends are an assumption, not a guarantee from Slack.
- Oversized command output can be cut or withheld in full. The reply names the cut or refusal.
- A failed command names its cause; a killed command reports its signal without claiming an OOM cause or victim.

## Retired names

Slack reserves `/status`; the relay accepts that retired command name until kendex 2.0.0 and warns with its replacement, `/lanes`.
