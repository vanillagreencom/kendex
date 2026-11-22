# Start Session Workflow (Worktree)

The whole item session inside its worktree: open the session, implement, publish and review in the order § 2.1 reads, then finalize.

| Command | Flow |
|---------|------|
| `start` / `start [ISSUE_ID]` (from a worktree) | § 1 → § 5 |
| `start github OWNER/REPO#N` (from a worktree) | normalize to `ISSUE_ID=issue-N`, then § 1 → § 5 |

## 1. Open The Session

1. **Write the status file.** In a lane whose brief names a status file, `tmp/lane-status-[ISSUE_ID].md`, write it before this section's first command. Rewrite it at each step change with what the brief names.

2. **Resolve the item.** Take `[ISSUE_ID]` from the argument, or from the branch:

   ```bash
   .agents/skills/orch/scripts/git-context issue-from-branch .
   ```

   Resolve `TRACKER` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution). `[WORKTREE_PATH]` is what `git-context repo-root .` prints.

3. **Resume from a handoff.** Run [start.md](start.md) § 0 for `[ISSUE_ID]`: its `handoff-standing` read, its stop-and-report rule and its `handoff-resume` stamp. `none` → step 4. A stamped record replaces the rest of this file. Take step 6's existing-state branch and its tier write, then continue from the first entry of the record's `remaining` list. A workflow that runs this § 1, such as [small.md](small.md) § 1, names its own continuation.

4. **Refuse what is not one PR's work.** **Linear only**, before any state exists. Apply the [Ancestor gate](../references/skill-rules.md#ancestor-gate) to:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
   ```

   A Verifying item stops development preparation here. Its post-merge readings are the overseer's ([verify.md](verify.md)). A container or a blocked item stops here, with nothing leased or initialized. For a container, list its unblocked children and say this worktree should not exist for it. For a blocked item, name the live blockers.

5. **Claim the worktree.** **Skip if** `[WORKTREE_PATH]` is the main checkout, which the guard refuses.

   ```bash
   .agents/skills/worktree/scripts/worktree-session-guard claim [WORKTREE_PATH] --owner [ISSUE_ID] --adopt
   ```

   Pass no `--repo`. Exit 75 means another session holds the lease: coordinate with that owner and go no further. Exit 1 means the guard itself failed: stop and read its message. Never continue unguarded.

6. **Create the record unless it stands.** Read whether it stands, and the branch:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state exists --item [ISSUE_ID]
   ```

   ```bash
   .agents/skills/orch/scripts/git-context branch [WORKTREE_PATH]
   ```

   `[BRANCH]` is that branch output. `result.exists` false → create the record:

   ```bash
   .agents/skills/orch/scripts/orch-runtime state init --item [ISSUE_ID] --worktree [WORKTREE_PATH] --branch "[BRANCH]"
   ```

   `result.exists` true → keep the record and write where this session runs:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-route","worktree":"[WORKTREE_PATH]","branch":"[BRANCH]"}'
   ```

   Record the tier this session runs at, which lifts any bound a `small` run left on the record:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-route","tier":"standard"}'
   ```

7. **Gate on base freshness.** Every route into a worktree reaches this step, fresh or reused, except a handoff resume (step 3):

   ```bash
   .agents/skills/orch/scripts/base-freshness [WORKTREE_PATH]
   ```

   - Exit 0 → § 2. `base-freshness --help` states what reads as fresh.
   - Exit 4 → rebase through the guarded restack, which also rebases a branch at its published head. Then run the gate again; it must exit 0 before § 2:

     ```bash
     .agents/skills/worktree/scripts/worktree create [ISSUE_ID] --restack
     ```

   - Exit 1, or a restack that cannot complete → run `worktree restack abort [ISSUE_ID]` where it paused, report the divergence and stop. Never review on an unverified base.

## 2. Implement

