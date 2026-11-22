---
name: slack
description: "Load to bind an overseer's mailbox to a private Slack channel, run or check the relay, or post an alert or a file to Slack."
license: MIT
user-invocable: true
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Slack

The relay between one checkout's overseer mailbox and one private Slack channel. Mailbox reads use the mailbox package installed beside Slack inside the relay process. Writes use the bound checkout's `lane-mail`. The relay keeps its own record under `tmp/slack/`.

```bash
.agents/skills/slack/scripts/slack setup [--root ROOT] [--name NAME | --take CHANNEL_ID]
.agents/skills/slack/scripts/slack listen --root ROOT [--root ROOT]... [--once]
.agents/skills/slack/scripts/slack listen --status --root ROOT [--root ROOT]...
.agents/skills/slack/scripts/slack deliver --root ROOT < event.json
.agents/skills/slack/scripts/slack post [--root ROOT] [--channel ID] --text TEXT [--mention] [--file PATH]... [--thread TS] [--update TS]
.agents/skills/slack/scripts/slack read --channel ID (--ts TS | --latest N)
.agents/skills/slack/scripts/slack compact [--root ROOT]...
.agents/skills/slack/scripts/slack install --root ROOT [--root ROOT]... [--print]
```

What each verb does, every setting, and every keyed line: `slack --help`.

## Rules

- Socket Mode is the standard mode without a hosted receiver: one app per machine and one relay per app over that machine's roots. Slack sends each message to one of an app's open connections.
- A hosted receiver uses one app per workspace.
  - Set `SLACK_INBOUND=queue` before setup and listen.
  - Its worker calls `slack deliver --root ROOT`.
  - Switching keeps the binding and journal.
- Webhooks cannot work through a proxy that swaps headers only. Every message post uses `chat.postMessage`.
- A relay reads its settings at start.
  - After changing `SLACK_OWNERS`, run `slack setup` for each bound root: it invites an added owner to the channel and restarts the unit `install` wrote.
  - A plain restart drops a removed owner but never invites an added one.
  - After changing either token, restart the relay.
- The channel binding is installation state written by `setup`, never a setting.
- The alert channel is the caller's `--channel` argument.
- Settings live in the project's `kendex.settings.toml` and the two tokens, `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN`, in its private env file: [kendex.settings.toml.example](kendex.settings.toml.example).

## Message standard

- Pull requests use `OWNER/REPO#N`, or `REPO#N` and `#N` in the sending repository.
- Existing links, Slack angle tokens, bare URLs, inline code and fenced code stay literal. Never put a tracker id in a code span.
- `slack post` text without `--file`, and the relay's ask, notice and answer posts, go out as standard Markdown, which Slack renders: `**bold**`, lists, headings, links and code blocks.
- Slack takes at most 12,000 characters of standard Markdown.
  - `slack post` refuses a final linked body past that cap as `text-too-long`. Send the long part as a file.
  - The relay also refuses oversized new and overdue questions after expansion and secret checks, before sending. Shorten the question or link its detail in a file, issue or report.
  - The complete question, including its draft, options and deadline, must fit the cap.
- A file's comment, the text beside `--file` or a notice's `--attach`, is written in standard Markdown like any post. It is outside the 12,000-character cap, and Slack's own message limits still bound it.
- Repeat `post --file` for related files in one share with one comment. An input or upload failure shares no partial group.

## Doctor row

`slack listen --status` prints one `slack: slack-relay=ROOT state=ok|failing|stale|never` line per root. The fields of the row: [schemas/journal.md § The status record](schemas/journal.md#the-status-record).
