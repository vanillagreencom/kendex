# vstack CLI

Rust CLI that installs vstack skills, agents, hooks, and Pi extensions into Claude Code, Cursor, OpenCode, Codex, and Pi.

Architecture, conventions, and per-harness translation rules live in [`AGENTS.md`](../AGENTS.md) (also exposed as `.claude/CLAUDE.md` via symlink). This file documents how to build and test the CLI itself.

## Build

```bash
cargo build
```

## Test

Unit + integration tests:

```bash
cargo test
```

Integration check — installs everything from this repo into a throwaway temp project and verifies the printed `Scope:` line points there:

```bash
scripts/integration-check.sh
```

Do not validate by running `cargo run -- add .. --all --copy` from inside this checkout: `vstack add` resolves PROJECT scope by walking up from the current directory to the nearest project root, which is this checkout itself — so that command installs every item into the source working copy, not a temp dir.

## Skill / Pi extension test surfaces

The CLI does not run skill or extension tests. Each test surface lives next to the code it covers:

- Orch shell tests: [`../skills/orch/DEVELOPMENT.md#tests`](../skills/orch/DEVELOPMENT.md#tests)
- Pi extension Bun tests: each `pi-extensions/<name>/tests/` directory
