# Start Session Workflow (Worktree)

The full session from inside a worktree: implement → review → submit → finalize. The consumer's publication order decides when the pull request opens (§ 2.1).

| Command | Flow |
|---------|------|
| `start` / `start [ISSUE_ID]` (from a worktree) | § 1 → § 5 |
| `start github OWNER/REPO#N` (from a worktree) | normalize to `ISSUE_ID=issue-N`, then § 1 → § 5 |

## 1. Open The Session

1. **Write the status file.** In a lane whose brief names a status file, `tmp/lane-status-[ISSUE_ID].md`, write it before this section's first command, and rewrite it at each step change, holding what the brief names.

2. **Resolve identity.** Take `[ISSUE_ID]` from the argument, or from the branch:

   ```bash
   .agents/skills/orch/scripts/git-context issue-from-branch .
   ```

   Resolve `TRACKER` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution). Set `WORKTREE_PATH` to `git-context repo-root .`.

3. **Refuse containers** — Linear only, before any state exists. Apply the Ancestor gate ([references/skill-rules.md § Coordination](../references/skill-rules.md#coordination)) to:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID] --with-bundle
   ```

   A Verifying item stops development preparation here. Its live readings belong to the overseer. A container, a blocked item, or a `(one PR)` promotion all STOP here without leasing or initializing anything. A promotion: point the operator at `/orch start [PARENT_ID]`. A container: list its unblocked children and say this worktree should not exist for it. A blocked item: name the live blockers.

4. **Claim the worktree.** **Skip if** `WORKTREE_PATH` is the main checkout — the guard refuses it.

   ```bash
   .agents/skills/worktree/scripts/worktree-session-guard claim [WORKTREE_PATH] --owner [ISSUE_ID] --adopt
   ```

   `--adopt` takes over the lease the session-start hook took under this session's environment owner. Do **not** pass `--repo` (`claim` and `refresh` reject it). Exit 75 means another session holds the lease — coordinate with that owner instead of proceeding. A flock-less host still serializes through the guard's mkdir mutex; exit 1 means the guard itself failed — stop and read its message, never continue unguarded.

5. **Initialize state unless it exists.** `init` overwrites, and a restarted item's state file carries its round history (`cycles`, `fixed_items`, `patched_causes`), so read existence and the branch first:

   ```bash
   .agents/skills/orch/scripts/workflow-state exists --json [ISSUE_ID]
   .agents/skills/orch/scripts/git-context branch [WORKTREE_PATH]
   ```

   `exists` false → initialize:

   ```bash
   .agents/skills/orch/scripts/workflow-state init [ISSUE_ID] --worktree [WORKTREE_PATH] --branch "[BRANCH]"
   ```

   `exists` true → keep the state and record where this session runs:

   ```bash
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] worktree "[WORKTREE_PATH]"
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] branch "[BRANCH]"
   ```

   `[BRANCH]` is the `git-context branch` output.

   Record the tier this session runs at. It lifts any bound a `small` run left in the state; [small.md](small.md) § 1 records `small` after this step:

   ```bash
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] tier standard
   ```

6. **Gate on base freshness.** Every route into a worktree lands here — fresh or reused:

   ```bash
   .agents/skills/orch/scripts/base-freshness [WORKTREE_PATH]
   ```

   - Exit 0 → § 2. On a merge-queue base whose rules demand no up-to-date branch, a branch behind it that merges cleanly is fresh; the JSON's `reading` names what decided (`base-freshness --help`).
   - Exit 4 → rebase through the guarded restack, which rebases a branch at its published head too, then re-run the gate; it must exit 0 before § 2:

     ```bash
     .agents/skills/worktree/scripts/worktree create [ISSUE_ID] --restack
     ```

   - Exit 1, or a restack that cannot complete → `worktree restack abort [ISSUE_ID]` where it paused, report the divergence and stop. Never review on an unverified base.

## 2. Implement

1. **Run Workflow**: `⤵ workflows/dev-start.md § 1-4 → § 2 step 2` with context `worktree`, `lifecycle: "managed"`, `issue_id`.
2. Parse the return: Branch, Commit, QA, Validate, Summary (the field names dev-implement emits).
3. § 3 requires committed clean work: `HEAD` advanced from the pre-dev SHA, the returned commit in `HEAD` history, and `git status --porcelain` empty. Any failure re-delegates the exact missing step under [Delegation](../references/skill-rules.md#delegation). Never review or submit a dirty worktree.
4. Dev persistence for § 3 fix cycles follows [Agent Lifecycle](../references/skill-rules.md#agent-lifecycle). § 5.4 retires the remaining agent.

### 2.1 Open Early

Read the consumer's publication order through `pr-order --help`:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/pr-order [WORKTREE_PATH]
```

