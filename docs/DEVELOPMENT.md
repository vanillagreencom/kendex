# Developing kendex

For people and agents working on kendex itself. Installing and using it starts at the [README](../README.md). The invariants and layer boundaries are [architecture/overview.md](architecture/overview.md); each directory's local rules are its own `AGENTS.md`, indexed from the root `AGENTS.md` § Read next.

## Build

Rust at the version in `rust-toolchain.toml`, Node at the version in `.nvmrc`, and git 2.41 or newer.

```sh
cargo build --release -p kendex-cli                     # the kendex command
npm ci --prefix ui                                      # the UI, in the main checkout only
cd crates/app && ../../ui/node_modules/.bin/tauri dev   # the desktop app
```

A change to the Tauri command surface regenerates `ui/src/bindings.ts`; the command is in `crates/app/AGENTS.md`.

## The debug sandbox

A debug build keeps its own home at `<data>/kendex-dev` under the platform data directory, so a branch cannot leave lock records, harness files or caches the installed kendex will not read. Your global skills and agents are invisible to it and nothing it writes reaches them. It also drops the five inherited variables that would aim it back at a real harness root (`CODEX_HOME`, `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, `PI_CODING_AGENT_DIR`, `COPILOT_HOME`) and keeps `KENDEX_GIT_BASE`, `KENDEX_SOURCE_CACHE_KEEP`, `KENDEX_TRASH_KEEP_DAYS`, `KENDEX_TRASH_KEEP_MB` and `GEMINI_CLI_SYSTEM_SETTINGS_PATH`, which name a git host, a cache count, the trash's age and size bounds (`crates/core/src/trash.rs`) and a read-only policy file rather than a home. Sign-in credentials are separated the same way.

The boundary is the home, not the machine: a repository you point a debug build at is the real one, so `--scope project` reads and writes it, and programs kendex runs for you, `npm` among them, see your real home.

`KENDEX_REAL_HOME=1` opts a debug build onto the real home for deliberate dogfooding, and only that exact value does; the rule and its tests are `crates/core/src/env/sandbox.rs`.

```sh
KENDEX_REAL_HOME=1 cargo run -p kendex-cli --bin kendex -- list
```

## The `kendex://` scheme

The app registers the `kendex://` scheme for the binary it runs as on launch on Linux and Windows; macOS registration is the bundle's `Info.plist`, which the bundler writes from `tauri.conf.json`. A sandboxed debug build registers nothing, since the handler file and the mime default belong to the real machine and would point every link at a `target/` binary; `KENDEX_REAL_HOME=1` is the opt-in, and then the last build launched owns the scheme. On Linux the registration is `~/.local/share/applications/kendex-url-handler.desktop`, written by `crates/app/src/deep_link/linux.rs` with a bare `Exec=` path where the path allows one, because `xdg-open` cannot run the quoted one the deep-link plugin writes, plus an `xdg-mime` default; it needs `xdg-mime` and `update-desktop-database` on the path. Windows registration is the plugin's, under the current user's registry key.

```sh
xdg-open 'kendex://m/vanillagreencom/kendex/agent/generalist'   # Linux: reaches the running app, or launches it
```

On Linux a debug build and the installed app are two apps to the single-instance plugin, each on its own D-Bus name, whatever home either was launched onto. On Windows and macOS the plugin keys on the bundle identifier alone, so a debug build launched while the installed app runs hands its argv to that app and exits.

## Process fixtures

CLI and installer tests use `fixture_env` from `crates/test_util.rs` to set HOME and the XDG config, cache, and data directories from one fixture root. The helper disables the debug sandbox. Set an explicit test override after these defaults. HOME alone does not replace an inherited XDG directory. Production builds retain the platform's HOME and XDG behavior.

## The commit chain

`tools/setup`, once per clone, arms the commit-guards hooks. The chain and its order are `skills/commit-guards/DEVELOPMENT.md` § The pre-commit chain; its last lane is `tools/guard`, named by `COMMIT_GUARDS_PRE_COMMIT_LOCAL` in `kendex.settings.toml`. Read `tools/guard`: it is the list of repo-specific rules and of what it runs, and every rule a shipped package already judges is left to that package. Commit checks compile the changed Rust crates and check changed UI code. They do not run the test suites or documentation builds. The commit-msg line holds every commit-message rule.

`tools/guard` selects compilation from staged changes and checks worktree content. `tools/guard --full` runs the full Rust and UI checks, including tests, documentation builds and cross-target compilation, and the suites of every skill, hook, tool and Pi-package tree the branch touched, so completion validation covers what CI covers for the change. It also runs the decider skill's `decisions check`, which fetches the base branch and refuses a decision ID two records share, a base branch it could not fetch or read, or an INDEX row it could not parse; CI does not run it, and no change class stands it down. The documentation build and cross-target compilation are skipped when the change set shows the branch touched no crate, no workspace compiler input and no file compiled code includes; a change set that cannot show it, empty or read without a branch base, runs them. `GUARD_FULL_CROSS_DOC=ci` in `.env.local` or the environment leaves them to CI. It also parses every shipped shell tree with a real Bash 3.2, so on any host whose own `bash` is not 3.2 it needs docker or podman and refuses without one; `tools/tests/bash32-parse.test.sh` and `tools/tests/guard-full.test.sh` need the same. macOS needs neither, its `/bin/bash` being that shell. `DEV_VALIDATE_CMD` selects this full run at development completion, and `DEV_VALIDATE_TIMEOUT_SECS` bounds it at one hour. The runner sets `DEV_VALIDATE_CLASS`, `DEV_VALIDATE_DOCS_ONLY` and `DEV_VALIDATE_PATHS` from the classifier and its docs reader over one range, and the run keeps only the lanes `tools/ci-job-set` selects for CI from the same three inputs, its workspace test run limited to the crates that selection names. The runner's fallback when it cannot read a class, `standard` with no changed paths, runs every lane. `tools/guard --range BASE` is a review-fix round's run, which `DEV_VALIDATE_RANGE_CMD` selects: the default rules over the changes since `BASE`, working tree included, cargo check and clippy for the crates those changes touch, any non-Markdown file inside a crate included, or for the workspace where they touch a shared compiler input or a file compiled code includes, the UI checks and suite for a non-Markdown change under `ui/`, and the suites of the trees they touch, a Markdown file compiling nothing unless compiled code includes it and running no UI check, and none of what `--full` adds beyond that: the workspace test run, cross-target checks, the documentation build, the Bash 3.2 parse, the working-tree bot-instructions check, the decision-ID check, the cargo free-space floor and the class lane selection. Submit reuses the successful completion result for the same commit, and never a range result. CI independently runs the full checks. A skill's suite lives under `skills/<name>/tests/`, a Pi package's under its own `test` script, and `.github/workflows/skill-tests.yml` runs them on every pull request and in the merge queue.

`tools/harness-smoke` asks each of the eight harnesses, on its own listing or startup surface, whether a package kendex installed into a scratch project loaded, and reads a marker its fixture hooks, MCP server and Pi extension write when the harness starts them; one row per harness per kind that harness installs, with `unanswerable` and its reason where a harness or this machine has no surface. It also asks what reaches a lane when the fleet overseer sends it a directive: on a harness that runs the `lane-mail-check` hook the row sends the directive inside a one-turn lane session and passes only where the lane read it and the mailbox cursor moved, and on a harness that runs no hooks the row asks that harness's own listing for the wait-point instruction kendex rendered there and reports `advisory`. The `lane-mail-check` row of `hooks/README.md` decides which of the two a harness gets. It spends model turns on the harnesses that expose nothing else, so it is run by hand after a render change, never in CI.

## The self-install

This repository is a kendex project as well as the default catalog. `kendex.toml` is what the catalog publishes; `kendex-local.toml` is the manifest this checkout installs from, so the published file stays the definition. Every skill, agent and hook the repository uses is a render under `.agents/skills/`, `.claude/`, `.codex/` and `.pi/`, and a change to a source lands its render in the same commit; the rule is `skills/AGENTS.md`. The binary that applies or verifies this tree must be built from it first; the command is in the root `AGENTS.md` § Commands.

From a worktree, `kendex apply`, `kendex refresh` and `kendex verify --scope project` act on the shared main checkout, not the worktree, and delete its renders. In a worktree, sync a render by replaying the source diff onto it; test behaviour on fixture projects under `tmp/` (gitignored) or a temporary directory. A render no diff replays, such as a newly declared hook's registration in every harness settings file, comes from a scratch clone of the worktree: that clone is its own repository, so a debug build's `refresh --scope project` there writes only the clone, and the rendered files, the inventory and the lock entries the change owns are copied back.

## Review bot files

Edit `[bot-instructions]` in `kendex-local.toml`. The installed [bot-instructions skill](../skills/bot-instructions/SKILL.md) owns the root review section, the rendered `.github/instructions/code-review.md` that section points at, and the Copilot files. The commit guard checks their staged state; full validation checks their worktree state. CI runs the candidate's own checker against the candidate configuration and doctrine; the default-branch checker is the consumer rule.

Codex and Copilot retain their existing review capability. Other vendor capabilities are off because their settings are unconfirmed. Local checks prove generated file consistency, not vendor enablement, instruction loading, content exclusions, or automatic review settings. Confirm those through the [settings checklist](../skills/bot-instructions/references/checklist.md#the-settings).

Review carry-forward is disabled here. The current gate accepts configured bot or human evidence and does not require a human specifically for policy-file changes. Changes to review policy need a trusted human's approval under the package's adoption policy.
