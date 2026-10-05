# slack

A relay between an overseer's mailbox and one private Slack channel. Session owners steer the overseer from Slack and read its questions, rulings and reports.

## Install

```bash
kendex add vanillagreencom/kendex --skill slack
```

Requires Python 3.8+ and the orch skill, which the install adds.

## Features

- Create or adopt one private channel per checkout and invite its owners by email.
- Post an overseer's question to the channel with an @mention, and record every reply in its open thread as an answer.
- Deliver any other owner message to the overseer as a directive, including a live reply in any thread at any age, with small parent context.
- Read a requested thread as plain text with `slack thread`, without loading channel history.
- Send a text reply only to its thread with `slack post --thread TS`.
- Post the overseer's notices and rulings, and upload its progress reports with the notice as the comment.
- Post an alert or a file to any channel from a script, with `--mention` for the owners.
- Send text as standard Markdown and file comments as Slack's mrkdwn markup. [Message standard](SKILL.md#message-standard) defines the difference.
- Refuse any text or file that matches the secret-value pattern.

## How it works

- `slack setup` resolves each owner's email address to a Slack user, creates the private channel or finds it by name, invites the owners and writes the binding under `tmp/slack/` in the checkout.
- `slack listen --root A --root B` is one process for every checkout on one machine. Slack sends each owner message over its one Socket Mode connection as it is posted, and the relay routes it by channel to the bound checkout.
- On reconnect, history resumes from saved positions and checks retained active threads. The relay opens a dropped connection again. API and mailbox waits do not block acknowledgements.
- Every `SLACK_POLL_SECONDS` the relay reads each checkout's mailbox for posts and receipt marks.
- An owner's message reaches the overseer through the checkout's `lane-mail`, keyed by the Slack message id, so the relay never carries a message twice.
- Owner text arrives as plain text. Slack links, mentions, channel names and dates expand; emoji stay `:name:`.
- Owner files go to `tmp/slack/files/`, readable only by the checkout's user. The overseer receives the text and each saved path, or `file <id> not fetched: <why>`. A failed download never holds the message back.
- Each delivered owner message gets an :eyes: reaction. Once the overseer's mailbox read passes a directive, the relay swaps its mark for :white_check_mark:. Neither mark posts text. Refused marks retry next poll.
- The relay posts new owner-bound mailbox envelopes: questions with choices, recommendations, deadlines and drafts, threaded notices, and uploaded reports. It skips envelopes older than `SLACK_THREAD_DAYS`.
- Posts get an `inflight` record before sending. After a stop or lost response, they stay `unknown` in `listen --status`, never repeated. Explicit refusals retry after a token fix if needed.
- Catch-up reads active threads under old parents. Temporary refusals retry next poll. `thread-read-failed` names the thread and envelope; other threads and posts continue. Deleted questions close in the relay, not the mailbox. Later answers and referenced notices go to the channel. [Journal](schemas/journal.md) defines the records.
- The relay's first run reads Slack from the moment of the binding and the mailbox from its newest envelope, so neither side's past is replayed. Open questions are posted whatever their age inside `SLACK_THREAD_DAYS`.
- A master session can hold a root's mailbox posts. Owner messages and relay replies still pass. [The master hold](#the-master-hold) defines the hold and resume.
- The relay compacts its journal daily. Run `slack compact` only while the relay is stopped.
- A package update restarts the relay in place once its files hold for two polls. A changed setting still needs `slack setup`.

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

The app must be a member of every channel it posts to. `setup` creates or adopts a channel the app is in; for an alert channel, invite the app in Slack.

## Setup

1. Set `KENDEX_USER_EMAIL` in the private env file if unset; `SLACK_OWNERS` defaults to it.
2. Put `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN` in the private env file.
3. Run `slack setup` in the checkout. It prints `slack: bound=CHANNEL_ID root=... name=... owners=N`.
4. Run `slack install --root <checkout>` on a host with systemd, or `slack listen --root <checkout>` in a terminal. To add a checkout later, run `slack install` again with every `--root`; it restarts the running relay on the new list.
5. Write in the channel. The overseer's reply lands in the thread.

## The master hold

Each root reads the presence pair from its own settings and private env files, with caller exports taking precedence. An empty or absent `SLACK_MASTER_FILE` means no hold. Relative paths start at that root; `~` expands to the home directory. A stale or missing file ends the hold. `slack listen --status` shows `held-by=master` while held.

