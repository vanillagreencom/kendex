# slack

A relay between an overseer's mailbox and one private Slack channel. Session owners steer the overseer from Slack and read its questions, rulings and reports.

## Features

- Create or adopt one private channel per checkout and invite its owners by email.
- Answer the overseer's questions in their Slack threads.
- Send other owner messages and files to the overseer, including live replies in old threads.
- Read a requested thread as plain text and send a reply only to its thread.
- Receive the overseer's notices, rulings and progress reports.
- Post an alert or related files together to another channel from a script.
- Refuse outgoing text or files that match the secret-value pattern.
- Optionally use `/lanes`, `/asks`, `/report` and the app's Home tab.

## Install

```bash
kendex add vanillagreencom/kendex --skill slack
```

## How it works

The relay connects each checkout's overseer to its private channel. Owners write in Slack; the overseer receives their words and files in its mailbox. Questions, replies and reports return to the channel.

Socket Mode reconnects after a dropped connection. Recovery reads saved positions and retained active threads. `SLACK_THREAD_DAYS` bounds reconnect history; live replies have no thread-age limit. Queue mode receives messages from a hosted receiver and reads no channel history. The hosted receiver owns retries. A first run starts at the newest mailbox message, so it does not replay old posts. Open questions within the history limit still post.

Posts whose response was lost are not repeated. Explicit refusals can retry after their cause is fixed. Use `slack listen --status` for a failed connection, binding or post and its repair. A temporary thread-read failure leaves other threads and posts running. [The relay's record](schemas/journal.md) defines delivery, recovery and status details.

## Setup

Requires Python 3.8 or newer. Installation adds the required skills, including orch.

Settings go in the project's `kendex.settings.toml` under `[env]`. Tokens go in its private env file or process environment. Installation writes no required settings. [kendex.settings.toml.example](kendex.settings.toml.example) describes the keys; `slack --help` gives commands, defaults and diagnostics.

Set `SLACK_OWNERS` to the owners' comma-separated email addresses, or use `KENDEX_USER_EMAIL` for one owner. Set `KENDEX_USER_HANDLE` for the person in the default channel name; otherwise setup uses that email's local part. Setup keeps an existing channel binding and purpose. Use `--name` to choose a name or `--take` to adopt a private channel the app has joined.

Run `slack setup` for each checkout, then serve the checkouts with one relay. Two checkouts cannot share one bound channel. After changing `SLACK_OWNERS`, run setup for each bound checkout: a plain restart does not invite an added owner. Restart after changing tokens or other process-wide settings. Package updates reload the running relay in place; they do not replace this configuration step.

Process-wide settings use the launch checkout, the first `--root` for an installed unit. Caller exports take precedence. The [Jarvis presence settings](#the-jarvis-session-hold) are per checkout and reload without a restart. Run `slack compact` only while the relay is stopped.

### Slack app

Use one Slack app per machine for Socket Mode, the standard mode when you have no hosted receiver. Create it from [this manifest](app-manifest.yaml) and install it to the workspace. Put its bot token in the private env file as `SLACK_BOT_TOKEN`. Under Basic Information, create an app-level token with `connections:write` and save it as `SLACK_APP_TOKEN` in the same file.

For a hosted receiver, use one app per workspace and set `SLACK_INBOUND=queue` before setup and listen. The receiver's worker calls `slack deliver --root ROOT` for each message. Queue mode needs the bot token alone. Disable Socket Mode on the hosted app and configure HTTP delivery; the manifest describes the Socket Mode app. Each mode is explicit and never falls back to the other. Switching modes keeps the existing binding and journal.

For an existing app, add the manifest's missing OAuth scopes, subscribe to `message.groups` under Event Subscriptions, then reinstall it. Enable Socket Mode only for a Socket Mode app. The app must join every channel it posts to. Invite it to any separate alert channel. Missing `files:read` prevents owner-file downloads; the delivered message explains that failure.

### Token rotation

1. Revoke the old token in the Slack app's settings.
2. Reinstall the app to the workspace. A person completes Slack's sudo step if shown.
3. Save the replacement token in the private env file and restart the relay.
4. Re-add the bot to each private channel it serves.

## Steering contract

Only `SLACK_OWNERS` steer. Anyone in the channel can read what the overseer posts.

| Where you write | What happens |
|---|---|
| Top-level | The overseer receives a directive. |
| In an open question's thread | Every reply is an answer to that question. |
| In any other thread, at any age, including “Also send to channel” | The overseer receives a directive with the thread context it has not received. [Parent pointers](schemas/journal.md#parent-pointers) define that context. |
| A file, with or without text | The overseer receives the text and each saved file path, or the reason a file could not be fetched. A failed file download does not hold back the message. |
| No text and no file, or a message from a nonowner | The message is not routed. The relay replies once to that message; moving its journal aside allows that reply again. |
| An edit or deletion | Ignored. |

An :eyes: reaction means delivered; :white_check_mark: means read. These marks post no text. Refused marks retry on the next poll. Owner text reaches the overseer as plain text: Slack links, mentions, channel names and dates expand; emoji stay `:name:`.

A tracker-posted question shows an @mention, its first line, item link and deadline if present; its detail stays on the item. Other questions include the complete question and @mention, with their choices, recommendation, deadline and draft where supplied.

The overseer records its ruling and closes the question. A reserved question waits for your decision; no option stands by default. [Owner asks](../orch/references/communication-modes.md#owner-asks) defines question closure and deadline handling.

A request forwarded by a satellite's Jarvis appears as a new channel message naming the computer, with the request time in your time zone, how forwarding was confirmed and the request's words. The overseer's notices follow in that thread. The confirmation does not prove who asked: reply in that thread if the request is not yours. The overseer judges the confirmation words in its mailbox, where the references stay. If the root post is refused before sending or its response is lost, notices can appear top-level. The relay does not turn an ambiguous send into a repeated post.

Send text and file comments as standard Markdown; the package converts a file comment to Slack's mrkdwn. [Message standard](SKILL.md#message-standard) explains the difference. Use `slack thread` for an explicit thread read and `slack post --thread TS` for a reply confined to that thread.

Repeat `--file` on one `slack post` to share related files with one comment: `slack post --thread TS --file A --file B --text T`. A rejected file or failed upload shares no partial group. Slack's recipient settings decide notifications.

## Slash commands and the Home tab

These are optional and available only to `SLACK_OWNERS`. An empty command setting leaves that command off; an empty `SLACK_HOME_COMMAND` leaves Home off.

- `/lanes` shows `SLACK_STATUS_COMMAND` output and `/asks` shows `SLACK_ASKS_COMMAND` output. Only the owner who typed the command sees the reply. Neither writes a mailbox nor takes an agent turn.
- `/report` requests a report from the overseer at `SLACK_REPORT_ROOT`, which must be one of the served checkouts. Its reply names the checkout and request id. With no recorded overseer, it writes nothing.
- Home shows `SLACK_HOME_COMMAND` output when an owner opens the tab. It does not refresh on a timer. A failed command shows its cause instead of its output. Home that Slack has not enabled stays off until a restart.

Only configured command lines run. Failed commands show their cause without their output; unknown commands do not run. A command lost after acknowledgement is not recovered: type it again. `/report` avoids duplicate delivery only when Slack resends the same request id; stable ids on resends are an assumption, not a guarantee from Slack.

Oversized command output can be cut or withheld in full. The reply names the cut or refusal. A failed command names its cause; a killed command reports its signal without claiming an OOM cause or victim. See `slack --help` for bounds and diagnostics, [the journal schema](schemas/journal.md) for relay records, and this package's `DEVELOPMENT.md` for maintainer details.

To enable them on an app:

1. Add the bot scope `commands` under OAuth & Permissions.
2. Register each enabled command under Slash Commands: `/lanes`, `/asks`, `/report`. Socket Mode needs no request URL.
3. For Home, enable the Home tab under App Home and subscribe to `app_home_opened` under Event Subscriptions.
4. Reinstall the app to the workspace.

Register `/lanes` for status output. Slack reserves `/status`; the relay accepts the retired name until kendex 2.0.0 and warns with its replacement. If two apps register the same command name in one workspace, Slack uses the most recently installed app.

A notice that answers the `/report` request with `lane-mail notice --ref` reaches the channel even during a Jarvis session hold. An ordinary `oversee-report write` notice has no request reference: it is held, skipped on resume if the session read it, and not sent during `ORCH_REPORT_QUIET_HOURS`.

## The Jarvis session hold

The relay pages an unread owner message from Jarvis's delivered `owner-unread` event in this root's mailbox. It waits for the session hold to end and checks the original message's read receipt before sending. A read message produces no page, even if it remains unanswered. A definite send refusal stays eligible for retry; an accepted page or an unknown send is not repeated. An unavailable relay cannot deliver a page, and a stopped producer emits no new event. Recovery handles retained events within the relay's existing history limit. [Journal lines](schemas/journal.md#journal-lines) define the event and receipt requirements and the limits of the send-time check.

Set `SLACK_JARVIS_SESSION_FILE` to the file the session keeps fresh and `SLACK_JARVIS_SESSION_MAX_AGE` to its freshness limit. Relative paths start at that checkout; `~` expands to the home directory. While held, ordinary mailbox posts wait and `--mention` posts without mentions, with a `mention-held` diagnostic. `slack listen --status` shows `held-by=jarvis`.

Owner messages still reach the overseer. Replies to messages the owner typed in Slack still post in their threads. A notice answering `/report` posts as a new channel message; a notice answering a forwarded request posts under its root, creating that root when needed.

Presence setting changes take effect at the next poll without a restart. Emptying or removing the file setting ends the hold. A stale or missing presence file also ends it, except that a running relay retains a renamed file's hold until the replacement is fresh or the retained file is stale. A failed settings read keeps that checkout's hold and fails its post step; other checkouts continue. The retired presence keys stay readable until kendex 2.0.0 with a `setting-renamed` warning; an explicitly set new key takes precedence, including an empty value.

The Jarvis session marks its view read with `lane-mail events --item overseer --box to-overseer --mark-read`. On resume, ordinary notices and questions the session marked read are skipped without a post or mention, including closed questions. Replies to Slack-origin messages, `/report` and forwarded requests still post. Later notices/questions and held answers continue to post. A missing, unreadable or invalid read marker skips nothing; hold times do not decide which messages were read.

The oldest supported mailbox producer is orch 3.0.0. Producers without usable position metadata still route, but cannot supply Jarvis-read suppression or position-based answer read marks. Bad position fields produce `envelope-field` diagnostics; other invalid fields skip that message. A checkout poll failure names the checkout while the others continue. The [journal schema](schemas/journal.md) and `slack --help` own the record and diagnostic details.

## Credential boundary

- Bot and app-level tokens belong only in the private env file or process environment, never in settings, bindings, journals or posts.
- The relay serves the bound private channel for each checkout. `post --channel` reaches another channel only through an explicit command.
- Outgoing text and files pass the orch secret-value pattern. A match refuses the send and leaves a report on disk.
- The binding stores channel/owner identifiers, names and binding time. The journal stores delivery identifiers and bounded parent excerpts; see [The relay's record](schemas/journal.md).
- Owner files stay in `tmp/slack/files/`, readable only by the checkout's user, until that user removes them.

## Proof

The [suites](https://github.com/vanillagreencom/kendex/tree/main/skills/slack/tests) use a fake Slack API and the real `lane-mail`. [Live proof](https://github.com/vanillagreencom/kendex/blob/main/skills/slack/DEVELOPMENT.md#live-proof) lists checks that need the owner's Slack app and channel; those checks remain pending there.

## Licence

MIT, in the repository's LICENSE file.
