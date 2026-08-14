# App-created worktree hooks and git-hook auto-repair

Installation-time wiring so app-created worktrees get the same env/config provisioning `create` applies. The everyday contract, and the one-line index of these commands, live in [../SKILL.md](../SKILL.md).

## Git-hook auto-repair (`repair-links`)

A rebase, merge, or branch checkout can re-materialize a `WORKTREE_SYMLINKS` entry as a real directory holding only the tracked files beneath it. The clobber happens at git-operation time, mid-session, from any harness or a plain human shell, so the interception point is git itself.

`create` and `fix-links` install shared `post-checkout`, `post-merge`, and `post-rewrite` hooks into the **main checkout's** hooks directory — worktrees resolve hooks there (`git rev-parse --git-path hooks`), so one installation covers every worktree and every harness.

- The hook logic lives in an owned helper file, `hooks/vstack-worktree-autorepair`, rewritten on every install. The three stock hooks get one marked delegating line: an existing shell hook is **appended to**, never overwritten; a non-shell or non-executable (disabled) hook is left alone with a warning; the append is idempotent.
- `core.hooksPath` is never used or modified — it replaces the hooks directory wholesale and would disable a consumer's own hooks. When it is set, the install is skipped with a warning; add a `repair-links` call to those hooks manually.
- The helper no-ops in the main checkout and in repos without the skill installed, and never fails the git operation it runs after.
- `repair-links` is cheap on the healthy path (one `readlink` per entry). Repair itself is the `fix-links` logic with one extra guarantee: a materialized path holding files git does not track (untracked **or** ignored — a worktree-local cache is ignored data) is never clobbered; the hook warns loudly, names the files, and points at manual `fix-links` after the data has been moved or deleted.

## Codex Desktop hooks

Codex Desktop owns app-created worktree creation and deletion. Configure project setup/cleanup hooks to run:

```bash
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-setup "$CODEX_WORKTREE_PATH"
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-cleanup "$CODEX_WORKTREE_PATH"
```

`codex-setup` applies the same symlinks, copies, mkdirs, bot remote, bot git identity, and dependency bootstrap `create` applies. `codex-branch` renames or switches the app-created branch to the lower-case issue branch; run it for issue workflows if the harness did not already normalize the branch:

```bash
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-branch CC-123 "$CODEX_WORKTREE_PATH"
```

Keep project-level teardown such as stopping containers or removing disposable caches in the Codex environment cleanup script after `codex-cleanup`, but do not call `worktree remove` from the hook.

## Claude Code hooks

Claude Code creates worktrees itself for `--worktree` sessions, subagents with `isolation: worktree`, and desktop parallel sessions. Those run a bare `git worktree add`, so the worktree has no `.agents`, no `.claude/*` links, and no `.env.local`. Point the `WorktreeCreate` hook in the consumer repo's `.claude/settings.json` at `claude-setup`:

```bash
.agents/skills/worktree/scripts/worktree claude-setup "$CLAUDE_WORKTREE_PATH"
.agents/skills/worktree/scripts/worktree claude-cleanup "$CLAUDE_WORKTREE_PATH"
```

Keep this in **project-level** settings: the hook then applies to every Claude auth/config-dir variant on the machine, since `CLAUDE_CONFIG_DIR` only relocates user-level config.
