# Merge-pr restack cycle

Use this cycle for a `conflicting` queue-wait verdict, and for a `worktree-push-base-conflict` refusal that [submit-pr.md](submit-pr.md) § 2 step 1 routes here: steps 1-3, and step 4 returns to that step instead of `merge-pr.md`. [§ Unarm at a stop](#unarm-at-a-stop) runs step 1 alone, to unarm a PR, and pushes or restacks nothing. A base conflict is not a CI failure.

1. Unarm the PR before any push. If live `autoMergeRequest` is set, disable auto-merge first. If `isInMergeQueue` remains true, read the PR node id with `gh pr view [PR_NUMBER] --json id`, call GraphQL `dequeuePullRequest`, then re-read both fields. Either still set means hand back without pushing. This order prevents an armed PR from re-entering the queue while it is dequeued.

2. Resolve the managed worktree, then ask whether a fix round is in flight before rebasing anything:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree path [ISSUE]
   ```

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/worktree-push --check-live-round --worktree [WT_PATH] --issue [ISSUE]
   ```

   It pushes nothing. Exit 0 is the only answer that permits the restack; any other exit hands back, and the command says which it was (`worktree-push --help`). `worktree create [ISSUE] --reuse` rebases outside this check too, and carries no live-round refusal of its own.

   Then start the guarded restack:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree create [ISSUE] --restack
   ```

   No issue worktree means hand back. On conflicts, resolve every listed file, stage it, and run `worktree restack continue [ISSUE]` until complete. Never force-push over an unresolved base.

3. Push through the guarded owner:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/worktree-push --worktree [WT_PATH] --issue [ISSUE]
   ```

   This step is not skippable and no other push replaces it: the restack in step 2 rewrote every branch commit, and this command is the only thing that reconciles the SHAs workflow state recorded before it. A non-zero exit hands back, because republishing `Fixed in <sha>` replies or a closing comment over unreconciled SHAs publishes commits the branch no longer has. What it reconciles from and what its summary lines mean are in `worktree-push --help`.

4. The head changed. Re-confirm the gate mode, then return to `merge-pr.md` § 5 step 1 to read the new exact head before re-arming it and starting a new wait.

## Unarm at a stop

A PR [submit-pr.md](submit-pr.md) § 2 step 5 armed at creation stays armed until something unarms it, and a lane that stops leaves it to merge with no queue-wait guard and none of [merge-pr.md](merge-pr.md) § 5 steps 2-6. So every run that ends without a merged PR takes this section first: [submit-pr.md](submit-pr.md) § 2 step 5 on a refused re-arm, a `MERGE_READY = false` stop at [submit-pr.md](submit-pr.md) § 6.1, and every [merge-pr.md](merge-pr.md) hand-back. The caller supplies `[STATE_KEY]` and `[STOP_DIR]`, the directory its own stop route renders into.

Run step 1 above on the PR. It reads the live arm and queue membership and unarms in its order; a PR it finds neither armed nor queued needs nothing. A hand-back means its final read still found the PR armed or queued: run step 1 once more. A second hand-back replaces the caller's stop with one saying the PR is still armed, which `record` writes over any earlier stop and every later `record-if-empty` keeps, and the run ends there:

```bash
.agents/skills/orch/scripts/workflow-state post-pr-stop record [STATE_KEY] disarm-unconfirmed merge "PR #[PR_NUMBER] is still armed or queued: the lane could not disarm it, and GitHub can merge it with no lane watching" [STOP_DIR]/post-pr-stop-[STATE_KEY].md
```

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh post-comment [PR_NUMBER] --body-file [STOP_DIR]/post-pr-stop-[STATE_KEY].md
```

In a lane, also tell the overseer: write a notice naming the PR and the stop to `[STOP_DIR]/disarm-unconfirmed-[STATE_KEY].md` with the harness file-write tool, then send it:

```bash
.agents/skills/orch/scripts/lane-mail notice --item [STATE_KEY] --file [STOP_DIR]/disarm-unconfirmed-[STATE_KEY].md
```
