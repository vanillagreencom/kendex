# Recovery reference

Deep failure-mode specs behind the recovery routing in [../SKILL.md](../SKILL.md).

## `remove` failure semantics

`remove` deletes the worktree before deleting the local branch. Git removes the intact worktree; configured symlinks are never pre-stripped, so a refusal issued before deletion starts (a lock, for example) leaves the worktree, its symlinks, and its branch untouched, and Git's message is reported. Git's deletion is not atomic — a failure partway through can leave the worktree partially removed, so treat a removal failure as "inspect what remains" (`fix-links` restores configured symlinks) rather than "nothing happened"; the branch is never deleted on that path. A worktree carrying a native `git worktree lock` cannot be removed at all, so `remove` also checks the lock up front and exits non-zero with a diagnostic naming the lock reason (sessions record their owner there) and the `git worktree unlock` command — Git's own refusal names neither. Branch deletion uses safe `git branch -d`; if that fails after worktree removal, the script exits non-zero with a diagnostic naming the remaining branch and manual `git branch -D` recovery command.

## `cleanup` failure semantics

`cleanup` fetches `origin`, considers non-main registered worktrees, proves each branch is merged into `origin/<default>` (or the local default branch when the remote ref is unavailable), asks Git to remove the intact worktree, then deletes the proven-merged local branch. If Git cannot remove a worktree, cleanup exits nonzero and preserves its path, configured symlinks, and branch for manual recovery. If branch deletion fails after worktree removal, cleanup also exits nonzero and names the remaining branch.

## `create --recover-local` full spec

Recovery accepts only the exact normalized issue branch (for example, `CC-123` → `cc-123`), records its commit tip, recreates it at the currently configured `WORKTREE_BASE_DIR` path, verifies the same branch and tip were checked out, and reapplies all configured setup. It never rebases, resets, deletes, or rewrites the surviving branch.

The command fails closed if the target path exists; any active, stale, or incomplete worktree registration owns the branch; the branch is missing, non-commit, the default branch, unrelated to `origin/<default>`, or has an upstream; or any matching remote branch, open PR, or alternate bot-prefixed candidate exists. Unlike an ordinary new-work claim, recovery requires every configured remote to be reachable because an unqueried secondary could already own the supposedly local-only branch. Remote/PR discovery is repeated under the normal per-issue claim lock before creation.

The exact local branch tip is snapshotted before any fetch-capable step. Recovery refreshes only `origin/<default>` into its remote-tracking ref with an explicit forced, no-tags/no-prune refspec; the force accepts an authoritative default-branch rewrite but is constrained to `refs/remotes/origin/*`. It does not honor a configured mirror-style fetch refspec that could prune or rewrite `refs/heads/*`. The local branch must still equal the snapshot immediately before creation. Inspect and reconcile any refusal instead of forcing recovery.

## Guarded restack internals

The guarded actions accept only a registered worktree whose worktree-local restack authorization, tool-created state token, and Git sequencer metadata agree on the exact remote, branch, observed remote OID, original head, and target base. `continue` and `skip` re-check the remote before and after replay, finalize the exact rewritten-head lease when complete, and fail closed on missing, stale, or unrelated state. `abort` requires the same matching local state, restores the recorded original head, and clears only the pending authorization; remote movement does not make that restorative action unsafe. Published paused states created by the pre-token tool remain recoverable when all legacy authorization and sequencer fields match exactly.

## A worktree with a broken `.agents` link

Run `fix-links` from the main checkout:

```bash
cd /path/to/main/checkout
.agents/skills/worktree/scripts/worktree fix-links <ID|WORKTREE_PATH>
```

**A worktree whose `.agents` is not a symlink cannot be trusted for local verification.** Project tooling resolving paths through it is reading either nothing or the wrong checkout's copy. Fix the link before believing any result from that tree — and prefer tooling that fails closed with a diagnostic naming the missing file over tooling that silently degrades.
