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

The relay reconnects after a dropped connection: [Reconnects and history](schemas/journal.md#reconnects-and-history) gives what it reads back.

A post whose response was lost is not repeated: [Lost responses](schemas/journal.md#lost-responses) gives which posts retry. Use `slack listen --status` for a failed connection, binding or post and its repair.

## Setup

Requires Python 3.8 or newer. Installation adds the required skills, including orch.

1. Create or update the Slack app and save its tokens, as § Slack app sets out.
2. Set `SLACK_OWNERS` to the owners' comma-separated email addresses, or use `KENDEX_USER_EMAIL` for one owner. Set `KENDEX_USER_HANDLE` for the person in the default channel name; otherwise setup uses that email's local part.
3. Run `slack setup` for each checkout. Use `--name` to choose a name, or `--take` to adopt a private channel the app has joined.
4. Serve the checkouts with one relay: `slack install --root CHECKOUT_A --root CHECKOUT_B`. It also restarts a running relay. On a host without systemd, run `slack listen` with the same roots.

- Settings go in the project's `kendex.settings.toml` under `[env]`.
- Tokens go in its private env file or process environment.
- Installation writes no required settings.
- [kendex.settings.toml.example](kendex.settings.toml.example) describes the keys.
- The command is `.agents/skills/slack/scripts/slack`.
- `slack --help` gives commands, defaults and diagnostics.
- Setup keeps an existing channel binding and purpose.
- Two checkouts cannot share one bound channel.
- After changing `SLACK_OWNERS`, run setup for each bound checkout: a plain restart does not invite an added owner.
- Restart after changing tokens or other process-wide settings.
- Package updates reload the running relay in place; they do not replace this configuration step.
- Process-wide settings use the launch checkout, the first `--root` for an installed unit.
- Caller exports take precedence.
- To hold ordinary posts while a Jarvis session runs, set `SLACK_JARVIS_SESSION_FILE` to the file the session keeps fresh and `SLACK_JARVIS_SESSION_MAX_AGE` to its freshness limit. Relative paths start at that checkout; `~` expands to the home directory. These settings are per checkout and reload without a restart. [The Jarvis session hold](schemas/journal.md#the-jarvis-session-hold) gives what the hold keeps back and what still posts.

### Slack app

Use one Slack app per machine for Socket Mode, the standard mode when you have no hosted receiver:

1. Create it from [this manifest](app-manifest.yaml).
2. Install it to the workspace.
3. Put its bot token in the private env file as `SLACK_BOT_TOKEN`.
4. Under Basic Information, create an app-level token with `connections:write`.
5. Save it as `SLACK_APP_TOKEN` in the same file.

For a hosted receiver, use one app per workspace.

- Set `SLACK_INBOUND=queue` before setup and listen.
- The receiver's worker calls `slack deliver --root ROOT` for each message.
- Queue mode needs the bot token alone.
- Disable Socket Mode on the hosted app.
- Configure HTTP delivery; the manifest describes the Socket Mode app.
- Each mode is explicit and never falls back to the other.
- Switching modes keeps the existing binding and journal.

For an existing app:

1. Add the manifest's missing OAuth scopes.
2. Subscribe to `message.groups` under Event Subscriptions.
3. Reinstall it.

- Enable Socket Mode only for a Socket Mode app.
- The app must join every channel it posts to.
- Invite it to any separate alert channel.
- Missing `files:read` prevents owner-file downloads; the delivered message explains that failure.

### Token rotation

1. Revoke the old token in the Slack app's settings.
2. Reinstall the app to the workspace. A person completes Slack's sudo step if shown.
3. Save the replacement token in the private env file.
4. Restart the relay.
5. Re-add the bot to each private channel it serves.

## Steering contract

Only `SLACK_OWNERS` steer. Anyone in the channel can read what the overseer posts.

| Where you write | What happens |
|---|---|
| Top-level | The overseer receives a directive. |
| In an open question's thread | Every reply is an answer to that question. |
| In any other thread, at any age, including “Also send to channel” | The overseer receives a directive with the thread context it has not received. |
| A file, with or without text | The overseer receives the text and each saved file path, or the reason a file could not be fetched. |
| No text and no file, or a message from a nonowner | The message is not routed. |
| An edit or deletion | Ignored. |

- [Parent pointers](schemas/journal.md#parent-pointers) define the thread context.
- A failed file download does not hold back the message.
- The relay replies once to a message with no text and no file, or from a nonowner; moving its journal aside allows that reply again.

An :eyes: reaction means delivered; :white_check_mark: means read. These marks post no text. Refused marks retry on the next poll. Owner text reaches the overseer as plain text: Slack links, mentions, channel names and dates expand; emoji stay `:name:`.

Slack asks include an @mention and the full question, with any choices, recommendation and draft, when the message fits Slack's limit. Each ask states what happens at its deadline if one is set. If the question also posts to a work item, Slack links to that item and opens a short thread when the full question exceeds the limit.

The overseer records its ruling and closes the question. A reserved question waits for your decision; no option stands by default. [Owner asks](../orch/references/communication-modes.md#owner-asks) defines question closure and deadline handling.

A request forwarded by a satellite's Jarvis appears as a new channel message naming the computer, with the request time in your time zone, how forwarding was confirmed, if the satellite asked, and the request's words. The overseer's notices follow in that thread.

- The confirmation does not prove who asked: reply in that thread if the request is not yours.
- The overseer judges the confirmation words in its mailbox, where the references stay.
- If the root post is refused before sending or its response is lost, notices can appear top-level. The relay does not turn an ambiguous send into a repeated post.

- Send text and file comments as standard Markdown; the package converts a file comment to Slack's mrkdwn. [Message standard](SKILL.md#message-standard) explains the difference.
- Use `slack thread` for an explicit thread read.
- Use `slack post --thread TS` for a reply confined to that thread.

Repeat `--file` on one `slack post` to share related files with one comment: `slack post --thread TS --file A --file B --text T`. A rejected file or failed upload shares no partial group. Slack's recipient settings decide notifications.

## Slash commands and the Home tab

These are optional and available only to `SLACK_OWNERS`. An empty command setting leaves that command off; an empty `SLACK_HOME_COMMAND` leaves Home off.

- `/lanes` shows `SLACK_STATUS_COMMAND` output and `/asks` shows `SLACK_ASKS_COMMAND` output. Only the owner who typed the command sees the reply. Neither writes a mailbox nor takes an agent turn.
- `/report` requests a report from the overseer at `SLACK_REPORT_ROOT`, which must be one of the served checkouts. Its reply names the checkout and request id. With no recorded overseer, it writes nothing.
- Home shows `SLACK_HOME_COMMAND` output when an owner opens the tab. It does not refresh on a timer. A failed command shows its cause instead of its output. Home that Slack has not enabled stays off until a restart.

Only configured command lines run. Failed commands show their cause without their output; unknown commands do not run. A command lost after acknowledgement is not recovered: type it again. [Slash command limits](schemas/journal.md#slash-command-limits) gives duplicate and output limits; `slack --help` gives bounds and diagnostics.

To enable them on an app:

1. Add the bot scope `commands` under OAuth & Permissions.
2. Register each enabled command under Slash Commands: `/lanes`, `/asks`, `/report`. Socket Mode needs no request URL.
3. For Home, enable the Home tab under App Home.
4. For Home, subscribe to `app_home_opened` under Event Subscriptions.
5. Reinstall the app to the workspace.

Register `/lanes` for status output; Slack reserves `/status` ([Retired names](schemas/journal.md#retired-names)). If two apps register the same command name in one workspace, Slack uses the most recently installed app.

A `/report` answer reaches the channel even during a Jarvis session hold; [The Jarvis session hold](schemas/journal.md#the-jarvis-session-hold) gives how other report notices are held.

## Credential boundary

- Bot and app-level tokens belong only in the private env file or process environment, never in settings, bindings, journals or posts.
- The relay serves the bound private channel for each checkout. `post --channel` reaches another channel only through an explicit command.
- Outgoing text and files pass the orch secret-value pattern. A match refuses the send and leaves a report on disk.
- The binding stores channel/owner identifiers, names and binding time. The journal stores delivery identifiers and bounded parent excerpts; see [The relay's record](schemas/journal.md).
- Owner files stay in `tmp/slack/files/`, readable only by the checkout's user, until that user removes them.

## Licence

MIT, in the repository's LICENSE file.
