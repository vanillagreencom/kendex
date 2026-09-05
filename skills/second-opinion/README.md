# Second Opinion

Code review and consultation through another AI CLI. It lets a project request an independent model's analysis of a change, design or question.

## Install

```bash
kendex add vanillagreencom/kendex --skill second-opinion
```

Requires jq and a logged-in external CLI, claude or codex.

## Features

- Review a branch diff or audit selected code.
- Challenge a proposed approach.
- Ask a focused technical question.
- Collect reviews from multiple configured models.

## How it works

You select a review, audit, challenge or question. The script identifies the current session model and chooses an eligible external CLI. That CLI reads the requested context and returns its analysis. Reviews and audits are saved in the shared finding format; other modes return text.

## Settings

Set shared values in `kendex.settings.toml` under `[env]` and personal overrides in `.env.local`; nothing is marked required, so an install writes no settings. Every key, its default and the built-in `claude` and `codex` command lines: `second-opinion --help`. The ones most projects touch:

- `SECOND_OPINION_MODELS`: the priority-ordered roster, default `claude codex`.
- `SECOND_OPINION_COUNT`: opinions a `review` collects, default `1`.
- `SECOND_OPINION_<NAME>_CMD`: the full command a roster entry runs; another model CLI is a settings entry, not new code. Keep the sandbox read-only so a second opinion can never write to your worktree.
- `SECOND_OPINION_TIMEOUT`: seconds per CLI invocation, default `1080`.
- `SECOND_OPINION_CURRENT_MODEL`: the session model, required in Pi, OpenCode, Cursor or an undetected shell; never store it in a project file.
