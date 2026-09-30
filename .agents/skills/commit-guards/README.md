# commit-guards

Repository checks installed as Git hooks. Maintainers use them to check source files, markdown and commit messages before a commit completes, and the whole branch before a push leaves the machine.

## Install

```bash
kendex add vanillagreencom/kendex --skill commit-guards
```

Requires Git, awk, jq and standard POSIX tools, plus ruff or pyflakes in a repository with Python files. Where that tool is installed in CI is in [CHECKS.md § py-names](CHECKS.md#py-names). Bash 3.2 is supported. Run `kendex guard install` in each fresh clone, then `kendex guard check` to check the hooks.

## Features

- Check conflict markers, work markers, file growth and lint suppressions.
- Check changelog fragments and required change entries.
- Check markdown layout and references.
- Check Python files for undefined names.
- Optionally check dates and issue references in source comments.
- Reflow markdown paragraphs with md-reflow.

## How it works

You select checks in the project settings and install the Git hooks. When you commit, the pre-commit hook runs the enabled checks on the staged files. The commit-msg hook checks the commit message. When you push, the pre-push hook runs the document byte-ceiling check over the pushed tree and then the enabled checks over what the push would change on the remote. A check that reads only staged files is skipped there where the push gives it no range to read instead, because a push stages nothing, and the hook names each one it skipped. A failed check stops the commit or the push and prints the problem.

The push check is there because Git runs no hook when it replays a commit. A rebase or a cherry-pick can leave a branch in a state no commit hook ever saw.

## Settings

Every key, its default and its meaning: [SKILL.md](SKILL.md) § Configuration. Each resolves environment > `.env.local` > `.kendex/settings.toml` > committed `kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > default; a `.env` file is never read. Per-check flags (`--excludes`, `--baseline`) override every source; relative paths are repo-root-relative.

A settings file is read whole. Each `[env]` value is a single-line double-quoted string with no `"` and no `\` inside. One value in another shape, or one key assigned twice, fails every read from that file, on any key, because every kendex settings reader refuses the same file. The error for a value in another shape names the file, the line and the key: `settings-string=kendex.settings.toml:3:OTHER`.

```toml
[env]
COMMIT_GUARDS_BYTE_CEILING_KB = "500"
COMMIT_GUARDS_CHECKS = "todo-ban suppression-ban"
```

`COMMIT_GUARDS_PRE_COMMIT_LOCAL` names a project check the pre-commit hook runs last. `COMMIT_GUARDS_PRE_COMMIT_LOCAL_PATHS` names the paths that check reads. The hook runs the check only for a commit that changes one of those paths, and prints `pre-commit: local-entry=skipped` when it skips it. The hook prints no install command of its own: write the check so that a missing tool prints its install command and exits `2`. With the paths set, that refusal blocks only a commit that changes them.

## Git hooks

The Git hooks run the committed skill scripts: `pre-commit` and `commit-msg` per commit, `pre-push` per branch. The harness pre-commit hook requires these Git hooks before it allows a commit.

Check definitions: [CHECKS.md](CHECKS.md). Hook setup and execution: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md).
