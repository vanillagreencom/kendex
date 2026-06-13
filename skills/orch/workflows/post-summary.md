# Post Summary Workflow

Post summary comments to git host and issue tracker, and selective handoff comments to downstream issues.

## Inputs

| Command | Behavior |
|---------|----------|
| `post-summary` | Post summary for current branch's issue |
| `post-summary [ISSUE_ID]` | Post summary for specific issue |
| (from start-worktree) | Managed lifecycle with caller context |

**Caller context parameters** (via `⤵`):
- `worktree`: worktree path
- `lifecycle` (optional): `"managed"` (return to caller at § 3) | `"self"` (default, standalone).
- `issue_id` (optional): Issue ID. If absent, extracted from branch.
- `pr_number` (optional): PR number for git host comment. If absent, detected from branch.

**Standalone init** (`lifecycle: "self"` only):
```bash
# Extract issue from branch if not provided
ISSUE_ID=$(git rev-parse --abbrev-ref HEAD | grep -oiP "$GH_ISSUE_PATTERN")
TRACKER=$(.agents/skills/orch/scripts/tracker-for-issue "$ISSUE_ID")
WT_PATH=$(.agents/skills/worktree/scripts/worktree path $ISSUE_ID 2>/dev/null || echo ".")
PR_NUMBER=$(.agents/skills/github/scripts/github.sh -C "$WT_PATH" pr-view --json number 2>/dev/null | jq -r .number)
# Init workflow state if not exists
if ! .agents/skills/orch/scripts/workflow-state exists $ISSUE_ID; then
  .agents/skills/orch/scripts/workflow-state init $ISSUE_ID --worktree "$WT_PATH" --branch "$(git rev-parse --abbrev-ref HEAD)"
fi
```

---

## 1. Post Summary Comments

1. **Read state**:
   ```bash
   FIXED_COUNT=$(.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.fixed_items | length')
   ESCALATED_COUNT=$(.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.escalated_items | length')
   AUDIT_ISSUES=$(.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.audit_issues_created | length')
   PR_ISSUES=$(.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pr_comment_review.issues_created | length')
   CYCLES=$(.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] .cycles)
   ```

2. **Skip if** `FIXED_COUNT == 0` AND `AUDIT_ISSUES == 0` AND `PR_ISSUES == 0` AND `ESCALATED_COUNT == 0`. → § 2

3. **Post to git host and issue tracker** — consolidate all review cycle results from state. Write to a file first (same backtick hazard as submit-pr PR body):
   ```bash
   SUMMARY_FILE="[WORKTREE_PATH]/tmp/post-summary-[ISSUE_ID]-$(date +%Y%m%d-%H%M%S).md"
   mkdir -p "$(dirname "$SUMMARY_FILE")"
   cat > "$SUMMARY_FILE" <<'SUMMARY_EOF'
   [filled SUMMARY_CONTENT — see template below]
   SUMMARY_EOF
   .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file "$SUMMARY_FILE"
   ```

   Linear only — GitHub items get linkage via `Closes #N` in the PR body:

   ```bash
   .agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file "$SUMMARY_FILE"
   ```

   **Summary content template** (omit empty sections):

   ```markdown
   ## Completed Issues
   - Closes [ISSUE_ID] - [TITLE]
     - Closes [ISSUE_ID] - [SUB_TITLE]
     - Closes [ISSUE_ID] - [SUB_TITLE]

   ## Created Issues
   - [ISSUE_ID] - [TITLE] — [PROJECT]
   - [ISSUE_ID] - [TITLE] — [PROJECT]

   ## QA Metrics
   (project-specific metrics summary)

   ## Recommendations Processed

   ### Fixed in PR
   - [SOURCE]: [ITEM] — [SHA]

   ### Skipped
   - [SOURCE]: [ITEM] — [REASON]

   **Cycles**: [N] | [STATUS_SUMMARY]
   ```

   - **Completed Issues**: Use `Closes` keyword for issue tracker linkage. Indent sub-issues.
   - **Created Issues**: From `audit_issues_created` + `pr_comment_review.issues_created`. Include project name.
   - **QA Metrics**: Include if QA agents ran (project-configurable).
   - **Recommendations Processed**: Dedupe by description across cycles.

---

## 2. Post Handoff Comments (selective)

**Skip if** `TRACKER=github` (dependencies live in issue bodies, not tracked relations). → § 3

1. **Check unblocked issues**: `.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] | jq '.blocks'`

2. **Evaluate conditions** — post handoff only if:
   - Downstream description references files touched in this PR
   - Decision created that downstream should know
   - API/interface change that downstream depends on

3. **Skip if** just unblocking by completion (most common case). → § 3

4. **Post handoff** (if conditions met):
   ```bash
   .agents/skills/linear/scripts/linear.sh comments create [DOWNSTREAM_ISSUE_ID] --body "Handoff from [ISSUE_ID]:
   - [RELEVANT_CONTEXT]"
   ```

---

## 3. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — summary posted.
