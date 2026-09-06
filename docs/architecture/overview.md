# kendex architecture

## The one idea

The desktop app and CLI project one Rust model: scan, declare, diff and apply. The per-scope manifest stores user intent. Drift compares that intent with observed harness state. Apply makes disk match the declaration; adopt records observed state as intent. App pages and CLI commands own no separate domain logic. Manifests, locks and harness directories hold all state; kendex has no server.

## Vocabulary

- Scope: `global` or `project { root }`; the unit a manifest, a lock, an apply and its OS-level lock belong to.
- Harness: a coding tool kendex writes to, in code (`HarnessId`) and on screen; never "tool" on screen.
- Item: a logical kind plus name from a source. Installation: item × harness × scope, what locks, drift rows and applies track.
- Source: `path` or `git`; a subscription is a source a scope declares. Bundle: a curated set a catalog offers under one name, installed as one declaration.
- Manifest: declared intent. Lock: provenance plus rendered hash per installation. Observation: scanner truth. Drift: declared against observed.
- Surface: where one kind lives for one harness at one scope, one of four shapes (`Surface` in `crates/core/src/harness/mod.rs`); harnesses reading one physical directory form a surface group.
- Fork: the one sanctioned rebind of a declaration, remote to `local`, recorded under `[forks.<kind>.<name>]`.
- Adopt and take-over: the two exits from a declaration landing on files kendex did not write; adopt keeps the files and rewrites the declaration, take-over keeps the declaration and trashes the files.

## Boundaries

- `crates/core`: pure domain logic; no Tauri, no IPC, no UI concern. Enforced by the `cargo tree` lane in `tools/guard`. Every external process is built by `crates/core/src/process/mod.rs` and every catalog read goes through `source_read::SealedSource`; both enforced by `tools/guard` lanes.
- `crates/app`: Tauri commands, one module per page domain, over core. The command surface and the constants the UI reads are declared in `specta_builder` and byte-checked against `ui/src/bindings.ts` by `crates/app/tests/bindings.rs`.
- `crates/cli`: thin verbs over the same core, with one presentation layer in `crates/cli/src/ui.rs`.
- `ui/`: renders state and invokes commands over the generated bindings; domain logic and types live in Rust. `@tauri-apps` is imported only by the generated bindings and no UI file carries a raw colour; both enforced by `tools/guard` lanes.
- Adapters under `crates/core/src/harness/` own paths and rendering only; what each harness supports is one capability table, `crates/core/src/harness/caps.rs`, read by core and UI. Enforced by `crates/core/src/harness/mod.rs::observe_capabilities_match_declared_surfaces`.

## Invariants

1. Generated artifacts are always overwritable by kendex, and bytes no apply wrote are the user's: an edited installation is a conflict naming its exits, never a silent loss. Enforced by `crates/core/tests/invariants.rs::invariant_1_generated_artifacts_regenerate_but_never_over_an_edit`.
2. Write-only-if-absent: a user-set value is never clobbered and a user removal is never re-added. The removal half is enforced by `crates/core/tests/invariants.rs::invariant_2_never_readd_a_user_removal`; the never-clobber half is not mechanically enforced.
3. A content hash covers the source bytes plus every manifest section that shapes the artifact. Enforced by `crates/core/tests/invariants.rs::invariant_3_shared_key_edits_invalidate_dependents`.
4. A lock records durable provenance for every installed kind, including Pi extensions: same-source reinstall is a no-op, a cross-source name collision is a hard error naming the original, and a fork is the one rebind. A read-only report or verify can use matching current manifest and render bytes when the lock is unavailable, but keeps the lock failure visible. Enforced by `crates/core/tests/invariants.rs::invariant_4_provenance_is_durable`, `crates/core/tests/collision_refusal.rs`, `crates/cli/tests/compat.rs` and `crates/cli/tests/pi_extension_only_lock.rs`.
5. Enable and disable are lossless: file-backed kinds toggle by rename, kinds inside a shared config file toggle by a structured edit that keeps every unrelated key. Enforced by `crates/core/tests/invariants.rs::invariant_5_toggle_is_lossless_rename`.
6. Never touch the unowned: unmanaged files are reported, never deleted; a foreign symlink is a conflict; ownership is read from the positions lock entries wrote, never from a lock key alone. Enforced by `crates/core/tests/invariants.rs::invariant_6_never_touch_the_unowned` and `crates/core/tests/unmanaged_ownership.rs`.
7. Applies are transactional: preconditions revalidate against observed hashes right before mutation, pre-images are journaled first, a failure rolls back, an interrupted apply recovers on next launch, and removals go to a trash. Enforced by `crates/core/tests/invariants.rs::invariant_7_applies_are_transactional`, `crates/core/tests/migration.rs::an_interrupted_apply_rolls_the_whole_scope_back` and `crates/app/tests/recovery.rs`.
8. One writer per scope: every apply holds an OS-level scope lock, journal recovery runs under it, and a busy scope is an error. Enforced by `crates/core/tests/invariants.rs::invariant_8_one_writer_per_scope` for the refusal; recovery under the lock is not mechanically enforced.
9. kendex never stages, commits or resets in a repository it did not create; managed scopes are the only writable surface. Not mechanically enforced.
10. In-place edits are byte-faithful: an edit changes the keys it names and nothing else, newline included, and a file that cannot be read is refused. The one exception, a repositioned list entry losing keys the model does not carry, is stated in `crates/core/src/manifest/fold.rs`. Enforced by `crates/core/tests/byte_faithful.rs::every_config_edit_is_byte_stable_on_reapply`.
11. Validation precedes mutation: a rejected operation leaves manifest, lock and install tree byte-identical, and every rendering is read back through the target harness's own loader rules inside plan preview. Enforced by `crates/core/tests/byte_faithful.rs::a_refused_apply_leaves_every_surface_byte_identical` and `crates/core/src/render/validate/tests.rs`.
12. Verification compares content, not provenance: an artifact kendex cannot compare is reported uncompared, never as passing. Enforced by `crates/core/tests/byte_faithful.rs::an_unreadable_artifact_reports_uncompared_not_ok`; that a matching lock entry alone never reports OK is not mechanically enforced.
13. External processes are hardened by one constructor: redirecting git environment cleared, every prompt path closed, a timeout on every call, and work inside a cache pins `--git-dir` and `--work-tree`. Enforced by the raw `Command::new` lane in `tools/guard`, which scans `crates/core/src` and `crates/cli/src`, and by `crates/core/src/process/tests.rs`; the two sanctioned raw spawns in `crates/app` are named in `crates/app/AGENTS.md`.
14. An item is scored on its own bytes and nothing else; a repo-root skill's `.git`, `node_modules` and build directories are not its bytes, and distinct readings return in the order given. Enforced by `crates/core/src/source_read/tests.rs::a_repo_root_skill_excludes_vcs_and_dependency_dirs` and the tests in `crates/core/src/parallel.rs`.
15. An item's tags come from the closed vocabulary in `crates/core/src/tags.rs` and are never inferred from a name. Enforced by the tests in `crates/core/src/tags.rs`.
16. A debug build gets its own home under `<data>/kendex-dev`, drops inherited harness-root variables, and only `KENDEX_REAL_HOME=1` opts out. Enforced by the tests in `crates/core/src/env/sandbox.rs` and the fixture-home lane in `tools/guard`.
17. One spelling per path: a root is canonicalized on entry and never re-spelled, so no comparison meets two spellings. Enforced by the tests in `crates/core/src/paths.rs`, `crates/core/tests/symlinked_harness_dir.rs` and the `rooted()` lane in `tools/guard`.
18. Beside every tracked `AGENTS.md`, kendex writes and verifies a `CLAUDE.md` whose whole content is `@AGENTS.md`, and for the gemini harness it writes `context.fileName` into `.gemini/settings.json`; a missing, stale or symlinked shim is drift. Enforced by `crates/core/tests/instruction_shims.rs` and `crates/cli/tests/instruction_shims_cli.rs`.

