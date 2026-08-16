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

Cross-model second opinion via external AI CLI. The guarantee is that the model this session runs is never asked to second-guess its own work: every mode walks the `SECOND_OPINION_MODELS` roster in priority order and takes the first target that is available and runs a different model — Codex from a Claude Code session, Claude from a Codex session. When nothing eligible remains the run refuses and says why. Breadth is opt-in: `SECOND_OPINION_COUNT` raises the number of opinions a `review` collects, and with two or more the lanes run in parallel and the findings are unioned (contract below).

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

**Timestamp and agent are wrapper-stamped.** In `review` and `audit` modes the wrapper overwrites the JSON `timestamp` field with its own UTC wall clock (`date -u`) after the model responds, so it records when the artifact was produced, never a model-serialized value. It overwrites `agent` the same way — `external-<target>` for a lane, `external-union(…)` for a union — so the marker is this skill's assertion of authorship rather than something a provider may omit or get wrong, and every artifact it writes is one its own cleanup can later recognize. Downstream freshness checks (`orch review-artifact-check --file <path> [delegated_at]`) validate filesystem mtime, and the stamped `timestamp` stays consistent with it.

**Cross-model is enforced, in every mode.** Identity is model-level and declared, not inferred from the CLI: this session's identity is `SECOND_OPINION_CURRENT_MODEL` when set, else the model the detected harness runs (`claude`, `codex` — the nearest harness ancestor in the process tree, then environment markers); each roster target's identity is `SECOND_OPINION_<NAME>_MODEL`, defaulting to its name. A target whose identity equals the session's is skipped loudly — `--target` and `SECOND_OPINION_TARGET` included — and a run with no eligible target exits 1 with every candidate and its reason, writing nothing and invoking nothing. A multi-model front end (Pi, OpenCode, Cursor) or an undetected harness with no `SECOND_OPINION_CURRENT_MODEL` has no identity to compare and is refused the same way — set it to the model the session runs, or to `none` when there is no session model (CI, a plain terminal), **in that session's environment**. **A positively detected single-model harness beats any contradicting declaration, whatever its source.** A `claude` or `codex` harness is direct evidence about *this* process; a declaration is a variable, and variables are inherited — a Claude session that exports one and starts a nested Codex session leaks it there. So a declaration that canonicalizes to a different identity than the detected harness is refused, naming both values and where the declaration came from; one that agrees changes nothing and is simply not used. Source decides only where detection *cannot* arbitrate (Pi, OpenCode, Cursor, undetected): there the declaration is the only identity available, and only a value in the session's own environment is a statement about this session — one from a project settings file (`.env`, `vstack.settings.toml`, `.vstack/settings.toml`, `.env.local`) is read by every session in the repo and is refused, naming the file. Declared values normalize from model ids, provider prefix and all, and surrounding whitespace is ignored (`opus`, `claude-opus-5`, `anthropic/claude-opus-4`, `  claude ` → `claude`; `gpt-5.6-sol`, `openai-codex/gpt-5.6-sol` → `codex`); a **declared** identity the roster does not spell is refused too — name the model in `SECOND_OPINION_MODELS` (a command is optional) or fix the declaration. A *detected* identity the roster does not name excludes nothing and the walk proceeds: the roster is the priority list of review targets, so naming only the cross-model one is a valid configuration.

**Multi-lane review is opt-in breadth.** With `SECOND_OPINION_COUNT` of 2 or more, `review` takes up to that many distinct eligible models from the roster, runs them in parallel on one pinned scope, and writes a single union artifact: findings deduplicated across lanes, per-lane provenance in `qa_metadata.lanes`, and — with `--output` — each lane's own artifact kept beside the union as `<output>.<target>.json`. Lane resolution, merge rules, artifact placement and permissions, scratch durability, and the failure taxonomy: [references/multi-lane.md](references/multi-lane.md).

**The review prompt reads the repo's own instruction files.** `review` mode appends, when present, the files matched by the `SECOND_OPINION_REVIEW_INSTRUCTIONS` glob list — default `AGENTS.md`, `review-bots.md`, `.github/instructions/*.instructions.md`, `.github/copilot-instructions.md`, resolved inside `--cwd` — so repo-rule adherence is reviewable locally, same as GitHub bots. When the list carries the literal `AGENTS.md` entry, nested `AGENTS.md` files governing the changed paths are collected too (ancestor-directory walk, same containment and dedupe). Set the variable empty to disable. Matches must be regular files physically inside the reviewed repo: a committed symlink (the file or a parent directory) pointing outside `--cwd` is skipped loudly, never followed — the reviewed checkout is untrusted and must not be able to leak host files into the prompt. The prompt reviews through explicit lenses (correctness, security/fail-open, adversarial inputs, Bash-3.2/portability, repo-rule adherence, docs-vs-code drift, test adequacy); only pure style and naming opinions stay out of scope.

