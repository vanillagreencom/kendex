# App-created worktree hooks

Read when wiring Codex Desktop or Claude Code to run the worktree setup and cleanup hooks. The git-hook auto-repair contract (`repair-links`, the shared `post-checkout`/`post-merge`/`post-rewrite` hooks, `core.hooksPath` handling) is under `worktree fix-links --help`.

## Codex Desktop hooks

Codex Desktop owns app-created worktree creation and deletion. Configure project setup/cleanup hooks to run:

```bash
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-setup "$CODEX_WORKTREE_PATH"
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-cleanup "$CODEX_WORKTREE_PATH"
```

`codex-setup` applies the same symlinks, copies, mkdirs, bot remote, bot git identity, and missing-dependency warning `create` applies. It then runs `WORKTREE_SETUP_CMD` when set, under the failure and retry contract in `worktree --help` § Dependencies.

`codex-branch` renames or switches the app-created branch to the lower-case issue branch without rerunning `WORKTREE_SETUP_CMD`. Run it for issue workflows if the harness did not already normalize the branch:

```bash
"$CODEX_SOURCE_TREE_PATH/.agents/skills/worktree/scripts/worktree" codex-branch CC-123 "$CODEX_WORKTREE_PATH"
```

- Keep project-level teardown, such as stopping containers or removing disposable caches, in the Codex environment cleanup script after `codex-cleanup`.
- Do not call `worktree remove` from the hook.

## Claude Code hooks

A `WorktreeCreate` hook replaces Claude Code's own `git worktree add` wherever Claude Code makes a worktree, such as a `--worktree` session or a subagent with `isolation: worktree`. Claude Code passes the hook its input as JSON on stdin and sets no worktree path variable. Wire both hooks in the consumer repo's `.claude/settings.json`, with no argument after the command:

```json
{
  "hooks": {
    "WorktreeCreate": [{ "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.agents/skills/worktree/scripts/worktree claude-setup" }] }],
    "WorktreeRemove": [{ "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.agents/skills/worktree/scripts/worktree claude-cleanup" }] }]
  }
}
```

- Keep this in **project-level** settings. `CLAUDE_CONFIG_DIR` only relocates user-level config.
- Wire `WorktreeRemove` beside `WorktreeCreate`. Without it, Claude Code removes a hook-created worktree as `git worktree remove --force` does and never deletes its branch. `claude-cleanup` removes the tree through `worktree remove`, which deletes its branch only when it can prove the branch merged.
- Claude Code keeps a subagent's hook-created worktree when the subagent ends. Remove it with `worktree remove`.
- Claude Code skips `.worktreeinclude` when the hook is wired. Name the files a worktree needs in `WORKTREE_SYMLINKS` and `WORKTREE_COPIES`.

What each hook creates, prints and removes: `worktree claude-setup --help`. A `WORKTREE_SETUP_CMD` failure fails the hook, so Claude Code does not start the session. The retry contract is `worktree --help` § Dependencies.
