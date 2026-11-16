# commit-guards development

What a maintainer must not break. What each check fails: [CHECKS.md](CHECKS.md); consumer text: [README.md](README.md); every key: [SKILL.md](SKILL.md).

## One definition each

- `scripts/commit-guards` is the dispatcher; `STAGED_SCOPED_CHECKS` names the checks the commit batch hands `--staged`, and `--skip-unscoped` withholds `PUSH_WITHHELD_CHECKS`, which names the checks owned by commit or CI, independent of scope or Markdown settings.
- `scripts/lib/common.sh` holds the shared scan helpers, `gg_content_carriers` and `gg_grep_lane`. `scripts/lib/messages.sh` emits a stable key and value before the English explanation and owns the collection-error exit.
- `scripts/lib/configured-paths.sh` holds a glob-list lane's list, excludes, matcher, index walk and `gg_note_skip`.
- `scripts/lib/staged-lines.sh` is `gg_added_lines`, the lines the staged diff or a commit range adds to one path, off one pinned `-U0` diff.
- `scripts/lib/command-position.sh` remains available to older installed `block-worktree-refresh` hooks. The current hook uses the parsed CLI guard; its suite under `hooks/tests/` tests advisory behavior.
- `scripts/lib/comment-text.sh` is the comment grammar per path and the `line<TAB>text` scanner md-refs reads; its limits are stated in CHECKS.md § comments and pinned by `tests/comments.test.sh`.
- `scripts/lib/commit-header.sh` and `changelog-grammar.sh` define what a commit header and a changelog fragment are; `commit-parent.sh` is the parent a commit will have, an amend read off `/proc/<pid>/cmdline`.
- `scripts/lib/helper-body.sh` is the exact bytes of `.git/hooks/kendex-guards` (`helper_body`, `helper_head_shape`, `gg_shell_quote`), and with them `GG_LANES` and `gg_lane_verb`: the lanes this package owns and the verb each one gates, read by the installer's delegating line and by `--check`, and carried a third time inside the helper, which can source nothing; `skill-roots.sh` is the one definition of the skills roots, including the copy baked into the helper; `hooks-path.sh` is where git reads hooks from.
- `scripts/lib/md-blocks.awk` is the one reading of a markdown file's blocks; `md-shapes.awk` the line-shape predicates it asks, always the first `-f` program of `md-reflow`, `md-refs` and `md-type`, never loaded alone; `md-type.awk` md-type's readings of docs-writing's route table and section list and of a judged file's structure; `md-refs.awk` what a file cites and defines; `md-slug.awk` a heading reduced to its GitHub anchor; `md-scope.sh` the scopes the markdown lanes share, the staged and range scopes selecting by the lane's own rename policy.
- `tests/`: run any file directly; every suite sources `tests/lib/harness.bash` first (scratch root, `TMPDIR` inside it, git-config isolation). `tests/lib/install-hooks.bash` is the fixture repository the installer suites share; `tests/lib/pty.bash` is sourced by `tests/terminal-paths.test.sh` alone.

## Design

- Exit contract: `0` clean, `1` violations, `2` usage, config or collection error. A failed measurement is exit 2, never a pass.
- Scans read index content, so the gate judges what is committed and a sparse checkout hides nothing.
- Content decides what is scannable; an attribute never does. Listings force text (`--text`, no `-I`), diffs pin `--no-ext-diff --no-textconv --no-color --text`, and each named blob is sniffed for a NUL in its first block.
- `gg_content_carriers` lists the measurable carriers and `gg_grep_lane` details the hits; both force text and move together, since a file the listing names and the detail scan drops is a spurious exit 2.
- Every skip goes through `gg_note_skip` and is counted in `GG_WALK_SKIPPED` by distinct path. Each verdict includes that count in its stable record.
- A check that refuses states what it refused, why, and the preferred remedy first, before any exemption path; every exclusion carries its reason; a tighten-only baseline exists only where legacy counts exist.
- A remedy is data, never a pasteable command line.

## Git hook install contract

The installer writes into `.git/hooks`, never `core.hooksPath`:

