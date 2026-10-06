# The commit is offered, never taken

Read before changing the commit, push or pull-request offer that follows a write.

## The approach

kendex writes files into a git project's checkout, and a project commits those files so that a clone works without kendex. After a write, on either surface, kendex offers four choices of equal standing: commit, commit and push, commit on a branch and open a pull request, or leave the files as diffs, which is the default and a success. The offer runs after the write, never before it and never as part of it, and covers what that action changed: the files kendex owns whole that git reports changed, and a file it writes into only where the action changed it from a clean state.

## Why

A write that also committed would turn every apply into a commit the person did not review, in a repository kendex did not create. Leaving the files as diffs as a first-class answer is what lets a person apply, look and decide.

## Rules

- Do commit only what kendex wrote; a file the person wrote is never staged and never committed. One deletion rule in `crates/core/src/commit_offer/paths.rs` serves every reader: a deleted path the committed inventory names is kendex's whole, unless `GeneratedPaths::beside` names it.
- Do carry a file kendex does not own whole, the manifest, `kendex.settings.toml`, `.gitignore` and the shared edit targets, only where the action changed it from a clean state; `Scan::carry` in `crates/core/src/commit_offer/mod.rs` is the one answer every count, list and commit reads.
- Do run the commit through `git commit`, so the repository's own hooks run on it, and hand a refusal from git, a hook or `gh` to the person in that program's own words, whole.
- Do hold the offer where an armed package says the commit would carry its files stale, per [repo-effects.md](repo-effects.md), and offer its setup instead.
- Do ask at most once per run per project.
- Never undo a commit: no revert, no moving a branch ref backwards, no reset, no stash. The one working-tree write, `restore` in `crates/core/src/commit_offer/restore.rs`, puts named paths back to what the last commit holds and touches no ref and no index.
- Never let a setting, a flag or a state make any of the three writes happen without a choice in this run.

## The canonical example

`crates/core/src/commit_offer/`: `Before::read` takes the state before the action, `Scan` reads one `git status` over the checkout and matches rows against the set, and `crates/cli/tests/commit_offer_cli.rs` plants an edited render and a changed manifest and reads what the commit carries. A new surface for the offer reads `Scan` and formats; it decides nothing.

## Revisit when

A project's workflow needs kendex's writes committed with no person present, such as a consumer refresh, and that run has no surface to choose on. Today that case is the consumer's own workflow, per [merge-rail.md](merge-rail.md), not the offer.

## Not governed

Which files kendex owns whole: [generated-paths.md](generated-paths.md). Whether a package's files are stale: the package's own checker, under [repo-effects.md](repo-effects.md).
