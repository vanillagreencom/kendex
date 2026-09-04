# growth-guards

Checks that stop quiet repository decay, one family beside `size-ratchet`, armed as git hooks so every committer is gated: a person at a terminal, an AI harness, a script, an editor's commit button. For a repository that wants its markers, sizes, suppressions, changelog, markdown and commit messages held to one shape.

## Install

```bash
kendex add vanillagreencom/kendex --skill growth-guards
kendex guard install
```

Needs `git`, `awk` and the usual POSIX userland; Bash 3.2 is enough. `kendex guard install` runs `scripts/install-git-hooks`, which writes a helper into `.git/hooks` plus one marked line in `pre-commit` and `commit-msg`, never `core.hooksPath`; an existing hook keeps its content. Git never clones hooks, so every fresh clone runs it once. `kendex guard check` or `install-git-hooks --check` says whether the hooks are armed, and never passes silently.

## What it does

- Refuses work markers, oversized additions, blanket lint suppression and conflict markers.
- Holds changelog fragments to shape and length, and refuses hand edits to the collated record.
- Holds the markdown agents load to one paragraph per line, with no dead references and no history prose.
- Optionally holds source comments to the same no-history rule.
- Holds commit messages to `type(scope): subject`, a length cap, and the changelog entry a change under a named path owes.
- `md-reflow` rewrites markdown into the format the `md-format` lane judges.

What each check bans and how it is scoped: [CHECKS.md](CHECKS.md).

## How it works

```bash
scripts/growth-guards [all]           # every enabled check
scripts/growth-guards [all] --staged  # the same batch at commit scope
scripts/growth-guards CHECK [ARGS]    # one check, flags passed through
```

Every check is a standalone executable with one exit contract: `0` clean, `1` violations, `2` usage, config or collection error. Nothing fails open: a check that could not complete is `2`, never a pass. Scans read index content and skip binaries.

The `pre-commit` hook judges one commit snapshot: `size-ratchet --staged` and `preflight --staged` where installed, `growth-guards all --staged`, then the repo-local executable named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL`. `commit-msg` runs the message gate. Both block on any failure; `git commit --no-verify` is the only bypass.

The markdown lanes start narrow: `md-format` and `md-refs` judge the files a commit touches. Reflow the tree once with `scripts/md-reflow --all`, commit, then set `GROWTH_GUARDS_MD_SCOPE = "all"` so CI judges every tracked markdown file. Vendored or generated markdown goes in `tools/md-excludes` with a reason.

In CI, run the batch without `--staged`: the index-wide `todo-ban` scan is the only lane that sees a marker no commit ever diffed. `byte-ceiling --base origin/main` gates a PR's additions.

## Who gates a commit

The git hooks are the gate. They need no kendex binary: the shim execs this skill's committed scripts, so a machine that never installed kendex is gated by committed shell and git alone. kendex only arms and reports: `kendex guard install` and `kendex guard uninstall` invoke the installer, and `kendex check` relays the installer's `--check` verdict where `.git/hooks/kendex-guards` exists rather than forming a second opinion.

The `pre-commit-check` harness hook never stands in for the git hooks. Where both hooks are armed it steps aside; where nothing is armed it refuses the commit and names `kendex guard install`. It refuses only what a git hook cannot: a `--no-verify` flag, a short cluster holding its letter, or a `core.hooksPath` key. Half-armed is not armed: with `commit-msg` missing, git takes any message.

## Configuration

Every key, its default and its meaning: [SKILL.md](SKILL.md) § Configuration. Each resolves environment > `.env.local` > `.kendex/settings.toml` > committed `kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > default; a `.env` file is never read. Per-check flags (`--excludes`, `--baseline`) override every source; relative paths are repo-root-relative.

```toml
[env]
GROWTH_GUARDS_BYTE_CEILING_KB = "500"
GROWTH_GUARDS_CHECKS = "todo-ban suppression-ban"
```
