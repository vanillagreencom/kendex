# commit-guards development

What a maintainer must not break. What each check fails: [CHECKS.md](CHECKS.md); consumer text: [README.md](README.md); every key: [SKILL.md](SKILL.md).

## One definition each

- `scripts/commit-guards` is the dispatcher; `STAGED_SCOPED_CHECKS` names the checks the commit batch hands `--staged`, and `--skip-unscoped` withholds the ones a caller that stages nothing leaves nothing for — which lanes defer to the shared markdown selector read off their own scripts, what that selector resolves to asked of `lib/md-scope.sh`.
- `scripts/lib/common.sh` holds the shared scan helpers, `gg_content_carriers` and `gg_grep_lane`. `scripts/lib/messages.sh` emits a stable key and value before the English explanation and owns the collection-error exit.
- `scripts/lib/configured-paths.sh` holds a glob-list lane's list, excludes, matcher, index walk and `gg_note_skip`.
- `scripts/lib/staged-lines.sh` is the lines a commit adds to one path, off a pinned `-U0` diff.
- `scripts/lib/comment-text.sh` is the comment grammar per path and the `line<TAB>text` scanner; its limits are stated in CHECKS.md § comments and pinned by `tests/comments.test.sh`.
- `scripts/lib/commit-header.sh` and `changelog-grammar.sh` define what a commit header and a changelog fragment are; `commit-parent.sh` is the parent a commit will have, an amend read off `/proc/<pid>/cmdline`.
- `scripts/lib/helper-body.sh` is the exact bytes of `.git/hooks/kendex-guards` (`helper_body`, `helper_head_shape`, `gg_shell_quote`), and with them `GG_LANES` and `gg_lane_verb`: the lanes this package owns and the verb each one gates, read by the installer's delegating line and by `--check`, and carried a third time inside the helper, which can source nothing; `skill-roots.sh` is the one definition of the skills roots, including the copy baked into the helper; `hooks-path.sh` is where git reads hooks from.
- `scripts/lib/md-blocks.awk` is the one reading of a markdown file's blocks; `md-shapes.awk` the line-shape predicates it asks, always the first `-f` program of `md-format`, `md-reflow` and `md-refs`, never loaded alone; `md-refs.awk` what a file cites and defines; `md-slug.awk` a heading reduced to its GitHub anchor; `md-scope.sh` the three scopes the markdown lanes share.
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
- `core.hooksPath` set to anything makes install a reported skip; removal and `--check` still run. `hooks_path_origins` prints the stand-down on stderr: git's `--show-origin --show-scope --get-all` lines verbatim through `%q`, and one sentence naming no path and no command.
- Linked worktrees share one install, and arming is refused in one: the helper names the scripts directory of the tree that armed it, which every session in the repository would then run and which goes away with that tree. The refusal stands down where there is no main checkout to name — a bare repository with work trees added — and it stands behind the `core.hooksPath` skip, which writes nothing from anywhere. `--check` and `--uninstall` answer from any work tree, and `--check`'s re-arm remedy names the main checkout where the caller is not standing in it; all of them, and arming from the main checkout, are repository-level and ask no other work tree or project.
- `--uninstall` drops the helper and the marked line, deletes a hook file this installer created outright, leaves every other line, and runs under `core.hooksPath` too. A line it may not edit keeps the helper and fails the removal.
- `--check` writes nothing, not even the hooks directory. `0`: helper and all three hooks pass the install predicate. `1`: a shim drifted or absent, or `core.hooksPath` set and empty. `2`: unmeasurable, or `core.hooksPath` naming a directory; the verifier reads `.git/hooks` only. Definitive drift outranks an unmeasured component. The first stdout line carries the stable verdict and finding keys. English explanation follows. The CLI reads the `commit-guards git hooks:` prefix.
- The helper is compared byte for byte against `helper_body`, its head against `helper_head_shape` with the per-checkout value blanked. Only `SCRIPT_DIR` may differ, and only when it round-trips through `gg_shell_quote` and names this project's scripts directory in another checkout of this repository; `project_rel` and `skill_roots` compare exactly.
- `gg_install_file` in `scripts/lib/atomic-install.sh` replaces baselines, collated changelogs, and reflowed markdown by a rename inside the destination's directory. `common.sh` removes its staging file on exit.
- kendex runs the installer through the `repo-effects` declaration in `SKILL.md`; every verb that drops the package runs `--uninstall` while the scripts are still on disk; `kendex guard install`, `guard uninstall` and `guard check` call it directly; `kendex check` relays `--check` only where `.git/hooks/kendex-guards` exists, and the declaration's `checker` names `--check` for the app's per-project setup status, which runs it only where kendex recorded arming the effect there.

