# Jarvis

Jarvis is a set of instructions for an AI assistant that carries out work you delegate. Use it in a folder with your coding assistant, including when you have no desktop app.

## Features

- A [persona](persona.md) defines how the assistant works and answers you.
- [Decision guidance](references/decisions.md) defines which actions need your approval.
- [Result checks](references/verification.md) keep completion claims tied to evidence.
- [Communication guidance](references/communication.md) covers replies, decision requests and progress reports.
- [Session guidance](references/long-session.md) keeps open work available when another assistant takes control.
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

## Install

One command installs the persona, references, workflows and agents:

```sh
kendex add --skill jarvis --harness claude,codex,copilot,pi --yes
```

## How it works

Your assistant reads the Jarvis skill when you delegate a task. It follows the reading routes in [SKILL.md](SKILL.md) to load the reference that the task needs.

## Customise

Keep your own instructions in the folder's `AGENTS.md`. Name your decision owners, permitted work, reporting cadence and quiet hours there.

For a skill you write, create `skills/my-task/SKILL.md` in your own catalog folder. Give it a frontmatter `name` that matches `my-task` and a `description` that says when the assistant must read it. Put the task instructions below the frontmatter. Install it beside Jarvis for the assistant you use:

```sh
kendex add /path/to/your-catalog --skill my-task --harness codex --yes
```

Use your actual catalog path for a personal skill. Select the harnesses you use with `--harness`.

Keep personal facts and preferences in a private `memory/` folder in your assistant's home. Record where a fact came from and when you checked it. Put reading routes for those notes in your `AGENTS.md`, so the assistant can find the context for a task. Keep unfinished work in a separate handoff note. Store secrets in a password manager rather than memory notes.

## Licence

MIT.
