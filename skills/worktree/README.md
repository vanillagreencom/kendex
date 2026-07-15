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

Run from the main checkout of a git repo with an `origin` remote. New-work claims require authenticated `gh` access and `flock` for fail-closed PR discovery and per-issue serialization. Optionally add committed settings in `vstack.settings.toml` and local secrets/overrides in `.env.local`.

```bash
./scripts/worktree create PROJ-123
./scripts/worktree list
./scripts/worktree remove PROJ-123
```

Defaults: detects branch from `origin/HEAD` (fallback: `main`), creates worktrees under sibling `trees/`, then applies configured symlinks and copies. Set `WORKTREE_BASE_DIR` to use another parent directory; relative paths resolve from the main checkout, absolute paths are used as-is.

Bare `create <ID>` claims new work only. Every new-branch mode, including `--from`, checks the normalized issue branch, an explicit requested branch, and `BOT_NAME/<issue>` for matching worktrees, local/remote refs, and open PRs. Existing ownership exits 75 without rebasing or modifying a branch. Remote-head and GitHub PR discovery are authoritative: an outage exits 1 before worktree config, branch, or target-path mutation instead of being treated as absence. A repository-local per-issue lock holds the final repeated discovery through `git worktree add`, so concurrent claimers produce one worktree and one exit 75. Inspect or monitor owned work instead of launching another implementer. Run each issue create separately and check its result; do not batch creates in a shell loop whose last success can mask an earlier active-work exit.

The owning session can opt in with `create <ID> --reuse`, which rebases the existing branch onto `origin/<default>` and refreshes its setup. Reuse/restack requires the target's exact canonical path to be registered in this repository's common Git directory; an incomplete directory is preserved and exits 75, even when it sits inside the main checkout. If a reuse rebase conflicts, it aborts back to the clean pre-rebase state and prints the conflicting files plus two recovery paths: `create <ID> --restack` re-runs the rebase and pauses in the conflict state so you can resolve the files, `git -C <path> add` each one, and `GIT_EDITOR=true git -C <path> rebase --continue` (or `rebase --abort` to back out), then re-run `create <ID> --reuse` to finish setup; alternatively `remove <ID>` + `create <ID>` recreates the worktree fresh from `origin/<default>`, discarding the conflicting local commits. Use `create <ID> --pr <N>` or `--base <branch>` to explicitly inspect existing remote work.

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

`worktree push` and origin fetches automatically use the GitHub skill's
`git-https-auth` fallback when that helper is installed. If `origin` or the
configured bot remote is `git@github.com:...` / `ssh://git@github.com/...` and
`gh` auth is valid, the command runs with temporary HTTPS rewrite and
`gh auth git-credential` config. The repository's remote URLs and git config
are not modified. Set `VSTACK_GITHUB_GIT_HTTPS_FALLBACK=never` to disable this
for a call.

When `worktree push` auto-rebases a branch before pushing, it uses a scoped
`--force-with-lease` pinned to the target branch OID known before the rebase so
already-pushed PR branches can be rebased onto an advanced `origin/main`
without failing non-fast-forward. If the remote branch has advanced beyond the
local branch, the command aborts and asks you to fetch/rebase/merge first
instead of overwriting unseen remote commits. Calls that skip auto-rebase still
use plain pushes.

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
