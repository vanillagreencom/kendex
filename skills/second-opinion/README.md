# Second Opinion

Cross-model code review and consultation via external AI CLI. The model your session runs is never asked to review its own work: every mode picks the first entry in your model roster that is available and runs a different model — Claude Code gets Codex, Codex gets Claude — and refuses, stating why, when nothing else is eligible. Want breadth? Raise `SECOND_OPINION_COUNT` and `review` runs that many distinct models on the same diff and unions the findings.

Four modes: `review` (code review → JSON), `challenge` (adversarial analysis → text), `audit` (code examination → JSON), `quick` (question → text).

The review prompt reviews through explicit holistic lenses (correctness, security/fail-open, adversarial inputs, Bash-3.2/portability, repo-rule adherence, docs-vs-code drift, test adequacy) and appends the reviewed repo's own instruction files (`AGENTS.md`, `review-bots.md`, `.github/instructions/*.instructions.md`, `.github/copilot-instructions.md`) when present — the same inputs GitHub review bots read.

## Prerequisites

- **jq** installed
- **`timeout`** (or `gtimeout`) on PATH — the deadline is what stops a review
  from running unbounded, so every mode but `detect` refuses without it.
  macOS ships neither: `brew install coreutils`
- At least one external CLI: `claude` (Claude Code) or `codex` (Codex CLI)
- CLI must be authenticated (`claude /login` or `codex login`)

## Usage

As a slash command (natural language works):

```
/second-opinion review                     # Full branch diff
/second-opinion review last 3 commits      # Recent commits only
/second-opinion review uncommitted work     # Staged/unstaged changes
/second-opinion challenge my refactor plan  # Stress-test an approach
/second-opinion audit src/auth/             # Examine existing code
/second-opinion quick is this pattern safe? # Quick question
```

From the shell:

```bash
./scripts/second-opinion review --cwd .
./scripts/second-opinion detect
./scripts/second-opinion review --target claude --range HEAD~3..HEAD --cwd .
```

## Setup

By default the skill runs exactly ONE reviewer: the highest-priority entry in `SECOND_OPINION_MODELS` that is available and is not the model your session runs. A Claude Code session gets Codex, a Codex session gets Claude, and nothing needs configuring beyond having the other CLI installed and logged in. From anywhere else — Pi, OpenCode, Cursor, a plain shell — export `SECOND_OPINION_CURRENT_MODEL` in **that session's environment** first; those clients front a model the script cannot probe, and a run refuses until you declare it. In a **detected** Claude Code or Codex session the key is not needed and not trusted over detection: an agreeing value is ignored, a contradicting one is refused naming both values — whatever its source, because an exported value is inherited by every nested session. And where detection *cannot* arbitrate, keep it out of every project file (`.env`, `kendex.settings.toml`, `.kendex/settings.toml`, `.env.local`): those are read by every session in the repo, so a value in one describes no single session and is refused naming the file — export it in the session that needs it. Every other key belongs in `kendex.settings.toml` under `[env]`:

| Key | Working example | What it does |
|-----|-----------------|--------------|
| `SECOND_OPINION_MODELS` | `"claude codex"` | Priority order. First eligible entry wins; an entry with no command still names a known model identity |
| `SECOND_OPINION_<NAME>_CMD` | `SECOND_OPINION_PI_DEEPSEEK_CMD = "pi -p --model deepseek/deepseek-v4-pro"` | Full command for roster entry `pi-deepseek` (`claude` and `codex` have built-in commands) |
| `SECOND_OPINION_<NAME>_MODEL` | `SECOND_OPINION_PI_DEEPSEEK_MODEL = "deepseek"` | The model that entry fronts, when it is not the entry's own name |
| `SECOND_OPINION_COUNT` | `"2"` | Opinions a `review` collects; 2+ runs up to that many distinct models and unions the findings |
| `SECOND_OPINION_CURRENT_MODEL` | `"claude"` (or `"opus"`, `"gpt-5.6-sol"`, `"openai-codex/gpt-5.6-sol"`, `"none"`) | The model your session runs — export per session, never in a project file. Detected for Claude Code and Codex, where detection wins over a contradicting value and an agreeing one is ignored; required in Pi, OpenCode, Cursor and undetected shells — `none` says there is no session model (CI, plain terminal) |
| `SECOND_OPINION_ARTIFACT_DIR` | `"tmp/second-opinion"` | Where records land when you pass no `--output` (relative to `--cwd`, or `~/…`/absolute) |
| `SECOND_OPINION_REVIEW_INSTRUCTIONS` | `"AGENTS.md review-bots.md .github/instructions/*.instructions.md"` | Repo instruction files appended to the review prompt; empty disables |
| `SECOND_OPINION_TIMEOUT` | `"1080"` | Seconds to wait for the external CLI. Above the ~600s a harness allows a foreground shell call: background the run, or pass `--timeout` at or below the harness ceiling |

`kendex add`/`refresh` seed these keys from this skill's `kendex.settings.toml.example` when the file is missing and add absent keys to an existing file — they never rewrite a value you already have, so an install seeded before the default became 1080 keeps its old `SECOND_OPINION_TIMEOUT = "300"` until you update it by hand. Run `scripts/second-opinion detect` to see which target a review would use from your current session.

## Configuration

