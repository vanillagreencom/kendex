# Jarvis

Jarvis is a set of instructions for an AI assistant that carries out work you delegate. Use it in a folder with your coding assistant, including when you have no desktop app.

## Features

The agents listed below require a kendex installation of Jarvis. An app-supplied copy of only the skill folder supplies none of their harness agent files.

- A [persona](persona.md) defines how the assistant works and answers you.
- [Decision guidance](references/decisions.md) defines which actions need your approval.
- [Result checks](references/verification.md) keep completion claims tied to evidence.
- [Communication guidance](references/communication.md) covers replies, decision requests and progress reports.
- The [session workflow](workflows/session.md) keeps open work available when another assistant takes control.
- The [home layout](#home-layout) keeps instructions, memory and handoffs available across machines.
- [Memory guidance](references/memory.md) keeps checked facts and preferences apart from unfinished work.
- [Computer guidance](references/computer-use.md) covers desktop control, recovery and scratch files.
- [Browser guidance](references/browser.md) covers forms, private profiles and bot checks.
- [Account guidance](references/accounts-and-secrets.md) covers credentials, sign-in and official records.
- [Research guidance](references/research.md) covers source checks, legal answers and audits.
- [Agent reach](references/agent-reach.md) lets the assistant hear from and instruct the agent in each of your kendex projects that has the mailbox package, and offers to install it where it is missing.
- `cpa` prepares finance and tax work for your decision.
- `legal` prepares legal answers with sources and the conditions that require another check.
- `operator` carries out an approved browser or account step and checks the result.
- `auditor` compares source evidence with a stated standard and reports gaps.
- `researcher` produces research reports with sources for each claim.
- `scout` finds code and explains the facts another assistant needs.
- `reviewer-arch` checks a design against the project's architecture rules.
- `publicist` drafts product videos, posts and outreach. Each send needs your approval on its tracker item.
- Setup workflows connect Slack, Linear, GitHub and a fleet machine with checked results.
- The [control-host event source](#control-host-events) collects mail and sends each settled burst through the session mailbox.
- Your own skills and private notes add task knowledge and personal context.
- [Updates](#update) replace the Jarvis render and keep your instructions, own skills, memory and handoffs unchanged.

## Install

You need kendex, Git, Python 3.8 or newer, Bash, jq, tmux, one supported coding assistant you have signed in to (Claude Code, Codex, Copilot CLI or Pi), and a Linear workspace. The continuing session keeps its open work in Linear.

Your Jarvis home is a new folder of its own, outside any existing project. Running `git init` in a folder inside a project does not separate it from that project. Run these four commands, with your assistant in place of `codex`:

```sh
mkdir ~/jarvis && cd ~/jarvis && git init
kendex add vanillagreencom/kendex --bundle jarvis --harness codex
.agents/skills/jarvis/scripts/jarvis-session start --home . --harness codex
.agents/skills/jarvis/scripts/jarvis-session attach --home .
```

- `kendex add` asks whether to install into this folder and whether to set up the commit-guards hooks. Answer yes to both. List each assistant you use in `--harness`, comma-separated.
- The first `start` writes the starting files, an `AGENTS.md` that loads the [persona](persona.md), the memory index and `state/`, and then starts the session. It uses the account folder your assistant uses, such as `~/.codex` or the folder `CODEX_HOME` names; add `--account DIR` for another one. In a folder that is not a new home of its own, it refuses and names what to do. [Initialize](references/home-layout.md#initialize) has the details.
- `attach` puts your terminal on the running session. Before the first start with Copilot CLI, follow [Copilot folder trust](references/home-layout.md#copilot-folder-trust).

## How it works

Jarvis reads the guidance your request needs, works within the authority you give it and checks the result. In a continuing session, open work stays in your tracker and recovery notes help the next session continue. These pages explain the current package and identify changes still being built.

| Your question | Read |
|---|---|
| How does a request get finished? | [Tasks](documentation/HIW-tasks.md) |
| How does Jarvis work with other agents? | [Delegation](documentation/HIW-delegation.md) |
| How does work continue after a restart or handover? | [Sessions](documentation/HIW-sessions.md) |
| What does Jarvis remember? | [Memory](documentation/HIW-memory.md) |
| How do requests and decisions reach Jarvis? | [Messages](documentation/HIW-messages.md) |
| What happens when a result needs another check? | [Checks](documentation/HIW-checks.md) |
| How does Jarvis use my computer and accounts? | [Tools](documentation/HIW-tools.md) |
| What belongs in my Jarvis home? | [Home](documentation/HIW-home.md) |

## Customise

Use the [home layout](#home-layout) for your files. Name your decision owners and permitted work in your standing instructions. Set minute cadence, quiet hours, time zone and report paths through orch's consumer settings; the [settings example](kendex.settings.toml.example) shows the report keys. The event producer runs the [progress checkpoint](workflows/session.md#progress-checkpoint) when a report is due.

For a skill you write, create a `my-task/SKILL.md` under the own-skills path in the [home layout](#home-layout). Give it a frontmatter `name` that matches `my-task` and a `description` that says when the assistant must read it. Put the task instructions below the frontmatter. Run `kendex add ./skills/own/my-task --skill my-task --harness codex --yes` from your assistant home. Select the harnesses you use with `--harness`.

Follow [Memory](references/memory.md) for personal facts and preferences. Follow the [home contract](references/home-contract.md) to find and read those notes. Follow the [session workflow](workflows/session.md) for unfinished work. Store secrets in a password manager rather than memory notes.

## Home layout

Use a private Git repository for your assistant home. Committed files travel with its commits. Local files stay on one machine.

Use the command in [Install](#install) to install Jarvis in this home.

Follow the [home layout reference](references/home-layout.md) for file paths, Git status, Copilot folder trust and the session record.

## Control-host events

Start the event source through the [session workflow](workflows/session.md#control-host-events). It reads mail on this machine and on declared SSH hosts, including control and satellite machines. A fixed settle combines a burst into one session mailbox directive. The session's existing mailbox route supplies the body.

Set the keys shown in [kendex.settings.toml.example](kendex.settings.toml.example) under `[env]` in the assistant home's `kendex.settings.toml`. The process environment takes precedence over the private env file, which takes precedence over shared settings.

- `JARVIS_CONTROL_HOST` keeps the existing control-host route. Empty leaves it off.
- `JARVIS_CONTROL_USER` names the account whose overseers the control host runs, when it is not the SSH user. `owner-note` lists roots and sends there as that account, and the event source reads mail and renews presence there as it, through passwordless `sudo -n`. Empty uses the SSH user.
- `JARVIS_REMOTE_HOSTS` adds whitespace-separated SSH aliases. With an additional alias, a bare note must name a unique registered root across all machines; select a duplicate with `--host ALIAS` or `--local`. Use one stable alias per machine and restart the event source after changing hosts.
- `JARVIS_MAIN_HOST` makes this machine a satellite of the main Jarvis at `DEST:/abs/main/home`. Empty makes it the main. Set it in the machine's private env file, never in shared settings; see [Agent reach: Main and satellites](references/agent-reach.md#main-and-satellites).
- `JARVIS_LOG_DIR` selects durable logs and batch state. The default is `${XDG_STATE_HOME:-$HOME/.local/state}/jarvis`. Give simultaneous homes separate directories.
- `JARVIS_WAKE_SETTLE_SECS` defaults to 15 seconds. Zero sends immediately.
- `SLACK_JARVIS_SESSION_FILE` reuses the Slack relay's hold. Set it in each local or host root whose relay the session must hold. An empty value creates no hold.

Three scripts in `.agents/skills/jarvis/scripts/` serve the session. Each reads the home from its working directory.

| Script | Use |
|---|---|
| `owner-unanswered` | Lists your messages that no reply, later reply in their Slack thread, closed question or progress record covers, one JSON line each. A file you send as its own message within 30 seconds of its text, in the same thread or both at the top of the channel, counts as that message. It reads the records in `state/handoff.md` and the archive beside it; `--handoff PATH` selects another handoff as `progress-log` does. It lists the last 24 hours; `--since TIME` replaces that window and `--older MINUTES` narrows the list. |
| `progress-log` | Adds one progress record to `state/handoff.md`, or to the handoff `--handoff PATH` selects. The clock supplies its id and time. An id is `P-` and the UTC time as `YYYYMMDDTHHMMSSZ`, with `-2`, `-3` added for later records in the same second. `--archived FILE` instead adds an archived handoff's dated line to the archive's `INDEX.md`. `--check-state` lists the State lines to correct: those whose tracker items are all Done or Canceled, and those naming no tracker, mailbox or Slack id. |
| `owner-note` | Sends a note file as your directive to a repository's agent on a declared machine. With no additional alias, it keeps control-host-first routing and local fallback. The note ends with a request to check its facts and approach. Read-only consumers can [resolve the registered destination](references/agent-reach.md#route) without sending. |

The loop adds `EVENT owner-unread` once when a message from you stays unread in the home inbox for 10 minutes. The local Slack relay pages you from the delivered event when its session hold permits. It checks the original message's read receipt before sending, so a read message produces no page. A stopped producer emits no new event, and an unavailable relay cannot deliver a page. When a message from you arrives, the loop checks it every 5 minutes until a reply, a later reply in its thread, a closed question or a progress record covers it, and adds `EVENT owner-unanswered` once if it is still uncovered after 10 minutes. With no message waiting, it runs no check. Each check reads the records in `state/handoff.md` and its archive, from the oldest waiting message on. That event reminds the session; it never means the message is unread.

Claude Code runs the loop through Monitor and receives a pointer for each batch. Pi uses its installed mailbox wake. Copilot receives mail through its installed hooks; idle delivery depends on its native extension.

Run one Slack app and local-root relay on each machine under [Slack setup](../slack/README.md#slack-app). The existing relay owns delivery keys and bounded history catch-up; a lost outbound response stays unknown and is not repeated. Consumer installation and live acceptance belong in the consumer tracker.

Consumer checks can append complete events under the [log contract](references/control-host-events.md#input-log). That reference also defines recovery and session-bound presence.

## Update

For an app-supplied package, the assistant app controls package updates. VGS updates the package files it wrote when it opens the home. It preserves files that kendex owns and your other files. Keep your changes in `AGENTS.md` and `skills/own/`.

When your home's `.kendex-lock.json` records the `jarvis` skill, kendex controls package updates. VGS writes no package files in that home.

Run `kendex refresh` from your kendex-managed assistant home to update `.agents/skills/jarvis/`. kendex keeps your standing instructions, own skills, memory and handoffs. Add `--verbose` for package details. An edited Jarvis render stays in place and the output reports the conflict. If you declare a private `operator`, `auditor` or `legal` from source `.`, your declaration wins. The catalog copy can install only after you remove your own entry. A release that needs a user-file edit states it in a `You do:` line in its changelog entry.

## Licence

MIT.
