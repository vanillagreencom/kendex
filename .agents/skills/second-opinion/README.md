# Second Opinion

Cross-model code review and consultation via external AI CLI. The model your session runs is never asked to review its own work: every mode picks the first entry in your model roster that is available and runs a different model — Claude Code gets Codex, Codex gets Claude — and refuses, stating why, when nothing else is eligible. Want breadth? Raise `SECOND_OPINION_COUNT` and `review` runs that many distinct models on the same diff and unions the findings.

Four modes: `review` (code review → JSON), `challenge` (adversarial analysis → text), `audit` (code examination → JSON), `quick` (question → text).

The review prompt reviews through explicit holistic lenses (correctness, security/fail-open, adversarial inputs, Bash-3.2/portability, repo-rule adherence, docs-vs-code drift, test adequacy) and appends the reviewed repo's own instruction files (`AGENTS.md`, `review-bots.md`, `.github/instructions/*.instructions.md`, `.github/copilot-instructions.md`) when present — the same inputs GitHub review bots read.

## Prerequisites

- **jq** installed
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

By default the skill runs the first available entry in `SECOND_OPINION_MODELS` that differs from the current session model. A detected Claude Code session gets Codex and a detected Codex session gets Claude without configuration.

Set shared, non-sensitive values in `kendex.settings.toml` under `[env]`. Keep personal overrides in `.env.local`. Installing the skill writes no settings because no key is marked `# required`.

| Variable | Default | Purpose |
|----------|---------|---------|
| `SECOND_OPINION_MODELS` | `claude codex` | Priority-ordered roster; the first available entry that is not your session's model wins |
| `SECOND_OPINION_COUNT` | `1` | Opinions a `review` collects; 2+ runs up to that many distinct models and unions the findings, deduped by location (a shortfall is reported and marked degraded) |
| `SECOND_OPINION_CURRENT_MODEL` | unset | Export the session model for Pi, OpenCode, Cursor, or an undetected shell; use `none` when no session model exists. Provider-prefixed IDs normalize and an unknown declared identity is refused; never store this key in a project file, because detected Claude Code and Codex sessions ignore an agreeing value and reject a conflicting one, while undetected clients reject project-file values |
| `SECOND_OPINION_<NAME>_MODEL` | `<name>` | The model a roster entry runs, when it differs from its name (a Pi lane fronting Claude: `claude`) |
| `SECOND_OPINION_<NAME>_CMD` | (none) | Full command for a roster entry — another model CLI is a settings entry, not new code |
| `SECOND_OPINION_TARGET` | (unset) | Force one target; refused if it is your session's model |
| `SECOND_OPINION_TIMEOUT` | `1080` | Seconds to wait per CLI invocation; a review's one retry can double the total |
| `SECOND_OPINION_FOREGROUND_CAP` | unset | Session-only alternative to `--foreground`; set it to `1` so the script detaches and prints the wait command |
| `SECOND_OPINION_ARTIFACT_DIR` | `tmp/second-opinion` | Where records and a multi-lane run's lane artifacts land when you pass no `--output` (relative to `--cwd`, or `~/…`/absolute; git-ignored on creation; falls back to a temp file, loudly, if it cannot be created or is a symlink) |
| `SECOND_OPINION_REVIEW_INSTRUCTIONS` | `AGENTS.md review-bots.md .github/instructions/*.instructions.md .github/copilot-instructions.md` | Instruction-file globs appended to the review prompt; set empty to disable |

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

The wrapper guarantees a "pass" artifact always corresponds to a complete review that actually happened: the `timestamp` is wrapper-stamped rather than model-supplied, the scope is derived from the worktree instead of being left to the model, and a response that is incomplete, self-reported as no-review, or never delivered is preserved beside the artifact rather than becoming it. Any run that ends without a verdict has already cleared whatever a previous run left at `--output` — the artifact, its lane artifacts, and their sidecars — so reusing one path can never hand a caller a stale pass. The exit-code contract is in `second-opinion --help`.