Defaults work out of the box in a **detected Claude Code or Codex session** — there every key below is optional. Any other client must declare its session model: Pi, OpenCode, Cursor and undetected shells front a model the script cannot probe, so a run there refuses until `SECOND_OPINION_CURRENT_MODEL` names the model the session runs (or `none` when there is no session model, as in CI or a plain terminal). Set shared, non-sensitive defaults in `kendex.settings.toml` under `[env]`. Existing `.env.local` values still work and should be reserved for personal overrides.

Project installs seed `kendex.settings.toml` from this skill's `kendex.settings.toml.example` when the file is missing, or merge any missing second-opinion keys into an existing file without overwriting user values.

| Variable | Default | Purpose |
|----------|---------|---------|
| `SECOND_OPINION_MODELS` | `claude codex` | Priority-ordered roster; the first available entry that is not your session's model wins |
| `SECOND_OPINION_COUNT` | `1` | Opinions a `review` collects; 2+ runs up to that many distinct models and unions the findings, deduped by location (a shortfall is reported and marked degraded) |
| `SECOND_OPINION_CURRENT_MODEL` | (unset) | The model your session runs, when the CLI cannot tell (Pi, OpenCode, Cursor, undetected — required there; `none` = no session model); Claude Code and Codex are detected. **Session-scoped: export it in the session, not in `.env`, `kendex.settings.toml`, `.kendex/settings.toml` or `.env.local`** — a detected Claude Code or Codex session knows its own model, so any declaration is judged by what it adds there — **ignored** when it agrees, **refused naming both values** when it contradicts, whether you exported it or committed it (exported values are inherited by nested sessions, so "I set it" is not evidence about *this* one). Where the harness cannot be detected (Pi, OpenCode, Cursor) the declaration is all there is: an exported one is authoritative, while one from a project file is **refused naming the file**, since a shared file cannot describe a per-session model. Model ids normalize, provider prefix included (`opus`, `anthropic/claude-opus-4` → claude; `gpt-*`, `openai-codex/gpt-*` → codex); a value you set that the roster does not know is refused (a detected one is not — the roster may name only the target) |
| `SECOND_OPINION_<NAME>_MODEL` | `<name>` | The model a roster entry runs, when it differs from its name (a Pi lane fronting Claude: `claude`) |
| `SECOND_OPINION_<NAME>_CMD` | (none) | Full command for a roster entry — another model CLI is a settings entry, not new code |
| `SECOND_OPINION_TARGET` | (unset) | Force one target; refused if it is your session's model |
| `SECOND_OPINION_TIMEOUT` | `1080` | Max seconds to wait — one total per lane, the one retry on a malformed response included (it gets the remainder, floored at 60s). The default exceeds the ~600s ceiling most agent harnesses put on a foreground shell call: run the script in the background, or a foreground call must pass `--timeout` at or below that ceiling |
| `SECOND_OPINION_ARTIFACT_DIR` | `tmp/second-opinion` | Where records and a multi-lane run's lane artifacts land when you pass no `--output` (relative to `--cwd`, or `~/…`/absolute; git-ignored on creation; falls back to a temp file, loudly, if it cannot be created or is a symlink) |
| `SECOND_OPINION_REVIEW_INSTRUCTIONS` | (see above) | Instruction-file globs appended to the review prompt; set empty to disable |

### Default commands

```bash
# Roster entry claude (model identity: claude):
SECOND_OPINION_CLAUDE_CMD="claude -p --no-session-persistence --model opus --effort max --allowedTools Bash(read-only:true),Read,Glob,Grep"

# Roster entry codex (model identity: codex):
SECOND_OPINION_CODEX_CMD="codex exec -m gpt-5.6-sol -s read-only -c model_reasoning_effort=xhigh --ephemeral"
```

Edit the full command string to change model, effort level, or tool access. No additional flags are appended.

Both defaults are shaped the same way: a non-interactive print mode, an ephemeral session, a model, a reasoning effort, and read-only tool access. Change the model and effort flags to trade cost against depth; keep the sandbox read-only so a second opinion can never write to your worktree. Each CLI's own `--help` is authoritative on its flags.

## orch Integration

The orch skill's `review-pr` workflow optionally offers an external review at § 2.1. If accepted, the script produces review-finding JSON (same schema as internal review agents) that flows through the standard blocker/suggestion/issue pipeline.

The orch `submit-pr` workflow also runs `review` as a local pre-PR review of the branch diff (standalone lifecycle), draining bot-class findings at local speed instead of blocking on asynchronous GitHub review bots.

Review artifacts stamp `qa_metadata.reviewed_head` (the reviewed worktree's HEAD commit) so callers can budget review passes **per pushed head** — GitHub bots re-review every push, and a new head is a new round, not a spend against a per-submission cap.

The wrapper guarantees a "pass" artifact always corresponds to a complete review that actually happened: the `timestamp` is wrapper-stamped rather than model-supplied, the scope is derived from the worktree instead of being left to the model, and a response that is incomplete, self-reported as no-review, or never delivered is preserved beside the artifact rather than becoming it. Any run that ends without a verdict has already cleared whatever a previous run left at `--output` — the artifact, its lane artifacts, and their sidecars — so reusing one path can never hand a caller a stale pass. See SKILL.md § Error Handling for the exit-code contract.