| File | Content |
|---|---|
| `kendex-guards` | Helper the installer owns and rewrites on every run. |
| `pre-commit` | One marked line delegating to the helper, created, or inserted after the shebang of an existing hook. |
| `commit-msg` | Same, passing git's message file through. |
| `pre-push` | Same, passing the remote name and URL through; git's ref lines are staged in a file under a cleanup trap, handed to the lane, and handed on to the rest of the hook. |

- The delegating line goes first (hook content ending in `exit` would leave an appended line unreachable), blocks on any nonzero, and falls through to the hook's own content, whose exit status still decides. In `pre-push` it also stages git's ref lines in a temporary file, reads the lane from that file, and `exec`s the hook's own stdin onto it before falling through, since git sends those lines once and a ref-aware consumer hook below ours would otherwise read an empty stream and check nothing. The file is unlinked while the redirection holds it open; a staging file that cannot be made or filled blocks the push. `EXIT` and signal traps go on the moment it exists, so an interrupt during the batch — the slow part of a push — takes it with them, and come off again once it is unlinked, since the hook below that point is the consumer's and its traps are theirs.
- Repeat runs are no-ops and repairs: only the exact line on a line of its own is current; a cleared executable bit is restored.
- Left alone, reported, exit 1: a symlinked or non-executable hook; a shebang naming a non-POSIX-shell interpreter, an `env` lookup, an interpreter option, or a shell outside the trusted full paths under `/bin` and `/usr/bin`. A helper file this installer did not write is never overwritten. A bare repository is refused.
- `core.hooksPath` set to anything makes install a reported skip; removal and `--check` still run. `hooks_path_origins` prints the stand-down on stderr: git's `--show-origin --show-scope --get-all` lines verbatim through `%q`, and one sentence naming no path and no command. The setting is its owner's, so that sentence routes the decision to whoever set it; the installer never takes the setting over.
- A successful install prints setup notices on stderr without changing its verdict: `package-incomplete=<path>` for a present companion or the batch whose script is missing or not executable, which the chain names unrun at every commit, and `tool-missing=ruff,pyflakes` where the repository tracks Python files and neither tool is installed.
- Linked worktrees share one install, and a linked worktree never arms it: the helper names the scripts directory of the tree that armed it, which every session in the repository would then run where a tree carries no render of its own, and which goes away with that tree. Nothing a worktree can do arms the repository correctly, so the installer there writes nothing: `armed-by-main`, exit 0, where `check_hooks_dir` passes, and otherwise a `linked-worktree` warning naming the main checkout's owner and `unarmed-linked-worktree`, exit 1, since kendex records an arming after any exit 0. The stand-down does not apply where there is no main checkout — a bare repository with work trees added — and it stands behind the `core.hooksPath` skip, which writes nothing from anywhere. `--check` and `--uninstall` answer from any work tree, and `--check`'s re-arm remedy names the main checkout where the caller is not standing in it; all of them, and arming from the main checkout, are repository-level and ask no other work tree or project.
- A commit or push is judged by the scripts the committing tree carries. The helper also bakes `installed_scripts_rel`, the scripts directory relative to the top level of its own checkout (empty when it sits in no checkout of this repository), and runs `<top>/<installed_scripts_rel>/<lane>` for the committing tree when that file is executable, the rule `scripts/lib/siblings.sh` applies to the chain's companions. Where that copy is not the baked one, one stderr line names it: `kendex-guards: scripts=<path> (this tree)`. A tree with no render there runs the baked directory, then the rediscovery search. No version is compared: a main checkout that is behind cannot judge a newer tree, and a tree that is behind is judged by the rules it carries.
- `--uninstall` drops the helper and the marked line, deletes a hook file this installer created outright, leaves every other line, and runs under `core.hooksPath` too. A line it may not edit keeps the helper and fails the removal.
- `--check` writes nothing, not even the hooks directory. `0`: helper and all three hooks pass the install predicate. `1`: a shim drifted or absent, or `core.hooksPath` set and empty. `2`: unmeasurable, or `core.hooksPath` naming a directory; the verifier reads `.git/hooks` only. Definitive drift outranks an unmeasured component. The first stdout line carries the stable verdict and finding keys. English explanation follows. The CLI reads the `commit-guards git hooks:` prefix.
- `helper_stamp` versions the helper program with POSIX `cksum`, excluding baked paths and the stamp itself. An older or missing stamp is drift, `helper-outdated`, with `fix=` naming the installer to run from the main checkout. A current stamp still requires the byte comparison; it does not establish authenticity. `tests/install-git-hooks-check.test.sh` covers both verdicts and a disabled version check.
- The helper is compared byte for byte against `helper_body`, its head against `helper_head_shape` with `SCRIPT_DIR` and `INSTALLED_SCRIPTS_REL` blanked; each lifted value must round-trip through `gg_shell_quote`, and `project_rel` and `skill_roots` compare exactly. `SCRIPT_DIR` and `INSTALLED_SCRIPTS_REL` may differ only when they name this project's copy of the package in this repository: the same place in another checkout, or another of the project's skill roots (`GG_SKILL_ROOTS`) where the project stands at the same place in its checkout and the copy's `SKILL.md`, or `SKILL.md.disabled` where kendex switched the skill off, declares the same `name:` and its scripts directory carries the same `gg_scripts_sum` checksum, taken over each file's path and `cksum`. A pair the arming tree no longer matches is drift, `helper-moved`: this project's scripts directory is there but the recorded place holds none of this project's copies, or the baked directory is gone while the recorded place still holds one. The installer derives that place from its own scripts directory, never from the `--repo` tree, so the main checkout's installer asked about a linked work tree holds the helper to the place it armed; a place it cannot resolve stops `--check` with `unknown=scripts-place`, exit 2, and the install with a refusal, never an empty value. `helper_is_dangling` keeps reading line 3.
- `gg_install_file` in `scripts/lib/atomic-install.sh` replaces baselines, collated changelogs, and reflowed markdown by a rename inside the destination's directory. `common.sh` removes its staging file on exit.
- kendex runs the installer through the `repo-effects` declaration in `SKILL.md`; every verb that drops the package runs `--uninstall` while the scripts are still on disk; `kendex guard install`, `guard uninstall` and `guard check` call it directly; `kendex check` relays `--check` only where `.git/hooks/kendex-guards` exists, and the declaration's `checker` names `--check` for the app's per-project setup status, which runs it only where kendex recorded arming the effect there.

