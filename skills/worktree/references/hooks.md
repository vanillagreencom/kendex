# App-created worktree hooks (Codex Desktop, Claude Code)

Installation-time wiring so app-created worktrees get the same env/config provisioning `create` applies. The everyday contract lives in [../SKILL.md](../SKILL.md).

| Command | Description |
|---------|-------------|
| `codex-setup` | Apply env/config setup to a Codex Desktop app-created worktree |
| `codex-branch` | Normalize a Codex Desktop app-created branch to an issue branch |
| `codex-cleanup` | Non-destructive Codex Desktop cleanup hook; app owns deletion |
| `claude-setup` | Apply env/config setup to a Claude Code-created worktree (`WorktreeCreate` hook) |
| `claude-cleanup` | Non-destructive Claude Code cleanup hook; app owns deletion |

## Codex Desktop hooks

Let Codex Desktop own app-created worktree creation and deletion. Configure project setup/cleanup hooks to run:

```bash
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-setup "$CODEX_WORKTREE_PATH"
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-cleanup "$CODEX_WORKTREE_PATH"
```

For issue workflows, run `codex-branch ISSUE_ID "$CODEX_WORKTREE_PATH"` before orchestration if the harness did not already normalize the branch.

## Claude Code hooks

Claude Code creates worktrees itself for `--worktree` sessions, subagents with `isolation: worktree`, and desktop parallel sessions. Those run a bare `git worktree add`, so the worktree has no `.agents`, no `.claude/*` links and no `.env.local`. Point the `WorktreeCreate` hook in the consumer repo's `.claude/settings.json` at `claude-setup` to apply the same provisioning `create` does:

```bash
.agents/skills/worktree/scripts/worktree claude-setup "$CLAUDE_WORKTREE_PATH"
.agents/skills/worktree/scripts/worktree claude-cleanup "$CLAUDE_WORKTREE_PATH"
```

Keep this in **project-level** settings: the hook then applies to every Claude auth/config-dir variant on the machine, since `CLAUDE_CONFIG_DIR` only relocates user-level config.
