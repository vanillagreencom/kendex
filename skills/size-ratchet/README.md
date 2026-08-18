# size-ratchet

A tighten-only gate on file size. New code cannot introduce a tracked file
over the line threshold; files already over it are frozen in a baseline at
their current counts and may only shrink. Growth is never automated away:
the single path to a bigger number is a human editing the baseline row in a
reviewed diff, with the justification on the record. `SKILL.md` is the full
verdict-and-flag reference; `DEVELOPMENT.md` covers internals.

## Usage

```bash
.agents/skills/size-ratchet/scripts/size-ratchet            # check (pre-PR / CI)
.agents/skills/size-ratchet/scripts/size-ratchet --staged   # check what a commit records (git hook)
.agents/skills/size-ratchet/scripts/size-ratchet --update   # tighten the baseline
.agents/skills/size-ratchet/scripts/size-ratchet --seed     # write the FIRST baseline
```

## Semantics

- **Scope**: every tracked file (`git ls-files`), tests included, minus the
  exclusion list. Lines are newline counts (`wc -l`).
- **Threshold**: default `400` lines, override via `SIZE_RATCHET_THRESHOLD`.
  `SIZE_RATCHET_CLASSES` maps globs to thresholds so one repo can run more
  than one number — see [Path classes](#path-classes). Every file resolves to
  exactly one threshold, and every other semantic runs per file against it.
- **FAIL** (exit 1) on any of:
  1. **New offender** — a file over its threshold with no baseline row.
  2. **Growth** — a baselined file whose actual count exceeds its row.
  3. **Baseline looser than reality** — a row above the file's actual
     count, a row for a file now at/under its threshold, or a row for a
     file that left the tracked set (deleted, or newly excluded). The
     ratchet must move down; stale slack is a failure, not headroom.
- **`--staged`** counts index blobs for every tracked file rather than
  preferring the worktree copy: what the commit records is the blob. Use it
  in a pre-commit hook; CI, which checks out a clean tree, does not need it.
- **`--update`** tightens only: it lowers rows to the actual count and
  removes rows for files now at/under their own threshold or no longer
  counted — never adds a row, never raises a number — then re-checks, so it
  still exits 1 while growth or new offenders remain.
- Exit codes: `0` clean, `1` violations, `2` usage/config/collection error.

## Baseline format

`tools/size-ratchet-baseline.tsv` by default (`SIZE_RATCHET_BASELINE` or
`--baseline FILE` to relocate). One row per frozen offender, `path<TAB>lines`.

Rows are `LC_ALL=C` sorted, paths unique, counts positive. A malformed,
unsorted, or duplicated baseline is a config error (exit 2), not a silent
pass — the file is reviewed input, so it fails loud.

### Seeding a first baseline

`--update` never adds rows, so the first baseline has its own mode:
`size-ratchet --seed` writes every tracked, non-excluded file over its
deciding threshold at its current count, `LC_ALL=C` sorted. It refuses once
the baseline has rows in the worktree, the index **or** `HEAD` — the ratchet
is live there. The seeded file lands uncommitted, so the initial freeze is
still a reviewed diff.

## Path classes

`SIZE_RATCHET_CLASSES` gives a repo more than one threshold without any
local code. It is one line of `pattern=threshold` entries separated by `;`:

```toml
[env]
SIZE_RATCHET_THRESHOLD = "400"
SIZE_RATCHET_CLASSES = "tests/*=800;*/tests/*=800;*.test.*=800"
```

A file's threshold is the **first** entry whose pattern matches its full
repo-relative path, else `SIZE_RATCHET_THRESHOLD`. Patterns are the same
shell globs as the exclusion list (`*` crosses `/`), matched by the same
matcher. A pattern cannot contain `;`, which separates entries.

A directory name takes **both** forms, as above: `*/tests/*` requires a
slash-delimited prefix, so a root-level `tests/` matches only `tests/*`.

## Exclusion list

`tools/size-ratchet-excludes` by default (`SIZE_RATCHET_EXCLUDES` or
`--excludes FILE`). One pattern per line, with a mandatory reason —
`pattern<TAB>reason`.

The pattern is a shell glob matched against the full repo-relative path (`*`
crosses `/`). Blank lines and `#` comments are ignored; a pattern without a
reason is a config error. Typical entries:

```
Cargo.lock	lockfile — generated, size is not a design signal
vendor/*	vendored third-party code
*/fixtures/*	test fixtures — size is the test's business
src/gen/*.rs	generated bindings
```

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `SIZE_RATCHET_THRESHOLD` | `400` | Line threshold for paths matching no class. |
| `SIZE_RATCHET_CLASSES` | *(none)* | Per-path-class thresholds, `pattern=threshold` separated by `;`. |
| `SIZE_RATCHET_BASELINE` | `tools/size-ratchet-baseline.tsv` | Baseline path. |
| `SIZE_RATCHET_EXCLUDES` | `tools/size-ratchet-excludes` | Exclusion-list path. |

Each key resolves environment > `.env.local` > `.vstack/settings.toml` >
committed `vstack.settings.toml` (flat `KEY = "value"` under `[env]`) >
`.env` > default; env files use `KEY=value` or `export KEY=value`, parsed,
never sourced. A source that exists but is unusable is a config error
(exit 2), never a fall-through to the next layer. `--baseline` /
`--excludes` override every source for those paths, and an empty value
(`--baseline=`, `--baseline ""`) is a config error, never a silent fall back
to the default path. All relative paths are repo-root-relative; the script
`cd`s to `git rev-parse --show-toplevel` before resolving anything.

## Requirements

`git`, `awk`, and the usual POSIX userland. Bash 3.2 compatible (macOS
system bash).
