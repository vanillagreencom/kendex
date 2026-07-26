---
name: worktree
description: "Git worktree management: create, list, remove isolated working copies with env/config symlinks."
license: MIT
user-invocable: true
argument-hint: "create <ID> [--base <branch>] [--from <ref>] [--pr <N>] [--reuse|--restack|--recover-local] | restack continue|skip|abort <ID|path> | list | remove <ID|path>"
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# Worktree Management

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

Portable git worktree manager. Worktrees live outside the repo root by default — `<parent-of-checkout>/.worktrees/<checkout-name>/{id}` — so recursive editor/file watchers on the repo never ingest worktree build outputs, and sibling repos cannot collide on a shared parent dir. Projects can override the worktree parent directory with `WORKTREE_BASE_DIR`.

Issue-ID resolution prefers the configured base dir and falls back to the worktree registered for the issue branch, so trees created under an older base-dir convention keep working unmoved (`list`/`remove`/`push`/`restack`/`create --reuse`); there is no auto-migration. Path comparisons are canonical (physical, symlink-resolved on both sides), so a worktree registered under a legacy symlinked spelling and addressed via its physical path — or vice versa — is recognized as the same tree, never as a foreign one.

Issue IDs used to derive paths must match `[A-Za-z0-9][A-Za-z0-9._-]*` and must not contain `..`; examples such as `issue-779`, `CC-123`, and `ds-enforcement` are valid. Direct path arguments for mutating commands must be registered worktrees of this repository's common Git directory. `fix-links`, `codex-setup`, `codex-branch`, `claude-setup`, and `remove` refuse the main checkout and foreign worktrees; Codex app-created worktrees remain supported because they are registered git worktrees even when they live outside `WORKTREE_BASE_DIR`.

Resolves project root via `git rev-parse`, detects default branch automatically, and reads project-specific config from `.env`, `vstack.settings.toml`, then `.env.local` (`.env.local` wins).

```bash
.agents/skills/worktree/scripts/worktree <command> [options]
```

## Commands

| Command | Description |
|---------|-------------|
| `create` | Claim a new issue worktree. Refuses implicit reuse when a worktree, branch, or PR already exists. |
| `restack` | Guardedly continue, skip, or abort a tool-created paused restack. |
| `list` | List all worktrees |
| `remove` | Remove worktree, clean symlinks, prune branches |
| `cleanup` | Remove worktrees whose branches are merged |
| `path` | Print worktree path for issue ID |
| `exists` | Check if worktree exists for issue ID |
| `check` | Pre-create git state check (JSON: uncommitted, unpushed) |
| `push` | Push worktree branch with auto-rebase |
| `codex-setup` | Apply env/config setup to a Codex Desktop app-created worktree |
| `codex-branch` | Normalize a Codex Desktop app-created branch to an issue branch |
| `codex-cleanup` | Non-destructive Codex Desktop cleanup hook; app owns deletion |
| `claude-setup` | Apply env/config setup to a Claude Code-created worktree (`WorktreeCreate` hook) |
| `claude-cleanup` | Non-destructive Claude Code cleanup hook; app owns deletion |

`push ISSUE_ID` normally resolves through the configured worktree registry. When run from a checkout whose current branch already matches the normalized issue branch, it pushes that active checkout instead. This supports Codex Desktop app-created worktrees that are valid git worktrees but are not registered under `WORKTREE_BASE_DIR`.

`push` and origin fetches use the GitHub skill's `git-https-auth` behavior when
available: GitHub SSH remotes stay unchanged by default, but if `gh` auth is
valid the git command gets temporary HTTPS rewrite and `gh auth git-credential`
config. This lets Codex/GitHub-authenticated sessions push without a working
SSH key. Set `VSTACK_GITHUB_GIT_HTTPS_FALLBACK=never` to force the normal SSH
path.

When `push` performs its auto-rebase, the following push uses a scoped
`--force-with-lease` pinned to the target branch OID known before the rebase.
`create --reuse` and the supported `create --restack` conflict-recovery flow
persist the same narrowly scoped authorization in the worktree: it records the
exact observed remote OID and the exact successfully restacked local head.
`push` accepts that rewritten head or later commits built on it, still pins the
force-with-lease to the recorded remote OID, and consumes the authorization
after success. A different local rewrite, remote movement while conflict
resolution is pending, or a moved remote at push time fails closed. Plain
pushes are still used with `--no-rebase`.

