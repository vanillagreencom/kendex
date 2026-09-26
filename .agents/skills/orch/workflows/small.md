# Small Workflow

The tier for a change inside one subsystem and within the `small` ceiling in [references/narrow-change.conf](../references/narrow-change.conf). It runs [start-worktree.md](start-worktree.md)'s session, dev implementation, review, submit and merge, under the bounds in § 3. [oversee.md](oversee.md) § Item Tier picks the tier; a `micro` item runs [micro.md](micro.md) and every other item runs [start.md](start.md).

| Command | Flow |
|---------|------|
| `small [ISSUE_ID]` (from a worktree) | § 1 → § 5 |
| `small github OWNER/REPO#N` (from a worktree) | normalize to `ISSUE_ID=issue-N`, then § 1 → § 5 |

The runner is a lane in the item's worktree. From the main checkout, [start.md](start.md) prepares the worktree first.

A lane never waits on the overseer for a step this workflow permits: [skill-rules.md § Coordination](../references/skill-rules.md#coordination), Lane asks.

## 1. Open The Session

Run [start-worktree.md](start-worktree.md) § 1. Then record the tier, which is what bounds § 3:

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

- **Panel.** The first-cycle panel is the domains the diff touches, by [review-pr.md](review-pr.md) § 2 Prepare Reviewers, and holds three reviewers at most. `workflow-state` refuses a larger panel as `panel-bound`.
- **QA.** [review-pr.md](review-pr.md) § 5 keeps a QA signal only when the change is visible in the UI or in the CLI output. Otherwise record `qa_decision` with no signals and the rationale `small tier: nothing visible`.
- **Fix rounds.** One fix round for blockers, then one re-review narrowed to the fix diff: `workflow-state cap REVIEW_MAX_CYCLES` reads `1` for this item.
- **Findings.** A wording, naming or index finding is answered by reply and starts no fix push: [finding-disposition.md § Decision flow](../references/finding-disposition.md#decision-flow).
- **Validation.** The implement round runs the full `DEV_VALIDATE_CMD` once. A fix round validates its own range, as [dev-fix.md](dev-fix.md) delegates it. No step reruns a green battery on an unchanged tree.

Before § 4, repeat the § 2 check on the tree the review left. `tier=small` continues; anything else escapes.

## 4. Submit

Run [start-worktree.md](start-worktree.md) § 4. Bot threads get two rounds: `workflow-state cap REVIEW_MAX_EXTERNAL_ROUNDS` reads `2` for this item, and at that cap [review-pr-comments.md](review-pr-comments.md) answers every standing thread by reply.

## 5. Finalize

Run [start-worktree.md](start-worktree.md) § 5.

## Escape

A branch whose class is wider than `small` ends this run. The run stops where it stands and reports the `item-tier` line. The item relaunches at the class that line names, on the branch it left, by the route [micro.md](micro.md) § Escape gives a lane.
