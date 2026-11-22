# Second Opinion

Code review and consultation through another AI CLI. It lets a project request an independent model's analysis of a change, design or question.

## Features

- Review a branch diff.
- Audit selected code.
- Challenge a proposed approach.
- Ask a focused technical question.
- Collect reviews from multiple configured models.

## Install

```bash
kendex add vanillagreencom/kendex --skill second-opinion
```

## How it works

You select a review, audit, challenge or question. The script identifies the current session model and chooses an eligible external CLI. That CLI reads the requested context and returns its analysis. Reviews and audits are saved in the shared finding format; other modes return text. A review or audit whose CLI fails or is killed keeps a failure record; [references/error-handling.md](references/error-handling.md) says what it holds.

## Setup

Requires jq, perl and a logged-in external CLI: claude, codex, pi with a Copilot login, or another CLI a settings entry names. kendex also installs the github skill, which this skill needs.

Set shared values in `kendex.settings.toml` under `[env]` and personal overrides in `.env.local`. Nothing is marked required, so installing writes no settings. Every key, its default and the built-in `claude`, `codex`, `pi-copilot` and `pi-copilot-gpt` command lines: `second-opinion --help`. The ones most projects touch:

- `SECOND_OPINION_MODELS`: the ordered fallback list, default `claude codex`. Set empty, the run refuses. An entry skipped for room or failing to run advances to the next name.
- `SECOND_OPINION_COUNT`: opinions a `review` collects, default `1`.
- `SECOND_OPINION_<NAME>_CMD`: the command a roster entry runs. Another model CLI is a settings entry, not new code. Keep the sandbox or tool restrictions read-only so a second opinion can never write to your worktree.
- An entry is skipped when its command's program is not installed. The command runs without a shell, so a leading shell builtin such as `exec` makes the entry unavailable.
- `SECOND_OPINION_TIMEOUT`: seconds per CLI invocation, default `1080`.
- `SECOND_OPINION_COPILOT_CMD` and `SECOND_OPINION_COPILOT_MODEL`: a `copilot` entry's command and the model it runs. Copilot CLI documents no read-only headless mode, so there is no built-in command. It fronts several vendors, so the entry is skipped until the model is named.
- `pi-copilot` and `pi-copilot-gpt`: Pi on the Copilot pool, running Claude Opus and GPT, with read-only file tools and no shell.
  - Neither is in the default list. Name one in `SECOND_OPINION_MODELS` to use it, such as `claude pi-copilot-gpt codex`, which sends a Claude session's review to GPT on Copilot before `codex`.
  - Each comes with its command, declared model, inline diff and a room check through agent-runtime's `agent-runtime accounts pick --env`, so it needs no other key.
  - An entry is skipped when pi is not installed, when agent-runtime is not installed in the project, when the skill is installed in no repository, such as a global install, or when the room check refuses.
  - Setting an entry's `_CMD` replaces its stock model, room check and inline diff with that entry's own settings.
- `SECOND_OPINION_<NAME>_ROOM_CMD`: a command judging whether the account an entry spends has room, such as agent-runtime's `agent-runtime accounts pick --env`. Set empty, the entry has no check.
  - A walled entry is skipped for the next one, so a Copilot entry can stand in while the Codex seats are walled.
  - The entry runs on the account the check names.
  - A check whose program is not installed is unavailable, never room.
- `SECOND_OPINION_<NAME>_INLINE_DIFF`: set to `1` to include the diff in a target's review prompt. Any other set value turns it off. `second-opinion --help` gives the defaults and the size cap.
- `SECOND_OPINION_CURRENT_MODEL`: the session model, required in Pi, OpenCode, Cursor, Copilot or an undetected shell. Never store it in a project file.

## Licence

MIT, in the repository's LICENSE file.
