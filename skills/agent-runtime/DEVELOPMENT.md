# Agent runtime development

Rust 1.96 or later. The crate at `runtime/` is its own Cargo workspace; every command below runs there.

## Build

```sh
cargo build                # a development binary at runtime/target/debug/agent-runtime
../scripts/setup           # the shipped route: a release build in the user cache, never in the tree
```

`cargo build` and `cargo test` write to `runtime/target/`, which `.gitignore` excludes and no render carries. `scripts/setup` builds into the cache its `--help` names, keyed by `scripts/lib/key.sh`. Point `AGENT_RUNTIME_CACHE` at a scratch folder to try setup without touching the real cache. `../tests/setup/setup.sh` runs setup against the fake cargo beside it.

`../scripts/setup --runtime DIR --name NAME` builds a dependent crate the same way, keyed over the dependency's inputs too. orch's `scripts/setup` is that caller, and its suite is `skills/orch/tests/setup.sh`.

## Test

```sh
cargo test                        # the unit tests and every integration target
cargo test --test integration     # the process-protocol tests alone
cargo test record::               # one module's unit tests
```

`runtime/Cargo.toml` sets `autotests = false`, so the package's top-level `tests/` stays out of renders. Each integration target is a `[[test]]` row whose path sits under `../tests/rust/`: `integration` (`main.rs`), `accounts`, `walk`, `controller` and `session`. A new integration file takes its own row. The targets run the built binary through `CARGO_BIN_EXE_agent-runtime`.

## Lint

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
```

- `Cargo.toml` denies `print_stdout` and `print_stderr`: the one stdout line is the reply and the stderr lines are the refusal, both written in `main`.
- `clippy.toml` lists the acting primitives as `disallowed-methods`. A call of one outside `effects` needs `#[allow(clippy::disallowed_methods, reason = "...")]` at the call's module, function or test module, and that attribute is the review's inventory.
