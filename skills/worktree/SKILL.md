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

```bash
.agents/skills/worktree/scripts/worktree <command> [options]
```

Worktrees live at `<parent-of-checkout>/.worktrees/<checkout-name>/{id}` — outside the repo root, so recursive file watchers never ingest worktree build outputs and sibling repos cannot collide. `WORKTREE_BASE_DIR` overrides the parent directory.

Issue IDs that derive paths must match `[A-Za-z0-9][A-Za-z0-9._-]*` and must not contain `..`. Issue-ID resolution prefers the configured base dir and falls back to the worktree registered for the issue branch, so trees created under an older base-dir convention keep working unmoved; there is no auto-migration. Path-argument rules and canonicalization: [references/config.md](references/config.md).

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

`push` auto-rebases onto the updated base; after an auto-rebase or a completed reuse/restack, the push uses a `--force-with-lease` pinned to the observed remote OID and fails closed on remote movement, while `--no-rebase` keeps a plain push. Lease authorization internals, the `rebase-map:` stdout contract for remapping pre-rebase SHAs, the GitHub HTTPS auth fallback, and app-created-checkout resolution: [references/config.md](references/config.md).

`remove` deletes the worktree before the branch and fails closed up front on a native `git worktree lock`; `cleanup` collects only branches proven merged into `origin/<default>`, never zero-commit branches. Both preserve and name what a partial failure leaves behind — failure semantics and manual recovery: [references/recovery.md](references/recovery.md).

## `create`

Bare `create <ID>` is a new-work claim, not a discovery command. Every new-branch mode, including `--from`, checks the normalized issue branch, an explicit requested branch, and `BOT_NAME/<issue>` across worktrees, local/remote refs, and open PRs. Existing ownership exits 75 and leaves local branches unchanged — inspect or monitor owned work instead of spawning a second implementer.

- Origin remote-head or GitHub PR discovery failure exits 1 before any worktree config, branch, or target-path mutation; never interpret an outage as absence.
- Unreachable secondary remotes are skipped with a warning — they cannot hold other sessions' pushes, so only origin is required for the gate; reachable ones still count as ownership signals.
- A repository-local claim lock holds the final repeated discovery through `git worktree add`, so concurrent claims cannot both mutate.
- Run issue creates as separate commands and check each result; a shell loop's final success can hide an earlier active-work exit.

| Flag | Effect |
|------|--------|
| `--base BRANCH` | Checkout an existing remote branch into the worktree; the default branch instead starts a new issue branch from it (it is always checked out in the main checkout and is never issue-ownership evidence) |
| `--from REF` | Create a new branch (named after ID) starting from REF after the normal ownership claim gate |
| `--pr NUMBER` | Look up the branch from a GitHub PR number (implies `--base`) |
| `--reuse` | Explicitly reuse an existing issue worktree and rebase it onto `origin/<default>` |
| `--restack` | When reusing an existing worktree and its rebase onto `origin/<default>` conflicts, stop in the conflict state for resolution instead of aborting |
| `--replay` | With `--reuse`/`--restack`: run the same restack as an ordered cherry-pick replay with no rebase porcelain, for execution policies that reject `git rebase` |
| `--recover-local` | Recreate a missing worktree for the exact local-only issue branch without rebasing or rewriting its commits |

An existing owner opts in with `--reuse`, which refreshes setup after rebasing onto `origin/<default>`. Reuse/restack requires the target's exact canonical path to be registered to this repository's common Git directory; incomplete directories are preserved and exit 75. To inspect existing remote work whose issue worktree is absent, use `--pr <N>` or `--base <branch>` explicitly.

When a worktree is removed outside this tool after commits but before a push, its normalized issue branch survives locally with no checkout. Bare `create <ID>` still exits 75 for it and points at `--recover-local`, which accepts only that exact branch, never rebases/resets/deletes/rewrites it, and fails closed on any ownership signal or unreachable remote — [references/recovery.md](references/recovery.md).

### Reuse rebase conflicts

Bare `create` never rebases an existing worktree. When the `--reuse` rebase conflicts, the run aborts it and exits 1 listing the conflicting files; the worktree is left clean on its pre-rebase state, so there is no conflict to resolve in place. Two recovery paths:

1. **Resolve in place:** re-run `create <ID> --restack`. The rebase re-runs and pauses in the conflict state. Resolve the listed files, stage each with `git -C <path> add <file>`, then `worktree restack continue <ID>`; repeat if it stops again. `restack skip <ID>` drops a commit already represented by the new base; `restack abort <ID>` restores the pre-restack branch.
2. **Discard divergence:** `remove <ID>` then `create <ID>` recreates the worktree fresh from `origin/<default>`, losing the local commits that conflicted.

With no conflict, `--restack` completes the same rebase as `--reuse`. The guarded actions validate worktree-local authorization, the tool-created state token, and Git sequencer metadata before acting, and fail closed on missing, stale, or unrelated state — [references/recovery.md](references/recovery.md).

### Policy-blocked rebase (cherry-pick replay fallback)

An execution policy that rejects top-level `git rebase` porcelain (Codex `approval_policy = never`) rejects the command, not the goal — never retry the porcelain and never substitute a raw `--force` push. Add `--replay` to the guarded restack instead; the controls stay `restack continue|skip|abort <ID>`, and the tool refuses a dirty tree or a range containing a merge commit.

## Recovering a broken `.agents` link

`WORKTREE_SYMLINKS` entries (typically `.agents`) point from a worktree back into the main checkout. **Route the recovery by shape, not by whether `test -L .agents` passes**: an untracked-only entry must be a symlink, while an entry with tracked content underneath is a real directory by design, holding the tracked files plus one symlink per untracked child.

