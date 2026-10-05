# D014: The Slack relay receives owner messages over one Socket Mode connection per machine

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active (journal storage, live reply age → D017)

**Research**: KEN-2082

**Refines**: [D009](D009-slack-relay.md), replacing its polling and its one-relay-per-person topology

**Decision**: `slack listen` opens one Socket Mode connection with `SLACK_APP_TOKEN`, acknowledges every envelope as soon as its loop reads it, before the delivery, and delivers each message event through `lane-mail`. A history read on every connect and reconnect delivers what the connection missed. One relay per machine serves every checkout on it from one process and one connection, routing each event by channel, and each machine runs its own Slack app. The WebSocket client is a small RFC 6455 module in the package, `skills/slack/scripts/lib/websocket.py`.

**Why**: The owner requires each message to reach and wake a session at once, and a poll waits up to its interval. Slack sends each payload to one of an app's open connections, so one connection per app on one machine is the only topology in which every event reaches the relay that can write its mailbox. Acknowledging before delivery keeps a slow download from making Slack resend the envelope.

**Rejected**: A shorter poll interval: still a wait, and it spends a shared allowance. The `websocket-client` package or the Slack SDK: a dependency and a package manager on the control VM for a handshake one small module holds. The Events API over HTTP: a public URL and a server on the control VM.

**Revisit when**: Slack retires Socket Mode or the `message.groups` event, one machine needs more relays than one app serves, or the catalog admits a dependency manager.
