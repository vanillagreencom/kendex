---
name: second-opinion
description: "Cross-model second opinion: review, challenge, audit, and consult via an external AI CLI (Claude ↔ Codex)."
license: MIT
user-invocable: true
argument-hint: "review [scope] | challenge [description] | audit [path] | quick [question]"
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [review]
---

# Second Opinion

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

Cross-model second opinion via external AI CLI. Every mode walks the `SECOND_OPINION_MODELS` roster in priority order and takes the first target that is available and runs a different model — Codex from a Claude Code session, Claude from a Codex session. When nothing eligible remains the run refuses and says why. `SECOND_OPINION_COUNT` raises the number of opinions a `review` collects; with two or more the lanes run in parallel and the findings are unioned (contract below).

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

**Timestamp and agent are wrapper-stamped.** In `review` and `audit` modes the wrapper overwrites the JSON `timestamp` field with its own UTC wall clock (`date -u`) after the model responds, and overwrites `agent` with `external-<target>` for a lane or `external-union(…)` for a union. Downstream freshness checks (`orch review-artifact-check --file <path> [delegated_at]`) validate filesystem mtime.

**Cross-model is enforced, in every mode.** This session's identity is `SECOND_OPINION_CURRENT_MODEL` when set, else the model the detected harness runs (`claude`, `codex` — the nearest harness ancestor in the process tree, then environment markers); each roster target's identity is `SECOND_OPINION_<NAME>_MODEL`, defaulting to its name. A target whose identity equals the session's is skipped loudly — `--target` and `SECOND_OPINION_TARGET` included — and a run with no eligible target exits 1 with every candidate and its reason, writing nothing and invoking nothing. A multi-model front end (Pi, OpenCode, Cursor) or an undetected harness with no `SECOND_OPINION_CURRENT_MODEL` is refused the same way — set it to the model the session runs, or to `none` when there is no session model (CI, a plain terminal), **in that session's environment**. **A positively detected single-model harness beats any contradicting declaration, whatever its source**: a declaration that canonicalizes to a different identity than the detected harness is refused, naming both values and where the declaration came from; one that agrees is not used. Where detection cannot arbitrate (Pi, OpenCode, Cursor, undetected), only a value in the session's own environment counts — one from a project settings file (`.env`, `kendex.settings.toml`, `.kendex/settings.toml`, `.env.local`) is refused, naming the file. Declared values normalize from model ids, provider prefix and all, and surrounding whitespace is ignored (`opus`, `claude-opus-5`, `anthropic/claude-opus-4`, `  claude ` → `claude`; `gpt-5.6-sol`, `openai-codex/gpt-5.6-sol` → `codex`); a **declared** identity the roster does not spell is refused — name the model in `SECOND_OPINION_MODELS` (a command is optional) or fix the declaration. A *detected* identity the roster does not name excludes nothing and the walk proceeds.

**Multi-lane review is opt-in breadth.** With `SECOND_OPINION_COUNT` of 2 or more, `review` takes up to that many distinct eligible models from the roster, runs them in parallel on one pinned scope, and writes a single union artifact: findings deduplicated across lanes, per-lane provenance in `qa_metadata.lanes`, and — with `--output` — each lane's own artifact kept beside the union as `<output>.<target>.json`. Lane resolution, merge rules, artifact placement and permissions, scratch durability, and the failure taxonomy: [references/multi-lane.md](references/multi-lane.md).

**The review prompt reads the repo's own instruction files.** `review` mode appends, when present, the files matched by the `SECOND_OPINION_REVIEW_INSTRUCTIONS` glob list — default `AGENTS.md`, `review-bots.md`, `.github/instructions/*.instructions.md`, `.github/copilot-instructions.md`, resolved inside `--cwd`. When the list carries the literal `AGENTS.md` entry, nested `AGENTS.md` files governing the changed paths are collected too (ancestor-directory walk, same containment and dedupe). Set the variable empty to disable. Matches must be regular files physically inside the reviewed repo: a committed symlink (the file or a parent directory) pointing outside `--cwd` is skipped loudly, never followed. The prompt reviews through explicit lenses (correctness, security/fail-open, adversarial inputs, Bash-3.2/portability, repo-rule adherence, docs-vs-code drift, test adequacy); only pure style and naming opinions stay out of scope.

**The artifact records the reviewed head.** `review` mode stamps `qa_metadata.reviewed_head` — the reviewed range's endpoint commit, captured when the scope is derived (before the model runs). Callers budget review passes **per pushed head** — a new head is a new round.

