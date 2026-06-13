# Git Worktree Management

Git worktree lifecycle management with env/config symlinks.

## Structure

```
skills/worktree/
├── SKILL.md          # Agent-facing skill definition
└── scripts/
    └── worktree      # Entry point
```

## Setup

Run from the main checkout of a git repo with an `origin` remote. Optionally add committed settings in `vstack.settings.toml` and local secrets/overrides in `.env.local`.

```bash
./scripts/worktree create PROJ-123
./scripts/worktree list
./scripts/worktree remove PROJ-123
```

Defaults: detects branch from `origin/HEAD` (fallback: `main`), creates worktrees under sibling `trees/`, then applies configured symlinks and copies. Set `WORKTREE_BASE_DIR` to use another parent directory; relative paths resolve from the main checkout, absolute paths are used as-is.

`remove` deletes the worktree first, then tries `git branch -d` for the associated local branch. If Git refuses the safe branch delete (for example, the branch is not merged into the current main checkout), the command exits non-zero and prints a diagnostic naming the remaining branch plus the manual `git branch -D` recovery command.

## Codex Desktop

When running inside Codex Desktop, let the app own worktree creation, branch metadata, and environment teardown. Use this script only as the project setup/cleanup hook for app-created worktrees.

Setup script:

```bash
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-setup "$CODEX_WORKTREE_PATH"
```

Cleanup script:

```bash
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-cleanup "$CODEX_WORKTREE_PATH"
```

`codex-branch` normalization is automatic under `orch`: `session-init` runs it for you when you invoke `initialize [ISSUE_ID]` or `start [ISSUE_ID]` in a Codex-managed worktree. You only need to run it by hand for a raw worktree workflow that does not go through `orch`:

```bash
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-branch CC-123 "$CODEX_WORKTREE_PATH"
```

From a Codex Desktop app-created worktree, `worktree push CC-123` pushes the active checkout when its current branch matches `cc-123`. It does not require the app-created worktree to live under the configured `WORKTREE_BASE_DIR` registry.

`codex-setup` applies the same env/config symlinks, copies, mkdirs, bot remote, bot git identity, and lightweight dependency bootstrap that `create` applies after creating a worktree. `codex-branch` renames or switches the app-created worktree branch to the lower-case issue branch expected by `orch`. `codex-cleanup` is intentionally a no-op lifecycle hook for this script; Codex owns app-created worktree and branch deletion. Keep project-level teardown such as stopping containers or removing disposable caches in the Codex environment cleanup script after this command, but do not call `worktree remove` from the hook.

## Configuration

Set non-sensitive project defaults in `vstack.settings.toml` under `[env]`. Existing `.env` and `.env.local` files still work; load order is `.env`, then `vstack.settings.toml`, then `.env.local`.

| Variable | Purpose |
|----------|---------|
| `WORKTREE_BASE_DIR` | Parent directory for created worktrees (default: `../trees`) |
| `WORKTREE_DEFAULT_BRANCH` | Override default branch detection |
| `WORKTREE_SYMLINKS` | Space-separated paths to symlink into worktrees |
| `WORKTREE_RELATIVE_SYMLINKS` | Space-separated `path=target` symlinks created inside each worktree |
| `WORKTREE_COPIES` | Space-separated files to copy into worktrees |
| `WORKTREE_MKDIRS` | Space-separated directories to create inside each worktree with `mkdir -p`; use for gitignored scratch dirs such as `tmp` |
| `BOT_NAME` / `BOT_EMAIL` | Git identity for worktree commits |
| `BOT_SIGNING_KEY` | SSH signing key for commits |
| `BOT_REMOTE_NAME` / `BOT_REMOTE_URL` | Remote for bot pushes |

Include `.env.local` in `WORKTREE_SYMLINKS` only when worktree sessions should share the main checkout's local secrets or personal overrides. Public settings should live in committed `vstack.settings.toml`.
If a configured symlink path is already tracked in the worktree branch, the script marks that path assume-unchanged before replacing it so `git status` stays clean.

Example for sharing local env plus generated Claude assets while keeping `.claude/CLAUDE.md`
pointed at each worktree's own `AGENTS.md`:

```toml
[env]
WORKTREE_BASE_DIR = "../trees"
WORKTREE_SYMLINKS = ".env.local .claude/agents .claude/hooks .claude/skills"
WORKTREE_RELATIVE_SYMLINKS = ".claude/CLAUDE.md=../AGENTS.md"
WORKTREE_MKDIRS = "tmp"
```
