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
- `scripts/lib/hook-check.sh` — the read-only verdict `install-git-hooks
  --check` returns over the shims this installer writes
- `scripts/lib/hooks-path.sh` — where git reads hooks from, and whether
  that is the directory this installer writes
- `scripts/lib/skill-roots.sh` — the one definition of the skills roots
  every search here uses, including the copy baked into the helper
- `kendex.settings.toml.example` — settings template for consumers
- `SKILL.md` — agent-facing skill definition
- `README.md` — consumer documentation
- `CHECKS.md` — what each check bans, and how it is scoped
- `tests/` — run any file directly; every suite sources the harness first
- `tests/lib/install-hooks.bash` — the consumer-shaped fixture repository
  and installer invocations the four `install-git-hooks` suites share
- `tests/lib/harness.bash` — the scratch root a suite owns, a `TMPDIR`
  inside it, and git-config isolation; sourced, so the name stays outside
  the `tests/*.sh` glob runners execute

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
repository's existing hooks; where a repo already sets it — to any value,
its own hooks directory included — the install is a reported skip, while
removal and `--check` still run):

| File | Content |
|---|---|
| `kendex-guards` | Helper the installer owns outright and rewrites on every run. |
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
main checkout's hooks directory. The same sharing governs removal, and it
makes arming repository-level: one hooks directory, one set of shims, shared
by every work tree and every nested project. `--uninstall` disarms the
repository. It does not ask whether another work tree or another project
still wants the shims — that question was five rounds of wrong answers, the
last of them a repository two projects could never disarm at all. Re-arming
is one `install-git-hooks` run from whichever project still wants it.

`--uninstall` drops the helper and our marked line from each hook, deleting
a hook file this installer created outright and leaving every other line of
a consumer's own hook untouched. It runs even where `core.hooksPath` is set
— shims left in `.git/hooks` come back to life the moment that setting goes
away. A delegating line it may not edit (a symlinked hook) keeps the helper
in place and fails the removal rather than stranding a hook with no guard to
reach.

Nothing runs this installer on a package lifecycle event today: `kendex guard
install`, `kendex guard uninstall` and `kendex guard check` are the verbs
that invoke it, and
disarming before removing the skill is the caller's to do — shims whose
scripts are gone block every commit. Wiring `kendex add` / `refresh` /
`remove` to it arrives with the repo-effects declaration (KEN-663 part 2).

`--check` is the read-only counterpart: it writes nothing — not even the
hooks directory — and answers whether the shims are armed. `0`: the helper
and both hooks pass the same predicate an install trusts (regular file, our
marker or exact line at its position, POSIX-sh shebang, executable). `1`:
some shim is drifted or absent, or `core.hooksPath` is set and empty, which
switches git hooks off outright. `2`: the question could not be answered (an
unreadable hooks directory, a hook file that cannot be read); failure to
measure is never a pass, and definitive drift outranks an unmeasured
component. The one stdout line carries every component finding, and `kendex check` reads the hook files natively instead of running this.

The helper is compared BYTE FOR BYTE against what this installer generates.
The marker inside it is only a comment, and `--check` writes nothing, so it
does not get to assume the installer has just refreshed the copy in front of
it; `helper_body` is the single definition both the writer and the verifier
use. The INTERPRETER is identified by full path against a short trusted list
(`/bin` and `/usr/bin` shells), because an executable named `sh` anywhere can
be a copy of `/bin/true`, and git then runs it and ignores the hook body
entirely. An `env` shebang resolves through PATH, so it is unverifiable
rather than armed, and a listed path this host does not have is unverifiable
too — git cannot exec such a hook at all. An interpreter OPTION is refused
for the same reason: `#!/bin/sh` handed the syntax-check flag reads the
guard line and executes none of it, exiting 0 for everything. The shared
shebang check stays permissive because a repo's own hooks may legitimately
carry either; a hook this tool vouches for may not.

Under `core.hooksPath` there is no verdict. A configured hooks path is
outside this verifier's contract: it reads `.git/hooks` and nothing else,
whatever the value resolves to — that directory under another spelling
included, because resolving spellings is the question this package stopped
asking. So `--check` answers `2` naming the value, the directory it does
read, and the unset that arms; it does not claim git was sent anywhere,
because it did not measure that. Grading the configured directory meant
deciding whether foreign shell text reaches our entry point when git runs
it — reachability, which needs a shell parser, and which answered `armed`
about a repository that gated nothing every time somebody wrote a hook
nobody had thought of. A `core.hooksPath` set and EMPTY is the exception,
and only because it needs no reading: it switches git hooks off, so it is
`1` with the unset as its remedy.

That remedy is data, not a command. `docs/ARCHITECTURE.md` rules it:
recovery instructions present their parameters as data, never a pasteable
command line. `hooks_path_origins` prints three things — that
`core.hooksPath` is set, git's own report of where from (`git config
--show-origin --show-scope --get-all core.hooksPath`, unedited), and one
sentence naming no path and no command: clear the setting at its source,
then run `kendex guard install`. Both modes print the same block, on
stderr, so `--check` keeps its single stdout line.

Composing a command instead was wrong three times. Unsetting the local file
misses a value that lives elsewhere. Reading the scope and unsetting there
still has to be right about `--unset-all`, about a second file the winning
value shadows, and about `include.path`, which pulls the key in from a file
git reports under the INCLUDING scope with its own path — so a scoped
`--unset` edits `.git/config` and leaves the included file setting it. Each
was this package predicting what a person's configuration would do to a
command it wrote for them.

Nothing here asserts what an origin is, either. git answers `command line:`
for a value carried in the environment or on the command line, where there
is no file to clear at all, and that answer goes through as git wrote it. A
report git will not produce is stated as missing rather than stood in for,
and the verdict is the same either way.

The cost is one arming: a directory hand-wired to these scripts really does
gate, and `--check` says `2` about it rather than `0`. That is why the
answer is not `1` either — the install's stand-down prints no hand-wiring
recipe for the same reason, since prescribing a shape this tool cannot
verify leaves a repository permanently unable to say whether it is gated.

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
