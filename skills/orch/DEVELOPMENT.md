# Orchestration development

Maintainer notes. Consumer docs: [README.md](README.md); the agent contract: [SKILL.md](SKILL.md).

## Tests

```bash
bash skills/orch/tests/run-all.sh
bash skills/orch/tests/run-all.sh workflow_helpers   # subset by name fragment
bash skills/orch/tests/run-all.sh open-terminal oversee       # either fragment
bash skills/orch/tests/run-all.sh '!open-terminal' '!oversee' # neither
```

A bare argument selects and `!name` rejects, so a set of fragments and that set negated split the battery: no suite runs in both halves and none runs in neither. CI runs the battery as four shards built that way, and `tools/tests/orch-shard-partition.test.sh` holds them to it.

Each `tests/*.sh` is self-contained: it builds its own sandbox with parametrized CLI stubs on `PATH`, prints `pass: N fail: M`, and exits 0 only when every assertion passed. `run-all.sh` discovers them at execution time, so a new suite needs no registration.

Every `tests/*.sh` carries one line directly under its `set -...o pipefail`:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
```

That lib is where the four git environment variables are cleared, so a new suite adds the line rather than its own `unset`. The position is the rule, not the presence: `git-env-isolation.test.sh` names any file whose line is absent or sits anywhere but directly under the `set`.

Every test the runner discovers ships with the installed skill and must pass in a downstream project with no access to the kendex source checkout. Byte identity and idempotence of what an apply writes are covered upstream of the installed tree, in `crates/core/tests/byte_faithful.rs`.

Run probes that import Python fixtures with `python3 -B`. Bytecode caches under the catalog become render inputs.

## Invariants the tests pin

- Round-id identity. Every dev and QA delegation mints a token (`workflow-state new-round-id`, a nanosecond timestamp plus a random suffix) and embeds it; `dev-return-write --round-id RID` writes `tmp/dev-return-[ISSUE]-[RID].json` with `round_id` inside, and `dev-artifact-check --round-id RID` resolves that exact path and requires the internal token to match. There is one identity model, no mtime gate and no positional mode, so a same-second re-stamp, a late-writing timed-out agent, a bundle group-A receipt consumed by group-B, and a cross-round ci-fix receipt are all unmatchable. `dev_delegated_at` remains only as the stall-watchdog deadline. Gate ordering and field rules: `dev-artifact-check --help` and [references/artifact-checks.md](references/artifact-checks.md); schemas in [schemas/](schemas/).
- Command shapes. Lints scan the orch and dev docs for the shapes strict harness classifiers reject inside a fenced `bash`/`sh` block: a literal backtick, and an env-assignment prefix. Each carries planted-control cases proving it still has teeth.
- Reference hygiene. Lints pin that no doc across orch, dev and github routes CI waiting through `github.sh` (the waiter is `.agents/skills/orch/scripts/ci-wait`), and that no orch doc uses an unsupported `decisions issue` lookup shape.
- Help is inert. Every orch CLI that loads project configuration answers a help form before the load. A parser reached by a dry run runs twice, so an arm that returns may only assign; an arm that prints must then exit. Held by `tools/tests/help-inert.test.sh`.
- Inherited git environment. `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` outrank `git -C <path>`, so a suite that inherits them builds its fixtures inside the caller's repository and still reports a clean pass. `lib/git-env.sh` clears all four at load. `git-env-isolation.test.sh` holds both halves: it runs `dev_round_gate.sh` with all four exported at a sandbox repository and pins that repository's log and index unchanged, repeating the run against a copied tree whose lib is neutralized to prove the clearing is what holds it; its lint pins the source line's position, with probe files placing the line after the fixture, inside a dead branch, and inside a heredoc body, since each of those runs late or not at all while reading as present.
- Sourced libs inherit that clearing. Every lib under `tests/lib/` that shells out to git does so with a bare `git -C` and is sandboxed only because the suite that sourced it sourced `lib/git-env.sh` first. The lint reaches `tests/*.sh` and not `tests/lib/*.sh`, so a lib added here rests on that precondition rather than on a check.
- Shard coverage. CI runs the battery as four shards and a shard is nothing but a `run-all.sh` name filter, so a filter that stopped matching would drop its suites out of every shard while all four stayed green. `tools/tests/orch-shard-partition.test.sh` reads those filters out of `.github/workflows/skill-tests.yml`, replays them over the real suite names in a sandbox of empty files, and requires each suite in exactly one shard; its controls drop a shard and repeat a shard.
- Controls. `help-inert.test.sh` plants its own must-fail controls. `workflow-state-state-dir-flag.sh` and `lanes-settings-refusal.sh` do not, so re-run them against the pre-fix file when changing what they cover.
- Waiter contracts. `approval_wait.sh`, `ci_wait.sh` and `queue_wait.sh` exercise the state machines and the shared auth ladder against stubbed `gh`, including the check-run and commit-status evidence surfaces, run correlation across reruns and cancelled siblings, and the queue's cross-poll `WAS_QUEUED` memory. They and the two `queue_wait_*` suites run on `lib/virtual-clock.sh`, whose `date`/`sleep` stubs make a poll budget arithmetic over a file rather than real seconds, so a deadline case cannot race a loaded runner. A case that needs a real wait sets `STUB_CLOCK=` and both stubs fall through; `ci_wait.sh`'s hanging-auth preflight is the only one. A `STUB_CLOCK` naming no file is a broken clock rather than a waiver and both stubs refuse it. `lib/waiter-assertions.sh` holds the suites' shared assertion vocabulary.

- Detached waiter completion. `waiter_launch.sh` executes the launch script from [Waiter launch](references/waiter-launch.md) against the real `approval-wait`. It kills the parent process group during a controlled GitHub call and checks the recorded exit. Its control removes `setsid -f` and checks that the same kill leaves no completion file. A table of three rows then has a detached child send itself INT. Every row runs as the async job of a non-interactive shell, which is the SIGINT and SIGQUIT ignore `open-terminal`'s `run_detached` gives a GUI-surface lane and a woken turn, and everything either of those runs; a tmux-surface lane is created by `tmux new-window`, never reaches `run_detached`, and carries no such ignore. Two rows take the GitHub skill's `KENDEX_GROUP_LEADER` prefix, which restores both dispositions in the process it execs and makes that process its own group leader, its full contract being `skills/github/scripts/lib/group-leader.sh`: the launch spelling records 130 and the trailing-`&` control records 0. The third row drops the prefix and records 0, which is the caller's own ignore reaching the detached job. Without the prefix a row reports that ignore as a launcher defect; `ignoring_caller` installs the same ignore on every host, so the result no longer turns on whether the suite runs inside a lane. The suite requires `setsid` and `perl`, and skips on a host without either.

## GitHub auth ladder

`approval-wait`, `ci-wait` and `queue-wait` share `scripts/lib/gh-auth.sh`, which wraps the GitHub skill's helpers. Each candidate is probed at most once, except the timed-out env token in step 1:

1. Selected env token. `GH_TOKEN` or `GITHUB_TOKEN` set: validate with a bounded `gh api user`. A 403 naming an integration, which a GitHub App installation token gets, is validated again with a bounded `gh api installation/repositories`. A value with no known token prefix is selected only when that validation passes. A validation killed at `KENDEX_GITHUB_AUTH_TIMEOUT` (status 124) is asked once more before the keyring fallback, since the first call through an egress proxy can be the slow one; `queue_wait.sh` holds both rows. One env token gets at most two checks in a waiter and at most three in `oversee-watch`, whose `orch_sanitize_gh_env` check comes first, each bounded by `KENDEX_GITHUB_AUTH_TIMEOUT`.
2. Keyring fallback. That token failing: `env -u GH_TOKEN -u GITHUB_TOKEN gh auth status` once; on success, warn on stderr and unset the stale env token.
3. Bot token. Keyring not recovering: unset the stale env tokens, then load a `GH_BOT_TOKEN` candidate from process env or project config. `op://` references resolve through `op read` only after the final source is selected. The `github.sh` router separately prefers a resolved `GH_BOT_TOKEN` over a resolved `GITHUB_TOKEN`, so bot access is not blocked by a user token.
4. No-env keyring. No env token at startup and no bot token: probe keyring auth once.
5. Hard fail. Nothing works: exit `3` with a diagnostic. Callers never poll against empty output.

`op` CLI service-account setup is outside orch: launchers may inject resolved secrets before starting a harness, and orch preserves those values rather than clobbering them with local `op://` references.

## Git HTTPS fallback

Merge and submit workflows use targeted `origin` operations through the GitHub skill's `scripts/git-https-auth` rather than broad remote enumeration. The helper is a per-command fallback for SSH-backed GitHub remotes: it validates env-token or keyring `gh` auth, then supplies temporary `credential.helper` and `url.insteadOf` config so GitHub SSH URLs work over HTTPS. It persists nothing. Never use `git fetch --all --prune` for PR closure: a secondary remote's SSH failure must not block branch cleanup or tracker closure.

## Reviewer slot budget

`REVIEWER_SLOT_BUDGET` bounds reviewer fanout for runtimes that cap concurrent agent threads. It is the runtime's total agent-session budget counting the primary session; `0` means unlimited. When the reviewer set exceeds the available slots, review workflows run bounded waves and retire each completed session, because a completed subagent thread can keep counting against the cap until it is explicitly shut down. The configured budget is advisory and the runtime cap authoritative: a persistent launch that hits the thread-limit error demotes to waves in place, persists the observed size, and recommends it to the user.

On the Codex collaboration runtime the cap is MultiAgentV2's configurable `features.multi_agent_v2.max_concurrent_threads_per_session`. `spawn-adapter slots` reports the effective cap, warns when only the silently-ignored legacy `agents.max_threads` is set, and notes that a running session keeps the cap it started with. Retiring is safe because review state lives in on-disk artifacts and workflow state, never in reviewer session memory.

## CI triggering

orch orders the review gate before CI verification universally, with no repo detection, so a repo whose CI starts only after a review verdict (approval-gated jobs, or a merge queue) can never deadlock the workflow. On always-on repos the post-gate CI verify returns quickly, and `ci-wait` tolerates dispatch latency through `CI_WAIT_NO_CHECKS_GRACE`.

When the review evidence arrives as a commit status rather than a check-run, no PR workflow trigger fires on it, so a run gated closed while that status was pending recovers only through the repo's own status convergence, or one bounded manual rerun-in-place after the evidence lands. Consuming-repo gate architecture belongs to the review-gate skill; vendor it rather than hand-writing gate jobs.

Reruns re-execute the workflow definition and verifier state pinned at the original triggering event, so a PR that changes gate or CI behavior only exhibits the new behavior on a fresh head. Reruns are for flakes and re-gating unchanged workflows.

## Launch lanes

The host dispatcher and static SSH provider have separate suites, `tests/lane-host.sh` and `tests/lane-host-ssh.sh`. The provider suite executes its SSH command payloads in temporary Git repositories with an SSH transport stub. It uses the installed worktree command to check shared links and copies after clone preparation. It executes the Claude prefix and records process arguments to check that the token travels only in the environment. It also covers account bytes, repeated creation, provider failures, dirty-close refusal, and close after lane cleanup removes the worktree. The `append` cases add lines to a mailbox file, close a fragment an interrupted writer left, drop a cut transfer, create an item directory the lane has not opened with the transfer umask keeping it private, and hold the mailbox lock against a second writer, which waits for it and writes through it once the lock call is removed. Archive tests read saved records, observe the printed path before deletion, and check that transport and local storage failures preserve remote data. They cover only records still present at close. The suite does not establish live SSH connectivity. The shared provider fixture is `tests/fixtures/lane-host`; launcher and watcher integration use that protocol independently. Its `append` runs the package library that `LANE_HOST_STUB_LIB` names, the way the real provider runs the one in the remote clone it is given. The optional SSH reference uses Python's standard library to quote remote shell arguments and transfer binary files without putting credentials in arguments.

`lanes` answers which harness account a session should launch under on a machine carrying several. The failure it exists for is account-level: when one account hits its limit mid-fleet, every session on it stalls at once.

- Headroom is `100 - max(session_5h, weekly, model_weekly)`, the binding bucket, never an average. An account at 5% session and 95% weekly has 5% headroom.
- Everything unmeasurable is refused, never assumed idle. A lane is pickable only at `status: ok` with at least one parsed window; `no_credentials`, `expired`, `unreachable`, `no_usage_data` and `error` all yield a null headroom and are skipped. `pick` exits `3` when nothing qualifies, distinct from 1 for a real failure.
- The inventory is discovered; config is only an overlay. `ORCH_LANE_ALIASES` renames discovered lanes, `ORCH_LANE_DIRS` covers a layout discovery cannot reach for each harness it holds an entry of, `ORCH_LANE_EXCLUDE` and `ORCH_LANE_RETIRE` remove lanes by directory name or alias. An excluded or retired lane's directory is never looked inside, because an excluded account can be one agents must not touch, and `open-terminal` refuses a named `--lane` either setting covers, through `lanes check`.
- Usage figures are cached per host under the oversee-watch state directory for `ORCH_LANES_USAGE_TTL` seconds, so several overseers on one machine poll each account at most once per TTL. Credentials are still read every run, so token expiry is never masked, and a failed fetch is never cached.
- In-flight launches outrank headroom. `open-terminal` records a claim per tmux lane it launches under a resolved lane; a claim is live while its pane is (`<server pid> <pane id>`, pruned on read), and `pick` takes the fewest live claims first, headroom only breaking the tie, because usage numbers lag a launch by minutes. The threshold is applied first; a claim count never buys a lane past it.
- An expired access token is renewed before the lane is measured, so the lane `pick` prints carries a live token and its record reads `refreshable: true`. Refreshing rotates the refresh token in a credentials file other tools on the machine share, so the write takes a flock and re-reads the credentials inside it. A lane with no refresh token, or whose renewal fails, stays `expired` with the cause in its detail and is never picked. The token POST is injected through `ORCH_LANES_TOKEN_CMD` for the suite.
- Two API shapes, one trap each. Claude's model-scoped weekly windows live in `limits[]` entries with `kind == "weekly_scoped"`. The legacy `seven_day_sonnet` and `seven_day_opus` fields stand in only where a response carries no such entry, and a response carrying both keeps both. Keep every scoped window under the label the response gives it: the most-consumed one names the MODEL column, and a launch on a named model is judged on the window scoped to that model. Codex's `primary_window`/`secondary_window` do not map to session/weekly by position; route each by its own `limit_window_seconds`.
- Testing. The network layer is the only impure part and is injected through `ORCH_LANES_FETCH_CMD`, so the suite runs offline against fixed responses. Bearer tokens never reach argv; they go to curl over stdin with `-K -`.

`open-terminal` takes model, effort and permission flags per launch through `--launch-flags`, validated to plain flag words before interpolation, and inside the `--cmd` command where a launch carries its own harness argv. Those are the two spellings of one choice and never both: a `--cmd` command is rendered verbatim and no flag is appended to it, so `--launch-flags` beside it are refused as `launch-flags-unreachable` rather than gating a model the harness never runs. Nothing stores them: a stored default silently applies yesterday's answer to today's work item.

## Container close

`container-close` owns Linear container closure and `sync-base` owns base resolution, fetch, checkout ownership and the fast-forward. Both contracts are in their own `--help`. Completion validation inside `container-close` must provide Boolean `all_ok`, exactly one typed parent result, and Boolean `has_summary`; the helper never infers that a later child completion came from a parent cascade.

## Codex app worktree routing

Codex Desktop handoff starts each child thread in an app-managed worktree, often on a detached `HEAD`. Generated Codex agents must be tracked under `.codex/agents/*.toml` in the saved project branch to be visible before subagent discovery; local ignored files are not enough, because setup hooks, `WORKTREE_SYMLINKS`, and `codex-setup` all run too late. Create the app worktree from the resolved base branch rather than a controller `working-tree` snapshot, which can start the child before those agents are visible and force a `worker` fallback.

The managed lifecycle relies on committed branch diffs, so `dev-start.md`, `review-pr.md` and `submit-pr.md` reject dirty or detached worktrees before review or submission; otherwise uncommitted edits read as "no changes".
