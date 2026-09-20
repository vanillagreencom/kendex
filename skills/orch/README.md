# Orchestration

orch takes Linear or GitHub issues through implementation, review and merge with coding agents. A primary agent assigns each issue's work to coding and review agents, and an overseer can run many issues at once, each in its own agent session, called a lane. It is for people who run coding agents against a tracked backlog.

## Install

```bash
kendex add vanillagreencom/kendex --skill orch
```

Requires jq, Bash 3.2, flock and setsid; the included SSH host provider also needs Python 3.8 or later on the controlling machine. kendex installs the required workflow skills. Add linear for Linear issues. Second-opinion and review-gate are optional.

## Features

- `orch start`, run in an issue's worktree, takes one issue to merge: a coding agent implements it, review agents check the change, the coding agent applies the required fixes, and orch opens the PR, waits for CI and the review gate, and merges it.
- `orch oversee` launches one lane per unblocked issue, reports merges, lane questions, stopped lanes, usage limits and new Linear issues as events through `oversee-watch`, takes each PR to merge, and then runs the post-merge steps and refreshes the consumer repositories when a merge changes shipped packages.
- `lane-mail` carries questions, notices and directives between a lane and the overseer as files in the lane's worktree, so messages need no tmux pane and also reach a lane on another machine.
- `oversee-succeed` starts a new overseer from the handoff file in the same tmux window position once an overseer with a 1M-token context window has used about 500,000 tokens, or once its account headroom falls to the `ORCH_OVERSEER_HEADROOM_PCT` trigger, then closes the old window; the successor is opened on an account above that trigger, and `ORCH_OVERSEER_SUCCESSION=off` turns the whole thing off.
- `lanes` reads the usage of each Claude Code and Codex account it discovers or is configured with, and picks the account with the fewest lanes in flight among those under the usage threshold; the watch reports an account that hit its usage limit and the time the limit resets.
- `lane-host` runs lanes on another machine through a provider script, with the same mailbox and watch; `lane-host-ssh` is the included provider for SSH hosts. What runs where, which credential each part spends and how mail and handoff move on a hosted fleet: [docs/hosted-oversight.html](docs/hosted-oversight.html).
- `open-terminal --relaunch` resumes a stopped lane's own agent session, on the same account or another one, and workflow state and handoff files let a lane or overseer continue where it stopped.
- Each review finding is fixed, filed as an issue or declined by the rules in [references/finding-disposition.md](references/finding-disposition.md), settings cap the review and CI-fix rounds, and `branch-size-check` compares the branch's added lines with the issue's expected size.
- Lanes run on Claude Code, Codex, OpenCode and Pi, and on another machine on Claude Code, Codex and Pi; the orchestrator runs on Claude Code, Codex, OpenCode and Pi, and account selection and overseer succession cover Claude Code and Codex.

A directive is handed over at the end of the lane's turn where the harness runs hooks, and at the lane's next wait point where it does not. Delivery is checked on every harness kendex installs the mailbox hook on. That check runs on one machine at a time and is started by hand, so a fleet's control machine is covered by running it there.

## How it works

In a single-issue cycle, the primary agent reads the issue in its worktree and assigns implementation to a coding agent. Review agents inspect the change and return findings, and the coding agent applies the required fixes. The primary agent opens the PR, waits for CI and the review gate, and merges under the configured merge policy. In overseer mode, the overseer selects unblocked issues and launches a lane for each, and every lane runs the single-issue cycle. `oversee-watch` waits until a lane needs attention, and the overseer then answers the lane's question, relaunches a stopped lane, or runs the post-merge steps after a merge.

## Settings

Non-secret settings go in committed `kendex.settings.toml` under `[env]`; secrets in `.env.local`. Nothing is marked required, so installing writes nothing into your settings file; [kendex.settings.toml.example](kendex.settings.toml.example) comments the keys worth changing first.

