# growth-guards — development notes

Internals, design, and maintenance for the growth-guards skill. Consumer
docs live in README.md.

## Structure

- `scripts/growth-guards` — batch dispatcher and single-check router
- `scripts/todo-ban`, `scripts/byte-ceiling`, `scripts/suppression-ban`,
  `scripts/conflict-markers`, `scripts/commit-msg` — the five checks, each a
  standalone executable
- `scripts/pre-commit` — the chain the git `pre-commit` shim runs
- `scripts/install-git-hooks` — hook installer, remover, and `--check` verdict
- `scripts/lib/common.sh`, `scripts/lib/settings.sh` — shared helpers and
  layered settings resolution
- `vstack.settings.toml.example` — settings template for consumers
- `SKILL.md` — agent-facing skill definition
- `README.md` — consumer documentation
- `tests/` — run any file directly; each is self-contained

`bash tests/*.sh` is the lane `tools/validate-changed` derives for a change
under this skill.

## Design

One idiom throughout — language-agnostic where possible, tighten-only
baselines only where legacy counts exist, every failure carries its
remediation, every exclusion carries its reason — and one exit contract:
`0` clean, `1` violations, `2` usage/config/collection error. A measurement
that fails (unreadable file, a git/grep execution failure) is a loud exit 2,
never a silent pass. Scans read INDEX content (`git grep --cached` / staged
blobs) so the gate judges what is being committed, and a sparse checkout
cannot hide a tracked file from it.

## Git hook install contract

The installer writes three files into the repository's `.git/hooks` (never
`core.hooksPath`, which redirects the whole directory and would disable the
repository's existing hooks; where a repo already sets it, the install is a
reported skip and only removal still runs):

| File | Content |
|---|---|
| `vstack-guards` | Helper the installer owns outright and rewrites on every run. |
| `pre-commit` | One marked line delegating to the helper — created, or inserted after the shebang of an existing hook. |
| `commit-msg` | Same, passing git's message file through. |

The line goes FIRST, not last: hook content ending in an explicit `exit`
would leave an appended guard unreachable. Ours runs, blocks on any nonzero,
and then falls through to whatever the hook already did — whose own exit
status still decides.

Repeat runs are no-ops, and repairs. A hook counts as current only when it
carries the EXACT delegating line on a line of its own — a line that was
commented out, truncated, or left behind by an older version is rewritten,
not trusted — and a hook whose executable bit was cleared gets it back,
because git silently ignores a hook it cannot execute. An existing
`pre-commit`/`commit-msg` keeps its content and its own exit status; a hook
that is symlinked, deliberately disabled (not executable), or whose shebang
names an interpreter that is not a POSIX-compatible shell is left alone
entirely (reported, and the install exits 1). A file at the helper path that
this installer did not write is never overwritten. A bare repository is
refused — there is no work tree to guard.

Linked worktrees share the install, since git resolves their hooks to the
main checkout's hooks directory. The same sharing governs removal: while any
work tree on that hooks directory still has a SEPARATE install of the skill,
`--uninstall` keeps the shims, retargets the helper at that surviving
install, and says so. Separate is decided by physical path — a worktree
whose skills directory links back into the checkout being uninstalled from
is the same install, and it is going away.

`--uninstall` drops the helper and our marked line from each hook, deleting
a hook file this installer created outright and leaving every other line of
a consumer's own hook untouched. It runs even where `core.hooksPath` is set
— shims left in `.git/hooks` come back to life the moment that setting goes
away. A delegating line it may not edit (a symlinked hook) keeps the helper
in place and fails the removal rather than stranding a hook with no guard to
reach. `vstack remove growth-guards` refuses the removal if that cleanup
fails, so removing the skill never leaves hooks that block every commit.

`--check` is the read-only counterpart: it writes nothing — not even the
hooks directory — and answers whether the shims are armed. `0`: the helper
and both hooks pass the same predicate an install trusts (regular file, our
marker or exact line at its position, POSIX-sh shebang, executable). `1`:
some shim is drifted or absent, or every shim is intact but a
`core.hooksPath` redirects git away from them — armed-but-dormant, reported
with its own wording and remedy, and still `1` because no commit runs a
guard right now. `2`: the question could not be answered (an unreadable
hooks directory, a hook file that cannot be read); failure to measure is
never a pass, and definitive drift outranks an unmeasured component. The
one stdout line carries every component finding, and `vstack check` folds
it in for projects with the skill installed.

