# Codebase Review Lifecycle

Whole-codebase review for ad-hoc early-stage audits: no PR, no issue, no diff. You review and return a verdict; the orchestrator owns fanout, collection, and presentation.

## 1. Scope

The delegation message provides `Worktree`, optional `Scope`, optional `Exclusions`. Default scope: all tracked, non-generated project code plus the tests, configs, and docs your domain needs — enumerated with `git -C [WORKTREE_PATH] ls-files`, never sampled or restricted to changed files. Default exclusions: harness mirrors (`.agents/`, `.claude/`, `.codex/`, `.opencode/`, `.pi/`, `.cursor/`), vendor/dependency dirs, build outputs, generated artifacts, binaries, lockfiles.

If the scope is too large to review honestly within context/tool limits, return `action_required` with a blocker naming the coverage gap and the smallest useful split.

## 2. Review

Review per your agent file and the reviewer skill's Ethos; read the relevant code before writing any finding — never from filenames or search hits alone. Report only what is actionable and material.

## 3. Artifact, Validate, Return

Write and self-validate per the skill's § Output Contract: [`../schemas/review-finding.md`](../schemas/review-finding.md) is the field authority and `review-artifact-check` the pre-return check, with `-codebase-` in the artifact name. Verdict: `action_required` when `blockers[]` is non-empty, else `pass`.

Send exactly one agent-to-agent message, then go idle:

<output_format>
Verdict: [pass|action_required]
File: [WORKTREE_PATH]/tmp/review-[AGENT]-codebase-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>

**Do NOT**: modify project files other than the artifact, modify tracker state, commit, push, call other subagents, or convert findings into issues.
