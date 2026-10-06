# Declare, diff, apply

Read before changing planning, apply, the manifest, the lock, ownership, take-over or forks.

## The approach

The desktop app and the CLI are thin shells over one Rust model in `crates/core`: scan what each coding tool has on disk, read what the person declared, diff the two, and apply. The manifest (`kendex.toml`) is intent and records only choices: requested items, installed bundles, dependencies taken, removals. The lock (`.kendex-lock.json`) is provenance: where each installation came from and the hash of what was rendered. A scan is a view, never state. There is no database and no server; manifests, locks and the harness directories hold everything.

The vocabulary the code uses, with the meaning a reader could get wrong: a scope is `global` or one project root, the unit a manifest, a lock and an apply belong to; an item is a kind plus a name from a source, and an installation is item × harness × scope; a fork is the one sanctioned rebind of a declaration, from a remote source to `local`; adopt keeps files kendex did not write and rewrites the declaration to them, take-over keeps the declaration and moves the files to the trash.

## Why

Intent that lives in one declared file can be diffed, reviewed and committed, and a clone with the manifest and the lock reproduces the setup without kendex's help. A lock that records provenance lets a reinstall be a no-op, a cross-source name collision a refusal, and an update a comparison. Keeping scans as views means the disk is never a second source of truth that drifts from the declaration.

## Rules

Each numbered rule has one test of the same number in `crates/core/tests/invariants.rs`; the rest name their check inline.

1. Generated artifacts are always overwritable by kendex, and bytes no apply wrote are the person's: an edited installation is a conflict naming its exits, adopt or take-over, and nothing replaces it silently.
2. A removal the person made is never re-added, and a value the person set is never clobbered.
3. A content hash covers every input that shapes the artifact: the source bytes and every manifest section that reaches the render.
4. The lock records durable provenance for every installed kind: a same-source reinstall is a no-op, a cross-source name collision is a refusal naming the original, and a fork is the one rebind.
5. Enable and disable are lossless: a file-backed kind toggles by rename, a kind inside a shared config file by a structured edit that keeps every unrelated key.
6. Never touch the unowned: an unmanaged file is reported, never deleted, except an adopted workflow still at the bytes of the template its leaving package shipped, which leaves with that package and is never written or restored; a foreign symlink is a conflict; ownership is read from the positions lock entries wrote, never from a lock key alone.
7. Applies are transactional: preconditions revalidate against observed hashes right before mutation, pre-images are journaled first, a failure rolls back, an interrupted apply recovers on the next launch, and a removal goes to the trash ([trash.md](trash.md)).
8. One writer per scope: every apply holds an OS-level scope lock keyed off the canonical root, and a busy scope is a refusal.
9. kendex never stages, commits or resets in a repository it did not create, beyond the explicit offer in [commit-offer.md](commit-offer.md). Review holds this rule; no test does.
10. In-place edits are byte-faithful: an edit changes the keys it names and nothing else, newline included. The one exception, a repositioned list entry losing keys the model does not carry, is stated at `crates/core/src/manifest/fold.rs`. `crates/core/tests/byte_faithful.rs` holds it.
11. Validation precedes mutation: a refused operation leaves manifest, lock and install tree byte-identical, and every rendering is read back through the target harness's own loader rules inside plan preview.
12. Verification compares content, not provenance: an artifact kendex cannot compare is reported uncompared, never as passing.
13. Every external process goes through one hardened constructor, `crates/core/src/process/`, with git's redirecting environment cleared, every prompt path closed and a timeout on every call; a raw `Command::new` elsewhere fails a `tools/guard` lane.
14. One spelling per path: a root is canonicalized on entry and never re-spelled, and one spelling per artifact: `kendex.toml`, `.kendex-lock.json`, `kendex.settings.toml`, `KENDEX_*`; no older product name is read anywhere.
15. Manifest and lock reads convert no format version: this build reads exactly the version it writes and refuses any other, leaving the file byte for byte.
16. Beside every tracked `AGENTS.md` kendex writes and verifies a `CLAUDE.md` whose whole content is `@AGENTS.md`, and for Gemini a `context.fileName` key; a missing, stale or symlinked shim is drift (`crates/core/tests/instruction_shims.rs`).
17. A credential a package declares under `[secrets]` is written only to the project's private env file, created owner-readable, never to `kendex.settings.toml`, and only after the rule that makes git ignore it is written.
18. kendex never emits a pasteable command line: an error, a hint or a remedy presents the verb and its parameters as data. Two exceptions: the session-start drift report, whose remedies come from a fixed template set, and the notice a kept retired item gets, whose `kendex refresh --prune` and `kendex remove` the owner ruled.

`refresh --locked` plans each declaration with no revision of its own at the commit its lock entries agree on, resolves one the lock cannot place at the source's tip, and records only what the plan read, so a project-side re-render changes no catalog commit in `.kendex-lock.json`; without the flag, refresh brings every catalog current. `crates/cli/tests/refresh_locked.rs` holds it.

A render's on-disk identity leaves out `__pycache__` and `.pytest_cache` at every depth (`source_read::TOOL_CACHES`), the caches a skill's source also leaves out and a skill's own Python script writes back on every run, so refresh, verify and every automatic removal read a cached render as the bytes kendex wrote; `.git`, `node_modules` and `.venv` inside a render stay the person's and keep the edit hold, so a refresh never replaces such a render and an orphan cleanup leaves it in place. `crates/core/tests/edits_and_forks/tool_caches.rs` holds it.

Never derive manifest state from what is on disk, never write a second copy of a decision another module owns (the capability table, the hook delivery decision, the generated-paths set), and never add a migration: a format change is a new version this build reads and the old one refuses.

## The canonical example

`crates/core/src/engine/ops/add.rs`: it refuses before any write when no target can take the kind, plans the desired set from the declaration, binds each op to the hash it read, and hands the plan to `crates/core/src/apply/` to journal and execute under the scope lock. A new verb copies that shape.

## Decisions

The committed lock and its machine half are [D001](../decisions/D001-portable-lock.md); who records it on `main` is [D007](../decisions/D007-lock-record-on-main.md); the trash bounds are [D004](../decisions/D004-trash-retention.md) and [D005](../decisions/D005-trash-size-record.md).
