# Orchestration development

Maintainer notes for the orch package: its runtime under `runtime/`, its scripts and its suites.

## Prerequisites

- What [README.md § Setup](README.md#setup) names. `orch-runtime ready` checks each and names the fix for one missing or refused.
- The suites run on Linux, and on macOS for the subset `tools/macos-test-contracts` selects, as CI runs them. A suite that reaches `orch-runtime` before `setup` built it fails on `orch-runtime: setup-required`.

## Build

```bash
skills/orch/scripts/setup                  # builds agent-runtime, then orch-runtime, into the user cache
skills/orch/scripts/orch-runtime --help    # every verb's contract
```

`setup` and the `orch-runtime` entry refuse when agent-runtime is not the sibling package beside orch.

## Stack

- **Language.** The runtime is two Rust crates, `orch-runtime` here and agent-runtime beside it, each its own Cargo workspace with a committed `Cargo.lock`. Revisit the language only for a demonstrated packaging or platform blocker.
- **Libraries.** Process I/O, waits, timers and cancellation run on Tokio inside agent-runtime; `orch-runtime` takes no Tokio dependency. Add a dependency only for a need the code has.
- **Storage.** Durable state is versioned local JSON: one record per item under `items/<ITEM>/` of the state directory, and one fleet record beside them, each written through agent-runtime's `record.rs`. Mailboxes are append-only JSONL files. The package has no database, server or event bus.
- **Interfaces.** Requests and results that cross an executable or a remote boundary are versioned JSON. Human diagnostics stay apart from machine output. Git, `gh`, the Linear client, tmux, SSH and each harness's own CLI stay external commands. Bash stays only for the entries § Shell that stays names, and JavaScript only where the host requires it. Model classes resolve through kendex's `tier-model`, never a table copied into the runtime.

## Tests

```bash
bash skills/orch/tests/run-all.sh
bash skills/orch/tests/run-all.sh lane-marker                 # suites whose name holds the fragment
bash skills/orch/tests/run-all.sh lane copilot                # either fragment
bash skills/orch/tests/run-all.sh '!lane' '!copilot'          # neither
bash skills/orch/tests/run-all.sh =lane-marker                # that suite alone
cargo test --manifest-path skills/orch/runtime/Cargo.toml     # the runtime's rows
```

The runner's header states every argument, CI's `--shard` among them. A set of fragments and that set negated split the battery: every suite runs in exactly one half.

The suites run from the catalog checkout. A kendex render leaves out `tests/` and this file.

- **Rust rows.** A row that runs the runtime's code in the test process starts with `support::isolated_row` (`tests/rust/support.rs`), so the runtime's git reads never see the operator's git configuration.
- **Shell suites.** Each `tests/*.sh` builds its own sandbox with stubs on `PATH`, prints `pass: N fail: M`, and exits 0 only when every assertion passed. `run-all.sh` finds the suites when it runs, so a new suite needs no registration. It runs them `nproc` at a time, so a suite keeps every file, socket and process it makes inside its own sandbox. A suite that holds a fixed wall-clock window a loaded host misses goes in `run-all.sh`'s `ALONE` list. A suite asserts through `tests/lib/assertions.sh` and defines none of its names. A shell wait runs on `tests/lib/virtual-clock.sh`, whose `date` and `sleep` stubs turn a poll budget into arithmetic over a file.
- **One job.** `tests/one_job.sh` runs whole repository jobs in a disposable consumer, on the real operations, with `tests/job/stub-harness` as the harness and fakes for the external services.
- **Hosts.** `tests/lane-host-ssh.sh` runs the static SSH provider in temporary git repositories behind an SSH transport stub. No suite proves live SSH connectivity.

Every shell suite carries this line directly under its `set -...o pipefail`. `tests/one_job.sh` is the exception: its `tests/job/one-job.sh` carries it.

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
```

A library under `tests/lib/` runs git in its suite's shell, so the library is cleared only where the suite sources `git-env.sh` first. `tests/git-env-isolation.test.sh` holds the line and the library case.

Run a probe that imports a Python fixture with `python3 -B`: a bytecode cache under the catalog becomes a render input.

## Effect boundary

In `skills/orch/runtime/`, run:

```bash
cargo clippy --all-targets -- -D warnings
```

`runtime/clippy.toml` lists the acting and reading primitives as disallowed methods outside `effects::lane_operation`; its header states the boundary. An allowance is one `#[allow(clippy::disallowed_methods, reason = "..")]` on a function, a trait impl's method or a test module. Its reason sits at the attribute, and review checks it with the change that adds it. A new acting function in agent-runtime joins the list, as `docs/architecture/orchestration.md` § Rules states. Before adding a guard, state the goal it serves and whom it guards against, and weigh its upkeep against the harm it prevents.

## Shell that stays

A file under `scripts/` stays only for one of these reasons. A file with none leaves.

- **It runs before the runtime is built.** `setup` and `orch-runtime`. `lane-marker` writes a lane's launch record; `lane-host-ssh`'s `create` runs it on a host before that host's runtime is built. `lib/lane-context.sh` holds the reads `lane-marker` and `copilot-statusline` share.
- **It moves the base.** `sync-base` and `resolve-base-branch`. `lane-host-ssh` runs the clone's own `sync-base` before the runtime exists there, and merge-pr's close-out runs it in the main checkout. `post-merge` runs `sync-base` in the base checkout; `post-merge --help` states its steps and modes. `base-freshness` reads the worktree skill's `lib/base-reading.sh`, the reading `worktree push` rebases by.
- **A provider is an executable.** `lane-host-ssh` follows the provider contract of [lane-host.md](schemas/lane-host.md). Its remote half runs on a host with no runtime.
- **The harness runs it by path.** `copilot-statusline`, the `statusLine` command of a Copilot CLI session, with `lib/copilot-session.sh`.
- **Workflow fences run it.** `git-context`, and `orch-env`, which reads a setting through the shared loader `lib/kendex-env.sh`.

Every shell file here follows two rules:

- A CLI that loads project configuration answers its help form before the load. A dry run reaches the parser twice, so an arm that returns may only assign, and an arm that prints must then exit. `tools/tests/help-inert.test.sh` holds it.
- A git call to GitHub names `origin` and runs through the github skill's `scripts/git-https-auth`. That script supplies a per-command HTTPS fallback for an SSH remote and persists nothing. Never enumerate remotes, as `git fetch --all --prune` does: another remote's SSH failure must not block the close-out.

## GitHub auth ladder

The ladder is the github skill's `scripts/gh-auth-ladder`; its library header states the steps. The runtime selects a credential through it in three places:

- `orch-runtime watch run` runs the ladder before its claim, and `orch-runtime report` before its first GitHub read (`reexec_with_github_auth` in `runtime/src/main.rs`). A ladder that selects nothing refuses the verb. On a refused sign-in the watch runs the ladder again (`install_sign_in` in `runtime/src/watch/github.rs`). A sign-in the watch cannot renew reaches the owner as an event ([oversee-events.md § `github-auth-failed`](references/oversee-events.md#github-auth-failed)).
- `orch-runtime validate` reads the base branch's required contexts under the pair the ladder selects for the worktree (`runtime/src/validate/mod.rs`).
- The `approve-head` request reads its token from the file `ORCH_OVERSEER_REVIEW_TOKEN_FILE` names.

The runtime's settings reader and the shell loader `scripts/lib/kendex-env.sh` read the private env file and the settings files as data, and never run them. Service-account setup for the `op` CLI is outside orch. A launcher may inject resolved secrets before it starts a harness, and the caller's environment outranks the project's `op://` references in every settings load.

## Debug

- `skills/orch/scripts/orch-runtime ready` prints each duty's readiness and the fix for an unready one. `--duty D` asks about one.
- A confined lane writes its checkout and, of the state directory, only its item's own folder `items/<ITEM>/` (`of` in `runtime/src/effects/grants.rs`). An overseer-owned act such a lane reaches leaves the act to the overseer and changes nothing.

## Harness update

A harness release can change what orch transcribed from the harness. Before a fleet runs on the release, re-check each transcription at its one home in agent-runtime:

- The permission words, and whether each grants a full bypass: `Harness::permission_spellings` in `runtime/src/harness.rs`, which the launch builder in `runtime/src/launch.rs` reads. A renamed or dropped word leaves a launch attended.
- The words that take the question tool away and turn compaction off: `Harness::question_off_words` and `Harness::compaction_off_words` in `runtime/src/harness.rs`.
- The Claude capacity table: `CLAUDE_CONTEXT_CAPACITY` in `runtime/src/harness.rs`. A model id with a measured window is an exact-id row ahead of its family word. An alias keeps the family's budget.
- The Codex rollout. `runtime/src/session.rs` binds a Codex session by `<home>/sessions/<year>/<month>/<day>/rollout-<stamp>-<session id>.jsonl`. `runtime/src/context.rs` reads the `token_count` event's `last_token_usage.total_tokens` and `model_context_window`, with the model the last `turn_context` names. A release that moves the rollout or renames the event leaves every Codex overseer's context unread, and the watch reports `overseer-context-unmeasured`.
- The session row shapes the hooks write: agent-runtime's `rows` writer.
- The three Claude prompt switches: `CLAUDE_BYPASS_ENV` in `runtime/src/launch.rs`. Where the catalog's `hooks/critical-path-deny.sh` is installed, the critical-path switch is inert and the hook refuses the removal with a rewrite. Where the hook is absent, the switch runs it. Neither case walls a lane.

Per-harness facts the skill text relies on, with their standing:

| Fact | Claude Code | Codex | Copilot CLI | Pi |
|---|---|---|---|---|
| A harness child a lane's tool starts inherits the lane's sign-in | not proven | not proven | not proven | not proven |

While a column reads not proven, the dev skill's § Long-Running Validation plans a lane without such a child and takes the harness's own subagent route for a second agent. A measured answer replaces the cell and this sentence together.
