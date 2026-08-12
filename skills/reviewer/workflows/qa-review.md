# QA Review Lifecycle

QA agents review ONE PR, triggered by a `needs-*` label. Review-only: never an issue owner. You review and return a verdict; the orchestrator owns tracker state, fix routing, and presentation.

## 1. Set Up

### 1.1 Resolve Tracker

Resolve tracker context once, before any tracker command. Precedence:

1. **Delegation context**: an explicit `Tracker:` value in the delegation prompt (with `[OWNER/REPO]` for `github`).
2. **Inference fallback**: `[ISSUE_ID]` starting with `issue-` → `github`; otherwise `linear`. The GitHub issue number `[N]` is `[ISSUE_ID]` without the `issue-` prefix. For `github` with no repository value, resolve it in the worktree:

   ```bash
   gh repo view --json nameWithOwner --jq .nameWithOwner
   ```

Store the result as `TRACKER`, plus `[OWNER/REPO]` when `TRACKER=github`.

**GitHub reviews must not run Linear commands**: when `TRACKER=github`, no `sync`, Linear cache read, or Linear mutation may run anywhere in this workflow. A missing Linear cache is not an error for a GitHub-tracked review — read live GitHub context instead (§ 1.2). If a tracker read fails on the resolved route, report the gap in your review output; do not silently fall back to the other tracker.

### 1.2 Read Context

**Linear route (TRACKER=linear)**:

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]
```

**GitHub route (TRACKER=github)**:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url
```

The delegation prompt carries the dev agent's completion summary, the triggering `needs-*` label, and the decisions that bind this review.

## 2. Review

Identify the changed files (same two commands as `review.md` § 1: `resolve-base-branch`, then the diff), then run your agent-specific review per your agent file and the reviewer skill's Ethos. Suggestions that contradict the delegation's listed decisions are invalid — unless the decision itself is flawed, which is a blocker citing the decision and why.

Mutation-validating a test as evidence commits you to the skill's Mutation-Stability Pairing.

**Performance QA agent only**: additionally follow [`../references/perf-qa.md`](../references/perf-qa.md) for benchmark execution, regression classification, and recording, and carry `benchmark_commit` into § 3.

## 3. Artifact, Validate, Return

Write the JSON per [`../schemas/review-finding.md`](../schemas/review-finding.md) to `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json`, with `qa_metadata.[agent_type]` populated per your agent file. Verdict: `action_required` when `blockers[]` is non-empty, else `pass`. Self-validate until `"ok": true`:

```bash
.agents/skills/orch/scripts/review-artifact-check [WORKTREE_PATH] [AGENT] 0
```

Send exactly one agent-to-agent message, then go idle:

<output_format>
QA_COMPLETE
verdict: [pass|action_required]
agent: [AGENT_NAME]
benchmark_commit: [SHA or "none"]
File: [WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>

**Do NOT**: claim the issue, modify tracker state, mark the issue done, commit, push, or call other subagents.
