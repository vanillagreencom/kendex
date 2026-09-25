# Orchestration

orch takes Linear or GitHub issues through implementation, review and merge with coding agents. A primary agent assigns each issue's work to coding and review agents, and an overseer can run many issues at once, each in its own agent session, called a lane. It is for people who run coding agents against a tracked backlog.

## Install

```bash
kendex add vanillagreencom/kendex --skill orch
```

Requires jq, Bash 3.2, flock, setsid and timeout or gtimeout; the included SSH host provider also needs Python 3.8+ on the controlling machine. kendex installs the required skills. Add linear for Linear issues. Second-opinion and review-gate are optional.

## Features

- `orch start`, run in an issue's worktree, takes one issue to merge: a coding agent implements it, review agents check the change, the coding agent applies the required fixes, and orch opens the PR, waits for CI and the review gate, and merges it.
- `orch oversee` launches one lane per unblocked issue, reports merges, lane questions, stopped lanes, usage limits and new Linear issues as events through `oversee-watch`, takes each PR to merge, and then runs the post-merge steps and, off a hosted fleet, refreshes the consumer repositories when a merge changes shipped packages.
- `lane-mail` carries questions, notices and directives between a lane and the overseer as files in the lane's worktree, so messages need no tmux pane and also reach a lane on another machine.
- `oversee-succeed` replaces an overseer in the same tmux position when its context, headroom, projected wall time, or qualifying-account trigger fires. It also replaces an overseer that ended or walled.
- `lanes` reads the usage of each Claude Code and Codex account it discovers or is configured with, and picks the account with the fewest lanes in flight among those under the usage threshold; the watch reports an account that hit its usage limit and the time the limit resets.
- `lane-host` runs lanes on another machine through a provider script, with the same mailbox and watch; `lane-host-ssh` is the included provider for SSH hosts. What runs where, which credential each part spends and how mail and handoff move on a hosted fleet: [docs/hosted-oversight.html](docs/hosted-oversight.html).
- `oversee-report` writes the overseer's scheduled and handover status reports.
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
| `ORCH_USER_MODE` | `ceo` or `engineer`, and what each asks: [communication-modes.md](references/communication-modes.md) | `ceo` |
| `ORCH_DECISION_MODE` | `ask` presents decision points; `auto-recommended` takes the recommended one | `auto-recommended` |
| `ORCH_MERGE_AUTONOMY` | `auto` merges once every gate is green on authorization already given; `ask` requires it per merge | `auto` |
| `ORCH_MERGE_BYPASS` | `fast-path` merges a PR directly, ahead of the merge queue and its second CI pass, when the head already holds the base head and every merge gate is met; every other value, unset or unrecognized, arms auto-merge first and the PR takes the queue | `off` |
| Admin-merge settings | `ORCH_ADMIN_MERGE_GH_CONFIG_DIR`, `ORCH_ADMIN_MERGE_CLASSES`: [settings example](kendex.settings.toml.example). A set config dir preempts `ORCH_MERGE_BYPASS=fast-path` | empty |
| `PM_CREATE_AUTONOMY` | Audit creation and cancellation: [project-management settings](../project-management/README.md#settings) | `ask`; `auto` under `ceo` |
| `ORCH_POST_MERGE_CMD` | Bash command that `scripts/post-merge` runs in the base checkout after synchronization. `ORCH_POST_MERGE_BEFORE` is the base before the oldest unprocessed synchronization; `ORCH_POST_MERGE_AFTER` is the current synchronized head. `sync-base` saves the first in `refs/kendex/post-merge-base`; only a successful or empty command advances it. A failed command stops before project refresh and verification and keeps the range for retry | empty |
| `ORCH_CONSUMER_REPOS` | Space-separated absolute base-checkout paths that set the consumer train's refresh order. The train also refreshes every other project `kendex project list` names that subscribes to the package | empty |
| `PR_REVIEW_ON_TIMEOUT` | `proceed` advances only when no reviewer engaged and no thread is open; `block` reports the timeout | `proceed` |
| `ORCH_OVERSEER_LANES`, `ORCH_LANE_ACCOUNT_CLAIMS` | Fleet, account (`0` off) lane caps: `open-terminal --help` | `3`, `3` |
| `ORCH_LANE_OUTPUT` | Lane pane output: [skill-rules.md](references/skill-rules.md) § Lane Output | `quiet` |
| `ORCH_HANDOFF_CONTEXT_TOKENS` | Context tokens at or past which a turn end is refused until that session's handoff record stands. The `lane-mail-check` hook judges a lane on it and `oversee-succeed` judges the overseer on it, for that hook and the watch. `lanes context` marks no lane on it: its `HANDOFF` column answers for the headroom mark alone | `500000` |
| `ORCH_HANDOFF_HEADROOM_PCT` | Account headroom at or below which `lanes context` marks a live lane for handoff and the `lane-mail-check` turn-end hook refuses that lane's turn end, read against the binding bucket | `3` |
| `ORCH_OVERSEER_PREFERENCE` | Comma-separated `harness:rank:effort` entries that `oversee-succeed` tries in order. `rank` is a kendex tier ladder position, 1 the top tier. A named entry writes its harness's model and effort, keeps same-harness permission words exact, and carries only full bypass across harnesses. The caller fallback keeps the flags after `--` but question-tool words. Lane selection: `oversee-succeed --help`. | empty |
| `ORCH_OVERSEER_QUESTION_TOOL` | `off` strips successors' question tool | `on` |
| `ORCH_OVERSEER_SUCCESSION` | `on` lets `oversee-succeed` launch the successor overseer; `off` launches nothing and turns off the turn-end refusal naming it; the `overseer-mark` watch line still goes out. A live overseer asks the user to start the next session. A dead or walled one gets a notice only | `on` |
| `ORCH_OVERSEER_DEAD_PASSES` | Consecutive watch passes that must read the overseer pane as exited, or as walled, before the watch reports it; a walled reading needs its account judged at or below the trigger too | `2` |
| `ORCH_OVERSEER_HEADROOM_PCT` | Account headroom at or below which `oversee-succeed` succeeds the overseer onto an account above it, and refuses its turn end through `lane-mail-check` | `10` |
| `ORCH_OVERSEER_WALL_MINUTES` | Projected wall minutes that fire overseer succession. `0` disables this trigger | `30` |
| `ORCH_OVERSEER_SUCCESSOR_ACCOUNTS` | Remaining qualifying successor accounts that fire succession. `0` disables this trigger | `1` |
| `ORCH_OVERSEER_MARK_REPEAT` | Watch passes a standing `overseer-mark` waits before it is reported again | `5` |
| Recording settings | `ORCH_FLEET_LOG_ROW_BYTES`, `ORCH_TAKEOVER_ROWS`, `ORCH_RECORD_RETENTION_DAYS`, `ORCH_PROGRESS_REPORT_DIR`: [recording policy](schemas/workflow-state.md#recording-policy) | |
| Report settings | `ORCH_REPORT`, `ORCH_REPORT_EVERY_MINUTES`, `ORCH_REPORT_EVERY_ISSUES`, `ORCH_REPORT_UPCOMING`, `ORCH_REPORT_COLUMNS`: `oversee-report --help` | |
| Watch settings | `ORCH_WATCH_TAIL_LINES`, `ORCH_WATCH_PREPARE_SECS`: `oversee-watch --help` § Environment | |
| `ORCH_LANE_HOST` | Provider `lane-host` runs: an executable script path or `local`. `open-terminal` launches through it; `--host` overrides. [Host protocol](schemas/lane-host.md) | `local` |
| `QA_PERF_PATHS` | Space-separated path globs whose modification adds the `needs-perf-test` QA signal | empty |
| `RECONCILE_STALE_HOURS` | Hours before an In Progress or In Review item counts as started-stale in `reconcile-work-items` sweeps | `24` |
| `WORKTREE_CLI` | Path to the worktree CLI `open-terminal` drives; empty resolves the installed worktree skill's script | resolved |
| Review-gate settings | `REVIEW_GATE_MODE`, `PR_REVIEW_GATE`, `PR_REVIEW_CHECK`, `PR_REVIEW_WAIT_SECS`: [references/gates.md](references/gates.md) | |
| `ORCH_LANE_MAX_PCT` | Usage share at or above which `lanes pick` refuses an account; the bucket it reads and its overrides: `lanes --help`, `open-terminal --help` | `95` |
| Lane settings | `ORCH_LANE_DIRS`, `ORCH_LANE_ALIASES`, `ORCH_LANE_EXCLUDE`, `ORCH_LANE_RETIRE`, `ORCH_LANES_USAGE_TTL`, `ORCH_LANES_USAGE_MAX_AGE`, `ORCH_TMUX_VERIFY_SECS`, `ORCH_LANE_SSH_PROMPT_SECS`, `ORCH_TMUX_SESSION`: `lanes --help`, `open-terminal --help` | |
| `ORCH_SIZE_RENDER_ROOTS` | Render-mirror roots excluded from production and test counts when their source changes in the same branch | `.agents .claude .codex .pi` |
| `ORCH_SIZE_TEST_PATHS` | Path globs counted as test lines in size reports and cut comparisons | empty |

`ORCH_MERGE_BYPASS` instructs the lane and grants it nothing. A direct merge lands only where the organization has given the merging account a ruleset bypass on the base branch. Without that grant GitHub refuses it and the PR takes the queue.

The fast path gives up what the queue provides: serialization against other merges on that base, and the late-findings dequeue `queue-wait` performs.

Maintainer notes and the test entry point: [DEVELOPMENT.md](DEVELOPMENT.md).