1. **Run Workflow**: `⤵ workflows/dev-start.md § 1-4 → § 2 step 2` with context `worktree`, `lifecycle: "managed"`, `issue_id`.
2. Parse the return's `Branch`, `Commit`, `QA`, `Validate` and `Summary` lines, the fields dev-implement returns. Where the round closed `no-change` or `pass-excused`, dev-start's managed return also names that word.
3. **A `no-change` return** ends the item here, with no review, publication or merge. The round's acceptance closed it `no-change` and posted the comparison as the item's Completion Summary ([dev-start.md](dev-start.md) § Close The Round's Stages).

   **Linear only**: read the item's Done-when boxes with `linear.sh issues get [ISSUE_ID]`. Write `[WORKTREE_PATH]/tmp/no-change-evidence-[ISSUE_ID].md` with the harness file tool: one `N: [TEXT]` line per box the comparison meets, where `[TEXT]` names the Completion Summary comment and its finding. Then complete the item:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues complete [ISSUE_ID] --done-when-met [N,...] --evidence-file [WORKTREE_PATH]/tmp/no-change-evidence-[ISSUE_ID].md
   ```

   An item with no Done-when boxes omits both flags. A refusal stops the session: report its line and stop.

   **GitHub only**: the acceptance posted the comparison on the issue and closed it as completed. Where its reply's `issue.closed` reads anything but `completed`, the issue is open: run the acceptance again through [dev-start.md](dev-start.md) § Close The Round's Stages, which closes it without a second comment.

   Then run § 5.4 and end.

4. Any other return, `pass-excused` among them, needs committed, clean work: dev-start § 3's Check B passed, the returned commit in `HEAD`'s history, and an empty `git status --porcelain`. On any failure, delegate the exact missing step again under [Delegation](../references/skill-rules.md#delegation). Never review or submit a dirty worktree.
5. The dev agent stays for § 3's fix rounds under [Agent Lifecycle](../references/skill-rules.md#agent-lifecycle). § 5.4 retires it.

### 2.1 Open Early

Read the consumer's publication order (`orch-runtime pr order --help`):

```bash
.agents/skills/orch/scripts/orch-runtime pr order [WORKTREE_PATH]
```

Bind `[ORDER]` from its `pr-order=[ORDER]` line. On a refusal, report its line and stop. Record the order:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"order","order":"[ORDER]"}'
```

Every order ends at the caller's review step: § 3 here, or [small.md](small.md) § 3 when small.md runs this section.

- `review-first` → the review step.
- `open-first` → `⤵ workflows/submit-pr.md § 1-2` with context `worktree`, `lifecycle: "managed"`, `issue_id`. It pushes the commit § 2 validated and opens a pull request, not a draft. Confirm the pull request exists:

  ```bash
  .agents/skills/orch/scripts/orch-runtime pr view [WORKTREE_PATH] --json number,state
  ```

  An open pull request → the review step, which reviews the pushed head. Its fix-round commits stay local until § 4 pushes them.

- `push-first` → the same submit as `open-first`. It creates a draft and leaves auto-merge unarmed. Confirm the pull request and read its head:

  ```bash
  .agents/skills/orch/scripts/orch-runtime pr view [WORKTREE_PATH] --json number,state,headRefOid
  ```

  Bind the open pull request's head as `[HEAD_SHA]`, and bind `[REVIEW_BASE_CHECKOUT]` per [Gate-mode routing](../references/gates.md#gate-mode-routing). **Push-first first head**: before the review step, run [the review call](../references/gates.md#the-review-call) once from `[WORKTREE_PATH]` with `[MARK_READY]` `true`. It marks the draft ready and settles the head's Copilot request. Route its `request` per [Copilot requests](../references/gates.md#copilot-requests). A refusal or an `unreadable` reply stops this pass; the next pass runs the call again. A `pending` reply reading `ready-head-moved` runs the call again on the new head. Then take the review step. Keep `pr_order` at `push-first` and the lane's `Review: pending` line through the internal fix rounds.

For either early order, a failed submit return, a `no_pr` status or a read error means nothing opened to review. Record the review-first order:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"order","order":"review-first"}'
```

Then report once that the early open failed, with the line submit-pr or the read printed, and take the `review-first` row.

## 3. Review

**Run Workflow**: `⤵ workflows/review-pr.md § 1-9 → § 4` with context `worktree`, `lifecycle: "managed"`, `dev_agent` from § 2, `issue_id`.

## 4. Submit

**Linear only.** Before submit-pr can arm the pull request, move the development item to In Review. Read the item live first. A Done or Verifying item skips the move; with `pr` delivery it continues through merge-pr's merged-PR route.

In the same step, read the item's Done-when boxes against the accepted development return. A post-merge box is one whose named evidence only a deployment, installation or live use can give, such as a real create or relaunch sample. An empty listing or other branch output does not stand in for it. Before submit-pr arms, rewrite each post-merge box on the item in the form of the project-management skill's references/filing.md § Done when (`Post-merge:`, `Where:`, `Why after merge:`, `Trigger:` and `Deadline:`), so the merged item reads Verifying. Leave branch-provable boxes unticked. Their proof stands in the pull request body's `## Done-when evidence` section before arming.

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --state "In Review"
```

A failed live read stops this step.

**Run Workflow**: `⤵ workflows/submit-pr.md § 1-7 → § 5` with context `worktree`, `lifecycle: "managed"`, `issue_id`.

## 5. Finalize

After a successful `push-base` delivery, submit-pr's § 2.1 has already completed the tracker and sent the pushed-commit notice. Run § 5.4, then end: this section records no stop, writes no summaries and merges nothing.

### 5.1 Record The Final Stop

`MERGE_READY = false` keeps submit-pr's stop, or records `merge-gates-unmet` where none stands:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop record-if-empty --item [ISSUE_ID] --name merge-gates-unmet --gate merge --remaining "[UNMET_GATE_AND_REMAINING_WORK]" --comment-file [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
```

A `result.result` of `recorded` means the command wrote that file. Post it:

```bash
.agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [WORKTREE_PATH]/tmp/post-pr-stop-[ISSUE_ID].md
```

`kept` posts nothing.

`MERGE_READY = true` lifts the stop:

```bash
.agents/skills/orch/scripts/orch-runtime state post-pr-stop clear --item [ISSUE_ID]
```

### 5.2 Post Summary

**Run Workflow**: `⤵ workflows/post-summary.md § 1-3 → § 5.3` with context `worktree`, `lifecycle: "managed"`, `issue_id`, `pr_number` from § 4.

### 5.3 Session Summary

```bash
STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --item [ISSUE_ID])" && jq -c '.result.value | {cycles: .cycles, fixed_count: (.fixed_items | length), escalated_count: (.escalated_items | length), pr_iterations: .pr_comment_review.iterations, pr_fixes: (.pr_comment_review.fixes | length), pr_issues: (.pr_comment_review.issues_created | length), audit_issues: (.audit_issues_created | length), post_pr_stop: .post_pr_stop}' <<<"$STATE_READ"
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

Omit a section with no data, and include the sub-issue tree only for a bundle.

### 5.4 Retire Agents

End every agent still active in `child_sessions`, then close their records:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"children-closed"}'
```

### 5.5 Merge

**Skip if** no pull request was created. When CI is not passing, or submit-pr's § 6.1 reported `MERGE_READY = false`, return the stop § 5.1 recorded and stop.

```bash
.agents/skills/orch/scripts/orch-env ORCH_MERGE_AUTONOMY auto
```

[settings.md § Talking to you](../references/settings.md#talking-to-you) states the setting and its default.

- `auto` → merge without asking: `⤵ workflows/merge-pr.md [PR_NUMBER] § 1-7 → end`.
- Anything else → ask, with the options `orch merge-pr [PR_NUMBER]` | `Skip`. Record the question before asking it:

  ```bash
  .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"merge-asked"}'
  ```

  In a lane the ask is `lane-mail ask` and its wait ([skill-rules.md § Lane mail](../references/skill-rules.md#lane-mail)). When the answer arrives, record it:

  ```bash
  .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-pr-progress","step":"merge-answered"}'
  ```

  On a merge answer, run the same merge-pr route as `auto`.