**Review scope is wrapper-derived.** In `review` mode the wrapper derives the scope from the worktree before invoking the external CLI — current branch, diff range (`--range` or `origin/BASE...HEAD`), diffstat, and the changed-file list are embedded in the prompt. A first response that is unparseable, or structurally incomplete, gets one retry resending the full original request (scope block included) alongside the captured response. Unusable responses never become the artifact — see Error Handling. `orch review-artifact-check` independently rejects self-reported no-review artifacts (reason `no_review`) and qa-shaped artifacts missing their finding arrays (reason `incomplete`), regardless of verdict.

## Common Options

All modes accept:

| Flag | Description |
|------|-------------|
| `--target <name>` | Force one target: `claude`, `codex`, or any configured target; refused when it runs this session's model |
| `--cwd <path>` | Working directory for external CLI (default: `.`) |
| `--timeout <secs>` | CLI timeout in seconds (default: 1080) |
| `--output <path>` | Write result to file (review/audit modes) |
| `--prompt <file>` | Prompt file (challenge/audit/quick modes) |
| `--range <ref>` | Git diff range for review (default: `origin/BASE...HEAD`) |

## Execution Rules

- Execute all workflow sections in order. The workflow decides what to skip via "**Skip if**" conditions — never skip based on your own scope assessment.
- `<output_format>` tags are literal templates: fill `[PLACEHOLDERS]`, omit empty lines, add nothing else, do not paraphrase.
- **Pass `--target`** when the user explicitly requests a specific model/CLI (e.g., "use Claude", "ask Codex"). Otherwise omit it — the script selects from the roster and the current session's model. A forced target that runs this session's model is refused; report the refusal, do not work around it.
- **Do not pass `--timeout`** unless the user explicitly asks for a different value for this specific call — the script reads the default from project config.
- **Always pass `--cwd`** with the absolute project root path. Never use `--cwd .`.
- For `quick` mode, you can pass the question as an inline argument instead of writing a file: `second-opinion quick "your question here" --cwd /path`

## Configuration

Set non-sensitive defaults in `kendex.settings.toml` under `[env]`. Existing `.env.local` and `.env` values still work; `.env.local` wins. The one exception is `SECOND_OPINION_CURRENT_MODEL` — export it in the environment of the session that needs it; a value in any project file (`.env`, `kendex.settings.toml`, `.kendex/settings.toml`, `.env.local`) is refused.

Project installs seed `kendex.settings.toml` from this skill's `kendex.settings.toml.example` when missing and merge only absent second-opinion keys into existing files.

| Variable | Default | Description |
|----------|---------|-------------|
| `SECOND_OPINION_MODELS` | `claude codex` | Priority-ordered target roster, space/comma separated; the first eligible entry wins. Set to the empty string it names no targets and the run refuses — unset it to get the default back |
| `SECOND_OPINION_COUNT` | `1` | Opinions a `review` collects — up to N distinct eligible models, unioned; a shortfall is stated on stderr and stamped as `qa_metadata.requested_count`/`selected_count` with `coverage: "degraded"` |
| `SECOND_OPINION_CURRENT_MODEL` | (unset) | Model identity of this session. A **detected** `claude`/`codex` harness outranks it: an agreeing value is ignored, a contradicting one is refused naming both values. **Export it in that session, never in `.env`, `kendex.settings.toml`, `.kendex/settings.toml` or `.env.local`** (a value from one is refused naming the file). Required in Pi/OpenCode/Cursor and undetected shells; `none` = no session model. Model ids normalize; a value the roster does not know is refused |
| `SECOND_OPINION_<NAME>_MODEL` | `<name>` | Model identity of roster target `<name>` (uppercased, hyphens as underscores) |
| `SECOND_OPINION_<NAME>_CMD` | (none) | Full command for roster target `<name>`; `claude` and `codex` have built-in defaults (below) |
| `SECOND_OPINION_TARGET` | (unset) | Force one target; still subject to self-exclusion |
| `SECOND_OPINION_TIMEOUT` | `1080` | CLI timeout in seconds, per invocation: `review`/`audit`'s one retry on a malformed response gets a fresh window, so a lane can run up to twice this. The default exceeds the ~600s ceiling most agent harnesses put on a foreground shell call: run the script in the background, or pass `--timeout` at or below that ceiling |
| `SECOND_OPINION_ARTIFACT_DIR` | `tmp/second-opinion` | Home for `review`/`audit` records written without `--output` (preserved raw, failed, and rejected responses), and for a multi-lane stdout run's per-lane review artifacts; relative to `--cwd`, `~/…` and absolute paths taken as given. Created owner-only when absent, seeded with a `*` `.gitignore`; a relative home that is a symlink or resolves outside `--cwd`, or one that cannot be created, falls back to a temp file, loudly, without changing the exit code. `--output` is the explicit override for the artifact itself |
| `SECOND_OPINION_REVIEW_INSTRUCTIONS` | `AGENTS.md review-bots.md .github/instructions/*.instructions.md .github/copilot-instructions.md` | Instruction-file globs appended to the review prompt, resolved inside `--cwd`; set empty to disable |

