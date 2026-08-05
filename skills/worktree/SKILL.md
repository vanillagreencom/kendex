---
name: worktree
description: "Git worktree management: create, list, remove isolated working copies with env/config symlinks."
license: MIT
user-invocable: true
argument-hint: "create <ID> [--base <branch>] [--from <ref>] [--pr <N>] [--reuse|--restack|--recover-local] [--replay] | restack continue|skip|abort <ID|path> | list | remove <ID|path>"
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

Issue IDs used to derive paths must match `[A-Za-z0-9][A-Za-z0-9._-]*` and must not contain `..`; examples such as `issue-779`, `CC-123`, and `ds-enforcement` are valid. Issue-ID resolution prefers the configured base dir and falls back to the worktree registered for the issue branch, so trees created under an older base-dir convention keep working unmoved (`list`/`remove`/`push`/`restack`/`create --reuse`); there is no auto-migration. Path-argument rules and canonicalization: [references/config.md](references/config.md).

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
| `fix-links` / `repair-links` | Restore configured symlinks in a worktree; `repair-links` is the git-hook-driven variant that never destroys untracked data — [references/hooks.md](references/hooks.md) |
| `codex-setup` / `codex-branch` / `codex-cleanup` | Codex Desktop app-created worktree hooks — [references/hooks.md](references/hooks.md) |
| `claude-setup` / `claude-cleanup` | Claude Code worktree hooks (`WorktreeCreate`) — [references/hooks.md](references/hooks.md) |

`push` auto-rebases onto the updated base; after an auto-rebase or a completed reuse/restack, the push uses a `--force-with-lease` pinned to the observed remote OID and fails closed on remote movement, while `--no-rebase` keeps a plain push. Lease authorization internals, the GitHub HTTPS auth fallback, and app-created-checkout resolution: [references/config.md](references/config.md).

`remove` deletes the worktree before the branch and fails closed up front on a native `git worktree lock`; `cleanup` collects only branches proven merged into `origin/<default>`, never zero-commit branches. Both preserve and name what a partial failure leaves behind — failure semantics and manual recovery: [references/recovery.md](references/recovery.md).

Bare `create <ID>` is a new-work claim, not a discovery command. Every new-branch mode, including `--from`, checks the normalized issue branch, an explicit requested branch, and `BOT_NAME/<issue>` across worktrees, local/remote refs, and open PRs. Existing ownership exits 75 and leaves local branches unchanged. Origin remote-head or GitHub PR discovery failure exits 1 before worktree config, branch, or target-path mutation; never interpret an outage as absence. Unreachable secondary remotes are skipped with a warning — they cannot receive other sessions' pushes, so only origin is required for the claim gate; reachable secondary remotes still count as ownership signals. A repository-local normalized-issue claim lock holds the final repeated discovery through `git worktree add`, so concurrent claims cannot both mutate. Inspect or monitor owned work instead of spawning a second implementer. Run issue creates as separate commands and check each result; do not batch them in a shell loop whose final successful command can hide an earlier active-work exit.

An existing owner may opt in with `create <ID> --reuse`, which refreshes setup after rebasing onto `origin/<default>`. Reuse/restack requires the target's exact canonical path to be registered to this repository's common Git directory; incomplete directories are preserved and exit 75. Use `--restack` only to pause that intentional rebase in a conflict state. To inspect existing remote work whose issue worktree is absent, use `create <ID> --pr <N>` or `--base <branch>` explicitly.

### `create` flags

| Flag | Effect |
|------|--------|
| `--base BRANCH` | Checkout an existing remote branch into the worktree; the default branch instead starts a new issue branch from it (it is always checked out in the main checkout and is never issue-ownership evidence) |
| `--from REF` | Create a new branch (named after ID) starting from REF after the normal ownership claim gate |
| `--pr NUMBER` | Look up the branch from a GitHub PR number (implies `--base`) |
| `--reuse` | Explicitly reuse an existing issue worktree and rebase it onto `origin/<default>` |
| `--restack` | When reusing an existing worktree and its rebase onto `origin/<default>` conflicts, stop in the conflict state for resolution instead of aborting |
| `--replay` | With `--reuse`/`--restack`: run the same restack as an ordered cherry-pick replay with no rebase porcelain, for execution policies that reject `git rebase` |
| `--recover-local` | Recreate a missing worktree for the exact local-only issue branch without rebasing or rewriting its commits |

### Recovering a local-only branch after worktree loss

