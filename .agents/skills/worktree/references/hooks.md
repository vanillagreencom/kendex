# App-created worktree hooks

Installation-time wiring for app-created worktrees. Command index: [../SKILL.md](../SKILL.md). The git-hook auto-repair contract (`repair-links`, the shared `post-checkout`/`post-merge`/`post-rewrite` hooks, `core.hooksPath` handling) is under `worktree fix-links --help`.

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

Claude Code creates worktrees itself (`--worktree` sessions, subagents with `isolation: worktree`, desktop parallel sessions) with a bare `git worktree add`. Point the `WorktreeCreate` hook in the consumer repo's `.claude/settings.json` at `claude-setup`:

```bash
.agents/skills/worktree/scripts/worktree claude-setup "$CLAUDE_WORKTREE_PATH"
.agents/skills/worktree/scripts/worktree claude-cleanup "$CLAUDE_WORKTREE_PATH"
```

Keep this in **project-level** settings (`CLAUDE_CONFIG_DIR` only relocates user-level config).
