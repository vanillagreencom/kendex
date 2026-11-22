# crates/core/

Pure domain logic over the filesystem and git: no Tauri, no IPC, no UI concern, and no dependency on `crates/app`, `crates/cli` or `ui/`. Before changing planning, dependencies or apply, read `docs/architecture/engine.md`.

- `unsafe` lives in three places in the workspace:
  - `src/fs/dacl.rs`: the Win32 security-descriptor calls behind the private credential file's owner-only access-control list.
  - The `acl` module of `src/fs/tests.rs`, which reads such a list back.
  - `crates/cli/src/ui/keys.rs::discard_typed_ahead`: the Win32 console input flush before a question.
- None of the three has a safe binding.
- Each of their functions allows `unsafe_code` per item with a reason.
- The workspace lint denies `unsafe_code` everywhere else.
- Review, not a guard lane, holds the boundary at those three sites.
- Every catalog read goes through `source_read::SealedSource`.
  - A raw filesystem read in a catalog-reading module fails a `tools/guard` lane.
- `Env` selects roots (`src/env.rs`). [The home override](../../DEVELOPMENT.md#home-override) gives the sandbox and portable roots.
- A path is canonicalized on entry through `paths::canonical` (`src/paths.rs`) and never re-spelled.
  - No comparison meets two spellings of one root.
  - Matching a registry entry whose folder has moved is the one exception, and `settings::recorded_entry` is the only place that makes it.
  - `paths::as_written` makes a path absolute by spelling alone and folds nothing. It serves the entry recorded under exactly that spelling.
  - `paths::absolute` resolves what is still there before it folds what is left. It serves the aliases a person types, and the settings location `settings::refuse_temporary` judges before the file exists.
  - Neither is used anywhere else.
- A test that needs a host path reads it from `Env` (`host_rooted`, `drift_dir`), never composes the platform path.
- A test's temporary root takes its canonical spelling on the next source line through `rooted()` in `crates/test_util.rs`.
  - A `tools/guard` lane checks new fixtures.
- A test that shells out to git clears `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` together.
- Project-write refusal and check-report destination rules are in `docs/architecture/in-place.md`.
- `Op` writes its own `Debug` (`src/apply/op.rs`), so `WritePrivateFile` renders a byte count instead of the credential it carries.
  - A `Plan` reaches assertion messages and panics, so restoring `#[derive(Debug)]` would put a person's API key in whatever formats one.
  - `tests/secret_storage.rs::a_plan_carrying_a_credential_never_renders_it` enforces this.
