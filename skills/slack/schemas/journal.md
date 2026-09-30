# The relay's record

What one checkout keeps under `tmp/slack/`. Every file but an owner's own under `files/` holds identifiers, never a message body.

| File | Writer | Holds |
|------|--------|-------|
| `binding.json` | `setup`, and the relay when `SLACK_OWNERS` changes | The channel and the owners |
| `journal.jsonl` | The relay | The transport ledger, one JSON object per line |
| `status.json` | The relay, every poll | The record `listen --status` reads |
| `listen.lock` | The relay | The OS lock; its text is the holder's pid |
| `files/<file id>-<name>` | The relay | A file an owner sent, as Slack served it; the directory mode 700, each file 600. Every character of `<file id>-<name>` outside `A-Z a-z 0-9 . _ -` is `_`, and `<file id>-<name>` is cut to its first 200 characters |

## The binding

| Field | Value |
|-------|-------|
| `channel` | The Slack channel id the relay reads and posts to |
| `channel_name` | The channel's name at binding time |
| `bound_at` | The moment of the binding as a Slack stamp; a start whose journal holds no `start` line reads the channel from here |
| `owners` | The `SLACK_OWNERS` list the ids were resolved from |
| `owner_ids` | Email address to Slack user id, one entry per owner |

A relay whose `SLACK_OWNERS` differs from `owners` re-resolves the ids and rewrites the binding before it delivers anything more.

## Journal lines

Every line carries `t`, its kind. The relay replays the file at start; a line of another shape is refused `journal-invalid` with its line number.

| `t` | Fields | Meaning |
|-----|--------|---------|
| `seen` | `ts` | The channel's history is read past this stamp; `compact` keeps the last one. A message event never writes it: a history read does, and so does a start whose journal holds no `start` line, which writes the binding moment |
| `start` | `at`, `ids` | Written by a start whose journal holds no `start` line, after its `seen`, so connection lines alone never count as seeded: the mailbox's newest envelope `at` then, or empty with none, and the ids of the envelopes stamped in that second. A notice or answer before it, or in that second and named, is never posted; an open ask is |
| `hold` | `at` | `SLACK_MASTER_FILE` turned fresh: no mailbox envelope posts until the poll that ends the hold. `at` is the file's mtime at the first held poll. Written on the transition alone; `compact` drops it once a `resume` follows |
| `resume` | `from_at`, `at`, `seen`, `skipped`, `asks` | The hold ended. `from_at` is its `hold` line's `at`; `at` is the resume poll's UTC second. `seen` is the master's mailbox line count from `to-overseer.seen`, clamped to the listed lines, or `"none"` for a missing, unreadable or invalid file. `skipped` is required, even when empty. It lists the not-yet-carried owner notice ids on lines at or below that count from the complete snapshot, even if a dead token stops an earlier post; replay adds them to the carried ids. `asks` lists open ask ids whose posts landed, never one refused or lost. Written after the posts, even if a dead token stops them. `compact` keeps the skipped ids with this line and drops it once its `at` is older than `SLACK_THREAD_DAYS` |
| `in` | `channel`, `ts`, `kind`, `id`, `thread` | A Slack message delivered to the mailbox: `kind` is `directive` or `answer`, `id` the envelope it landed as, `thread` the parent stamp it belongs to |
| `in` | `channel`, `ts`, `kind` = `ignored`, `reason` | A message answered once and not routed: `reason` is `not-owner`, or `no-text` for a message with no text and no file |
| `out` | `channel`, `id`, `kind`, `state`, `at`, `thread` | A mailbox envelope posted: `kind` is `ask`, `notice` or `answer`; `state` is `open` for an ask awaiting its answer, `resolved` otherwise; `thread` the stamp the post is under, the ask's own for an ask |
| `out` | `channel`, `id`, `kind` = `notice`, `state` = `file`, `at`, `file` | A report uploaded; its thread is bound by a later `bound` line |
| `out` | `channel`, `id`, `kind`, `state` = `unknown`, `at` | A post whose response was lost; shown by `--status`, never repeated. A post Slack refused or never received has no line: the next poll makes it again |
| `out` | `channel`, `id`, `kind`, `state` = `refused`, `at`, `reason` | A post refused before sending; `reason` is the refusal key, `secret-value` or `file-unreadable` |
| `resolved` | `id` | The ask with this envelope id is closed. A reply event under its thread is routed while its parent is younger than `SLACK_THREAD_DAYS`, and a history read reads the thread only when its latest reply moved |
| `bound` | `file`, `id`, `ts` | The share message Slack made for an uploaded file; its thread now carries the notice's envelope |
| `thread` | `ts`, `seen` | The thread under `ts` is read past the reply stamp `seen`; only a history read writes it |
| `mark` | `ts`, `name` | The directive's message at `ts` carries the reaction `name`: `eyes` once delivered, `white_check_mark` once the overseer's `to-lane.cursor` passes the directive. Each delivery and each poll marks `eyes` a `directive` `in` line with no `mark` line. An `eyes` line with no later `white_check_mark` line is checked every poll; `compact` drops a mark line once `ts` is past `SLACK_THREAD_DAYS` and the directive is read, and keeps the `in` and `mark` lines of a directive with no `white_check_mark` line whatever their age |
| `connect` | `at` | The relay's first Socket Mode connection since it started is open: Slack's `hello` arrived at the UTC second `at`. The next poll reads the channel's history |
| `disconnect` | `at`, `reason` | The connection closed at `at`. `reason` is `slack-<reason>` for Slack's own `disconnect` envelope, such as `slack-refresh_requested`, or the client's cause, such as `connection ended` or `no frame in 60s` |
| `reconnect` | `at` | A later connection is open; the next poll reads the channel's history, which delivers what was sent while the relay was disconnected |

