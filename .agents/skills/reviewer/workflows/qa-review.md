# QA Review Lifecycle

QA agents review ONE PR, triggered by a `needs-*` label. Review-only: never an issue owner. You review and return a verdict; the orchestrator owns tracker state, fix routing, and presentation.

## 1. Set Up

### 1.1 Resolve Tracker

Before any tracker command, apply [orch SKILL.md § Tracker Resolution](../../orch/SKILL.md#tracker-resolution).

**GitHub reviews must not run Linear commands**: when `TRACKER=github`, no Linear read or mutation may run anywhere in this workflow; read live GitHub context instead (§ 1.2). If a tracker read fails on the resolved route, report the gap in your review output; do not silently fall back to the other tracker.

### 1.2 Read Context

**Linear route (TRACKER=linear)**:

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh comments list [ISSUE_ID]
```

**GitHub route (TRACKER=github)**. `[N]` is `ISSUE_REF` without its `#`:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url
```

The delegation prompt carries the dev agent's completion summary, the triggering `needs-*` label, and the decisions that bind this review.

## 2. Review

Identify the changed files (same two commands as `review.md` § 1: `resolve-base-branch`, then the diff), then run your agent-specific review per your agent file and the reviewer skill's Ethos. Suggestions that contradict the delegation's listed decisions are invalid; a flawed decision is a blocker citing the decision.

Mutation-validating a test as evidence commits you to the skill's Mutation-Stability Pairing.

For `needs-ui-review`, judge the view from the set in [ui-screenshots.md § Screenshots](../references/ui-screenshots.md#screenshots).

**Performance QA agent only**: also follow [`../references/perf-qa.md`](../references/perf-qa.md) and carry `benchmark_commit` into § 3.

## 3. Artifact, Validate, Return

Write and self-validate per the skill's § Output Contract: [`../schemas/review-finding.md`](../schemas/review-finding.md) is the field authority and `review-artifact-check` the pre-return check. Populate `qa_metadata.[agent_type]` per your agent file. Verdict: `action_required` when `blockers[]` is non-empty, else `pass`.

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

**Do NOT**: claim the issue, modify tracker state, mark the issue done, or call other subagents.