## Decisions

- Stack: Tauri 2, React 19, Vite, Tailwind v4, shadcn/ui, zustand, tauri-specta, serde and toml.
- No database: manifests, locks and native directories are the state; scans are in-memory views; app preferences live in one settings file.
- No migration machinery: manifest and lock carry a format version, this build reads exactly the one it writes, and a file from another version is refused and left byte-for-byte. After the person moves an unreadable lock aside, `apply --record-existing` writes a current lock only when current source and every declared render match; it converts no old record.
- One spelling per artifact: `kendex.toml`, `.kendex-lock.json`, `.kendex-local/`, `kendex.settings.toml`, `KENDEX_*` variables; no older product name is read anywhere.
- App and CLI are equal thin shells over core; the only app-only operations are install-beside (`fork_beside`) and per-package update (`package::update_one`).
- A capability the harness lacks natively is marked unsupported, never shimmed; where a vendor stores one surface as another the table names the stored kind and the lock records what was written.
- Catalogs are adversarial input: reads are sealed and budgeted, frontmatter is real YAML with aliases and duplicate keys refused, and every interpolated value in a generated file is quoted.
- Two scores, safety and quality, are never averaged and are advisory everywhere: install, update and apply proceed regardless.
- Hook events have one vocabulary, Claude Code's names in `crates/core/src/hook.rs::EVENTS`; every other harness maps from it.
- Propagation into consuming repositories is local: kendex reports drift at session start and a local refresh brings the repo current; opening pull requests there is a permanent non-goal.
- Commits walk through the growth-guards package's committed scripts whatever tool makes them; kendex implements no check of its own and `kendex check` relays the package's verdict.
- kendex never emits a pasteable command line: errors, hints and recovery instructions present the verb and its parameters as data. The one exception is the session-start drift report, whose remedies come from a fixed template set with validated identifiers.
- The default catalog is `vanillagreencom/kendex`; subscriptions are matched by what a declaration names, never by literal spelling.
- The Linux app decides its display environment once, before GTK starts, by relaunching itself (`crates/app/src/launch_env.rs`); the environment is never rewritten in place because the workspace forbids `unsafe`.
- A `kendex://` link opens a marketplace or package as the Community tab opens a repository, a read writing no manifest: it comes from a web page (`crates/app/src/deep_link.rs`).

## Topics

- [engine.md](engine.md): read before changing planning, apply, locks, manifests, ownership, take-over or forks.
- [sources.md](sources.md): read before changing the source store, discovery, browsing, subscriptions, bundles, unsubscribe or the drift snapshot.
- [harnesses.md](harnesses.md): read before changing an adapter, the capability table, rendering, hook delivery or the Pi carrier.
- [scoring.md](scoring.md): read before changing a safety or quality rule.
- [updates.md](updates.md): read before changing the release feed, signing, digests or self-replace.
- [registry.md](registry.md): read before changing the community directory, sign-in or the skills.sh lead.
- [../adapters/README.md](../adapters/README.md): the per-harness on-disk facts, one page per harness; read when touching one adapter's paths or formats.
- [../authoring/README.md](../authoring/README.md): how a marketplace repository is laid out and checked; read when changing what a catalog may declare.
- [../DEVELOPMENT.md](../DEVELOPMENT.md): building from source and the debug sandbox.
- [../RELEASING.md](../RELEASING.md): cutting a release and what the workflow publishes.
