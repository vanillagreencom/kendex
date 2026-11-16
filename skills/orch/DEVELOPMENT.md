# Orchestration development

Maintainer notes for the orch package: its runtime under `runtime/`, its scripts and its suites. People using the package read [README.md](README.md); agents read [SKILL.md](SKILL.md). Why orchestration, session execution and messaging have separate owners: [docs/architecture/orchestration.md](../../docs/architecture/orchestration.md).

## Prerequisites

- Rust 1.96 or later with Cargo: both crates declare `rust-version = "1.96"` and edition 2024.
- On `PATH`: `tmux`, `git`, `setsid` and `gh`, with `jq` for the scripts, and Python 3 and `flock` for `lane-host-ssh` and its suite.
- On Linux, `bwrap` with unprivileged user namespaces, which a lane launch on Claude Code, Codex or Pi runs its harness under; `orch-runtime ready` names it, with the fix, where it is missing or refused.
- The suites run on Linux, and on macOS for the subset `tools/macos-test-contracts` selects, as CI runs them. A suite that reaches `orch-runtime` before `setup` built it fails on `orch-runtime: setup-required`.

## Build

```bash
skills/orch/scripts/setup                  # builds agent-runtime, then orch-runtime, into the user cache
skills/orch/scripts/orch-runtime --help    # every verb's contract
```

`setup` builds through agent-runtime's `scripts/setup`, keyed on both crates' sources, and prints `orch-runtime ready`'s lines on stderr once both builds stand. The `orch-runtime` entry runs only the binary built for the sources beside it: where that binary is absent it builds nothing, prints `orch-runtime: setup-required key=<key> run=<path to setup>` on stderr and exits 69. Both refuse with exit 2 when `agent-runtime` is not the sibling package beside orch.

## Stack

- **Language.** The runtime is Rust: two crates, `orch-runtime` here and agent-runtime beside it, each its own Cargo workspace with a committed `Cargo.lock`, built into native executables by `setup`. Rust gives explicit ownership of state and processes, operations shared in one process, and an executable a consumer builds from the shipped sources. Revisit the language only for a demonstrated packaging or platform blocker.
- **Libraries.** clap parses the commands, Serde and serde_json carry the typed records and the machine output, and thiserror names the error kinds. Process I/O, waits, timers and cancellation run on Tokio inside agent-runtime; `orch-runtime` itself takes no Tokio dependency. Add a dependency only for a need the code has.
- **Storage.** Durable state is versioned local JSON: one record per item under `items/<ITEM>/` of the state directory and one fleet record beside them. agent-runtime's `record.rs` writes each under one OS-backed writer lock per file, as a temporary file renamed over the target, after an explicit revision check. An operation records its intent before its effect starts and the observed outcome after it, and `orch-runtime reconcile` re-observes an open intent by its recorded identity: a file write does not make a process start, a delivery and a record update one transaction. Mailboxes are append-only JSONL files; logs, transcripts and artifacts are files named by identity. No database, server or event bus is part of the package.
- **Interfaces.** Requests and results crossing an executable or a remote boundary are versioned JSON; Rust types carry them inside the process, and human diagnostics stay apart from machine output. Git, `gh`, the Linear client, tmux, SSH and each harness's own CLI stay external commands at their package boundaries. Bash stays only for the entries `§ Shell that stays` names; JavaScript stays where the host requires it, such as the Copilot CLI context extension agent-runtime installs. Model classes resolve through kendex's `tier-model`, never a table copied into the runtime.

## Tests

```bash
bash skills/orch/tests/run-all.sh
bash skills/orch/tests/run-all.sh lane-marker                 # suites whose name holds the fragment
bash skills/orch/tests/run-all.sh lane copilot                # either fragment
bash skills/orch/tests/run-all.sh '!lane' '!copilot'          # neither
bash skills/orch/tests/run-all.sh =lane-marker                # that suite alone
cargo test --manifest-path skills/orch/runtime/Cargo.toml     # the runtime's rows
```

The runner's header states every argument, CI's `--shard` among them. A set of fragments and that set negated split the battery: every suite runs in exactly one half, and `tools/tests/orch-shard-partition.test.sh` holds that each suite lands in exactly one CI shard on Linux and macOS.

The suites run from the catalog checkout; a kendex render leaves out `tests/` and this file.

