---
name: growth-guards
description: "Four repo growth guards beside size-ratchet: todo-ban (flat ban on work markers — the TODO/FIXME/HACK/XXX comment shapes — in first-party tracked files), byte-ceiling (newly added files over N KB fail, default 200; lockfiles and declared asset trees exempt), suppression-ban (blanket lint suppressions fail flat; bare rust allow(dead_code)/allow(unused) attributes ratchet against a tighten-only baseline), and commit-msg (conventional-commit gate that accepts uppercase issue keys and git-generated messages). Also installs the real git pre-commit/commit-msg shims that run the chain for every tool that commits. Load when adding, tuning, or debugging any of these checks, the git hook shims, their exclusion lists, the suppression baseline, or GROWTH_GUARDS_* settings — or when a change trips one of them."
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

Four checks that stop quiet repo decay, one family beside `size-ratchet`:
same idiom (language-agnostic where possible, tighten-only baselines only
where legacy counts exist, every failure names its remediation, exclusion
rows carry their reasons) and the same exit contract.

```bash
.agents/skills/growth-guards/scripts/growth-guards              # batch: every enabled repo check
.agents/skills/growth-guards/scripts/growth-guards todo-ban     # one check by name, flags pass through
.agents/skills/growth-guards/scripts/install-git-hooks          # arm the git pre-commit/commit-msg shims
```

Every check is also independently invocable as `scripts/CHECK` — wire CI at
whichever grain fits.

## Git hooks

`scripts/install-git-hooks [--repo PATH]` writes real `.git/hooks` shims, so
the chain fires for every tool that commits — any agent harness, an editor, a
script, a plain shell. `vstack add` and `vstack refresh` run it for a project
that has this skill installed, and `vstack remove growth-guards` runs
`--uninstall` before the files go; a non-git project is skipped with a note.

- `pre-commit` runs `scripts/pre-commit`: `size-ratchet --staged` when that
  skill is installed beside this one, the batch over staged content, then the
  repo-root-relative executable named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL`
  (empty = none).
- `commit-msg` runs `scripts/commit-msg` on git's message file.
- The shims BLOCK and fail closed on the family's exit contract: `1` for a
  violation with its remediation, `2` for a guard that could not run, naming
  what is missing. `git commit --no-verify` is the deliberate bypass.
- The line goes first in the hook, not last: content ending in an explicit
  `exit` would leave an appended guard unreachable.
- `core.hooksPath` is never set — it would redirect every hook and disable the
  repository's existing ones. Where a repo already sets it, the install is a
  reported skip.
- Existing hooks keep their content and exit status; the install is a no-op
  only when the exact delegating line is present, and repairs a tampered or
  stale one and a cleared executable bit. Removal keeps and retargets the
  shims while another work tree on the same hooks directory still has a
  separate install. Full behaviour: [README.md](README.md).

## The checks

| Check | Verdict |
|---|---|
| **todo-ban** | Any work marker (the words TODO, FIXME, HACK, XXX in comment-marker shapes) in a tracked, non-excluded file fails. No baseline. Prose that quotes or names a marker word does not fire. |
| **byte-ceiling** | A newly added tracked file over the ceiling (default 200 KB) fails. `--staged` (default) gates the staged diff, `--base REF` the additions since merge-base, `--all` sweeps every tracked file. Lockfiles are exempt built-in. |
| **suppression-ban** | Blanket lint suppressions fail flat: module-wide rust `allow` inner attributes, file-level ruff/flake8 noqa, the bare `eslint-disable` block form, bare or `all` nolint. Bare rust `allow(dead_code)`/`allow(unused*)` attributes are counted per file against a tighten-only baseline; `--update` lowers/removes rows, never adds or raises one. A per-line suppression naming its lint with a stated reason stays legal. |
| **commit-msg** | Header must be `type(scope)!: subject` (scope and `!` optional). Uppercase issue keys (`fix(ABC-123)`) and `#`-number scopes pass; git-generated messages (Merge/Revert/Reapply, fixup!/squash!/amend!) pass unchanged. Takes the message file or stdin. |

Exit codes everywhere: `0` clean, `1` violations, `2`
usage/config/collection error. The gates distinguish "measured and fine"
from "could not measure": any failure to collect (an unreadable file, a
git/grep execution failure) is a loud exit 2, never a silent pass. The
batch dispatcher exits 2 if any check could not complete.

Scans read INDEX content (`git grep --cached`, staged blobs): what is
staged is what gets committed, and a sparse checkout cannot hide a tracked
file from a gate.

## Configuration

Resolution order for every key: explicit environment > `.env.local`
(personal, untracked) > `.vstack/settings.toml` > the repo's committed
`vstack.settings.toml` (flat `KEY = "value"` under `[env]`) > `.env` >
built-in default. Only an ABSENT source is skipped: a source that exists
but is unusable — unreadable, a directory, FIFO, socket or device, or a
symlink that does not resolve — is a config error (exit 2), never a
fall-through to the next layer. `/dev/null` forces the built-in defaults.

| Key | Default | Meaning |
|---|---|---|
| `GROWTH_GUARDS_CHECKS` | `todo-ban byte-ceiling suppression-ban` | Batch check list (`commit-msg` never batches). |
| `GROWTH_GUARDS_TODO_EXCLUDES` | `tools/todo-ban-excludes` | todo-ban exclusion list. |
| `GROWTH_GUARDS_BYTE_CEILING_KB` | `200` | Byte ceiling in KB. |
| `GROWTH_GUARDS_BYTE_EXCLUDES` | `tools/byte-ceiling-excludes` | byte-ceiling exclusion list (declared asset trees). |
| `GROWTH_GUARDS_SUPPRESSION_EXCLUDES` | `tools/suppression-ban-excludes` | suppression-ban exclusion list. |
| `GROWTH_GUARDS_SUPPRESSION_BASELINE` | `tools/suppression-baseline.tsv` | Bare-allow ratchet baseline. |
| `GROWTH_GUARDS_COMMIT_TYPES` | `build chore ci docs feat fix perf refactor revert style test` | Accepted commit types. |
| `GROWTH_GUARDS_PRE_COMMIT_LOCAL` | *(empty)* | Repo-root-relative executable the pre-commit shim runs last. |

**Excludes format** — `pattern<TAB>reason` per line (shell glob against the
full repo-relative path; `*` crosses `/`); blank lines and `#` comments are
ignored, and a pattern without a reason is a config error — every exclusion
carries its justification (vendored, generated, assets, fixtures).
**Baseline format** — `path<TAB>count`, `LC_ALL=C` sorted, unique paths,
positive counts; the only way a number goes up is a human editing the row
in a reviewed diff.

Marker shapes, per-language suppression patterns, seeding a first baseline,
and CI wiring: [README.md](README.md).