Stamps (`ts`, `thread`, `seen`) are Slack message stamps, seconds with six decimals; `at` is the UTC second `lane-mail` writes, or the relay's clock on a connection line. `compact` drops a connection line once its `at` is older than `SLACK_THREAD_DAYS`; the connection lines of one relay are written to the journal of every root it serves, and replay reads nothing from them. Every inbound delivery hands `lane-mail` the key `channel:ts`. Every `out` line carries its envelope's `at`. An envelope whose `at` is older than `SLACK_THREAD_DAYS` is never posted, and `compact` judges an `out` line by that same `at`, never by its `thread`, so a line it drops is one whose envelope can never post again.

## The status record

`status.json` is rewritten after every poll.

| Field | Value |
|-------|-------|
| `pid` | The relay's process id |
| `channel` | The bound channel id |
| `poll_seconds` | The `SLACK_POLL_SECONDS` the relay runs with |
| `compacted_day` | The UTC day the journal was last compacted, or first seen |
| `last_poll`, `last_poll_ok` | The clock at the last poll and whether it succeeded |
| `last_error` | The keyed refusal of the last failed poll, empty after a successful one |
| `last_delivered_ts`, `seen_ts` | The last stamp delivered and the history position |
| `open_asks`, `unknown`, `refused` | Envelope ids: asks awaiting an answer, posts with a lost response, posts refused |
| `calls_last_minute` | Slack Web API calls made with the bot token in the last minute |
| `connection`, `connection_since` | `connected` while the Socket Mode connection is open, `reconnecting` while the relay tries to open one, `disconnected` for a `--once` run, which opens none; and the UTC second the state began |
| `connection_error` | The keyed refusal of the last refused connect or drop while `reconnecting`; empty once a connection opens |
| `held_by` | `master` while a hold stands, empty otherwise |


`listen --status` prints per root: `state` (`ok` inside two poll intervals plus five seconds of a successful poll, `failing` inside that of a refused one, or of one with a `connection_error` after 120 seconds `reconnecting`, `stale` past it, `never` with no record), `channel`, `last_poll_age`, `connection` and `connection_since` (for a `stale` record `disconnected` since its `last_poll`, since its relay is gone), `last_delivered_ts`, `open_asks`, `oldest_unknown`, `refused`, `calls_last_minute`, `held-by=master` while a hold stands, and `fix=` when the state is not `ok`: `last_error` for a refused poll, else `connection_error` for `failing`, a restart for `stale`, the start command for `never`. A `never` line carries `fix=` alone, with no other field.
