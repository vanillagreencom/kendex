---
name: growth-guards
description: "Five repo growth guards beside size-ratchet — todo-ban, byte-ceiling, suppression-ban, conflict-markers, commit-msg — and the git hook shims that run them. Load to add, tune, or debug a check, the hooks, or GROWTH_GUARDS_* settings."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# Growth Guards

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

Five checks that stop quiet repo decay, one family beside `size-ratchet`,
sharing its idiom and its exit contract.

```bash
.agents/skills/growth-guards/scripts/growth-guards              # batch: every enabled repo check
.agents/skills/growth-guards/scripts/growth-guards todo-ban     # one check by name, flags pass through
.agents/skills/growth-guards/scripts/install-git-hooks          # arm the git pre-commit/commit-msg shims
.agents/skills/growth-guards/scripts/install-git-hooks --check  # read-only: are the shims still armed?
```

Every check is also independently invocable as `scripts/CHECK` — wire CI at
whichever grain fits.

## The checks

| Check | Verdict |
|---|---|
| **todo-ban** | Any work marker (the words TODO, FIXME, HACK, XXX in comment-marker shapes) in a tracked, non-excluded file fails. No baseline. Prose that quotes or names a marker word does not fire. |
| **byte-ceiling** | A newly added tracked file over the ceiling (default 200 KB) fails. `--staged` (default) gates the staged diff, `--base REF` the additions since merge-base, `--all` sweeps every tracked file. Lockfiles are exempt built-in. |
| **suppression-ban** | Blanket lint suppressions fail flat: module-wide rust `allow` inner attributes, file-level ruff/flake8 noqa, the bare `eslint-disable` block form, bare or `all` nolint, biome's `biome-ignore-all` / unscoped `biome-ignore-start` / rule-less `biome-ignore lint` and group forms. Bare rust `allow(dead_code)`/`allow(unused*)` attributes are counted per file against a tighten-only baseline; `--update` lowers/removes rows, never adds or raises one. A per-line suppression naming its lint with a stated reason stays legal. |
| **conflict-markers** | An unresolved merge-conflict marker in a tracked, non-excluded file fails: the open/base/close trio (seven `<`, seven vertical bars, seven `>`) at column 0, each followed by a space or end of line. No baseline. Indented or quoted occurrences do not fire; the bare seven-equals separator is deliberately unmatched (a valid Markdown setext underline — a real conflict always carries the open and close markers). |
| **commit-msg** | Header must be `type(scope)!: subject` (scope and `!` optional). Uppercase issue keys (`fix(ABC-123)`) and `#`-number scopes pass; git-generated messages (Merge/Revert/Reapply, fixup!/squash!/amend!) pass unchanged. Takes the message file or stdin. |

Exit codes everywhere: `0` clean, `1` violations, `2`
usage/config/collection error. The gates distinguish "measured and fine"
from "could not measure": any failure to collect (an unreadable file, a
git/grep execution failure) is a loud exit 2, never a silent pass. The
batch dispatcher exits 2 if any check could not complete.

Scans read INDEX content (`git grep --cached`, staged blobs): what is
staged is what gets committed, and a sparse checkout cannot hide a tracked
file from a gate. An UNMERGED index cannot be scanned that way — git skips
unmerged entries and spends no error status doing it — so a scan whose paths
include one exits 2 naming them: finish or abort the merge, then re-run.

## Git hooks

`scripts/install-git-hooks [--repo PATH]` writes real `.git/hooks` shims —
`pre-commit` runs the chain (`size-ratchet --staged` and `preflight --staged`
when the committing work tree or this install carries those skills — the
work tree's copy wins, so a shared install in another checkout never decides
which gates exist — a first commit skips
preflight with a note, having no base to diff, and a size-ratchet that
rejects `--staged` in its own first-line parser diagnostic is a repo-local
replacement whose own wiring owns that gate: stated skip — any other
failure blocks as usual — the batch over staged
content, then the repo-root-relative executable named by
`GROWTH_GUARDS_PRE_COMMIT_LOCAL`),
`commit-msg` runs this family's message gate. They BLOCK on the family's exit
contract, fail closed on a guard that could not run, and `git commit
--no-verify` is the deliberate bypass. `vstack add` and `vstack refresh` run
the installer, `vstack remove growth-guards` runs `--uninstall` first, and
`vstack check` folds in `--check`'s read-only verdict (0 armed — in
`.git/hooks`, or in a `core.hooksPath` directory hand-wired to this skill's
`pre-commit` and `commit-msg`; 1 drifted, absent, or dormant behind a
`core.hooksPath` that redirects git away from the shims; 2 could not
determine — an unreadable hooks directory, or a hand-wired hook whose shape
this check does not recognize, is 2, never a pass and never a verdict). Repeat runs are no-ops and repairs; `core.hooksPath` is never set,
existing hooks keep their content and their own exit status. Full behaviour,
including what the installer refuses to touch:
[DEVELOPMENT.md](DEVELOPMENT.md).

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
`.vstack/settings.toml` > the repo's committed `vstack.settings.toml` (flat
`KEY = "value"` under `[env]`) > `.env` > built-in default. Only an ABSENT
source is skipped: one that exists but is unusable is a config error (exit
2), never a fall-through. `GROWTH_GUARDS_SETTINGS_FILE=/dev/null` selects no
settings source at all (`.env.local`, the settings file and `.env` are all
skipped), leaving environment variables and the defaults.

**Excludes format** — `pattern<TAB>reason` per line (shell glob against the
full repo-relative path; `*` crosses `/`); a pattern without a reason is a
config error. **Baseline format** — `path<TAB>count`, `LC_ALL=C` sorted,
unique paths, positive counts.

Per-check consumer detail, seeding a first baseline, and CI wiring:
[README.md](README.md). Marker shapes, per-language suppression patterns,
and the hook install and removal contract: [DEVELOPMENT.md](DEVELOPMENT.md).