If an issue worktree was removed outside this tool after commits were made but before the branch was pushed, the exact normalized issue branch can survive locally without any checkout. Recover it explicitly with `create ISSUE_ID --recover-local`. Recovery is not a shortcut around the new-work claim gate: bare `create <ID>` continues to exit 75 for the surviving local branch and points the owning session to this explicit mode. Recovery accepts only the exact normalized issue branch and never rebases, resets, deletes, or rewrites it; it fails closed on any ownership signal or unreachable remote — full spec: [references/recovery.md](references/recovery.md).

### Reuse rebase conflicts

Bare `create` never rebases an existing worktree. After the owning session opts in with `--reuse`, the branch rebases onto `origin/<default>`. If that rebase conflicts, the run aborts the rebase and exits 1 — the worktree is left clean on its pre-rebase state, so there is no conflict left to resolve in place. The error lists the conflicting files (captured before the abort) and the two supported recovery paths:

1. **Resolve in place:** re-run `create <ID> --restack`. The rebase re-runs and pauses in the conflict state. Resolve the listed files, stage each with `git -C <path> add <file>`, then run `worktree restack continue <ID>`; repeat if it stops again. If the current commit is already represented by the new base and should be omitted, use `worktree restack skip <ID>`. Use `worktree restack abort <ID>` to restore the pre-restack branch.
2. **Discard divergence:** `remove <ID>` then `create <ID>` recreates the worktree fresh from `origin/<default>`, losing the local commits that conflicted.

With no conflict, `--restack` completes the same intentional rebase as `--reuse`. The guarded actions validate worktree-local authorization, the tool-created state token, and Git sequencer metadata before acting, and fail closed on missing, stale, or unrelated state — internals: [references/recovery.md](references/recovery.md).

### Policy-blocked rebase (cherry-pick replay fallback)

Some execution policies reject top-level `git rebase` porcelain outright (Codex `approval_policy = never`). The rejection names the command, not the goal — never retry the porcelain and never substitute a raw `--force` push. Add `--replay` to the guarded restack instead: `create <ID> --reuse --replay` (or `create <ID> --restack --replay` to pause on conflicts) produces the identical rebased history from ordered plain cherry-picks, with no rebase porcelain at any level. Conflicts pause the same guarded state with the same controls — `worktree restack continue|skip|abort <ID>` — and the finished replay records the same pinned force-with-lease authorization that `worktree push` consumes. The tool refuses a dirty tree up front (never replay over uncommitted changes). If the range contains a merge commit the replay is refused as well — use the rebase engine or reconcile manually.

## Recovering a broken `.agents` link

The configured symlinks (`WORKTREE_SYMLINKS`, typically `.agents`) point from a worktree back into the main checkout, so a large harness library is shared rather than copied per branch. **The healthy shape depends on whether the entry has tracked content underneath, so route the recovery by shape — not by whether `test -L .agents` passes.**

- **Untracked-only entry** (the common case): the entry must be a symlink. Missing, or a real directory, means the link is broken.
- **Entry with tracked content underneath** (a consumer still committing some files under `.agents`): a real directory is the correct steady state, not damage — the entry holds the tracked files git owns, plus one symlink per untracked child. Check the untracked children instead of the parent's shape.

**`git checkout -- .agents` is never the recovery for an untracked-only entry.** The path holds no tracked content, so there is nothing for git to restore; the command succeeds and changes nothing, which reads as "recovered" while the link is still broken.

| Symptom | Recovery |
|---|---|
| Untracked-only entry missing, or a real directory instead of a symlink | `worktree fix-links <ID\|PATH>` — **from the main checkout** |
| Tracked-content entry present, but an untracked child underneath is missing its link or is itself a real path | `worktree fix-links <ID\|PATH>` — **from the main checkout** (heals per child; never overwrites a child holding data git does not track — reported instead) |
| A genuinely modified or corrupt **tracked** file | `git checkout -- <path>` — run in the checkout the file really lives in |

A directory entry that contains tracked files is provisioned per child, as above: `fix-links` and hook-driven repair keep the parent real, restore any missing tracked file from the index, and re-link any untracked child that has gone missing or been replaced. A legacy worktree that still holds a parent link over tracked content (where `git checkout` writes through the link into the main checkout while `assume-unchanged` keeps `git status` clean in both) heals the same way on the next `fix-links` or hook repair ([references/config.md](references/config.md)).

Most of the time the links now heal themselves: `create` and `fix-links` install shared `post-checkout`/`post-merge`/`post-rewrite` hooks in the main checkout's hooks dir (worktrees resolve hooks there, so one install covers every worktree and every harness) that re-assert the configured symlinks after the git operations that clobber them. The auto-repair refuses to touch a materialized path holding data git does not track — it warns loudly and leaves the manual `fix-links` as the way out — and it is skipped entirely when `core.hooksPath` is set ([references/hooks.md](references/hooks.md)).

