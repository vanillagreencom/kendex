# Post Summary Workflow

Post the session summary to the pull request and the tracker. Hand context to the downstream issues that need it.

| Command | Behavior |
|---------|----------|
| `post-summary` | Post for the current branch's issue |
| `post-summary [ISSUE_ID]` | Post for a specific issue |
| (from start-worktree or merge-pr) | Managed lifecycle with caller context |

**Caller context** (via `⤵`): `worktree`; `lifecycle`, `"managed"` (return at § 3) or `"self"` (the default); `issue_id`, the workflow-state key: the normalized issue ID, never the bare GitHub issue number; `pr_number`, absent for a direct delivery ([submit-pr.md § 2.1](submit-pr.md#21-base-publication)). Before you render the summary, resolve `TRACKER` and `ISSUE_REF` from `issue_id` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution). Resolve `SUB_ISSUE_REF` the same way from each completed sub-issue's ID.

**Standalone init** (`lifecycle: "self"`):

1. Bind `ISSUE_ID` from `.agents/skills/orch/scripts/git-context issue-from-branch .`. Resolve `TRACKER` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution).
2. `[DIR]` is `.` unless `.agents/skills/worktree/scripts/worktree exists` and `worktree path` name another worktree. `WT_PATH` is what `git-context repo-root "[DIR]"` prints.
3. Read the pull request: `.agents/skills/orch/scripts/orch-runtime pr view "[WT_PATH]" --json number`. Its `number` is `PR_NUMBER`; `{"status":"no_pr","number":null}` leaves `PR_NUMBER` unbound.
4. Where `orch-runtime state exists --item [ISSUE_ID]` reports no record, read the branch with `git-context branch [WT_PATH]`. Create the record with `orch-runtime state init --item [ISSUE_ID] --worktree [WT_PATH] --branch [BRANCH]`.

## 1. Post The Summary

Read the counts the summary needs:

```bash
STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])" && jq -c '.result.value | {fixed_count: (.fixed_items | length), escalated_count: (.escalated_items | length), audit_issues: (.audit_issues_created | length), pr_issues: (.pr_comment_review.issues_created | length), cycles: .cycles, post_pr_stop: .post_pr_stop}' <<<"$STATE_READ"
```

Collect each round's Validation Routes from its completion or fix artifact, and each later restack run's own evidence, per [dev-implement.md § 9.1](../../dev/workflows/dev-implement.md#91-completion-summary-file). Carry the rows into the comment with their original identities and outcomes. In a bundle, put each child's rows on the child's item; the parent summary may carry them too. Never fill a field the original sources lack from a state projection or a final verdict.

**Skip if** every count is zero, `post_pr_stop` is null and no validation route is left to report: go to § 2.

Write the summary with the harness file-write tool to `[WORKTREE_PATH]/tmp/post-summary-[ISSUE_ID]-[TIMESTAMP].md` (`git-context timestamp compact`). Bind that path as `SUMMARY_FILE`. With a `pr_number`, post it on the pull request:

```bash
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file "$SUMMARY_FILE"
```

With no `pr_number`, post no pull-request comment.

**Linear only**, post it on the issue:

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

## Validation Routes
[Each actual round/run's fixed-field row from dev-implement.md § 9.1, including fix and restack runs.]

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

- Omit empty sections. Render Orchestration stopped only when `post_pr_stop` is non-null.
- Created Issues comes from `audit_issues_created` and `pr_comment_review.issues_created`, with project names.
- Deduplicate Recommendations Processed by description across cycles.

**Commit SHAs.** Where workflow state carries a `.rebase_map`, resolve every published SHA through it before posting. Follow the chain until no key matches. Never publish an unreconciled pre-rebase SHA. A SHA taken from an artifact, such as a perf QA `benchmark_commit`, is still unreconciled ([submit-pr.md § 2](submit-pr.md#2-push-and-submit) step 1). A stored fix commit `dropped:<sha>` names a commit a rebase dropped. Report that item without a SHA, or cite the upstream commit that carries the patch. Never print the dead hash.

## 2. Post Handoff Comments

**Skip if** `TRACKER` is `github` or `none`: go to § 3.

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
```

Read `.blocks`. Post a handoff comment to a downstream issue only when:

- its description names files this change touched;
- this change created a decision it should know; or
- an API or interface it depends on changed.

Being unblocked alone earns no comment.

Write the handoff body with the harness file-write tool to `[WORKTREE_PATH]/tmp/handoff-[ISSUE_ID]-to-[DOWNSTREAM_ISSUE_ID].md`. Bind that path as `[BODY_FILE]`:

```markdown
Handoff from [ISSUE_ID]:
- [RELEVANT_CONTEXT]
```

```bash
.agents/skills/linear/scripts/linear.sh comments create [DOWNSTREAM_ISSUE_ID] --body-file [BODY_FILE]
```

## 3. Return

**Managed**: return to the parent workflow's next section. **Standalone**: the session is complete.
