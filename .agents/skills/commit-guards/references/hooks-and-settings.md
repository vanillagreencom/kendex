# Hooks and settings

Read when resolving where a setting's value comes from, writing a settings file, judging how the Git hooks and the harness hook layer, or writing the repo-local pre-commit check. Every key, its default and its meaning: [SKILL.md § Configuration](../SKILL.md#configuration). The person's install and consent steps: [README.md § Setup](../README.md#setup).

## Hook layering

The Git hooks run the committed skill scripts: `pre-commit` and `commit-msg` per commit, `pre-push` per branch. The harness pre-commit hook allows commits when these Git hooks are absent. It reports the missing setup with a consent route, or a main-checkout owner route for a linked worktree. Git checks run only after setup is armed.

## Settings resolution

Each key resolves environment > `.env.local` > `.kendex/settings.toml` > committed `kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > default; a `.env` file is never read. Per-check flags (`--excludes`, `--baseline`) override every source; relative paths are repo-root-relative.

## Settings file grammar

A settings file is read whole. Each `[env]` value is a single-line basic string with no `"` or `\` inside, or a literal string with no apostrophe inside. Literal strings preserve backslashes and double quotes as text. One value in another shape, or one key assigned twice, fails every read from that file, on any key, because every kendex settings reader refuses the same file. The error for a value in another shape names the file, the line and the key: `settings-string=kendex.settings.toml:3:OTHER`.

## Repo-local check

`COMMIT_GUARDS_PRE_COMMIT_LOCAL` names a project check the pre-commit hook runs last. `COMMIT_GUARDS_PRE_COMMIT_LOCAL_PATHS` names the paths that check reads. The hook runs the check only for a commit that changes one of those paths, and prints `pre-commit: local-entry=skipped` when it skips it. The hook prints no install command of its own: write the check so that a missing tool prints its install command and exits `2`. With the paths set, that refusal blocks only a commit that changes them.
