# Orchestration — Development Notes

Maintainer notes. End-user setup: [`README.md`](./README.md). Agent-facing instructions: [`SKILL.md`](./SKILL.md).

## Tests

```bash
bash skills/orch/tests/run-all.sh
bash skills/orch/tests/run-all.sh workflow_helpers   # subset by name fragment
```

Each `tests/*.sh` is self-contained: it builds its own sandbox with parametrized CLI stubs on `PATH`, prints `pass: N fail: M`, and exits 0 only when every assertion passed. `run-all.sh` discovers them at execution time, so a new suite needs no registration.

Every test the runner discovers ships with the installed skill and must pass in a downstream project with no access to the vstack source checkout. Source-only generator and install regressions live in `cli/scripts/integration-check.sh`, which validates install/refresh byte identity, markdownlint, idempotence, the refreshed downstream `run-all.sh`, and the installed dev cache-preflight contract.

## Invariants the tests pin

- **Round-id identity.** Every dev/QA delegation mints a token (`workflow-state new-round-id`, a nanosecond timestamp plus a random suffix) and embeds it; `dev-return-write --round-id RID` writes `tmp/dev-return-[ISSUE]-[RID].json` with `round_id` inside, and `dev-artifact-check --round-id RID` resolves that exact path and requires the internal token to match. There is one identity model — no mtime gate, no legacy positional mode — so a same-second re-stamp, a late-writing timed-out agent, a bundle group-A receipt consumed by group-B, and a cross-round ci-fix receipt are all unmatchable. `dev_delegated_at` remains only as the stall-watchdog deadline. Full gate ordering and field rules: [`references/artifact-checks.md`](./references/artifact-checks.md); schemas in [`schemas/`](./schemas/).
- **Command shapes.** Four lints scan the orch and dev docs for shapes strict harness classifiers reject: a literal backtick or an env-assignment prefix inside a fenced `bash`/`sh` block, two or more `workflow-state` invocations stacked in one fenced block, and a token naming one harness's tool, agent type, poll shape, or tool-call cap sitting outside a block that labels the harness it belongs to. Each carries planted-control cases proving it still has teeth.
- **Reference hygiene.** Lints pin that no doc routes CI waiting through `github.sh` (the waiter is `.agents/skills/orch/scripts/ci-wait`), that no doc uses an unsupported `decisions issue` lookup shape, and that no always-loaded `SKILL.md` or `agents/*.md` carries an issue-number citation.
- **Settings parity.** `settings-example-sync.test.sh` requires every orch key to exist in both `vstack.settings.toml.example` files with identical defaults, so the two places users learn the options cannot drift.
- **Waiter contracts.** `approval_wait.sh`, `ci_wait.sh`, and `queue_wait.sh` exercise the state machines and the shared auth ladder against stubbed `gh`, including the check-run and commit-status evidence surfaces, run correlation across reruns and cancelled siblings, and the queue's cross-poll `WAS_QUEUED` memory.

## GitHub auth ladder

`approval-wait`, `ci-wait`, and `queue-wait` share `scripts/lib/gh-auth.sh`, which wraps the GitHub skill's helpers. Each candidate is probed at most once:

1. **Selected env token.** `GH_TOKEN` or `GITHUB_TOKEN` set → validate with a bounded `gh api user`.
2. **Keyring fallback.** That token failing → `env -u GH_TOKEN -u GITHUB_TOKEN gh auth status` once; on success, warn on stderr and unset the stale env token.
3. **Bot token.** Keyring not recovering → unset the stale env tokens, then load a `GH_BOT_TOKEN` candidate from process env or project config. `op://` references resolve through `op read` only after the final source is selected. The `github.sh` router separately prefers a resolved `GH_BOT_TOKEN` over a resolved `GITHUB_TOKEN`, so bot access is not blocked by a user token.
4. **No-env keyring.** No env token at startup and no bot token → probe keyring auth once.
5. **Hard fail.** Nothing works → exit `3` with a diagnostic. Callers never poll against empty output.

`op` CLI service-account setup is deliberately outside orch: launchers may inject resolved secrets before starting a harness, and orch preserves those values rather than clobbering them with local `op://` references.

## Git HTTPS fallback

Merge and submit workflows use targeted `origin` operations through the GitHub skill's `scripts/git-https-auth` rather than broad remote enumeration. The helper is a per-command fallback for SSH-backed GitHub remotes: it validates env-token or keyring `gh` auth, then supplies temporary `credential.helper` and `url.insteadOf` config so GitHub SSH URLs work over HTTPS. It persists nothing. Never use `git fetch --all --prune` for PR closure — a secondary remote's SSH failure must not block branch cleanup or tracker closure.

## Reviewer slot budget

`REVIEWER_SLOT_BUDGET` bounds reviewer fanout for runtimes that cap concurrent agent threads. It is the runtime's total agent-session budget counting the primary session; `0` means unlimited. When the reviewer set exceeds the available slots, review workflows run bounded waves and retire each completed session — necessary because a completed subagent thread can keep counting against the cap until it is explicitly shut down. The configured budget is advisory and the runtime cap authoritative: a persistent launch that hits the thread-limit error demotes to waves in place, persists the observed size, and recommends it to the user.