| Variable | Purpose | Default |
|---------|---------|---------|
| `ORCH_STATE_DIR` | Workflow state directory; the `--state-dir` flag wins where both are set | `tmp` |
| `OVERSEE_WATCH_STATE_DIR` | Directory for watch baselines, lane claims and cached account usage, shared by `oversee-watch`, `lanes` and `open-terminal` | `tmp/oversee-watch` under the project root |
| `GH_ISSUE_PATTERN` | Regex for issue IDs in branch names, matched case-insensitively and canonicalized | `([A-Z]+-[0-9]+\|issue-[0-9]+)` |
| `CI_WAIT_NO_CHECKS_GRACE` | Seconds `ci-wait` keeps polling when no CI checks have registered before it fails | `600` |
| `CI_FIX_MAX_CYCLES` | Automatic ci-fix cycles for one PR, counted across the heads they push; a passing CI run clears the count | `6` |
| `REVIEW_MAX_CYCLES` | Internal re-review cycles per issue; the number set is the number of re-entries allowed | `4` |
| `REVIEW_MAX_EXTERNAL_ROUNDS` | External comment-triage passes and automatic review-wait restarts on one PR head | `4` |
| `REVIEWER_SLOT_BUDGET` | Concurrent agent-session budget counting the primary; `0` is unlimited; reviews run in waves past it. On Codex, the cap `spawn-adapter slots` reports | `0` |
| `ORCH_DECISION_MODE` | `ask` presents decision points; `auto-recommended` executes the recommended option. The always-ask set in [SKILL.md § The Cycle](SKILL.md#the-cycle) holds in every mode | `auto-recommended` |
| `ORCH_MERGE_AUTONOMY` | `auto` uses existing user authorization to merge once every gate is green; `ask` requires user authorization for each merge and routes it through the fleet overseer | `auto` |
| `ORCH_MERGE_BYPASS` | `fast-path` merges a PR directly, ahead of the merge queue and its second CI pass, when the head already holds the base head and every merge gate is met; every other value, unset or unrecognized, arms auto-merge first and the PR takes the queue | `off` |
| `PM_CREATE_AUTONOMY` | Audit creation and cancellation policy: [project-management settings](../project-management/README.md#settings) | `ask` |
| `ORCH_POST_MERGE_CMD` | Bash command that `scripts/post-merge` runs in the base checkout after synchronization. `ORCH_POST_MERGE_BEFORE` is the base before the oldest unprocessed synchronization; `ORCH_POST_MERGE_AFTER` is the current synchronized head. `sync-base` saves the first in `refs/kendex/post-merge-base`; only a successful or empty command advances it. A failed command stops before project refresh and verification and keeps the range for retry | empty |
| `ORCH_CONSUMER_REPOS` | Space-separated absolute base-checkout paths that set the consumer train's refresh order. The train also refreshes every other project `kendex project list` names that subscribes to the package | empty |
| `PR_REVIEW_ON_TIMEOUT` | `proceed` advances only when no reviewer engaged and no thread is open; `block` reports the timeout | `proceed` |
| `ORCH_OVERSEER_LANES` | Concurrent lanes `oversee` keeps in flight | `3` |
| `ORCH_HANDOFF_CONTEXT_TOKENS` | Context tokens at or past which the `lane-mail-check` turn-end hook refuses a lane's turn end until its handoff record stands. The hook resolves it through `orch-env`, so a settings file sets it. `lanes context` neither reads this setting nor marks a lane on it: its `HANDOFF` column answers for the headroom mark alone, so the overseer's backstop here is reading the poll's `CONTEXT_TOKENS` column against this number by hand | `500000` |
| `ORCH_HANDOFF_HEADROOM_PCT` | Account headroom at or below which `lanes context` marks a live lane for handoff and the `lane-mail-check` turn-end hook refuses that lane's turn end, read against the binding bucket. Both resolve it through the kendex settings ladder, the hook through `orch-env` and `lanes context` through its own `kendex_load_project_env` call, so a settings file sets one mark for both. Never compared with `ORCH_LANE_MAX_PCT` | `3` |
| `ORCH_OVERSEER_PREFERENCE` | Comma-separated `harness:rank:effort` entries `oversee-succeed` tries in order for the successor overseer. `rank` is a position on the kendex tier ladder, 1 for the top tier, never a model name. Empty means the caller's own harness, with the model and effort flags the overseer passes after `--`. Which lane the successor opens on is `oversee-succeed`'s own rule, stated once in its `--help` | empty |
| `ORCH_OVERSEER_SUCCESSION` | `on` lets `oversee-succeed` launch the successor overseer; `off` launches nothing. A live overseer asks the user to start the next session. A dead overseer gets a notice only for a manual replacement | `on` |
| `ORCH_OVERSEER_DEAD_PASSES` | Consecutive watch passes that must read the overseer pane as exited before the watch reports its death | `2` |
| `ORCH_OVERSEER_HEADROOM_PCT` | Account headroom at or below which `oversee-succeed` succeeds the overseer, and at or below which it opens no successor | `20` |
| `ORCH_WATCH_TAIL_LINES` | Most lines any one `oversee-watch` event prints off a lane's pane. Each kind carries only what its handling reads: the dialog, the limit banner, the lane's closing lines, and nothing at all for `model-capacity` and `window-gone` | `12` |
| `ORCH_LANE_HOST` | Provider selected by `lane-host`; executable script path or `local`. `open-terminal` launches through it; `--host` overrides it. [Host protocol](schemas/lane-host.md) | `local` |
| `QA_PERF_PATHS` | Space-separated path globs whose modification adds the `needs-perf-test` QA signal | empty |
| `RECONCILE_STALE_HOURS` | Hours before an In Progress or In Review item counts as started-stale in `reconcile-work-items` sweeps | `24` |
| `WORKTREE_CLI` | Path to the worktree CLI `open-terminal` drives; empty resolves the installed worktree skill's script | resolved |
| Review-gate settings | `REVIEW_GATE_MODE`, `PR_REVIEW_GATE`, `PR_REVIEW_CHECK`, `PR_REVIEW_WAIT_SECS`: [references/gates.md](references/gates.md) | |
| `ORCH_LANE_MAX_PCT` | Usage share at or above which `lanes pick` refuses an account, read against the binding bucket or, with `--model`, against the window that walls that model. `lanes --max-pct`, `lanes --min-headroom-pct` and `open-terminal --lane-max-pct` override it. It is never compared with `ORCH_HANDOFF_HEADROOM_PCT`, so a lane picked on a model window can already be at or below the handoff mark on the account's own bucket; `lanes pick --binding-floor` holds both to one bound for a caller that needs it, as `oversee-succeed` does | `95` |
| Lane settings | `ORCH_LANE_DIRS`, `ORCH_LANE_ALIASES`, `ORCH_LANE_EXCLUDE`, `ORCH_LANE_RETIRE`, `ORCH_LANES_USAGE_TTL`, `ORCH_TMUX_VERIFY_SECS`: `lanes --help`, `open-terminal --help` | |
| `ORCH_SIZE_RENDER_ROOTS` | Render-mirror roots excluded from production and test counts when their source changes in the same branch | `.agents .claude .codex .pi` |
| `ORCH_SIZE_TEST_PATHS` | Path globs counted as test lines in size reports and cut comparisons | empty |

`ORCH_MERGE_BYPASS` instructs the lane and grants it nothing. A direct merge lands only where the organization has given the merging account a ruleset bypass on the base branch, which is the organization's decision and not this package's. Without that grant GitHub refuses the direct merge and the PR takes the queue.

The fast path gives up what the queue provides: serialization against the other merges landing on that base, and the late-findings dequeue `queue-wait` performs. Base containment is read twice, once by `base-freshness` and again immediately before the merge call, because `--expected-head` pins the PR head alone and GitHub's `mergeable` field never reports a branch behind its base; the gap between that second read and the merge is a window nothing closes.

Every decision, taken or refused, goes in the PR body under `## Merge decision`. `submit-pr.md` § 6.2 writes that same section for the unmet-gate question, so the bypass appends its one line and never rewrites what that step wrote.

Maintainer notes and the test entry point: [DEVELOPMENT.md](DEVELOPMENT.md).
