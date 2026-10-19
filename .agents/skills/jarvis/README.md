# Jarvis

Jarvis is a set of instructions for an AI assistant that carries out work you delegate. Use it in a folder with your coding assistant, including when you have no desktop app.

## Features

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

One command installs the persona, references, workflows and agents:

```sh
kendex add --skill jarvis --harness claude,codex,copilot,pi --yes
```

## How it works

Your assistant reads the Jarvis skill when you delegate a task. It follows the reading routes in [SKILL.md](SKILL.md) to load the reference that the task needs.

## Customise

Use the [home layout](#home-layout) for your files. Name your decision owners, permitted work, reporting cadence and quiet hours in your standing instructions.

For a skill you write, create a `my-task/SKILL.md` under the own-skills path in the [home layout](#home-layout). Give it a frontmatter `name` that matches `my-task` and a `description` that says when the assistant must read it. Put the task instructions below the frontmatter. Run `kendex add ./skills/own/my-task --skill my-task --harness codex --yes` from your assistant home. Select the harnesses you use with `--harness`.

Follow [Memory](references/memory.md) for personal facts and preferences. Follow the [home contract](references/home-contract.md) to find and read those notes. Follow the [session workflow](workflows/session.md) for unfinished work. Store secrets in a password manager rather than memory notes.

## Home layout

Use a private Git repository for your assistant home. Committed files travel with its commits. Local files stay on one machine.

Install the `jarvis` bundle in this home with `kendex add --bundle jarvis --harness claude,codex,copilot,pi --yes`. The bundle installs Jarvis and the hooks that confirm the native session identity.

Follow the [home layout reference](references/home-layout.md) for file paths, Git status, Copilot folder trust and the session record.

## Control-host events

Start the event source through the [session workflow](workflows/session.md#control-host-events). It reads mail on this machine and, when configured, on an SSH control host. A fixed settle combines a burst into one session mailbox directive. The session's existing mailbox route supplies the body.

Set the keys shown in [kendex.settings.toml.example](kendex.settings.toml.example) under `[env]` in the assistant home's `kendex.settings.toml`. The process environment takes precedence over the private env file, which takes precedence over shared settings.

- `JARVIS_CONTROL_HOST` selects the SSH destination. Empty runs local mail only.
- `JARVIS_LOG_DIR` selects durable logs and batch state. The default is `${XDG_STATE_HOME:-$HOME/.local/state}/jarvis`. Give simultaneous homes separate directories.
- `JARVIS_WAKE_SETTLE_SECS` defaults to 15 seconds. Zero sends immediately.
- `SLACK_JARVIS_SESSION_FILE` reuses the Slack relay's hold. Set it in each local or host root whose relay the session must hold. An empty value creates no hold.

Three scripts in `.agents/skills/jarvis/scripts/` serve the session. Each reads the home from its working directory.

| Script | Use |
|---|---|
| `owner-unanswered` | Lists your messages that no reply, closed question or progress record covers, one JSON line each. `--since TIME` and `--older MINUTES` narrow the list. |
| `progress-log` | Adds one progress record to `state/handoff.md`. The clock supplies its id and time. An id is `P-` and the UTC time as `YYYYMMDDTHHMMSSZ`, with `-2`, `-3` added for later records in the same second. |
| `owner-note` | Sends a note file as your directive to a repository's agent, on the control host first, then on this machine. The note ends with a request to check its facts and approach. |

The loop adds `EVENT owner-unread` once when a message from you stays unread in the home inbox for 10 minutes. Key a page on that event. Every 5 minutes the loop also adds `EVENT owner-unanswered` once for each message `owner-unanswered` lists after 10 minutes. That event reminds the session; it never means the message is unread.

Claude Code runs the loop through Monitor and receives a pointer for each batch. Pi uses its installed mailbox wake. Copilot receives mail through its installed hooks; idle delivery depends on its native extension.

Consumer checks can append complete events under the [log contract](references/control-host-events.md#input-log). That reference also defines recovery and session-bound presence.

## Update

For an app-supplied package, the assistant app controls package updates. VGS updates the package files it wrote when it opens the home. It preserves files that kendex owns and your other files. Keep your changes in `AGENTS.md` and `skills/own/`.

When your home's `.kendex-lock.json` records the `jarvis` skill, kendex controls package updates. VGS writes no package files in that home.

Run `kendex refresh` from your kendex-managed assistant home to update `.agents/skills/jarvis/`. kendex keeps your standing instructions, own skills, memory and handoffs. Add `--verbose` for package details. An edited Jarvis render stays in place and the output reports the conflict. If you declare a private `operator`, `auditor` or `legal` from source `.`, your declaration wins. The catalog copy can install only after you remove your own entry. A release that needs a user-file edit states it in a `You do:` line in its changelog entry.

## Licence

MIT.
