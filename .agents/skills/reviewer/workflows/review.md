# Code Review Lifecycle

Review agents run in parallel, each reviewing the same changes from their own domain.

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

- Review the changed code and directly affected call paths per your agent file and the reviewer skill's Ethos.
- Read from the worktree as needed.
- Inspect a deleted path through the diff or git history.
- Exclude research documents from what you read.
- Findings respect the delegation's listed decisions, each read in full with its status.
- A decision marked superseded binds only what its status leaves active, and a retired one binds nothing.
- If a listed decision file does not exist, do not hunt for it.
- Note the broken reference in your report and review without it.

## 3. Artifact, Validate, Return

Write and self-validate per the skill's § Output Contract: [`../schemas/review-finding.md`](../schemas/review-finding.md) is the field authority and `orch-runtime review-artifact check` the pre-return check.

Send exactly one agent-to-agent message, then go idle:

<output_format>
Verdict: [pass|action_required]
File: [ARTIFACT_PATH]
```json
{complete JSON object}
```
</output_format>

**Do NOT**: modify tracker state or call other subagents.