### Default commands

**Claude** (identity `claude`):
```bash
SECOND_OPINION_CLAUDE_CMD="claude -p --no-session-persistence --model opus --effort max --allowedTools Bash(read-only:true),Read,Glob,Grep"
```

**Codex** (identity `codex`):
```bash
SECOND_OPINION_CODEX_CMD="codex exec -m gpt-5.6-sol -s read-only -c model_reasoning_effort=xhigh --ephemeral"
```

To customize, copy the full command into `kendex.settings.toml` for shared defaults or `.env.local` for personal overrides and edit any flags. The entire variable is used as-is.

## Error Handling

On script failure (non-zero exit), stderr contains a JSON error object:

```json
{"error": "description", "target": "codex"}
```

| Exit code | Meaning | Action |
|-----------|---------|--------|
| 1 | No eligible cross-model target (the error lists every candidate and why), CLI not found, missing prompt, invalid JSON response, **or any `challenge`/`quick` CLI failure including timeout** | Report the stated reason. Candidates skipped for **availability** are fixed by installing the CLI or setting its `SECOND_OPINION_<NAME>_CMD`; candidates skipped for **identity** by `SECOND_OPINION_MODELS` / `SECOND_OPINION_CURRENT_MODEL`. Never by forcing the same model |
| 3 | `review`: derived diff scope is empty or invalid — nothing to review | Report; verify the worktree has committed/pending changes or pass an explicit `--range` |
| 4 | `review`/`audit`: model self-reported no review was performed (`qa_metadata.review_performed: false`), omitted the required `qa_metadata` object, or stayed structurally incomplete after the one-shot retry (missing `verdict` or the `blockers`/`suggestions`/`questions` arrays) | Report; the response is preserved as `<output>.noreview.json` / `<output>.incomplete.json` (under `SECOND_OPINION_ARTIFACT_DIR` without `--output`; a multi-lane stdout run keeps no lane records — see references/multi-lane.md) — never treat it as a pass |
| 5 | `review`/`audit`: the external CLI never produced a review — non-zero exit (quota, auth, network), **timeout** (`--timeout`, default 1080s; `challenge`/`quick` exit 1 instead), or empty response on a zero exit | Report; partial output is preserved as `<output>.failed.json` (under `SECOND_OPINION_ARTIFACT_DIR` without `--output`; a multi-lane stdout run keeps no lane records — see references/multi-lane.md) and the CLI's own error text is echoed on stderr. For a timeout, suggest a larger `--timeout` or a narrower `--range` |

**No exit leaves a previous run's output behind.** Every mode that writes `--output` — `review`, `audit`, `challenge`, `quick` — clears that path as soon as the arguments are read (ahead of a bad-flag error, the `jq` check, the mode check, `--timeout` validation, target selection, or any CLI run), together with the sidecar records that mode can produce: `review` and `audit` add `.raw.txt`, `.retry.txt`, `.failed.json`, `.noreview.json` and `.incomplete.json`; `challenge` and `quick` clear their output path alone. `--help` and `detect` clear nothing.

**One rule governs every deletion:** a path is removed unconditionally only when *this* run will write it (`--output` itself, and each `<output>.<lane>.json` a multi-lane run is about to write); anything else must first prove the skill wrote it — the review schema **plus** the `external-…` agent marker. That applies to roster-named siblings too: at the default `SECOND_OPINION_COUNT=1` a run writes no lane file, so `<output>.codex.json` holding your data survives. The ownership check **requires `jq`**: without it the designated output is still cleared, but sibling lane artifacts are left alone and the run says so on stderr before exiting on the missing dependency. A sibling sharing only the name shape (`<output>.notes.json`), or sharing the *schema* under another agent (an internal `reviewer-*` artifact), is never touched.

Options take their value in either form, `--opt VALUE` or `--opt=VALUE`; the split form refuses a value that begins with `-`, so a dash-leading path is passed as `--output=-report.json`.

Runtime failures emit the JSON error object above; pre-flight configuration errors — unknown flag, an option missing its value, missing mode, non-integer `--timeout` or `SECOND_OPINION_COUNT`, missing `jq`, a directory or an uncreatable parent at `--output`, a missing `--cwd` — are plain `Error:` lines on stderr with exit 1.

Multi-lane review maps lane failures into the same contract: a failing lane is recorded inside the union artifact (`qa_metadata.lanes`, `coverage: "degraded"`) with the run still exiting 0; only when **every** lane fails does the run exit 4 (at least one lane answered unusably) or 5 (no lane answered), writing no artifact.

If the script fails during the orch `review-pr` or `submit-pr` (local pre-PR review) workflows, **continue** — external review is advisory.
