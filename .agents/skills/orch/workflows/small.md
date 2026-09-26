# Small Workflow

The tier for a change inside one subsystem and within the `small` ceiling in [references/narrow-change.conf](../references/narrow-change.conf). It runs [start-worktree.md](start-worktree.md)'s session, dev implementation, review, submit and merge, under the bounds in § 3. [oversee.md](oversee.md) § Item Tier picks the tier; a `micro` item runs [micro.md](micro.md) and every other item runs [start.md](start.md).

| Command | Flow |
|---------|------|
| `small [ISSUE_ID]` (from a worktree) | § 1 → § 5 |
| `small github OWNER/REPO#N` (from a worktree) | normalize to `ISSUE_ID=issue-N`, then § 1 → § 5 |
| `small [ISSUE_ID]` (from the main checkout) | [start.md](start.md) § 1 Route through § 4 Prepare Worktree, then § 1 → § 5 here in `[WT_PATH]`, in place of start.md § 5 |

The runner is a lane in the item's worktree, or a session that prepared one from the main checkout by the route above.

A lane never waits on the overseer for a step this workflow permits: [skill-rules.md § Coordination](../references/skill-rules.md#coordination), Lane asks.

## 1. Open The Session

Run [start-worktree.md](start-worktree.md) § 1, which records the tier as `standard`. Then record it as `small`, which is what bounds § 3 and § 4:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] tier small
```

## 2. Implement

Run [start-worktree.md](start-worktree.md) § 2. Then check the branch against its class:

```bash
.agents/skills/orch/scripts/item-tier --floor small --base origin/[BASE_BRANCH] --head HEAD --repo [WORKTREE_PATH]
```

`[BASE_BRANCH]` is `resolve-base-branch [WORKTREE_PATH]`. `tier=small` continues. Any other answer, or a non-zero exit, escapes (§ Escape).

## 3. Review

Run [start-worktree.md](start-worktree.md) § 3 under these bounds:

- **Panel.** The first-cycle panel is the domains the diff touches, by [review-pr.md](review-pr.md) § 2 Prepare Reviewers, and holds three reviewers at most. `workflow-state` refuses a larger `first_panel`, `rereview_panel` or `verification_panel` as `panel-bound`. Trim a larger panel to three in this order: `reviewer-error` where review-pr.md § 2 always carries it, then the reviewers whose findings the pass verifies, then the domains with the most changed production lines. The same trim applies to the verification panel [review-pr-comments.md](review-pr-comments.md) writes.
- **QA.** [review-pr.md](review-pr.md) § 5 drops `needs-review` when the change is not visible in the UI or in the CLI output, recording `qa_decision` with the rationale `small tier: nothing visible`. `needs-safety-audit` and `needs-perf-test` follow review-pr.md § 5 unchanged.
- **Fix rounds.** One fix round for blockers, then one re-review narrowed to the fix diff: `workflow-state cap REVIEW_MAX_CYCLES --issue [ISSUE_ID]` reads a cap of 1 for this item.
- **Findings.** A wording, naming or index finding is answered by reply and starts no fix push: [finding-disposition.md § Decision flow](../references/finding-disposition.md#decision-flow).
- **Validation.** The implement round runs the full `DEV_VALIDATE_CMD` once. A fix round validates its own range, as [dev-fix.md](dev-fix.md) delegates it. No step reruns a green battery on an unchanged tree.

Before § 4, repeat the § 2 check on the tree the review left. `tier=small` continues; anything else escapes.

## 4. Submit

Run [start-worktree.md](start-worktree.md) § 4. Bot threads get two rounds: `workflow-state cap REVIEW_MAX_EXTERNAL_ROUNDS --issue [ISSUE_ID]` reads a cap of 2 for this item, and at that cap [review-pr-comments.md](review-pr-comments.md) answers every standing thread by reply.

## 5. Finalize

Run [start-worktree.md](start-worktree.md) § 5.

## Escape

A branch whose class is wider than `small` ends this run. The run stops where it stands and reports the `item-tier` line. The item relaunches at the class that line names, on the branch it left, by the route [micro.md](micro.md) § Escape gives a lane. That session's [start-worktree.md](start-worktree.md) § 1 records the tier as `standard`, which lifts this workflow's bounds.
