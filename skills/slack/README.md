# slack

A relay between an overseer's mailbox and one private Slack channel. The people who own a kendex overseer session use it to steer that session from Slack and to read its questions, rulings and reports there.

## Install

```bash
kendex add vanillagreencom/kendex --skill slack
```

Requires Python 3.8 or newer and the orch skill, which the install adds as a dependency.

## Features

- Create or adopt one private channel per checkout and invite its owners by email address.
- Post an overseer's question to the channel with an @mention, and record the first reply in its thread as the answer.
- Deliver any other owner message to the overseer as a directive.
- Save the files an owner sends under `tmp/slack/files/` and name each saved path in the directive.
- Mark each directive's message with :eyes: once it reaches the overseer's mailbox, and with :white_check_mark: once the overseer has read it.
- Post the overseer's notices and rulings, and upload its progress reports with the notice as the comment.
- Post an alert or a file to any channel from a script, with `--mention` for the owners.
- Send a text posted alone as standard Markdown, so bold, lists, headings, links and code blocks render; a file's comment renders as Slack's mrkdwn markup. Which post is which: [SKILL.md § Message standard](SKILL.md#message-standard).
- Refuse any text or file that matches the secret-value pattern.
- Run as a systemd user unit, and report its health in one line per checkout.

## How it works

- `slack setup` resolves each owner's email address to a Slack user, creates the private channel or finds it by name, invites the owners and writes the binding under `tmp/slack/` in the checkout.
- `slack listen --root A --root B` is one process for one person. Every `SLACK_POLL_SECONDS` it reads each channel's new messages, the thread of every open question, and every tenth poll the other threads younger than `SLACK_THREAD_DAYS`.
- An owner's message reaches the overseer through the checkout's `lane-mail`, keyed by the Slack message id, so a message the relay carried once is never carried twice.
- An owner's text reaches the overseer as typed. Slack's escapes read back as `&`, `<` and `>`; a link as `label (URL)`, or the URL alone; a mention as `@name`, or `@<user id>` when Slack will not name the user; a channel as `#name`, or `#<channel id>` when Slack sends no name; `<!here>` as `@here`; a user group as its label, or `@subteam` with none; a date as its fallback text. Emoji stay `:name:`.
- Each file on an owner's message is downloaded with the bot token to `tmp/slack/files/<file id>-<name>` in the checkout, the directory mode 700 and the file mode 600. The message reaches the overseer with one line per file after its text: the saved path, or `file <id> not fetched: <why>`, such as `HTTP 403` or a download cut short. `<file id>-<name>` is cut to its first 200 characters. A download that fails never holds the message back.
- A directive's message gets an :eyes: reaction in the poll that delivers it. Once the overseer's mailbox read passes that directive, the relay swaps it for :white_check_mark:. Neither mark posts a message. A mark Slack refuses is printed and delivery goes on; a refused mark or swap, a mark a relay stop cut off, or the relay's check of what the overseer has read that `lane-mail` refuses, is made again on the next poll.
- The mailbox's new envelopes for the owner are posted to the channel: a question with its options, recommendation and deadline, a notice in the thread of the message it answers, a report as an uploaded file. An envelope older than `SLACK_THREAD_DAYS` is never posted.
- The relay's first run reads Slack from the moment of the binding and the mailbox from its newest envelope, so neither side's past is replayed. Open questions are posted whatever their age inside `SLACK_THREAD_DAYS`.
- While `SLACK_MASTER_FILE` is younger than `SLACK_MASTER_MAX_AGE`, a master session answers the overseer and the relay posts no questions, notices, reports or answers from the mailbox; owner messages in the channel still reach the overseer, the relay's replies to them still post, and `slack listen --status` shows `held-by=master`. When the file goes stale or is gone, the relay posts the questions still open and the answer to a question the channel shows open. A notice stamped after the second of the file mtime the relay first read and before the second the hold ended, `SLACK_MASTER_MAX_AGE` past the last touch or the last poll that found a removed file fresh, never posts; any other notice posts, so one the master already saw can.
- `slack compact` drops journal lines older than `SLACK_THREAD_DAYS` once they are resolved. A directive not yet marked :white_check_mark: keeps its lines whatever its age, so one whose :eyes: mark Slack refused still gets it on a later poll, and every directive still gets :white_check_mark: once read. The relay runs it once a day, so the verb is refused `relay-running` while the relay runs on that checkout.
- `slack install` writes the systemd user unit that runs the relay over the roots you name.

## Slack app

Create one Slack app from this manifest, install it to the workspace, and copy its bot token into the project's private env file as `SLACK_BOT_TOKEN`.

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
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
```

| Scope | What the relay does with it |
|-------|-----------------------------|
| `chat:write` | Post messages and edit one it posted |
| `files:read` | Download a file an owner sends. Without it Slack answers with its sign-in page, and the relay delivers `file <id> not fetched: HTTP 200 sign-in page, the app needs files:read` |
| `files:write` | Upload a report |
| `groups:history` | Read a private channel and its threads |
| `groups:read` | Find a private channel by name or id |
| `groups:write` | Create a private channel and invite the owners |
| `reactions:write` | Mark a directive's message as delivered and as read |
| `users:read`, `users:read.email` | Resolve an owner's email address to a user, and name a user an owner mentions |

An app made from an earlier copy of this manifest lacks the scopes added since. Add each missing scope under the app's OAuth settings and reinstall the app to the workspace.

The app must be a member of every channel it posts to. `setup` creates the channel with the app in it, or invites the owners to one the app already belongs to; for an alert channel, invite the app in Slack.

## Setup

1. Set `KENDEX_USER_EMAIL` in the private env file if it is not set; `SLACK_OWNERS` defaults to it.
2. Put `SLACK_BOT_TOKEN` in the private env file.
3. Run `slack setup` in the checkout. It prints `slack: bound=CHANNEL_ID root=... name=... owners=N`.
4. Run `slack install --root <checkout>` on a host with systemd, or `slack listen --root <checkout>` in a terminal. To add a checkout later, run `slack install` again with every `--root`; it restarts the running relay on the new list.
5. Write in the channel. The overseer's reply lands in the thread.

## The local run

A workstation runs the relay by hand:

```bash
.agents/skills/slack/scripts/slack listen --root "$PWD"
```

The relay prints `slack: listening=1 poll_seconds=15` and polls until it is stopped. `--once` polls each root one time and exits, which is the form a test uses; the doctor reads `listen --status`, which polls nothing. A second relay on the same checkout is refused `relay-running`.

## Steering contract

What an owner's message in the channel does:

| Where you write | What happens |
|-----------------|--------------|
| Top-level | The overseer receives it as a directive; :eyes: marks it delivered, :white_check_mark: read |
| In a question's thread, first reply | Your words are the answer; the relay replies "Recorded as your answer" |
| In a question's thread, later reply | The overseer receives it as a directive; the relay says the question was already answered |
| In the thread of a notice or report younger than `SLACK_THREAD_DAYS` | The overseer receives it as a directive, within ten polls |
| In a thread older than `SLACK_THREAD_DAYS` | Not routed. Write top-level |
| A file, with or without text | The overseer receives the text, then the saved path of each file |
| A message with no text and no file | Not routed; the relay replies once, and once more after its journal is moved aside |
| From anyone not in `SLACK_OWNERS` | Not routed; the relay replies once, then ignores that message until its journal is moved aside, which answers it once more |
| An edit, a deletion or a thread broadcast | Ignored |

A question answered in the overseer's chat shows in its Slack thread as "Answered in the chat"; one nobody answered by its deadline shows as "No answer by the deadline", with the option that stood. After changing `SLACK_OWNERS`, run `slack setup` for each bound checkout: it invites an added owner to the channel and restarts the unit `install` wrote. A plain restart drops a removed owner but never invites an added one, who could then steer a channel they cannot see.

## Credential boundary

- The bot token lives in the private env file or the process environment, never in a settings file, the binding, the journal or a post.
- The relay reads and writes one channel per checkout, the one `setup` bound. `setup --take` binds a private channel only, and a relay given two checkouts bound to one channel refuses to start. `post --channel` reaches another channel only from the command line.
- Every text and every file leaving the host passes the secret-value pattern the orch skill ships. A match is refused and never sent, and the report stays on disk.
- The journal and the binding hold identifiers only: channel ids, message stamps, user ids, envelope ids and file ids. No message body is copied.
- A file an owner sends is kept under `tmp/slack/files/`, readable by the checkout's user alone. Nothing removes it but that user.
- Anyone in the channel reads what the overseer posts. Only the owners steer.

## Settings

Settings go in the project's `kendex.settings.toml` under `[env]` and the token in its private env file. Nothing is required, so the install writes nothing; [kendex.settings.toml.example](kendex.settings.toml.example) comments each key.

| Variable | Purpose | Default |
|----------|---------|---------|
| `SLACK_BOT_TOKEN` | The bot token of the Slack app; private env file or process environment only | unset: Slack is off |
| `SLACK_OWNERS` | Comma-separated email addresses of the people whose messages steer | `KENDEX_USER_EMAIL` |
| `SLACK_POLL_SECONDS` | Seconds between two reads of each channel | `15` |
| `SLACK_THREAD_DAYS` | Days a thread stays open for replies | `7` |
| `SLACK_MASTER_FILE` | A file a master session touches while it answers the overseer; while it is fresh the relay posts nothing from the mailbox | empty: no hold |
| `SLACK_MASTER_MAX_AGE` | Seconds after its last touch that `SLACK_MASTER_FILE` still holds the relay | `600` |

Slack's call allowance is shared by every relay of one app. A relay's calls per minute are `channels × (1 + open questions) × 60 / SLACK_POLL_SECONDS` plus the tenth-poll thread reads; `slack listen --status` prints the figure per root and the sum.

## Proof

The suites under `tests/` prove the package's behaviour against a fake Slack API and the real `lane-mail`. The rows that need the owner's Slack app and channel, each with the command that proves it, are listed in [DEVELOPMENT.md § Live proof](DEVELOPMENT.md#live-proof).