`remove` deletes the worktree before deleting the local branch. Git removes the intact worktree; configured symlinks are never pre-stripped, so a refusal issued before deletion starts (a lock, for example) leaves the worktree, its symlinks, and its branch untouched, and Git's message is reported. Git's deletion is not atomic — a failure partway through can leave the worktree partially removed, so treat a removal failure as "inspect what remains" (`fix-links` restores configured symlinks) rather than "nothing happened"; the branch is never deleted on that path. A worktree carrying a native `git worktree lock` cannot be removed at all, so `remove` also checks the lock up front and exits non-zero with a diagnostic naming the lock reason (sessions record their owner there) and the `git worktree unlock` command — Git's own refusal names neither. Branch deletion uses safe `git branch -d`; if that fails after worktree removal, the script exits non-zero with a diagnostic naming the remaining branch and manual `git branch -D` recovery command.

`cleanup` fetches `origin`, considers non-main registered worktrees, proves each branch is merged into `origin/<default>` (or the local default branch when the remote ref is unavailable), asks Git to remove the intact worktree, then deletes the proven-merged local branch. If Git cannot remove a worktree, cleanup exits nonzero and preserves its path, configured symlinks, and branch for manual recovery. If branch deletion fails after worktree removal, cleanup also exits nonzero and names the remaining branch.

When a configured symlink path is already tracked in the worktree branch, the script marks that path assume-unchanged before replacing it so `git status` stays clean.

Bare `create <ID>` is a new-work claim, not a discovery command. Every new-branch mode, including `--from`, checks the normalized issue branch, an explicit requested branch, and `BOT_NAME/<issue>` across worktrees, local/remote refs, and open PRs. Existing ownership exits 75 and leaves local branches unchanged. Origin remote-head or GitHub PR discovery failure exits 1 before worktree config, branch, or target-path mutation; never interpret an outage as absence. Unreachable secondary remotes are skipped with a warning — they cannot receive other sessions' pushes, so only origin is required for the claim gate; reachable secondary remotes still count as ownership signals. A repository-local normalized-issue claim lock holds the final repeated discovery through `git worktree add`, so concurrent claims cannot both mutate. Inspect or monitor owned work instead of spawning a second implementer. Run issue creates as separate commands and check each result; do not batch them in a shell loop whose final successful command can hide an earlier active-work exit.

An existing owner may opt in with `create <ID> --reuse`, which refreshes setup after rebasing onto `origin/<default>`. Reuse/restack requires the target's exact canonical path to be registered to this repository's common Git directory; incomplete directories are preserved and exit 75. Use `--restack` only to pause that intentional rebase in a conflict state. To inspect existing remote work whose issue worktree is absent, use `create <ID> --pr <N>` or `--base <branch>` explicitly.

### Codex Desktop hooks

Let Codex Desktop own app-created worktree creation and deletion. Configure project setup/cleanup hooks to run:

```bash
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-setup "$CODEX_WORKTREE_PATH"
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-cleanup "$CODEX_WORKTREE_PATH"
```

For issue workflows, run `codex-branch ISSUE_ID "$CODEX_WORKTREE_PATH"` before orchestration if the harness did not already normalize the branch.

### Claude Code hooks

Claude Code creates worktrees itself for `--worktree` sessions, subagents with `isolation: worktree`, and desktop parallel sessions. Those run a bare `git worktree add`, so the worktree has no `.agents`, no `.claude/*` links and no `.env.local`. Point the `WorktreeCreate` hook in the consumer repo's `.claude/settings.json` at `claude-setup` to apply the same provisioning `create` does:

```bash
.agents/skills/worktree/scripts/worktree claude-setup "$CLAUDE_WORKTREE_PATH"
.agents/skills/worktree/scripts/worktree claude-cleanup "$CLAUDE_WORKTREE_PATH"
```

Keep this in **project-level** settings: the hook then applies to every Claude auth/config-dir variant on the machine, since `CLAUDE_CONFIG_DIR` only relocates user-level config.

