# QA Review Lifecycle

The caller applies [orch § Delegation](../../orch/references/skill-rules.md#delegation) before selecting an agent for each round.

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

**GitHub reviews must not run Linear commands**: when `TRACKER=github`, no Linear read or mutation may run anywhere in this workflow; read live GitHub context instead (§ 1.2). If a tracker read fails on the resolved route, report the gap in your review output; do not silently fall back to the other tracker.

### 1.2 Read Context

**Linear route (TRACKER=linear)**:

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh comments list [ISSUE_ID]
```

**GitHub route (TRACKER=github)**:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url
```

The delegation prompt carries the dev agent's completion summary, the triggering `needs-*` label, and the decisions that bind this review.

## 2. Review

Identify the changed files (same two commands as `review.md` § 1: `resolve-base-branch`, then the diff), then run your agent-specific review per your agent file and the reviewer skill's Ethos. Suggestions that contradict the delegation's listed decisions are invalid; a flawed decision is a blocker citing the decision.

Mutation-validating a test as evidence commits you to the skill's Mutation-Stability Pairing.

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

## Screenshots

A `needs-ui-review` review judges each changed view from this set. The round that changes the view captures it and lists it in its summary.

- Each changed view has an actual before image from the base revision and an actual after image from HEAD, in every theme the app has: dark and light where it has both.
- Where the view did not exist at the base revision, the before image is the actual comparable state there, such as the empty or missing-feature state, identified as that state. Never a fabricated blank.
- Each image keeps its comparison conditions: view and state, before or after, the revision it was captured from, theme, and viewport, scale or platform where they matter. A pair whose conditions differ says which one changed. An image is never relabelled as another revision's.
- Each image is a file where the repository's own capture procedure puts it, and under the worktree's `tmp/ui-shots/` only where the repository names no directory. It is listed on its own line of the round's summary as `[PATH]` - [View], [before|after], [THEME].
- A later round that changes the view again recaptures its after images and lists the view's full set, carrying the earlier round's before images with their original revision and conditions.
- A view missing any image of its set cannot be judged in that theme. When no actual comparable before image exists, the evidence stays incomplete: the blocker names the cause and the view's conditions, and only the owner's decision on that case, through the caller's owner-decision route, settles it. No after-only image stands in by default.
