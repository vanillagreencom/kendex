# Git Worktree Management

Creates, lists and removes isolated git worktrees for issue work, provisioning each one with the env files, symlinks and bot git identity the main checkout has. It refuses to hand the same issue to two sessions, and a session guard keeps automated cleanup from deleting a tree someone is still working in. For a project where several agents or people work on separate issues from one clone.

## Install

```bash
kendex add vanillagreencom/kendex --skill worktree
```

Run from the main checkout of a git repository with an `origin` remote. New-work claims need an authenticated `gh` and `flock`; Bash 3.2 is enough.

## What it does

- `create ID` claims new work: it surveys existing worktrees, branches and open PRs first, and exits 75 on existing ownership rather than starting a second implementer.
- `create --reuse` resumes your own worktree with a rebase onto the default branch; `--restack` pauses on conflict for `restack continue|skip|abort`, and `--replay` gets the same result from ordered cherry-picks where a policy forbids `git rebase`.
- `push` rebases onto the updated base and publishes with a lease pinned to the remote commit it observed, so it fails closed if the remote moved.
- `remove` deletes the worktree then the branch; `cleanup` collects only worktrees whose branches are provably merged.
- `fix-links` restores the configured symlinks; `repair-links` is the hook-driven variant that never destroys untracked data.
- Hooks give worktrees that Codex Desktop and Claude Code create themselves the same provisioning.

## How it works

```bash
scripts/worktree create PROJ-123
scripts/worktree create PROJ-123 --reuse
scripts/worktree push PROJ-123
scripts/worktree list
scripts/worktree remove PROJ-123
```

Worktrees are created under `<parent-of-checkout>/.worktrees/<checkout-name>/`, beside the checkout rather than inside it, so editor file watchers never ingest worktree build outputs. The default branch comes from `origin/HEAD`, falling back to `main`. After creation the configured symlinks, copies and scratch directories are applied.

The session guard records a claim as a native `git worktree lock`, so `git worktree remove` and `git worktree prune` respect it with no cooperation from whoever runs the cleanup. Who claims, what staleness measures and the guard's limits: [references/session-guard.md](references/session-guard.md). Each command's full contract is its own `--help`.

## Customise

Put project defaults in committed `kendex.settings.toml` under `[env]`; `.env.local` wins for secrets and personal overrides, and a `.env` file is never read.

| Variable | Purpose |
|----------|---------|
| `WORKTREE_BASE_DIR` | Parent directory for created worktrees; never inside the repository root |
| `WORKTREE_DEFAULT_BRANCH` | Overrides default-branch detection |
| `WORKTREE_SYMLINKS` | Space-separated paths symlinked from the main checkout into each worktree |
| `WORKTREE_RELATIVE_SYMLINKS` | Space-separated `link=target` pairs created inside each worktree |
| `WORKTREE_COPIES` | Space-separated files copied into each worktree |
| `WORKTREE_MKDIRS` | Space-separated gitignored scratch directories created in each worktree |
| `BOT_NAME` / `BOT_EMAIL` | Git identity for worktree commits |
| `BOT_SIGNING_KEY` | SSH signing key for those commits |
| `BOT_REMOTE_NAME` / `BOT_REMOTE_URL` | Remote for bot pushes |

```toml
[env]
WORKTREE_SYMLINKS = ".env.local .cache node_modules"
WORKTREE_RELATIVE_SYMLINKS = "ui/.env=../.env.worktree"
WORKTREE_MKDIRS = "tmp"
```

Point `WORKTREE_SYMLINKS` only at paths git does not carry: an entry does nothing when git carries every path under it, and a directory holding tracked files stays a real directory with only its untracked children linked. Each key's full semantics: `scripts/worktree --help` and `scripts/worktree fix-links --help`.

Wiring the Codex Desktop and Claude Code worktree hooks: [references/hooks.md](references/hooks.md).
