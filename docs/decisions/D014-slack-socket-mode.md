# D014: The Slack relay receives owner messages over one Socket Mode connection per machine

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: —

**Applies to**: `skills/slack/`

**Refines**: [D009](D009-slack-relay.md), whose items 2 and 4 this decision replaces; its item 1, build not adopt, and item 3, the mailbox is the ledger, stand.

## Summary

`slack listen` receives each owner message over Slack's Socket Mode, not by polling `conversations.history`. One relay per machine holds its Slack app's one connection for every checkout on that machine, acknowledges each envelope, and routes each message event by its channel. A history read on every connect and reconnect delivers what the connection missed. The WebSocket client is a small RFC 6455 client in the package, not a dependency.

## Context

Owner directive 1790643457 requires each owner Slack message to reach and wake a session at once. The polling relay of D009 read each channel every `SLACK_POLL_SECONDS` (15), so a message waited up to 15 seconds before the wake. Slack's own interface for this is Socket Mode: an app-level token with `connections:write` opens a WebSocket through `apps.connections.open`, and Events API payloads, a private channel's messages as the `message.groups` bot event, arrive over it with no public URL.

D009 rejected Socket Mode because Slack sends each payload to one of an app's open connections, with no pattern to which, so several listeners on one app each hear a fraction. That holds; the topology below answers it instead of avoiding Socket Mode.

## Decision

1. **Socket Mode, not polling.** `slack listen` opens one connection with `SLACK_APP_TOKEN`, acknowledges every envelope by its `envelope_id` as soon as its loop reads it, before the delivery, and delivers each message event through `lane-mail send --delivery-id` or `lane-mail resolve --delivery-id`, as before. The `conversations.history` poll loop is deleted. The relay still polls each checkout's mailbox every `SLACK_POLL_SECONDS`, for posts and receipt marks.
2. **A history read on every connect.** The first poll after each connect and reconnect reads the channel's history, and the threads whose latest reply moved, and delivers what the connection missed. An event moves no position, so a message whose envelope was lost, or whose delivery a stop cut off after its acknowledgement, lands on the next such read; the delivery id judges any repeat.
3. **One relay per machine, one Slack app per machine.** A relay serves every checkout on its machine from one process and one connection, routing each event by its channel to the bound checkout. Each machine runs its own Slack app: the fleet app on the control VM, a second app for the master home on the operator machine. A slash command registered by two apps goes to the app installed most recently, so commands live on the fleet app alone.
4. **A WebSocket client in the package.** `skills/slack/scripts/lib/websocket.py` holds the opening handshake, text frames, ping and pong, and close; the package stays on the Python standard library.

## Rationale

- An event arrives the moment Slack has it; a poll waits up to its interval.
- The per-minute history and replies reads of every relay are gone, so `SLACK_POLL_SECONDS` no longer spends Slack's call allowance; the history read runs once per connection.
- Each envelope is acknowledged as soon as the loop reads it, before its delivery, so a download never delays its own envelope's acknowledgement. The loop is one thread: an envelope that waits behind other work past Slack's three seconds is sent again, and the journal skips the repeat by its stamp. The history read of the next connect covers a stop between the acknowledgement and the delivery.
- One connection per app is the one topology in which every event reaches the relay that can write its mailbox.
- Socket Mode needs a small part of RFC 6455. One module of about 230 lines on the standard library costs less than a dependency and a package manager on the control VM and in a catalog that ships standard-library scripts.

## Alternatives Considered

| Alternative | Why rejected |
|-------------|--------------|
| Keep polling with a shorter `SLACK_POLL_SECONDS` | Still a wait, and the history and replies allowance is shared by every relay of one app |
| One connection per checkout on a shared app | Slack sends each event to one open connection, so a checkout's relay would receive another checkout's messages and could not write that mailbox |
| The `websocket-client` package or the Slack SDK | A dependency and a package manager on the control VM, for handshake and framing the package holds in one small module |
| The Events API over HTTP | A public URL and a server on the control VM |
| Acknowledge after delivery | A file download can outlast Slack's three-second window, and Slack then sends the envelope again; the history read already covers a stop before delivery |

## Impact

- A relay needs a second secret, `SLACK_APP_TOKEN`, and the Slack app needs Socket Mode on and the `message.groups` bot event; the package README names both.
- A reply under a notice younger than `SLACK_THREAD_DAYS` arrives at once, not within ten polls; `listen --status` shows the connection state and no longer prints a call budget.
- A second relay on one app takes part of the first relay's events. Those messages land only at the first relay's next reconnect.

**Revisit When**: Slack retires Socket Mode or the `message.groups` event; one machine needs more relays than one app serves; or the catalog admits a dependency manager.

**Verification**: `skills/slack/tests/socket.test.sh`: an owner message lands from its event; every envelope is acknowledged, with a control that drops the acknowledgement; an envelope lost with its connection lands through the reconnect's history read, with a control that skips that read.

**References**: [D009](D009-slack-relay.md), KEN-2082, KEN-2099
