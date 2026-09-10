# crates/core/

Pure domain logic over the filesystem and git: no Tauri, no IPC, no UI concern, and no dependency on `crates/app`, `crates/cli` or `ui/`. The invariants and their enforcers are `docs/architecture/overview.md` § Invariants and the topic files beside it.

- One constructor builds every external process (`src/process/mod.rs`); a raw `Command::new` outside that module fails a `tools/guard` lane.
- Every catalog read goes through `source_read::SealedSource`; a raw filesystem read in a catalog-reading module fails a `tools/guard` lane.
- Every root hangs off `Env::home` (`src/env.rs`); a debug build roots at `<data>/kendex-dev` and only `KENDEX_REAL_HOME=1` opts out (`src/env/sandbox.rs`).
- A path is canonicalized on entry through `paths::canonical` (`src/paths.rs`) and never re-spelled; no comparison meets two spellings of one root. The one path that cannot be canonicalized is one that is not there, which is what a person names when a folder has moved: `paths::absolute` makes it absolute without resolving it, for matching a registry entry whose folder is gone, and nowhere else.
- A test that needs a host path reads it from `Env` (`host_rooted`, `drift_dir`), never composes the platform path.
- A test's temporary root takes its canonical spelling on the next source line through `rooted()` in `crates/test_util.rs`; a `tools/guard` lane checks new fixtures.
- A test that hands the binary a fixture `HOME` sets `KENDEX_REAL_HOME=1` on the next line, or the command runs in the dev sandbox; a `tools/guard` lane checks it.
- A test that shells out to git clears `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` together.
- `Op` writes its own `Debug` (`src/apply/op.rs`) so `WritePrivateFile` renders a byte count instead of the credential it carries; a `Plan` reaches assertion messages and panics, so restoring `#[derive(Debug)]` would put a person's API key in whatever formats one. Enforced by `tests/secret_storage.rs::a_plan_carrying_a_credential_never_renders_it`.