Record the order its `pr-order=` field names, `review-first` on a non-zero exit:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_order [ORDER]
```

All orders end at the caller's review step: § 3 here, or [small.md](small.md) § 3 when small.md runs this section.

- `review-first` → the review step. A non-zero exit takes this row and reports its `pr-order-error:` line once.
- `push-first` → the same early submit and existence check as `open-first` below. Submit creates a draft and leaves auto-merge unarmed. Its `ci` record accepts completed local edits with required CI pending. Keep the draft through internal fix rounds. The passing review and submit own the ready transition and combined fix push.
- `open-first` → `⤵ workflows/submit-pr.md § 1-2` with context `worktree`, `lifecycle: "managed"`, `issue_id`. It pushes the commit § 2 validated and opens a pull request, not a draft, so Copilot reviews it while the review step runs; the `open-first` recorded above keeps its § 2 step 5 from arming it. Then confirm the pull request exists:

  ```bash
  env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/orch/scripts/pr-view-json [WORKTREE_PATH] --json number,state
  ```

  An open pull request → the review step, which reviews the pushed head; its fix round commits stay local until § 4 pushes them. A failed submit return, a `no_pr` status or a read error opened nothing to review on. Record the review-first order:

  ```bash
  .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pr_order review-first
  ```

  Then report once that the early open failed, with the line submit-pr or this read printed, and take the `review-first` row.

## 3. Review

**Run Workflow**: `⤵ workflows/review-pr.md § 1-9 → § 4` with context `worktree`, `lifecycle: "managed"`, `dev_agent` from § 2, `issue_id`.

## 4. Submit

Before submit-pr can arm the PR, move a Linear development item to In Review. Read the item live first. A Done or Verifying item skips this mutation and continues through the existing merged-PR route in merge-pr. This state write belongs before arming because an armed PR can merge while submit-pr runs.

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --state "In Review"
```

**GitHub** skips both Linear commands. A failed live read stops this state step.

**Run Workflow**: `⤵ workflows/submit-pr.md § 1-7 → § 5` with context `worktree`, `lifecycle: "managed"`, `issue_id`. After an `open-first` § 2.1 this pass updates the open pull request: its § 2 step 1 pushes § 3's fix round with the fixes for Copilot's threads in one push, then writes § 3's verdict line and routes the pushed head, and its step 5 arms the head once § 3 has returned.

## 5. Finalize

Before either summary, `MERGE_READY = false` preserves submit-pr's stop or creates `merge-gates-unmet`:

```bash
.agents/skills/orch/scripts/workflow-state post-pr-stop record-if-empty [ISSUE_ID] merge-gates-unmet merge "[UNMET_GATE_AND_REMAINING_WORK]" [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
```

`recorded` wrote that file, so post it:

```bash
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
```

`kept` posts nothing. The file at that path is the one submit-pr rendered for the stop it recorded, and submit-pr already posted it; posting again would put a byte-identical duplicate on the PR.

Read the final stop before § 5.1. `MERGE_READY = true` clears it:

```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.post_pr_stop = null'
```

### 5.1 Post Summary

**Run Workflow**: `⤵ workflows/post-summary.md § 1-3 → § 5.3` with context `worktree`, `lifecycle: "managed"`, `issue_id`, `pr_number` from § 4.

### 5.3 Session Summary

```bash
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '{cycles: .cycles, fixed_count: (.fixed_items | length), escalated_count: (.escalated_items | length), pr_iterations: .pr_comment_review.iterations, pr_fixes: (.pr_comment_review.fixes | length), pr_issues: (.pr_comment_review.issues_created | length), audit_issues: (.audit_issues_created | length), post_pr_stop: .post_pr_stop}'
```

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### SESSION STATUS — [ISSUE_ID]: [TITLE]

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
| Review gate | ✅ approved / ⏳ pending / forced / off ([Gate-mode routing](../references/gates.md#gate-mode-routing)) |
| Unresolved threads | 0 |
| Stop | [POST_PR_STOP name: gate; remaining] |

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

**Skip if** no PR was created. When CI is not passing or `submit-pr.md` § 6.1 reported `MERGE_READY = false`, return the final stop already rendered in § 5 before the summaries, then stop.

```bash
.agents/skills/orch/scripts/orch-env ORCH_MERGE_AUTONOMY auto
```

`auto` → merge without asking: `⤵ workflows/merge-pr.md [PR_NUMBER] § 1-7 → end`. Anything else → ask: `orch merge-pr [PR_NUMBER]` | `Skip`, and on merge run the same workflows. A `MERGE_READY = false` state never auto-merges: `submit-pr.md` § 6.1 disarmed a PR its § 2 step 5 armed before it returned the stop.
