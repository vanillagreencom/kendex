# size-ratchet

A tighten-only gate on file size. New code cannot introduce a tracked file
over the line threshold; files already over it are frozen in a baseline at
their current counts and may only shrink. Growth is never automated away:
the single path to a bigger number is a human editing the baseline row in a
reviewed diff, with the justification on the record.

## Semantics

- **Scope**: every tracked file (`git ls-files`), tests included, minus the
  exclusion list. Symlinks are skipped; a submodule gitlink at a tracked
  path is not a countable file (a baseline row for one is stale). A tracked
  file absent from the worktree (unstaged deletion, sparse checkout) is
  counted from the INDEX blob, so "every tracked file" holds on partial
  trees too — a sparse checkout can neither smuggle a new offender past the
  gate nor loosen a baselined row. An index blob that cannot be read
  (corrupt object, promisor blob unavailable) is a collection error (exit
  2, naming the file) — a file the gate could not measure is never
  skipped. A tracked path containing a tab or newline is refused
  loudly (exit 2; exclude it to skip the gate) — it cannot be represented
  in the line-oriented records. Lines are newline counts (`wc -l`).
- **Threshold**: default `1000` lines, override via
  `SIZE_RATCHET_THRESHOLD` (environment > `.env.local` > `.vstack/settings.toml` > `vstack.settings.toml` `[env]` > `.env` >
  default).
- **FAIL** (exit 1) on any of:
  1. **New offender** — a file over the threshold with no baseline row.
  2. **Growth** — a baselined file whose actual count exceeds its row.
  3. **Baseline looser than reality** — a row above the file's actual
     count, a row for a file now at/under the threshold, or a row for a
     file that left the tracked set (deleted, or newly excluded). The
     ratchet must move down; stale slack is a failure, not headroom.
- **Diagnostics** name the file, its count, and the threshold or baseline
  row it violated, and state the remedies: *split at a concept seam, or
  raise the baseline row in this diff with justification*.
- **`--update`** tightens only: it lowers rows to the actual count and
  removes rows for files now at/under the threshold or no longer counted.
  It never adds a row and never raises a number, then re-checks — so it
  still exits 1 while growth or new offenders remain. Deliberate growth is
  a hand-edit of the row.
- Exit codes: `0` clean, `1` violations, `2` usage/config/collection error.

## Baseline format

`tools/size-ratchet-baseline.tsv` by default (`SIZE_RATCHET_BASELINE` or
`--baseline FILE` to relocate). One row per frozen offender:

```
path<TAB>lines
```

Rows are `LC_ALL=C` sorted, paths unique, counts positive. A malformed,
unsorted, or duplicated baseline is a config error (exit 2), not a silent
pass — the file is reviewed input, so it fails loud.

### Seeding a first baseline

In a sparse checkout that omits the baseline file, checks still run against
the index copy, but `--update` refuses (it will not rewrite a file the
worktree cannot show): materialize it first with
`git update-index --no-skip-worktree -- <baseline-path> && git checkout-index -- <baseline-path>`
(literal file paths in both commands — works in cone and non-cone mode for
any path shape; a later `git sparse-checkout reapply` re-hides the file),
then rerun.

`--update` never adds rows, so the first baseline is created explicitly:
run the check, and turn each reported `new offender` line (path and count)
into a `path<TAB>lines` row, `LC_ALL=C` sorted. That the initial freeze is
a hand-authored, reviewed diff is the point — every frozen offender enters
the record deliberately.

## Exclusion list

`tools/size-ratchet-excludes` by default (`SIZE_RATCHET_EXCLUDES` or
`--excludes FILE`). One pattern per line, with a mandatory reason:

```
pattern<TAB>reason
```

The pattern is a shell glob matched against the full repo-relative path
(`*` crosses `/`). Blank lines and `#` comments are ignored; a pattern
without a reason is a config error. Typical entries:

```
Cargo.lock	lockfile — generated, size is not a design signal
vendor/*	vendored third-party code
*/fixtures/*	test fixtures — size is the test's business
src/gen/*.rs	generated bindings
```

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `SIZE_RATCHET_THRESHOLD` | `1000` | New-file line threshold. |
| `SIZE_RATCHET_BASELINE` | `tools/size-ratchet-baseline.tsv` | Baseline path. |
| `SIZE_RATCHET_EXCLUDES` | `tools/size-ratchet-excludes` | Exclusion-list path. |

Each key resolves environment > `.env.local` > `.vstack/settings.toml` > committed `vstack.settings.toml`
(flat `KEY = "value"` assignment under `[env]`) >
`.env` > default (env files use `KEY=value` or `export KEY=value`; parsed,
never sourced). `--baseline` / `--excludes` flags override every source for
the paths. All relative paths are
repo-root-relative; the script `cd`s to `git rev-parse --show-toplevel`
before resolving anything.

```toml
[env]
SIZE_RATCHET_THRESHOLD = "800"
```

## Migration

Consumers already running a size ratchet with this exact baseline format
(`path<TAB>lines`, `LC_ALL=C` sorted) can swap this script in drop-in: keep
the existing baseline file where it is and point `SIZE_RATCHET_BASELINE`
(or `--baseline`) at it. Semantics are unchanged by agreement across repos:
same three failure directions, same tighten-only `--update`.

## Requirements

`git`, `awk`, and the usual POSIX userland. Bash 3.2 compatible (macOS
system bash).