**Run `fix-links` from the main checkout, not from the broken worktree** — the worktree's own copy of this script is reached *through* the link that is broken, so invoking it from there is the one place it may not exist. `fix-links` is also the repair after any operation that can replace a configured symlink with tracked content — a manual rebase or a partially-completed `remove`. Until the link is fixed, do not trust local verification from that tree: [references/recovery.md](references/recovery.md).

**Consumers: carry this inline; do not point here.** In a consumer install this section is itself read through `.agents`, so from the worktree whose link is broken it is unreachable exactly when it is needed — a consumer repo's own tracked file (`AGENTS.md` / `CLAUDE.md`) is readable in that state, so that is where the recovery text belongs. Copy it verbatim:

```text
Broken `.agents` in a worktree (missing, or a real directory): from the MAIN checkout run
`.agents/skills/worktree/scripts/worktree fix-links <ID|PATH>` — never from the worktree,
and never `git checkout -- .agents` (the path holds no tracked content, so the command
changes nothing while the link stays broken). A genuinely corrupt tracked file is the other
case: `git checkout -- <path>`, run in the checkout the file really lives in (the main
checkout when the path sits under a configured symlink).
```

## Session guard (ownership leases)

`scripts/worktree-session-guard` stops cleanup from destroying a worktree a session is still working in. The lease is recorded as a **native Git worktree lock** whose reason line carries the owner and heartbeat, so `git worktree remove [--force]` refuses it and `git worktree prune` never prunes the registration — even after the directory itself is gone.

**Claiming is explicit; the destructive commands are wired.** Owner defaults to `$VSTACK_SESSION_OWNER`, else `$USER`; the workflow sets it to the issue ID:

```bash
scripts/worktree-session-guard claim   <PATH> --owner <ID>
scripts/worktree-session-guard status  <PATH> --owner <ID>   # read-only probe
scripts/worktree-session-guard release <PATH> --owner <ID>
scripts/worktree-session-guard sweep --dry-run               # every lease past the TTL
```

**Exit codes** — `status` answers "may I work here?" by exit code alone: 0 lease for this owner, 1 path not registered, 3 unclaimed, 4 locked outside the guard, 75 claimed by a different owner. Use `status`, not `claim`, to probe: `claim` takes or rewrites the lease.

**`--repo` applies only to `release`/`status`/`list`/`sweep`.** `claim` and `refresh` reject it, because the target worktree is itself a checkout of the repository. Passing it makes every claim fail, and a best-effort wrapper around that swallows the error — the guard then looks installed while silently never claiming, with `status` returning 3 as the only symptom.

### Lifecycle

| Command | Behaviour |
|---|---|
| `worktree create` | **Never claims.** A fresh worktree is unclaimed. |
| `worktree create --reuse\|--restack` | Refuses a foreign lease by name (exit 75); **refreshes** its own in place, so a long reuse cycle cannot age past the TTL and be swept. |
| `worktree remove` | Releases **its own** lease before removing, so a claiming session can tear down its own tree. A foreign lease is left alone and refuses the removal, naming the owner. |
| `worktree cleanup` | **Never collects a claimed worktree** — not even one this session claimed, since our own lease still means work is in progress. Every skip is reported; a quiet cleanup means nothing was held back. |
| `worktree cleanup --stale [--ttl-minutes N]` | Additionally releases and collects leases past the TTL (default 720) — the abandoned-session recovery path. |

Claiming is the caller's job: orch claims in `orch/workflows/initialize.md` once the worktree is the session's, and `remove` releases at teardown. Design rationale and the guard's limits — shared same-issue leases, staleness without liveness, flock availability, what the lock does not block, and the `$USER` owner fallback: [references/session-guard.md](references/session-guard.md).

## System Dependencies

`git`; authenticated `gh` for new-work PR ownership discovery; `flock` for repository-local per-issue claim serialization (the session guard prefers it and falls back to a `mkdir` mutex without it); Bash 3.2+ (macOS system bash is supported).

## Configuration

Set non-sensitive defaults in committed `vstack.settings.toml` under `[env]`. Existing `.env` and `.env.local` variables still work, and `.env.local` wins for secrets or personal overrides. Setup is driven by `WORKTREE_BASE_DIR` (worktree parent directory), `WORKTREE_SYMLINKS`, `WORKTREE_RELATIVE_SYMLINKS`, `WORKTREE_COPIES`, and `WORKTREE_MKDIRS`. **Symlink untracked paths only** — an entry that shadows tracked files makes git refuse writes in that worktree while `git status` reports clean. Variable semantics, setup-path hardening, tracked-content and `info/exclude` mechanics, and a worked example: [references/config.md](references/config.md).
