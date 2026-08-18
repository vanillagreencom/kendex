# Git Worktree Management

Creates, lists, and removes isolated git worktrees for issue work, provisioning each one with the env files, config symlinks, and bot git identity the main checkout has. It refuses to hand the same issue to two sessions: `create` surveys existing worktrees, branches, and open PRs first, and a session guard keeps automated cleanup from deleting a tree someone is still working in. Codex Desktop and Claude Code create their own worktrees; hook commands here give those the same provisioning.

## How it works

```bash
scripts/worktree create PROJ-123          # claim new work
scripts/worktree create PROJ-123 --reuse  # rebase and resume your own worktree
scripts/worktree push PROJ-123
scripts/worktree list
scripts/worktree remove PROJ-123
```

Worktrees are created under `<parent-of-checkout>/.worktrees/<checkout-name>/` — beside the checkout, not inside it, so editor file watchers never ingest worktree build outputs and sibling repos cannot collide. The default branch comes from `origin/HEAD` (fallback `main`). After creation the configured symlinks, copies, and scratch directories are applied. JS dependencies install automatically only where npm is the package manager (a `package.json` with no other manager's lockfile and no non-npm `packageManager` pin; explicit npm evidence wins over an incidental foreign lockfile) — pnpm/yarn/bun workspaces provision their own dependencies. The install runs in the background with every std fd detached (a `$(create)` capture returns at once); a failure leaves its full log at `npm-install.log` inside the worktree's own gitdir (`<checkout>/.git/worktrees/<name>/`), which is private to that worktree and never shared.

`create` claims new work only. Existing ownership exits 75 without touching branches; a GitHub or remote outage exits 1 rather than being read as "nobody owns this". The owning session resumes with `--reuse`, which rebases onto the default branch — if that rebase conflicts, `--restack` pauses in the conflict state and `restack continue|skip|abort` drives it. Where the execution policy forbids `git rebase` outright, `--replay` produces the same result from ordered cherry-picks. A worktree lost outside the tool with unpushed commits is recovered with `--recover-local`.

`push` rebases onto the updated base and publishes with a lease pinned to the remote commit it observed, so it fails closed if the remote moved. `remove` deletes the worktree then the branch; `cleanup` collects only worktrees whose branches are provably merged.

The session guard records a claim as a native `git worktree lock`, so `git worktree remove` and `git worktree prune` respect it with no cooperation needed from whoever runs the cleanup. `status PATH --owner NAME` is the read-only probe and answers by exit code alone: 0 lease for this owner, 1 path not registered, 3 unclaimed, 4 locked outside the guard, 75 claimed by a different owner.

Limits worth knowing before relying on the guard:

- The lease is keyed on the owner string (the issue ID), so two sessions on the same issue share one lease. Bare `create <ID>` is what refuses a second implementer; `create --reuse|--restack` skips that refusal by design, so **nothing prevents a second implementer there**.
- Staleness is heartbeat age with no liveness probe, so a session still running that has **outlived its TTL without refreshing** will be treated as abandoned by `release --stale` and `sweep`.
- Mutations serialize through `flock(1)` when it is on PATH and a `mkdir` mutex otherwise (stock macOS ships no flock) — a capability, not a platform — so **wherever the repository's common dir is writable, the claim is mandatory**.
- `git worktree remove -f -f` and `rm -rf` still destroy a claimed worktree; `status` and `list` exist to attribute that afterwards.

Recovering a broken `.agents` link in a worktree, the app-created-worktree hooks, and the deeper failure semantics are documented in `SKILL.md` and `references/`.

## Setup

Run from the main checkout of a git repo with an `origin` remote. New-work claims need authenticated `gh` and `flock`. Put project defaults in committed `vstack.settings.toml` under `[env]`; keep secrets and personal overrides in `.env.local`. Load order is `.env`, then `vstack.settings.toml`, then `.env.local`.

| Variable | Purpose |
|----------|---------|
| `WORKTREE_BASE_DIR` | Parent directory for created worktrees (default: `../.worktrees/<checkout-name>`) |
| `WORKTREE_DEFAULT_BRANCH` | Override default branch detection |
| `WORKTREE_SYMLINKS` | Space-separated paths to symlink into worktrees |
| `WORKTREE_RELATIVE_SYMLINKS` | Space-separated `path=target` symlinks created inside each worktree |
| `WORKTREE_COPIES` | Space-separated files to copy into worktrees |
| `WORKTREE_MKDIRS` | Space-separated directories to create inside each worktree; use for gitignored scratch dirs such as `tmp` |
| `BOT_NAME` / `BOT_EMAIL` | Git identity for worktree commits |
| `BOT_SIGNING_KEY` | SSH signing key for commits |
| `BOT_REMOTE_NAME` / `BOT_REMOTE_URL` | Remote for bot pushes |

```toml
[env]
WORKTREE_BASE_DIR = "~/dev/.worktrees/myproject"
WORKTREE_SYMLINKS = ".env.local .claude/agents .claude/hooks .claude/skills"
WORKTREE_RELATIVE_SYMLINKS = ".claude/CLAUDE.md=../AGENTS.md"
WORKTREE_MKDIRS = "tmp"
```

Point `WORKTREE_SYMLINKS` at untracked paths. A directory entry containing tracked files stays a real directory with only its untracked children linked; a tracked file entry is marked assume-unchanged before replacement. Full rules: `references/config.md`.

### App-created worktrees

Codex Desktop owns creation, branch metadata, and teardown for its own worktrees — wire the project setup and cleanup hooks to `codex-setup` / `codex-cleanup`, which apply the same provisioning `create` does. Branch normalization to the lower-case issue branch runs automatically under `orch`; invoke `codex-branch <ID> "$CODEX_WORKTREE_PATH"` by hand only for a raw worktree workflow that does not go through `orch`.

`claude-setup` / `claude-cleanup` are the Claude Code equivalents for `--worktree` sessions, `isolation: worktree` subagents, and desktop parallel sessions, all of which run a bare `git worktree add` that leaves no `.agents`, `.claude/*` links, or `.env.local`. Wire `claude-setup` into the consumer repo's `.claude/settings.json` `WorktreeCreate` hook, and keep it in **project-level** settings so it covers every Claude config-dir variant on the machine.
