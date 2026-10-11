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
- `cpa` prepares finance and tax work for your decision.
- `legal` prepares legal answers with sources and the conditions that require another check.
- `operator` carries out an approved browser or account step and checks the result.
- `auditor` compares source evidence with a stated standard and reports gaps.
- `researcher` produces research reports with sources for each claim.
- `scout` finds code and explains the facts another assistant needs.
- `reviewer-arch` checks a design against the project's architecture rules.
- Setup workflows connect Slack, Linear, GitHub and a fleet machine with checked results.
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

| Path | Git status | Reason |
|---|---|---|
| `AGENTS.md` | Committed | Your standing instructions travel with you. |
| `skills/own/` | Committed | You are the source; `kendex add ./skills/own/my-task --skill my-task --harness codex --yes` makes your skill available to the harness. |
| `memory/` | Committed | Durable facts and rulings travel with you under [Memory](references/memory.md). |
| `state/`, with `state/handoff.md` and `state/archive/` | Committed | Current and archived handoffs travel with you without secrets under [Handoff](references/long-session.md#handoff); an app-managed home permits model file and shell writes only here. |
| `.agents/skills/` and each harness's skill directory, such as `.claude/skills/` | Committed | kendex renders or links installed skills here so a clone has them; VGS reads the Jarvis render when present. |
| `skills/base/` | Local | VGS supplies this package copy when `.agents/skills/jarvis/` is absent; it removes the copy when that render is present. |
| `tmp/` | Local | Scratch files stay on this machine under [Scratch files](references/computer-use.md#scratch-files). |
| `.env.local`, or the private env file selected by `KENDEX_ENV_FILE` | Local | Secrets stay on this machine; kendex creates the file with mode 600. |

`kendex add` writes the managed local-state ignore block. When kendex saves a secret into a new private env file, it adds that file's ignore line. These lines keep scratch and secrets out of Git. You do not need to add them yourself.

## Update

Run `kendex refresh` from your assistant home to update `.agents/skills/jarvis/`. kendex leaves `AGENTS.md`, `skills/own/`, `memory/` and `state/` byte-identical and writes no `skills/base/` copy. Add `--verbose` for package details: the CLI test sees `skill jarvis [codex]: Stale` before the update and `refreshed 3 changes · safety: clean` after it. An edited Jarvis render stays in place; the output names `skill jarvis for Codex: edited on disk and changed upstream`. If you declare a private `operator`, `auditor` or `legal` from source `.`, your declaration wins. The test's plan prints `Install agent operator for Codex` and installs the private operator. The catalog copy can install only after you remove your own entry. A release that needs a user-file edit states it in a `You do:` line in its changelog entry.

## Licence

MIT.
