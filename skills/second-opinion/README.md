# Second Opinion

Cross-model code review and consultation via external AI CLI. `review` mode runs every available review lane (default: codex + claude) on the same diff and unions the findings — model diversity has different blind spots. The other modes auto-detect your current harness and call the opposite — Claude calls Codex, Codex calls Claude, Pi calls Claude.

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

## Configuration

All optional — defaults work out of the box. Set shared, non-sensitive defaults in `vstack.settings.toml` under `[env]`. Existing `.env.local` values still work and should be reserved for personal overrides.

Project installs seed `vstack.settings.toml` from this skill's `vstack.settings.toml.example` when the file is missing, or merge any missing second-opinion keys into an existing file without overwriting user values.

| Variable | Default | Purpose |
|----------|---------|---------|
| `SECOND_OPINION_TARGET` | (unset) | Force a single target; disables multi-lane review |
| `SECOND_OPINION_TIMEOUT` | `300` | Max seconds to wait |
| `SECOND_OPINION_CLAUDE_CMD` | (see below) | Full command when calling Claude |
| `SECOND_OPINION_CODEX_CMD` | (see below) | Full command when calling Codex |
| `SECOND_OPINION_REVIEW_TARGETS` | `codex claude` | Review lanes; every available lane runs and findings are unioned, deduped by location |
| `SECOND_OPINION_REVIEW_INSTRUCTIONS` | (see above) | Instruction-file globs appended to the review prompt; set empty to disable |
| `SECOND_OPINION_<NAME>_CMD` | (none) | Full command for a custom review target — a third model CLI is a settings entry, not new code |

### Default commands

```bash
# When calling Claude (from Codex):
SECOND_OPINION_CLAUDE_CMD="claude -p --no-session-persistence --model opus --effort max --allowedTools Bash(read-only:true),Read,Glob,Grep"

# When calling Codex (from Claude):
SECOND_OPINION_CODEX_CMD="codex exec -m gpt-5.6-sol -s read-only -c model_reasoning_effort=xhigh --ephemeral"
```

Edit the full command string to change model, effort level, or tool access. No additional flags are appended.

### Flag reference

**Claude:**

| Flag | Purpose |
|------|---------|
| `-p` | Non-interactive print mode |
| `--no-session-persistence` | Ephemeral session |
| `--model opus` | Opus 4.6 (change to `sonnet` or `haiku` for speed/cost) |
| `--effort max` | Reasoning effort (`low`, `medium`, `high`, `max`) |
| `--allowedTools` | Tool access — read-only bash, file reads, search (no writes) |

**Codex:**

| Flag | Purpose |
|------|---------|
| `-m gpt-5.6-sol` | Model (change to any supported model) |
| `-s read-only` | Sandbox (`read-only`, `workspace-write`) |
| `-c model_reasoning_effort=xhigh` | Reasoning effort (`low`, `medium`, `high`, `xhigh`) |
| `--ephemeral` | Ephemeral session |

## orch Integration

The orch skill's `review-pr` workflow optionally offers an external review at § 2.1. If accepted, the script produces review-finding JSON (same schema as internal review agents) that flows through the standard blocker/suggestion/issue pipeline.

The orch `submit-pr` workflow also runs `review` as a local pre-PR review of the branch diff (standalone lifecycle), draining bot-class findings at local speed instead of blocking on asynchronous GitHub review bots.

Review artifacts stamp `qa_metadata.reviewed_head` (the reviewed worktree's HEAD commit) so callers can budget review passes **per pushed head** — GitHub bots re-review every push, and a new head is a new round, not a spend against a per-submission cap.

The wrapper guarantees a "pass" artifact always corresponds to a complete review that actually happened: the artifact `timestamp` is wrapper-stamped (never model-supplied), the review scope is derived from the worktree and embedded in the prompt, incomplete or no-review responses are preserved beside the artifact (`.incomplete.json` / `.noreview.json`, exit 4) instead of becoming it, an empty diff fails with exit 3, and a CLI that never answers fails with exit 5 (`.failed.json`). See SKILL.md § Error Handling for the exit-code contract.
