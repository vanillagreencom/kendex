---
name: growth-guards
description: "Five repo growth guards beside size-ratchet — todo-ban, byte-ceiling, suppression-ban, conflict-markers, commit-msg — and the git hook shims that run them. Load to add, tune, or debug a check, the hooks, or GROWTH_GUARDS_* settings."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [automation]
---

# Growth Guards

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

Five checks beside `size-ratchet`, sharing its idiom and exit contract.

```bash
.agents/skills/growth-guards/scripts/growth-guards              # batch: every enabled repo check
.agents/skills/growth-guards/scripts/growth-guards todo-ban     # one check by name, flags pass through
.agents/skills/growth-guards/scripts/install-git-hooks          # arm the git pre-commit/commit-msg shims
.agents/skills/growth-guards/scripts/install-git-hooks --check  # read-only: are the shims still armed?
```

Each check is also invocable as `scripts/CHECK`.

## The checks

| Check | Verdict |
|---|---|
| **todo-ban** | Any work marker (TODO, FIXME, HACK, XXX in comment-marker shapes) in a tracked, non-excluded file fails. No baseline. Prose naming a marker word does not fire. |
| **byte-ceiling** | A newly added tracked file over the ceiling (default 200 KB) fails. `--staged` (default) gates the staged diff, `--base REF` the additions since merge-base, `--all` sweeps every tracked file. Lockfiles are exempt built-in. |
| **suppression-ban** | Blanket lint suppressions fail flat: module-wide rust `allow` inner attributes, file-level ruff/flake8 noqa, the bare `eslint-disable` block form, bare or `all` nolint, biome's `biome-ignore-all` / unscoped `biome-ignore-start` / rule-less `biome-ignore lint` and group forms. Bare rust `allow(dead_code)`/`allow(unused*)` attributes are counted per file against a tighten-only baseline; `--update` lowers/removes rows, never adds or raises one. A per-line suppression naming its lint with a stated reason stays legal. |
| **conflict-markers** | An unresolved merge-conflict marker in a tracked, non-excluded file fails: the open/base/close trio (seven `<`, seven vertical bars, seven `>`) at column 0, each followed by a space or end of line. No baseline. Indented or quoted occurrences and the bare seven-equals separator do not fire. |
| **commit-msg** | Header must be `type(scope)!: subject` (scope and `!` optional). Uppercase issue keys (`fix(ABC-123)`) and `#`-number scopes pass; git-generated messages (Merge/Revert/Reapply, fixup!/squash!/amend!) pass unchanged. Takes the message file or stdin. |

Exit codes everywhere: `0` clean, `1` violations, `2` usage/config/collection
error. Any failure to collect (unreadable file, git/grep execution failure) is
exit 2, never a silent pass. The batch dispatcher exits 2 if any check could
not complete.

Scans read INDEX content (`git grep --cached`, staged blobs). A scan whose
paths include an UNMERGED entry exits 2 naming them: finish or abort the merge,
then re-run.

## Git hooks

`scripts/install-git-hooks [--repo PATH]` writes `.git/hooks` shims.
`pre-commit` runs, in order: `size-ratchet --staged` and `preflight --staged`
when the committing work tree or this install carries those skills (the work
tree's copy wins; a first commit skips preflight with a note; a size-ratchet
that rejects `--staged` in its first-line parser diagnostic is a stated skip —
any other failure blocks); the batch over staged content; then the
repo-root-relative executable named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL`.
`commit-msg` runs the message gate. Both BLOCK on the exit contract, fail
closed on a guard that could not run; `git commit --no-verify` is the bypass.
`kendex guard install` runs the installer and `kendex guard uninstall` runs
`--uninstall`. Those are the only verbs that invoke it, so disarm before
removing this skill: shims whose scripts are gone block every commit.
`kendex check` reads the hook files itself and reports armed, not armed, or
could not tell — it runs nothing out of a checkout. The `--check` verdicts
below are the fuller vocabulary, for a person running it:
(0 armed — in `.git/hooks` or a `core.hooksPath` directory hand-wired to this
skill's `pre-commit` and `commit-msg`; 1 drifted, absent, or dormant behind a
`core.hooksPath` that redirects away from the shims; 2 could not determine —
unreadable hooks directory or an unrecognized hand-wired hook). Repeat runs
are no-ops and repairs; `core.hooksPath` is never set; existing hooks keep
their content and exit status. Full install and refusal behaviour:
[DEVELOPMENT.md](DEVELOPMENT.md).

The git hooks are the authoritative gate: they run for every committer, and
they need no kendex binary — the shim execs this skill's committed scripts.
kendex arms and reports, and implements no check of its own. The
`pre-commit-check` harness hook stands aside where a git hook is armed,
refuses commands that would sidestep one, and refuses the commit where
nothing is armed — it never runs these scripts on a repository's behalf.
Layering and reasoning: [README](README.md).

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `GROWTH_GUARDS_CHECKS` | `todo-ban byte-ceiling suppression-ban conflict-markers` | Batch check list (`commit-msg` never batches). |
| `GROWTH_GUARDS_TODO_EXCLUDES` | `tools/todo-ban-excludes` | todo-ban exclusion list. |
| `GROWTH_GUARDS_BYTE_CEILING_KB` | `200` | Byte ceiling in KB. |
| `GROWTH_GUARDS_BYTE_EXCLUDES` | `tools/byte-ceiling-excludes` | byte-ceiling exclusion list (declared asset trees). |
| `GROWTH_GUARDS_SUPPRESSION_EXCLUDES` | `tools/suppression-ban-excludes` | suppression-ban exclusion list. |
| `GROWTH_GUARDS_SUPPRESSION_BASELINE` | `tools/suppression-baseline.tsv` | Bare-allow ratchet baseline. |
| `GROWTH_GUARDS_CONFLICT_EXCLUDES` | `tools/conflict-markers-excludes` | conflict-markers exclusion list. |
| `GROWTH_GUARDS_COMMIT_TYPES` | `build chore ci docs feat fix perf refactor revert style test` | Accepted commit types. |
| `GROWTH_GUARDS_PRE_COMMIT_LOCAL` | *(empty)* | Repo-root-relative executable the pre-commit shim runs last. |

Resolution order for every key: explicit environment > `.env.local` >
`.kendex/settings.toml` > the repo's committed `kendex.settings.toml` (flat
`KEY = "value"` under `[env]`) > `.env` > built-in default. Only an ABSENT
source is skipped; one that exists but is unusable is a config error (exit 2).
`GROWTH_GUARDS_SETTINGS_FILE=/dev/null` skips `.env.local`, the settings file
and `.env`, leaving environment variables and defaults.

**Excludes format** — `pattern<TAB>reason` per line (shell glob against the
full repo-relative path; `*` crosses `/`); a pattern without a reason is a
config error. **Baseline format** — `path<TAB>count`, `LC_ALL=C` sorted,
unique paths, positive counts.

What each check bans and how it is scoped: [CHECKS.md](CHECKS.md). Seeding
a first baseline and CI wiring: [README.md](README.md). Marker shapes, per-language suppression patterns,
and the hook install and removal contract: [DEVELOPMENT.md](DEVELOPMENT.md).
