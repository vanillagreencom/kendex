# crates/core/

Pure domain logic over the filesystem and git: no Tauri, no IPC, no UI concern, and no dependency on `crates/app`, `crates/cli` or `ui/`. The invariants and their enforcers are `docs/architecture/overview.md` § Invariants and the topic files beside it.

- One constructor builds every external process (`src/process/mod.rs`); a raw `Command::new` outside that module fails a `tools/guard` lane.
- Every catalog read goes through `source_read::SealedSource`; a raw filesystem read in a catalog-reading module fails a `tools/guard` lane.
- Every root hangs off `Env::home` (`src/env.rs`); a debug build roots at `<data>/kendex-dev` and only `KENDEX_REAL_HOME=1` opts out (`src/env/sandbox.rs`).
- A path is canonicalized on entry through `paths::canonical` (`src/paths.rs`) and never re-spelled; no comparison meets two spellings of one root.
- A test that needs a host path reads it from `Env` (`host_rooted`, `drift_dir`), never composes the platform path.
- A test's temporary root takes its canonical spelling on the next source line through `rooted()` in `crates/test_util.rs`; a `tools/guard` lane checks new fixtures.
- A test that hands the binary a fixture `HOME` sets `KENDEX_REAL_HOME=1` on the next line, or the command runs in the dev sandbox; a `tools/guard` lane checks it.
- A test that shells out to git clears `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` together.
