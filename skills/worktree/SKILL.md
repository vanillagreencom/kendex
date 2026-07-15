---
name: worktree
description: "Git worktree management: create, list, remove isolated working copies with env/config symlinks."
license: MIT
user-invocable: true
argument-hint: "create <ID> [--base <branch>] [--from <ref>] [--pr <N>] [--reuse|--restack] | list | remove <ID|path>"
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
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
| `create` | Claim a new issue worktree. Refuses implicit reuse when a worktree, branch, or PR already exists. |
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

`push` and origin fetches use the GitHub skill's `git-https-auth` behavior when
available: GitHub SSH remotes stay unchanged by default, but if `gh` auth is
valid the git command gets temporary HTTPS rewrite and `gh auth git-credential`
config. This lets Codex/GitHub-authenticated sessions push without a working
SSH key. Set `VSTACK_GITHUB_GIT_HTTPS_FALLBACK=never` to force the normal SSH
path.

When `push` performs its auto-rebase, the following push uses a scoped
`--force-with-lease` pinned to the target branch OID known before the rebase.
Plain pushes are still used when `--no-rebase` is passed or no auto-rebase
runs. If the remote branch has advanced beyond the local branch, `push` aborts
and asks the user to fetch/rebase/merge first instead of overwriting unseen
remote commits.

`remove` deletes the worktree before deleting the local branch. Branch deletion uses safe `git branch -d`; if that fails after worktree removal, the script exits non-zero with a diagnostic naming the remaining branch and manual `git branch -D` recovery command.

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

### `create` flags

| Flag | Effect |
|------|--------|
| `--base BRANCH` | Checkout an existing remote branch into the worktree |
| `--from REF` | Create a new branch (named after ID) starting from REF after the normal ownership claim gate |
| `--pr NUMBER` | Look up the branch from a GitHub PR number (implies `--base`) |
| `--reuse` | Explicitly reuse an existing issue worktree and rebase it onto `origin/<default>` |
| `--restack` | When reusing an existing worktree and its rebase onto `origin/<default>` conflicts, stop in the conflict state for resolution instead of aborting |

### Reuse rebase conflicts

Bare `create` never rebases an existing worktree. After the owning session opts in with `--reuse`, the branch rebases onto `origin/<default>`. If that rebase conflicts, the run aborts the rebase and exits 1 — the worktree is left clean on its pre-rebase state, so there is no conflict left to resolve in place. The error lists the conflicting files (captured before the abort) and the two supported recovery paths:

1. **Resolve in place:** re-run `create <ID> --restack`. The rebase re-runs and pauses in the conflict state. Resolve the listed files, stage each with `git -C <path> add <file>`, run `GIT_EDITOR=true git -C <path> rebase --continue` (repeat if it stops again), then re-run `create <ID> --reuse` to finish worktree setup. `git -C <path> rebase --abort` backs out to the clean pre-rebase state. This is the supported exception to the no-raw-`git rebase` rule: only `--continue`/`--abort` on the paused rebase, never starting one by hand.
2. **Discard divergence:** `remove <ID>` then `create <ID>` recreates the worktree fresh from `origin/<default>`, losing the local commits that conflicted.

With no conflict, `--restack` completes the same intentional rebase as `--reuse`.

## System Dependencies

- `git`
- authenticated `gh` for new-work PR ownership discovery
- `flock` for repository-local per-issue claim serialization
- Bash 3.2+ (macOS system bash is supported)

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
