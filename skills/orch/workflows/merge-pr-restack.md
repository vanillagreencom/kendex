# Merge-pr restack cycle

Use this cycle only for a `conflicting` queue-wait verdict. A base conflict is
not a CI failure.

1. Unarm the PR before any push. If live `autoMergeRequest` is set, disable
   auto-merge first. If `isInMergeQueue` remains true, read the PR node id with
   `gh pr view [PR_NUMBER] --json id`, call GraphQL `dequeuePullRequest`, then
   re-read both fields. Either still set means hand back without pushing. This
   order prevents an armed PR from re-entering the queue while it is dequeued.

2. Resolve the managed worktree, then check for a live fix round before
   rebasing anything:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree path [ISSUE]
   ```
   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/workflow-state get [ISSUE] '.dev_round_id // empty'
   ```

   A printed token whose record `[WT_PATH]/tmp/dev-round-[ISSUE]-[TOKEN].json`
   exists with no `[WT_PATH]/tmp/dev-return-[ISSUE]-[TOKEN].json` beside it is a
   round in flight: hand back without restacking. This is the same refusal
   `worktree-push` makes, at the one path that rebases without reaching it —
   the round record pins the commit the delegated agent is working from, and
   the restack moves the branch out from under it. Land that round's receipt,
   or stamp a fresh `dev_round_id`, then restack. No token, no record, or a
   receipt already beside it means no round is in flight.

   Then start the guarded restack:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/worktree/scripts/worktree create [ISSUE] --restack
   ```

   No issue worktree means hand back. On conflicts, resolve every listed file,
   stage it, and run `worktree restack continue [ISSUE]` until complete. Never
   force-push over an unresolved base.

3. Push through the guarded owner:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/worktree-push --worktree [WT_PATH] --issue [ISSUE]
   ```

4. The head changed. Re-confirm the gate mode, then return to
   `merge-pr.md` § 5 step 1 to read the new exact head before re-arming it and
   starting a new wait.
