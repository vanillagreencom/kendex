# Declare, diff, apply

Read before changing planning, apply, the manifest, the lock, ownership, take-over or forks.

## The approach

The desktop app and the CLI are thin shells over one Rust model in `crates/core`. The model scans what each coding tool holds on disk, reads what the person declared, diffs the two and applies the difference. The manifest, `kendex.toml`, is intent and records only choices: requested items, installed bundles, dependencies taken, removals. The lock, `.kendex-lock.json`, is provenance: where each installation came from and the hash of what was rendered. A scan is a view, never state. There is no database and no server; the manifests, the locks and the harness directories hold everything.

The words the code uses, with the meaning a reader could get wrong: a scope is `global` or one project root, the unit a manifest, a lock and an apply belong to. An item is a kind plus a name from a source, and an installation is one item on one harness in one scope. A fork is the one sanctioned rebind of a declaration, from a remote source to `local`. Adopt keeps files kendex did not write and rewrites the declaration to them; take-over keeps the declaration and moves the files to the trash.

## Why

Intent in one declared file can be diffed, reviewed and committed, and a clone holding the manifest and the lock reproduces the setup. A lock that records provenance makes a reinstall a no-op, a cross-source name collision a refusal and an update a comparison. A scan that is only a view keeps the disk from becoming a second source of truth that drifts from the declaration.

## Rules

Rules 1 to 8 each have one test of the same number in `crates/core/tests/invariants.rs`; the others name their check inline.

1. kendex may always overwrite a generated artifact, and bytes no apply wrote are the person's: an edited installation is a conflict naming its exits, adopt or take-over, and nothing replaces it silently.
2. A removal the person made is never re-added, and a value the person set is never clobbered.
3. A content hash covers every input that shapes the artifact: the source bytes and every manifest section that reaches the render.
4. The lock records durable provenance for every installed kind: a same-source reinstall is a no-op, a cross-source name collision is a refusal naming the original, and a fork is the one rebind.
5. Enable and disable are lossless: a file-backed kind toggles by rename, a kind inside a shared config file by a structured edit that keeps every unrelated key.
6. Never touch the unowned: an unmanaged file is reported, never deleted, except an adopted workflow still at the bytes of the template its leaving package shipped, which leaves with that package and is never written or restored; a foreign symlink is a conflict; ownership is read from the positions lock entries wrote, never from a lock key alone.
7. Applies are transactional: preconditions revalidate against observed hashes right before mutation, pre-images are journaled first, a failure rolls back, an interrupted apply recovers on the next launch, and a removal goes to the trash per [trash.md](trash.md).
8. One writer per scope: every apply holds an OS-level scope lock keyed off the canonical root, and a busy scope is a refusal.
9. kendex never stages, commits or resets in a repository it did not create, beyond the explicit offer in [commit-offer.md](commit-offer.md). Review holds this rule; no test does.
10. In-place edits are byte-faithful: an edit changes the keys it names and nothing else, newline included. The one exception, a repositioned list entry losing keys the model does not carry, is stated at `crates/core/src/manifest/fold.rs`. `crates/core/tests/byte_faithful.rs` holds it.
11. Validation precedes mutation: a refused operation leaves manifest, lock and install tree byte-identical, and every rendering is read back through the target harness's own loader rules inside plan preview.
12. Verification compares content, not provenance: an artifact kendex cannot compare is reported uncompared, never as passing.
13. Every external process goes through one hardened constructor in `crates/core/src/process/`, with git's redirecting environment cleared, every prompt path closed and a timeout on every call. A raw `Command::new` elsewhere fails the `raw-command-new` lane of `tools/guard`.
14. One spelling per path and per artifact: a root is canonicalized on entry and never re-spelled, and the names are `kendex.toml`, `.kendex-lock.json`, `kendex.settings.toml` and `KENDEX_*`; no older product name is read anywhere.
15. Manifest and lock reads convert no format version: this build reads exactly the version it writes and refuses any other, leaving the file byte for byte. A format change is a new version this build reads and the old one refuses; never add a migration.
16. Beside every tracked `AGENTS.md` kendex writes and verifies a `CLAUDE.md` whose whole content is `@AGENTS.md`, and for Gemini a `context.fileName` key; a missing, stale or symlinked shim is drift. `crates/core/tests/instruction_shims.rs` holds it.
17. A credential a package declares under `[secrets]` is written only to the project's private env file, created owner-readable, never to `kendex.settings.toml`, and only after the rule that makes git ignore it is written.
18. kendex never prints a pasteable command line: an error, a hint or a remedy presents the verb and its parameters as data. Two exceptions: the session-start drift report, whose remedies come from the fixed template set in `crates/core/src/drift/report/`, and the notice a retired item gets, whose `kendex refresh --prune` and `kendex remove` the owner ruled.
19. `refresh --locked` plans each declaration with no revision of its own at the commit its lock entries agree on, so a project-side re-render changes no catalog commit in the lock; without the flag, refresh brings every catalog current. `crates/cli/tests/refresh_locked.rs` holds it.
20. A render's on-disk identity leaves out the tool caches `source_read::TOOL_CACHES` names at every depth, so a cached render still reads as the bytes kendex wrote; `.git`, `node_modules` and `.venv` inside a render stay the person's and keep the edit hold. `crates/core/tests/edits_and_forks/tool_caches.rs` holds it.

Never derive manifest state from what is on disk, and never write a second copy of a decision another module owns: the capability table and hook delivery are [harnesses.md](harnesses.md), the generated-paths set is [generated-paths.md](generated-paths.md).

## The canonical example

`crates/core/src/engine/ops/add.rs`: it refuses before any write when no target can take the kind, plans the desired set from the declaration, binds each op to the hash it read, and hands the plan to `crates/core/src/apply/` to journal and execute under the scope lock. A new verb copies that shape.

## Revisit when

A harness stores state kendex cannot render from a declaration, so a scan would have to become state, or a second product has to read the manifest and the lock and the versioned-format refusal of rule 15 blocks it.

## Not governed

What a lock row holds and who records it on `main`: [D001](../decisions/D001-portable-lock.md) and [D007](../decisions/D007-lock-record-on-main.md). The trash's bounds: [trash.md](trash.md). Each harness's paths and formats: [harnesses.md](harnesses.md).