## The pre-commit chain

`scripts/pre-commit` judges ONE commit snapshot — staged content, and
tracked configuration read from the index, so an unstaged edit cannot switch
a check off for content the commit keeps. It runs `size-ratchet --staged`
and `preflight --staged` when the committing work tree or this install
carries those skills — the work tree's copy wins, so a shim exec'ing a shared
install in another checkout still gates on this tree's own copies (a
repository's first commit skips preflight with a note — nothing to diff
against; a size-ratchet that rejects `--staged` in its own first-line parser
diagnostic is a repo-local replacement — stated skip, that repo's own wiring
owns the gate — while any other failure blocks as a guard that could not
run), then the `growth-guards` batch over the staged content, then the
repo-local entry named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL`. Every step runs
before the verdict, so one attempt reports every blocker.

The shims fail closed on `2` for a guard that could not run — an uninstalled
script, a missing helper, a missing repo-local entry — naming what is
missing.

## todo-ban marker shapes

No baseline: consumer repos are at or near zero, so the count starts frozen
at nothing. A marker word counts only in marker shapes:

- the word at line start, after whitespace, or after a comment leader,
  immediately followed by `:` or `(` — the classic annotated forms
  (`MARKER: fix this`, `MARKER(owner): fix this`);
- the bare word directly after a comment leader (only whitespace between),
  followed by whitespace or end of line.

Comment leaders: `//`, `#`, `;`, `/*`, `<!--`. A marker preceded by a
backtick, a quote, or joined text (documentation quoting the word, a regex
listing the words, `\n` inside a string literal) matches neither shape.
Matching is case-sensitive — lowercase uses of the words are prose.

## byte-ceiling sizing

Sizes are object sizes (`git cat-file -s` of the added blob): the bytes that
actually enter history, independent of worktree state. Rename detection is
pinned on, so moving an existing large file is not an addition; a copy is
one (it duplicates the bytes in the tree). Symlinks and submodule gitlinks
are not sized content.

Exempt built-in (exact basename): `Cargo.lock`, `package-lock.json`,
`npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`,
`bun.lockb`, `flake.lock`, `poetry.lock`, `uv.lock`, `Pipfile.lock`,
`Gemfile.lock`, `composer.lock`, `go.sum`, `gradle.lockfile`,
`packages.lock.json`, `Package.resolved`.

## suppression-ban patterns

Blanket suppressions are scanned language-scoped by pathspec, so docs and
scripts that quote a pragma never fire:

| Language | Pathspec | Banned shape |
|---|---|---|
| Rust | `*.rs` | module/crate-wide inner attribute `#![allow(...)]` at line start |
| Python | `*.py` | file-level `# ruff: noqa` / `# flake8: noqa` (own-line, with or without codes) |
| JS/TS | `*.js *.jsx *.ts *.tsx *.mjs *.cjs *.mts *.cts *.vue *.svelte` | bare block `/* eslint-disable */` with no rules named |
| Go | `*.go` | `//nolint` with nothing after it, or `//nolint:all` |

The bare-allow ratchet counts matching lines per file; an attribute carrying
`reason = "..."` does not count — stating the reason is the legal form.
`--update` never adds a row, so the first baseline is hand-authored from the
reported `new bare allow` lines: the initial freeze being a hand-authored,
reviewed diff is the point.

## Settings sources

Env files use `KEY=value` or `export KEY=value`; they are parsed, never
sourced. Only an ABSENT source is skipped: a source that exists but is
unusable — unreadable, a directory, FIFO, socket or device, or a symlink
that does not resolve — is a config error (exit 2), never a fall-through to
the next layer. `GROWTH_GUARDS_SETTINGS_FILE=/dev/null` selects no settings
source at all — `.env.local`, the settings file and `.env` are all skipped —
leaving explicit environment variables and the built-in defaults. The
scripts `cd` to `git rev-parse --show-toplevel` before resolving anything,
so all relative paths are repo-root-relative.

**Excludes format** (all four lists): `pattern<TAB>reason` per line — shell
glob matched against the full repo-relative path (`*` crosses `/`); blank
lines and `#` comments ignored; a pattern without a reason is a config
error. **Baseline format**: `path<TAB>count`, `LC_ALL=C` sorted, unique
paths, positive counts; malformed, unsorted, or duplicated rows are config
errors (exit 2), never repaired silently.
