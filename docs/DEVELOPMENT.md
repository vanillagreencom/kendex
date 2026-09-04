# Developing kendex

For people and agents working on kendex itself. Installing and using it starts at the [README](../README.md). The invariants and layer boundaries are [architecture/overview.md](architecture/overview.md); each directory's local rules are its own `AGENTS.md`, indexed from the root `AGENTS.md` § Read next.

## Build

Rust at the version in `rust-toolchain.toml`, Node at the version in `.nvmrc`, and git 2.41 or newer, the first git that takes `--attr-source`, which is how kendex materializes a catalog checkout.

```sh
cargo build --release -p kendex-cli                     # the kendex command
npm ci --prefix ui                                      # the UI, in the main checkout only
cd crates/app && ../../ui/node_modules/.bin/tauri dev   # the desktop app
```

A change to the Tauri command surface regenerates `ui/src/bindings.ts`; the command is in `crates/app/AGENTS.md`.

## The debug sandbox

A debug build keeps its own home at `<data>/kendex-dev` under the platform data directory, so a branch cannot leave lock records, harness files or caches the installed kendex will not read. Your global skills and agents are invisible to it and nothing it writes reaches them. It also drops the five inherited variables that would aim it back at a real harness root (`CODEX_HOME`, `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, `PI_CODING_AGENT_DIR`, `COPILOT_HOME`) and keeps `KENDEX_GIT_BASE` and `GEMINI_CLI_SYSTEM_SETTINGS_PATH`, which name a git host and a read-only policy file rather than a home. Sign-in credentials are separated the same way.

The boundary is the home, not the machine: a repository you point a debug build at is the real one, so `--scope project` reads and writes it, and programs kendex runs for you, `npm` among them, see your real home.

`KENDEX_REAL_HOME=1` opts a debug build onto the real home for deliberate dogfooding, and only that exact value does; the rule and its tests are `crates/core/src/env/sandbox.rs`.

```sh
KENDEX_REAL_HOME=1 cargo run -p kendex-cli --bin kendex -- list
```

## The commit chain

`tools/setup`, once per clone, arms the growth-guards hooks. The chain and its order are `skills/growth-guards/DEVELOPMENT.md` § The pre-commit chain; its last lane is `tools/guard`, named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL` in `kendex.settings.toml`. Read `tools/guard`: it is the list of repo-specific rules and of what it runs, and every rule a shipped package already judges is left to that package. Every commit is slow because the guard runs the whole test surface; batch work into few commits. The commit-msg line holds every commit-message rule.

`tools/guard` by hand judges the working tree, not the index. A skill's suite lives under `skills/<name>/tests/`, a Pi package's under its own `test` script, and `.github/workflows/skill-tests.yml` runs them on every pull request and in the merge queue.

## The self-install

This repository is a kendex project as well as the default catalog. `kendex.toml` is what the catalog publishes; `kendex-local.toml` is the manifest this checkout installs from, so the published file stays the definition. Every skill, agent and hook the repository uses is a render under `.agents/skills/`, `.claude/`, `.codex/` and `.pi/`, and a change to a source lands its render in the same commit; the rule is `skills/AGENTS.md`. The binary that applies or verifies this tree must be built from it first; the command is in the root `AGENTS.md` § Commands.

From a worktree, `kendex apply`, `kendex refresh` and `kendex verify --scope project` act on the shared main checkout, not the worktree, and delete its renders. In a worktree, sync a render by replaying the source diff onto it; test behaviour on fixture projects under `tmp/` (gitignored) or a temporary directory.