On the Codex collaboration runtime the cap is not a fixed property but MultiAgentV2's configurable `features.multi_agent_v2.max_concurrent_threads_per_session`. `spawn-adapter slots` reports the effective cap, warns when only the silently-ignored legacy `agents.max_threads` is set, and notes that a running session keeps the cap it started with. Retiring is safe because review state lives in on-disk artifacts and workflow state, never in reviewer session memory.

## CI triggering patterns

orch orders the review gate before CI verification universally, with no repo detection, so a repo whose CI starts only after a review verdict — approval-gated jobs, or a merge queue — can never deadlock the workflow. On always-on repos the post-gate CI verify simply returns quickly, and `ci-wait` tolerates dispatch latency through `CI_WAIT_NO_CHECKS_GRACE`.

One repo-side wiring case needs naming: when the review evidence arrives as a commit status rather than a check-run, no PR workflow trigger fires on it, so a run gated closed while that status was pending recovers only through the repo's own status convergence — or, absent that, one bounded manual rerun-in-place after the evidence lands. Consuming-repo gate architecture (the writer, the predicate, evidence surfaces, and adoption) belongs to the **review-gate skill**; vendor it rather than hand-writing gate jobs.

Reruns re-execute the workflow definition and verifier state pinned at the original triggering event, so a PR that changes gate or CI behavior only exhibits the new behavior on a fresh head. Reruns are for flakes and re-gating unchanged workflows.

## Launch lanes

`lanes` answers which harness account a session should launch under on a machine carrying several. The failure it exists for is account-level: when one account hits its limit mid-fleet, every session on it stalls at once.

- **Headroom is `100 - max(session_5h, weekly, model_weekly)`** — the binding bucket, never an average. An account at 5% session and 95% weekly has 5% headroom; averaging calls it 50% free and sends the fleet into the wall.
- **Everything unmeasurable is refused, never assumed idle.** A lane is pickable only at `status: ok` with at least one parsed window; `no_credentials`, `expired`, `unreachable`, `no_usage_data`, and `error` all yield a null headroom and are skipped. `pick` exits **3** when nothing qualifies, distinct from 1 for a real failure, so a caller can tell "every account is full" from "the helper broke".
- **The inventory is discovered; config is only an overlay.** `ORCH_LANE_ALIASES` renames discovered lanes, `ORCH_LANE_DIRS` covers a layout discovery cannot reach. Adding an account needs no config edit.
- **In-flight launches outrank headroom.** `open-terminal` records a claim per tmux lane it launches under a resolved lane; a claim is live while its pane is (`<server pid> <pane id>`, pruned on read), and `pick` takes the fewest live claims first, headroom only breaking the tie. Usage numbers lag a launch by minutes, so ordering on them alone hands one account a whole fleet launched back to back. The threshold is applied first — a claim count never buys a lane past it.
- **Token refresh is opt-in.** Refreshing rotates the refresh token in a credentials file other tools on the machine share, so a chooser that silently rotates during a fleet launch trades a visible `expired` for an invisible auth failure everywhere. `--refresh` opts in and takes an flock, re-reading inside it.
- **Two API shapes, one trap each.** Claude's model-scoped weekly window lives in `limits[]` entries with `kind == "weekly_scoped"`, not the legacy `seven_day_*` fields — take the most-consumed one and read its label from the response. Codex's `primary_window`/`secondary_window` do not map to session/weekly by position; their durations vary by account, so route each by its own `limit_window_seconds` or a weekly-only account gets a 7-day window labelled "5h" and a phantom 0% weekly.
- **Testing.** The network layer is the only impure part and is injected through `ORCH_LANES_FETCH_CMD`, so the suite runs offline against fixed responses. Bearer tokens never reach argv — anything on the box can read `/proc/<pid>/cmdline` — so they go to curl over stdin with `-K -`.

`open-terminal` takes model, effort, and permission flags per launch through `--launch-flags`, validated to plain flag words before interpolation. Nothing stores them: a stored default silently applies yesterday's answer to today's work item.

## Container close

`merge-pr.md` § 5 step 2's container-close sequence — the per-parent lock, the canceled-child snapshot, validation, completion, and cascade repair — is agent-interpreted prose rather than a helper script. Every step is lock-guarded and fail-closed, and each exit path names its cleanup. Mechanizing it into a tested helper is the intended evolution; grow that helper from this sequence rather than re-deriving it.

## Codex app worktree routing

Codex Desktop handoff starts each child thread in an app-managed worktree, often on a detached `HEAD`. Generated Codex agents must be tracked under `.codex/agents/*.toml` in the saved project branch to be visible before subagent discovery — local ignored files are not enough, because setup hooks, `WORKTREE_SYMLINKS`, and `codex-setup` all run too late. Create the app worktree from the resolved base branch rather than a controller `working-tree` snapshot, which can start the child before those agents are visible and force a `worker` fallback.

The managed lifecycle relies on committed branch diffs, so `dev-start.md`, `review-pr.md`, and `submit-pr.md` reject dirty or detached worktrees before review or submission — otherwise uncommitted edits read as "no changes".
