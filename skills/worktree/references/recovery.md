# Recovery reference

Failure-mode specs behind the recovery routing in [../SKILL.md](../SKILL.md).

## `remove` failure semantics

`remove` deletes the worktree before deleting the local branch. Configured symlinks are never pre-stripped; a refusal issued before deletion starts leaves the worktree, its symlinks, and its branch untouched, and Git's message is reported. A failure partway through can leave the worktree partially removed: treat a removal failure as "inspect what remains" (`fix-links` restores configured symlinks); the branch is never deleted on that path. `remove` checks for a native `git worktree lock` up front and exits non-zero with a diagnostic naming the lock reason and the `git worktree unlock` command. Branch deletion uses safe `git branch -d`; if that fails after worktree removal, the script exits non-zero with a diagnostic naming the remaining branch and the manual `git branch -D` recovery command.

## `cleanup` failure semantics

`cleanup` fetches `origin`, considers non-main registered worktrees, proves each branch is merged into `origin/<default>` (or the local default branch when the remote ref is unavailable), skips branches with no commits of their own (every skip is reported), then asks Git to remove the intact worktree and deletes the proven-merged local branch. If Git cannot remove a worktree, cleanup exits nonzero and preserves its path, configured symlinks, and branch for manual recovery. If branch deletion fails after worktree removal, cleanup also exits nonzero and names the remaining branch.

## `create --recover-local` full spec

Recovery accepts only the exact normalized issue branch (for example, `CC-123` → `cc-123`), records its commit tip, recreates it at the currently configured `WORKTREE_BASE_DIR` path, verifies the same branch and tip were checked out, and reapplies all configured setup. It never rebases, resets, deletes, or rewrites the surviving branch.

The command fails closed if the target path exists; any active, stale, or incomplete worktree registration owns the branch; the branch is missing, non-commit, the default branch, unrelated to `origin/<default>`, or has an upstream; or any matching remote branch, open PR, or alternate bot-prefixed candidate exists. Recovery requires every configured remote to be reachable. Remote/PR discovery is repeated under the normal per-issue claim lock before creation.

The exact local branch tip is snapshotted before any fetch-capable step. Recovery refreshes only `origin/<default>` into its remote-tracking ref with an explicit forced, no-tags/no-prune refspec constrained to `refs/remotes/origin/*`. It does not honor a configured mirror-style fetch refspec. The local branch must still equal the snapshot immediately before creation. Inspect and reconcile any refusal instead of forcing recovery.

## Guarded restack internals

The guarded actions accept only a registered worktree whose worktree-local restack authorization, tool-created state token, and Git sequencer metadata agree on the exact remote, branch, observed remote OID, original head, and target base. `continue` and `skip` re-check the remote before and after replay, finalize the exact rewritten-head lease when complete, and fail closed on missing, stale, or unrelated state. `abort` requires the same matching local state, restores the recorded original head, and clears only the pending authorization; remote movement does not block it. Paused states created by the pre-token tool remain recoverable when all legacy authorization and sequencer fields match exactly.