**The artifact records the reviewed head.** `review` mode stamps `qa_metadata.reviewed_head` — the reviewed range's endpoint commit, captured when the scope is derived (before the model runs), never re-sampled from a mutable `HEAD` afterward — so callers can budget review passes **per pushed head** — a new head is a new round — instead of per submission.

**Review scope is wrapper-derived.** In `review` mode the wrapper derives the scope from the worktree before invoking the external CLI — current branch, diff range (`--range` or `origin/BASE...HEAD`), diffstat, and the changed-file list are embedded in the prompt, so the external model is never asked to guess its own scope. A first response that is unparseable, or structurally incomplete, gets one retry resending the full original request (scope block included) alongside the captured response, so the retry session reviews the same scope instead of answering context-free. Unusable responses never become the artifact — see Error Handling. `orch review-artifact-check` independently rejects self-reported no-review artifacts (reason `no_review`) and qa-shaped artifacts missing their finding arrays (reason `incomplete`), regardless of verdict.

## Common Options

All modes accept:

| Flag | Description |
|------|-------------|
| `--target <name>` | Force one target: `claude`, `codex`, or any configured target; refused when it runs this session's model |
| `--cwd <path>` | Working directory for external CLI (default: `.`) |
| `--timeout <secs>` | CLI timeout in seconds (default: 300) |
| `--output <path>` | Write result to file (review/audit modes) |
| `--prompt <file>` | Prompt file (challenge/audit/quick modes) |
| `--range <ref>` | Git diff range for review (default: `origin/BASE...HEAD`) |

## Execution Rules

- Execute all workflow sections in order. The workflow decides what to skip via "**Skip if**" conditions — never skip based on your own scope assessment.
- `<output_format>` tags are literal templates: fill `[PLACEHOLDERS]`, omit empty lines, add nothing else, do not paraphrase.
- **Pass `--target`** when the user explicitly requests a specific model/CLI (e.g., "use Claude", "ask Codex"). Otherwise omit it — the script selects from the roster and the current session's model. A forced target that runs this session's model is refused; report the refusal, do not work around it.
- **Do not pass `--timeout`** unless the user explicitly asks for a different value for this specific call — the script reads the default from project config.
- **Always pass `--cwd`** with the absolute project root path. Never use `--cwd .` — the external CLI needs the full path to find project files.
- For `quick` mode, you can pass the question as an inline argument instead of writing a file: `second-opinion quick "your question here" --cwd /path`

## Configuration

Set non-sensitive defaults in `vstack.settings.toml` under `[env]`. Existing `.env.local` and `.env` values still work; `.env.local` wins. The one exception is `SECOND_OPINION_CURRENT_MODEL` — export it in the environment of the session that needs it; a value in any project file (`.env`, `vstack.settings.toml`, `.vstack/settings.toml`, `.env.local`) is refused.

Project installs seed `vstack.settings.toml` from this skill's `vstack.settings.toml.example` when missing and merge only absent second-opinion keys into existing files.

| Variable | Default | Description |
|----------|---------|-------------|
| `SECOND_OPINION_MODELS` | `claude codex` | Priority-ordered target roster, space/comma separated; the first eligible entry wins. Set to the empty string it names no targets and the run refuses — unset it to get the default back |
| `SECOND_OPINION_COUNT` | `1` | Opinions a `review` collects — up to N distinct eligible models, unioned; a shortfall is stated on stderr and stamped as `qa_metadata.requested_count`/`selected_count` with `coverage: "degraded"` |
| `SECOND_OPINION_CURRENT_MODEL` | (unset) | Model identity of this session. A **detected** `claude`/`codex` harness outranks it: an agreeing value is ignored, a contradicting one is refused naming both values, whatever its source. Where detection cannot arbitrate it is the only identity there is — **export it in that session, never in `.env`, `vstack.settings.toml`, `.vstack/settings.toml` or `.env.local`**, since those reach every session in the repo and a value from one is refused naming the file. Required in Pi/OpenCode/Cursor and undetected shells (refused until set); `none` = no session model. Model ids normalize; a value the roster does not know is refused |
| `SECOND_OPINION_<NAME>_MODEL` | `<name>` | Model identity of roster target `<name>` (uppercased, hyphens as underscores) |
| `SECOND_OPINION_<NAME>_CMD` | (none) | Full command for roster target `<name>`; `claude` and `codex` have built-in defaults (below) |
| `SECOND_OPINION_TARGET` | (unset) | Force one target; still subject to self-exclusion |
| `SECOND_OPINION_TIMEOUT` | `300` | CLI timeout in seconds |
| `SECOND_OPINION_ARTIFACT_DIR` | `tmp/second-opinion` | Home for `review`/`audit` records written without `--output` (preserved raw, failed, and rejected responses); relative to `--cwd`, `~/…` and absolute paths taken as given. Created owner-only when absent, seeded with a `*` `.gitignore` so records never dirty the reviewed working tree; a relative home that is a symlink or resolves outside `--cwd`, or one that cannot be created, falls back to a temp file, loudly, without changing the exit code — and when nothing is writable at all the cause is reported inline and the exit class still holds. `--output` is the explicit override for the artifact itself |
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

