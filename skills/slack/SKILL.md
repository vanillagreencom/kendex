---
name: slack
description: "Load to bind an overseer's mailbox to a private Slack channel, run or check the relay, or post an alert or a file to Slack."
summary: "Relays one checkout's overseer mailbox to one private Slack channel and back, owner messages over Socket Mode, through lane-mail alone: setup, listen, post, compact and install."
license: MIT
user-invocable: true
dependencies:
  required: [orch]
  optional: [linear]
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
- One relay per Slack app. Slack sends each owner message to one of an app's open Socket Mode connections, so a second relay on the same app takes part of the first one's messages, and each waits for the first relay's next reconnect. Each machine runs its own app and one relay over every root on it.
- The relay never reads or writes a mailbox file itself. An owner's words land through `lane-mail send --delivery-id`; who judges a repeat is [DEVELOPMENT.md § Constraints](https://github.com/vanillagreencom/kendex/blob/main/skills/slack/DEVELOPMENT.md#constraints).
- A delivery prints `delivered` with its Slack ts, mailbox id and `path=live|catch-up`. Eyes failures print a keyed cause and retry on the next poll; `already_reacted` settles the mark.
- Owner answers, question closure and ruling notices follow [orch communication-modes.md § Owner asks](../orch/references/communication-modes.md#owner-asks).
- Every outbound text and file passes the secret-value pattern the orch skill ships at `references/secret-value.ere`. A match is refused, journaled and never sent.
- A relay reads its settings at start. After changing `SLACK_OWNERS`, run `slack setup` for each bound root: it invites an added owner to the channel and restarts the unit `install` wrote. A plain restart drops a removed owner but never invites an added one. After changing either token, restart the relay.
- A threaded directive carries a small parent pointer, cached in the journal: [schemas/journal.md § Parent pointers](schemas/journal.md#parent-pointers). Read the full thread only when needed with `slack thread TS [--limit N]`.
- The channel binding is installation state written by `setup`, never a setting. The alert channel is the caller's `--channel` argument.
- Settings live in the project's `kendex.settings.toml` and the two tokens, `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN`, in its private env file: [kendex.settings.toml.example](kendex.settings.toml.example).

## Message standard

- `markup.py` owns outbound tracker links and their representation. Consumers set nothing new: each root's `LINEAR_TEAM`, read through `orch-env`, selects Linear; otherwise its GitHub repository selects GitHub issues. With neither, text stays unchanged. Linear keys and the workspace URL key come from the sibling Linear skill's `teams keys` action, cached per root for a day. A missing or failed read leaves text unlinked with one `tracker-links-unavailable` notice per root and process.
- The relay and `slack post` link bare tracker ids before checking secrets and the Markdown cap. Existing links, Slack angle tokens, bare URLs, inline code and fenced code stay literal. Never put a tracker id in a code span.
- `slack post` text without `--file`, and the relay's ask, notice and answer posts, go out as standard Markdown, which Slack renders: `**bold**`, lists, headings, links and code blocks.
- Slack takes at most 12,000 characters of standard Markdown. `slack post` refuses an input already longer than that `text-too-long`; send the long part as a file. Link expansion across the cap selects mrkdwn for both outbound paths. The relay also posts a longer input as mrkdwn, its Markdown marks shown as typed, so an ask still reaches the owner before its deadline.
- An ask's draft, the text the owner approves, posts as one code block, never linked, so the owner reads it as typed. Past the cap its mrkdwn block escapes `&`, `<` and `>`; mrkdwn cannot show a run of three backticks inside a block, so such a draft is refused `text-not-literal` and not sent.
- A file's comment, the text beside `--file` or a notice's `--attach`, renders as Slack's own mrkdwn markup, not standard Markdown. It is outside the 12,000-character cap, and Slack's own message limits still bound it. How to write it: [orch communication-modes.md § Owner messages](../orch/references/communication-modes.md#owner-messages), the rule for a text sent beside a file.
- The words and markup of every post follow [orch communication-modes.md § Owner messages](../orch/references/communication-modes.md#owner-messages).

## Doctor row

`slack listen --status` prints one `slack: slack-relay=ROOT state=ok|failing|stale|never` line per root, with `connection=connected|reconnecting|disconnected` and `connection_since=`; a `never` line carries only `fix=`. A state other than `ok` carries `fix=`. A relay reconnecting past the bound the status record states reads `failing`. The fields of the row: [schemas/journal.md § The status record](schemas/journal.md#the-status-record).
