# Agent runtime development

Rust 1.96 or later. The crate at `runtime/` is its own Cargo workspace; every command below runs there.

## Build

```sh
cargo build                # a development binary at runtime/target/debug/agent-runtime
../scripts/setup           # the shipped route: a release build in the user cache, never in the tree
```

`cargo build` and `cargo test` here write to `runtime/target/`, which `.gitignore` excludes and no render carries. The shipped route never writes there: `scripts/setup` builds into `$AGENT_RUNTIME_CACHE`, else `$XDG_CACHE_HOME/kendex/agent-runtime`, else `~/.cache/kendex/agent-runtime`, keyed by `scripts/lib/key.sh`. Point `AGENT_RUNTIME_CACHE` at a scratch directory to try setup without touching the real cache; `../tests/setup/setup.sh` runs it against a fake cargo. `../scripts/setup --runtime DIR --name NAME` builds a dependent crate the same way, at `<cache>/bin/NAME-<key>` with the key covering the dependency's inputs too; orch's `scripts/setup` is that caller, and its suite is `skills/orch/tests/setup.sh`.

## Test

```sh
cargo test                        # the unit tests and the integration harness
cargo test --test integration     # the process-protocol tests alone
cargo test record::               # one module's unit tests
```

`autotests = false`: the one integration harness is `../tests/rust/main.rs`, named by `[[test]] path` so the package's top-level `tests/` stays out of renders. A new integration test goes in that file, or in a new `[[test]]` row whose path sits above `runtime/`. The harness runs the built binary through `CARGO_BIN_EXE_agent-runtime`.

## Native probe

```sh
../tests/native/thin-path.sh --harness claude --out ../../../tmp/native/run1
```

The probe starts a real session per harness in a disposable home on a private tmux server, hands it work after its first turn, stops it exactly and writes `DIR/<harness>.json`. It copies the operator's login from the harness's own home and spends real model turns on that account. Run it only when a person authorizes the spend; nothing in CI calls it. It needs the harness, tmux, jq and git on `PATH`, and builds the debug binary when it is absent.

## Lint

```sh
cargo fmt --check
cargo clippy --all-targets
```

Clippy denies `println!` and `eprintln!`: the one stdout line is the reply and the stderr lines are the refusal, both written in `main`.

## Permission spellings

`Harness::permission_spellings` in `runtime/src/harness.rs` is a transcription of the sixth and seventh columns of orch's launch table in `skills/orch/scripts/lib/lane-launch.sh` and changes with them; no test compares the two.
