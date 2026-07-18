# Start Session Workflow (Worktree)

Expedited session start for worktree contexts. Skips issue selection, preparation, and worktree creation — completed in the prior main-repo session.

## Inputs

| Command | Flow |
|---------|------|
| `start` (from worktree) | § 1 → § 2 → § 3 → § 4 → § 5 |
| `start [ISSUE_ID]` (from worktree) | § 1 → § 2 → § 3 → § 4 → § 5 |
| `start github OWNER/REPO#N` (from worktree) | normalize to `ISSUE_ID=issue-N`, then § 1 → § 2 → § 3 → § 4 → § 5 |

---

## 1. Initialize Worktree Session

If invoked as `start github OWNER/REPO#N`, parse it before initialization:
- `TRACKER=github`
- `ISSUE_ID=issue-N`
- `GITHUB_REPO=OWNER/REPO`

**Invoke workflow**: `⤵ workflows/initialize.md § 1-2 → § 2` with context:
- `lifecycle`: `"managed"`
- `issue_id`: normalized issue ID from argument or branch
- `tracker`: `[TRACKER]` when parsed
- `github_repo`: `[GITHUB_REPO]` when parsed

---

## 2. Delegate to Specialist Agent(s)

1. **Invoke workflow**: `⤵ workflows/dev-start.md § 1-4 → § 2 step 2` with context:
   - `worktree`: [WORKTREE_PATH]
   - `lifecycle`: `"managed"`
   - `issue_id`: [ISSUE_ID]

2. **Parse return**: Branch, Commit, QA Labels, Summary.

3. **Require committed clean work before review.** Do not proceed to § 3 unless § 2 validation confirms:
   - `HEAD` advanced from the pre-dev SHA captured by `dev-start.md`.
   - The returned commit exists in `HEAD` history.
   - `git status --porcelain` is empty.

   If any check fails, re-delegate to the same dev agent with the exact missing step: commit the implemented changes, report the commit SHA, and leave the worktree clean. Never review or submit a dirty worktree.

4. **Do NOT shutdown dev agent.** Persists for § 3 fix cycles and re-delegation. Only § 5.5 shuts it down.

→ § 3

---

## 3. Run Review Cycle

**Invoke workflow**: `⤵ workflows/review-pr.md § 1-11 → § 4` with context:
- `worktree`: [WORKTREE_PATH]
- `lifecycle`: `"managed"`
- `dev_agent`: `[DOMAIN_AGENT]` from § 2
- `issue_id`: `[ISSUE_ID]`

---

## 4. Submit PR

1. **Invoke workflow**: `⤵ workflows/submit-pr.md § 1-7 → § 5` with context:
   - `worktree`: [WORKTREE_PATH]
   - `lifecycle`: `"managed"`
   - `issue_id`: `[ISSUE_ID]`

---

## 5. Finalization

### 5.1 Reconcile Fixes Against Existing Issues

**Invoke workflow**: `⤵ workflows/fix-reconcile.md § 1-9 → § 5.2` with context:
- `issue_id`: [ISSUE_ID]
- `pr_number`: from § 4

### 5.2 Post Summary & Handoff Comments

**Invoke workflow**: `⤵ workflows/post-summary.md § 1-3 → § 5.3` with context:
- `worktree`: [WORKTREE_PATH]
- `lifecycle`: `"managed"`
- `issue_id`: [ISSUE_ID]
- `pr_number`: from § 4

### 5.3 Move Linear Issue To In Review

**Do NOT mark issues Done.** Issues stay "In Review" until merge triggers Done.

1. **Resolve tracker**:
   ```bash
   .agents/skills/orch/scripts/tracker-for-issue "[ISSUE_ID]"
   ```
   Use the output as `TRACKER`.

2. **Skip if** `TRACKER=github` (GitHub issues close via PR merge keywords). → § 5.4

3. **Move to review**. After PR submission, CI, comment triage, fix reconciliation, and final comments are complete, move the managed Linear issue into review ownership:
   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --state "In Review"
   ```

→ § 5.4

### 5.4 Output Session Summary

1. **Read final state**:
   ```bash
   .agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{cycles: .cycles, fixed_count: (.fixed_items | length), escalated_count: (.escalated_items | length), pr_iterations: .pr_comment_review.iterations, pr_fixes: (.pr_comment_review.fixes | length), pr_issues: (.pr_comment_review.issues_created | length), audit_issues: (.audit_issues_created | length)}'
   ```
   Read `cycles` as `CYCLES`, `fixed_count` as `FIXED_COUNT`, `escalated_count` as `ESCALATED_COUNT`, `pr_iterations` as `PR_ITERATIONS`, `pr_fixes` as `PR_FIXES`, `pr_issues` as `PR_ISSUES`, and `audit_issues` as `AUDIT_ISSUES` from the JSON object.

2. **Output session summary**:

   <output_format>

   ### ✅ SESSION COMPLETE — [ISSUE_ID]: [TITLE]

   Sub-issues (tree):
   ↳ [SUB_ISSUE_1]: [TITLE] | blocks: [SUB_ISSUE_2]
   ↳ [SUB_ISSUE_2]: [TITLE] | blocked by: [SUB_ISSUE_1]
      ↳ [SUB_ISSUE_3]: [TITLE]  ← nested

   | Metric | Value |
   |--------|-------|
   | PR | #N |
   | Commits | N (sha1, sha2, ...) |
   | Files | N |
   | Review cycles (§ 3) | [CYCLES] |
   | Fixes applied (§ 3) | [FIXED_COUNT] |
   | Escalated | [ESCALATED_COUNT] |
   | Audit issues created (§ 3) | [AUDIT_ISSUES] |
   | PR comment iterations (§ 4) | [PR_ITERATIONS] |
   | PR comment fixes | [PR_FIXES] |
   | PR comment issues | [PR_ISSUES] |
   | CI | ✅ passing |
   | Review gate | ✅ approved / ✅ reviewed / ⏳ pending / forced / off (no reviewer policy) |
   | Unresolved threads | 0 |

   ### Issues Created

   | ID | Title | Project | Relations |
   |----|-------|---------|-----------|
   | [ISSUE_ID] | [TITLE] | [PROJECT] | blk [ISSUE_X], rel [ISSUE_Y] |

   ### Issues Updated

   | ID | Title | Changes |
   |----|-------|---------|
   | [ISSUE_ID] | [TITLE] | state: [PREVIOUS]→In Review, +rel [ISSUE_X] |

   Omit sections with no data. Include sub-issues tree if bundled.


   </output_format>

### 5.5 Shutdown Team

1. Terminate all still-active agents from `child_sessions` in workflow state.
2. Retire the terminated records so reviewer slot accounting (`review-pr.md` § 2) stops counting them:

   ```bash
   .agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.child_sessions = ((.child_sessions // {}) | with_entries(.value.status = "closed"))'
   ```

### 5.6 Offer Merge

**Skip if** no PR created (§ 4), CI not passing, or the § 4 submit-pr merge gates (`submit-pr.md` § 6.1) report `MERGE_READY = false` (unresolved review comments or an unmet reviewer-gate verdict).

→ Ask user: `orch merge-pr [PR_NUMBER]` | `Skip`

| Choice | Action |
|--------|--------|
| Merge | `⤵ workflows/merge-pr.md [PR_NUMBER] § 1-8 → end` |
| Skip | → end |

→ end
