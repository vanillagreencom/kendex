# Orchestration development

Maintainer notes. Consumer docs: [README.md](README.md); the agent contract: [SKILL.md](SKILL.md).

## Tests

```bash
bash skills/orch/tests/run-all.sh
bash skills/orch/tests/run-all.sh lane-host   # subset by name fragment
bash skills/orch/tests/run-all.sh open-terminal oversee       # either fragment
bash skills/orch/tests/run-all.sh '!open-terminal' '!oversee' # neither
bash skills/orch/tests/run-all.sh =lanes                     # that suite alone
cargo test --manifest-path skills/orch/runtime/Cargo.toml    # the runtime's rows
```

A bare argument selects and `!name` rejects; `=name` in either place matches one whole suite name, the form `tools/guard --range` passes for the suites a diff maps to. A set of fragments and that set negated split the battery: no suite runs in both halves and none runs in neither. CI passes `--shard` instead, and `run-all.sh`'s `shard_of` gives each suite its shard by name, by `RUNNER_OS`.

The tests run from the catalog checkout: a kendex render leaves out the top-level `tests/` and this file. The runtime's Rust rows are the `[[test]]` targets `runtime/Cargo.toml` names by path under `tests/rust/`, beside the unit rows in `runtime/src/`. `tests/job/one-job.sh`, run through `tests/one_job.sh`, runs whole repository jobs in a disposable consumer on the real operations, with `tests/job/stub-harness` as the harness and fakes for the external services. Byte identity and idempotence of what an apply writes are covered in `crates/core/tests/byte_faithful.rs`.

Each shell suite is self-contained: it builds its own sandbox with parametrized CLI stubs on `PATH`, prints `pass: N fail: M`, and exits 0 only when every assertion passed. `run-all.sh` discovers `tests/*.sh` at execution time, so a new suite needs no registration. It runs them `nproc` at a time, so a suite keeps every file, socket and process it makes inside its own sandbox. A suite that holds a fixed wall-clock window a loaded host makes it miss goes in `run-all.sh`'s `ALONE` list and runs by itself after the others. The `run-all.sh` header states the report it prints, and `tests/run-all-parallel.sh` holds it.

A shell suite asserts through `lib/assertions.sh`, sourced directly or through a fixture library under `tests/lib/`, and defines none of its names. `tests/assertions.test.sh` holds the library, judging without it. `lane-host.sh`, `lane-host-ssh.sh` and `lanes-normalized.sh` run Python suites under `tests/lib/`.