| Symptom | Recovery |
|---|---|
| Untracked-only entry missing, or a real directory instead of a symlink | `worktree fix-links <ID\|PATH>` — **from the main checkout** |
| Tracked-content entry present, but an untracked child underneath is missing its link or is itself a real path | `worktree fix-links <ID\|PATH>` — **from the main checkout** (heals per child; never overwrites a child holding data git does not track — reported instead) |
| A genuinely modified or corrupt **tracked** file | `git checkout -- <path>` — run in the checkout the file really lives in |

**`git checkout -- .agents` is never the recovery for an untracked-only entry**: the path holds no tracked content, so the command succeeds and changes nothing while the link stays broken. **Run `fix-links` from the main checkout**, since the worktree's own copy of the script is reached *through* the broken link. Until it is fixed, that tree cannot be trusted for local verification — tooling resolving paths through it reads nothing or the wrong checkout's copy.

Most clobbers heal themselves: `create` and `fix-links` install shared `post-checkout`/`post-merge`/`post-rewrite` hooks in the main checkout's hooks dir, which covers every worktree and harness ([references/hooks.md](references/hooks.md)). Auto-repair never touches a materialized path holding data git does not track, and is skipped when `core.hooksPath` is set. `fix-links` is also the repair after a manual rebase or a partially-completed `remove`, and heals a legacy parent link over tracked content ([references/config.md](references/config.md)).

**Consumers: carry this inline; do not point here.** In a consumer install this section is read *through* `.agents`, so it is unreachable exactly when it is needed, while the consumer's own tracked `AGENTS.md` / `CLAUDE.md` stays readable. Copy it verbatim:

```text
Broken `.agents` in a worktree (missing, or a real directory): from the MAIN checkout run
`.agents/skills/worktree/scripts/worktree fix-links <ID|PATH>` — never from the worktree,
and never `git checkout -- .agents` (the path holds no tracked content, so the command
changes nothing while the link stays broken). A genuinely corrupt tracked file is the other
case: `git checkout -- <path>`, run in the checkout the file really lives in (the main
checkout when the path sits under a configured symlink).
```

## Session guard (ownership leases)

`scripts/worktree-session-guard` stops cleanup from destroying a worktree a session is still working in. The lease is a **native Git worktree lock** whose reason line carries the owner and heartbeat, so `git worktree remove [--force]` refuses it and `git worktree prune` never prunes the registration — even after the directory itself is gone. Owner defaults to `$VSTACK_SESSION_OWNER`, else `$USER`; the calling workflow sets it to the issue ID.

```bash
scripts/worktree-session-guard claim   <PATH> --owner <ID>
scripts/worktree-session-guard status  <PATH> --owner <ID>   # read-only probe
scripts/worktree-session-guard release <PATH> --owner <ID>
scripts/worktree-session-guard sweep --dry-run               # every lease past the TTL
```

**Exit codes** — `status` answers "may I work here?" by exit code alone: 0 lease for this owner, 1 path not registered, 3 unclaimed, 4 locked outside the guard, 75 claimed by a different owner. Use `status`, not `claim`, to probe: `claim` takes or rewrites the lease.

**`--repo` applies only to `release`/`status`/`list`/`sweep`.** `claim` and `refresh` reject it, because the target worktree is itself a checkout of the repository. Passing it makes every claim fail; a best-effort wrapper swallows that error, so the guard looks installed while silently never claiming, with `status` returning 3 as the only symptom.

| Command | Behaviour |
|---|---|
| `worktree create` | **Never claims.** A fresh worktree is unclaimed. |
| `worktree create --reuse\|--restack` | Refuses a foreign lease by name (exit 75); **refreshes** its own in place, so a long reuse cycle cannot age past the TTL and be swept. |
| `worktree remove` | Releases **its own** lease before removing, so a claiming session can tear down its own tree. A foreign lease is left alone and refuses the removal, naming the owner. |
| `worktree cleanup` | **Never collects a claimed worktree** — not even one this session claimed, since our own lease still means work is in progress. Every skip is reported; a quiet cleanup means nothing was held back. |
| `worktree cleanup --stale [--ttl-minutes N]` | Additionally releases and collects leases past the TTL (default 720) — the abandoned-session recovery path. |

Claiming is the caller's job: the orchestrating workflow claims once the worktree is the session's, and `remove` releases at teardown. The guard's limits — shared same-issue leases, staleness without liveness, flock availability, what the lock does not block, and the `$USER` owner fallback: [references/session-guard.md](references/session-guard.md).

## System Dependencies

`git`; authenticated `gh` for new-work PR ownership discovery; `flock` for repository-local per-issue claim serialization (the session guard prefers it and falls back to a `mkdir` mutex without it); Bash 3.2+ (macOS system bash is supported).

## Configuration

Set non-sensitive defaults in committed `vstack.settings.toml` under `[env]`. Existing `.env` and `.env.local` variables still work, and `.env.local` wins for secrets or personal overrides. Setup is driven by `WORKTREE_BASE_DIR`, `WORKTREE_SYMLINKS`, `WORKTREE_RELATIVE_SYMLINKS`, `WORKTREE_COPIES`, and `WORKTREE_MKDIRS`. **Symlink untracked paths only** — an entry that shadows tracked files makes git refuse writes in that worktree while `git status` reports clean. Variable semantics, setup-path hardening, and tracked-content/`info/exclude` mechanics: [references/config.md](references/config.md).
