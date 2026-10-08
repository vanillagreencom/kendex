# Declare, diff, apply

Read before changing planning, apply, the manifest, the lock, ownership, take-over, forks, the generated-file inventory, verification, workflow adoption, tracked outputs, or the commit, push or pull-request offer that follows a write.

## The approach

The desktop app and the CLI are thin shells over one Rust model in `crates/core`. The model scans what each coding tool holds on disk, reads what the person declared, diffs the two and applies the difference. The manifest, `kendex.toml`, is intent and records only choices: requested items, installed bundles, dependencies taken, removals. The lock, `.kendex-lock.json`, is provenance: where each installation came from and the hash of what was rendered. A scan is a view, never state. There is no database and no server; the manifests, the locks and the harness directories hold everything.

The words the code uses, with the meaning a reader could get wrong: a scope is `global` or one project root, the unit a manifest, a lock and an apply belong to. An item is a kind plus a name from a source, and an installation is one item on one harness in one scope. A fork is the one sanctioned rebind of a declaration, from a remote source to `local`. Adopt keeps files kendex did not write and rewrites the declaration to them; take-over keeps the declaration and moves the files to the trash.

The generated-file inventory, `.kendex-generated.json`, lists the files kendex wrote that verification can compare with declared content: rendered paths, plus workflow copies a package adopted with their template hash. Every reader of a render path consults it, and a path it does not list is judged hand-written. A record there says what can be compared. It never grants permission to overwrite or restore a file: ownership comes from the positions the lock entries wrote, and the one exception is rule 6's adopted workflow, which leaves with its package.

kendex writes files into a git project's checkout, and a project commits those files so that a clone works without kendex. After a write, on either surface, kendex offers four choices of equal standing: commit, commit and push, commit on a branch and open a pull request, or leave the files as diffs, which is the default and a success. The offer runs after the write, never before it and never as part of it, and covers what that action changed: the files kendex owns whole that git reports changed, and a file it writes into only where the action changed it from a clean state.

## Why

Intent in one declared file can be diffed, reviewed and committed, and a clone holding the manifest and the lock reproduces the setup. A lock that records provenance makes a reinstall a no-op, a cross-source name collision a refusal and an update a comparison. A scan that is only a view keeps the disk from becoming a second source of truth that drifts from the declaration.

CI, the commit offer, the classifier and `kendex verify` all need to know which bytes are kendex's without re-rendering, and one committed list answers them. Keeping that list a record and not a licence stops a stale inventory, or one a branch rewrote, from authorizing a write over a person's file. The adopted-workflow exception writes nothing and moves only bytes the leaving package's own tree vouches for, so a stale record cannot take a person's edit.

A write that also committed would turn every apply into a commit the person did not review, in a repository kendex did not create. Leaving the files as diffs as a first-class answer lets a person apply, look and decide.

## Rules

Rules 1 to 8 each have one test of the same number in `crates/core/tests/invariants.rs`; the others name their check inline.

