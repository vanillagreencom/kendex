---
name: second-opinion
description: "Load for a cross-model review, challenge, audit, or quick consult."
summary: "Cross-model second opinion: review, challenge, audit, and consult through an external AI CLI (Claude and Codex, or one a settings entry names)."
license: MIT
user-invocable: true
argument-hint: "review [scope] | challenge [description] | audit [path] | quick [question]"
dependencies:
  required: [github]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [review]
---

# Second Opinion

Cross-model second opinion via external AI CLI. Every mode walks the `SECOND_OPINION_MODELS` roster in priority order and takes the first target that is available, runs a different model and, where it has a room check, has room on its account: Codex from a Claude Code session, Claude from a Codex session; when nothing eligible remains the run refuses and says why. Full contract: `second-opinion --help`.

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

- Execute all workflow sections in order. The workflow decides what to skip via "**Skip if**" conditions. Never skip based on your own scope assessment.
- `<output_format>` tags are literal templates: fill `[PLACEHOLDERS]`, omit empty lines, add nothing else, do not paraphrase.
- **Pass `--target`** when the user explicitly requests a specific model/CLI (e.g., "use Claude", "ask Codex"). Otherwise omit it. The script selects from the roster and the current session's model. A forced target that runs this session's model is refused; report the refusal, do not work around it.
- **Do not pass `--timeout`** unless the user explicitly asks for a different value for this specific call. The script reads the default from project config.
- **Always pass `--cwd`** with the absolute project root path. Never use `--cwd .`.
- Pass `--foreground` when the call can outlast the harness foreground cap. This detaches the run and prints its artifact, deadline, and wait command.
- Execute the exact printed wait command and follow its exit handling in `second-opinion --help` until terminal.
- For `quick` mode, you can pass the question inline: `.agents/skills/second-opinion/scripts/second-opinion quick "your question here" --cwd /path --foreground`.

## Session identity

Cross-model is enforced in every mode: a run with no eligible target exits 1 naming every candidate and its reason, writing nothing and invoking nothing. In a multi-model front end (Pi, OpenCode, Cursor, Copilot) or an undetected harness, export `SECOND_OPINION_CURRENT_MODEL` in that session's own environment (`none` when there is no session model), never in a project settings file. Identity resolution, normalization, and the refusal rules: `second-opinion --help`.

## Multi-lane review

The `SECOND_OPINION_MODELS` order is the fallback order at both the room check and execution. A nonzero exit, per-CLI timeout or recognized quota/rate-limit refusal on stderr advances to the next name. Each attempt records its name, cause and seconds. A failed attempt does not exclude another entry running that model. Forced targets do not fall through.

`SECOND_OPINION_COUNT` of 2 or more makes `review` collect that many distinct eligible opinions in order on one pinned scope and write a single union artifact. Collection stops when the count is met or the list ends. Lane resolution, merge rules, artifact placement and permissions, scratch durability, and the failure taxonomy: [references/multi-lane.md](references/multi-lane.md).

## Configuration

Set non-sensitive defaults in `kendex.settings.toml` under `[env]`; `.env.local` wins over it, and a `.env` file is never read. `SECOND_OPINION_FOREGROUND_CAP` is session-only; a project-file foreground-cap declaration is refused, and shipped workflows pass `--foreground` directly. This skill marks no key `# required`, so an install writes nothing into `kendex.settings.toml`; assign a key there only to change a default the scripts already read (`SECOND_OPINION_TARGET` has none). Keys, defaults, and the built-in `claude`/`codex` commands: `second-opinion --help`. A target named for a harness that fronts a selectable model, `copilot` among them, runs only once its `SECOND_OPINION_<NAME>_MODEL` is set. `SECOND_OPINION_<NAME>_ROOM_CMD` gives a target a room check, such as the orch skill's `lanes pick` for the seat it spends: a target whose check refuses is skipped for the next roster entry, and one with room runs under the account prefix the check printed. `SECOND_OPINION_<NAME>_INLINE_DIFF` set to `1` sends a target that cannot run git, such as Pi on read-only file tools, the review diff inside its prompt.

## Error Handling

On script failure, stderr carries a JSON error object (`{"error": "description", "target": "codex"}`) or a plain `Error:` line for pre-flight configuration errors; exit codes, preserved-response paths, and the output-clearing/ownership rules are in `second-opinion --help`. Report the stated reason. An ineligible-target refusal is fixed by installing the CLI or adjusting `SECOND_OPINION_<NAME>_CMD`, `SECOND_OPINION_MODELS`, or `SECOND_OPINION_CURRENT_MODEL`, never by forcing the same model; a roster target skipped as `model undeclared` is fixed by setting that target's `SECOND_OPINION_<NAME>_MODEL` to the model id it runs. A `room check refused` candidate names the check's setting and its exit; the check's own stderr, passed through above it, holds the cause. Run that `SECOND_OPINION_<NAME>_ROOM_CMD` command and read its keyed line: a wall to wait out, or a setting or read to fix (for orch's check, `lanes pick --help`). A `room check printed a line that is no NAME=value assignment` candidate quotes that line: the check must print only the `NAME=value` env prefix of the account it judged, so fix that `SECOND_OPINION_<NAME>_ROOM_CMD` command, e.g. drop a `--json` flag. The next roster entry reviews meanwhile; never remove the room check to get past it. For a timeout, suggest a larger `--timeout` or a narrower `--range`.

If the script fails during the orch `review-pr` or `submit-pr` (local pre-PR review) workflows, **continue**. External review is advisory.
