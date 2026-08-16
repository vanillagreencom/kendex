# Post Summary Workflow

Post the session summary to the git host and issue tracker, plus selective handoff comments to downstream issues.

| Command | Behavior |
|---------|----------|
| `post-summary` | Post for the current branch's issue |
| `post-summary [ISSUE_ID]` | Post for a specific issue |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle` — `"managed"` (return at § 3) or `"self"` (default); `issue_id` — the workflow-state key, the normalized issue ID, never the bare GitHub issue number; `pr_number`. Every lifecycle path resolves `TRACKER`, `ISSUE_REF`, and `SUB_ISSUE_REF` from `issue_id` per [Tracker Resolution](../SKILL.md#tracker-resolution) before rendering the summary.

**Standalone init** (`lifecycle: "self"`): `git-context issue-from-branch .` gives `ISSUE_ID`; resolve `TRACKER` per [Tracker Resolution](../SKILL.md#tracker-resolution); `WT_PATH` is the current directory unless `worktree exists`/`worktree path` says otherwise; `pr-view-json [WT_PATH] --json number` gives `PR_NUMBER`. When `workflow-state exists --json [ISSUE_ID]` reports false, initialize with `git-context branch [WT_PATH]` and `workflow-state init`.

## 1. Post The Summary

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{fixed_count: (.fixed_items | length), escalated_count: (.escalated_items | length), audit_issues: (.audit_issues_created | length), pr_issues: (.pr_comment_review.issues_created | length), cycles: .cycles}'
```

**Skip if** every count is zero → § 2.

Write the summary to a file first — inline bodies with backticks or fenced blocks corrupt under shell command substitution — using the harness file-write tool at `[WORKTREE_PATH]/tmp/post-summary-[ISSUE_ID]-[TIMESTAMP].md` (`git-context timestamp compact`), then post it:

```bash
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file "$SUMMARY_FILE"
```

**Linear only** — GitHub items get their linkage from `Closes #N` in the PR body:

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

## Recommendations Processed

### Fixed in PR
- [SOURCE]: [ITEM] — [SHA]

### Skipped
- [SOURCE]: [ITEM] — [REASON]

**Cycles**: [N] | [STATUS_SUMMARY]
```

Omit empty sections. Created Issues comes from `audit_issues_created` plus `pr_comment_review.issues_created`, with project names. Deduplicate Recommendations Processed by description across cycles.

**Commit SHAs.** When workflow state carries a `.rebase_map`, resolve every published SHA through it before posting — follow the chain until no key matches; publishing an unreconciled pre-rebase SHA is forbidden. State-stored fix SHAs were already rewritten at push time; the map matters for artifact-sourced references such as a perf QA `benchmark_commit` (`submit-pr.md` § 2).

## 2. Post Handoff Comments

**Skip if** `TRACKER=github` — dependencies there live in issue bodies, not tracked relations. → § 3

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
```

Read `.blocks`. Post a handoff comment to a downstream issue only when it earns one: its description references files this PR touched, a decision it should know about was created, or an API or interface it depends on changed. Simply being unblocked — the common case — earns nothing.

```bash
.agents/skills/linear/scripts/linear.sh comments create [DOWNSTREAM_ISSUE_ID] --body "Handoff from [ISSUE_ID]:
- [RELEVANT_CONTEXT]"
```

## 3. Return

**Managed**: return to the parent workflow's next section. **Standalone**: session complete.
