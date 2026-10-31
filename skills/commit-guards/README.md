# commit-guards

Repository checks installed as Git hooks. Maintainers use them to check source files, markdown and commit messages before a commit completes, and the whole branch before a push leaves the machine.

## Features

- Check conflict markers, work markers, file growth and lint suppressions.
- Check changelog fragments and required change entries.
- Check markdown layout and references.
- Check Python files for undefined names.
- Check added lines for credentials with gitleaks.
- Optionally check dates and issue references in source comments.
- Reflow markdown paragraphs with md-reflow.

## Install

```bash
kendex add vanillagreencom/kendex --skill commit-guards
```

## How it works

You select checks in the project settings and install the Git hooks. When you commit, the pre-commit hook runs the enabled checks on the staged files. The commit-msg hook checks the commit message. When you push, the pre-push hook runs the document byte-ceiling check over the pushed tree and then the enabled checks over what the push would change on the remote. A check that reads only staged files is skipped there where the push gives it no range to read instead, because a push stages nothing, and the hook names each one it skipped. The credential scan runs at commit and in CI, never at push: [CHECKS.md § secrets](CHECKS.md#secrets) says why and what that leaves to CI. A failed check stops the commit or the push and prints the problem.

The push check is there because Git runs no hook when it replays a commit. A rebase or a cherry-pick can leave a branch in a state no commit hook ever saw.

## Git hooks

The Git hooks run the committed skill scripts: `pre-commit` and `commit-msg` per commit, `pre-push` per branch. How they layer with the harness pre-commit hook: [references/hooks-and-settings.md § Hook layering](references/hooks-and-settings.md#hook-layering).

Check definitions: [CHECKS.md](CHECKS.md). Hook setup and execution: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md).

## Setup

Requires Git, awk, jq 1.7 or newer (jq 1.6 refuses every generated-path inventory) and standard POSIX tools, plus ruff or pyflakes in a repository with Python files, and gitleaks 8.19 or newer for the credential scan. Where those tools are installed in CI is in [CHECKS.md § py-names](CHECKS.md#py-names) and [CHECKS.md § secrets](CHECKS.md#secrets). Bash 3.2 is supported. Run `bash .agents/skills/commit-guards/scripts/install-git-hooks`, which needs no kendex, or `kendex guard install` in each fresh clone, then `bash .agents/skills/commit-guards/scripts/install-git-hooks --check` or `kendex guard check` to check the hooks. Git never clones hooks: until they are armed, commits run no Git checks. The `pre-commit-check` harness hook allows the command and reports the setup route. Obtain the repository owner’s consent before setup runs repository scripts.

Every key, its default and its meaning: [SKILL.md](SKILL.md) § Configuration. Set keys under `[env]` in committed `kendex.settings.toml`. Resolution order and the settings-file grammar: [references/hooks-and-settings.md](references/hooks-and-settings.md).

```toml
[env]
COMMIT_GUARDS_BYTE_CEILING_KB = "500"
COMMIT_GUARDS_CHECKS = "todo-ban suppression-ban"
```

`COMMIT_GUARDS_PRE_COMMIT_LOCAL` names a project check the pre-commit hook runs last. Writing that check: [references/hooks-and-settings.md § Repo-local check](references/hooks-and-settings.md#repo-local-check).

## Licence

MIT, in the repository's LICENSE file.