- **Rust rows.** The runtime's integration rows are the `[[test]]` targets `runtime/Cargo.toml` names under `tests/rust/`, beside the unit rows in `runtime/src/`. A row that runs the runtime's code in the test process starts with `support::isolated_row` (`tests/rust/support.rs`), which reruns it alone in a child of the test binary, so the runtime's git reads never see the operator's git configuration.
- **Shell suites.** Each `tests/*.sh` builds its own sandbox with stubs on `PATH`, prints `pass: N fail: M`, and exits 0 only when every assertion passed. `run-all.sh` finds the suites when it runs, so a new suite needs no registration, and runs them `nproc` at a time: a suite keeps every file, socket and process it makes inside its own sandbox. A suite holding a fixed wall-clock window that a loaded host misses goes in `run-all.sh`'s `ALONE` list. A suite asserts through `tests/lib/assertions.sh` and defines none of its names; `tests/assertions.test.sh` holds the library. A shell wait runs on `tests/lib/virtual-clock.sh`, whose `date` and `sleep` stubs turn a poll budget into arithmetic over a file.
- **One job.** `tests/one_job.sh` runs `tests/job/one-job.sh`: whole repository jobs in a disposable consumer, on the real operations, with `tests/job/stub-harness` as the harness and fakes for the external services.
- **Jobs.** The detached job runner is agent-runtime's `runtime/src/effects/job.rs`. The `launch-job` and `stop-job` answers a caller reads are held by `a_launched_job_runs_as_its_recorded_group_and_stop_job_ends_it_by_that_record` in `tests/rust/controller.rs`.
- **Hosts.** `tests/lane-host-ssh.sh` runs `tests/lib/lane-host-ssh-tests.py` against the static SSH provider, in temporary git repositories behind an SSH transport stub; no suite proves live SSH connectivity.
- **Secret pattern.** `tests/secret-value.test.sh` reads [references/secret-value.ere](references/secret-value.ere) by the reader contract in that file's header, and runs every row through both readers the header names.

Every shell suite carries this line directly under its `set -...o pipefail`, except `tests/one_job.sh`, whose `tests/job/one-job.sh` carries it:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
```

It clears `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE`, which outrank `git -C <path>`; a suite that inherited them would build its fixtures inside the caller's repository and still pass. A library under `tests/lib/` runs git in its suite's shell, so it is cleared only where the suite sources `git-env.sh` first. `tests/git-env-isolation.test.sh` holds both.

Run a probe that imports a Python fixture with `python3 -B`: a bytecode cache under the catalog becomes a render input.

## Effect boundary

The runtime is its own Cargo workspace. In `skills/orch/runtime/`, run:

```bash
cargo clippy --all-targets -- -D warnings
```

`runtime/clippy.toml` lists the acting and reading primitives as disallowed methods outside `effects::lane_operation`; its header states the boundary. An allowance is one `#[allow(clippy::disallowed_methods, reason = "..")]` on a function, a trait impl's method or a test module, its reason at the attribute, reviewed with the change that adds it. A new acting function in agent-runtime joins the list in the same change. Before adding a guard, state the goal it serves and whom it guards against, and weigh its upkeep against the harm it prevents.

## Shell that stays

The runtime owns every decision and every record write. A file under `scripts/` stays only for one of these reasons; a file with none leaves.

- **It runs before the runtime is built.** `setup` and `orch-runtime`. `lane-marker` writes a lane's launch record, which `lane-host-ssh`'s `create` runs on a host before its runtime is built; `lib/lane-context.sh` holds the reads `lane-marker` and `copilot-statusline` share.
- **It moves the base.** `sync-base` and `resolve-base-branch`: `lane-host-ssh` runs the clone's own `sync-base` before the runtime exists there, and merge-pr's close-out runs it in the main checkout. `post-merge` runs `sync-base`, the repository's command, `kendex refresh` and `kendex verify` in the base checkout, then `setup` for that checkout's own install; `post-merge --help` states its modes. `base-freshness` reads the worktree skill's `lib/base-reading.sh`, the reading `worktree push` rebases by.
- **A provider is an executable.** `lane-host-ssh`, by the provider contract of [lane-host.md](schemas/lane-host.md); its remote half runs on a host with no runtime.
- **The harness runs it by path.** `copilot-statusline`, the `statusLine` command of a Copilot CLI session, with `lib/copilot-session.sh`.
- **Workflow fences run it.** `orch-env`, which reads a setting through `lib/kendex-env.sh`, the shared loader, and `git-context`.

