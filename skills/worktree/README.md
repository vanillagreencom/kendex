# Git Worktree Management

Git worktree lifecycle management with env/config symlinks.

## Structure

```text
skills/worktree/
├── SKILL.md          # Agent-facing skill definition
└── scripts/
    └── worktree      # Entry point
```

## Setup

Run from the main checkout of a git repo with an `origin` remote. New-work claims require authenticated `gh` access and `flock` for fail-closed PR discovery and per-issue serialization. Optionally add committed settings in `vstack.settings.toml` and local secrets/overrides in `.env.local`.

```bash
./scripts/worktree create PROJ-123
./scripts/worktree create PROJ-123 --recover-local
./scripts/worktree restack continue PROJ-123
./scripts/worktree list
./scripts/worktree remove PROJ-123
```

Defaults: detects branch from `origin/HEAD` (fallback: `main`), creates worktrees under `<parent-of-checkout>/.worktrees/<checkout-name>/` — an external per-repo dir beside the checkout, so recursive editor/file watchers on the repo never ingest worktree build outputs and sibling repos cannot collide — then applies configured symlinks and copies. Set `WORKTREE_BASE_DIR` to use another parent directory; relative paths resolve from the main checkout, absolute paths and `~` are used as-is. Avoid pointing it inside the repo root.

Issue-ID commands (`remove`, `push`, `restack`, `path`, `exists`, `create --reuse`) resolve against the configured base dir first, then fall back to the worktree registered for the issue branch — worktrees created under an older base-dir convention keep working unmoved, with no auto-migration. Path comparisons are canonical (symlink-resolved on both sides), so a tree registered under a legacy symlinked spelling is recognized as the same tree when addressed by its physical path, and a foreign repo's worktree is still refused.

Issue IDs used to derive paths must match `[A-Za-z0-9][A-Za-z0-9._-]*` and must not contain `..`; examples such as `issue-779`, `CC-123`, and `ds-enforcement` are valid. Direct path arguments for mutating commands must be registered worktrees of the current repository's common Git directory. `fix-links`, `codex-setup`, `codex-branch`, and `remove` refuse the main checkout and foreign worktrees; Codex app-created worktrees remain supported because they are registered git worktrees even when they live outside `WORKTREE_BASE_DIR`.

