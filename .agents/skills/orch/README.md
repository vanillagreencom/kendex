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
- `lane-host` runs lanes on another machine through a provider script, with the same mailbox and watch; `lane-host-ssh` is the included provider for SSH hosts.
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
| `PM_CREATE_AUTONOMY` | Audit creation and cancellation policy: [project-management settings](../project-management/README.md#settings) | `ask` |
| `ORCH_POST_MERGE_CMD` | Bash command that `scripts/post-merge` runs in the base checkout after synchronization. `ORCH_POST_MERGE_BEFORE` is the base before the oldest unprocessed synchronization; `ORCH_POST_MERGE_AFTER` is the current synchronized head. `sync-base` saves the first in `refs/kendex/post-merge-base`; only a successful or empty command advances it. A failed command stops before project refresh and verification and keeps the range for retry | empty |
| `ORCH_CONSUMER_REPOS` | Space-separated absolute base-checkout paths that receive the consumer train, in refresh order | empty |
| `PR_REVIEW_ON_TIMEOUT` | `proceed` advances only when no reviewer engaged and no thread is open; `block` reports the timeout | `proceed` |
| `ORCH_OVERSEER_LANES` | Concurrent lanes `oversee` keeps in flight | `3` |
| `ORCH_HANDOFF_HEADROOM_PCT` | Account headroom at or below which `lanes context` marks a live lane for handoff | `5` |
| `ORCH_OVERSEER_PREFERENCE` | Comma-separated `harness:rank:effort` entries `oversee-succeed` tries in order for the successor overseer. `rank` is a position on the kendex tier ladder, 1 for the top tier, never a model name. Empty keeps the current overseer's lane at the context mark and takes the lane `lanes pick` names at the account mark, either way with the model and effort flags the overseer passes after `--` | empty |
| `ORCH_OVERSEER_SUCCESSION` | `on` lets `oversee-succeed` launch the successor overseer; `off` launches nothing, and the overseer asks the user to start the next session | `on` |
| `ORCH_OVERSEER_HEADROOM_PCT` | Account headroom at or below which `oversee-succeed` succeeds the overseer, and at or below which it opens no successor | `20` |
| `ORCH_LANE_HOST` | Provider selected by `lane-host`; executable script path or `local`. `open-terminal` launches through it; `--host` overrides it. [Host protocol](schemas/lane-host.md) | `local` |
| `QA_PERF_PATHS` | Space-separated path globs whose modification adds the `needs-perf-test` QA signal | empty |
| `RECONCILE_STALE_HOURS` | Hours before an In Progress or In Review item counts as started-stale in `reconcile-work-items` sweeps | `24` |
| `WORKTREE_CLI` | Path to the worktree CLI `open-terminal` drives; empty resolves the installed worktree skill's script | resolved |
| Review-gate settings | `REVIEW_GATE_MODE`, `PR_REVIEW_GATE`, `PR_REVIEW_CHECK`, `PR_REVIEW_WAIT_SECS`: [references/gates.md](references/gates.md) | |
| Lane settings | `ORCH_LANE_DIRS`, `ORCH_LANE_ALIASES`, `ORCH_LANE_EXCLUDE`, `ORCH_LANE_RETIRE`, `ORCH_LANES_USAGE_TTL`, `ORCH_LANE_MAX_PCT`, `ORCH_TMUX_VERIFY_SECS`: `lanes --help`, `open-terminal --help` | |
| `ORCH_SIZE_RENDER_ROOTS` | Render-mirror roots excluded from production and test counts when their source changes in the same branch | `.agents .claude .codex .pi` |
| `ORCH_SIZE_TEST_PATHS` | Path globs counted as test lines in size reports and cut comparisons | empty |

Maintainer notes and the test entry point: [DEVELOPMENT.md](DEVELOPMENT.md).
