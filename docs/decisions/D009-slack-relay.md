# D009: One standard-library relay carries the overseer mailbox to Slack, and the mailbox stays the ledger

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Active (transport and topology → D014)

**Research**: KEN-1845

**Decision**: The `slack` package is one Python standard-library script that relays an overseer mailbox to one private channel. It reads and writes the mailbox only through `lane-mail`, Slack is never the ledger, and the mailbox's locked check-and-append judges every repeated delivery the relay's journal did not record: every inbound delivery carries `--delivery-id channel:ts`, and outbound posts are bounded by two horizons so a restart with no journal never reposts history. The transport and the one-relay-per-machine topology are [D014](D014-slack-socket-mode.md).

**Why**: The owner reads Slack on a phone and is away from the terminal most of the day. A standard-library script keeps a dependency manager out of a catalog that ships standard-library scripts, and the mailbox on disk under its lock is the one place a question cannot be lost.

**Rejected**: A Slack SDK or Bolt app: a dependency and a package manager, and an event loop that owns the process. Slack as the record of pending questions: a message the relay cannot find is a question lost.

**Revisit when**: A second consumer of Slack events appears that one relay cannot serve, or the catalog admits a dependency manager.