### `create` flags

| Flag | Effect |
|------|--------|
| `--base BRANCH` | Checkout an existing remote branch into the worktree |
| `--from REF` | Create a new branch (named after ID) starting from REF after the normal ownership claim gate |
| `--pr NUMBER` | Look up the branch from a GitHub PR number (implies `--base`) |
| `--reuse` | Explicitly reuse an existing issue worktree and rebase it onto `origin/<default>` |
| `--restack` | When reusing an existing worktree and its rebase onto `origin/<default>` conflicts, stop in the conflict state for resolution instead of aborting |
| `--recover-local` | Recreate a missing worktree for the exact local-only issue branch without rebasing or rewriting its commits |

### Recovering a local-only branch after worktree loss

If an issue worktree was removed outside this tool after commits were made but before the branch was pushed, the exact normalized issue branch can survive locally without any checkout. Recover it explicitly:

```bash
.agents/skills/worktree/scripts/worktree create ISSUE_ID --recover-local
```

Recovery is not a shortcut around the new-work claim gate. Bare `create <ID>` continues to exit 75 for the surviving local branch and points the owning session to this explicit mode. Recovery accepts only the exact normalized issue branch (for example, `CC-123` → `cc-123`), records its commit tip, recreates it at the currently configured `WORKTREE_BASE_DIR` path, verifies the same branch and tip were checked out, and reapplies all configured setup. It never rebases, resets, deletes, or rewrites the surviving branch.

The command fails closed if the target path exists; any active, stale, or incomplete worktree registration owns the branch; the branch is missing, non-commit, the default branch, unrelated to `origin/<default>`, or has an upstream; or any matching remote branch, open PR, or alternate bot-prefixed candidate exists. Unlike an ordinary new-work claim, recovery requires every configured remote to be reachable because an unqueried secondary could already own the supposedly local-only branch. Remote/PR discovery is repeated under the normal per-issue claim lock before creation.

The exact local branch tip is snapshotted before any fetch-capable step. Recovery refreshes only `origin/<default>` into its remote-tracking ref with an explicit forced, no-tags/no-prune refspec; the force accepts an authoritative default-branch rewrite but is constrained to `refs/remotes/origin/*`. It does not honor a configured mirror-style fetch refspec that could prune or rewrite `refs/heads/*`. The local branch must still equal the snapshot immediately before creation. Inspect and reconcile any refusal instead of forcing recovery.

### Reuse rebase conflicts

Bare `create` never rebases an existing worktree. After the owning session opts in with `--reuse`, the branch rebases onto `origin/<default>`. If that rebase conflicts, the run aborts the rebase and exits 1 — the worktree is left clean on its pre-rebase state, so there is no conflict left to resolve in place. The error lists the conflicting files (captured before the abort) and the two supported recovery paths:

1. **Resolve in place:** re-run `create <ID> --restack`. The rebase re-runs and pauses in the conflict state. Resolve the listed files, stage each with `git -C <path> add <file>`, then run `worktree restack continue <ID>`; repeat if it stops again. If the current commit is already represented by the new base and should be omitted, use `worktree restack skip <ID>`. Use `worktree restack abort <ID>` to restore the pre-restack branch.
2. **Discard divergence:** `remove <ID>` then `create <ID>` recreates the worktree fresh from `origin/<default>`, losing the local commits that conflicted.

The guarded actions accept only a registered worktree whose worktree-local restack authorization, tool-created state token, and Git sequencer metadata agree on the exact remote, branch, observed remote OID, original head, and target base. `continue` and `skip` re-check the remote before and after replay, finalize the exact rewritten-head lease when complete, and fail closed on missing, stale, or unrelated state. `abort` requires the same matching local state, restores the recorded original head, and clears only the pending authorization; remote movement does not make that restorative action unsafe. Published paused states created by the pre-token tool remain recoverable when all legacy authorization and sequencer fields match exactly. With no conflict, `--restack` completes the same intentional rebase as `--reuse`.

### Policy-blocked rebase (cherry-pick replay fallback)