## The pre-push lane

`scripts/pre-push` runs doc-limits over the pushed tree and judges what each pushed branch would do to the remote. Git runs no hook when it replays a commit, so a rebase, a cherry-pick or an autosquash can leave a branch in a state no commit hook ever saw; push is where the branch leaves the machine, whatever produced its state.

- Git passes the remote name and URL as arguments and the ref lines `<local-ref> <local-oid> <remote-ref> <remote-oid>` on stdin. They are read whole before the first check runs, and the batch is given `/dev/null`, so no check can take a line the loop has not reached.
- A line missing a field is refused with `ref-line-short`, exit 2: a line the lane cannot read may be depositing anything, and passing over it is the fail-open the lane exists to refuse.
- A deletion (an all-zero local oid) is announced and skipped, and so is a line whose REMOTE ref is under `refs/tags/` or `refs/notes/`.
- What a line deposits decides, so the classification reads the remote ref and never the left side. `git push origin HEAD`, `git push origin @:refs/heads/x` and `git push origin <sha>:refs/heads/x` all send something other than a branch name on the left while landing a branch on the right; `worktree push` sends the first of those after a restack. Every destination outside the tag and note namespaces is judged rather than guessed at.
- A message names the branch, not the spelling: `HEAD` and `@` resolve through `git symbolic-ref --quiet HEAD`, and a detached HEAD keeps what git sent.
- A branch whose local oid is not HEAD is refused with `not-head`, exit 2. Every lane but byte-ceiling reads the working tree or the index, and byte-ceiling's `--base` diffs `REF...HEAD`, so the batch judges this checkout and nothing else. The lane's own verdict line names the bypass, which costs every check in the batch.
- Where the ref line carries a remote oid this repository holds, the batch is asked `--against` that oid. The oid is the one thing here bound to the destination — git read it from the destination's own advertisement — but the ref alone settles nothing: `--base` is three dots, so it would compare against the ancestor the two share rather than the destination's tree, and on a branch that diverged from the destination those are different answers. `--against` is two dots, so byte-ceiling's baseline is the destination's own blob and the question is what landing HEAD there would do to it.
- Otherwise — the destination has no such ref — the base is the first boundary commit of `git rev-list --boundary <local-oid> --not --remotes=<remote>`, handed to `--base`, and it is a best-effort **local** scope rather than a claim about the destination: `refs/remotes/<name>/*` record a past fetch and nothing local dates them. After a `git remote set-url` they still describe the previous repository, so on a new destination branch byte-ceiling can treat an oversized file as pre-existing. `git ls-remote` would close that and is refused — a network round trip and an offline failure mode inside a hook, for the new-branch case alone.
- The push-URL test guarding that boundary is hygiene, not soundness. It stops the boundary being read off refs that are plainly another repository's — `pushurl` and `insteadOf` rewrites, the fetch-upstream push-to-a-fork triangle — by requiring `remote.<name>.url` to hold exactly one value equal to the hook's second argument. The key is multi-valued when a remote pushes to two places, a fetch uses the first, and git runs the hook once per URL, so `--get-all` asks it. `core.hooksPath` and `core.bare` stay on `--get`: those ask which value git uses, and for a scalar that is the last, which is what `--get` returns. Any inequality falls to the whole tree, which is also where a remote spelled as a URL lands.
- Where no boundary can be established the scope is the whole tree, `commit-guards all`, because nothing on the branch has been vetted against the destination and that is the only honest answer left. Three ways there: a push by direct URL, a push URL the tracking refs do not describe, and a branch nothing of which has reached the remote. It is the last resort rather than the first because `--all` emits candidates with no source blob, so the tighten-only ratchet never applies and every tracked file over the ceiling fails (CHECKS.md § byte-ceiling states the scopes apart) — which means a repository carrying files that were already oversized when it adopted the package **does** have such a push refused, with the excludes list or the bypass as the way past. Trying the boundary first is what keeps that rare; giving `--all` a ratchet is byte-ceiling's to do.
- The remote reaches `--remotes=` and no message. `git push <url> <branch>` passes the URL as the remote, userinfo and token included; git strips userinfo from its own diagnostics, and a lane printing what git withholds would put a credential in scrollback and in every log that captures hook output.
- The index holding content HEAD does not is refused with `index-drift`, exit 2, one `index-path` line per staged path. byte-ceiling is the only lane scoped to a commit range; every other one scans the index, so staged content makes the batch answer about a tree nobody is pushing — clean over a violation that is being uploaded, most of all. The index, not the work tree: an unstaged edit and an untracked file change nothing any lane reads, so neither is consulted. Asked once, at the first line that would be judged.
- doc-limits runs once per push, not once per ref line: it measures every tracked document against its class ceiling, absolutely, so a second run over another scope would repeat the first verdict word for word. It is asked lazily, at the first ref line that would be judged and after `index_is_head` has passed — so a push carrying nothing but deletions and tags is never held for it, and `--staged` reads an index the refusal has already held equal to HEAD. Sibling resolution, the re-vendor rule and the lane itself are `scripts/lib/siblings.sh`'s, shared with the pre-commit chain rather than spelled twice.
- The batch runs once per distinct scope: `commit-guards all --against REF`, `--base REF`, or `commit-guards all` for the whole tree, with `/dev/null` on its stdin. A second ref line at the same scope is announced as `scope-repeat` rather than judged again.
- Every batch run passes `--skip-unscoped`, so a check this run hands no scope, and whose bare default would then open no file, is withheld and named as `unscoped` rather than counted clean. The index-drift refusal guarantees nothing is staged, so such a check opens nothing; the index-reading checks are untouched by that and judge the pushed tree exactly.
- That withholding turns on three questions the dispatcher keeps apart. What the run itself hands a check is asked first, of one resolution both the withholding pass and the run loop read, because a lane given an explicit scope opens files whatever its bare default would have done. Which lanes take their bare scope from the shared markdown selector is read off each enabled check's own script, so no second list of lane names exists to fall behind. What a bare run of such a lane would resolve to is asked of `lib/md-scope.sh` itself through `gg_md_bare_scope`, because deferring to the selector says where a lane's answer comes from and not what it is — under `COMMIT_GUARDS_MD_SCOPE=all` the lane sweeps the tree, needs nothing staged, and runs here like any other. Asking it also puts an invalid setting where it belongs, exit 2, which withholding the lane before it ran would have swallowed.
- So a malformed document or a broken reference carried in by a replay is judged wherever this lane has a range to hand those lanes, which is every push whose destination ref or tracking refs settle a boundary. Under the whole-tree scope it is not: that sweep is absolute rather than ratcheted, so imposing it would refuse every push in a repository holding markdown that predates the guard, and `COMMIT_GUARDS_MD_SCOPE=all` is the project's call rather than this lane's.
- Verdicts fold as the pre-commit chain's do: exit 2 if any scope could not be judged, else 1 if any found violations, else 0.
- Tracked settings resolve from the index, as the pre-commit chain's do: the refusal above holds the index to HEAD, so the policy a push is measured against is the pushed commit's. The untracked sources — `.env.local`, `.kendex/settings.toml`, the environment — are local override by design and are untouched by it.

