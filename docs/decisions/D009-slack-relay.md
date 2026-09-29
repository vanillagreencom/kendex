# D009: One polling relay per person carries the overseer mailbox to Slack

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Active (polling, one relay per person → D014)

**Research**: —

**Applies to**: `skills/slack/`, `skills/orch/scripts/lane-mail` § Owner channel

## Summary

The `slack` package is one Python standard-library script that polls Slack's Web API and relays one checkout's overseer mailbox to one private channel. It reads and writes the mailbox only through `lane-mail`, one process serves every bound checkout of one person, and the mailbox's locked check-and-append judges every repeated delivery the relay's journal did not record.

## Context

An overseer asks its owner questions, reports and takes directives through its mailbox. The owner is away from the terminal for most of the day and reads Slack on a phone. The fleet runs several overseers on one host under one Slack app, and a workstation may run one more against the same app. The package catalog is standard-library only.

## Decision

1. **Build, not adopt.** The relay is this package. No Slack SDK, bridge or bot framework is a dependency.
2. **Polling, not Socket Mode.** Every `SLACK_POLL_SECONDS` the relay reads each bound channel's history since its journal position, the thread of every open question, and every tenth poll the other bound threads younger than `SLACK_THREAD_DAYS`.
3. **The mailbox relay.** Slack is never the ledger. Pending questions live in the mailbox, reports on disk, and the relay's journal holds identifiers only. Inbound, every delivery carries `--delivery-id channel:ts`: the journal skips a stamp it already carried, and `lane-mail` judges under its lock any stamp the journal lost, the crash between the append and the mark. Outbound, the journal's `out` lines are the record, bounded by two horizons: an envelope older than `SLACK_THREAD_DAYS` is never posted, and a start with no journal posts nothing at or before the mailbox's newest envelope but its open asks.
4. **One relay per person.** `slack listen --root A --root B` serves every bound checkout of one person from one process, with one token and one owners list from the process environment. Each checkout keeps its own binding, journal and lock.

## Rationale

- One token instead of two, no WebSocket, no SDK and no package manager in a catalog that ships standard-library scripts.
- Socket Mode spreads one app's events across every open connection, so several listeners on one app would each hear a fraction and a workstation listener would steal the host's events. A poll reads only its own channel.
- Each poll is its own reconciliation: catch-up after an outage is the same call with more pages.
- The mailbox already holds a locked check-and-append keyed by delivery id, so the crash between an append and the relay's mark loses nothing and repeats nothing.
- One process per person is one resident per person on a host where every resident counts, and no process crosses a home.

## Alternatives Considered

| Alternative | Why rejected |
|-------------|--------------|
| A Slack SDK or Bolt app in Python or Node | A dependency and a package manager in a standard-library catalog; the SDK's event loop owns the process the relay needs for its poll |
| Socket Mode | Two tokens, a WebSocket to reconnect and reconcile, and events split across every listener of the app |
| Slack as the record of pending questions | A message the relay cannot find is a question lost; the mailbox is on disk and under a lock |
| The journal alone as the judge of a repeated inbound delivery | The crash between `lane-mail`'s append and the journal's mark leaves a stamp the journal never saw; only the mailbox's own lock can answer it |
| Every `out` line kept forever, so the journal alone records what was posted | The mailbox lists every envelope forever, so the journal would grow with it; each `out` line carries its envelope's `at`, and compaction drops a line only once that `at` is past the horizon the relay never posts past |
| One relay per checkout | One resident per checkout, and the token and owners repeated per repository |

## Impact

- The fleet sets `SLACK_POLL_SECONDS` per home so the sum of every relay's calls per minute stays inside Slack's allowance for `conversations.history` and `conversations.replies`; `slack listen --status` prints each relay's figure.
- An owner's reply under a thread older than `SLACK_THREAD_DAYS` is not routed, and a reply under a younger notice waits up to ten polls; the package README states both.

**Revisit When**: Slack's history or replies allowance no longer holds every relay of one app at the poll interval the owner accepts; a second consumer of Slack events appears that polling cannot serve; or the catalog admits a dependency manager.

**Verification**: `skills/slack/tests/listen.test.sh`: the crash between the mailbox append and the journal mark delivers each note once, with a control whose delivery id is dropped; the second relay on one checkout is refused; the reply under a thread past `SLACK_THREAD_DAYS` is not routed.

**References**: KEN-1845, KEN-1844, KEN-1846