## The pre-push lane

`scripts/pre-push` owns Git ref parsing and destination scopes. The dispatcher owns enabled checks and push withholding. Only explicitly enabled byte-ceiling remains at push; the default set runs no content check. Content checks belong to pre-commit, and merge-group CI owns the Markdown and changelog range judgments. Git replay runs no commit hook, so CI must judge replayed commits. No earlier-hook record or cache is read.

- Drain Git's ref lines before checks and give the batch `/dev/null`. Ref lines missing a field refuse with exit 2. Skip deletions and destinations under `refs/tags/` or `refs/notes/`; classify by destination, including when the source is `HEAD`, `@` or an oid.
- Refuse a tip other than HEAD or an index different from HEAD. Byte-ceiling range scopes end at HEAD, and tracked policy reads the index. Untracked files and unstaged edits do not change this judgment.
- Prefer the advertised destination oid when its commit is available locally. Use `--against` (two dots), so the binary growth baseline is the destination's own blob. A merge-base comparison can excuse growth over a destination that previously shrank the file.
- Without that object, `local_boundary` uses tracking refs only when Git resolves exactly one configured remote URL to the hook's push URL. It reduces reached boundaries with `git merge-base --independent`. A sole survivor bounds the range. Multiple survivors use HEAD's merge base with the recorded remote default branch, then their common ancestor when no usable default exists. An ancestry collection failure refuses. No common ancestor leaves no base.
- Tracking refs are best-effort local evidence. After a remote URL change they may describe an earlier repository. The hook makes no network query to repair that limitation. A remote passed as a URL, an unmatched push URL, or no usable boundary falls back to the whole tree.
- Run the batch once per distinct scope with `--skip-unscoped`: `--against REF`, `--base REF` or no range. The dispatcher withholds checks owned elsewhere, independent of the Markdown scope setting. Byte-ceiling's whole-tree fallback holds oversized binaries to the indexed baseline, as CHECKS.md § byte-ceiling defines.
- Never print the remote name or URL: Git can pass a credential-bearing URL as the remote name. Diagnostics name the ref and scope. Verdicts fold to exit 2 for any incomplete scope, else 1 for any violation, else 0.
- Tracked settings read the index held equal to HEAD; environment and untracked settings remain local overrides.

