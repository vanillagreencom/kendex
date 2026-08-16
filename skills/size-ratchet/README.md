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
- **Threshold**: default `400` lines, override via
  `SIZE_RATCHET_THRESHOLD` (environment > `.env.local` > `.vstack/settings.toml` > `vstack.settings.toml` `[env]` > `.env` >
  default).
- **Path classes**: `SIZE_RATCHET_CLASSES` maps globs to thresholds so one
  repo can run more than one number — see [Path classes](#path-classes).
  Every file resolves to exactly one threshold and every other semantic
  below is unchanged, per file, against that number.
- **FAIL** (exit 1) on any of:
  1. **New offender** — a file over its threshold with no baseline row.
  2. **Growth** — a baselined file whose actual count exceeds its row.
  3. **Baseline looser than reality** — a row above the file's actual
     count, a row for a file now at/under its threshold, or a row for a
     file that left the tracked set (deleted, or newly excluded). The
     ratchet must move down; stale slack is a failure, not headroom.
- **Diagnostics** name the file, its count and the baseline row it violated,
  and — wherever a threshold decided the verdict — that threshold and
  whether the number came from a class pattern or the default, and state
  the remedies: *split at a concept seam, or raise the baseline row in this
  diff with justification*.
- **`--staged`** counts index blobs for every tracked file rather than
  preferring the worktree copy: what the commit records is the blob, and
  growth staged then reverted in the worktree is invisible to the default
  mode. Policy comes from the same snapshot — a TRACKED baseline, exclusion
  list or settings source is read from the index too, so an unstaged edit to
  any of them cannot authorize growth the commit does not carry, and a policy
  file staged for DELETION governs as absent. An untracked source (a personal
  `.env.local`) is still the worktree copy, and an explicit environment
  variable still wins over everything. Use it in a pre-commit hook; CI, which
  checks out a clean tree, does not need it.
- **`--update`** tightens only: it lowers rows to the actual count and
  removes rows for files now at/under their own threshold or no longer counted.
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
matcher. Whitespace around an entry and around its `=` is ignored, and an
empty entry is skipped.

A directory name takes **both** forms, as above: `*` may match nothing but
the literal `/` in `*/tests/*` still must be there, so `*/tests/*` covers
`pkg/tests/x` and never a root-level `tests/x` — that one needs `tests/*`.
A pattern cannot contain `;`, which separates entries.

Classes move only the number a path is judged against: new-offender,
growth, and stale-row detection and the tighten-only `--update` all run per
file against that file's own threshold, and every diagnostic names both the
number and where it came from (`class */tests/*` or `default`).

A malformed entry — no `=`, an empty pattern, a threshold that is not a
positive integer — is a config error (exit 2) naming the entry, never a
silent fall back to the base threshold. Unset or empty is exact
single-threshold behavior.

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
| `SIZE_RATCHET_THRESHOLD` | `400` | Line threshold for paths matching no class. |
| `SIZE_RATCHET_CLASSES` | *(none)* | Per-path-class thresholds, `pattern=threshold` separated by `;`. |
| `SIZE_RATCHET_BASELINE` | `tools/size-ratchet-baseline.tsv` | Baseline path. |
| `SIZE_RATCHET_EXCLUDES` | `tools/size-ratchet-excludes` | Exclusion-list path. |

Each key resolves environment > `.env.local` > `.vstack/settings.toml` > committed `vstack.settings.toml`
(flat `KEY = "value"` assignment under `[env]`) >
`.env` > default (env files use `KEY=value` or `export KEY=value`; parsed,
never sourced). Only an ABSENT source is skipped: a source that exists but
is unusable — unreadable, a directory, FIFO, socket or device, or a symlink
that does not resolve — is a config error (exit 2), never a fall-through to
the next layer; `/dev/null` forces the built-in defaults. `--baseline` /
`--excludes` flags override every source for the paths. All relative paths
are
repo-root-relative; the script `cd`s to `git rev-parse --show-toplevel`
before resolving anything.

```toml
[env]
SIZE_RATCHET_THRESHOLD = "400"
SIZE_RATCHET_CLASSES = "tests/*=800;*/tests/*=800"
```

## Migration

Consumers already running a size ratchet with this exact baseline format
(`path<TAB>lines`, `LC_ALL=C` sorted) can swap this script in drop-in: keep
the existing baseline file where it is and point `SIZE_RATCHET_BASELINE`
(or `--baseline`) at it. Semantics are unchanged by agreement across repos:
same three failure directions, same tighten-only `--update`.

A repo adopting the `400` default over a looser one gains offenders in the
range between the two thresholds. Order matters: declare
`SIZE_RATCHET_CLASSES` **first**, then freeze. Freezing first baselines
401–800-line test files that the test class then puts back under their
threshold, and a row for a file under its threshold is a stale row — an
immediately failing migration.

`--update` never adds rows, so the freeze is one hand-edit: with the classes
declared, run the check and turn each reported `new offender` line into a
`path<TAB>lines` row (see [Seeding a first baseline](#seeding-a-first-baseline)),
then commit that baseline together with the settings change. Declaring
`SIZE_RATCHET_THRESHOLD` explicitly keeps the previous number instead.

## Requirements

`git`, `awk`, and the usual POSIX userland. Bash 3.2 compatible (macOS
system bash).
