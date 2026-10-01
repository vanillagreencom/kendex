# Orchestration

orch takes Linear or GitHub issues through implementation, review and merge with coding agents. A primary agent assigns each issue's work to coding and review agents, and an overseer can run many issues at once, each in its own agent session, called a lane.

## Install

```bash
kendex add vanillagreencom/kendex --skill orch
```

Requires jq, Bash 3.2, flock, setsid and timeout or gtimeout; the included SSH host provider also needs Python 3.8+ on the controlling machine. kendex installs the required skills. Add linear for Linear issues. Second-opinion and review-gate are optional.

## Features

- `orch start`, run in an issue's worktree, takes one issue to merge: a coding agent implements it, review agents check it, the coding agent applies required fixes, and orch merges it.
- `orch oversee` launches one lane per unblocked issue, reports merges, lane questions, stopped lanes, usage limits, new Linear issues and GitHub security alerts as events through `oversee-watch`, takes each PR to merge, then runs the post-merge steps and, off a hosted fleet, refreshes the consumer repositories when a merge changes shipped packages.
- `lane-mail` carries questions, notices and directives between a lane and the overseer as files in the lane's worktree, so messages need no tmux pane and also reach a lane on another machine.
- `oversee launch` opens a fleet's first overseer and `oversee register` records one opened by hand. `oversee-succeed` replaces an overseer in the same tmux position when its context, headroom, projected wall time, or qualifying-account trigger fires, or once it has ended or walled.
- `lanes` reads the usage of each Claude Code, Codex and Copilot CLI account it discovers or is configured with, and picks the one with the fewest lanes in flight under the threshold, never an overseer's; the watch reports an account that hit its usage limit and when the limit resets.
- `lane-host` runs lanes on another machine through a provider script, with the same mailbox and watch; `lane-host-ssh` is the included provider for SSH hosts. What runs where, which credential each part spends and how mail and handoff move on a hosted fleet: [docs/hosted-oversight.html](docs/hosted-oversight.html).
- `oversee-report` writes the overseer's status reports; `oversee-cycle` times each merge against its class target.
- `open-terminal --relaunch` resumes a stopped lane's own agent session, on the same account or another, and workflow state and handoff files let a lane or overseer continue where it stopped.
- Each review finding is fixed, filed as an issue or declined by the rules in [references/finding-disposition.md](references/finding-disposition.md), settings cap the review and CI-fix rounds, and `branch-size-check` compares the branch's added lines with the issue's expected size.
- [references/secret-value.ere](references/secret-value.ere) holds a pattern of secret values: GitHub and Slack tokens and private-key headers, for a package or a fleet script to refuse to send text or a file that matches it. Its header says how to read it.
- Lanes run on Claude Code, Codex, OpenCode, Pi and Copilot CLI, remotely and in a fleet on all but OpenCode (Copilot fleets local); account selection, succession and preference entries cover all but OpenCode.

Dependabot security updates open the fleet's fix pull requests; an organization owner turns them on for every repository through an organization security configuration.

A directive is handed over at the lane's turn end where the harness runs hooks, and at the lane's next wait point where it does not. Delivery is checked on every harness kendex installs the mailbox hook on. That check runs on one machine at a time and is started by hand, so run it on a fleet's control machine to cover it.

## How it works

The primary agent opens the PR and, by the merge policy, arms auto-merge where the base requires the review gate. In overseer mode, the overseer selects unblocked issues and launches a lane for each, and every lane runs the single-issue cycle. `oversee-watch` waits until a lane needs attention, and the overseer then answers the lane's question, relaunches a stopped lane, or runs the post-merge steps after a merge.

## Settings

Non-secret settings go in committed `kendex.settings.toml` under `[env]`; secrets in `.env.local`. Nothing is marked required, so installing writes nothing to your settings file; [kendex.settings.toml.example](kendex.settings.toml.example) comments the keys worth changing first.