Some execution policies reject top-level `git rebase` porcelain outright — Codex `approval_policy = never` rejects it with `approval required by policy, but AskForApproval is set to Never`, and no approval can ever arrive. That rejection names the command, not the goal: do not retry the same porcelain, do not delegate it to a sub-agent, and never substitute a raw `--force` push.

**First choice — the supported tool path.** Every guarded restack command is a single simple helper invocation with no top-level rebase porcelain: `create <ID> --reuse` performs the rebase onto `origin/<default>` inside the tool and records the exact lease `worktree push` needs, `create <ID> --restack` pauses a conflicting rebase for resolution, and `worktree restack continue|skip|abort <ID>` controls the paused state. Use this path whenever the checkout is a registered issue worktree.

**Cherry-pick replay — only when the tool path is unavailable or also rejected.** The replay produces the same rebased history from single simple commands: it detaches at the new base, replays the branch's unique commits in order, moves the branch ref only after the whole replay succeeds, and publishes with the same pinned-lease model the tool uses. Run each fenced command below as exactly one command per tool call; take derived values from a previous command's printed output, never from `$(...)` substitution.

1. **Clean-worktree check** — the output must be empty; never replay over uncommitted changes:

   ```bash
   git -C <path> status --porcelain
   ```

2. **Fetch** the current remote state:

   ```bash
   git -C <path> fetch origin
   ```

3. **Record the observed remote head** — use the printed OID as `<remote-oid>` in steps 4 and 10. If the ref does not exist the branch is unpublished: skip step 4, and finish with `worktree push <ID> --set-upstream` instead of step 10.

   ```bash
   git -C <path> rev-parse refs/remotes/origin/<branch>
   ```

