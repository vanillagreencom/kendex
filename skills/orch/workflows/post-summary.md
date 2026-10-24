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

Collect each actual round's Validation routes from its completion or fix artifact, and read any later restack run's native evidence, following [dev-implement.md § 9.1](../../dev/workflows/dev-implement.md#91-completion-comment). Carry those rows into this comment, preserving their original identities and outcomes. Include each child on its originating item when bundled; the parent summary may also carry the rows. A compact workflow-state projection or final verdict cannot fill fields absent from the original sources.

**Skip if** every count is zero, `post_pr_stop` is null and there are no validation routes to report → § 2.

Write the summary to a file first with the harness file-write tool at `[WORKTREE_PATH]/tmp/post-summary-[ISSUE_ID]-[TIMESTAMP].md` (`git-context timestamp compact`), then post it:

```bash
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file "$SUMMARY_FILE"
```

**Linear only**:

```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file "$SUMMARY_FILE"
```

```markdown
[What landed or stopped and its effect. Describe implementation awaiting merge as awaiting merge.]

## Completed Issues

- Closes [ISSUE_REF] - [TITLE]
  - Closes [SUB_ISSUE_REF] - [SUB_TITLE]

## Evidence

- [ACCEPTANCE_OR_QA_RESULT_WITH_SOURCE; LINK_IMPLEMENTATION_SUMMARIES_AND_THEIR_MEASURED_DOMAIN_METRICS]

## Validation routes

[Each actual round/run's fixed-field row from dev-implement.md § 9.1, including fix and restack runs.]

## Orchestration stopped

- Stop: `[POST_PR_STOP.name]`
- Gate: `[POST_PR_STOP.gate]`
- Remaining: [POST_PR_STOP.remaining]

## Created Issues

- [ISSUE_ID] - [TITLE] — [PROJECT]

## Recommendations Processed

### Fixed in PR

- [SOURCE]: [ITEM] — [SHA]

### Skipped

- [SOURCE]: [ITEM] — [REASON]

**Fix rounds**: [N] | [STATUS_SUMMARY]

## Handoff Notes

[Changed contracts and the downstream action, with source or existing handoff links.]
```

Omit empty sections. Completed Issues requires the corresponding result read from its source service in this session; preserve PR-body `Closes` references independently of this comment. Link implementation summaries instead of recopying their files, choices, screenshots or measures. When merge adds evidence, append the actual merge state and new evidence at the existing merge-comment delivery point, retaining the earlier run rows. Post one update at each existing delivery point. Render Orchestration stopped only when `post_pr_stop` is non-null. Created Issues comes from `audit_issues_created` plus `pr_comment_review.issues_created`, with project names. Deduplicate Recommendations Processed by description across cycles.

**Commit SHAs.** When workflow state carries a `.rebase_map`, resolve every published SHA through it before posting — follow the chain until no key matches; publishing an unreconciled pre-rebase SHA is forbidden. Artifact-sourced references such as a perf QA `benchmark_commit` are the ones still unreconciled (`submit-pr.md` § 2). A stored fix commit reading `dropped:<sha>` names a commit that vanished in a rebase — report that item without a SHA (or cite the upstream commit that carries the patch), never print the dead hash.

## 2. Post Handoff Comments

**Skip if** `TRACKER=github` → § 3

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
```

Read `.blocks` and the downstream issue’s comments. Reuse an existing `Handoff from [ISSUE_ID]:` posted by dev or an earlier session unless the contract changed again. Post a handoff comment to a downstream issue only when its description references files this PR touched, a decision it should know about was created, or an API or interface it depends on changed. Simply being unblocked earns nothing.

Write the handoff body with the harness file-write tool to `tmp/handoff-[ISSUE_ID]-to-[DOWNSTREAM_ISSUE_ID].md` and bind that path as `[BODY_FILE]`:

```markdown
Handoff from [ISSUE_ID]:
- [CHANGED_API_FILE_INTERFACE_OR_DECISION; SOURCE; DOWNSTREAM_ACTION]
```

```bash
.agents/skills/linear/scripts/linear.sh comments create [DOWNSTREAM_ISSUE_ID] --body-file [BODY_FILE]
```

## 3. Return

**Managed**: return to the parent workflow's next section. **Standalone**: session complete.
