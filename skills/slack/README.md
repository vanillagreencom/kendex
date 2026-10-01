# slack

A relay between an overseer's mailbox and one private Slack channel. The owners of a kendex overseer session use it to steer that session from Slack and read its questions, rulings and reports there.

## Install

```bash
kendex add vanillagreencom/kendex --skill slack
```

Requires Python 3.8+ and the orch skill, which the install adds.

## Features

- Create or adopt one private channel per checkout and invite its owners by email.
- Post an overseer's question to the channel with an @mention, and record the first reply in its thread as the answer.
- Deliver any other owner message to the overseer as a directive.
- Save the files an owner sends under `tmp/slack/files/` and name each saved path in the directive.
- Mark each directive's message with :eyes: once it reaches the overseer's mailbox, and :white_check_mark: once the overseer reads it.
- Post the overseer's notices and rulings, and upload its progress reports with the notice as the comment.
- Post an alert or a file to any channel from a script, with `--mention` for the owners.
- Send text as standard Markdown and file comments as Slack's mrkdwn markup. [Message standard](SKILL.md#message-standard) defines the difference.
- Refuse any text or file that matches the secret-value pattern.
- Run as a systemd user unit and report its health in one line per checkout.

## How it works

- `slack setup` resolves each owner's email address to a Slack user, creates the private channel or finds it by name, invites the owners and writes the binding under `tmp/slack/` in the checkout.
- `slack listen --root A --root B` is one process for every checkout on one machine. Slack sends each owner message over its one Socket Mode connection as it is posted, and the relay routes it by channel to the bound checkout.
- Each time the connection opens, the relay reads each channel's history, so a message sent while it was stopped or disconnected still lands. A dropped connection is opened again at once.
- Every `SLACK_POLL_SECONDS` the relay reads each checkout's mailbox for posts and receipt marks.
- An owner's message reaches the overseer through the checkout's `lane-mail`, keyed by the Slack message id, so the relay never carries a message twice.
- An owner's text reaches the overseer as typed: Slack's escapes, links, mentions, channel names and dates read back as plain text, and emoji stay `:name:`.
- Each file on an owner's message is downloaded with the bot token to `tmp/slack/files/<file id>-<name>` in the checkout, directory mode 700, file mode 600. The message reaches the overseer with one line per file after its text: the saved path, or `file <id> not fetched: <why>`, such as `HTTP 403` or a download cut short. A failed download never holds the message back.
- A directive's message gets an :eyes: reaction as it is delivered. Once the overseer's mailbox read passes that directive, the relay swaps it for :white_check_mark:. Neither mark posts a message. A mark Slack refuses is made again on the next poll.
- The relay posts new owner-bound mailbox envelopes: questions with choices, recommendations and deadlines, threaded notices, and uploaded reports. It skips envelopes older than `SLACK_THREAD_DAYS`.
- The relay's first run reads Slack from the moment of the binding and the mailbox from its newest envelope, so neither side's past is replayed. Open questions are posted whatever their age inside `SLACK_THREAD_DAYS`.
- While `SLACK_MASTER_FILE` is younger than `SLACK_MASTER_MAX_AGE`, a master session answers the overseer and the relay posts no questions, notices, reports or answers from the mailbox; owner messages in the channel still reach the overseer, the relay's replies to them still post, and `slack listen --status` shows `held-by=master`. When the file goes stale or is gone, the relay resumes. [The master hold](#the-master-hold) defines which envelopes post.
- `slack compact` drops journal lines older than `SLACK_THREAD_DAYS` once resolved. The relay runs it once a day, so the verb is refused `relay-running` while the relay runs on that checkout.
- `slack install` writes the systemd user unit that runs the relay over the roots you name.

## Slack app

Create one Slack app per machine from this manifest and install it to the workspace. Copy its bot token into the project's private env file as `SLACK_BOT_TOKEN`. Under the app's Basic Information, create an app-level token with the `connections:write` scope and copy it into the same file as `SLACK_APP_TOKEN`.

```yaml
display_information:
  name: kendex
  description: Relays a kendex overseer's mailbox to a private channel
features:
  bot_user:
    display_name: kendex
    always_online: false
oauth_config:
  scopes:
    bot:
      - chat:write
      - files:read
      - files:write
      - groups:history
      - groups:read
      - groups:write
      - reactions:write
      - users:read
      - users:read.email
settings:
  event_subscriptions:
    bot_events:
      - message.groups
  org_deploy_enabled: false
  socket_mode_enabled: true
  token_rotation_enabled: false
```

| Scope | What the relay does with it |
|-------|-----------------------------|
| `chat:write` | Post messages and edit one it posted |
| `files:read` | Download a file an owner sends. Without it Slack answers with its sign-in page, and the relay delivers `file <id> not fetched: HTTP 200 sign-in page, the app needs files:read` |
| `files:write` | Upload a report |
| `groups:history` | Read a private channel and its threads, and receive its new messages as the `message.groups` event |
| `groups:read` | Find a private channel by name or id |
| `groups:write` | Create a private channel and invite the owners |
| `reactions:write` | Mark a directive's message as delivered and as read |
| `users:read`, `users:read.email` | Resolve an owner's email to a user, and name a user an owner mentions |

For an existing app, add missing OAuth scopes, enable Socket Mode, subscribe to `message.groups` under Event Subscriptions, then reinstall it to the workspace.