| Variable | Purpose | Default |
|---------|---------|---------|
| `ORCH_STATE_DIR` | Workflow state directory; the `--state-dir` flag wins where both are set | `tmp` |
| `OVERSEE_WATCH_STATE_DIR` | Directory for watch baselines, lane claims and cached account usage, shared by `oversee-watch`, `lanes` and `open-terminal` | `tmp/oversee-watch` under the project root |
| `GH_ISSUE_PATTERN` | Regex for issue IDs in branch names, matched case-insensitively and canonicalized | `([A-Z]+-[0-9]+\|issue-[0-9]+)` |
| `CI_WAIT_NO_CHECKS_GRACE` | Seconds `ci-wait` keeps polling when no CI checks have registered before it fails | `600` |
| `CI_FIX_MAX_CYCLES` | Automatic ci-fix cycles for one PR, counted across the heads they push; a passing CI run clears the count | `6` |
| `REVIEW_MAX_CYCLES` | Internal re-review cycles per issue; the number set is the number of re-entries allowed | `1` |
| `REVIEW_MAX_EXTERNAL_ROUNDS` | External comment-triage passes and automatic review-wait restarts on one PR head | `4` |
| `REVIEWER_SLOT_BUDGET` | Concurrent agent-session budget counting the primary; `0` is unlimited; reviews run in waves past it. On Codex, the cap `spawn-adapter slots` reports | `0` |
| `ORCH_USER_MODE` | `ceo` or `engineer`, and what each asks: [communication-modes.md](references/communication-modes.md) | `ceo` |
| `ORCH_DECISION_MODE` | `ask` presents decision points; `auto-recommended` takes the recommended one | `auto-recommended` |
| `ORCH_MERGE_AUTONOMY` | `auto` merges once every gate is green on authorization already given; `ask` requires it per merge | `auto` |
| `PM_CREATE_AUTONOMY` | Audit creation and cancellation: [project-management settings](../project-management/README.md#settings) | `ask`; `auto` under `ceo` |
| `ORCH_POST_MERGE_CMD` | Bash command that `scripts/post-merge` runs in the base checkout after synchronization. `ORCH_POST_MERGE_BEFORE` is the base before the oldest unprocessed synchronization; `ORCH_POST_MERGE_AFTER` is the current synchronized head. `sync-base` saves the first in `refs/kendex/post-merge-base`; only a successful or empty command advances it. A failed command stops before project refresh and verification and keeps the range for retry | empty |
| `PR_REVIEW_ON_TIMEOUT` | `proceed` advances only when no reviewer engaged and no thread is open; `block` reports the timeout | `proceed` |
| `ORCH_OVERSEER_LANES` | Fleet lane cap: `open-terminal --help` | `3` |
| `ORCH_LANE_OUTPUT` | Lane pane output: [skill-rules.md](references/skill-rules.md) § Lane Output | `quiet` |
| `ORCH_ROUND_PRUNE_DISK_PCT` | Disk use percent at or past which `round-prune` clears the item worktree's Cargo output before a dev round: [skill-rules.md](references/skill-rules.md) § Round Closure | `75` |
| `ORCH_HANDOFF_CONTEXT_PCT` | Earlier handoff percentage (1 to 100, capped at 90); strict comparison and independent token limit: [context rule](references/oversee-events.md#judgement-rules) | `90` |
| `ORCH_HANDOFF_HEADROOM_PCT` | Account headroom at or below which `lanes context` marks a live lane for handoff and the `lane-mail-check` turn-end hook refuses that lane's turn end, read against the binding bucket | `3` |
| `ORCH_OVERSEER_PREFERENCE` | Comma-separated `harness:model:effort` entries `oversee launch` and `oversee-succeed` try in order; grammar: [kendex.settings.toml.example](kendex.settings.toml.example) § Fleet. Empty names none | `claude:fable:high,claude:claude-opus-5-5:high,codex:gpt-6-astra:high,codex:gpt-5.6-sol:high` |
| Owner-ask settings | `ORCH_QUESTION_TOOL`, `ORCH_ASK_WAIT_MINUTES`: [kendex.settings.toml.example](kendex.settings.toml.example) § Talking to you | |
| `ORCH_OVERSEER_SUCCESSION` | `on` lets `oversee-succeed` launch the successor overseer; `off` launches none and turns off the account-mark turn-end refusals, not the context one. A live overseer asks the user to start the next session; `oversee-watch --help` states the rest | `on` |
| `ORCH_OVERSEER_DEAD_PASSES` | Watch passes that read the overseer exited or walled before it is reported: `oversee-watch --help` | `2` |
| `ORCH_OVERSEER_HEADROOM_PCT` | Account headroom at or below which the overseer succeeds onto an account above it and `lane-mail-check` refuses its turn end | `5` |
| `ORCH_OVERSEER_WALL_MINUTES` | Projected wall minutes that fire overseer succession. `0` disables it | `20` |
| `ORCH_OVERSEER_SUCCESSOR_ACCOUNTS` | Qualifying-account count that fires succession, by the rule `oversee-succeed --help` states. `0` disables it | `1` |
| `ORCH_OVERSEER_MARK_REPEAT` | Watch passes a standing `overseer-mark` waits before it repeats | `5` |
| Recording settings | `ORCH_FLEET_LOG_ROW_BYTES`, `ORCH_TAKEOVER_ROWS`, `ORCH_RECORD_RETENTION_DAYS`, `ORCH_PROGRESS_REPORT_DIR`: [recording policy](schemas/workflow-state.md#recording-policy) | |
| Report settings | `ORCH_REPORT`, `ORCH_REPORT_EVERY_MINUTES`, `ORCH_REPORT_EVERY_ISSUES`, `ORCH_REPORT_UPCOMING`, `ORCH_REPORT_COLUMNS`, `ORCH_REPORT_SUMMARY_LINES`: `oversee-report --help` | |
| Watch settings | `ORCH_WATCH_*`, `ORCH_EXTERNAL_TRIAGE`, `ORCH_SECURITY_ALERTS`: `oversee-watch --help` | |
| `ORCH_LANE_HOST` | `lane-host`'s provider: an executable or `local`; `ORCH_LANE_HOST_MAX_CALLS` and `ORCH_LANE_HOST_BUSY_WAIT_SECS` cap it: [Host protocol](schemas/lane-host.md) | `local` |
| `ORCH_OVERSEER_HOST` | Runtime of the overseer's own session: `tmux`, the included provider; another is refused as `runtime-unsupported`. [Protocol](schemas/overseer-host.md) | `tmux` |
| `QA_PERF_PATHS` | Space-separated path globs whose modification adds the `needs-perf-test` QA signal | empty |
| `RECONCILE_STALE_HOURS` | Hours before an In Progress or In Review item counts as started-stale in `reconcile-work-items` sweeps | `24` |
| `WORKTREE_CLI` | Path to the worktree CLI `open-terminal` drives; empty resolves the installed worktree skill's script | resolved |
| Review-gate settings | `PR_REVIEW_WAIT_SECS`: [references/gates.md](references/gates.md) | |
| `ORCH_LANE_MAX_PCT` | Usage share at or above which `lanes pick` refuses an account; the bucket it reads and its overrides: `lanes --help`, `open-terminal --help` | `95` |
| Lane settings | `ORCH_LANE_BURN_PCT_PER_HOUR`, `ORCH_LANE_DIRS`, `ORCH_LANE_ALIASES`, `ORCH_LANE_EXCLUDE`, `ORCH_LANE_RETIRE`, `ORCH_LANE_COPILOT_POOL` (overrides the Copilot pool read live from the lane host), `ORCH_LANES_USAGE_TTL`, `ORCH_LANES_USAGE_MAX_AGE`, `ORCH_TMUX_VERIFY_SECS`, `ORCH_LANE_SSH_PROMPT_SECS`, `ORCH_TMUX_SESSION`: `lanes --help`, `open-terminal --help` | |
| `ORCH_SIZE_RENDER_ROOTS` | Render-mirror roots excluded from production and test counts when their source changes in the same branch | `.agents .claude .codex .pi` |
| `ORCH_SIZE_TEST_PATHS` | Path globs counted as test lines in size reports and cut comparisons | empty |

`ORCH_OVERSEER_PREFERENCE` reads deprecated `harness:positive-integer:effort` until the next minor release after this change. It uses the caller's model at the supplied effort and warns once per run. Replace the number with a model name: `harness:model:effort`.

Launch settings and Codex compaction limits: [skill-rules.md](references/skill-rules.md#coordination), Compaction.

Every lane merges its own pull request, past the merge queue or through it, as the github skill's `pr-merge --help` § Merge route says.

Maintainer notes and test entry point: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/orch/DEVELOPMENT.md).
