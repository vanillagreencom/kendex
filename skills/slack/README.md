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
- Post the overseer's notices and rulings, and upload its progress reports with the notice as the comment.
- Post an alert or a file to any channel from a script, with `--mention` for the owners.
- Refuse any text or file that matches the secret-value pattern.
- Run as a systemd user unit, and report its health in one line per checkout.

## How it works

- `slack setup` resolves each owner's email address to a Slack user, creates the private channel or finds it by name, invites the owners and writes the binding under `tmp/slack/` in the checkout.
- `slack listen --root A --root B` is one process for one person. Every `SLACK_POLL_SECONDS` it reads each channel's new messages, the thread of every open question, and every tenth poll the other threads younger than `SLACK_THREAD_DAYS`.
- An owner's message reaches the overseer through the checkout's `lane-mail`, keyed by the Slack message id, so a message the relay carried once is never carried twice.
- The mailbox's new envelopes for the owner are posted to the channel: a question with its options, recommendation and deadline, a notice in the thread of the message it answers, a report as an uploaded file.
- `slack compact` drops journal lines older than `SLACK_THREAD_DAYS` once they are resolved. The relay runs it once a day.
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
      - files:write
      - groups:history
      - groups:read
      - groups:write
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
| `files:write` | Upload a report |
| `groups:history` | Read a private channel and its threads |
| `groups:read` | Find a private channel by name or id |
| `groups:write` | Create a private channel and invite the owners |
| `users:read`, `users:read.email` | Resolve an owner's email address to a user |

The app must be a member of every channel it posts to. `setup` creates the channel with the app in it, or invites the owners to one the app already belongs to; for an alert channel, invite the app in Slack.

## Setup

1. Set `KENDEX_USER_EMAIL` in the private env file if it is not set; `SLACK_OWNERS` defaults to it.
2. Put `SLACK_BOT_TOKEN` in the private env file.
3. Run `slack setup` in the checkout. It prints `slack: bound=CHANNEL_ID root=... name=... owners=N`.
4. Run `slack install --root <checkout>` on a host with systemd, or `slack listen --root <checkout>` in a terminal.
5. Write in the channel. The overseer's reply lands in the thread.

## The local run

A workstation runs the relay by hand:

```bash
.agents/skills/slack/scripts/slack listen --root "$PWD"
```

The relay prints `slack: listening=1 poll_seconds=15` and polls until it is stopped. `--once` polls each root one time and exits, which is the form a test or a doctor probe uses. A second relay on the same checkout is refused `relay-running`.

## Steering contract

What an owner's message in the channel does:

| Where you write | What happens |
|-----------------|--------------|
| Top-level | The overseer receives it as a directive |
| In a question's thread, first reply | Your words are the answer; the relay replies "Recorded as your answer" |
| In a question's thread, later reply | The overseer receives it as a directive; the relay says the question was already answered |
| In the thread of a notice or report younger than `SLACK_THREAD_DAYS` | The overseer receives it as a directive, within ten polls |
| In a thread older than `SLACK_THREAD_DAYS` | Not routed. Write top-level |
| A file with no text | Not routed; the relay replies once |
| From anyone not in `SLACK_OWNERS` | Not routed; the relay replies once, then ignores that message |
| An edit, a deletion or a thread broadcast | Ignored |

A question answered in the overseer's chat shows in its Slack thread as "Answered in the chat"; one nobody answered by its deadline shows as "No answer by the deadline", with the option that stood. Removing an address from `SLACK_OWNERS` takes effect at the relay's next poll.

## Credential boundary

- The bot token lives in the private env file or the process environment, never in a settings file, the binding, the journal or a post.
- The relay reads and writes one channel per checkout, the one `setup` bound. `post --channel` reaches another channel only from the command line.
- Every text and every file leaving the host passes the secret-value pattern the orch skill ships. A match is refused and never sent, and the report stays on disk.
- The journal and the binding hold identifiers only: channel ids, message stamps, user ids, envelope ids and file ids. No message body is copied.
- Anyone in the channel reads what the overseer posts. Only the owners steer.

## Settings

Settings go in the project's `kendex.settings.toml` under `[env]` and the token in its private env file. Nothing is required, so the install writes nothing; [kendex.settings.toml.example](kendex.settings.toml.example) comments each key.

| Variable | Purpose | Default |
|----------|---------|---------|
| `SLACK_BOT_TOKEN` | The bot token of the Slack app; private env file or process environment only | unset: Slack is off |
| `SLACK_OWNERS` | Comma-separated email addresses of the people whose messages steer | `KENDEX_USER_EMAIL` |
| `SLACK_POLL_SECONDS` | Seconds between two reads of each channel | `15` |
| `SLACK_THREAD_DAYS` | Days a thread stays open for replies | `7` |

Slack's call allowance is shared by every relay of one app. A relay's calls per minute are `channels × (1 + open questions) × 60 / SLACK_POLL_SECONDS` plus the tenth-poll thread reads; `slack listen --status` prints the figure per root and the sum.

## Proof

Each row below needs the owner's Slack app and channel. A host with no `SLACK_BOT_TOKEN` cannot run them, so each stands pending with the command that proves it; the suites under `tests/` prove the same behaviour against a fake Slack API and the real `lane-mail`.

| Row | Command | State |
|-----|---------|-------|
| The owner writes in the channel and the overseer's notice lands in that thread within a minute | Write top-level; the overseer answers with `lane-mail notice --item overseer --to owner --ref <ID>`; read the thread | pending |
| An ask with an @mention, the reply as the answer, a second reply as a directive | `lane-mail ask --item overseer --to owner --options a,b --recommend a --file q.txt`; reply twice in the thread; `lane-mail events --item overseer` | pending |
| A second ask answered in the chat shows in the thread | `lane-mail resolve --item overseer --id <ASK> --text a.txt`; read the thread | pending |
| A third ask left unanswered proceeds at the deadline with a notice in the thread | `lane-mail ask ... --wait 1`; wait for the watch; read the thread | pending |
| A report lands with its file | `oversee-report write`; read the channel | pending |
| A forced stall posts one @mention alert to the overseer's channel and the alert channel | `slack post --mention --text "..."` and `slack post --channel <ALERTS> --mention --text "..."` | pending |
| The crash between the mailbox append and the journal mark delivers each note once | kill the relay after a delivery, remove that delivery's `in` line from `tmp/slack/journal.jsonl`, write again, restart; `lane-mail events --item overseer` | pending |
| A second relay on the same checkout is refused | `slack listen --root <checkout> --once` beside the running unit | pending |
| A reply in a thread older than `SLACK_THREAD_DAYS` is not routed | reply under a week-old message; `lane-mail events --item overseer` | pending |
| One answer in chat and one in Slack; a second answer to either is refused and delivered as a directive | `lane-mail resolve ...` then reply in the thread, and the reverse | pending |
| The relay's resident memory under the user slice with three bound checkouts | `systemctl --user status slack-listen.service` after an hour | pending |
| The same on a workstation with a local overseer, token from the private env file | the Setup steps above with `--name kendex-<name>-local` | pending |
| The same for a Codex and a Pi overseer | the Setup steps above in each checkout | pending |
