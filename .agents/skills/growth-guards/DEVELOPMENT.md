# growth-guards — development notes

Internals, design, and maintenance for the growth-guards skill. Consumer
docs live in README.md.

## Structure

- `scripts/growth-guards` — batch dispatcher and single-check router
- `scripts/todo-ban`, `scripts/byte-ceiling`, `scripts/suppression-ban`,
  `scripts/conflict-markers`, `scripts/changelog-entries`, `scripts/prose`,
  `scripts/commit-msg` — the seven checks, each a standalone executable
- `scripts/pre-commit` — the chain the git `pre-commit` shim runs
- `scripts/install-git-hooks` — hook installer, remover, and `--check` verdict
- `scripts/lib/common.sh`, `scripts/lib/settings.sh` — shared helpers and
  layered settings resolution
- `scripts/lib/configured-paths.sh` — the glob-list concept for the lanes
  scoped by one: the configured list, the excludes list read from the index,
  the one matcher both answer through, the walk over the index records, and
  what may be measured at a matched path
- `scripts/lib/commit-header.sh`, `scripts/lib/changelog-grammar.sh` — what
  a commit header and a changelog ARE to this family: the two changelog
  scopes both lanes resolve from, and the grammars each is judged by, kept
  apart from the scans that run them
- `scripts/lib/changelog-record-scope.sh` — the record half of the
  `changelog-entries` judge: one tracked file against HEAD's copy, kept apart
  from the fragment-tree walk it shares nothing with but a verdict
- `scripts/lib/changelog-collate.sh` — the write half, run by
  `changelog-entries --collate` on the verdict those two just reached: it
  folds the accepted fragments into the record and deletes them, and decides
  nothing about either
- `scripts/lib/atomic-install.sh` — how the two writing lanes replace a file
  they own: a rename inside the destination's own directory, so a policy file
  is never left truncated. Sourced by `suppression-ban` and
  `changelog-entries` alone; its staging file is declared and removed in
  `common.sh`, where the reset reaches every guard and the one exit handler
  lives
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
- `tests/terminal-paths.test.sh` — the cases that only exist at a tty, and
  the pins for the pty probe itself
- `tests/lib/install-hooks.bash` — the consumer-shaped fixture repository
  and installer invocations the four `install-git-hooks` suites share
- `tests/lib/pty.bash` — running a case at a terminal, and the rules such a
  probe follows; sourced by `terminal-paths.test.sh` alone
- `tests/lib/harness.bash` — the scratch root a suite owns, a `TMPDIR`
  inside it, and git-config isolation; sourced, so the name stays outside
  the `tests/*.sh` glob runners execute

`bash tests/*.sh` is the lane `tools/validate-changed` derives for a change
under this skill.

## Probing a terminal-only code path

A suite run with stdin off a terminal cannot reach a branch that only exists
at a tty, so a probe written headless measures nothing there. `mv` prompts
before replacing a destination that denies write ONLY at a tty, which makes
plain `mv` and `mv -f` indistinguishable to such a run — how a prompting
`gg_install_file` shipped green. Where a suite's own stdin IS a terminal the
same branch is live and unguarded: `index-reads.test.sh` installs onto a 0444
destination, so with the `-f` reverted such a run reaches the prompt and
waits for a person.

`gg_pty_run CAP SCRIPT_FILE`, in `tests/lib/pty.bash`, runs a bash script file
with fds 0, 1 and 2 on a pseudo-terminal. It picks the `script` grammar from
`uname` — Darwin takes the BSD form, everything else the util-linux one — and
a host whose `script` answers neither has no working spawner here, which is a
RED naming the spawner as its cause rather than a skip: a case that cannot
reach the terminal branch is not covering it. What a call sets is documented
above the function; the states are enumerated there and nowhere else.

Two rules hold, and a probe that drops either is worse than no probe:

- **Stdin redirected.** The spawner reads `/dev/null`, so a prompt is
  answered by EOF the moment it is written and the session returns instead of
  waiting for a person who is not there. What it returns differs by platform,
  which is why a case asserts on the destination.
- **A time cap, held on both sides.** After `CAP` seconds the caller kills the
  session's process group, the spawner's after it: `script` puts the session in
  a group of its own, so killing the spawner alone leaves the stuck child
  behind. The session holds the same deadline over ITSELF a few seconds later,
  because a suite killed mid-run takes the caller's poll loop with it and
  leaves a setsid'd session nothing can reach. A probe that HANGS yields no
  measurement at all, so a mutation run scores it as not killed and prints a
  silent miss rather than a wedge.

Three things to assert, and `terminal-paths.test.sh` is the worked example —
its `pty_call` is the wrapper shape a new case copies:

- **The effect the branch has, not the spawner's status.** Whether the
  destination was replaced is what the branch does; a status is what one `mv`
  on one host chose to say about it. `GG_PTY_STATE = ok` is the separate
  claim that the probe ran rather than wedged.
- **Positive evidence that the code under test was entered**, paired with
  every negative. An unreplaced destination is also what a session that never
  got there leaves behind, which is why the mutant control echoes a marker
  before the call it measures and requires it back.
- **The premise, inside the session.** A destination that denies write is
  what makes `mv` prompt, and at euid 0 mode `0444` is not enforced — so
  without that check a root run covers nothing and says nothing.

Every path written into the session goes through `%q`. They come from
`TMPDIR` and from the caller, so an unquoted one lands in a shell script as
syntax rather than as a path. The session also exports `LC_ALL=C`, because a
case matching a tool's own words is matching a string that gets translated.

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
`pre-commit`/`commit-msg` keeps its content, its shebang and its own exit
status; a hook that is symlinked, deliberately disabled (not executable),
whose shebang names an interpreter that is not a POSIX-compatible shell, or
whose shebang names a shell outside the trusted full paths under `/bin` and
`/usr/bin`, is left alone entirely (reported, and the install exits 1). That
trusted-path rule holds at install exactly as it does at `--check`, whoever
wrote the hook. A file at the helper path that this installer did not write
is never overwritten. A bare repository is refused — there is no work tree to
guard.

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

kendex runs this installer through the `repo-effects` declaration in
`SKILL.md`: `kendex add --allow-repo-effects`, or a yes at the prompt in the
terminal or in the app, runs it after the files land. Every CLI verb that
drops the package — `kendex remove`, an `apply` or `refresh` whose plan takes
it away, `marketplace unsubscribe --remove-packages` — runs `--uninstall`
while the scripts are still on disk, because shims whose scripts are gone
block every commit.
`kendex guard install`, `kendex guard uninstall` and `kendex guard check`
invoke it directly. So does `kendex check`, but only where
`.git/hooks/kendex-guards` is already there: git clones no hooks, so that
file is a local act, and without it nothing here is run.

`--check` is the read-only counterpart: it writes nothing — not even the
hooks directory — and answers whether the shims are armed. `0`: the helper
and both hooks pass the same predicate an install trusts (regular file, our
marker or exact line at its position, POSIX-sh shebang, executable). `1`:
some shim is drifted or absent, or `core.hooksPath` is set and empty, which
switches git hooks off outright. `2`: the question could not be answered (an
unreadable hooks directory, a hook file that cannot be read); failure to
measure is never a pass, and definitive drift outranks an unmeasured
component. The one stdout line carries every component finding, and it is what `kendex check` relays
where there is something to report; a clean result folds into kendex's own all-clear instead.

The helper's PROGRAM is compared byte for byte against what this installer
generates. The marker inside it is only a comment, and `--check` writes
nothing, so it does not get to assume the installer has just refreshed the
copy in front of it. Its generated HEAD is held to the head this checkout
would bake with the per-checkout value blanked (`helper_head_shape`): fixed
bytes either side of one value, so everything but that value is exact.
`helper_body` writes both halves, so a writer and a verifier cannot drift
apart.

Only `SCRIPT_DIR` is excusable, and only twice over: the value has to be one
`gg_shell_quote` would have written, proved by unescaping and re-escaping it,
and it has to name this same project's scripts directory in another checkout
of this repository. A linked worktree shares the arming checkout's hooks
directory and stands at the same place in its own checkout, so its helper is
recognized. A second project in one repository stands somewhere else in the
same checkout, so it is refused rather than relaying under the first
project's consent. `project_rel` and `skill_roots` are compared exactly.

The INTERPRETER is identified by full path against a short trusted list
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
--show-origin --show-scope --get-all core.hooksPath`, line for line), and
one sentence naming no path and no command: clear the setting at its source,
then run `kendex guard install`. Both modes print the same block, on
stderr, so `--check` keeps its single stdout line.

No command is composed for anyone to run. A composed one has to be right
about `--unset-all`, about a second file the winning value shadows, and about
`include.path`, which pulls the key in from a file git reports under the
INCLUDING scope with its own path, so a scoped `--unset` edits `.git/config`
and leaves the included file setting it. That is this package predicting what
a person's configuration would do to a command it wrote for them.

Nothing here asserts what an origin is, either. git answers `command line:`
for a value carried in the environment or on the command line, where there
is no file to clear at all, and that answer goes through as git said it —
rendered by `%q`, the way the summary renders the value, because a report
quoting somebody's configuration must not hand that configuration a
terminal. One line in, one line out; nothing dropped or reordered. A
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

Comment leaders: `//`, `#`, `;`, `/*`, `<!--`. A marker IMMEDIATELY preceded
by a backtick, a quote, or joined text (documentation quoting the word, a
regex listing the words, `\n` inside a string literal) matches neither
shape; a space between them exempts nothing.
Matching is case-sensitive — lowercase uses of the words are prose.

