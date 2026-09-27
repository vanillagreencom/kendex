# The relay's record

What one checkout keeps under `tmp/slack/`. Every file holds identifiers, never a message body.

| File | Writer | Holds |
|------|--------|-------|
| `binding.json` | `setup`, and the relay when `SLACK_OWNERS` changes | The channel and the owners |
| `journal.jsonl` | The relay | The transport ledger, one JSON object per line |
| `status.json` | The relay, every poll | The record `listen --status` reads |
| `listen.lock` | The relay | The OS lock; its text is the holder's pid |

## The binding

| Field | Value |
|-------|-------|
| `channel` | The Slack channel id the relay reads and posts to |
| `channel_name` | The channel's name at binding time |
| `owners` | The `SLACK_OWNERS` list the ids were resolved from |
| `owner_ids` | Email address to Slack user id, one entry per owner |

A relay whose `SLACK_OWNERS` differs from `owners` re-resolves the ids and rewrites the binding before it delivers anything more.

## Journal lines

Every line carries `t`, its kind. The relay replays the file at start; a line of another shape is refused `journal-invalid` with its line number.

| `t` | Fields | Meaning |
|-----|--------|---------|
| `seen` | `ts` | The channel's history is read past this stamp; `compact` keeps the last one |
| `in` | `channel`, `ts`, `kind`, `id`, `thread` | A Slack message delivered to the mailbox: `kind` is `directive` or `answer`, `id` the envelope it landed as, `thread` the parent stamp it belongs to |
| `in` | `channel`, `ts`, `kind` = `ignored`, `reason` | A message answered once and not routed: `reason` is `not-owner` or `no-text` |
| `out` | `channel`, `id`, `kind`, `state`, `thread` | A mailbox envelope posted: `kind` is `ask`, `notice` or `answer`; `state` is `open` for an ask awaiting its answer, `resolved` otherwise; `thread` the stamp the post is under, the ask's own for an ask |
| `out` | `channel`, `id`, `kind` = `notice`, `state` = `file`, `file` | A report uploaded; its thread is bound by a later `bound` line |
| `out` | `channel`, `id`, `kind`, `state` = `unknown` | A post whose response was lost; shown by `--status`, never retried |
| `out` | `channel`, `id`, `kind`, `state` = `refused`, `reason` | A post refused before sending; `reason` is the refusal key, `secret-value` or `file-unreadable` |
| `resolved` | `id` | The ask with this envelope id is closed; its thread is read every tenth poll from now on |
| `bound` | `file`, `id`, `ts` | The share message Slack made for an uploaded file; its thread now carries the notice's envelope |
| `thread` | `ts`, `seen` | The thread under `ts` is read past the reply stamp `seen` |

Stamps (`ts`, `thread`, `seen`) are Slack message stamps, seconds with six decimals. Every inbound delivery hands `lane-mail` the key `channel:ts`.

## The status record

`status.json` is rewritten after every poll.

| Field | Value |
|-------|-------|
| `pid` | The relay's process id |
| `channel` | The bound channel id |
| `poll_seconds` | The `SLACK_POLL_SECONDS` the relay runs with |
| `polls` | Polls since the record was first written; every tenth reads the other bound threads |
| `compacted_day` | The UTC day the journal was last compacted, or first seen |
| `last_poll`, `last_poll_ok` | The clock at the last poll and whether it succeeded |
| `last_delivered_ts`, `seen_ts` | The last stamp delivered and the history position |
| `open_asks`, `unknown`, `refused` | Envelope ids: asks awaiting an answer, posts with a lost response, posts refused |
| `calls_last_minute`, `budget_per_minute` | Slack calls made in the last minute, and the calls per minute the settings and open asks budget |

`listen --status` prints per root: `state` (`ok` inside two poll intervals plus five seconds of a successful poll, `failing` inside that of a refused one, `stale` past it, `never` with no record), `channel`, `last_poll_age`, `last_delivered_ts`, `open_asks`, `oldest_unknown`, `refused`, `calls_last_minute`, `budget_per_minute`, and `fix=` when the state is not `ok`.
