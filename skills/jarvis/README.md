# Jarvis

Jarvis is a set of instructions for an AI assistant that carries out work you delegate. Use it in a folder with your coding assistant, including when you have no desktop app.

## Features

- A persona defines how the assistant works and answers you.
- Task references cover decisions, result checks and communication.
- Your own skills and private notes add task knowledge and personal context.

## Install

```sh
kendex add --skill jarvis --harness claude,codex,copilot,pi --yes
kendex verify --scope project
```

## How it works

Your assistant reads the Jarvis skill when you delegate a task. It follows the reading routes in [SKILL.md](SKILL.md) to load the reference that the task needs.

| File | Use |
|---|---|
| [persona.md](persona.md) | Standing work and response instructions |
| [references/decisions.md](references/decisions.md) | Actions the assistant can take, approval requests and deferred work |
| [references/verification.md](references/verification.md) | Evidence for claims, completion checks and recurring tools |
| [references/communication.md](references/communication.md) | Replies, decisions, progress reports and communication preferences |

## Customise

Use [SKILL.md § Setup](SKILL.md#setup) to enable the persona. Keep your own instructions in the folder's `AGENTS.md`. Name your decision owners, permitted work, reporting cadence and quiet hours there.

For a skill you write, create `skills/my-task/SKILL.md` in your own catalog folder. Give it a frontmatter `name` that matches `my-task` and a `description` that says when the assistant must read it. Put the task instructions below the frontmatter. Install it beside Jarvis for the assistant you use:

```sh
kendex add /path/to/your-catalog --skill my-task --harness codex --yes
```

Use your actual catalog path for a personal skill. Select the harnesses you use with `--harness`.

Keep personal facts and preferences in a private `memory/` folder in your assistant's home. Record where a fact came from and when you checked it. Put reading routes for those notes in your `AGENTS.md`, so the assistant can find the context for a task. Keep unfinished work in a separate handoff note. Store secrets in a password manager rather than memory notes.

## Licence

MIT.