Every suite carries one line directly under its `set -...o pipefail`:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
```

That lib clears the four git environment variables, so a new suite adds the line rather than its own `unset`. `tests/one_job.sh` only runs `tests/job/one-job.sh`, which carries the line.

Run probes that import Python fixtures with `python3 -B`. Bytecode caches under the catalog become render inputs.

## Invariants the tests pin

- Relaunch ownership comes from the lane record's bound session and the home its last confirmed launch recorded, never kickoff text. The relaunch route, `relaunch_route` in `runtime/src/effects/launch.rs`, resumes a session only by its fixed id, under the same harness and account, and otherwise starts fresh and names its cause. Agent-runtime's `session::resume_owner` reads the directory the session's own file records, so a session another directory owns refuses as `session-owned-elsewhere`. `tests/rust/effects.rs` holds the account switch and the same account's resume. `open-terminal --wake` finds a Claude lane's session through `find_relaunch_session` in `scripts/lib/lane-relaunch.sh`: the newest lead transcript whose recorded working directory is the item's worktree.
- Round-id identity. Every dev and QA delegation mints a token through the runtime's `begin-round` (a nanosecond timestamp plus a random suffix) and embeds it. `orch-runtime dev-return write --round-id RID` writes `tmp/dev-return-[ISSUE]-[RID].json` with `round_id` inside, and `dev-return check --round-id RID` selects that round's receipt and answers `invalid` where the token inside differs. There is one identity model, no mtime gate and no positional mode, so a same-second re-stamp, a late-writing timed-out agent, a bundle group-A receipt consumed by group-B, and a cross-round ci-fix receipt are all unmatchable. `dev_delegated_at` is the epoch second of the round's delegation; [references/skill-rules.md § Round Closure](references/skill-rules.md#round-closure) owns its uses. Gate ordering and field rules: [references/artifact-checks.md](references/artifact-checks.md); schemas in [schemas/](schemas/).
- Help is inert. Every orch shell CLI that loads project configuration answers a help form before the load. A parser reached by a dry run runs twice, so an arm that returns may only assign; an arm that prints must then exit. `tools/tests/help-inert.test.sh` holds it, with its own must-fail controls.
- Inherited git environment. `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` outrank `git -C <path>`, so a suite that inherits them builds its fixtures inside the caller's repository and still reports a clean pass. `lib/git-env.sh` clears all four at load. `git-env-isolation.test.sh` holds both halves: it runs `resolve-base-branch.sh` with all four exported at a sandbox repository and pins that repository's log and index unchanged, then repeats the run against a copied tree whose lib is neutralized to prove the clearing is what holds it.
- Sourced libs inherit that clearing. A lib under `tests/lib/` that runs git is sandboxed only because the suite that sourced it sourced `lib/git-env.sh` first. A lib added here rests on that precondition.
- Shard coverage. CI runs the battery as shards, and a shard that stopped claiming its suites would drop them out of every shard while every shard stayed green. `tools/tests/orch-shard-partition.test.sh` reads the shard calls out of `.github/workflows/skill-tests.yml`, replays them over the real suite names on Linux and macOS, and requires each suite in exactly one shard; its controls drop a shard and repeat a shard.
- Controls. `lanes-settings-refusal.sh` plants no must-fail control, so re-run it against the pre-fix `lanes` when changing what it covers.
- Waits. `tests/rust/verify.rs` drives `verify-review` and `verify-pr` through the built binary against a fixture `gh`, which holds the review request a head owes. `tests/rust/queue_watch.rs` drives `queue-watch`'s poll loop on the runtime's fake clock, so a deadline case cannot race a loaded runner. The kept shell waits, such as the mailbox skill's `lane-mail.sh` rows and `lanes.sh`, run on `tests/lib/virtual-clock.sh`, whose `date` and `sleep` stubs make a poll budget arithmetic over a file rather than real seconds. Which repository a shell script reads is `scripts/lib/gh-repo.sh`'s ladder, held by `gh-repo-resolve.test.sh`.
- Detached job completion. The runtime's job runner is `runtime/src/effects/operation/job.rs`, whose rows hold its launch, record and stop. `job_unit.sh` holds the shell job runner `scripts/lib/job-unit.sh`. `codex_round_wait.sh` executes the launch script from [Waiter launch](references/waiter-launch.md) against the shipped dev and reviewer artifact checkers and reads the recorded exit.
- Secret-value pattern. `secret-value.test.sh` reads [references/secret-value.ere](references/secret-value.ere) by the reader contract in its header and runs every row through both readers the header names, `grep -aiE` in the C locale and Python's `re` with `re.I | re.M`; each row needs its verdict from both. Its control removes the `xapp-` branch and requires an app token to pass.

## Effect boundary

The runtime at `runtime/` is its own Cargo workspace; run `cargo clippy --all-targets -- -D warnings` there. Its `clippy.toml` lists the tmux, process, session, job, store, clock, wait and file primitives as disallowed methods, so that command refuses an ordinary call of one outside `src/effects/operation/` and the functions that carry an allowance. The list guards against an accidental call past the operation handle; a deliberate bypass is a code-review matter, never the list's. An allowance is one `#[allow(clippy::disallowed_methods, reason = "..")]` on a function, a trait impl's method, a test module or `mod operation`, its reason at the attribute, reviewed with the change that adds it; the inventory is those attributes. A new acting function in agent-runtime joins the list in the same change. Before building a guard here, state the goal it serves and who it is against, weigh its upkeep against the harm it prevents, and treat a constructed bypass as a defect only when ordinary code reaches it.

## GitHub auth ladder

The ladder is the github skill's: `scripts/gh-auth-ladder` over its `scripts/lib/gh-auth.sh`, whose header states the steps. Every GitHub read the runtime makes goes through one handle, `verify::Gh` in `runtime/src/verify/mod.rs`, which uses its process's environment or the credential pair a caller hands it, and never reads a credential itself. Three runtime callers select that credential through the ladder:

- `orch-runtime watch run` runs the ladder once before its claim, and `orch-runtime report` before its first GitHub read. Each then starts itself again in place under the ladder's selection with `--credential-selected` (`reexec_with_github_auth` in `runtime/src/main.rs`), so its `gh` children inherit the selected token. A ladder that selects nothing refuses as `auth-failed service=github`.
- `orch-runtime validate` reads the base branch's required contexts under the pair the ladder prints for the worktree (`runtime/src/validate/mod.rs`).
- The `approve-head` request reads its token from the file `ORCH_OVERSEER_REVIEW_TOKEN_FILE` names (`runtime/src/ops/approve.rs`).

