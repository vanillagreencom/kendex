---
name: second-opinion
description: "Load for a cross-model review, challenge, audit, or quick consult."
license: MIT
user-invocable: true
argument-hint: "review [scope] | challenge [description] | audit [path] | quick [question]"
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Second Opinion

Cross-model second opinion via external AI CLI. Full contract: `second-opinion --help`.

```bash
.agents/skills/second-opinion/scripts/second-opinion <mode> [options]
```

## Workflows

| Command | Workflow | Output |
|---------|----------|--------|
| `review [scope]` | [workflows/review.md](workflows/review.md) | Review finding JSON |
| `challenge [description]` | [workflows/challenge.md](workflows/challenge.md) | Structured critique (text) |
| `audit [path]` | [workflows/audit.md](workflows/audit.md) | Review finding JSON |
| `quick [question]` | [workflows/quick.md](workflows/quick.md) | Text response |
| `detect` | (built-in) | Target name(s) a review would run |

## Execution Rules

- `<output_format>` tags are literal templates:
  - Fill `[PLACEHOLDERS]`.
  - Omit empty lines.
  - Add nothing else.
  - Do not paraphrase.
- **Pass `--target`** only when the user explicitly requests a specific model or CLI, such as "use Claude" or "ask Codex". Otherwise omit it. The script selects from the roster and the current session's model.
- A forced target that runs this session's model is refused. Report the refusal. Do not work around it.
- **Do not pass `--timeout`** unless the user explicitly asks for a different value for this specific call.
- **Always pass `--cwd`** with the absolute project root path. Never use `--cwd .`.
- Pass `--foreground` when the call can outlast the harness foreground cap. The script then detaches and prints its artifact, deadline and wait command.

## Session identity

- In a multi-model front end (Pi, OpenCode, Cursor, Copilot) or an undetected harness, export `SECOND_OPINION_CURRENT_MODEL` in that session's own environment.
- Set it to `none` when the session has no model.
- Never set it in a project settings file.

Identity resolution, normalization and the refusal rules: `second-opinion --help`.

## Multi-lane review

With `SECOND_OPINION_COUNT` of 2 or more, `review` collects that many distinct opinions on one scope and writes one union artifact. Lane resolution, the union's fields, artifact placement and the failure classes: [references/multi-lane.md](references/multi-lane.md).

## Configuration

- Set non-sensitive defaults in `kendex.settings.toml` under `[env]`. `.env.local` wins over it, and a `.env` file is never read.
- Set a key there only to change a default the scripts already read. `SECOND_OPINION_TARGET` has no default.

Keys, defaults and the built-in commands: `second-opinion --help`.

## Error Handling

- On a script failure, report the reason it states. Error forms, exit codes and preserved-response paths: `second-opinion --help`.
- A CLI-failure record, `<output>.failed.json` at exit 5 or 6, holds the reason, the cause with its source, the partial output and each attempt.

Fix each reason a refused candidate names as follows:

- An ineligible target: install its CLI, or adjust `SECOND_OPINION_<NAME>_CMD`, `SECOND_OPINION_MODELS` or `SECOND_OPINION_CURRENT_MODEL`. Never force the same model.
- `model undeclared`: set that target's `SECOND_OPINION_<NAME>_MODEL` to the model id it runs.
- `room check refused`: the candidate names the check's setting and its exit. For a stock Copilot entry it quotes the default command. The check's own stderr, passed through above it, holds the cause.
  1. Run that command.
  2. Read its keyed line: a wall to wait out, or a setting or read to fix. For the stock check, `agent-runtime accounts pick --help` gives them.
- `room check printed a line that is no NAME=value assignment`: the candidate quotes that line. The check must print only the `NAME=value` env prefix of the account it judged. Fix that `SECOND_OPINION_<NAME>_ROOM_CMD` command, for example by dropping a `--json` flag.
- `room check unavailable`: the candidate quotes the check's command.
  - Install its program. For a stock Copilot entry, that is agent-runtime in the project this skill is installed in. A global install has no project, so there its check is always unavailable.
  - Or set that entry's `SECOND_OPINION_<NAME>_ROOM_CMD` or `_CMD`.
  - Or leave the entry out of `SECOND_OPINION_MODELS`.
  - The next roster entry reviews meanwhile. Never remove the room check to get past it.

For a timeout, suggest a larger `--timeout` or a narrower `--range`.
