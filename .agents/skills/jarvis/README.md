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

For a skill you write, create a `my-task/SKILL.md` under the own-skills path in the [home layout](#home-layout). Give it a frontmatter `name` that matches `my-task` and a `description` that says when the assistant must read it. Put the task instructions below the frontmatter. Run the command in the own-skills row below from your assistant home. Select the harnesses you use with `--harness`.

Follow [Memory](references/memory.md) for personal facts and preferences. Put reading routes for those notes in your standing instructions. Follow the [session workflow](workflows/session.md) for unfinished work. Store secrets in a password manager rather than memory notes.

## Home layout

Use a private Git repository for your assistant home. Committed files travel with its commits. Local files stay on one machine.

Install the `jarvis` bundle in this home with `kendex add --bundle jarvis --harness claude,codex,copilot,pi --yes`. The bundle installs Jarvis and the hooks that confirm the native session identity.

Before the first Jarvis Start with Copilot CLI, open this home in native Copilot with the selected account. Approve its folder-trust request once. Jarvis does not approve native security requests. Without this setup, Start can remain Starting until the launch bound, then report a launch failure.

| Path | Git status | Reason |
|---|---|---|
| `AGENTS.md` | Committed | Your standing instructions travel with you. |
| `skills/own/` | Committed | You are the source; `kendex add ./skills/own/my-task --skill my-task --harness codex --yes` makes your skill available to the harness. |
| `memory/` | Committed | Durable facts and rulings travel with you under [Memory](references/memory.md). |
| `state/handoff.md` | Committed | The session model writes the current handoff under [Handoff](references/long-session.md#handoff). |
| `state/archive/` | Committed | The session model writes archived handoffs and progress logs under [Handoff](references/long-session.md#handoff). |
| Other files under `state/` | Committed | A consumer's file and shell tools write its work here. An app-managed home limits model file and shell writes to this folder. |
| `${XDG_STATE_HOME:-$HOME/.local/state}/kendex/jarvis/<canonical-home-key>/jarvis-session.json` | Outside the home | The session runtime and the native SessionStart hook write the local controller record. The runtime writes no start-critical record under `state/`. |
| `.agents/skills/` and each harness's skill and agent directories, such as `.claude/skills/`, `.claude/agents/` and `.codex/agents/` | Committed | kendex renders or links installed skills and agents here so a clone has them. In a home where kendex did not install Jarvis, an assistant app such as VGS can copy a kendex-rendered package to these same paths. |
| `tmp/` | Local | Scratch files stay on this machine under [Scratch files](references/computer-use.md#scratch-files). |
| `.env.local`, or the private env file selected by `KENDEX_ENV_FILE` | Local | Secrets stay on this machine; kendex creates the file with mode 600. |

`kendex add` writes the managed local-state ignore block. When kendex saves a secret into a new private env file, it adds that file's ignore line. These lines keep scratch and secrets out of Git. You do not need to add them yourself.

The [session command](workflows/session.md#session-command) keeps one tmux controller per canonical home. Its record stays across logins and restarts. Each home uses a separate tmux socket. Status names that socket and the owned session, window and pane.

## Control-host events

Start the event source through the [session workflow](workflows/session.md#control-host-events). It reads mail on this machine and, when configured, on an SSH control host. A fixed settle combines a burst into one session mailbox directive. The session's existing mailbox route supplies the body.

Set the keys shown in [kendex.settings.toml.example](kendex.settings.toml.example) under `[env]` in the assistant home's `kendex.settings.toml`. The process environment takes precedence over the private env file, which takes precedence over shared settings.

- `JARVIS_CONTROL_HOST` selects the SSH destination. Empty runs local mail only.
- `JARVIS_LOG_DIR` selects durable logs and batch state. The default is `${XDG_STATE_HOME:-$HOME/.local/state}/jarvis`. Give simultaneous homes separate directories.
- `JARVIS_WAKE_SETTLE_SECS` defaults to 15 seconds. Zero sends immediately.
- `SLACK_JARVIS_SESSION_FILE` reuses the Slack relay's hold. Set it in each local or host root whose relay the session must hold. An empty value creates no hold.

Claude Code runs the loop through Monitor and receives a pointer for each batch. Pi uses its installed mailbox wake. Copilot receives mail through its installed hooks; idle delivery depends on its native extension.

Consumer checks can append complete events under the [log contract](references/control-host-events.md#input-log). That reference also defines recovery and session-bound presence.

## Update

For an app-supplied package, the assistant app controls package updates. VGS updates the package files it wrote when it opens the home. It preserves files that kendex owns and your other files. Keep your changes in `AGENTS.md` and `skills/own/`.

When your home's `.kendex-lock.json` records the `jarvis` skill, kendex controls package updates. VGS writes no package files in that home.

Run `kendex refresh` from your kendex-managed assistant home to update `.agents/skills/jarvis/`. kendex keeps your standing instructions, own skills, memory and handoffs. Add `--verbose` for package details. An edited Jarvis render stays in place and the output reports the conflict. If you declare a private `operator`, `auditor` or `legal` from source `.`, your declaration wins. The catalog copy can install only after you remove your own entry. A release that needs a user-file edit states it in a `You do:` line in its changelog entry.

## Licence

MIT.
