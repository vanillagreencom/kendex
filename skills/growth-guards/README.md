# growth-guards

Repository checks installed as Git hooks. Maintainers use them to check source files, markdown and commit messages before a commit completes.

## Install

```bash
kendex add vanillagreencom/kendex --skill growth-guards
```

Requires Git, awk and standard POSIX tools. Bash 3.2 is supported. Run `kendex guard install` in each fresh clone, then `kendex guard check` to check the hooks.

## Features

- Check conflict markers, work markers, file growth and lint suppressions.
- Check changelog fragments and required change entries.
- Check markdown layout and references.
- Optionally check dates and issue references in source comments.
- Reflow markdown paragraphs with md-reflow.

## How it works

You select checks in the project settings and install the Git hooks. When you commit, the pre-commit hook runs the enabled checks on the staged files. The commit-msg hook checks the commit message. A failed check stops the commit and prints the problem.

## Settings

Every key, its default and its meaning: [SKILL.md](SKILL.md) § Configuration. Each resolves environment > `.env.local` > `.kendex/settings.toml` > committed `kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > default; a `.env` file is never read. Per-check flags (`--excludes`, `--baseline`) override every source; relative paths are repo-root-relative.

```toml
[env]
GROWTH_GUARDS_BYTE_CEILING_KB = "500"
GROWTH_GUARDS_CHECKS = "todo-ban suppression-ban"
```

## Git hooks

The Git hooks run the committed skill scripts. The harness pre-commit hook requires these Git hooks before it allows a commit.

Check definitions: [CHECKS.md](CHECKS.md). Hook setup and execution: [DEVELOPMENT.md](DEVELOPMENT.md).
