# Second Opinion

Code review and consultation through another AI CLI. It lets a project request an independent model's analysis of a change, design or question.

## Install

```bash
kendex add vanillagreencom/kendex --skill second-opinion
```

Requires jq, perl and a logged-in external CLI, claude or codex, or another CLI a settings entry names. kendex also installs github, which carries the shared helper that starts each CLI in its own process group.

## Features

- Review a branch diff or audit selected code.
- Challenge a proposed approach.
- Ask a focused technical question.
- Collect reviews from multiple configured models.

## How it works

You select a review, audit, challenge or question. The script identifies the current session model and chooses an eligible external CLI. That CLI reads the requested context and returns its analysis. Reviews and audits are saved in the shared finding format; other modes return text.

## Settings

Set shared values in `kendex.settings.toml` under `[env]` and personal overrides in `.env.local`; nothing is marked required, so an install writes no settings. Every key, its default and the built-in `claude` and `codex` command lines: `second-opinion --help`. The ones most projects touch:

- `SECOND_OPINION_MODELS`: the ordered fallback list, default `claude codex`. Both room-check skips and execution failures advance to the next name. Nonzero exit, timeout and recognized quota/rate-limit refusal on stderr are execution failures. A stderr refusal counts only when stdout holds no usable review answer. Attempts report name, cause and seconds. The script stops when it collects the requested opinions or the list ends. It runs one command at a time. A forced target does not fall through.
- `SECOND_OPINION_COUNT`: opinions a `review` collects, default `1`.
- `SECOND_OPINION_<NAME>_CMD`: the full command a roster entry runs; another model CLI is a settings entry, not new code. Keep the sandbox read-only so a second opinion can never write to your worktree.
- `SECOND_OPINION_TIMEOUT`: seconds per CLI invocation, default `1080`.
- `SECOND_OPINION_COPILOT_CMD` and `SECOND_OPINION_COPILOT_MODEL`: a `copilot` entry's command and the model it runs. Copilot CLI documents no read-only headless mode, so there is no built-in command, and it fronts several vendors, so the entry is skipped until the model is named.
- `SECOND_OPINION_<NAME>_ROOM_CMD`: a command judging whether the account an entry spends has room, such as orch's `lanes pick`. A walled entry is skipped for the next one, so a Copilot entry can stand in while the Codex seats are walled, and the entry runs on the account the check names.
- `SECOND_OPINION_<NAME>_INLINE_DIFF`: set to `1` for an entry that cannot run git, such as Pi on read-only file tools; its review prompt then carries the diff, up to the cap `second-opinion --help` names.
- `SECOND_OPINION_CURRENT_MODEL`: the session model, required in Pi, OpenCode, Cursor, Copilot or an undetected shell; never store it in a project file.
