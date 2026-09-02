# size-ratchet

A tighten-only gate on file size. New code cannot introduce a tracked file
over its threshold; files already over it are frozen in a baseline at their
current sizes. While a row keeps its unit, its number may only shrink. Growth
is never automated away: the single path to a bigger number is a reviewed
hand edit declared with `RATCHET_RAISE=1`, and a frozen class refuses even
that. Markdown is measured in bytes and code in lines. Flags and exit codes:
`size-ratchet --help`; verdicts: [Semantics](#semantics); internals:
`DEVELOPMENT.md`.

## Usage

```bash
.agents/skills/size-ratchet/scripts/size-ratchet            # check (pre-PR / CI)
.agents/skills/size-ratchet/scripts/size-ratchet --staged   # check what a commit records (git hook)
.agents/skills/size-ratchet/scripts/size-ratchet --update   # tighten the baseline
.agents/skills/size-ratchet/scripts/size-ratchet --seed     # write the FIRST baseline
```

## Semantics

- **Scope**: every tracked file (`git ls-files`), tests included, minus the
  exclusion list and the baseline itself. A policy file cannot carry a row
  for its own size.
- **Units**: a class threshold counts LINES when it is a bare number and
  BYTES when it carries the `k` suffix (`24k` = 24×1024 bytes). Lines are
  newline counts. The shipped list measures markdown in bytes, because a
  re-wrap moves a line count on prose and leaves the byte count alone, and
  everything else in lines.
- **Threshold**: `SIZE_RATCHET_CLASSES` first, then the shipped
  `SIZE_RATCHET_DEFAULT_CLASSES`, then `SIZE_RATCHET_THRESHOLD` (default
  `400` lines), with one inversion on frozen paths. [Path
  classes](#path-classes) states that rule and is the only place that does.
  Every file resolves to exactly one threshold, and every other semantic runs
  per file against it.
- **FAIL** (exit 1) on any of:
  1. **New offender** — a file over its threshold with no baseline row.
  2. **Growth** — a baselined file whose actual size exceeds its row.
  3. **Baseline looser than reality** — a row above the file's actual
     size, a row for a file now at/under its threshold, or a row for a
     file that left the tracked set (deleted, or newly excluded). The
     ratchet must move down; stale slack is a failure, not headroom.
  4. **A row in the wrong unit** — a byte class carrying a line row, or the
     reverse. The number counts something else, so `--update` re-measures it
     instead of comparing it.
  5. **A row added, raised, or changed to another unit against the trusted
     baseline** — see [Trusted HEAD baseline](#trusted-head-baseline).
- **`--staged`** counts index blobs for every tracked file rather than
  preferring the worktree copy: what the commit records is the blob. Use it
  in a pre-commit hook; CI, which checks out a clean tree, does not need it.
  It also runs the `--update` rewrite itself and stages the baseline, so a
  commit that shrinks a limited file passes on the first attempt. Two
  accepted edges, neither of which loosens a row: a `git commit -- <paths>`
  commit acquires the baseline change, and unrelated unstaged row edits in
  the baseline are staged along with it.
- **`--update`** tightens only: it lowers rows to the actual size, re-measures
  rows whose unit no longer matches their class, and removes rows for files
  now at/under their own threshold or no longer counted. It never adds a row
  or raises a number whose unit stayed the same, then re-checks.
- Exit codes: `0` clean, `1` violations, `2` usage/config/collection error.

## Trusted HEAD baseline

Every mode uses one reference. `--baseline` or a process
`SIZE_RATCHET_BASELINE` applies directly; otherwise the settings parser reads
the implicit root and nested sources, tracked `.env.local`, or an explicit
repo-relative source from HEAD. A HEAD symlink at the source path itself is
followed only while its target stays in the repository; one at a parent
component refuses, because HEAD cannot be read through it and a lookup that
could not be performed is not an absent source. An absolute, escaping, or candidate-only
explicit source contributes nothing to the historical lookup; if it assigns
this key, the run refuses because that value has no historical form. The same
rule applies to an untracked `.env.local`. The rows at the selected HEAD path are
the only reference, even when the candidate uses another path or its target
already held dormant rows. Repoint in a commit that changes nothing else, then
change its rows next; the gate does not check that sequence. No rows at the
selected path means a true bootstrap, and the gate says so on its verdict line
rather than reporting a clean raise check.

For a candidate row in the same unit, the reference number is its ceiling. A
larger open row or a first row beside an existing reference set needs
`RATCHET_RAISE=1`; a frozen row never rises. When the units differ, the
numbers are not compared: an open row needs the same declaration and a frozen
row refuses until the file is below its new threshold. The gate reads no
commit message, so put the declaration's reason in the commit body.

## Baseline format

`tools/size-ratchet-baseline.tsv` by default (`SIZE_RATCHET_BASELINE` or
`--baseline FILE` to relocate). One row per frozen offender, `path<TAB>size`,
the size suffixed `b` when its class counts bytes:

```
crates/core/src/error.rs	495
docs/handbook.md	86104b
```

Rows are `LC_ALL=C` sorted, paths unique, counts positive. A malformed,
unsorted, or duplicated baseline is a config error (exit 2), not a silent
pass — the file is reviewed input, so it fails loud. A row naming the baseline
itself is stale because the baseline is outside the measured set.

### Seeding a first baseline

`--update` never adds rows, so the first baseline has its own mode:
`size-ratchet --seed` writes every tracked, non-excluded file over its
deciding threshold at its current size, `LC_ALL=C` sorted. It refuses a
selected baseline that already has rows or does not parse. The baseline and
exclusion list must be different plain leaf paths. Either leaf being a symlink
refuses. The baseline's physical parent must stay in the repository; the
exclusion parent is read-only. Their future physical destinations must differ,
including through in-repository parent symlinks. Seed uses
the [trusted HEAD baseline](#trusted-head-baseline) like every other mode: a
true first seed succeeds without `RATCHET_RAISE=1`, while seed after a repoint
is judged against the prior active rows. The seeded file lands uncommitted, so
the initial freeze is still a reviewed diff.

## Path classes

A file's threshold is the **first** entry whose pattern matches its full
repo-relative path across `SIZE_RATCHET_CLASSES`, then
`SIZE_RATCHET_DEFAULT_CLASSES`, else `SIZE_RATCHET_THRESHOLD`. Patterns are
the same shell globs as the exclusion list (`*` crosses `/`), matched by the
same matcher. A pattern cannot contain `;`, which separates entries.

The package ships this list, so a repo that configures nothing still runs it:

| Class | Threshold |
|---|---|
| `AGENTS.md`, `CLAUDE.md`, and their nested forms | 24k bytes |
| `*/SKILL.md` | 24k bytes |
| `*/workflows/*.md` | 40k bytes |
| every other `*.md` | 64k bytes |
| `tests/*`, `test/*`, `__tests__/*`, `tests.rs` and their `*/` forms, plus `*test_util.rs`, `*.test.*`, `*.spec.*` | 800 lines |
| everything else | `SIZE_RATCHET_THRESHOLD`, 400 lines |

A repo overrides a class, never the list: its own entries are matched first,
and the shipped list decides everything they leave alone.

```toml
[env]
SIZE_RATCHET_CLASSES = "*/SKILL.md=32k"
```

**A repo entry never shadows a frozen class.** `*` crosses `/`, so
`ui/*.ts=250` also matches the test files under `ui/`, and a broader
`docs/*=250` reaches documents too. Those paths already have a shipped class
naming them, and the repo never named them: the entry retitles that class
silently, the counting UNIT included, so a `docs/*=250` written for code
judges a byte class in lines. Such an entry is skipped and the shipped class
decides. The rule holds in both directions, a looser repo entry as much as a
tighter one, so no consumer restates a shipped threshold to scope a narrower
policy to one directory:

```toml
[env]
SIZE_RATCHET_CLASSES = "ui/*.ts=250;ui/*.tsx=250"  # ui/ test files stay at 800
```

To move a frozen class deliberately, restate that class's own pattern, as
the `*/SKILL.md` example above does: an entry naming a pattern the shipped
list carries still wins. Where the shipped list names no class for a frozen
path, the repo entry stands.

**This is the only statement of the rule.** Every other surface — the
`--help` text, the block comments, `DEVELOPMENT.md`, the settings table —
names it and points here, because a rule paraphrased in six places loses a
clause in one of them.

The verdict line says what each entry governed. An entry that decided some
paths and was passed over on frozen ones reads `ui/*.ts=250 (yielded on
frozen paths)`; one that decided none reads `(governed nothing: decided no
counted path)`. It reports the state, not the cause: a pattern matching
nothing and a pattern an earlier entry already claimed cannot be told apart,
and an entry passed over on frozen paths reads the same once it decided
nothing, because one reason is enough.

`SIZE_RATCHET_DEFAULT_CLASSES = ""` drops the shipped list; the repo's own
`SIZE_RATCHET_CLASSES` still matches first, so single-threshold behavior
needs both empty.

A directory name takes **both** forms: `*/tests/*` requires a
slash-delimited prefix, so a root-level `tests/` needs its own `tests/*`
entry. The shipped list carries both for every directory pattern it names;
a repo writing its own entries has to do the same.

## Exclusion list

`tools/size-ratchet-excludes` by default (`SIZE_RATCHET_EXCLUDES` or
`--excludes FILE`). One pattern per line, with a mandatory reason —
`pattern<TAB>reason`.

The package applies its own exclusions on top of that list — currently
`CHANGELOG*.md`, where one long file is the documented norm and the entries,
not the file, are what carry a rule.

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
| `SIZE_RATCHET_CLASSES` | *(none)* | This repo's overrides, `pattern=threshold` separated by `;`, matched before the shipped list, with one inversion on frozen paths — see [Path classes](#path-classes). |
| `SIZE_RATCHET_DEFAULT_CLASSES` | *(the shipped list)* | The class list the package ships; empty runs with no classes. |
| `SIZE_RATCHET_FROZEN_CLASSES` | *(markdown and tests)* | `;`-separated globs whose rows may never rise; they also decide where the [Path classes](#path-classes) inversion applies. |
| `SIZE_RATCHET_BASELINE` | `tools/size-ratchet-baseline.tsv` | Baseline path. |
| `SIZE_RATCHET_EXCLUDES` | `tools/size-ratchet-excludes` | Exclusion-list path. |

Each key resolves environment > `.env.local` > `.kendex/settings.toml` >
committed `kendex.settings.toml` (flat `KEY = "value"` under `[env]`; other
tables are ignored) > default; a `.env` file is never read, and `.env.local`
uses `KEY=value` or `export KEY=value`, parsed, never sourced. A source that exists but is unusable is a config error
(exit 2), never a fall-through to the next layer. `--baseline` /
`--excludes` override every source for those paths, and an empty value
(`--baseline=`, `--baseline ""`) is a config error, never a silent fall back
to the default path. All relative paths are repo-root-relative; the script
`cd`s to `git rev-parse --show-toplevel` before resolving anything.

`RATCHET_RAISE=1` is not configuration: it is a per-invocation declaration
that this run's added or raised rows are deliberate, read from the
environment alone.

## Requirements

`git`, `awk`, the usual POSIX userland. Bash 3.2 compatible (macOS bash).
