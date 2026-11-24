---
name: second-opinion
description: "Load for a cross-model review, challenge, audit, or quick consult."
summary: "Cross-model second opinion: review, challenge, audit, and consult through an external AI CLI (Pi on Copilot, Claude and Codex, or one a settings entry names)."
license: MIT
user-invocable: true
argument-hint: "review [scope] | challenge [description] | audit [path] | quick [question]"
dependencies:
  required: [github]
  optional: [agent-runtime]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [review]
---

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

- Execute every section of the workflow in order.
- Never skip a section on your own scope assessment.
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

On a failed run or a refused target, read [references/error-handling.md](references/error-handling.md).
