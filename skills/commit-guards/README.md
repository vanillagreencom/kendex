# commit-guards

Repository checks installed as Git hooks. Maintainers use them to check source files, markdown and commit messages before a commit completes, and binary growth against the destination before a push leaves the machine.

## Features

- Check conflict markers and binary file growth.
- Check changelog fragments and required change entries.
- Check that markdown files parse to their end, and their references.
- Check Python files for undefined names.
- Check added lines for credentials with gitleaks.
- Reflow markdown paragraphs with md-reflow.

## Install

```bash
kendex add vanillagreencom/kendex --skill commit-guards
```

## How it works

You select checks in the project settings and install the Git hooks. The checks run when you commit and report a problem before the commit completes. If you enable binary growth checks, they also run before a push. A failed check stops the commit or push.

Replaying commits does not run these commit checks. Keep CI checks enabled for replayed changes. Check coverage and push limits: [hooks and settings](references/hooks-and-settings.md#pre-push-scope).

## Setup

Requires Git, awk, jq 1.7 or newer and standard POSIX tools. Bash 3.2 is supported. Python checks need ruff or pyflakes; credential checks need gitleaks 8.19 or newer. Tool requirements and CI setup: [CHECKS.md](CHECKS.md).

Obtain the repository owner’s consent before setup runs repository scripts. In each fresh clone, run `kendex guard install`, or `bash .agents/skills/commit-guards/scripts/install-git-hooks` without kendex. Check the installation with `kendex guard check` or the installer's `--check` option. Git does not clone hooks; commits run no Git checks until setup is armed. Hook layering and setup limits: [hooks and settings](references/hooks-and-settings.md#hook-layering).

The keys a project usually sets, with their meanings: [kendex.settings.toml.example](kendex.settings.toml.example). Each check's own keys: its section in [CHECKS.md](CHECKS.md). Set keys under `[env]` in committed `kendex.settings.toml`. Resolution order and the settings-file grammar: [references/hooks-and-settings.md](references/hooks-and-settings.md). Each check's defaults: its `--help`, such as `bash .agents/skills/commit-guards/scripts/byte-ceiling --help`.

`COMMIT_GUARDS_CHECKS` replaces the default check set; the template's value is that set. This example keeps the default checks, adds the optional binary-size check, and raises its ceiling from the default 200 KB to 500 KB:

```toml
[env]
COMMIT_GUARDS_CHECKS = "conflict-markers changelog-entries md-type md-refs py-names secrets byte-ceiling"
COMMIT_GUARDS_BYTE_CEILING_KB = "500"
```

`COMMIT_GUARDS_PRE_COMMIT_LOCAL` names a project check the pre-commit hook runs last. Writing that check: [references/hooks-and-settings.md § Repo-local check](references/hooks-and-settings.md#repo-local-check).

Maintainer testing and debugging: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md).

## Licence

MIT, in the repository's LICENSE file.
