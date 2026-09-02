# Start Session Workflow (Worktree)

The full session from inside a worktree: implement → review → submit → finalize.

| Command | Flow |
|---------|------|
| `start` / `start [ISSUE_ID]` (from a worktree) | § 1 → § 5 |
| `start github OWNER/REPO#N` (from a worktree) | normalize to `ISSUE_ID=issue-N`, then § 1 → § 5 |

## 1. Open The Session

1. **Resolve identity.** Take `[ISSUE_ID]` from the argument, or from the branch:

   ```bash
   .agents/skills/orch/scripts/git-context issue-from-branch .
   ```

   Resolve `TRACKER` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution). Set `WORKTREE_PATH` to `git-context repo-root .`.

2. **Refuse containers** — Linear only, before any state exists. Apply the Ancestor gate ([SKILL.md § Coordination](../SKILL.md#coordination)) to:

   ```bash
   .agents/skills/linear/scripts/linear.sh sync --reconcile
   .agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --with-bundle
   ```

   A container, a blocked child, or a `(one PR)` promotion all STOP here without leasing or initializing anything. A promotion: point the operator at `/orch start [PARENT_ID]`. A container: list its unblocked children and say this worktree should not exist for it. A blocked child: name the live blockers.

3. **Claim the worktree.** **Skip if** `WORKTREE_PATH` is the main checkout — the guard refuses it.

   ```bash
   .agents/skills/worktree/scripts/worktree-session-guard claim [WORKTREE_PATH] --owner [ISSUE_ID]
   ```

   Do **not** pass `--repo` (`claim` and `refresh` reject it). Exit 75 means another session holds the lease — coordinate with that owner instead of proceeding. A flock-less host still serializes through the guard's mkdir mutex; exit 1 means the guard itself failed — stop and read its message, never continue unguarded.

4. **Initialize state**:

   ```bash
   .agents/skills/orch/scripts/git-context branch [WORKTREE_PATH]
   .agents/skills/orch/scripts/workflow-state init [ISSUE_ID] --worktree [WORKTREE_PATH] --branch "[BRANCH_FROM_PREVIOUS_COMMAND]"
   ```

5. **Gate on base freshness.** Every route into a worktree lands here — fresh or reused:

   ```bash
   .agents/skills/orch/scripts/base-freshness [WORKTREE_PATH]
   ```

   - Exit 0 → § 2.
   - Exit 4 → rebase through the supported reuse path, then re-run the gate; it must exit 0 before § 2:

     ```bash
     .agents/skills/worktree/scripts/worktree create [ISSUE_ID] --reuse
     ```

   - Exit 1, or a reuse that cannot complete → report the divergence and stop. Never review on an unverified base.

## 2. Implement

1. **Run Workflow**: `⤵ workflows/dev-start.md § 1-4 → § 2 step 2` with context `worktree`, `lifecycle: "managed"`, `issue_id`.
2. Parse the return: Branch, Commit, QA, Validate, Summary (the field names dev-implement emits).
3. § 3 requires committed clean work: `HEAD` advanced from the pre-dev SHA, the returned commit in `HEAD` history, and `git status --porcelain` empty. Any failure re-delegates to the same dev agent with the exact missing step. Never review or submit a dirty worktree.
4. **Do not shut the dev agent down** — it persists for § 3 fix cycles. Only § 5.4 retires it.

## 3. Review

**Run Workflow**: `⤵ workflows/review-pr.md § 1-9 → § 4` with context `worktree`, `lifecycle: "managed"`, `dev_agent` from § 2, `issue_id`.

## 4. Submit

**Run Workflow**: `⤵ workflows/submit-pr.md § 1-7 → § 5` with context `worktree`, `lifecycle: "managed"`, `issue_id`.

## 5. Finalize

### 5.1 Post Summary

**Run Workflow**: `⤵ workflows/post-summary.md § 1-3 → § 5.2` with context `worktree`, `lifecycle: "managed"`, `issue_id`, `pr_number` from § 4.

### 5.2 Move The Issue To In Review

**Skip if** `TRACKER=github`.

```bash
.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --state "In Review"
```

### 5.3 Session Summary

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{cycles: .cycles, fixed_count: (.fixed_items | length), escalated_count: (.escalated_items | length), pr_iterations: .pr_comment_review.iterations, pr_fixes: (.pr_comment_review.fixes | length), pr_issues: (.pr_comment_review.issues_created | length), audit_issues: (.audit_issues_created | length)}'
```

<output_format>

### ✅ SESSION COMPLETE — [ISSUE_ID]: [TITLE]

Sub-issues (tree):
↳ [SUB_ISSUE_1]: [TITLE] | blocks: [SUB_ISSUE_2]
↳ [SUB_ISSUE_2]: [TITLE] | blocked by: [SUB_ISSUE_1]

| Metric | Value |
|--------|-------|
| PR | #N |
| Commits | N (sha1, sha2, ...) |
| Files | N |
| Fix rounds | [CYCLES] |
| Fixes applied | [FIXED_COUNT] |
| Escalated | [ESCALATED_COUNT] |
| Audit issues created | [AUDIT_ISSUES] |
| PR comment iterations | [PR_ITERATIONS] |
| PR comment fixes | [PR_FIXES] |
| PR comment issues | [PR_ISSUES] |
| CI | ✅ passing |
| Review gate | ✅ approved / ✅ reviewed / ⏳ pending / forced / off (no reviewer policy) |
| Unresolved threads | 0 |

### Issues Created

| ID | Title | Project | Relations |
|----|-------|---------|-----------|
| [ISSUE_ID] | [TITLE] | [PROJECT] | blk [ISSUE_X], rel [ISSUE_Y] |

</output_format>

Omit sections with no data; include the sub-issue tree only for a bundle.

### 5.4 Retire Agents

Terminate every still-active agent in `child_sessions`, then retire the records:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.child_sessions = ((.child_sessions // {}) | with_entries(.value.status = "closed"))'
```

### 5.5 Merge

**Skip if** no PR was created, CI is not passing, or `submit-pr.md` § 6.1 reported `MERGE_READY = false`.

```bash
.agents/skills/orch/scripts/orch-env ORCH_MERGE_AUTONOMY ask
```

`auto` → merge without asking: `⤵ workflows/merge-pr.md [PR_NUMBER] § 1-7 → end`. Anything else → ask: `orch merge-pr [PR_NUMBER]` | `Skip`, and on merge run the same workflows. A `MERGE_READY = false` state never auto-merges.