The master's watch writes a bare read line count to `<root>/tmp/lane-mail/overseer/to-overseer.seen`. On resume, the relay clamps the count to the mailbox length, skips notices at or below it and journals their ids. Later notices, open asks and held answers still post. A missing or unreadable count skips nothing; hold times do not set the cutoff.

`lane-mail events` supplies `line` (physical position) and `count` (complete line count) for suppression. The oldest supported producer is orch 3.0.0 with its [owner channel](https://github.com/vanillagreencom/kendex/commit/ac62981e). [Position metadata](https://github.com/vanillagreencom/kendex/commit/e9c9497e) enables master-read suppression. Missing or malformed positions still route without that suppression. Each bad field gets an `envelope-field` diagnostic with root and id. Other bad fields skip the envelope. A checkout poll failure names the root; other checkouts still run.

## Steering contract

| Where you write | What happens |
|-----------------|--------------|
| Top-level | The overseer receives it as a directive; :eyes: marks it delivered, :white_check_mark: read |
| In an open question's thread, any reply | The overseer receives your words as an answer to that question, with eyes when they land. The question stays open until the overseer closes it or its deadline passes; a reserved question has no deadline close and stays open until the overseer closes it |
| In any thread, at any age, including "Also send to channel" | The overseer receives it as a directive with small parent context, unless it answers an open question |
| A file, with or without text | The overseer receives the text, then the saved path of each file |
| A message with no text and no file | Not routed; the relay replies once, and once more after its journal is moved aside |
| From anyone not in `SLACK_OWNERS` | Not routed; the relay replies once, then ignores that message until its journal is moved aside, which answers it once more |
| An edit or a deletion | Ignored |

A question answered in the overseer's chat shows in its Slack thread as "Answered in the chat"; one nobody answered by its deadline shows as "No answer by the deadline", with the option that stood. A reserved question, a decision only you can take, has no option that stands. If you have not answered by its deadline, the relay posts it once more in its thread, mentioning you, or in a new thread where its own is gone; a reply there answers it. After changing `SLACK_OWNERS`, run `slack setup` for each bound checkout: a plain restart never invites an added owner, who could then steer a channel they cannot see.

## Credential boundary

- The bot token and the app-level token live in the private env file or the process environment, never in a settings file, the binding, the journal or a post.
- The relay reads and writes one channel per checkout, the one `setup` bound. `setup --take` binds a private channel only, and a relay given two checkouts bound to one channel refuses to start. `post --channel` reaches another channel only from the command line.
- Every text and file leaving the host passes the secret-value pattern the orch skill ships. A match is refused and never sent, and the report stays on disk.
- The binding stores channel and owner identifiers, names and the binding time, not message text. The journal stores delivery identifiers and parent context, including an excerpt of the parent's first 300 characters with newlines collapsed.
- Owner files stay in `tmp/slack/files/` until the checkout's user removes them.
- Anyone in the channel reads what the overseer posts. Only the owners steer.

## Settings

Settings go in the project's `kendex.settings.toml` under `[env]` and the tokens in its private env file. Nothing is required, so an arrival writes nothing; [kendex.settings.toml.example](kendex.settings.toml.example) comments each key.

Other Slack settings are process-wide and use the launch checkout, the first `--root` for an installed unit. Caller exports take precedence.

| Variable | Purpose | Default |
|----------|---------|---------|
| `SLACK_BOT_TOKEN` | The bot token of the Slack app; private env file or process environment only | unset: Slack is off |
| `SLACK_APP_TOKEN` | The app-level token (`connections:write`) that opens the relay's Socket Mode connection; private env file or process environment only | unset: `listen` refuses, and so does `setup` while the unit `install` wrote stands |
| `SLACK_OWNERS` | Comma-separated email addresses of those whose messages steer | `KENDEX_USER_EMAIL` |
| `SLACK_POLL_SECONDS` | Seconds between two reads of each mailbox for posts and receipt marks | `15` |
| `SLACK_THREAD_DAYS` | Journal retention and reconnect lookback in days; live replies have no age limit | `7` |
| `SLACK_MASTER_FILE` | Per root: the master's presence file; while fresh it holds that root's mailbox posts | empty: no hold |
| `SLACK_MASTER_MAX_AGE` | Per root: seconds after the file's last touch that it still holds posts | `600` |

## Proof

The [suites](https://github.com/vanillagreencom/kendex/tree/main/skills/slack/tests) use a fake Slack API and the real `lane-mail`. [Live proof](https://github.com/vanillagreencom/kendex/blob/main/skills/slack/DEVELOPMENT.md#live-proof) covers checks that need the owner's Slack app and channel.
