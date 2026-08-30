# Lane post-merge completion

This is the managed continuation after merge-pr. Skip when merge-pr returned an
armed or nonmerged result.

1. Read the durable lifecycle. Continue only for `awaiting_lane_postmerge`:

   ```bash
   .agents/skills/orch/scripts/merge-queue-watch inspect --root [MAIN_REPO_ROOT] --issue [STATE_KEY]
   ```

2. Run the project's build, install, and verification work required by its own
   instructions. This workflow defines no generic command and does not infer
   one.

3. On success, remove the issue worktree through the lifecycle owner. The
   command enters `[MAIN_REPO_ROOT]` before calling its absolute worktree helper,
   so removing the lane's original cwd cannot break the transition:

   ```bash
   [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/merge-queue-watch cleanup --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID]
   ```

4. Acknowledge lane completion only after cleanup reports `cleanup_complete`:

   ```bash
   .agents/skills/orch/scripts/merge-queue-watch acknowledge --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID] --result pass
   ```

   On project work or cleanup failure, write the command and diagnostic to `[DIAGNOSTIC_FILE]`, then
   acknowledge the failed result. The failed lifecycle is terminal and the
   overseer reports it instead of advancing the item:

   ```bash
   .agents/skills/orch/scripts/merge-queue-watch acknowledge --root [MAIN_REPO_ROOT] --issue [STATE_KEY] --watch-id [WATCH_ID] --result fail --diagnostic-file [DIAGNOSTIC_FILE]
   ```