The app must be a member of every channel it posts to. `setup` creates the channel with the app in it, or invites the owners to one the app already belongs to; for an alert channel, invite the app in Slack.

## Setup

1. Set `KENDEX_USER_EMAIL` in the private env file if unset; `SLACK_OWNERS` defaults to it.
2. Put `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN` in the private env file.
3. Run `slack setup` in the checkout. It prints `slack: bound=CHANNEL_ID root=... name=... owners=N`.
4. Run `slack install --root <checkout>` on a host with systemd, or `slack listen --root <checkout>` in a terminal. To add a checkout later, run `slack install` again with every `--root`; it restarts the running relay on the new list.
5. Write in the channel. The overseer's reply lands in the thread.

## The master hold

The master's watch writes its read line count to `<root>/tmp/lane-mail/overseer/to-overseer.seen` as a bare integer. The relay reads this file and clamps the count to the mailbox length. On resume, it skips notices at or below the count and journals their ids. Later notices, open asks and held answers still post. A missing or unreadable file skips nothing. Hold times do not set the cutoff.

`lane-mail events`, not the envelope writer, supplies `line` (physical position) and `count` (complete line count). Filtered invalid JSON rows prevent the relay from computing either. The oldest supported producer is orch 3.0.0 with its [owner channel](https://github.com/vanillagreencom/kendex/commit/ac62981e). [Position metadata](https://github.com/vanillagreencom/kendex/commit/e9c9497e) enables master-read suppression. Missing or malformed positions still route without that suppression. Each bad field gets one `envelope-field` journal line with root and id. Other bad fields skip the envelope. A checkout poll failure names the root; other checkouts still run.

## Steering contract

What an owner's message in the channel does:

| Where you write | What happens |
|-----------------|--------------|
| Top-level | The overseer receives it as a directive; :eyes: marks it delivered, :white_check_mark: read |
| In a question's thread, first reply | Your words are the answer; the relay replies "Recorded as your answer" |
| In a question's thread, later reply | The overseer receives it as a directive; the relay says the question was already answered |
| In the thread of a notice or report younger than `SLACK_THREAD_DAYS` | The overseer receives it as a directive |
| In a thread older than `SLACK_THREAD_DAYS` | Not routed. Write top-level |
| A file, with or without text | The overseer receives the text, then the saved path of each file |
| A message with no text and no file | Not routed; the relay replies once, and once more after its journal is moved aside |
| From anyone not in `SLACK_OWNERS` | Not routed; the relay replies once, then ignores that message until its journal is moved aside, which answers it once more |
| An edit, a deletion or a thread broadcast | Ignored |

A question answered in the overseer's chat shows in its Slack thread as "Answered in the chat"; one nobody answered by its deadline shows as "No answer by the deadline", with the option that stood. After changing `SLACK_OWNERS`, run `slack setup` for each bound checkout: it invites an added owner to the channel and restarts the unit `install` wrote. A plain restart drops a removed owner but never invites an added one, who could then steer a channel they cannot see.

## Credential boundary

- The bot token and the app-level token live in the private env file or the process environment, never in a settings file, the binding, the journal or a post.
- The relay reads and writes one channel per checkout, the one `setup` bound. `setup --take` binds a private channel only, and a relay given two checkouts bound to one channel refuses to start. `post --channel` reaches another channel only from the command line.
- Every text and file leaving the host passes the secret-value pattern the orch skill ships. A match is refused and never sent, and the report stays on disk.
- The journal and the binding hold identifiers only: channel ids, message stamps, user ids, envelope ids and file ids. No message body is copied.
- A file an owner sends is kept under `tmp/slack/files/`, readable by the checkout's user alone. Only that user removes it.
- Anyone in the channel reads what the overseer posts. Only the owners steer.

## Settings

Settings go in the project's `kendex.settings.toml` under `[env]` and the tokens in its private env file. Nothing is required, so the install writes nothing; [kendex.settings.toml.example](kendex.settings.toml.example) comments each key.

| Variable | Purpose | Default |
|----------|---------|---------|
| `SLACK_BOT_TOKEN` | The bot token of the Slack app; private env file or process environment only | unset: Slack is off |
| `SLACK_APP_TOKEN` | The app-level token (`connections:write`) that opens the relay's Socket Mode connection; private env file or process environment only | unset: `listen` refuses, and so does `setup` while the unit `install` wrote stands |
| `SLACK_OWNERS` | Comma-separated email addresses of those whose messages steer | `KENDEX_USER_EMAIL` |
| `SLACK_POLL_SECONDS` | Seconds between two reads of each mailbox for posts and receipt marks | `15` |
| `SLACK_THREAD_DAYS` | Days a thread stays open for replies | `7` |
| `SLACK_MASTER_FILE` | A file a master session touches while it answers the overseer; while it is fresh the relay posts nothing from the mailbox | empty: no hold |
| `SLACK_MASTER_MAX_AGE` | Seconds after its last touch that `SLACK_MASTER_FILE` still holds the relay | `600` |

## Proof

The [suites](https://github.com/vanillagreencom/kendex/tree/main/skills/slack/tests) use a fake Slack API and the real `lane-mail`. [Live proof](https://github.com/vanillagreencom/kendex/blob/main/skills/slack/DEVELOPMENT.md#live-proof) covers checks that need the owner's Slack app and channel.