## The pre-commit chain

`scripts/pre-commit` judges one commit snapshot: staged content, with tracked configuration read from the index. Order:

1. `doc-limits --staged` for document byte ceilings, from the committing work tree's copy first, then this install's; a silent skip where neither exists. An installed copy that does not complete is a step that did not complete, and blocks. `scripts/lib/siblings.sh` owns companion resolution for this chain.
2. `preflight --staged`, resolved the same way; a first commit skips it with a note.
3. One review-file check, resolved the same way: `github-repository-settings check --staged` when that package resolves, otherwise `bot-instructions check --staged` when installed. A failing or unrunnable selected owner never falls back. Both packages use the bot-instructions record protocol. Its attested `unconfigured` result prints `not-adopted=` under the selected package's name and passes at exit 0 or the older exit 2. The second library record must be `bot-instructions: renders=none`; bot-instructions' `schemas/validators.md` § `orphan` owns that proof. The wrapper's preceding check-location record stays visible.
4. `commit-guards all --staged`.
5. The repo-root-relative executable `COMMIT_GUARDS_PRE_COMMIT_LOCAL` names, when set. With `COMMIT_GUARDS_PRE_COMMIT_LOCAL_PATHS` set, it runs only when a path the commit touches matches, the list `gg_commit_paths` in `scripts/lib/commit-changes.sh` gives the commit-msg gate too.

Every step runs before the verdict. A present companion, or the batch, whose script is missing or not executable is an incomplete package, its author's or installer's to repair: the chain prints `package-incomplete=<path>` and leaves the verdict to the lanes that ran, except the selected github-repository-settings owner, which announces its step and blocks with exit 2. Any other companion failure blocks. The repo-local entry is the committer's own setting, so a missing one is `local-missing`, exit 2. The shims fail closed on `2` for a guard that could not run, naming what is missing.

## The markdown lanes

- `md-blocks.awk` mode `reflow` prints the file in the format, `lines` the judged lines with blockquote prefix stripped, the HTML block lines apart, and each heading's text.
- md-type runs the `lines` stream through `md-type.awk`, for the judged file and for docs-writing's SKILL.md, references and example documents alike. Two raw reads remain: the judged file, for each heading's level, which the stream's heading record does not carry, and an example, for its document's lines, since the stream emits no fence content. It reads docs-writing as data on every run, so a wording change in docs-writing reaches it only through the route table, the numbered list and the linked files; `tests/md-type.test.sh` reads the shipped docs-writing and fails in kendex when that contract breaks.
- md-refs runs the `lines` stream through `md-refs.awk`, then resolves in three passes: every selected file's references, the headings of every cited file read from the index whether or not in scope, then the verdict. Its source set joins the first pass through `md-refs.awk -v grammar=text`, fed by `comment-text.sh`; one `git grep` for the section sign over the index names the files that pass opens, so a source tree with no citation costs one search.
- The programs are POSIX awk (no interval expressions, no gawk builtins) under `LC_ALL=C`; `mawk` and `gawk --posix` give the same records over the suites' fixtures.
- The reflow is the block state machine printing the format, and `--check` compares a file with its reflow; `tests/md-reflow.test.sh` proves the output over the corpus and proves each rewrite is a fixed point.
- The batch passes `--staged` to both markdown checks at commit scope and `--base REF` or `--against REF` at a range scope, on byte-ceiling's dot conventions. md-type selects the documents the scope changed, renames detected, so a move is judged against the path it left; md-refs is a trigger, so any change in scope widens it to all configured documents against the index, since a removed target invalidates references in callers the change never touched. `COMMIT_GUARDS_MD_SCOPE=all` makes unflagged checks unconditional, and keeps md-refs on the sweep under a range; md-type keeps the range, since its verdict is what the change introduced.