The shapes are the same in both scopes; only the lines they are matched
against differ. `--staged` collects the change set the way byte-ceiling's
staged lane does (`--raw`, additions/modifications/type changes, renames at
exact content), dropping symlinks and submodule gitlinks by destination
mode because they carry no lines to read. A `git grep --cached` over THOSE
PATHS then names the ones whose staged content carries a marker at all,
chunked so a large change set stays inside ARG_MAX. Scoping the scan is
what keeps the cost proportional to the commit and keeps a blob the commit
never touched — corrupt, or not yet fetched into a blobless clone — out of
the verdict. Only the named paths reach the per-path `-U0` diff that reads
their added lines, one file per invocation, so no patch header is ever
parsed for a path and a path git would have had to quote cannot be misread.
Membership in that list is a `case` over a newline-delimited set, not a loop
per staged path: the loop cost O(staged x carriers) and overtook the code it
replaced on a marker-dense tree, and Bash 3.2 has no associative array.

**Content decides what is scannable. An attribute never does.** That rule
settles both halves of the commit lane. Diff configuration is pinned
(`--no-ext-diff`, `--no-textconv`, `--no-color`, `--text`): a textconv filter
would otherwise hand the lane content the commit does not carry, and a
committed `.gitattributes` rule marking a path non-diffable would leave the
diff with no hunks at all. The pre-filter carries no `-I` for the same
reason — with it, one attributes line would hide a whole extension from the
fast path, where a skipped file reads as clean. What forcing text lets
through is then judged on content: each named path's index blob is sniffed
for a NUL in its first block, git's own test, and a genuinely binary blob is
NAMED as unmeasured rather than decoded. So a text file under a `-diff` rule
is still read, while an asset whose bytes happen to spell a marker cannot
block a commit with a record of raw bytes, and cannot ride inside a clean
verdict either. Sniffing only the named paths keeps that at one `cat-file`
per marker-carrying file, not one per staged file.

The index-wide scans give the same answer, in the shared
`gg_content_carriers` every one of them lists through: it forces text, drops
the excluded paths, sniffs each named blob, and hands back the paths a scan
may measure. `gg_grep_lane` details the hits per carrier, and its detail
scan forces text too — the two move TOGETHER, since text on the listing over
`-I` on the detail scan would name a file the detail scan then finds nothing
in, which the lane's own invariant turns into a spurious exit 2.
`conflict-markers`, `suppression-ban`'s seven blanket lanes and its bare-allow
count, and `prose` inherit the rule from the helper; `prose` reaches it having
already made the same judgement in its own walk. Every skip the helper makes
is named and counted in `GG_WALK_SKIPPED`, which each check's verdict line
carries as `N matched path(s) not measured`. The tally is of distinct PATHS:
a check running several lanes over overlapping pathspecs meets the same
unreadable blob once per lane, and `gg_note_skip` names and counts it once.

## byte-ceiling sizing

Sizes are object sizes (`git cat-file -s` of the recorded blob): the bytes
that actually enter history, independent of worktree state. Rename detection
is pinned on, so moving an existing large file is judged in neither default
mode; a copy is an addition (it duplicates the bytes in the tree). Symlinks
and submodule gitlinks are not sized content. The staged lane reads
additions, modifications and type changes, and holds rename detection to
exact content so a file that moved AND grew is judged as the addition it
is; `--base` reads additions alone, because a PR's diff against its merge
base has no pre-commit moment to answer at.

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
source at all — `.env.local` and the settings files are both skipped —
leaving explicit environment variables and the built-in defaults. The
scripts `cd` to `git rev-parse --show-toplevel` before resolving anything,
so all relative paths are repo-root-relative.

**Excludes format** (all four lists): `pattern<TAB>reason` per line — shell
glob matched against the full repo-relative path (`*` crosses `/`); blank
lines and `#` comments ignored; a pattern without a reason is a config
error. **Baseline format**: `path<TAB>count`, `LC_ALL=C` sorted, unique
paths, positive counts; malformed, unsorted, or duplicated rows are config
errors (exit 2), never repaired silently. **Path-globs format**
(`GROWTH_GUARDS_CHANGELOG_PATHS`, `GROWTH_GUARDS_PROSE_PATHS`, both loaded
by `gg_load_path_globs`): one space-separated list of shell globs against
the full repo-relative path (`*` crosses `/`), REPLACING the built-in
default rather than extending it. An absolute pattern, one escaping the
repository, one leading with `-`, and an empty list are all config errors
(exit 2); a list matching no tracked file is a clean pass. The caller runs
under `set -f`, which the loader checks: without it the patterns expand
against the work tree instead of matching the index.
