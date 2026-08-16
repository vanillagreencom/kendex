# growth-guards

Four checks that stop quiet repo decay, one family beside `size-ratchet`:
work markers, oversized additions, blanket lint suppression, and
non-conventional commit messages. Same idiom throughout — language-agnostic
where possible, tighten-only baselines only where legacy counts exist,
every failure carries its remediation, every exclusion carries its reason —
and the same exit contract: `0` clean, `1` violations, `2`
usage/config/collection error. A measurement that fails (unreadable file, a
git/grep execution failure) is a loud exit 2, never a silent pass.

All scans read INDEX content (`git grep --cached` / staged blobs): the gate
judges what is being committed, and a sparse checkout cannot hide a tracked
file from it. Binary files are skipped by the text scans.

## Invocation

```bash
scripts/growth-guards               # batch: every enabled repo check
scripts/growth-guards all           # ditto
scripts/growth-guards CHECK [ARGS]  # one check, flags passed through
scripts/CHECK [ARGS]                # each check is a standalone executable
```

The batch runs `GROWTH_GUARDS_CHECKS` (default
`todo-ban byte-ceiling suppression-ban`) and fails closed: exit 2 if any
check could not complete, else 1 if any found violations. `commit-msg`
reads a message, so it never runs in the batch.

Typical wiring:

```bash
# .git/hooks/commit-msg
.agents/skills/growth-guards/scripts/commit-msg "$1"

# pre-commit shim / CI
.agents/skills/growth-guards/scripts/todo-ban
.agents/skills/growth-guards/scripts/byte-ceiling            # staged additions
.agents/skills/growth-guards/scripts/byte-ceiling --base origin/main   # CI on a PR
.agents/skills/growth-guards/scripts/suppression-ban
```

## todo-ban

Flat ban on work markers in first-party tracked files — the words TODO,
FIXME, HACK, XXX in comment-marker shapes. No baseline: consumer repos are
at or near zero, so the count starts frozen at nothing.

A marker word counts only in marker shapes, so prose that quotes or names
a marker does not fire:

- the word at line start, after whitespace, or after a comment leader,
  immediately followed by `:` or `(` — the classic annotated forms
  (`MARKER: fix this`, `MARKER(owner): fix this`);
- the bare word directly after a comment leader (only whitespace between),
  followed by whitespace or end of line.

Comment leaders: `//`, `#`, `;`, `/*`, `<!--`. A marker preceded by a
backtick, a quote, or joined text (documentation quoting the word, a regex
listing the words, `\n` inside a string literal) matches neither shape.
Matching is case-sensitive — lowercase uses of the words are prose.

Remediation: do the work now, or move it to the tracker and delete the
marker. Vendored/generated trees go in the excludes list with a reason.

## byte-ceiling

Newly added tracked files over the ceiling (default 200 KB, KB = 1024
bytes) fail. Growth-oriented like size-ratchet: legacy files already in
history are not gated by the default modes, so adoption needs no cleanup
first.

- `--staged` (default) — files added in the staged diff (pre-commit).
- `--base REF` — files added since the merge-base with REF (CI on a PR).
- `--all` — every tracked file (audits; pair with excludes rows for known
  legacy assets).

Sizes are object sizes (`git cat-file -s` of the added blob): the bytes
that actually enter history, independent of worktree state. Rename
detection is pinned on, so moving an existing large file is not an
addition; a copy is one (it duplicates the bytes in the tree). Symlinks and
submodule gitlinks are not sized content.

Exempt built-in (exact basename): `Cargo.lock`, `package-lock.json`,
`npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`,
`bun.lockb`, `flake.lock`, `poetry.lock`, `uv.lock`, `Pipfile.lock`,
`Gemfile.lock`, `composer.lock`, `go.sum`, `gradle.lockfile`,
`packages.lock.json`, `Package.resolved`. Declared asset trees go in the
excludes list with a reason.

## suppression-ban

Two gates, both scanned language-scoped by pathspec (so docs and scripts
that quote a pragma never fire):

**Blanket suppressions fail flat** — the pragmas that turn a linter off
wholesale:

| Language | Pathspec | Banned shape |
|---|---|---|
| Rust | `*.rs` | module/crate-wide inner attribute `#![allow(...)]` at line start |
| Python | `*.py` | file-level `# ruff: noqa` / `# flake8: noqa` (own-line, with or without codes) |
| JS/TS | `*.js *.jsx *.ts *.tsx *.mjs *.cjs *.mts *.cts *.vue *.svelte` | bare block `/* eslint-disable */` with no rules named |
| Go | `*.go` | `//nolint` with nothing after it, or `//nolint:all` |

A per-line suppression that names its lint and states its reason stays
legal (`// eslint-disable-next-line rule -- why`, `# noqa: E501`,
`//nolint:gosec // why`, a per-item rust attribute).

**Bare-allow ratchet (Rust)** — reasonless `#[allow(dead_code)]` /
`#[allow(unused…)]` attributes are counted per file (matching lines).
An attribute carrying `reason = "..."` does not count — stating the reason
is the legal form. Repos with legacy counts freeze them in a tighten-only
baseline: new bare allows, growth past a row, and a baseline looser than
reality all fail. `--update` lowers/removes rows to current reality and
re-checks; it never adds a row and never raises a number — deliberate
growth is a hand-edit of the row, visible in review.

### Seeding a first baseline

`--update` never adds rows, so the first baseline is created explicitly:
run the check and turn each reported `new bare allow` line (path and
count) into a `path<TAB>count` row, `LC_ALL=C` sorted. The initial freeze
being a hand-authored, reviewed diff is the point.

## commit-msg

Conventional-commit gate over one message, shaped for the git
`commit-msg` hook (`commit-msg FILE`, or stdin when FILE is absent/`-`).
The header — the first non-blank, non-comment line — must match:

```
type(scope)!: subject        # scope and '!' optional
```

- Types: `GROWTH_GUARDS_COMMIT_TYPES` (default
  `build chore ci docs feat fix perf refactor revert style test`).
- Scope class: `[#A-Za-z0-9 _.,/-]+` — uppercase issue keys
  (`fix(ABC-123): ...`) and issue numbers (`fix(#123): ...`) pass.
- Git-generated messages pass unchanged: headers starting `Merge `,
  `Revert `, `Reapply `, `fixup! `, `squash! `, `amend! `.

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `GROWTH_GUARDS_CHECKS` | `todo-ban byte-ceiling suppression-ban` | Batch check list. |
| `GROWTH_GUARDS_TODO_EXCLUDES` | `tools/todo-ban-excludes` | todo-ban exclusion list. |
| `GROWTH_GUARDS_BYTE_CEILING_KB` | `200` | Ceiling in KB. |
| `GROWTH_GUARDS_BYTE_EXCLUDES` | `tools/byte-ceiling-excludes` | byte-ceiling exclusion list. |
| `GROWTH_GUARDS_SUPPRESSION_EXCLUDES` | `tools/suppression-ban-excludes` | suppression-ban exclusion list. |
| `GROWTH_GUARDS_SUPPRESSION_BASELINE` | `tools/suppression-baseline.tsv` | Bare-allow baseline. |
| `GROWTH_GUARDS_COMMIT_TYPES` | `build chore ci docs feat fix perf refactor revert style test` | Accepted types. |

Each key resolves environment > `.env.local` > `.vstack/settings.toml` >
committed `vstack.settings.toml` (flat `KEY = "value"` under `[env]`) >
`.env` > default (env files use `KEY=value` or `export KEY=value`; parsed,
never sourced). Per-check flags (`--excludes`, `--baseline`) override
every source for the paths. All relative paths are repo-root-relative; the
scripts `cd` to `git rev-parse --show-toplevel` before resolving anything.

```toml
[env]
GROWTH_GUARDS_BYTE_CEILING_KB = "500"
GROWTH_GUARDS_CHECKS = "todo-ban suppression-ban"
```

**Excludes format** (all three lists): `pattern<TAB>reason` per line —
shell glob matched against the full repo-relative path (`*` crosses `/`);
blank lines and `#` comments ignored; a pattern without a reason is a
config error. **Baseline format**: `path<TAB>count`, `LC_ALL=C` sorted,
unique paths, positive counts; malformed, unsorted, or duplicated rows are
config errors (exit 2), never repaired silently.

## Requirements

`git`, `awk`, and the usual POSIX userland. Bash 3.2 compatible (macOS
system bash).
