# Post Summary Workflow

Post the session summary to the git host and issue tracker, plus selective handoff comments to downstream issues.

| Command | Behavior |
|---------|----------|
| `post-summary` | Post for the current branch's issue |
| `post-summary [ISSUE_ID]` | Post for a specific issue |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle` — `"managed"` (return at § 3) or `"self"` (default); `issue_id` — the workflow-state key, the normalized issue ID, never the bare GitHub issue number; `pr_number`. Every lifecycle path resolves `TRACKER` and `ISSUE_REF` from `issue_id` per [Tracker Resolution](../SKILL.md#tracker-resolution), and `SUB_ISSUE_REF` the same way from each completed sub-issue's own id, before rendering the summary.

**Standalone init** (`lifecycle: "self"`): `git-context issue-from-branch .` gives `ISSUE_ID`; resolve `TRACKER` per [Tracker Resolution](../SKILL.md#tracker-resolution); `WT_PATH` is `git-context repo-root "[DIR]"`, `[DIR]` being `.` unless `worktree exists`/`worktree path` says otherwise; `pr-view-json [WT_PATH] --json number` gives `PR_NUMBER`. When `workflow-state exists --json [ISSUE_ID]` reports false, initialize with `git-context branch [WT_PATH]` and `workflow-state init`.

## 1. Post The Summary

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{fixed_count: (.fixed_items | length), escalated_count: (.escalated_items | length), audit_issues: (.audit_issues_created | length), pr_issues: (.pr_comment_review.issues_created | length), cycles: .cycles, post_pr_stop: .post_pr_stop}'
```

**Skip if** every count is zero and `post_pr_stop` is null → § 2.

Write the summary to a file first with the harness file-write tool at `[WORKTREE_PATH]/tmp/post-summary-[ISSUE_ID]-[TIMESTAMP].md` (`git-context timestamp compact`), then post it:

```bash
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file "$SUMMARY_FILE"
```

**Linear only**:

```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file "$SUMMARY_FILE"
```

```markdown
## Completed Issues
- Closes [ISSUE_REF] - [TITLE]
  - Closes [SUB_ISSUE_REF] - [SUB_TITLE]

## Created Issues
- [ISSUE_ID] - [TITLE] — [PROJECT]

## QA Metrics
[Results from the QA agents that ran — project-configurable.]

## Orchestration stopped
- Stop: `[POST_PR_STOP.name]`
- Gate: `[POST_PR_STOP.gate]`
- Remaining: [POST_PR_STOP.remaining]

## Recommendations Processed

### Fixed in PR
- [SOURCE]: [ITEM] — [SHA]

### Skipped
- [SOURCE]: [ITEM] — [REASON]

**Fix rounds**: [N] | [STATUS_SUMMARY]
```

Omit empty sections. Render Orchestration stopped only when `post_pr_stop` is
non-null. Created Issues comes from `audit_issues_created` plus
`pr_comment_review.issues_created`, with project names. Deduplicate
Recommendations Processed by description across cycles.

**Commit SHAs.** When workflow state carries a `.rebase_map`, resolve every published SHA through it before posting — follow the chain until no key matches; publishing an unreconciled pre-rebase SHA is forbidden. Artifact-sourced references such as a perf QA `benchmark_commit` are the ones still unreconciled (`submit-pr.md` § 2). A stored fix commit reading `dropped:<sha>` names a commit that vanished in a rebase — report that item without a SHA (or cite the upstream commit that carries the patch), never print the dead hash.

## 2. Post Handoff Comments

**Skip if** `TRACKER=github` → § 3

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
```

Read `.blocks`. Post a handoff comment to a downstream issue only when its description references files this PR touched, a decision it should know about was created, or an API or interface it depends on changed. Simply being unblocked earns nothing.

```bash
.agents/skills/linear/scripts/linear.sh comments create [DOWNSTREAM_ISSUE_ID] --body "Handoff from [ISSUE_ID]:
- [RELEVANT_CONTEXT]"
```

## 3. Return

**Managed**: return to the parent workflow's next section. **Standalone**: session complete.
