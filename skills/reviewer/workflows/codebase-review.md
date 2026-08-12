# Codebase Review Lifecycle

Whole-codebase review for ad-hoc early-stage audits: no PR, no issue, no diff. You review and return a verdict; the orchestrator owns fanout, collection, and presentation.

## 1. Scope

The delegation message provides `Worktree`, optional `Scope`, optional `Exclusions`. Default scope: all tracked, non-generated project code plus the tests, configs, and docs your domain needs — enumerated with `git -C [WORKTREE_PATH] ls-files`, never sampled or restricted to changed files. Default exclusions: harness mirrors (`.agents/`, `.claude/`, `.codex/`, `.opencode/`, `.pi/`, `.cursor/`), vendor/dependency dirs, build outputs, generated artifacts, binaries, lockfiles.

If the scope is too large to review honestly within context/tool limits, return `action_required` with a blocker naming the coverage gap and the smallest useful split.

## 2. Review

Review per your agent file and the reviewer skill's Ethos, reading the relevant code before writing any finding — never from filenames or search hits alone. Findings may be pre-existing; report only what is actionable and material for an early-stage quality pass.

## 3. Artifact, Validate, Return

Write the JSON per [`../schemas/review-finding.md`](../schemas/review-finding.md) to `[WORKTREE_PATH]/tmp/review-[AGENT]-codebase-YYYYMMDD-HHMMSS.json` (`mkdir -p [WORKTREE_PATH]/tmp` first if needed). Verdict: `action_required` when `blockers[]` is non-empty, else `pass`. Self-validate until `"ok": true`:

```bash
.agents/skills/orch/scripts/review-artifact-check [WORKTREE_PATH] [AGENT] 0
```

Send exactly one agent-to-agent message, then go idle:

<output_format>
Verdict: [pass|action_required]
File: [WORKTREE_PATH]/tmp/review-[AGENT]-codebase-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>

**Do NOT**: modify project files other than the artifact, modify tracker state, commit, push, call other subagents, or convert findings into issues.