To customize, copy the full command into `vstack.settings.toml` for shared defaults or `.env.local` for personal overrides and edit any flags. The entire variable is used as-is.

## Error Handling

On script failure (non-zero exit), stderr contains a JSON error object:

```json
{"error": "description", "target": "codex"}
```

| Exit code | Meaning | Action |
|-----------|---------|--------|
| 1 | No eligible cross-model target (refused — the error lists every candidate and why), CLI not found, missing prompt, invalid JSON response, **or a `challenge`/`quick` timeout** — those two modes carry no no-verdict contract, so every CLI failure in them is a generic 1 | Report the stated reason. The refusal names its own cause: candidates skipped for **availability** are fixed by installing the CLI or setting its `SECOND_OPINION_<NAME>_CMD`; candidates skipped for **identity** by `SECOND_OPINION_MODELS` / `SECOND_OPINION_CURRENT_MODEL`. Never by forcing the same model |
| 3 | `review`: derived diff scope is empty or invalid — nothing to review | Report; verify the worktree has committed/pending changes or pass an explicit `--range` |
| 4 | `review`/`audit`: model self-reported no review was performed (`qa_metadata.review_performed: false`), omitted the required `qa_metadata` object, or stayed structurally incomplete after the one-shot retry (missing `verdict` or the `blockers`/`suggestions`/`questions` arrays) | Report; the response is preserved as `<output>.noreview.json` / `<output>.incomplete.json` (under `SECOND_OPINION_ARTIFACT_DIR` without `--output`; a multi-lane stdout run keeps no lane records — see references/multi-lane.md) — never treat it as a pass |
| 5 | `review`/`audit`: the external CLI never produced a review — non-zero exit (quota, auth, network), **timeout** (`--timeout`, default 300s; every mode enforces the same limit, but only these two map it to 5 — `challenge`/`quick` exit 1), or empty response on a zero exit. Distinct from 4: 4 is a model that answered unusably, 5 is a lane that never answered | Report; partial output is preserved as `<output>.failed.json` (under `SECOND_OPINION_ARTIFACT_DIR` without `--output`; a multi-lane stdout run keeps no lane records — see references/multi-lane.md) and the CLI's own error text — from whichever stream it used, stderr or stdout — is echoed on stderr. For a timeout, suggest a larger `--timeout` or a narrower `--range` |

**No exit leaves a previous run's output behind.** Every mode that writes `--output` — `review`, `audit`, `challenge`, `quick` — clears that path as soon as the arguments are read, together with exactly the sidecar records that mode can produce: `review` and `audit` add `.raw.txt`, `.retry.txt`, `.failed.json`, `.noreview.json` and `.incomplete.json`, while `challenge` and `quick` preserve no such record and so clear their output path alone — beside *their* `--output` those five names are your files: ahead of a bad-flag error, the `jq` check, the mode check and `--timeout` validation, and before target selection or any CLI run. So a refusal, timeout, or unusable response cannot be read as this run's result by a caller that continues past the advisory non-zero exit. `--output` is a path the caller designated for this run's output, so no question of authorship arises there; `--help` and `detect` never reach the write and clear nothing.

**One rule governs every deletion:** a path is removed unconditionally only when *this* run will write it; anything else must first prove the skill wrote it — the review schema **plus** the `external-…` agent marker. Two paths meet the first half: `--output` itself, and each `<output>.<lane>.json` a multi-lane run is about to write. Every other sibling goes through the ownership check, **including roster-named ones** — at the default `SECOND_OPINION_COUNT=1` a run writes no lane file at all, so `<output>.codex.json` holding your data survives while the same name carrying the skill's marker is reclaimed. That check parses the candidate, so it **requires `jq`**: without it the designated output is still cleared (a path the run writes needs no proof), but sibling lane artifacts cannot be shown to be ours and are left alone — the run says so on stderr before exiting on the missing dependency. A sibling sharing only the name shape (`<output>.notes.json`), or sharing the *schema* under another agent (an internal `reviewer-*` artifact), is never touched.

Runtime failures emit the JSON error object above; pre-flight configuration errors — unknown flag, missing mode, non-integer `--timeout` or `SECOND_OPINION_COUNT`, missing `jq`, a directory or an uncreatable parent at `--output`, a missing `--cwd` — are plain `Error:` lines on stderr with exit 1. They are plain by necessity: they can precede the `jq` dependency check, which is what would format the JSON.

Multi-lane review maps lane failures into the same contract: a failing lane is recorded inside the union artifact (`qa_metadata.lanes`, `coverage: "degraded"`) with the run still exiting 0; only when **every** lane fails does the run exit 4 (at least one lane answered unusably) or 5 (no lane answered), writing no artifact.

If the script fails during the orch `review-pr` or `submit-pr` (local pre-PR review) workflows, **continue** — external review is advisory.
