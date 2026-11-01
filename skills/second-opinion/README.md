# Second Opinion

Code review and consultation through another AI CLI. It lets a project request an independent model's analysis of a change, design or question.

## Features

- Review a branch diff or audit selected code.
- Challenge a proposed approach.
- Ask a focused technical question.
- Collect reviews from multiple configured models.

## Install

```bash
kendex add vanillagreencom/kendex --skill second-opinion
```

## How it works

You select a review, audit, challenge or question. The script identifies the current session model and chooses an eligible external CLI. That CLI reads the requested context and returns its analysis. Reviews and audits are saved in the shared finding format; other modes return text. A review or audit whose CLI fails or is killed keeps a failure record; [SKILL.md § Error Handling](SKILL.md#error-handling) says what it holds.

## Setup

Requires jq, perl and a logged-in external CLI: claude, codex, pi with a Copilot login, or another CLI a settings entry names. kendex also installs github, which carries the shared helper that starts each CLI in its own process group.

Set shared values in `kendex.settings.toml` under `[env]` and personal overrides in `.env.local`; nothing is marked required, so an arrival writes no settings. Every key, its default and the built-in `claude`, `codex`, `pi-copilot` and `pi-copilot-gpt` command lines: `second-opinion --help`. The ones most projects touch:

- `SECOND_OPINION_MODELS`: the ordered fallback list, default `pi-copilot claude pi-copilot-gpt codex`; set empty, the run refuses. Both room-check skips and execution failures advance to the next name. Nonzero exit, timeout and recognized quota/rate-limit refusal on stderr are execution failures. A stderr refusal counts only when stdout holds no usable review answer. Attempts report name, cause and seconds. The script stops when it collects the requested opinions or the list ends. It runs one command at a time. A forced target does not fall through.
- `SECOND_OPINION_COUNT`: opinions a `review` collects, default `1`.
- `SECOND_OPINION_<NAME>_CMD`: the command a roster entry runs; another model CLI is a settings entry, not new code. For a target named `codex` (any case), a command that directly runs `codex` also receives `--disable hooks --json`, including overrides with supported `env` prefixes. Other target names, CLIs and opaque wrappers supply their own backend flags. Keep the sandbox or tool restrictions read-only so a second opinion can never write to your worktree.
- An entry is available when its command's program word is an executable where the command will look for it: the first word, or past a leading `env`, its options and its `VAR=value` assignments, so `env VAR=value copilot ...` is skipped when `copilot` is missing rather than run to fail. The lookup uses the `PATH` and directory the command runs with: `--cwd`, then `env`'s `PATH=`, `-i` or `-u PATH` (the system default `PATH`) and its last `-C DIR`. An `env` option outside those, such as BSD's `-P` or GNU's `-S`, judges the entry on `env` itself. The command runs without a shell, so a leading shell builtin such as `exec` makes the entry unavailable, and a command with no program word after its assignments is skipped the same way.
- `SECOND_OPINION_TIMEOUT`: seconds per CLI invocation, default `1080`.
- `SECOND_OPINION_COPILOT_CMD` and `SECOND_OPINION_COPILOT_MODEL`: a `copilot` entry's command and the model it runs. Copilot CLI documents no read-only headless mode, so there is no built-in command, and it fronts several vendors, so the entry is skipped until the model is named.
- `pi-copilot` and `pi-copilot-gpt`: Pi on the Copilot pool, running Claude Opus and GPT, with read-only file tools and no shell. Each comes with its command, declared model, inline diff and a room check through orch's `lanes pick` at `.agents/skills/orch/scripts/lanes` under the project root, so a Claude session skips `pi-copilot` and reviews on `pi-copilot-gpt` before `codex`. An entry is skipped when pi is not installed, orch is not installed there, or the check refuses. Setting an entry's `_CMD` replaces its stock model, room check and inline diff with that entry's own settings.
- `SECOND_OPINION_<NAME>_ROOM_CMD`: a command judging whether the account an entry spends has room, such as orch's `lanes pick`; set empty, the entry has no check. A walled entry is skipped for the next one, so a Copilot entry can stand in while the Codex seats are walled, and the entry runs on the account the check names. A check whose program is not installed is unavailable, never room.
- `SECOND_OPINION_<NAME>_INLINE_DIFF`: set to `1` for an entry that cannot run git, such as Pi on read-only file tools; its review prompt then carries the diff, up to the cap `second-opinion --help` names. On by default for the stock Copilot entries; any other value turns it off.
- `SECOND_OPINION_CURRENT_MODEL`: the session model, required in Pi, OpenCode, Cursor, Copilot or an undetected shell; never store it in a project file.

## Licence

MIT, in the repository's LICENSE file.
