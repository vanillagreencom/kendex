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

## Source cache refresh

Remote sources are cloned under `~/.vstack/cache/`. Concurrency and process rules the user-facing docs deliberately omit:

- Fetching an existing cache is serialized by a per-cache lock that every writing command takes. The first clone creates the cache rather than mutating it, so it is not covered by that lock.
- `check` never fetches inline. A cache past its six-hour TTL is handed to a detached `vstack cache-refresh` that nobody waits on; its outcome is recorded and reported at the next session. `--offline` skips the handoff entirely.
- When the background refresh cannot even be spawned (a sandbox denying process creation, for instance), `check` reports it on its own line — informational, never drift.
- `vstack refresh` fetches synchronously and unbounded; only the background refresh and the wizard's startup fetch are bounded and credential-free.
- A `source` recorded anywhere in the cache SUBTREE (`vstack add ~/.vstack/cache/<entry>` is a supported invocation, and so is a subdirectory of one) is a remote source spelled as a path, and resolves as one — in `add` as well as in `refresh`, `check`, `verify` and `cache-refresh`. The remote comes from the entry's own `origin`: a cache key is derived from the repository identity and is not reversible, and one machine can hold `owner_repo` beside `owner_repo-<digest>` for a single repository. Resolution stays pinned to the entry the source named, and a path below an entry is read inside the tree that entry's fetch left behind; `add` at an entry root goes through the remote itself, because `add` is the one command that may mint the canonical clone. An entry whose remote cannot be established is refused rather than read as a local directory, everywhere — `cache-refresh` included, which reports it and exits nonzero. `refresh` rewrites an entry-root source to the remote spec once vstack's own entry for that remote is present and a fetch of it has returned `FetchAttempt::Updated`; `Ok` alone is not that answer, since a failed or unwritable attempt returns `Ok` too and leaves the clone where it was.

## Skill / Pi extension test surfaces

The CLI does not run skill or extension tests during ordinary commands. Each test surface lives next to the code it covers, except source-only cross-boundary installation checks, which stay in `scripts/integration-check.sh` so they are not shipped in an installed skill:

- Orch shell tests: [`../skills/orch/DEVELOPMENT.md#tests`](../skills/orch/DEVELOPMENT.md#tests)
- Dev shell tests: [`../skills/dev/README.md#tests`](../skills/dev/README.md#tests)
- Pi extension Bun tests: each `pi-extensions/<name>/tests/` directory
