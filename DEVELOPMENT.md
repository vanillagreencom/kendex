# Developing kendex

For people and agents working on kendex itself. Using it starts at the [README](README.md); each directory's rules are its own `AGENTS.md`, listed in the root `AGENTS.md` § Read when.

## Build

Rust at the version in `rust-toolchain.toml`, Node at the version in `.nvmrc`, and git 2.41 or newer.

```sh
cargo build --release -p kendex-cli                     # the kendex command
npm ci --prefix ui                                      # the UI, in the main checkout only
cd crates/app && ../../ui/node_modules/.bin/tauri dev   # the desktop app against this checkout
```

A change to the Tauri command surface regenerates `ui/src/bindings.ts`; the command is in `crates/app/AGENTS.md`. The binary that applies or verifies this tree is built from it first, with the self-install command in the root `AGENTS.md` § Commands.

## Test

```sh
cargo test                                  # the Rust suites; a crate's integration tests are one harness, tests/main.rs
npm test --prefix ui                        # the UI suites
npm run check --prefix ui                   # types and lint
skills/<name>/tests/<suite>.test.sh         # one shell suite, run directly
tools/guard --full                          # the local full battery: Rust and UI checks with tests, plus the suites a change reaches
```

`tools/guard --full` runs the Rust and UI checks with tests, documentation builds and cross-target compilation, the suites a touched skill's or `hooks/`' changed files map to, the suites of every tool and Pi-package tree the branch touched, and the decider skill's `decisions check`, which CI does not run. The documentation build and the cross-target compilation are skipped when the branch touched no crate; `GUARD_FULL_CROSS_DOC=ci` in `.env.local` or the environment leaves them to CI. The Bash 3.2 parse needs docker or podman on a host whose own `bash` is not 3.2, and refuses without one.

`tools/harness-smoke` asks each harness on the machine, through its own listing or startup surface, whether a package kendex installed into a scratch project loaded, and what reaches a lane sent a directive: one row per harness per kind, `unanswerable` with its reason where a harness or this machine has no surface. Which rows a harness gets follows each hook's answer for that harness in `kendex index --json` on this checkout. It writes nothing to the repository.

## Debug

A debug build keeps its own home at `<data>/kendex-dev` under the platform data directory, so a branch cannot leave lock records, harness files or caches the installed kendex will not read. Your global skills and agents are invisible to it and nothing it writes reaches them. It drops the inherited variables that would aim it back at a real harness root and keeps the ones that name a git host, a cache count, the trash's bounds or a read-only policy file; the list is `crates/core/src/env/sandbox.rs`. Sign-in credentials are separated the same way.

The boundary is the home, not the machine: a repository you point a debug build at is the real one, so `--scope project` reads and writes it, and programs kendex runs for you, `npm` among them, see your real home.

```sh
cargo run -p kendex-cli --bin kendex -- list                      # against the debug sandbox
KENDEX_REAL_HOME=1 cargo run -p kendex-cli --bin kendex -- list   # against your real setup
```

### Home override

`KENDEX_REAL_HOME` is the portable-install and test hook on every platform, unset by default. An absolute path selects that home before any operating-system directory lookup and disables the debug sandbox; kendex puts its config, cache and data directories under that home in the host platform's layout, and an explicit harness-root variable still selects its own harness directory. The value `1` uses the system directories and disables the debug sandbox for deliberate dogfooding. Unset, empty and other non-absolute values keep normal platform discovery and the debug sandbox's default. Release builds have no debug sandbox. The rule is `crates/core/src/env/sandbox.rs`.

### The `kendex://` scheme

The app registers the `kendex://` scheme for the binary it runs as on launch on Linux and Windows; macOS registration is the bundle's `Info.plist`. A sandboxed debug build registers nothing, since the handler file and the mime default belong to the real machine and would point every link at a `target/` binary. With a home override, the last build launched owns the scheme. On Linux the registration is the desktop file `crates/app/src/deep_link/linux.rs` writes plus an `xdg-mime` default, and needs `xdg-mime` and `update-desktop-database` on the path.

```sh
xdg-open 'kendex://m/vanillagreencom/kendex/agent/maintainer'   # Linux: reaches the running app, or launches it
```

On Linux a debug build and the installed app are two apps to the single-instance plugin, each on its own D-Bus name. On Windows and macOS the plugin keys on the bundle identifier alone, so a debug build launched while the installed app runs hands its argv to that app and exits.

## The commit chain

`tools/setup`, once per clone, arms the commit-guards hooks. The chain and its order are `skills/commit-guards/DEVELOPMENT.md` § The pre-commit chain; its last lane is `tools/guard`, named by `COMMIT_GUARDS_PRE_COMMIT_LOCAL` in `kendex.settings.toml`. Read `tools/guard`: it is the list of repo-specific rules, and every rule a shipped package already judges is left to that package. Commit checks compile the changed Rust crates and check changed UI code; they do not run the test suites or documentation builds. The commit-msg hook holds every commit-message rule.

## The self-install

This repository is a kendex project as well as the default catalog. `kendex.toml` is what the catalog publishes; `kendex-local.toml` is the manifest this checkout installs from, so the published file stays the definition. Every skill, agent and hook the repository uses is a render under `.agents/skills/`, `.claude/`, `.codex/` and `.pi/`, and a change to a source lands its render in the same commit; the rule is `skills/AGENTS.md`.

A linked worktree carries its own `kendex-local.toml`, so a bare `kendex apply` or `kendex refresh` typed there writes that worktree, under `docs/architecture/in-place.md`. A refresh there re-renders every package from the branch's catalog, which is the release's write and not a change's: in a worktree, sync a render by replaying the source diff onto it, and test behaviour on fixture projects under `tmp/` or a temporary directory. A render no diff replays, such as a newly declared hook's registration in every harness settings file, comes from a scratch clone of the worktree: a debug build's `refresh --scope project` there writes only the clone, and the rendered files and the inventory are copied back. In a lane worktree that refresh refuses with `lane-refresh: item=`; write the registration by hand beside its neighbours, and a debug build's `apply --plan --scope project` in the worktree then plans no write but the install record.

## Packaging

`cd crates/app && ../../ui/node_modules/.bin/tauri build` bundles deb and rpm anywhere; the AppImage step needs FUSE2 for linuxdeploy. Bundling signs updater artifacts, so set `TAURI_SIGNING_PRIVATE_KEY` or pass `--no-sign`.

The command inside each installer comes from an overlay under `crates/app/release/`, one per platform, passed as `--config release/<platform>.json`; each reads the command staged under `target/bundle-cli/`. To bundle with the command locally: `cargo build --release -p kendex-cli`, copy `target/release/kendex` to `target/bundle-cli/kendex`, then `../../ui/node_modules/.bin/tauri build --bundles deb,rpm --no-sign --config release/linux.json` from `crates/app`.

## Release

Cutting a release is the app-deploy skill, `.agents/skills/app-deploy/SKILL.md`; the package-manager recipes are `packaging/README.md`.