## The pre-commit chain

`scripts/pre-commit` judges one commit snapshot: staged content, with tracked configuration read from the index. Order:

1. `doc-limits --staged` for document byte ceilings, from the committing work tree's copy first, then this install's; a stated skip where neither exists or the repo-local one rejects `--staged` in its first-line parser diagnostic. The resolution and the lane are `scripts/lib/siblings.sh`'s, so the pre-push chain runs the same gate the same way.
2. `preflight --staged`, resolved the same way; a first commit skips it with a note.
3. `bot-instructions check --staged`, resolved the same way, so no consumer carries a wrapper for it.
4. `commit-guards all --staged`.
5. The repo-root-relative executable `COMMIT_GUARDS_PRE_COMMIT_LOCAL` names, when set.

Every step runs before the verdict; any other companion failure blocks. The shims fail closed on `2` for a guard that could not run, naming what is missing.

## The markdown lanes

- `md-blocks.awk` mode `check` prints md-format's violations, `reflow` the file in the format, `lines` the judged lines with blockquote prefix stripped, the HTML block lines apart, and each heading's text.
- md-refs runs the `lines` stream through `md-refs.awk`, then resolves in three passes: every selected file's references, the headings of every cited file read from the index whether or not in scope, then the verdict. Its source set joins the first pass through `md-refs.awk -v grammar=text`, fed by `comment-text.sh`; one `git grep` for the section sign over the index names the files that pass opens, so a source tree with no citation costs one search.
- Both programs are POSIX awk (no interval expressions, no gawk builtins) under `LC_ALL=C`; `mawk` and `gawk --posix` give the same records over the suites' fixtures.
- The reflow is the check's state machine printing instead of complaining, so a reflowed file passes md-format by construction; `tests/md-reflow.test.sh` proves it over the corpus and proves each rewrite is a fixed point.
- The batch passes `--staged` to both markdown checks at commit scope and `--base REF` or `--against REF` at a range scope, on byte-ceiling's dot conventions. md-format selects the documents the scope changed; md-refs is a trigger, so any change in scope widens it to all configured documents against the index, since a removed target invalidates references in callers the change never touched. `COMMIT_GUARDS_MD_SCOPE=all` makes unflagged checks unconditional.

