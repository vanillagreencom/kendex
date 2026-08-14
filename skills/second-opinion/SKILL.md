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

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

Cross-model second opinion via external AI CLI. `review` mode is multi-lane: every available lane runs and the findings are unioned — model diversity has different blind spots (contract below). The other modes auto-detect the current harness and call the opposite model: Codex when running in Claude Code; Claude from everywhere else (Codex, Pi, OpenCode, Cursor, unknown — cross-model preferred).

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

**Timestamp is wrapper-stamped.** In `review` and `audit` modes the wrapper overwrites the JSON `timestamp` field with its own UTC wall clock (`date -u`) after the model responds, so it records when the artifact was produced, never a model-serialized value. Downstream freshness checks (`orch review-artifact-check --file <path> [delegated_at]`) validate filesystem mtime, and the stamped `timestamp` stays consistent with it.

**Review is multi-lane by default.** With no `--target` and no `SECOND_OPINION_TARGET`, `review` runs every available lane in `SECOND_OPINION_REVIEW_TARGETS` in parallel on one pinned scope and writes a single union artifact: findings deduplicated across lanes, per-lane provenance in `qa_metadata.lanes`, and — with `--output` — each lane's own artifact kept beside the union as `<output>.<target>.json`. Lane resolution, merge rules, artifact placement and permissions, scratch durability, and the failure taxonomy: [references/multi-lane.md](references/multi-lane.md).

**The review prompt reads the repo's own instruction files.** `review` mode appends, when present, the files matched by the `SECOND_OPINION_REVIEW_INSTRUCTIONS` glob list — default `AGENTS.md`, `review-bots.md`, `.github/instructions/*.instructions.md`, `.github/copilot-instructions.md`, resolved inside `--cwd` — so repo-rule adherence is reviewable locally, same as GitHub bots. When the list carries the literal `AGENTS.md` entry, nested `AGENTS.md` files governing the changed paths are collected too (ancestor-directory walk, same containment and dedupe). Set the variable empty to disable. Matches must be regular files physically inside the reviewed repo: a committed symlink (the file or a parent directory) pointing outside `--cwd` is skipped loudly, never followed — the reviewed checkout is untrusted and must not be able to leak host files into the prompt. The prompt reviews through explicit lenses (correctness, security/fail-open, adversarial inputs, Bash-3.2/portability, repo-rule adherence, docs-vs-code drift, test adequacy); only pure style and naming opinions stay out of scope.

**The artifact records the reviewed head.** `review` mode stamps `qa_metadata.reviewed_head` — the reviewed range's endpoint commit, captured when the scope is derived (before the model runs), never re-sampled from a mutable `HEAD` afterward — so callers can budget review passes **per pushed head** — a new head is a new round — instead of per submission.

**Review scope is wrapper-derived.** In `review` mode the wrapper derives the scope from the worktree before invoking the external CLI — current branch, diff range (`--range` or `origin/BASE...HEAD`), diffstat, and the changed-file list are embedded in the prompt, so the external model is never asked to guess its own scope. A first response that is unparseable, or structurally incomplete, gets one retry resending the full original request (scope block included) alongside the captured response, so the retry session reviews the same scope instead of answering context-free. Unusable responses never become the artifact — see Error Handling. `orch review-artifact-check` independently rejects self-reported no-review artifacts (reason `no_review`) and qa-shaped artifacts missing their finding arrays (reason `incomplete`), regardless of verdict.

## Common Options

All modes accept:

| Flag | Description |
|------|-------------|
| `--target <name>` | Force a single lane: `claude`, `codex`, or any configured target (disables multi-lane review) |
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
| `SECOND_OPINION_TARGET` | (unset) | Force a single target CLI; disables multi-lane review |
| `SECOND_OPINION_TIMEOUT` | `300` | CLI timeout in seconds |
| `SECOND_OPINION_CLAUDE_CMD` | (see below) | Full `claude` command — all flags |
| `SECOND_OPINION_CODEX_CMD` | (see below) | Full `codex` command — all flags |
| `SECOND_OPINION_REVIEW_TARGETS` | `codex claude` | Review lanes, space/comma separated; every available lane runs and findings are unioned |
| `SECOND_OPINION_REVIEW_INSTRUCTIONS` | `AGENTS.md review-bots.md .github/instructions/*.instructions.md .github/copilot-instructions.md` | Instruction-file globs appended to the review prompt, resolved inside `--cwd`; set empty to disable |
| `SECOND_OPINION_<NAME>_CMD` | (none) | Full command for a custom review target `<name>` (uppercased, hyphens as underscores) |

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
| 4 | `review`/`audit`: model self-reported no review was performed (`qa_metadata.review_performed: false`), omitted the required `qa_metadata` object, or stayed structurally incomplete after the one-shot retry (missing `verdict` or the `blockers`/`suggestions`/`questions` arrays) | Report; the response is preserved as `<output>.noreview.json` / `<output>.incomplete.json` — never treat it as a pass |
| 5 | `review`/`audit`: the external CLI never produced a review — non-zero exit (quota, auth, network) or empty response on a zero exit. Distinct from 4: 4 is a model that answered unusably, 5 is a lane that never answered | Report; partial output is preserved as `<output>.failed.json` and the CLI's own error text — from whichever stream it used, stderr or stdout — is echoed on stderr |
| 124 | Timeout (default 300s) | Report timeout, suggest `--timeout` increase or narrower `--range` |

Multi-lane review maps lane failures into the same contract: a failing lane is recorded inside the union artifact (`qa_metadata.lanes`, `coverage: "degraded"`) with the run still exiting 0; only when **every** lane fails does the run exit 4 (at least one lane answered unusably) or 5 (no lane answered), writing no artifact.

If the script fails during the orch `review-pr` or `submit-pr` (local pre-PR review) workflows, **continue** — external review is advisory.