## byte-ceiling sizing

The shared binary classifier selects blobs for the ceiling and warning. Text and source files are not sized against the ceiling. Large binary blobs remain in every clone.

Sizes are `git cat-file -s` of the diff's source and destination blobs. The source size is the tighten-only baseline when it already exceeds the ceiling, so which tree the source blob comes from decides what the ratchet permits: `--base` takes it from the merge base, `--against` from the ref's own tree, `--staged` from the index's parent. `--all` has no source blob; an oversized binary file's prior is its row in `COMMIT_GUARDS_BYTE_BASELINE`, read from the index. Rows naming text files are ignored. Rename detection is pinned on and held to exact content in every lane that diffs.

## Settings sources

`scripts/lib/settings.sh` resolves each key environment > `.env.local` > `.kendex/settings.toml` > committed `kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > default; `.env` is never read. Env files take `KEY=value` or `export KEY=value`, parsed, never sourced. Only an absent source is skipped; one that exists but is unusable (unreadable, a directory, FIFO, socket or device, a dangling symlink) is exit 2. `COMMIT_GUARDS_SETTINGS_FILE=/dev/null` selects no file source. Scripts `cd` to `git rev-parse --show-toplevel` first, so every relative path is repo-root-relative; a per-check flag overrides every source.

## Excludes format

The row format, the `!` carve and the `\!` escape are stated in `SKILL.md § Configuration`; every excludes list shares it, and a bare `!` is a config error. A baseline is `path<TAB>N`, `LC_ALL=C` sorted, unique paths, N a positive integer; a malformed, unsorted or duplicated row is exit 2, never repaired, by `gg_validate_baseline` in `scripts/lib/common.sh` for the binary baseline. The path-glob lists (`COMMIT_GUARDS_CHANGELOG_PATHS`, `COMMIT_GUARDS_MD_PATHS`, `COMMIT_GUARDS_MD_REFS_PATHS`) load through `gg_load_path_globs`: an absolute pattern, one escaping the repository, one leading with `-`, and an empty effective list are exit 2. For md-refs, `gg_md_load_paths` combines each base list with its matching EXTRA list before this check. The caller runs under `set -f`, which the loader checks; without it the patterns expand against the work tree.

## Probing a terminal-only code path

A headless suite cannot reach a branch that exists only at a tty (`mv` prompts before replacing a write-denied destination only there). `gg_pty_run CAP SCRIPT_FILE` in `tests/lib/pty.bash` runs a bash script with fds 0, 1 and 2 on a pseudo-terminal, picking the `script` grammar from `uname`; a host whose `script` answers neither form is a red naming the spawner, not a skip. Its states are enumerated above the function and nowhere else. `tests/terminal-paths.test.sh` is the worked example; its `pty_line` runs one session body and `install_line` is the wrapper an install case copies.

- Stdin is `/dev/null`, so a prompt is answered by EOF.
- A time cap on both sides: after `CAP` seconds the caller kills the session's process group, then the spawner's; the session holds the same deadline over itself a few seconds later.
- Assert the effect the branch has, not the spawner's status; `GG_PTY_STATE = ok` is the separate claim that the probe ran.
- Pair every negative with positive evidence the code was entered: echo a marker before the call and require it back.
- Check the premise inside the session: mode `0444` is not enforced at euid 0.
- Every path written into the session goes through `%q`; the session exports `LC_ALL=C`.

## Commit change collection

`scripts/lib/commit-changes.sh::gg_commit_changes` owns the changed, written and product path sets. The changelog message gate and kendex's compile scheduling share these sets. Product paths use `COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS`. Rename sources and destinations both count as changed paths. The written set retains the changelog gate's content and file-mode rules.