## todo-ban marker shapes

Stated once, in CHECKS.md § todo-ban. At `--staged` the change set is collected as byte-ceiling's staged lane collects it (`--raw`, renames at exact content, symlinks and gitlinks dropped by destination mode), a `git grep --cached` over those paths names the carriers in chunks inside ARG_MAX, and only the named paths reach the per-path `-U0` diff. Membership is a `case` over a newline-delimited set: Bash 3.2 has no associative array.

## byte-ceiling sizing

Sizes are `git cat-file -s` of the diff's source and destination blobs. The source size is the tighten-only baseline when it already exceeds the ceiling, so which tree the source blob comes from decides what the ratchet permits: `--base` takes it from the merge base, `--against` from the ref's own tree, `--staged` from the index's parent, and `--all` has none at all. Rename detection is pinned on and held to exact content in every lane that diffs.

## suppression-ban patterns

The pathspec table is in CHECKS.md § suppression-ban. The bare-allow count runs over `gg_content_carriers`, then one `git grep --cached -c` per surviving `*.rs` carrier; a count that never arrived is a collection error, never 0. A tracked `*.rs` path holding a tab or newline is a config error.

## Settings sources

`scripts/lib/settings.sh` resolves each key environment > `.env.local` > `.kendex/settings.toml` > committed `kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > default; `.env` is never read. Env files take `KEY=value` or `export KEY=value`, parsed, never sourced. Only an absent source is skipped; one that exists but is unusable (unreadable, a directory, FIFO, socket or device, a dangling symlink) is exit 2. `COMMIT_GUARDS_SETTINGS_FILE=/dev/null` selects no file source. Scripts `cd` to `git rev-parse --show-toplevel` first, so every relative path is repo-root-relative; a per-check flag overrides every source.

## Excludes format

The row format, the `!` carve and the `\!` escape are stated in `SKILL.md § Configuration`; all six excludes lists share it, and a bare `!` is a config error. A baseline is `path<TAB>count`, `LC_ALL=C` sorted, unique paths, positive counts; a malformed, unsorted or duplicated row is exit 2, never repaired. The path-glob lists (`COMMIT_GUARDS_CHANGELOG_PATHS`, `COMMIT_GUARDS_PROSE_PATHS`, `COMMIT_GUARDS_MD_PATHS`, `COMMIT_GUARDS_MD_REFS_PATHS`, `COMMIT_GUARDS_COMMENT_PATHS`) load through `gg_load_path_globs`: an absolute pattern, one escaping the repository, one leading with `-`, and an empty list are exit 2. The caller runs under `set -f`, which the loader checks; without it the patterns expand against the work tree.

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
