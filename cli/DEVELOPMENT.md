# vstack CLI — development notes

Architecture, conventions, and per-harness translation rules live in [`AGENTS.md`](../AGENTS.md) (also exposed as `.claude/CLAUDE.md` via symlink).

## Build

```bash
cargo build
```

## Test

Unit + integration tests:

```bash
cargo test
```

Integration check — installs everything from this repo into a throwaway downstream project, verifies the printed `Scope:` line, refreshes twice, checks generated orch workflow byte identity and markdownlint plus generated dev workflow byte identity, then runs the refreshed installed dev cache-preflight regression and orch suite from an external working directory:

```bash
scripts/integration-check.sh
```

Do not validate by running `cargo run -- add .. --all --copy` from inside this checkout: `vstack add` resolves PROJECT scope by walking up from the current directory to the nearest project root, which is this checkout itself — so that command installs every item into the source working copy, not a temp dir.

## Skill / Pi extension test surfaces

The CLI does not run skill or extension tests during ordinary commands. Each test surface lives next to the code it covers, except source-only cross-boundary installation checks, which stay in `scripts/integration-check.sh` so they are not shipped in an installed skill:

- Orch shell tests: [`../skills/orch/DEVELOPMENT.md#tests`](../skills/orch/DEVELOPMENT.md#tests)
- Dev shell tests: [`../skills/dev/README.md#tests`](../skills/dev/README.md#tests)
- Pi extension Bun tests: each `pi-extensions/<name>/tests/` directory
