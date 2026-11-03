# slack

A relay between an overseer's mailbox and one private Slack channel. Session owners steer the overseer from Slack and read its questions, rulings and reports.

## Features

- Create or adopt one private channel per checkout and invite its owners by email.
- Post an overseer's question to the channel and record every reply in its open thread as an answer. After confirmed tracker posting, an ask shows one line: an @mention, `Question from <sender>:`, its first line, the item link and its deadline, if any. Other asks include the complete question and an @mention.
- Deliver any other owner message to the overseer as a directive, including a live reply in any thread at any age. Its parent carries every owner and app thread message this reader generation has not received: [schemas/journal.md § Parent pointers](schemas/journal.md#parent-pointers).
- Read a requested thread as plain text with `slack thread`, without loading channel history.
- Send a text reply only to its thread with `slack post --thread TS`.
- Post the overseer's notices and rulings, and upload its progress reports with the notice as the comment.
- Post an alert or a file to any channel from a script, with `--mention` for the owners. While the root's Jarvis session hold stands, including a presence-file rename, `--mention` posts with no mention and prints one `mention-held` line on stderr.
- Send text as standard Markdown and file comments as Slack's mrkdwn markup. [Message standard](SKILL.md#message-standard) defines the difference.
- Refuse any text or file that matches the secret-value pattern.
- Optionally answer `/lanes`, `/asks` and `/report` with no agent turn, and draw the app's Home tab: [Slash commands and the Home tab](#slash-commands-and-the-home-tab).

## Install

```bash
kendex add vanillagreencom/kendex --skill slack
```

## How it works

- `slack setup` resolves each owner's email address to a Slack user, creates the private channel or finds it by name, invites the owners and writes the binding under `tmp/slack/` in the checkout.
- Without `--name`, the channel is named `<person>-<repo>-<side>`, for example `bradm-kendex-vm`: Slack channel names are unique per workspace, so two people's overseers of one repository, or one person's on the control VM and on a laptop, never share a name. The person is `KENDEX_USER_HANDLE`, else the local part of `KENDEX_USER_EMAIL` with one `handle-from-email` line on stderr, never `SLACK_OWNERS`, which lists who is invited. The repository is the last path segment of `origin`, else the checkout's directory name. The side is `vm` where the orch skill's `lane-host resolve` names a hosted fleet, and `local` where it prints `local` or orch is not installed in the checkout. Past Slack's 80 characters the repository part is shortened, never the person or the side. A checkout already bound keeps its channel under whatever name it has now, so setup never renames or replaces it.
- `setup` writes the channel's purpose where it is empty, on create or on a channel it binds: `<repo> overseer on the control VM.` or `on a local machine.`, the first sentence of the GitHub description (`gh repo view`), `Repo: <origin URL>` and `| Board: https://linear.app/<workspace>/team/<LINEAR_TEAM_PREFIX>` where the checkout sets the prefix and the linear cache names the workspace. A line over Slack's 250 characters drops the sentence, then the board. A purpose already set is never overwritten; a refused write is a `purpose-unset` line on stderr and setup still binds.
- `slack listen --root A --root B` is one process for every checkout on one machine. Slack sends each owner message over its one Socket Mode connection as it is posted, and the relay routes it by channel to the bound checkout.
- On reconnect, history resumes from saved positions and checks retained active threads. The relay opens a dropped connection again. API and mailbox waits do not block acknowledgements.
- Every `SLACK_POLL_SECONDS` the relay reads each checkout's mailbox for posts and receipt marks.
- An owner's message reaches the overseer through the checkout's `lane-mail`, keyed by the Slack message id, so the relay never carries a message twice.
- Owner text arrives as plain text. Slack links, mentions, channel names and dates expand; emoji stay `:name:`.
- Owner files go to `tmp/slack/files/`, readable only by the checkout's user. The overseer receives the text and each saved path, or `file <id> not fetched: <why>`. A failed download never holds the message back.
- Each delivered owner message gets an :eyes: reaction. Once the overseer's mailbox read passes it, the relay swaps its mark for :white_check_mark:. Neither mark posts text. Refused marks retry next poll.
- The relay posts new owner-bound mailbox envelopes: confirmed tracker questions as one line with the @mention, item link and deadline, other questions with choices, recommendations, deadlines and drafts, threaded notices, and uploaded reports. It skips envelopes older than `SLACK_THREAD_DAYS`.
- A request a satellite's Jarvis forwarded with `jarvis-session forward` lands as an owner directive keyed `forward-` and 64 hex digits. Its text ends in one line: `forwarded-request: satellite=NAME request-ref=REF request-at=TIME confirmation-ref=REF confirmed-at=TIME key=KEY confirmation-method=words|voice|physical confirmation-text=WORDS`, where `WORDS` is the owner's words as one JSON string, or `null` for `voice` or `physical`. The first notice that names the directive posts a root at the top of the channel first: `Forwarded from NAME:`, the request, then `Confirmed WORDS at TIME (REF); request REF at TIME.`, with `by voice` or `physically` in place of the words. That notice and every later one post in the root's thread. A root Slack refuses holds the notice for the next poll; a root refused before sending, or whose response was lost, leaves that directive's notices top-level. The relay checks only the line's shape, that `key` is the delivery id, and that `WORDS` is a JSON string for `words` and `null` otherwise; the overseer judges the words. A notice that names any other directive keyed `forward-` does not post.
- Posts get an `inflight` record before sending. After a stop or lost response, they stay `unknown` in `listen --status`, never repeated. Explicit refusals retry after a token fix if needed.
- `slack listen --status` checks each root's `tmp/slack/binding.json`. A missing or unreadable file reports `state=failing` with `cause=binding-missing` or `cause=binding-unreadable`, whatever the recorded connection. Its `fix=slack setup --take CHANNEL --root DIR` line names the recorded channel and root.
- Catch-up reads active threads under old parents. Temporary refusals retry next poll. `thread-read-failed` names the thread and envelope; other threads and posts continue. Deleted questions close in the relay, not the mailbox. Later answers and referenced notices go to the channel. [Journal](schemas/journal.md) defines the records.
- The relay's first run reads Slack from the moment of the binding and the mailbox from its newest envelope, so neither side's past is replayed. Open questions are posted whatever their age inside `SLACK_THREAD_DAYS`.
- A Jarvis session can hold a root's mailbox posts; replies to messages the owner typed in the channel still post in their threads, a notice that names a `/report` directive as a new message, and a notice that names a forwarded directive under its root. Owner messages still reach the overseer. [The Jarvis session hold](#the-jarvis-session-hold) defines the hold and resume.
- The relay compacts its journal daily. Run `slack compact` only while the relay is stopped.
- A package update restarts the relay in place once its files hold for two polls. A changed setting other than the presence pair still needs `slack setup` or a restart.

## Slack app

Create one Slack app per machine from [this manifest](app-manifest.yaml) and install it to the workspace. Copy its bot token into the project's private env file as `SLACK_BOT_TOKEN`. Under the app's Basic Information, create an app-level token with the `connections:write` scope and copy it into the same file as `SLACK_APP_TOKEN`.

| Scope | What the relay does with it |
|-------|-----------------------------|
| `chat:write` | Post messages and edit one it posted |
| `files:read` | Download a file an owner sends. Without it Slack answers with its sign-in page, and the relay delivers `file <id> not fetched: HTTP 200 sign-in page, the app needs files:read` |
| `files:write` | Upload a report |
| `groups:history` | Read a private channel and its threads, and receive its new messages as the `message.groups` event |
| `groups:read` | Find a private channel by name or id |
| `groups:write` | Create a private channel, set its purpose and invite the owners |
| `reactions:write` | Mark an owner message as delivered and as read |
| `users:read`, `users:read.email` | Resolve an owner's email to a user, and name a user an owner mentions |
| `commands` | Optional: receive the slash commands the app registers |

For an existing app, add missing OAuth scopes, enable Socket Mode, subscribe to `message.groups` under Event Subscriptions, then reinstall it to the workspace.

The app must be a member of every channel it posts to. `setup` creates or adopts a channel the app is in; for an alert channel, invite the app in Slack.

### Token rotation

1. Revoke the old token in the Slack app's settings.
2. Reinstall the app to the workspace. If Slack shows its sudo page, the human completes that step.
3. Put the replacement token in the project's private env file and restart the relay.
4. Re-add the bot to each private channel it serves.

## Slash commands and the Home tab

Both are optional. A command whose setting is empty runs nothing and replies that it is off, and with `SLACK_HOME_COMMAND` empty the relay draws no Home tab. Both arrive on the relay's one Socket Mode connection, and the package uses the standard library alone, no Slack SDK or Bolt.

- `/lanes` and `/asks` reply with the output of the command lines `SLACK_STATUS_COMMAND` and `SLACK_ASKS_COMMAND` name. The reply is ephemeral: only the owner who typed the command sees it, in the channel it was typed in. No mailbox is written and no agent takes a turn.
- `/report` writes one directive to the overseer mailbox of `SLACK_REPORT_ROOT`, asking for a progress report now. The reply names that checkout and the directive's id. Where no overseer is recorded there, it says so, and nothing is written. A notice that names the directive, sent with `lane-mail notice --ref`, is a reply: it reaches that root's channel as a new message, even while a Jarvis session hold stands. The report notice `oversee-report write` sends names no directive, so it is an ordinary owner notice: held while a Jarvis session hold stands, skipped on resume once the session read it, and not sent at all during `ORCH_REPORT_QUIET_HOURS`.
- An unknown command replies that the relay does not answer it.
- The relay acknowledges each envelope as it reads it, inside Slack's 3 seconds, and answers on its worker through the command's `response_url`. A command line still running after 10 seconds is stopped, TERM and then KILL to its process group, and its reply names `timeout`. The stop holds the worker for up to 15 seconds more. A reply is cut at 4,000 characters, with a marker.
- Only `SLACK_OWNERS` run commands and see the Home tab. Anyone else who types a command is told so, and nothing runs. The relay publishes no Home tab for anyone else.
- `/report` keys its directive by the command's `trigger_id`, so a payload Slack sends again lands once. Slack's documentation does not state that a resent payload keeps its `trigger_id`; the relay assumes it does, and two distinct ids are two directives. A payload with no usable `trigger_id` is answered as unavailable before any mailbox write. A command acknowledged and then lost to a relay stop is not recovered and never retried under another key: type it again.
- The Home tab shows `SLACK_HOME_COMMAND`'s output as Slack's mrkdwn, cut at 100 sections of 3,000 characters. The relay publishes it with `views.publish` each time an owner opens the tab; nothing polls to keep it fresh. When the command fails, the tab shows the cause in place of the output. With the setting empty, or with Slack answering `not_enabled`, the relay prints one `home-not-enabled` line, leaves Home off until a restart, and keeps running.

Only the settings choose a command line. No field of a Slack payload reaches its arguments, environment or stdin. It runs with no shell, in the directory the relay started in, which is the first `--root` for the unit `install` writes, with the caller's environment and none of the settings the launcher loaded from the checkout's files. Its stdout is the reply or the Home tab, after the secret-value check. Its stderr goes to the relay's log. A failed command's reply or Home tab names the cause, `start`, `timeout`, `exit-N`, `empty` or a refusal key, and carries none of its output. Output that is not valid UTF-8 is read with each invalid byte sequence replaced.

To register them on an app:

1. Under OAuth & Permissions, add the bot scope `commands`.
2. Under Slash Commands, create each command you enable: `/lanes`, `/asks`, `/report`. Socket Mode needs no request URL.
3. For the Home tab, turn on the Home tab under App Home and subscribe to the `app_home_opened` bot event under Event Subscriptions.
4. Reinstall the app to the workspace.

Slack reserves `/status` for its built-in command. The relay keeps that retired name readable until kendex 2.0.0 and prints one `command-renamed` warning per process naming `/lanes` as its replacement. Register `/lanes` for configured status output.

Slack sends a command name that two apps of one workspace register to the app installed most recently. The relay answers the names in `scripts/lib/relay.py`'s `COMMANDS` table; the package needs one app. For example:

```toml
[env]
SLACK_STATUS_COMMAND = "scripts/fleet-status --slack"
SLACK_REPORT_ROOT = "~/dev/fleet"
SLACK_HOME_COMMAND = "scripts/fleet-status --slack --merges"
```

## The Jarvis session hold

The relay pages an unread owner message from Jarvis's delivered `owner-unread` event in this root's mailbox. It waits for the session hold to end and checks the original message's read receipt before sending. A read message produces no page, even if it remains unanswered. A definite send refusal stays eligible for retry; an accepted page or an unknown send is not repeated. An unavailable relay cannot deliver a page, and a stopped producer emits no new event. Recovery handles retained events within the relay's existing history limit.

Each root checks the presence pair at every poll from its own settings and private env files, with caller exports taking precedence. The settings reader runs when a file's modification time, size or existence changes. A presence setting added, changed or removed takes effect on the next poll after that file changes, with no restart. Other settings still need `slack setup` or a restart. An empty or absent `SLACK_JARVIS_SESSION_FILE` means no hold. Relative paths start at that root; `~` expands to the home directory. A stale or missing file ends the hold at the next check. When the setting moves to another file, a running relay keeps the replaced file: the hold stands while either file is fresh. The relay drops the replaced file once the new one is fresh or the replaced one is stale. Emptying or removing the setting ends the hold at the next check. Before Slack calls, the relay publishes the hold in a per-root OS lock. It releases the lock when the hold ends. Process exit also releases it. Explicit posts check this lock and the current presence file, so a live Slack retry cannot restore mentions when the health record expires. `slack listen --status` shows `held-by=jarvis` while held. A refused settings read fails that root's post step and keeps its hold; other roots continue.

Replies to messages the owner typed in the channel still post in their threads while held, a notice that names a `/report` directive posts as a new message, and a notice that names a forwarded directive posts under its root, the root included.

The retired presence keys remain readable until kendex 2.0.0. Each fallback prints a `setting-renamed` line once per old key and process. The new key takes precedence, including an empty value.

The Jarvis session's `lane-mail events --item overseer --box to-overseer --mark-read` writes a bare logical read line count atomically to `<root>/tmp/lane-mail/overseer/to-overseer.seen`. On resume, the relay clamps the count to the mailbox length, skips notices and asks at or below it, including closed asks, with no post and no mention, and journals their ids. A reply to an owner message, a `/report` directive or a forwarded directive is not skipped: the session reading it does not show it in Slack, so it posts. A skipped reserved ask stays skipped after its deadline and after a restart. Posted unread reserved asks still get their overdue reminder. Later notices and asks, and held answers, still post. A missing or unreadable count skips nothing; hold times do not set the cutoff.

`lane-mail events` supplies `line` (physical position) and `count` (complete line count) for suppression. The oldest supported producer is orch 3.0.0 with its [owner channel](https://github.com/vanillagreencom/kendex/commit/ac62981e). [Position metadata](https://github.com/vanillagreencom/kendex/commit/e9c9497e) enables Jarvis-read suppression and the read mark on an answer. Missing or malformed positions still route without that suppression. Each bad field gets an `envelope-field` diagnostic with root and id. Other bad fields skip the envelope. A checkout poll failure names the root; other checkouts still run.

## Steering contract

| Where you write | What happens |
|-----------------|--------------|
| Top-level | The overseer receives it as a directive; :eyes: marks it delivered, :white_check_mark: read |
| In an open question's thread, any reply | The overseer receives your words as an answer to that question; :eyes: marks it delivered, :white_check_mark: read. The question stays open until the overseer closes it, or until its deadline passes where it names an option that stands |
| In any thread, at any age, including "Also send to channel" | The overseer receives it as a directive, unless it answers an open question. Its parent carries every owner and app thread message this reader generation has not received: [schemas/journal.md § Parent pointers](schemas/journal.md#parent-pointers) |
| A file, with or without text | The overseer receives the text, then the saved path of each file |
| A message with no text and no file | Not routed; the relay replies once, and once more after its journal is moved aside |
| From anyone not in `SLACK_OWNERS` | Not routed; the relay replies once, then ignores that message until its journal is moved aside, which answers it once more |
| An edit or a deletion | Ignored |

A question answered in the overseer's chat shows in its Slack thread as "Answered in the chat". An answer delivered by a program shows one line: `Answered: <option>.` If its text has no line that matches a question option, it shows "Answered outside the chat." A question nobody answered by its deadline shows as "No answer by the deadline", with the option that stood. A reserved question, a decision only you can take, has no option that stands. If you have not answered by its deadline, the relay posts it once more in its thread, mentioning you, or in a new thread where its own is gone; a reply there answers it. After changing `SLACK_OWNERS`, run `slack setup` for each bound checkout: a plain restart never invites an added owner, who could then steer a channel they cannot see.

## Credential boundary

- The bot token and the app-level token live in the private env file or the process environment, never in a settings file, the binding, the journal or a post.
- The relay reads and writes one channel per checkout, the one `setup` bound. `setup --take` binds a private channel only, and a relay given two checkouts bound to one channel refuses to start. `post --channel` reaches another channel only from the command line.
- Every text and file leaving the host passes the secret-value pattern the orch skill ships. A match is refused and never sent, and the report stays on disk.
- The binding stores channel and owner identifiers, names and the binding time, not message text. The journal stores delivery identifiers and parent context, including an excerpt of the parent's first 300 characters with newlines collapsed.
- Owner files stay in `tmp/slack/files/` until the checkout's user removes them.
- Anyone in the channel reads what the overseer posts. Only the owners steer.

## Proof

The [suites](https://github.com/vanillagreencom/kendex/tree/main/skills/slack/tests) use a fake Slack API and the real `lane-mail`. [Live proof](https://github.com/vanillagreencom/kendex/blob/main/skills/slack/DEVELOPMENT.md#live-proof) covers checks that need the owner's Slack app and channel.

## Setup

Requires Python 3.8+ and the orch skill, which the install adds.

Settings go in the project's `kendex.settings.toml` under `[env]` and the tokens in its private env file. Nothing is required, so an arrival writes nothing; [kendex.settings.toml.example](kendex.settings.toml.example) comments each key.

Other Slack settings are process-wide and use the launch checkout, the first `--root` for an installed unit. Caller exports take precedence.

| Variable | Purpose | Default |
|----------|---------|---------|
| `SLACK_BOT_TOKEN` | The bot token of the Slack app; private env file or process environment only | unset: Slack is off |
| `SLACK_APP_TOKEN` | The app-level token (`connections:write`) that opens the relay's Socket Mode connection; private env file or process environment only | unset: `listen` refuses, and so does `setup` while the unit `install` wrote stands |
| `SLACK_OWNERS` | Comma-separated email addresses of those whose messages steer | `KENDEX_USER_EMAIL` |
| `KENDEX_USER_HANDLE` | The person in `setup`'s default channel name, first name plus last initial (`bradm`), beside `KENDEX_USER_EMAIL` in the private env file | the local part of `KENDEX_USER_EMAIL` |
| `SLACK_POLL_SECONDS` | Seconds between two reads of each mailbox for posts and receipt marks | `15` |
| `SLACK_THREAD_DAYS` | Journal retention and reconnect lookback in days; live replies have no age limit | `7` |
| `SLACK_JARVIS_SESSION_FILE` | Per root: the Jarvis session's presence file; while fresh it holds mailbox posts except replies to messages the owner typed in the channel, which still post in their threads, and a notice that names a `/report` directive | empty: no hold |
| `SLACK_JARVIS_SESSION_MAX_AGE` | Per root: seconds after the file's last touch that it still holds posts | `600` |
| `SLACK_STATUS_COMMAND` | The command line `/lanes` replies with the output of | empty: off |
| `SLACK_ASKS_COMMAND` | The command line `/asks` replies with the output of | empty: off |
| `SLACK_REPORT_ROOT` | The `--root` checkout whose overseer mailbox `/report` writes to; another path refuses the relay's start with `setting-invalid` | empty: off |
| `SLACK_HOME_COMMAND` | The command line whose output the Home tab shows | empty: off |

## Licence

MIT, in the repository's LICENSE file.
