---
name: second-opinion
description: "Cross-model second opinion: review, challenge, audit, and consult via an external AI CLI (Claude ↔ Codex)."
license: MIT
user-invocable: true
argument-hint: "review [scope] | challenge [description] | audit [path] | quick [question]"
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# Second Opinion

Cross-model second opinion via external AI CLI. Auto-detects the current harness and calls the opposite:

| Running in | Calls |
|------------|-------|
| Claude Code | Codex |
| Codex | Claude |
| Pi | Claude |
| OpenCode / Cursor / unknown | Claude (prefers cross-model) |

Override with `SECOND_OPINION_TARGET=claude|codex` in committed `vstack.settings.toml` for shared defaults, or `.env.local` for personal overrides.

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
| `detect` | (built-in) | Target CLI name |

**Timestamp is wrapper-stamped.** In `review` and `audit` modes the JSON `timestamp` field is overwritten by the wrapper with its own UTC wall clock (`date -u`) after the model responds — the schema keeps `ISO_8601` only as a hint. The written value therefore reflects when the wrapper produced the artifact, not a value the reviewing model serialized (which could be stale or fabricated). Downstream freshness checks (`orch review-artifact-check --file <path> [delegated_at]`) validate filesystem mtime, and the stamped `timestamp` stays consistent with it.

**Review scope is wrapper-derived.** In `review` mode the wrapper derives the scope from the worktree before invoking the external CLI — current branch, diff range (`--range` or `origin/BASE...HEAD`), diffstat, and the changed-file list are embedded in the prompt, so the external model is never asked to guess its own scope. An empty or invalid diff range fails with exit 3 and writes no artifact — an empty-scope review is an error, not a pass. A response whose `qa_metadata` self-reports that no review happened (`review_performed: false`, or a no-scope/no-review `reason`) is never written to `--output`: the wrapper preserves it as `<output>.noreview.json` and exits 4. `orch review-artifact-check` independently rejects any such artifact with reason `no_review`, regardless of its verdict.

## Common Options

All modes accept:

| Flag | Description |
|------|-------------|
| `--target <name>` | Override target: `claude` or `codex` |
| `--cwd <path>` | Working directory for external CLI (default: `.`) |
| `--timeout <secs>` | CLI timeout in seconds (default: 300) |
| `--output <path>` | Write result to file (review/audit modes) |
| `--prompt <file>` | Prompt file (challenge/audit/quick modes) |
| `--range <ref>` | Git diff range for review (default: `origin/BASE...HEAD`) |

## Execution Rules

- Execute all workflow sections in order. The workflow decides what to skip via "**Skip if**" conditions — never skip based on your own scope assessment.
- `<output_format>` tags are literal templates: fill `[PLACEHOLDERS]`, omit empty lines, add nothing else, do not paraphrase.
- **Pass `--target`** when the user explicitly requests a specific model/CLI (e.g., "use Claude", "ask Codex"). Otherwise omit it — the script auto-detects from the current harness and project config.
- **Do not pass `--timeout`** unless the user explicitly asks for a different value for this specific call — the script reads the default from project config.
- **Always pass `--cwd`** with the absolute project root path. Never use `--cwd .` — the external CLI needs the full path to find project files.
- For `quick` mode, you can pass the question as an inline argument instead of writing a file: `second-opinion quick "your question here" --cwd /path`

## Configuration

Set non-sensitive defaults in `vstack.settings.toml` under `[env]`. Existing `.env.local` and `.env` values still work; `.env.local` wins.

Project installs seed `vstack.settings.toml` from this skill's `vstack.settings.toml.example` when missing and merge only absent second-opinion keys into existing files.

| Variable | Default | Description |
|----------|---------|-------------|
| `SECOND_OPINION_TARGET` | auto-detect | Force target CLI: `claude` or `codex` |
| `SECOND_OPINION_TIMEOUT` | `300` | CLI timeout in seconds |
| `SECOND_OPINION_CLAUDE_CMD` | (see below) | Full `claude` command — all flags |
| `SECOND_OPINION_CODEX_CMD` | (see below) | Full `codex` command — all flags |

### Default commands

**Claude** (called when running from Codex):
```bash
SECOND_OPINION_CLAUDE_CMD="claude -p --no-session-persistence --model opus --effort max --allowedTools Bash(read-only:true),Read,Glob,Grep"
```

**Codex** (called when running from Claude):
```bash
SECOND_OPINION_CODEX_CMD="codex exec -m gpt-5.6-sol -s read-only -c model_reasoning_effort=xhigh --ephemeral"
```

To customize, copy the full command into `vstack.settings.toml` for shared defaults or `.env.local` for personal overrides and edit any flags. The entire variable is used as-is.

## Error Handling

On script failure (non-zero exit), stderr contains a JSON error object:

```json
{"error": "description", "target": "codex"}
```

| Exit code | Meaning | Action |
|-----------|---------|--------|
| 1 | CLI not found, missing prompt, invalid JSON response | Report error to user, suggest checking CLI installation |
| 3 | `review`: derived diff scope is empty or invalid — nothing to review | Report; verify the worktree has committed/pending changes or pass an explicit `--range` |
| 4 | `review`/`audit`: model self-reported no review was performed (`qa_metadata.review_performed: false`) | Report; the response is preserved as `<output>.noreview.json` — never treat it as a pass |
| 124 | Timeout (default 300s) | Report timeout, suggest `--timeout` increase or narrower `--range` |

If the script fails during the orch `review-pr` or `submit-pr` (local pre-PR review) workflows, **continue** — external review is advisory.