Bare `create <ID>` claims new work only. Every new-branch mode, including `--from`, checks the normalized issue branch, an explicit requested branch, and `BOT_NAME/<issue>` for matching worktrees, local/remote refs, and open PRs. Existing ownership exits 75 without rebasing or modifying a branch. Origin remote-head and GitHub PR discovery are authoritative: an outage exits 1 before worktree config, branch, or target-path mutation instead of being treated as absence. Unreachable secondary remotes are skipped with a warning (they cannot hold other sessions' pushes); reachable ones still count as ownership. A repository-local per-issue lock holds the final repeated discovery through `git worktree add`, so concurrent claimers produce one worktree and one exit 75. Inspect or monitor owned work instead of launching another implementer. Run each issue create separately and check its result; do not batch creates in a shell loop whose last success can mask an earlier active-work exit.

The owning session can opt in with `create <ID> --reuse`, which rebases the existing branch onto `origin/<default>` and refreshes its setup. Reuse/restack requires the target's exact canonical path to be registered in this repository's common Git directory; an incomplete directory is preserved and exits 75, even when it sits inside the main checkout. If a reuse rebase conflicts, it aborts back to the clean pre-rebase state and prints two recovery paths. `create <ID> --restack` re-runs the rebase and pauses in the conflict state so you can resolve and stage the files, then use `restack continue <ID>`; use `restack skip <ID>` for a replayed commit already represented by the new base, or `restack abort <ID>` to restore the original branch. Alternatively, `remove <ID>` + `create <ID>` recreates the worktree fresh from `origin/<default>`, discarding the conflicting local commits. A completed supported rewrite records its exact remote OID and rewritten local head in worktree-local config so the next `worktree push <ID>` can publish it safely. Use `create <ID> --pr <N>` or `--base <branch>` to explicitly inspect existing remote work.

If an issue worktree was externally removed after local commits but before push, bare `create <ID>` still exits 75 for the surviving branch and points the owning session to `create <ID> --recover-local`. This guarded mode accepts only the exact normalized, local-only issue branch with no upstream, active/stale registration, remote branch, open PR, or competing bot-prefixed candidate. Every configured remote must be reachable for recovery, even though ordinary new-work claims may skip an unreachable secondary. It snapshots the local tip before fetching, refreshes only `origin/<default>` through an explicit forced, no-tags/no-prune remote-tracking refspec (accepting an authoritative default rewrite only within `refs/remotes/origin/*`, never a configured mirror-style local-head refspec), requires shared history with that base, and verifies the branch tip is unchanged before recreating the configured path and restoring setup. Existing/foreign target paths and ambiguous or incomplete ownership fail closed.

The restack control commands fail closed unless the target is a registered worktree and its tool-created state token, recorded remote, branch, observed remote OID, original head, target base, and live Git rebase metadata all match. `continue` and `skip` verify the remote has not moved before and after replay, then authorize only the completed rewritten head. `abort` verifies the same local restack boundary, restores the recorded original head, and clears pending authorization; it remains safe and available if the remote moved while conflict resolution was paused. Published restacks paused by older vstack versions remain recoverable when their complete legacy authorization and sequencer metadata match.

If the harness execution policy rejects top-level `git rebase` itself (for example Codex `approval_policy = never`), use the guarded `create <ID> --reuse` / `--restack` path — each control is a single simple helper command — or, when that is also unavailable, the exact verified replay documented in `SKILL.md` § Policy-blocked rebase (cherry-pick replay fallback).

`remove` deletes the worktree first, then tries `git branch -d` for the associated local branch. If Git refuses the safe branch delete (for example, the branch is not merged into the current main checkout), the command exits non-zero and prints a diagnostic naming the remaining branch plus the manual `git branch -D` recovery command.

`cleanup` fetches `origin`, considers non-main registered worktrees, proves each branch is merged into `origin/<default>` (or the local default branch when the remote ref is unavailable), asks Git to remove the intact worktree, then deletes the proven-merged local branch. If Git cannot remove a worktree, cleanup exits nonzero and preserves its path, configured symlinks, and branch for manual recovery. If branch deletion fails after worktree removal, cleanup also exits nonzero and names the remaining branch.

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
without failing non-fast-forward. The same exact-OID lease publishes a branch
rewritten by supported `create --reuse` / `create --restack`: authorization is
bound to that worktree, remote, branch, observed remote OID, and restacked head;
later commits must descend from that head. The authorization is consumed after
a successful push. Unexpected local rewrites and remote movement fail closed.
Calls that skip auto-rebase still use plain pushes.

When the auto-rebase rewrites branch commits, `worktree push` prints one
`rebase-map: <old-sha> <new-sha>` line per rewritten commit on stdout
(`dropped` in place of the new SHA when the replayed commit vanished because
its patch was already upstream), so callers can remap commit SHAs recorded
before the rebase — orch `submit-pr.md` § 2 step 1 consumes this to rewrite
workflow-state fix references before publication (vstack#728). Commits pair by
position when the pre/post counts match, otherwise by commit subject. A push
that skips the rebase, or one run with `--no-rebase`, prints no map.

`codex-setup` applies the same env/config symlinks, copies, mkdirs, bot remote, bot git identity, and lightweight dependency bootstrap that `create` applies after creating a worktree. `codex-branch` renames or switches the app-created worktree branch to the lower-case issue branch expected by `orch`. `codex-cleanup` is intentionally a no-op lifecycle hook for this script; Codex owns app-created worktree and branch deletion. Keep project-level teardown such as stopping containers or removing disposable caches in the Codex environment cleanup script after this command, but do not call `worktree remove` from the hook.

## Configuration

Set non-sensitive project defaults in `vstack.settings.toml` under `[env]`. Existing `.env` and `.env.local` files still work; load order is `.env`, then `vstack.settings.toml`, then `.env.local`.

| Variable | Purpose |
|----------|---------|
| `WORKTREE_BASE_DIR` | Parent directory for created worktrees (default: `../.worktrees/<checkout-name>`, an external per-repo dir beside the checkout) |
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
Configured setup paths (`WORKTREE_SYMLINKS`, `WORKTREE_COPIES`, `WORKTREE_MKDIRS`, and the path side of `WORKTREE_RELATIVE_SYMLINKS`) must be worktree-relative literal paths without `.`, `..`, absolute, backslash, or shell glob metacharacter components (`*`, `?`, `[`, `]`). A configured symlink path cannot also be, contain, or parent another configured setup path, because later mkdir/copy/link operations would follow the symlink target. Existing symlink parents are rejected before writes. Copy and mkdir destinations also reject leaf symlinks. File and relative-symlink destinations may replace an existing leaf symlink or file without following it, but refuse a real directory leaf.

Example for sharing local env plus generated Claude assets while keeping `.claude/CLAUDE.md`
pointed at each worktree's own `AGENTS.md`:

```toml
[env]
WORKTREE_BASE_DIR = "~/dev/.worktrees/myproject"
WORKTREE_SYMLINKS = ".env.local .claude/agents .claude/hooks .claude/skills"
WORKTREE_RELATIVE_SYMLINKS = ".claude/CLAUDE.md=../AGENTS.md"
WORKTREE_MKDIRS = "tmp"
```
