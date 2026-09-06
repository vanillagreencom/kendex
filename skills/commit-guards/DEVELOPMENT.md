# commit-guards development

What a maintainer must not break. What each check fails: [CHECKS.md](CHECKS.md); consumer text: [README.md](README.md); every key: [SKILL.md](SKILL.md).

## One definition each

- `scripts/commit-guards` is the dispatcher; `STAGED_SCOPED_CHECKS` names the checks the commit batch hands `--staged`.
- `scripts/lib/common.sh` holds the shared helpers, the one exit handler, `gg_content_carriers` and `gg_grep_lane`.
- `scripts/lib/configured-paths.sh` holds a glob-list lane's list, excludes, matcher, index walk and `gg_note_skip`.
- `scripts/lib/staged-lines.sh` is the lines a commit adds to one path, off a pinned `-U0` diff.
- `scripts/lib/comment-text.sh` is the comment grammar per path and the `line<TAB>text` scanner; its limits are stated in CHECKS.md § comments and pinned by `tests/comments.test.sh`.
- `scripts/lib/commit-header.sh` and `changelog-grammar.sh` define what a commit header and a changelog fragment are; `commit-parent.sh` is the parent a commit will have, an amend read off `/proc/<pid>/cmdline`.
- `scripts/lib/helper-body.sh` is the exact bytes of `.git/hooks/kendex-guards` (`helper_body`, `helper_head_shape`, `gg_shell_quote`); `skill-roots.sh` is the one definition of the skills roots, including the copy baked into the helper; `hooks-path.sh` is where git reads hooks from.
- `scripts/lib/md-blocks.awk` is the one reading of a markdown file's blocks; `md-shapes.awk` the line-shape predicates it asks, always the first `-f` program of `md-format`, `md-reflow` and `md-refs`, never loaded alone; `md-refs.awk` what a file cites and defines; `md-slug.awk` a heading reduced to its GitHub anchor; `md-scope.sh` the three scopes the markdown lanes share.
- `tests/`: run any file directly; every suite sources `tests/lib/harness.bash` first (scratch root, `TMPDIR` inside it, git-config isolation). `tests/lib/install-hooks.bash` is the fixture repository the installer suites share; `tests/lib/pty.bash` is sourced by `tests/terminal-paths.test.sh` alone.

## Design

- Exit contract: `0` clean, `1` violations, `2` usage, config or collection error. A failed measurement is exit 2, never a pass.
- Scans read index content, so the gate judges what is committed and a sparse checkout hides nothing.
- Content decides what is scannable; an attribute never does. Listings force text (`--text`, no `-I`), diffs pin `--no-ext-diff --no-textconv --no-color --text`, and each named blob is sniffed for a NUL in its first block.
- `gg_content_carriers` lists the measurable carriers and `gg_grep_lane` details the hits; both force text and move together, since a file the listing names and the detail scan drops is a spurious exit 2.
- Every skip goes through `gg_note_skip` and is counted in `GG_WALK_SKIPPED` by distinct path; each verdict line carries `N matched path(s) not measured`.
- A check that refuses states what it refused, why, and the preferred remedy first, before any exemption path; every exclusion carries its reason; a tighten-only baseline exists only where legacy counts exist.
- A remedy is data, never a pasteable command line.

## Git hook install contract

The installer writes into `.git/hooks`, never `core.hooksPath`:

| File | Content |
|---|---|
| `kendex-guards` | Helper the installer owns and rewrites on every run. |
| `pre-commit` | One marked line delegating to the helper, created, or inserted after the shebang of an existing hook. |
| `commit-msg` | Same, passing git's message file through. |

- The delegating line goes first (hook content ending in `exit` would leave an appended line unreachable), blocks on any nonzero, and falls through to the hook's own content, whose exit status still decides.
- Repeat runs are no-ops and repairs: only the exact line on a line of its own is current; a cleared executable bit is restored.
- Left alone, reported, exit 1: a symlinked or non-executable hook; a shebang naming a non-POSIX-shell interpreter, an `env` lookup, an interpreter option, or a shell outside the trusted full paths under `/bin` and `/usr/bin`. A helper file this installer did not write is never overwritten. A bare repository is refused.
- `core.hooksPath` set to anything makes install a reported skip; removal and `--check` still run. `hooks_path_origins` prints the stand-down on stderr: git's `--show-origin --show-scope --get-all` lines verbatim through `%q`, and one sentence naming no path and no command.
- Linked worktrees share the install; arming and `--uninstall` are repository-level and ask no other work tree or project.
- `--uninstall` drops the helper and the marked line, deletes a hook file this installer created outright, leaves every other line, and runs under `core.hooksPath` too. A line it may not edit keeps the helper and fails the removal.
- `--check` writes nothing, not even the hooks directory. `0`: helper and both hooks pass the install predicate. `1`: a shim drifted or absent, or `core.hooksPath` set and empty. `2`: unmeasurable, or `core.hooksPath` naming a directory; the verifier reads `.git/hooks` only. Definitive drift outranks an unmeasured component. One stdout line carries every finding.
- The helper is compared byte for byte against `helper_body`, its head against `helper_head_shape` with the per-checkout value blanked. Only `SCRIPT_DIR` may differ, and only when it round-trips through `gg_shell_quote` and names this project's scripts directory in another checkout of this repository; `project_rel` and `skill_roots` compare exactly.
- `gg_install_file` in `scripts/lib/atomic-install.sh` replaces baselines, collated changelogs, and reflowed markdown by a rename inside the destination's directory. `common.sh` removes its staging file on exit.
- kendex runs the installer through the `repo-effects` declaration in `SKILL.md`; every verb that drops the package runs `--uninstall` while the scripts are still on disk; `kendex guard install`, `guard uninstall` and `guard check` call it directly; `kendex check` relays `--check` only where `.git/hooks/kendex-guards` exists.

