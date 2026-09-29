---
name: slack
description: "Load to bind an overseer's mailbox to a private Slack channel, run or check the relay, or post an alert or a file to Slack."
summary: "Relays one checkout's overseer mailbox to one private Slack channel and back by polling, through lane-mail alone: setup, listen, post, compact and install."
license: MIT
user-invocable: true
dependencies:
  required: [orch]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [orchestration]
---

# Slack

The relay between one checkout's overseer mailbox and one private Slack channel. Every mailbox read and write goes through that checkout's `lane-mail`; the relay keeps its own record under `tmp/slack/`.

```bash
.agents/skills/slack/scripts/slack setup [--root ROOT] [--name NAME | --take CHANNEL_ID]
.agents/skills/slack/scripts/slack listen --root ROOT [--root ROOT]... [--once]
.agents/skills/slack/scripts/slack listen --status --root ROOT [--root ROOT]...
.agents/skills/slack/scripts/slack post [--root ROOT] [--channel ID] --text TEXT [--mention] [--file PATH] [--thread TS] [--update TS]
.agents/skills/slack/scripts/slack compact [--root ROOT]...
.agents/skills/slack/scripts/slack install --root ROOT [--root ROOT]... [--print]
```

What each verb does, every setting, and every keyed line: `slack --help`. Python 3.8 or newer, standard library only.

## Rules

- A root is a checkout with the orch skill installed. A relay serves every root it is given, and one relay serves one checkout, held by an OS lock.
- The relay never reads or writes a mailbox file itself. An owner's words land through `lane-mail send --delivery-id` or `lane-mail resolve --delivery-id`; who judges a repeat is [DEVELOPMENT.md § Constraints](DEVELOPMENT.md#constraints).
- The first owner reply in a question's thread closes the question. The ruling the overseer records reaches Slack as a notice with `--ref`, per [orch communication-modes.md § Owner asks](../orch/references/communication-modes.md#owner-asks).
- Every outbound text and file passes the secret-value pattern the orch skill ships at `references/secret-value.ere`. A match is refused, journaled and never sent.
- A relay reads its settings at start. After changing `SLACK_OWNERS`, run `slack setup` for each bound root: it invites an added owner to the channel and restarts the unit `install` wrote. A plain restart drops a removed owner but never invites an added one. After changing the token, restart the relay.
- The journal holds identifiers only: [schemas/journal.md](schemas/journal.md).
- The channel binding is installation state written by `setup`, never a setting. The alert channel is the caller's `--channel` argument.
- Settings live in the project's `kendex.settings.toml` and the token in its private env file: [kendex.settings.toml.example](kendex.settings.toml.example).

## Message standard

- `slack post` text without `--file`, and the relay's ask, notice and answer posts, go out as standard Markdown, which Slack renders: `**bold**`, lists, headings, links and code blocks.
- Slack takes at most 12,000 characters of standard Markdown. `slack post` refuses a longer text `text-too-long`; send the long part as a file. The relay posts a longer text as Slack's mrkdwn, its Markdown marks shown as typed, so an ask still reaches the owner before its deadline.
- A file's comment, the text beside `--file` or a notice's `--attach`, renders as Slack's own mrkdwn markup, not standard Markdown. It is outside the 12,000-character cap, and Slack's own message limits still bound it. How to write it: [orch communication-modes.md § Owner messages](../orch/references/communication-modes.md#owner-messages), the rule for a text sent beside a file.
- The words and markup of every post follow [orch communication-modes.md § Owner messages](../orch/references/communication-modes.md#owner-messages).

## Doctor row

`slack listen --status` prints one `slack: slack-relay=ROOT state=ok|failing|stale|never` line per root, then one `slack: slack-relay-budget=N` line summing the roots. A state other than `ok` carries `fix=`. The fields of the row: [schemas/journal.md § The status record](schemas/journal.md#the-status-record).