1. kendex may always overwrite a generated artifact, and bytes no apply wrote are the person's: an edited installation is a conflict naming its exits, adopt or take-over, and nothing replaces it silently.
2. A removal the person made is never re-added, and a value the person set is never clobbered.
3. A content hash covers every input that shapes the artifact: the source bytes and every manifest section that reaches the render.
4. The lock records durable provenance for every installed kind: a same-source reinstall is a no-op and a cross-source name collision is a refusal naming the original. A fork rebinds to local. An explicit unsubscribe transfers a member to the surviving bundle's source at the commit the plan reads, with installed hashes kept for edit detection.
5. Enable and disable are lossless: a file-backed kind toggles by rename, a kind inside a shared config file by a structured edit that keeps every unrelated key.
6. Never touch the unowned: an unmanaged file is reported, never deleted, except an adopted workflow still at the bytes of the template its leaving package shipped, which leaves with that package and is never written or restored; a foreign symlink is a conflict; ownership is read from the positions lock entries wrote, never from a lock key alone.
7. Applies are transactional: preconditions revalidate against observed hashes right before mutation, pre-images are journaled first, a failure rolls back, an interrupted apply recovers on the next launch, and a removal goes to the trash per [trash.md](trash.md).
8. One writer per scope: every apply holds an OS-level scope lock keyed off the canonical root, and a busy scope is a refusal.
9. kendex never stages, commits or resets in a repository it did not create, beyond the explicit offer under [§ The commit offer](#the-commit-offer). Review holds this rule; no test does.
10. In-place edits are byte-faithful: an edit changes the keys it names and nothing else, newline included. The one exception, a repositioned list entry losing keys the model does not carry, is stated at `crates/core/src/manifest/fold.rs`. `crates/core/tests/byte_faithful.rs` holds it.
11. Validation precedes mutation: a refused operation leaves manifest, lock and install tree byte-identical, and every rendering is read back through the target harness's own loader rules inside plan preview.
12. Verification compares content, not provenance: an artifact kendex cannot compare is reported uncompared, never as passing.
13. Every external process goes through one hardened constructor in `crates/core/src/process/`, with git's redirecting environment cleared, every prompt path closed and a timeout on every call. A raw `Command::new` elsewhere fails the `raw-command-new` lane of `tools/guard`.
14. One spelling per path and per artifact: a root is canonicalized on entry and never re-spelled, and the names are `kendex.toml`, `.kendex-lock.json`, `kendex.settings.toml` and `KENDEX_*`; no older product name is read anywhere.
15. Manifest and lock reads convert no format version: this build reads exactly the version it writes and refuses any other, leaving the file byte for byte. A format change is a new version this build reads and the old one refuses; never add a migration.
16. Claude Code reads `AGENTS.md` itself. kendex writes no `CLAUDE.md`. Former whole-file shims stay with the project for sessions that still need imports; refresh drops their generated-path records without reading or removing the files. Personal files and symlinks at these positions stay untouched. The old `.claude/CLAUDE.md` link to the root `AGENTS.md` retires. Gemini keeps its `context.fileName` key; a missing or stale key is drift. `crates/core/tests/instruction_shims.rs` holds it.
17. A credential a package declares under `[secrets]` is written only to the project's private env file, created owner-readable, never to `kendex.settings.toml`, and only after the rule that makes git ignore it is written.
18. kendex never prints a pasteable command line: an error, a hint or a remedy presents the verb and its parameters as data. Two exceptions: the session-start drift report, whose remedies come from the fixed template set in `crates/core/src/drift/report/`, and the notice a retired item or bundle gets, whose `kendex refresh --prune`, and for an item `kendex remove`, the owner ruled.
19. `refresh --locked` plans each declaration with no revision of its own at the commit its lock entries agree on, fetches a recorded commit this machine lacks, resolves one the lock cannot place, or whose recorded commit is gone from its source, at the source's tip, and records only what the plan read, so a project-side re-render changes no catalog commit in the lock; without the flag, refresh brings every catalog current. `crates/cli/tests/refresh_locked.rs` holds it.
20. A render's on-disk identity leaves out the tool caches `source_read::TOOL_CACHES` names at every depth, so a cached render still reads as the bytes kendex wrote; `.git`, `node_modules` and `.venv` inside a render stay the person's and keep the edit hold. `crates/core/tests/edits_and_forks/tool_caches.rs` holds it.

Never derive manifest state from what is on disk, and never write a second copy of a decision another module owns: the capability table and hook delivery are [harnesses.md](harnesses.md), the generated-paths set is `GeneratedPaths`, under [§ The generated-file inventory](#the-generated-file-inventory).

### The generated-file inventory

- Do take the set from one place, `GeneratedPaths` in `crates/core/src/engine/generated_paths.rs`: written positions, adoption declarations, held positions already listed at `HEAD`, unresolved former Claude shims listed on disk, and the rows listed at `HEAD` under each package the pass keeps as recorded, a kept retired item, or a kept set's member or what one requires, until a removal or a prune takes it.
- Do leave a skill's top-level `tests/`, `evals/` and `DEVELOPMENT.md` out of every render; `SealedSource::rendered_item` is the one reading of which files an install holds, and an edit to one of those entries moves no hash.
- Do keep a shared refresh caller outside the inventory: the release adopter checks its bytes against shipped history and removes its earlier record. Do verify other adopted workflows against their template's bytes at the recorded revision; an edited installed template cannot attest an edited workflow, and refresh never rewrites or restores a workflow.
- Do take an adopted workflow out with its package: where the package leaves the install record and the copy still holds the bytes of the template in the package's tree, the copy goes to the trash and its record leaves the inventory; an edited copy stays, and verify keeps failing it. A tree one tool drops while the package stays is no leaving. While a retired package stays installed, its adopted workflow is held to the template in that package's tree.
- Do keep an invalid inventory's bytes: apply cannot erase an adoption declaration it could not read.
- Do read `.kendex-generated.json` at both endpoints in CI, from the render plan, with in-place sources and Pi carrier payloads outside it.
- Do keep every committed render at the bytes its source renders: `cargo test -p kendex-core --lib own_renders` plans a copy of the commit with edits discarded and fails on each inventory path a planned op would write. The install record is the one inventory path it leaves alone, since a pull request keeps the record as `main` holds it, per [D007](../decisions/D007-lock-record-on-main.md).
- Never write the inventory from a consumer of it: a consumer reads the list and compares, as `crates/core/src/engine/generated_paths/own_inventory.rs` reads kendex's own inventory against a fresh render of the catalog.
- Never add a path to the inventory by hand except in a worktree, where `kendex refresh` would re-render the whole tree: there the entry is added sorted, one per line, and `cargo test -p kendex-core --lib own_inventory` judges it.
- Never treat a listed path as owned whole where `GeneratedPaths::beside` names it: the manifest, `kendex.settings.toml`, `.gitignore` and the shared edit targets are written into, never replaced.

### The commit offer

- Do commit only what kendex wrote; a file the person wrote is never staged and never committed. One deletion rule in `crates/core/src/commit_offer/paths.rs` serves every reader: a deleted path the committed inventory names is kendex's whole, unless `GeneratedPaths::beside` names it.
- Do carry a file kendex does not own whole, the manifest, `kendex.settings.toml`, `.gitignore` and the shared edit targets, only where the action changed it from a clean state; `Scan::carried` in `crates/core/src/commit_offer/mod.rs` is the one answer every count, list and commit reads.
- Do run the commit through `git commit`, so the repository's own hooks run on it, and hand a refusal from git, a hook or `gh` to the person in that program's own words, whole.
- Do hold the offer where an armed package says the commit would carry its files stale, per [repo-effects.md](repo-effects.md), and offer its setup instead.
- Do ask at most once per run per project.
- Do build a new surface for the offer on `Scan` in `crates/core/src/commit_offer/`: it reads `Scan` and formats, and decides nothing.
- Never undo a commit: no revert, no moving a branch ref backwards, no reset, no stash. The one working-tree write, `restore` in `crates/core/src/commit_offer/restore.rs`, puts named paths back to what the last commit holds and touches no ref and no index.
- Never let a setting, a flag or a state commit, push or open a pull request without a choice in this run.

## The canonical example

`crates/core/src/engine/ops/add.rs`: it refuses before any write when no target can take the kind, plans the desired set from the declaration, binds each op to the hash it read, and hands the plan to `crates/core/src/apply/` to journal and execute under the scope lock. A new verb copies that shape.

## Revisit when

A harness stores state kendex cannot render from a declaration, so a scan would have to become state, or a second product has to read the manifest and the lock and the versioned-format refusal of rule 15 blocks it.

A project's workflow needs kendex's writes committed with no person present, such as a consumer refresh, and that run has no surface to choose on. Today that case is the consumer's own workflow, per [merge-rail.md](merge-rail.md), not the offer.

A reader needs to know what kendex wrote at a commit no checkout holds, or a package adopts a file that no template hash can attest.

## Not governed

What a lock row holds and who records it on `main`: [D001](../decisions/D001-portable-lock.md) and [D007](../decisions/D007-lock-record-on-main.md). The trash's bounds: [trash.md](trash.md). Each harness's paths and formats, and which bytes a render holds: [harnesses.md](harnesses.md). Whether a package's files are stale: the package's own checker, under [repo-effects.md](repo-effects.md).
