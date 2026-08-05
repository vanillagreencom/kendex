# Configuration and push internals

Deep mechanics behind the worktree tool's setup and `push` behavior. The everyday contract lives in [../SKILL.md](../SKILL.md).

## Project config resolution

Resolves project root via `git rev-parse`, detects default branch automatically, and reads project-specific config from `.env`, `vstack.settings.toml`, then `.env.local` (`.env.local` wins).

## Path arguments and canonicalization

Path comparisons are canonical (physical, symlink-resolved on both sides), so a worktree registered under a legacy symlinked spelling and addressed via its physical path — or vice versa — is recognized as the same tree, never as a foreign one.

Direct path arguments for mutating commands must be registered worktrees of this repository's common Git directory. `fix-links`, `codex-setup`, `codex-branch`, `claude-setup`, and `remove` refuse the main checkout and foreign worktrees; Codex app-created worktrees remain supported because they are registered git worktrees even when they live outside `WORKTREE_BASE_DIR`.

## `push` resolution and authentication

`push ISSUE_ID` normally resolves through the configured worktree registry. When run from a checkout whose current branch already matches the normalized issue branch, it pushes that active checkout instead. This supports Codex Desktop app-created worktrees that are valid git worktrees but are not registered under `WORKTREE_BASE_DIR`.

`push` and origin fetches use the GitHub skill's `git-https-auth` behavior when available: GitHub SSH remotes stay unchanged by default, but if `gh` auth is valid the git command gets temporary HTTPS rewrite and `gh auth git-credential` config. This lets Codex/GitHub-authenticated sessions push without a working SSH key. Set `VSTACK_GITHUB_GIT_HTTPS_FALLBACK=never` to force the normal SSH path.

## Force-with-lease authorization

When `push` performs its auto-rebase, the following push uses a scoped `--force-with-lease` pinned to the target branch OID known before the rebase. `create --reuse` and the supported `create --restack` conflict-recovery flow persist the same narrowly scoped authorization in the worktree: it records the exact observed remote OID and the exact successfully restacked local head. `push` accepts that rewritten head or later commits built on it, still pins the force-with-lease to the recorded remote OID, and consumes the authorization after success. A different local rewrite, remote movement while conflict resolution is pending, or a moved remote at push time fails closed. Plain pushes are still used with `--no-rebase`.

## Configuration variables

| Variable | Effect |
|----------|--------|
| `WORKTREE_BASE_DIR` | Parent directory for created worktrees. Relative paths resolve from the main checkout; absolute paths and `~` are used as-is. Default: `../.worktrees/<checkout-name>` (external per-repo dir beside the checkout). Do not point it inside the repo root: worktree build outputs under the repo can exhaust recursive file-watcher (inotify) budgets |
| `WORKTREE_SYMLINKS` | Space-separated paths symlinked from main checkout into each worktree; include `.env.local` only if worktrees should share local secrets/overrides. Point entries at untracked runtime paths — see the tracked-content caveat below |
| `WORKTREE_RELATIVE_SYMLINKS` | Space-separated `path=target` symlinks created inside each worktree, with relative targets resolving from the link location |
| `WORKTREE_COPIES` | Space-separated files copied from main checkout into each worktree |
| `WORKTREE_MKDIRS` | Space-separated directories created inside each worktree with `mkdir -p`; use for gitignored scratch dirs such as `tmp` |

## Setup-path hardening

Configured setup paths (`WORKTREE_SYMLINKS`, `WORKTREE_COPIES`, `WORKTREE_MKDIRS`, and the path side of `WORKTREE_RELATIVE_SYMLINKS`) must be worktree-relative literal paths without `.`, `..`, absolute, backslash, or shell glob metacharacter components (`*`, `?`, `[`, `]`). A configured symlink path cannot also be, contain, or parent another configured setup path, because later mkdir/copy/link operations would follow the symlink target. Existing symlink parents are rejected before writes. Copy and mkdir destinations also reject leaf symlinks. File and relative-symlink destinations may replace an existing leaf symlink or file without following it, but refuse a real directory leaf.

## Symlink entries that shadow tracked content

When a configured symlink path is a tracked **file** in the worktree branch, the script marks that file assume-unchanged before replacing it so `git status` stays clean (the migration case: a project moving away from committing harness config files).

**Directory entries with tracked content are linked per child.** When a `WORKTREE_SYMLINKS` directory entry contains tracked files, setup does not link the parent. It keeps the entry a real directory, leaves the tracked paths as real files git owns, and symlinks only the entry's untracked children — recursing into children that mix tracked and untracked content. The result is the same as hand-enumerating the untracked subpaths in `WORKTREE_SYMLINKS`, with nothing to maintain per consumer: a newly installed skill under the entry is linked on the next `create`/`fix-links`/auto-repair pass, and a PR that updates the tracked subtree (a vendored review-gate engine, say) merges normally in every worktree because git can write those paths directly. Children setup cannot resolve — a tracked path whose main-checkout counterpart is neither a regular file nor a directory, or nesting deeper than 8 levels — are left alone with a warning naming them.

(Earlier versions linked the parent and marked the tracked files underneath `assume-unchanged`, which made `cherry-pick`/`checkout`/`merge` fail on those paths while `git status` read clean. A worktree still carrying that legacy layout heals on the next `fix-links` or hook-driven repair: the parent link is replaced with a real directory, the assume-unchanged bits are cleared, and missing tracked files are restored from the index — locally modified ones are never touched.)

`create --reuse` and `create --restack` also reconcile the legacy layout before rebasing: they clear the `assume-unchanged` bits, drop the configured symlinks, and restore the shadowed files from the index, so git can detach HEAD; setup is re-applied on every terminal path — success, a rebase that never started, an aborted conflict, and `restack continue`/`restack abort`. A `--restack` that pauses on conflicts deliberately stays un-shadowed, so conflicts are resolved against real files; the links come back when the restack finishes or is aborted.

## `info/exclude` entries

The ignore entry setup writes for each symlinked path goes into the **common** git dir's `info/exclude`, which every checkout of the repo reads — including main, where that path is a real directory rather than a symlink. A plain entry there marked the whole directory ignored in main, so `git add <tracked file under it>` refused with *"The following paths are ignored by one of your .gitignore files"* while `git status` still listed the file as modified, and it outlived the worktree. When the path holds tracked content, setup now follows the entry with `!<path>/`: a trailing-slash pattern matches a real directory but **not** a symlink pointing at one, so main keeps the directory while the worktree's symlink stays ignored. Runtime-only paths keep the plain entry — many projects (vstack's own `.agents` mirror included) rely on it alone to hide the mirror in main, with no `.gitignore` rule behind it, and a negation there would fill main with untracked noise. The shape is re-evaluated on every `create`/`fix-links` against both indexes, main being authoritative, so a path that gains or loses tracked content self-heals.

## Example

Share local env plus generated Claude assets, but keep `.claude/CLAUDE.md` pointed at each worktree's own `AGENTS.md`:

```toml
[env]
WORKTREE_BASE_DIR = "~/dev/.worktrees/myproject"
WORKTREE_SYMLINKS = ".env.local .claude/agents .claude/hooks .claude/skills"
WORKTREE_RELATIVE_SYMLINKS = ".claude/CLAUDE.md=../AGENTS.md"
WORKTREE_MKDIRS = "tmp"
```
