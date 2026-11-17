# Git Worktree Management

A CLI for separate Git working copies. Teams can work on independent issues while each copy receives the project's configured files, links and Git identity.

## Features

- Create or resume a worktree for an issue.
- Check for existing work before assigning the same issue again.
- Update a branch and publish it with a check for remote changes.
- Remove merged worktrees and repair configured links.
- Protect active worktrees with Git worktree locks.

## Install

```bash
kendex add vanillagreencom/kendex --skill worktree
```

## How it works

You give the CLI an issue identifier. It checks existing worktrees, branches and PRs before creating a working copy. It adds the configured links, copied files and scratch directories. The worktree holds a separate branch for the assigned change. Push and cleanup commands use the recorded branch state to complete the work.

## Setup

Run from the main checkout of a Git repository with an origin remote. Claiming work requires authenticated gh and flock. Bash 3.2 is supported.

Put project defaults in committed `kendex.settings.toml` under `[env]`; `.env.local` wins for secrets and personal overrides, and a `.env` file is never read.

| Variable | Purpose |
|----------|---------|
| `WORKTREE_BASE_DIR` | Parent directory for created worktrees; never inside the repository root |
| `WORKTREE_HOSTED_NAME` | Directory name for a hosted lane's worktree (`create --hosted`) |
| `WORKTREE_DEFAULT_BRANCH` | Overrides the repository's default branch |
| `WORKTREE_SYMLINKS` | Space-separated untracked paths symlinked from the main checkout into each worktree |
| `WORKTREE_RELATIVE_SYMLINKS` | Space-separated `link=target` pairs created inside each worktree |
| `WORKTREE_COPIES` | Space-separated files copied from the main checkout only when neither checkout's Git index owns them; Git-owned files stay with their checkout |
| `WORKTREE_MKDIRS` | Space-separated gitignored scratch directories created in each worktree |
| `WORKTREE_SETUP_CMD` | Optional Bash command run after file and Git setup. A failure keeps the worktree for retry through `create --reuse` or the app setup hook |
| `BOT_NAME` / `BOT_EMAIL` | Git identity for worktree commits |
| `BOT_SIGNING_KEY` | SSH signing key for those commits |
| `BOT_REMOTE_NAME` / `BOT_REMOTE_URL` | Remote for bot pushes |

```toml
[env]
# An npm project; pnpm and Next.js need the private install described below.
WORKTREE_SYMLINKS = ".env.local .cache node_modules"
WORKTREE_RELATIVE_SYMLINKS = "ui/.env=../.env.worktree"
WORKTREE_MKDIRS = "tmp"
```

For pnpm or Next.js, leave `node_modules` out of `WORKTREE_SYMLINKS` and set `WORKTREE_SETUP_CMD = "pnpm install --frozen-lockfile"`. Each worktree then receives its own dependencies. pnpm hard-links packages from its store.

Hosted creates run this command on the lane host. The provider must deliver private files before the create that runs setup.

Use the full path to `scripts/worktree` in the installed skill directory containing this README, and keep your working directory at the repository's main checkout. Run that executable with `--help` for each key's full semantics, default-branch fallback and refusal conditions, setup requirements and retries. Run it with `fix-links --help` for links beside tracked files.

Wiring the Codex Desktop and Claude Code worktree hooks: [references/hooks.md](references/hooks.md).

## Licence

MIT, in the repository's LICENSE file.
