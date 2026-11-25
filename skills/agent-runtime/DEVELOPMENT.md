# Agent runtime development

- Rust 1.96 or later.
- The crate at `runtime/` is its own Cargo workspace.
- Run every command below there.

## Build

```sh
cargo build                # a development binary at runtime/target/debug/agent-runtime
../scripts/setup           # the shipped route: a release build in the user cache, never in the tree
```

- To try setup without touching the real cache, point `AGENT_RUNTIME_CACHE` at a scratch folder.
- `../tests/setup/setup.sh` runs setup against the fake cargo beside it.
- `../scripts/setup --runtime DIR --name NAME` builds a dependent crate the same way, with the dependency's inputs in its key.
- orch's `scripts/setup` is that caller.
- Its suite is `skills/orch/tests/setup.sh`.

## Test

```sh
cargo test                        # the unit tests and every integration target
cargo test --test integration     # the process-protocol tests alone
cargo test record::               # one module's unit tests
```

- `runtime/Cargo.toml` sets `autotests = false`.
- Each integration target is a `[[test]]` row in `runtime/Cargo.toml` whose path is under `../tests/rust/`.
- Give a new integration file its own row.

## Capture a screen fixture

A screen fixture under `tests/rust/fixtures/` is a real pane capture, never a hand-drawn screen.

- Run the harness in a tmux pane of the width under test, on a private socket (`tmux -L NAME`).
- Give it a scratch `HOME`, XDG directories and `CLAUDE_CONFIG_DIR`.
- To draw a Claude API-error banner, point `ANTHROPIC_BASE_URL` at a local stub that answers `/v1/messages` with the error's status and JSON body, and set `ANTHROPIC_AUTH_TOKEN` to any value.
- Claude retries a 401 ten times before it draws the banner.
- Read the pane with `tmux capture-pane -p -N`, the row form `host::tmux::capture` reads.
- Replace a personal path in the capture with `/home/me/work`.

## Record versions

- A change that raises a record's `record_version` reads the previous version in the same change.
- The reader keeps that version in its `supported` list and reads its form, or converts the record to the new form at its first read.
- `record::split_meta` refuses a version outside `supported`, so a reader that drops the previous version refuses every record a running session wrote.
- A window in which every worker lands and every overseer switches at once is not a route for a record change.
- Add no conversion code before a version changes.
- The change that raises a version carries a test that reads a record written at the previous version.
- That test is the change's acceptance.

## Lint

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
```

## Effect boundary

- `clippy.toml` lists this crate's own acting functions as `disallowed-methods`.
- A call of one outside `effects` needs `#[allow(clippy::disallowed_methods, reason = "...")]` on the module, function, trait impl's method or test module that makes it.
- Review reads those attributes as the inventory.
- The list names no `std::process` call, so clippy passes a raw `std::process::Command` outside `effects`.
- Review catches that call, not clippy.
- Every external program starts through `runtime/src/host/mod.rs`:
  - A bounded call starts through `host::run_with` or another runner there, each of which counts the start and bounds the call.
  - A detached job starts through `host::start_detached`.
  - `process lead` becomes its program through `host::exec`.