## The pre-commit chain

`scripts/pre-commit` judges one commit snapshot: staged content, with tracked configuration read from the index. Order:

1. `doc-limits --staged` for document byte ceilings, from the committing work tree's copy first, then this install's; a stated skip where neither exists or the repo-local one rejects `--staged` in its first-line parser diagnostic.
2. `preflight --staged`, resolved the same way; a first commit skips it with a note.
3. `commit-guards all --staged`.
4. The repo-root-relative executable `COMMIT_GUARDS_PRE_COMMIT_LOCAL` names, when set.

Every step runs before the verdict; any other companion failure blocks. The shims fail closed on `2` for a guard that could not run, naming what is missing.

## The markdown lanes

- `md-blocks.awk` mode `check` prints md-format's violations, `reflow` the file in the format, `lines` the judged lines with blockquote prefix stripped, the HTML block lines apart, and each heading's text.
- md-refs runs the `lines` stream through `md-refs.awk`, then resolves in three passes: every selected file's references, the headings of every cited file read from the index whether or not in scope, then the verdict.
- Both programs are POSIX awk (no interval expressions, no gawk builtins) under `LC_ALL=C`; `mawk` and `gawk --posix` give the same records over the suites' fixtures.
- The reflow is the check's state machine printing instead of complaining, so a reflowed file passes md-format by construction; `tests/md-reflow.test.sh` proves it over the corpus and proves each rewrite is a fixed point.
- The batch passes `--staged` to both markdown checks. md-format selects changed documents; md-refs checks all configured documents against the index. `COMMIT_GUARDS_MD_SCOPE=all` makes unflagged checks unconditional.

## todo-ban marker shapes

Stated once, in CHECKS.md § todo-ban. At `--staged` the change set is collected as byte-ceiling's staged lane collects it (`--raw`, renames at exact content, symlinks and gitlinks dropped by destination mode), a `git grep --cached` over those paths names the carriers in chunks inside ARG_MAX, and only the named paths reach the per-path `-U0` diff. Membership is a `case` over a newline-delimited set: Bash 3.2 has no associative array.

## byte-ceiling sizing

Sizes are `git cat-file -s` of the diff's source and destination blobs. The source size is the tighten-only baseline when it already exceeds the ceiling. Rename detection is pinned on and held to exact content in the staged and base lanes.

## suppression-ban patterns

The pathspec table is in CHECKS.md § suppression-ban. The bare-allow count runs over `gg_content_carriers`, then one `git grep --cached -c` per surviving `*.rs` carrier; a count that never arrived is a collection error, never 0. A tracked `*.rs` path holding a tab or newline is a config error.

## Settings sources

`scripts/lib/settings.sh` resolves each key environment > `.env.local` > `.kendex/settings.toml` > committed `kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > default; `.env` is never read. Env files take `KEY=value` or `export KEY=value`, parsed, never sourced. Only an absent source is skipped; one that exists but is unusable (unreadable, a directory, FIFO, socket or device, a dangling symlink) is exit 2. `COMMIT_GUARDS_SETTINGS_FILE=/dev/null` selects no file source. Scripts `cd` to `git rev-parse --show-toplevel` first, so every relative path is repo-root-relative; a per-check flag overrides every source.

## Excludes format

The row format, the `!` carve and the `\!` escape are stated in `SKILL.md § Configuration`; all six excludes lists share it, and a bare `!` is a config error. A baseline is `path<TAB>count`, `LC_ALL=C` sorted, unique paths, positive counts; a malformed, unsorted or duplicated row is exit 2, never repaired. The path-glob lists (`COMMIT_GUARDS_CHANGELOG_PATHS`, `COMMIT_GUARDS_PROSE_PATHS`, `COMMIT_GUARDS_MD_PATHS`, `COMMIT_GUARDS_MD_REFS_PATHS`, `COMMIT_GUARDS_COMMENT_PATHS`) load through `gg_load_path_globs`: an absolute pattern, one escaping the repository, one leading with `-`, and an empty list are exit 2. The caller runs under `set -f`, which the loader checks; without it the patterns expand against the work tree.

## Probing a terminal-only code path

A headless suite cannot reach a branch that exists only at a tty (`mv` prompts before replacing a write-denied destination only there). `gg_pty_run CAP SCRIPT_FILE` in `tests/lib/pty.bash` runs a bash script with fds 0, 1 and 2 on a pseudo-terminal, picking the `script` grammar from `uname`; a host whose `script` answers neither form is a red naming the spawner, not a skip. Its states are enumerated above the function and nowhere else. `tests/terminal-paths.test.sh` is the worked example; its `pty_call` is the wrapper a new case copies.

- Stdin is `/dev/null`, so a prompt is answered by EOF.
- A time cap on both sides: after `CAP` seconds the caller kills the session's process group, then the spawner's; the session holds the same deadline over itself a few seconds later.
- Assert the effect the branch has, not the spawner's status; `GG_PTY_STATE = ok` is the separate claim that the probe ran.
- Pair every negative with positive evidence the code was entered: echo a marker before the call and require it back.
- Check the premise inside the session: mode `0444` is not enforced at euid 0.
- Every path written into the session goes through `%q`; the session exports `LC_ALL=C`.

## Commit change collection

`scripts/lib/commit-changes.sh::gg_commit_changes` owns the changed, written and product path sets. The changelog message gate and kendex's compile scheduling share these sets. Product paths use `COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS`. Rename sources and destinations both count as changed paths. The written set retains the changelog gate's content and file-mode rules.
