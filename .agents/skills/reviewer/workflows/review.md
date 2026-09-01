# Code Review Lifecycle

Review agents run in parallel, each reviewing the same changes from their own domain. You review and return a verdict; the orchestrator owns tracker state, fix routing, and presentation.

## 1. Diff

The delegation message provides `Worktree`, `Branch`, optional `Diff-range`, `Decisions`, and any re-review context.

With a `Diff-range` naming a range:

```bash
git -C [WORKTREE_PATH] diff [DIFF_RANGE]
```

Otherwise — the line absent, or reading `Diff-range: unavailable` — the pass is the whole branch (two separate commands):

```bash
.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]
git -C [WORKTREE_PATH] diff "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]"...HEAD
```

Either case beside a re-review block declares the pass unscoped: open § 3's artifact `summary` with `unscoped re-review: Diff-range unavailable`.

## 2. Review

Review the changed code and directly affected call paths per your agent file and the reviewer skill's Ethos, reading from the worktree as needed (a deleted path is inspected via the diff or git history; research documents are excluded). Findings must respect the delegation's listed decisions. If a listed decision file does not exist, do not hunt for it; note the broken reference in your report and review without it.

Mutation-validating a test as evidence commits you to the skill's Mutation-Stability Pairing.

**Re-review round?** Apply the skill's Re-Review Rounds rule.

## 3. Artifact, Validate, Return

Write and self-validate per the skill's § Output Contract: [`../schemas/review-finding.md`](../schemas/review-finding.md) is the field authority and `review-artifact-check` the pre-return check. Verdict: `action_required` when `blockers[]` is non-empty, else `pass`.

Send exactly one agent-to-agent message, then go idle:

<output_format>
Verdict: [pass|action_required]
File: [WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>

**Do NOT**: modify tracker state, commit, push, or call other subagents.