The runtime's settings reader (`runtime/src/settings.rs`) reads the private env file and the settings files as data and never runs them. The shell entries and the `github.sh` router load them through `lib/kendex-env.sh`, the shared loader each package carries, which sources the private env file. The shell entries `oversee-report` and `overseer-approve` select a credential through `scripts/lib/gh-auth.sh`, orch's wrapper over the github skill's helpers. The `github.sh` router prefers a resolved `GH_BOT_TOKEN` over a resolved `GITHUB_TOKEN` (`github.sh --help` § Token selection).

`op` CLI service-account setup is outside orch: launchers may inject resolved secrets before starting a harness, and the caller's environment outranks the project's `op://` references in every settings load.

## Git HTTPS fallback

Merge and submit workflows use targeted `origin` operations through the github skill's `scripts/git-https-auth` rather than broad remote enumeration. The helper is a per-command fallback for SSH-backed GitHub remotes: it validates env-token or keyring `gh` auth, then supplies temporary `credential.helper` and `url.insteadOf` config so GitHub SSH URLs work over HTTPS. It persists nothing. Never use `git fetch --all --prune` for PR closure: a secondary remote's SSH failure must not block branch cleanup or tracker closure.

## Reviewer slot budget

`REVIEWER_SLOT_BUDGET` bounds reviewer fanout for harnesses that cap concurrent agent threads; [references/settings.md](references/settings.md) states its meaning and default. [references/skill-rules.md § Reviewer persistence is budget-conditional](references/skill-rules.md#reviewer-persistence-is-budget-conditional) owns how a review fits it, and § Codex thread reuse owns the Codex MultiAgentV2 count, reuse and waves. On Codex the cap is `features.multi_agent_v2.max_concurrent_threads_per_session`, which `scripts/spawn-adapter slots` reports as `effective_cap`, warning when only the ignored `agents.max_threads` is set. Review state lives in on-disk artifacts and workflow state, never in reviewer session memory.

## CI triggering

orch waits for the review result before CI verification. An armed PR still waits for GitHub's required approval and thread resolution. CI job selection belongs to the repository's workflow. The CI wait is the runtime's `verify-pr` request (`runtime/src/ops/verify_pr.rs`), which a workflow repeats through Waiter launch while it answers `pending`, no check registered included, within `CI_WAIT_MAX_SECS`. The merge-queue wait, `queue-watch` (`runtime/src/ops/queue_watch.rs`), reads a failed required check through the same `verify-pr` read, so a check not yet registered reads `pending` there too.

Reruns re-execute the workflow definition and verifier state pinned at the original triggering event, so a PR that changes gate or CI behavior only exhibits the new behavior on a fresh head. Reruns are for flakes and re-gating unchanged workflows: the workflows rerun a transient runner failure once per head through the github skill's `ci-rerun`, the item's `ci_rerun` record written before the verb runs.

## Merge route

A lane merges its own pull request: [merge-pr.md](workflows/merge-pr.md) § 5 step 1 runs `pr-merge` on the exact head, and `pr-merge --help` § Merge route owns the route and its causes. A queued PR (exit `75`) waits in the runtime's `queue-watch` to a terminal verdict, and a review thread left unresolved while it is queued or armed takes it back out through `queue-watch`'s late-findings guard. `merge-pr.md` § 5 step 1 owns the explicit arms for `pr_approval.forced` and unresolved merge state; [submit-pr.md](workflows/submit-pr.md) § 2 step 5 owns the arm at creation.

## Launch lanes

The runtime's `launch-lane` request owns every lane launch (`runtime/src/effects/launch.rs`), and `close-lane` every close (`runtime/src/effects/close.rs`). The launch line comes from agent-runtime's builder (`skills/agent-runtime/runtime/src/launch.rs`): a local line reads the brief file when the command runs, so brief newlines never enter terminal input, and a hosted line quotes the brief's text inline for the remote shell, since the file is on this machine. A launch's routing and brief rules are in [lane-directive.md § Lane preference](references/lane-directive.md#lane-preference) and [§ Brief file](references/lane-directive.md#brief-file).

[`runtime/src/ops/accounts.rs`](runtime/src/ops/accounts.rs) owns the account listing and judge, including model windows, launch projections, overseer seats and grant ordering; its module documentation states the measurement and refusal rules. Token renewal uses the shared credentials lock in agent-runtime; [`runtime/src/ops/accounts/renewal.rs`](runtime/src/ops/accounts/renewal.rs) owns its endpoint and Codex CLI answers.

The host dispatcher `scripts/lane-host` and the static SSH provider `scripts/lane-host-ssh` have separate suites, `tests/lane-host.sh` and `tests/lane-host-ssh.sh`, which run `tests/lib/lane-host-tests.py` and `tests/lib/lane-host-ssh-tests.py`. The dispatcher suite holds the per-home bound on provider calls, `lane-host-busy` past the cap, and its call-site rows fail on any command under `scripts/` that runs a provider verb without `scripts/lane-host`. The provider suite runs its SSH command payloads in temporary git repositories behind an SSH transport stub; it does not establish live SSH connectivity. The shared provider fixture is `tests/fixtures/lane-host`, whose `append` runs the package library that `LANE_HOST_STUB_LIB` names, the way the real provider runs the one in the remote clone it is given.

## Overseer session

The runtime owns the controller's session and record. `orch-runtime successor` reads the overseer walk's choice (`runtime/src/ops/successor.rs`, `runtime/src/ops/walk.rs`) into the pending that a `start-controller` request (a first start or a resume) or a `request-transfer` request (a succession) carries through `orch-runtime op --fleet`; `runtime/src/effects/transfer.rs` runs both, and `stop-controller` retires the controller by identity. `orch-runtime handoff` writes the overseer handoff's snapshot. `scripts/oversee register` records a session a person opened by hand. The watch's overseer duty, `runtime/src/watch/overseer.rs`, judges the controller once per pass and its marks, and asks for a succession through `request-transfer`; the turn-end hook asks for the same mark judgement through `orch-runtime marks`.

The overseer's death, wall and identity come from its own session rows. The `session-start-row`, `session-end-row` and `stop-failure-row` hooks and the overseer's turn end run `lane-mail-check`, which appends one JSON row per event, through `scripts/lib/session-rows.sh`, to the file the fleet state's `overseer.session_rows` names, under the mailbox lock. Only the pane's own top-level harness writes a row (`session_rows_top_level`), so a harness another harness started in the same pane writes nothing. Agent-runtime's `rows.rs` reads them for the watch and keeps that library's verdict tables; a last row it cannot judge reads `unsupported`, and the watch takes the pane capture, the named fallback. `hooks/tests/session-rows.test.sh` holds the writer, and `tests/rust/watch_observe.rs` the watch's judgement.

`overseer-host` dispatches to the provider `ORCH_OVERSEER_HOST` names, and `overseer-host-tmux` is the included one; the protocol is `schemas/overseer-host.md`. `tests/overseer-host.sh` runs the dispatcher against a fixture provider and the tmux provider against a real server on a private socket. `tests/oversee_launch.sh` runs `oversee register` against a server at the default socket under a private `TMUX_TMPDIR`, which is how a run with no `$TMUX` and `ORCH_TMUX_SESSION` set reaches the person's own server. Both build their controls through `tests/lib/growth-state.sh`'s `mutant_scripts`, a tree of links to the shipped scripts with the one file a case mutates copied in. `scripts/lib/tmux-server.sh` is the one shell rule for which server a verb reaches and whether it holds a named session, read by `oversee`, `overseer-host-tmux`, `workflow-state`, `lib/overseer-launch.sh`, the mailbox's `lane-mail` and Jarvis's session backend.

## Container close

`orch-runtime container-close` (`container_close` in `runtime/src/ops/accept.rs`) owns Linear container closure, and `sync-base` owns base resolution, fetch, checkout ownership and the fast-forward; each states its contract in its own `--help`. The tracker CLI's completion validation reports facts and decides nothing: the close accepts only exactly one parent row, with Boolean `has_summary`, array `container_open_boxes` and `errors`, and a numeric or null `child_box`, and Boolean `ok`, `state_ok` and `has_summary` on every child row (`validation_rows`). Its one decision table, `decide`, reads those rows and never `all_ok`. A close decides its own parent alone: whether that container's own parent closes after it is the workflow's to ask.

## Codex app worktree routing

Codex Desktop handoff starts each child thread in an app-managed worktree, often on a detached `HEAD`. Generated Codex agents must be tracked under `.codex/agents/*.toml` in the saved project branch to be visible before subagent discovery; local ignored files are not enough, because setup hooks, `WORKTREE_SYMLINKS`, and `codex-setup` all run too late. Create the app worktree from the resolved base branch rather than a controller `working-tree` snapshot, which can start the child before those agents are visible and force a `worker` fallback.

The managed lifecycle relies on committed branch diffs, so `dev-start.md` and `review-pr.md` reject a dirty worktree, and `submit-pr.md` a dirty or detached one, before review or submission; otherwise uncommitted edits read as "no changes".

## Branch measurements

`item-tier` reads the launch estimate and Expected delta to select a tier, Expected delta through change-scope's `expected_delta_read` (`scripts/lib/branch-growth.sh`). Its branch-range mode reads changed paths only: measured line counts never select a tier. Invalid or absent delta text does not refuse a tier.

`orch-runtime dev-return write` records an implement receipt's `baseline_lines` through the same library's `branch_baseline_lines`: the branch's changed lines, a paired render counted as mirror lines. The receipt reports churn; no round, stamp or cut reads a branch size.

## Harness update

A harness release can change what orch transcribed from the harness. Before a fleet runs on the release, re-check each transcription at its one home:

- The permission table: `Harness::permission_spellings` in `skills/agent-runtime/runtime/src/harness.rs`, each harness's permission words with whether each grants a full bypass, which the launch builder in `skills/agent-runtime/runtime/src/launch.rs` reads; `launch_choice_permission_spellings` in `scripts/lib/lane-launch.sh` spells the same words for the shell's readers of a recorded launch line. A permission word the release renamed or dropped leaves a launch attended.
- The Claude capacity table: `Harness::context_capacity` in `skills/agent-runtime/runtime/src/harness.rs`. `LANE_ADAPTER_CLAUDE_WINDOWS` in `scripts/lib/adapters/claude.sh` spells it in glob form for the shell readers that judge before the runtime is built: the adapter reading the turn-end hook hands `orch-runtime marks`, and `scripts/lib/lane-launch.sh`'s launch checks. A figure changes in both files in one commit; agent-runtime's row `the_adapters_capacity_line_spells_this_table_row_for_row` refuses one that moved alone. A model id with a measured window is an exact-id row ahead of its family word, and an alias keeps the family's budget.
- The native thin path on each of the four harnesses: `skills/agent-runtime/tests/native/thin-path.sh --harness [HARNESS]`, run by a person on a real account ([agent-runtime's DEVELOPMENT.md § Native probe](../agent-runtime/DEVELOPMENT.md#native-probe)), proves the start identity, the first turn, the idle read, the later deliveries and the exact stop on the release.
- The Codex rollout shape: `lane_adapter_codex_transcript_owned` in `scripts/lib/adapters/codex.sh` admits `<home>/sessions/<year>/<month>/<day>/rollout-<time>-<session id>.jsonl` and nothing else, `lane_adapter_codex_reading` reads the `token_count` event's `last_token_usage.total_tokens` and `model_context_window` with the model the last `turn_context` names, and agent-runtime's `skills/agent-runtime/runtime/src/session.rs` binds a Codex session by the same path. A release that moves the rollout or renames the event leaves every Codex overseer's context a gap, which the watch reports as `overseer-context-unmeasured`.
- The session row shapes the overseer's hooks write: `scripts/lib/session-rows.sh` and agent-runtime's `rows.rs`, which name the hook inputs each row follows.
- The three Claude prompt switches: one list in `CLAUDE_BYPASS_ENV` (`skills/agent-runtime/runtime/src/launch.rs`), which `lane_launch_rm_prompt_env` in `scripts/lib/lane-launch.sh` spells for the lines the shell launchers execute, a wake's included; the pin row `the_launchers_prompt_switch_line_spells_this_list_row_for_row` holds the two equal. Where the catalog's `hooks/critical-path-deny.sh` is installed the critical-path switch is inert and the hook refuses the removal with a rewrite; where it is absent the switch runs it; a lane is walled in neither case.

Per-harness facts the skill text relies on, with their standing:

| Fact | Claude Code | Codex | Copilot CLI | Pi |
|---|---|---|---|---|
| A harness child a lane's tool starts inherits the lane's sign-in | not proven | not proven | not proven | not proven |

While a column reads not proven, the dev skill's § Long-Running Validation has a lane plan without such a child and take the harness's own subagent route for a second agent. A measured answer replaces the cell and that sentence together.
