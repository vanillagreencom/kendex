# Configuration and push internals

Setup and `push` internals behind [../SKILL.md](../SKILL.md).

## Path arguments and canonicalization

Project root resolves via `git rev-parse`, the default branch is detected automatically, and project config is read from `.env`, `kendex.settings.toml`, then `.env.local` (`.env.local` wins).

Path comparisons are canonical (physical, symlink-resolved on both sides).

Direct path arguments for mutating commands must be registered worktrees of this repository's common Git directory. `fix-links`, `codex-setup`, `codex-branch`, `claude-setup`, and `remove` refuse the main checkout and foreign worktrees; Codex app-created worktrees are registered git worktrees and are accepted even outside `WORKTREE_BASE_DIR`.

## `push` resolution and authentication

`push ISSUE_ID` normally resolves through the configured worktree registry. When run from a checkout whose current branch already matches the normalized issue branch, it pushes that active checkout instead (app-created worktrees).

`push` and origin fetches use the GitHub skill's `git-https-auth` behavior when available: if `gh` auth is valid the git command gets temporary HTTPS rewrite and `gh auth git-credential` config. Remote URLs and git config are not modified. `KENDEX_GITHUB_GIT_HTTPS_FALLBACK=never` forces the normal SSH path.

## Force-with-lease authorization

When `push` performs its auto-rebase, the following push uses a scoped `--force-with-lease` pinned to the target branch OID known before the rebase. `create --reuse` and the supported `create --restack` conflict-recovery flow persist the same narrowly scoped authorization in the worktree: it records the exact observed remote OID and the exact successfully restacked local head. `push` accepts that rewritten head or later commits built on it, still pins the force-with-lease to the recorded remote OID, and consumes the authorization after success. A different local rewrite, remote movement while conflict resolution is pending, or a moved remote at push time fails closed. Plain pushes are still used with `--no-rebase`.

When the auto-rebase rewrites commits, `push` prints one `rebase-map: <old-sha> <new-sha>` line per rewritten commit on stdout (`dropped` in place of the new SHA when the replayed commit's patch was already upstream). Use it to remap commit SHAs recorded before the rebase. Commits pair by position when the pre/post counts match, otherwise by commit subject. A push that skips the rebase, or one run with `--no-rebase`, prints no map.

## Configuration variables

| Variable | Effect |
|----------|--------|
| `WORKTREE_BASE_DIR` | Parent directory for created worktrees. Relative paths resolve from the main checkout; absolute paths and `~` are used as-is. Default: `../.worktrees/<checkout-name>`. Do not point it inside the repo root |
| `WORKTREE_SYMLINKS` | Space-separated paths symlinked from main checkout into each worktree; include `.env.local` only if worktrees should share local secrets/overrides. Point entries at untracked runtime paths — see the tracked-content caveat below |
| `WORKTREE_RELATIVE_SYMLINKS` | Space-separated `path=target` symlinks created inside each worktree, with relative targets resolving from the link location |
| `WORKTREE_COPIES` | Space-separated files copied from main checkout into each worktree |
| `WORKTREE_MKDIRS` | Space-separated directories created inside each worktree with `mkdir -p`; use for gitignored scratch dirs such as `tmp` |

## Setup-path hardening

Configured setup paths (`WORKTREE_SYMLINKS`, `WORKTREE_COPIES`, `WORKTREE_MKDIRS`, and the path side of `WORKTREE_RELATIVE_SYMLINKS`) must be worktree-relative literal paths without `.`, `..`, absolute, backslash, or shell glob metacharacter components (`*`, `?`, `[`, `]`). A configured symlink path cannot also be, contain, or parent another configured setup path. Existing symlink parents are rejected before writes. Copy and mkdir destinations also reject leaf symlinks. File and relative-symlink destinations may replace an existing leaf symlink or file without following it, but refuse a real directory leaf.

## Symlink entries that shadow tracked content

When a configured symlink path is a tracked **file** in the worktree branch, the script marks that file assume-unchanged before replacing it so `git status` stays clean.

**Directory entries with tracked content are linked per child.** Setup does not link the parent: the entry stays a real directory, tracked paths stay real files git owns, and only the untracked children are symlinked, recursing into children that mix tracked and untracked content. A newly installed skill under the entry is linked on the next `create`/`fix-links`/auto-repair pass.

Each untracked child goes through the same quarantine as a top-level entry: a child that has materialized as a real file or directory holding data git does not track, or that differs from the index, is reported and left in place, never overwritten. A child nesting deeper than 8 levels is reported the same way. Either makes setup fail naming the affected paths — an error from `create`/`fix-links`, a blocked warning from hook-driven auto-repair.

A worktree carrying the legacy layout — a parent link over tracked content, tracked files underneath marked `assume-unchanged` — heals on the next `fix-links` or hook repair: the parent link becomes a real directory, the bits are cleared, and missing tracked files are restored from the index (locally modified ones are never touched). `create --reuse`/`--restack` reconcile the same layout before rebasing, and re-apply setup on every terminal path: success, a rebase that never started, an aborted conflict, `restack continue`, and `restack abort`. A `--restack` paused on conflicts stays un-shadowed; the links return when the restack finishes or aborts.

## `info/exclude` entries

The ignore entry setup writes for each symlinked path goes into the **common** git dir's `info/exclude`, which every checkout reads. When the path holds tracked content, setup follows the entry with `!<path>/` (a trailing-slash pattern matches a real directory but **not** a symlink pointing at one). Runtime-only paths keep the plain entry. The shape is re-evaluated on every `create`/`fix-links` against both indexes, main authoritative.
