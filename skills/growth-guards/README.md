# growth-guards

Five checks that stop quiet repo decay, one family beside `size-ratchet`:
work markers, oversized additions, blanket lint suppression, conflict
markers, and non-conventional commit messages. One idiom, one exit contract
— `0` clean, `1` violations, `2` usage/config/collection error. Scans read
INDEX content and skip binaries. Requirements: `git`, `awk`, the usual
POSIX userland; Bash 3.2 compatible (macOS bash). `SKILL.md` is the
agent-facing reference; `DEVELOPMENT.md` covers internals.

## Invocation

```bash
scripts/growth-guards [all]         # batch: every enabled repo check
scripts/growth-guards CHECK [ARGS]  # one check, flags passed through
scripts/CHECK [ARGS]                # each check is a standalone executable
```

The batch runs `GROWTH_GUARDS_CHECKS` (default
`todo-ban byte-ceiling suppression-ban conflict-markers`) and fails closed:
exit 2 if any check could not complete, else 1 on violations. `commit-msg`
reads a message, so it never runs in the batch. Installed scripts live under
`.agents/skills/growth-guards/scripts/`; wire CI at whichever grain fits
(`byte-ceiling --base origin/main` gates a PR's additions); the git hooks
below cover local commits.

## Git hooks

```bash
.agents/skills/growth-guards/scripts/install-git-hooks [--repo PATH]
.agents/skills/growth-guards/scripts/install-git-hooks --uninstall
.agents/skills/growth-guards/scripts/install-git-hooks --check
```

The installer writes a helper into `.git/hooks` plus one marked delegating
line in `pre-commit` and `commit-msg` — never `core.hooksPath`; an existing
hook keeps its content and exit status; repeat runs are no-ops and repairs.
`--uninstall` drops only the helper and our line. `kendex guard install` and
`kendex guard uninstall` invoke those two.

`--check` writes nothing: `0` armed in `.git/hooks`, `1` drifted, absent, or
`core.hooksPath` set and empty (which switches git hooks off), `2` could not
determine — which any `core.hooksPath` naming a directory is: this package
reads `.git/hooks` only, whatever that value resolves to. Never a silent
pass.

`pre-commit` judges ONE commit snapshot: `size-ratchet --staged` and
`preflight --staged` when the committing work tree or this install
carries them (work tree first), the `growth-guards` batch, then the
repo-root-relative executable named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL`
(empty means none). `commit-msg` runs this family's message gate. Both
shims BLOCK and fail closed — `1` carries the check's remediation text,
`2` a guard that could not run; `git commit --no-verify` is the bypass.

## Who gates a commit

Two layers, and only one of them is authoritative.

**The git hooks are the gate.** Git runs them for every committer — a person
at a terminal, any AI harness, a script, an editor's commit button. They need
no kendex binary: the shim execs this skill's committed scripts. Git never
clones `.git/hooks`, so a fresh clone carries the scripts but no shims. One
`kendex guard install` arms them, and every commit after that is gated by
committed shell and git on a machine that has never installed kendex.

**kendex only arms and reports.** `kendex guard install` and `kendex guard
uninstall` invoke the installer; `kendex check` reads the hook files and says
armed, not armed, or could not tell. It runs nothing out of a checkout and
implements no check of its own — the verdicts a commit is judged by are all
this skill's.

**The `pre-commit-check` harness hook never stands in.** Where BOTH git hooks
are armed — this package's marker in `pre-commit` and `commit-msg`, both
executable — it steps aside and lets git run the gate. Half-armed is not
armed: with `commit-msg` missing, git takes any message. The hook does the
one thing a git hook cannot, refusing a command that would sidestep an armed
hook (`--no-verify`, the short flag, injected git configuration), and where
nothing is armed it refuses the commit and names `kendex guard install`. It
gates its own working directory and no other, and runs no script of the
repository's on anyone's behalf.

## The checks

What each one bans, and how it is scoped: [CHECKS.md](CHECKS.md).

## Configuration

Every key, its default and its meaning: [SKILL.md](SKILL.md). Each resolves
environment > `.env.local` > `.kendex/settings.toml` > committed
`kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > `.env` >
default. Per-check flags (`--excludes`, `--baseline`) override every
source; relative paths are repo-root-relative.

```toml
[env]
GROWTH_GUARDS_BYTE_CEILING_KB = "500"
GROWTH_GUARDS_CHECKS = "todo-ban suppression-ban"
```
