---
name: worktree
description: "Git worktree management: create, list, remove isolated working copies with env/config symlinks."
license: MIT
user-invocable: true
argument-hint: "create <ID> [--base <branch>] [--from <ref>] [--pr <N>] | list | remove <ID|path>"
metadata:
  author: vanillagreen
  version: "1.0.0"
---

# Worktree Management

Portable git worktree manager. Layout defaults to `project/main` (repo) + `project/trees/{id}` (worktrees); projects can override the worktree parent directory.

Resolves project root via `git rev-parse`, detects default branch automatically, and reads project-specific config from `.env`, `vstack.settings.toml`, then `.env.local` (`.env.local` wins).

```bash
.agents/skills/worktree/scripts/worktree <command> [options]
```

## Commands

| Command | Description |
|---------|-------------|
| `create` | Create worktree for issue. Reuses existing (with rebase). Auto-detects PR branches via `gh`. |
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

`push ISSUE_ID` normally resolves through the configured worktree registry. When run from a checkout whose current branch already matches the normalized issue branch, it pushes that active checkout instead. This supports Codex Desktop app-created worktrees that are valid git worktrees but are not registered under `WORKTREE_BASE_DIR`.

`remove` deletes the worktree before deleting the local branch. Branch deletion uses safe `git branch -d`; if that fails after worktree removal, the script exits non-zero with a diagnostic naming the remaining branch and manual `git branch -D` recovery command.

When a configured symlink path is already tracked in the worktree branch, the script marks that path assume-unchanged before replacing it so `git status` stays clean.

### Codex Desktop hooks

Let Codex Desktop own app-created worktree creation and deletion. Configure project setup/cleanup hooks to run:

```bash
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-setup "$CODEX_WORKTREE_PATH"
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-cleanup "$CODEX_WORKTREE_PATH"
```

For issue workflows, run `codex-branch ISSUE_ID "$CODEX_WORKTREE_PATH"` before orchestration if the harness did not already normalize the branch.

### `create` flags

| Flag | Effect |
|------|--------|
| `--base BRANCH` | Checkout an existing remote branch into the worktree |
| `--from REF` | Create a new branch (named after ID) starting from REF (branch, tag, or commit) |
| `--pr NUMBER` | Look up the branch from a GitHub PR number (implies `--base`) |

## Configuration

Set non-sensitive defaults in committed `vstack.settings.toml` under `[env]`. Existing `.env` and `.env.local` variables still work, and `.env.local` wins for secrets or personal overrides.

| Variable | Effect |
|----------|--------|
| `WORKTREE_BASE_DIR` | Parent directory for created worktrees. Relative paths resolve from the main checkout; absolute paths are used as-is. Default: `../trees` |
| `WORKTREE_SYMLINKS` | Space-separated paths symlinked from main checkout into each worktree; include `.env.local` only if worktrees should share local secrets/overrides |
| `WORKTREE_RELATIVE_SYMLINKS` | Space-separated `path=target` symlinks created inside each worktree, with relative targets resolving from the link location |
| `WORKTREE_COPIES` | Space-separated files copied from main checkout into each worktree |
| `WORKTREE_MKDIRS` | Space-separated directories created inside each worktree with `mkdir -p`; use for gitignored scratch dirs such as `tmp` |

Example: share local env plus generated Claude assets, but keep `.claude/CLAUDE.md` pointed at each worktree's own `AGENTS.md`:

```toml
[env]
WORKTREE_BASE_DIR = "../trees"
WORKTREE_SYMLINKS = ".env.local .claude/agents .claude/hooks .claude/skills"
WORKTREE_RELATIVE_SYMLINKS = ".claude/CLAUDE.md=../AGENTS.md"
WORKTREE_MKDIRS = "tmp"
```