4. **Ancestry check** (the tool's own lease rule) — exit status must be 0. Nonzero means the remote holds commits this checkout has never observed: stop and reconcile; replaying would overwrite them.

   ```bash
   git -C <path> merge-base --is-ancestor <remote-oid> <branch>
   ```

   Also stop if there is nothing to restack: `git -C <path> merge-base --is-ancestor origin/<default> <branch>` exiting 0 means the branch already contains the new base.

5. **List the commits to replay**, oldest first, and record the list:

   ```bash
   git -C <path> log --oneline --reverse origin/<default>..<branch>
   ```

6. **Detach at the new base.** Detaching is worktree-safe: it never checks out `<default>` as a branch, so it cannot collide with the main checkout.

   ```bash
   git -C <path> checkout --detach origin/<default>
   ```

7. **Replay the unique commits in order** (same range as step 5; git applies it oldest first):

   ```bash
   git -C <path> cherry-pick origin/<default>..<branch>
   ```

   If the range contains a merge commit the replay stops without picking it; run the abort control below and use the supported tool path or manual reconciliation instead.

8. **Conflict controls** — the policy-shaped equivalents of `restack continue|skip|abort`. On a conflict stop, edit the conflicting files with harness file-edit tools (never shell redirection), stage each one, then continue:

   ```bash
   git -C <path> add <file>
   ```

   ```bash
   git -C <path> -c core.editor=true cherry-pick --continue
   ```

   `-c core.editor=true` keeps git from opening an interactive editor; it is a git flag, not an env-assignment prefix, so the command stays a single simple command. If the stopped pick is already represented by the new base (git reports the pick is now empty), skip it:

   ```bash
   git -C <path> cherry-pick --skip
   ```

   To back out entirely — the branch ref has not moved yet, so aborting restores everything; reattach afterward with `git -C <path> checkout <branch>`:

   ```bash
   git -C <path> cherry-pick --abort
   ```

9. **Verify the replayed tip and move the branch.** First confirm the new base is contained — exit status must be 0:

   ```bash
   git -C <path> merge-base --is-ancestor origin/<default> HEAD
   ```

   Then move the branch ref to the replayed tip (the first ref mutation of the whole procedure) and reattach the worktree to it:

   ```bash
   git -C <path> branch -f <branch> HEAD
   ```

   ```bash
   git -C <path> checkout <branch>
   ```

10. **Publish with the pinned lease** — the exact `<remote-oid>` recorded in step 3, so the push fails closed if the remote moved. `worktree push` refuses manual rewrites by design (its rewritten-push authorization is recorded only by the tool's own supported restack), so this one command is the documented completion; never use raw `--force`, and never an unpinned `--force-with-lease` (a background fetch can move the tracking ref and defeat it):

    ```bash
    git -C <path> push origin <branch> --force-with-lease=refs/heads/<branch>:<remote-oid>
    ```

11. **Restore worktree setup** — the replay can replace configured symlinks with tracked content, exactly like a manual rebase:

    ```bash
    .agents/skills/worktree/scripts/worktree fix-links <ID>
    ```

## Session guard (ownership leases)

`scripts/worktree-session-guard` stops cleanup from destroying a worktree a session is still working in. The lease is recorded as a **native Git worktree lock** whose reason line carries the owner and heartbeat, so `git worktree remove [--force]` refuses it and `git worktree prune` never prunes the registration — even after the directory itself is gone. That needs no cooperation from whoever runs the cleanup, which a private marker file would.

**Not yet wired into `create`/`remove`/`cleanup`** — drive it explicitly for now (vstack#877 tracks the lifecycle integration; see the note at the end of this section for why it is not automatic yet). Owner defaults to `$VSTACK_SESSION_OWNER`, else `$USER`; the workflow sets it to the issue ID:

```bash
scripts/worktree-session-guard claim   <PATH> --owner <ID>
scripts/worktree-session-guard status  <PATH> --owner <ID>   # read-only probe
scripts/worktree-session-guard release <PATH> --owner <ID>
scripts/worktree-session-guard sweep --dry-run               # every lease past the TTL
```

**Exit codes** — `status` answers "may I work here?" by exit code alone: 0 lease for this owner, 1 path not registered, 3 unclaimed, 4 locked outside the guard, 75 claimed by a different owner. Use `status`, not `claim`, to probe: `claim` takes or rewrites the lease.

**Limits, stated rather than papered over.**

The lease is scoped to the OWNER string, which the workflow sets to the issue ID, so two sessions on the same issue share one lease and either may release it. What refuses a second implementer is bare `create <ID>`, which surveys worktrees, refs, and open PRs and exits 75 on existing ownership; `create --reuse|--restack` skips that refusal by design (#571), so **nothing prevents a second implementer there**. The per-issue claim lock is not that gate either — it is a repository-local flock held only inside one `create` invocation.

Staleness is heartbeat age with **no liveness check**. The recorded pid and host identify who took a claim but are never consulted, so a session that is still running and has **outlived its TTL without refreshing** is indistinguishable from an abandoned one and will be unlocked by `release --stale` or `sweep`. Nothing refreshes a lease automatically and nothing runs `sweep` automatically; confirm the owner is really gone before releasing.

The guard requires `flock(1)` and checks only whether it is on PATH — it is a capability, not a platform, so **wherever flock is available, the claim is mandatory**, including a macOS host whose Homebrew setup installs it. Without flock the session is unguarded rather than protected.

A Git worktree lock does not block writes, commits, or rebases inside the worktree, and `git worktree remove -f -f` or a plain `rm -rf` still destroy a claimed tree — `status` and `list` exist so such a removal can be attributed afterwards.

**Why the lifecycle wiring is not in yet.** Claiming on `create` and releasing only on `remove` leaves every worktree claimed for its whole life, so a lease-aware `cleanup` stops collecting merged worktrees entirely unless `--stale` is passed — a behaviour change for every consumer, not a local one. Deciding whether that is the right trade (or whether a provably-merged branch should release the lease, since the work has landed) is a policy call, so the mechanism ships first and the wiring waits on that decision.

## System Dependencies

- `git`
- authenticated `gh` for new-work PR ownership discovery
- `flock` for repository-local per-issue claim serialization and for the session guard
- Bash 3.2+ (macOS system bash is supported)

## Configuration

Set non-sensitive defaults in committed `vstack.settings.toml` under `[env]`. Existing `.env` and `.env.local` variables still work, and `.env.local` wins for secrets or personal overrides.

| Variable | Effect |
|----------|--------|
| `WORKTREE_BASE_DIR` | Parent directory for created worktrees. Relative paths resolve from the main checkout; absolute paths and `~` are used as-is. Default: `../.worktrees/<checkout-name>` (external per-repo dir beside the checkout). Do not point it inside the repo root: worktree build outputs under the repo can exhaust recursive file-watcher (inotify) budgets |
| `WORKTREE_SYMLINKS` | Space-separated paths symlinked from main checkout into each worktree; include `.env.local` only if worktrees should share local secrets/overrides. Point entries at untracked runtime paths — see the tracked-content caveat below |
| `WORKTREE_RELATIVE_SYMLINKS` | Space-separated `path=target` symlinks created inside each worktree, with relative targets resolving from the link location |
| `WORKTREE_COPIES` | Space-separated files copied from main checkout into each worktree |
| `WORKTREE_MKDIRS` | Space-separated directories created inside each worktree with `mkdir -p`; use for gitignored scratch dirs such as `tmp` |

Configured setup paths (`WORKTREE_SYMLINKS`, `WORKTREE_COPIES`, `WORKTREE_MKDIRS`, and the path side of `WORKTREE_RELATIVE_SYMLINKS`) must be worktree-relative literal paths without `.`, `..`, absolute, backslash, or shell glob metacharacter components (`*`, `?`, `[`, `]`). A configured symlink path cannot also be, contain, or parent another configured setup path, because later mkdir/copy/link operations would follow the symlink target. Existing symlink parents are rejected before writes. Copy and mkdir destinations also reject leaf symlinks. File and relative-symlink destinations may replace an existing leaf symlink or file without following it, but refuse a real directory leaf.

**Symlink untracked paths only.** When a `WORKTREE_SYMLINKS` directory entry contains tracked files, setup marks them `assume-unchanged` so the symlink does not show as a typechange. Git then refuses to write those paths in that worktree — `cherry-pick`, `checkout`, and `merge` fail with *"local changes would be overwritten"* while `git status` reports clean, which is a hard failure to diagnose. That behavior exists for projects migrating away from committing harness config; it is wrong when the project still tracks the content. Setup warns and names the shadowed files. The fix is to narrow the entry to the untracked subpaths: symlink `.pi/agents` and `.pi/APPEND_SYSTEM.md` rather than `.pi`, so tracked `.pi/prompts/*.md` stay real files in every worktree.

`create --reuse` and `create --restack` no longer fail on this. Before rebasing, they clear the `assume-unchanged` bits, drop the configured symlinks, and restore the shadowed files from the index, so git can detach HEAD; setup is re-applied on every terminal path — success, a rebase that never started, an aborted conflict, and `restack continue`/`restack abort`. A `--restack` that pauses on conflicts deliberately stays un-shadowed, so conflicts are resolved against real files; the links come back when the restack finishes or is aborted. This makes reuse work against an entry that shadows tracked files, but it does not make that configuration correct — narrowing the entry is still the right fix, and setup still warns.

The ignore entry setup writes for each symlinked path goes into the **common** git dir's `info/exclude`, which every checkout of the repo reads — including main, where that path is a real directory rather than a symlink. A plain entry there marked the whole directory ignored in main, so `git add <tracked file under it>` refused with *"The following paths are ignored by one of your .gitignore files"* while `git status` still listed the file as modified, and it outlived the worktree (#878). When the path holds tracked content, setup now follows the entry with `!<path>/`: a trailing-slash pattern matches a real directory but **not** a symlink pointing at one, so main keeps the directory while the worktree's symlink stays ignored. Runtime-only paths keep the plain entry — many projects (vstack's own `.agents` mirror included) rely on it alone to hide the mirror in main, with no `.gitignore` rule behind it, and a negation there would fill main with untracked noise. The shape is re-evaluated on every `create`/`fix-links` against both indexes, main being authoritative, so a path that gains or loses tracked content self-heals.

Example: share local env plus generated Claude assets, but keep `.claude/CLAUDE.md` pointed at each worktree's own `AGENTS.md`:

```toml
[env]
WORKTREE_BASE_DIR = "~/dev/.worktrees/myproject"
WORKTREE_SYMLINKS = ".env.local .claude/agents .claude/hooks .claude/skills"
WORKTREE_RELATIVE_SYMLINKS = ".claude/CLAUDE.md=../AGENTS.md"
WORKTREE_MKDIRS = "tmp"
```