Two rules for every shell file here:

- A CLI that loads project configuration answers its help form before the load. A parser reached by a dry run runs twice, so an arm that returns may only assign, and an arm that prints must then exit. `tools/tests/help-inert.test.sh` holds it.
- A git call to GitHub names `origin` and runs through the github skill's `scripts/git-https-auth`, which supplies a per-command HTTPS fallback for an SSH remote and persists nothing. Never enumerate remotes, as `git fetch --all --prune` does: another remote's SSH failure must not block the close-out.

## GitHub auth ladder

The ladder is the github skill's `scripts/gh-auth-ladder`, whose library header states its steps. The runtime selects a credential through it in three places:

- `orch-runtime watch run` runs it before its claim, and `orch-runtime report` before its first GitHub read. Each then starts itself again in place under the selection with `--credential-selected` (`reexec_with_github_auth` in `runtime/src/main.rs`). A ladder that selects nothing refuses `auth-failed service=github`. The watch runs the ladder again on a refused sign-in, and its reads and the GitHub-reading children it starts take the renewed pair (`install_sign_in` in `runtime/src/watch/github.rs`); a sign-in it cannot renew reaches the owner as `github-auth-failed`.
- `orch-runtime validate` reads the base branch's required contexts under the pair the ladder selects for the worktree (`runtime/src/validate/mod.rs`).
- The `approve-head` request reads its token from the file `ORCH_OVERSEER_REVIEW_TOKEN_FILE` names.

The runtime's settings reader, and the shell loader `scripts/lib/kendex-env.sh`, read the private env file and the settings files as data and never run them. Service-account setup for the `op` CLI is outside orch: a launcher may inject resolved secrets before it starts a harness, and the caller's environment outranks the project's `op://` references in every settings load.

## Debug

- `skills/orch/scripts/orch-runtime ready` prints one line per duty, `ready duty=D` or `unready duty=D program=P cause=C fix=F`, and exits 1 where a duty asked about is unready; `--duty D` asks about one.
- A confined lane writes its checkout and only its item's own folder of the state directory, `items/<ITEM>/`; the rest of the state directory is read-only to it (`of` in `runtime/src/effects/grants.rs`). An act the overseer owns that such a lane reaches answers `<act>: left cause=confined owner=overseer`, exits 0 and changes nothing.

## Harness update

A harness release can change what orch transcribed from the harness. Before a fleet runs on the release, re-check each transcription at its one home in agent-runtime:

- The permission words and whether each grants a full bypass: `Harness::permission_spellings` in `runtime/src/harness.rs`, which the launch builder in `runtime/src/launch.rs` reads. A renamed or dropped word leaves a launch attended.
- The words that take the question tool away and turn compaction off: `Harness::question_off_words` and `Harness::compaction_off_words` in `runtime/src/harness.rs`.
- The Claude capacity table: `CLAUDE_CONTEXT_CAPACITY` in `runtime/src/harness.rs`. A model id with a measured window is an exact-id row ahead of its family word, and an alias keeps the family's budget.
- The Codex rollout: `runtime/src/session.rs` binds a Codex session by `<home>/sessions/<year>/<month>/<day>/rollout-<stamp>-<session id>.jsonl`, and `runtime/src/context.rs` reads the `token_count` event's `last_token_usage.total_tokens` and `model_context_window` with the model the last `turn_context` names. A release that moves the rollout or renames the event leaves every Codex overseer's context unread, which the watch reports as `overseer-context-unmeasured`.
- The session row shapes the hooks write: agent-runtime's `rows` writer.
- The three Claude prompt switches: `CLAUDE_BYPASS_ENV` in `runtime/src/launch.rs`. Where the catalog's `hooks/critical-path-deny.sh` is installed, the critical-path switch is inert and the hook refuses the removal with a rewrite; where it is absent, the switch runs it; a lane is walled in neither case.

Per-harness facts the skill text relies on, with their standing:

| Fact | Claude Code | Codex | Copilot CLI | Pi |
|---|---|---|---|---|
| A harness child a lane's tool starts inherits the lane's sign-in | not proven | not proven | not proven | not proven |

While a column reads not proven, the dev skill's § Long-Running Validation plans a lane without such a child and takes the harness's own subagent route for a second agent. A measured answer replaces the cell and that sentence together.
