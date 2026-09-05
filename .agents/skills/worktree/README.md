# Git Worktree Management

A CLI for separate Git working copies. Teams can work on independent issues while each copy receives the project's configured files, links and Git identity.

## Install

```bash
kendex add vanillagreencom/kendex --skill worktree
```

Run from the main checkout of a Git repository with an origin remote. Claiming work requires authenticated gh and flock. Bash 3.2 is supported.

## Features

- Create or resume a worktree for an issue.
- Check for existing work before assigning the same issue again.
- Update a branch and publish it with a check for remote changes.
- Remove merged worktrees and repair configured links.
- Protect active worktrees with Git worktree locks.

## How it works

You give the CLI an issue identifier. It checks existing worktrees, branches and PRs before creating a working copy. It adds the configured links, copied files and scratch directories. The worktree holds a separate branch for the assigned change. Push and cleanup commands use the recorded branch state to complete the work.

## Settings

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
