# Engine

Covers: crates/core/src/apply/, crates/core/src/engine/, crates/core/src/manifest/, crates/core/src/lock/, crates/core/src/hook/, crates/core/src/base.rs, crates/core/src/fs.rs

The engine turns a manifest into a plan and a plan into disk. Planning derives the closure of what a scope wants, compares it with what the scanner observed, and produces ops with preconditions; apply runs those ops as one journaled transaction under the scope lock.

## Boundaries

- The manifest records choices, never consequences: items asked for, bundles installed, optional dependencies taken, what stays removed. A bundle's members and a skill's dependencies are derived on every plan, and the lock caches why each installation exists as typed edges (`requested`, `required-by`, `member-of`); losing the lock loses nothing. Enforced by `crates/core/tests/bundles/` and `crates/core/tests/dependencies/`.
- Production manifest writes go through the apply; `manifest::save` is not public, and a whole-file write carries a `Base` (`crates/core/src/base.rs`, the hash of the bytes read) that binds into the plan op's precondition. Enforced by the tests in `crates/core/src/base.rs`.
- Every apply, from the app or the CLI, holds the OS-level scope lock keyed off `apply::scope_key`, which reads the canonical scope so two spellings of one root cannot hold two locks. Enforced by `crates/core/tests/invariants.rs::invariant_8_one_writer_per_scope`.
- Mutation ownership comes only from recorded written positions. Read-only origin lookup uses `crates/core/src/ownership.rs` to consult current records, declarations, and installed metadata. Recovered evidence never authorizes replacement. Enforced by `crates/core/tests/unmanaged_ownership.rs` and `crates/core/src/library/tests.rs::report_and_library_recover_the_same_origin_without_a_readable_record`.

- CI reads the committed generated-file inventory from the render plan. In-place sources and Pi carrier payloads stay outside it. Enforced by `crates/core/tests/instruction_shims.rs::generated_inventory_tracks_renders_and_excludes_source` and the harness-ci package tests.

## Invariants

1. A declaration landing on files kendex never wrote is a conflict with two exits, adopt and take-over, and the row names every position in the way. Take-over trashes the files bound to the bytes the plan read, whole or not at all: a place nothing can settle refuses the run and nothing is written. Enforced by `crates/core/tests/unmanaged_takeover/` and `crates/app/tests/replace_unmanaged.rs`.
2. A link is never its target: a link the user put at a shared config file or a manifest is edited through, link kept, and whether a link may sit at a position is decided at plan time, never by the write. Enforced by `crates/core/tests/symlinked_harness_dir.rs`.
3. A fork keeps the installed name so dependents and bundles resolve; one made beside takes a chosen name proven free before the first durable write. Enforced by `crates/core/tests/edits_and_forks/`.
4. A hook registration is reconciled, not added to: what a hook registered is recorded (`engine::item_record`), a catalog moving it retires the recorded entry where the document still has it, and an entry the record cannot name with certainty is the person's to keep. Enforced by `crates/core/tests/hook_records.rs` and `crates/core/tests/hook_removal.rs`.
5. Permission intent is typed as `Unspecified | AllowOnly | DenyExtra` and never widens through parse, merge or render; a surface that cannot express it renders the most restrictive expressible form or refuses, and a refusal removes the older, wider rendering. Enforced by `crates/core/tests/permissions.rs`.
6. Manifest and lock carry a format version, and reads convert neither. After an unreadable lock is moved aside, explicit record-existing mode creates a new lock only when every declared render matches current source and disk bytes; any mismatch leaves every file unchanged. Pi recovery seeds the audit from byte matches through `crates/core/src/pi_ext/state.rs`; it does not require a prior completion record. Enforced by `crates/core/tests/migration.rs`, `crates/core/tests/v1_lock.rs`, `crates/app/tests/apply_migration.rs` and `crates/cli/tests/update_pi.rs::verification_and_record_recovery_compare_pi_bytes`.
7. A namespaced `<plugin>/<item>` name is the identity in manifest, lock and UI; the `/` never reaches disk, the halves are joined by the separator `crates/core/src/harness/caps.rs` derives from the name rule, and two declarations landing on one file install neither. Only agents, commands and skills may carry a plugin segment. Enforced by `crates/core/tests/command_names.rs` and `crates/core/tests/collision_refusal.rs`.
8. A `kendex.toml` name that cannot be a path is refused with the reason: `..`, a Windows device name, a trailing dot or space, a component over `MAX_SEGMENT` bytes, a stray `/`, a leading `-` and shell metacharacters. Enforced by `crates/core/src/names.rs::path_hostile_shapes_are_named_with_the_reason`.
9. A name says where it comes from or the search does, never a fallback: `marketplace::name` resolves against subscription aliases only, and a bare name searching every enabled subscription refuses on two offers, naming both spellings. Enforced by `crates/cli/tests/add_kinds.rs` and `crates/core/tests/install_into_project.rs`.
10. Unsubscribing removes or keeps exactly the subscription's closure, derived by expanding the installed set with and without the source and diffing; keep copies source-form bytes into the scope's local source before the manifest flip, and refuses an edited package or an occupied local target. Enforced by `crates/core/tests/unsubscribe.rs` and `crates/core/tests/unsubscribe_keep.rs`.
11. Every atomic write gets its own temp file: `fs::write_then_rename` names it per write, not per process. Not mechanically enforced.
12. Journal recovery is idempotent, so a crash mid-rollback recovers by rolling back again; an empty journal is never written because it would read as an interrupted apply. Enforced by `crates/app/tests/recovery.rs`.

- Record-only recovery requires a complete declaration audit and read preconditions that still match at execution. Enforced by `crates/core/tests/migration.rs::recovery_requires_the_whole_declared_set` and `::recovery_rechecks_render_bytes_before_recording`.
- Generic orphan cleanup keeps Pi payloads and registrations together until carrier removal handles both. Enforced by `crates/cli/tests/update_pi.rs::generic_orphan_cleanup_keeps_pi_payload_and_registration_together`.

## Decisions

- A catalog hook and a manifest `[[custom-hooks]]` entry both become one `HookSpec` (`crates/core/src/hook/spec.rs`), and `crates/core/src/hook/delivery.rs` decides once how a spec reaches each harness at each scope; the engine, the agent renderer and the editor read that one decision, so a registered hook never also renders as prose. Enforced by `crates/core/tests/custom_hooks.rs`.
- A member the user removes from a bundle is a suppression: refresh honors it, declaring the item outranks it, and the audit reports the bundle with members held back. Enforced by `crates/core/tests/bundles/`.
- A settings template applies once, when its skill's declaration arrives in `kendex.toml`, write-if-absent, and nothing else writes there but a save from the app; the authoring rules are in [../authoring/settings.md](../authoring/settings.md). Enforced by `crates/core/tests/settings_seed/`.
