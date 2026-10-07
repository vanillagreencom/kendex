# Orchestration

orch takes Linear or GitHub issues from implementation to merge with coding and review agents. An overseer can run many issues at once, each in its own agent session, called a lane.

## Features

- `orch start` takes one issue from its worktree to merge.
- `orch oversee` launches one lane per unblocked issue, reports merges, lane questions, stopped lanes, new Linear issues and GitHub security alerts as events through `oversee-watch`, takes each PR to merge, then runs the post-merge steps and, off a hosted fleet, refreshes the consumer repositories when a merge changes shipped packages.
- `lane-mail` carries questions, notices and directives between a lane and the overseer as files in the lane's worktree, so messages need no tmux pane and also reach a lane on another machine.
- `oversee launch` opens a fleet's first overseer and `oversee register` records one opened by hand. `oversee-succeed` replaces an overseer in the same tmux position when its context, headroom, projected wall time, or qualifying-account trigger fires, or once it has ended or walled.
- `lanes` reads the usage of each Claude Code, Codex and Copilot CLI account it discovers or is configured with, and picks on projected room weighted by time to reset, never an overseer's; the watch reports an account that hit its usage limit and when the limit resets.
- `lane-host` runs lanes on another machine through a provider script, with the same mailbox and watch; `lane-host-ssh` is the included provider for SSH hosts. What runs where, which credential each part spends and how mail and handoff move on a hosted fleet: [docs/hosted-oversight.html](docs/hosted-oversight.html).
- `oversee-report` writes the overseer's status reports; `oversee-cycle` times each merge against its class target.
- `open-terminal --relaunch` resumes a stopped lane's own agent session, on the same account or another, and workflow state and handoff files let a lane or overseer continue where it stopped.
- Each review finding is fixed, filed as an issue or declined by the rules in [references/finding-disposition.md](references/finding-disposition.md), settings cap the review and CI-fix rounds.
- [references/secret-value.ere](references/secret-value.ere) matches GitHub and Slack tokens and private-key headers for scripts to refuse to send matching text or files. Its header states how to read it.
- Lanes run on Claude Code, Codex, OpenCode, Pi and Copilot CLI, remotely and in a fleet on all but OpenCode (Copilot fleets local); account selection, succession and preference entries cover all but OpenCode.

Dependabot security updates open the fleet's fix pull requests; an organization owner turns them on for every repository through an organization security configuration.

A directive is handed over at the lane's turn end where the harness runs hooks, and at the lane's next wait point where it does not. Delivery is checked on every harness kendex installs the mailbox hook on. That check runs on one machine at a time and is started by hand, so run it on a fleet's control machine to cover it.

## Install

```bash
kendex add vanillagreencom/kendex --skill orch
```

## How it works

The primary agent opens the PR and, by the merge policy, arms auto-merge where the base requires the review gate. `oversee-watch` waits until a lane needs attention, and the overseer then answers the lane's question, relaunches a stopped lane, or runs the post-merge steps after a merge.

## Setup

Requires jq, Bash 3.2, Python 3.8+, flock, setsid and timeout or gtimeout. Local lane-mail and the included SSH host provider use Python on the controlling machine. kendex installs the required skills. Add linear for Linear issues. Second-opinion and review-gate are optional.

Set defaults in `kendex.settings.toml` `[env]` and secrets in `.env.local`; installation adds no settings ([guide](kendex.settings.toml.example)).

Until KEN-2466 lands, the Claude Code agent renderer maps `haiku` to `sonnet` and prints one warning per run.

| Variable | Purpose | Default |
|---------|---------|---------|
| `ORCH_STATE_DIR` | Workflow state directory; the `--state-dir` flag wins where both are set | `tmp` |
| `OVERSEE_WATCH_STATE_DIR` | Directory for watch baselines, lane claims, the weekly walls recorded from lane banners and cached account usage, shared by `oversee-watch`, `lanes` and `open-terminal` | `tmp/oversee-watch` under the project root |
| `GH_ISSUE_PATTERN` | Regex for issue IDs in branch names, matched case-insensitively and canonicalized | `([A-Z]+-[0-9]+\|issue-[0-9]+)` |
| `CI_WAIT_NO_CHECKS_GRACE` | Seconds `ci-wait` keeps polling when no CI checks have registered before it fails | `600` |
| `CI_FIX_MAX_CYCLES` | Automatic ci-fix cycles for one PR, counted across the heads they push; a passing CI run clears the count | `6` |
| `REVIEW_MAX_CYCLES` | Re-review cycles per issue. `0`: one blockers-only fix round, accepted on its validation without re-review; `1`: one fix round and one re-review of its diff | `1` |
| `REVIEW_MAX_EXTERNAL_ROUNDS` | External comment-triage passes and automatic review-wait restarts on one PR head | `4` |
| `REVIEWER_SLOT_BUDGET` | Concurrent agent-session budget counting the primary; `0` is unlimited; reviews run in waves past it. On Codex, the cap `spawn-adapter slots` reports | `0` |
| `ORCH_USER_MODE` | `ceo` or `engineer`, and what each asks: [communication-modes.md](references/communication-modes.md) | `ceo` |
| `ORCH_DECISION_MODE` | `ask` presents decision points; `auto-recommended` takes the recommended one | `auto-recommended` |
| `ORCH_MERGE_AUTONOMY` | `auto` merges once every gate is green on authorization already given; `ask` requires it per merge | `auto` |
| `PM_CREATE_AUTONOMY` | Audit creation and cancellation: [project-management settings](../project-management/README.md#setup) | `ask`; `auto` under `ceo` |
| `ORCH_POST_MERGE_CMD` | Bash command that `scripts/post-merge` runs in the base checkout after synchronization. `ORCH_POST_MERGE_BEFORE` is the base before the oldest unprocessed synchronization; `ORCH_POST_MERGE_AFTER` is the current synchronized head. `sync-base` saves the first in `refs/kendex/post-merge-base`; only a successful or empty command advances it. A failed command stops before project refresh and verification and keeps the range for retry | empty |
| `PR_REVIEW_ON_TIMEOUT` | `proceed` advances only when no reviewer engaged and no thread is open; `block` reports the timeout | `proceed` |
| `ORCH_OVERSEER_LANES` | Fleet lane cap: `open-terminal --help` | `3` |
| `ORCH_CONNECTED_REPOS` | Blank-separated `OWNER/REPO` list of repositories the overseer may launch lanes in beside its own. `open-terminal` reads it in the overseer's checkout without the launcher's own value or `KENDEX_ENV_FILE`, which can be the launch checkout's, and matches it to a launch checkout's origin remote: `open-terminal --help`. `oversee-watch` and `oversee-report` run in the overseer's checkout, honor both, and read each one after their `--repo` values: `oversee-watch --help`, `oversee-report --help` | empty |
| `ORCH_WAKE_PROCESS` | `pgrep -f` wake pattern for `lane-mail-check`. Empty disables the check with no watch record | empty |
| `ORCH_WAKE_START` | Wake start command printed by the turn-end refusal. Empty disables the check with no watch record | empty |
| `ORCH_LANE_OUTPUT` | Lane pane output: [skill-rules.md](references/skill-rules.md) § Lane Output | `quiet` |
| `ORCH_ROUND_PRUNE_DISK_PCT` | Disk use percent at or past which `round-prune` clears the item worktree's Cargo output before a dev round: [skill-rules.md](references/skill-rules.md) § Round Closure | `75` |
| `ORCH_HANDOFF_CONTEXT_PCT` | Earlier handoff percentage (1 to 100, capped at 90); strict comparison and independent token limit: [context rule](references/oversee-events.md#judgement-rules) | `90` |
| `ORCH_HANDOFF_HEADROOM_PCT` | Account headroom at or below which `lanes context` marks a live lane for handoff and `lane-mail-check` refuses its turn end, Codex credits exempt: `lanes --help` | `3` |
| `ORCH_OVERSEER_PREFERENCE` | Comma-separated `harness:model:effort` entries `oversee launch` and `oversee-succeed` try in order; grammar: [guide](kendex.settings.toml.example) § Fleet. Empty names none | `claude:claude-opus-5-5:high,codex:gpt-6.1-sol:high` |
| `ORCH_LANE_PREFERENCE` | Default-model order; explicit models keep the caller's route. [Lane preference](references/lane-directive.md#lane-preference) | unset |
| Owner-ask settings | `ORCH_QUESTION_TOOL`, `ORCH_ASK_WAIT_MINUTES`: [guide](kendex.settings.toml.example) § Talking to you | |
| `ORCH_OVERSEER_SUCCESSION` | `on` lets `oversee-succeed` launch the successor overseer; `off` launches none and turns off the account-mark turn-end refusals, not the context one: `oversee-watch --help` | `on` |
| `ORCH_OVERSEER_DEAD_PASSES` | Watch passes that read the overseer exited or walled before it is reported: `oversee-watch --help` | `2` |
| `ORCH_OVERSEER_HEADROOM_PCT` | Account headroom at or below which the overseer succeeds onto an account above it and `lane-mail-check` refuses its turn end, Codex credits exempt | `5` |
| `ORCH_OVERSEER_WALL_MINUTES` | Projected wall minutes that fire overseer succession. `0` disables it | `20` |
| `ORCH_OVERSEER_SUCCESSOR_ACCOUNTS` | Qualifying-account count that fires succession: `oversee-succeed --help`. `0` disables it | `1` |
| `ORCH_OVERSEER_MARK_REPEAT` | Watch passes a standing `overseer-mark` waits before it repeats | `5` |
| Recording settings | `ORCH_FLEET_LOG_ROW_BYTES`, `ORCH_TAKEOVER_ROWS`, `ORCH_RECORD_RETENTION_DAYS`, `ORCH_PROGRESS_REPORT_DIR`: [recording policy](schemas/workflow-state.md#recording-policy) | |
| `ORCH_REPORT_QUIET_HOURS` | Owner-local window: reports write and print, with no owner notice. Empty disables it. The first due morning brief covers work since the last sent report. Asks and critical notices stay immediate. | `0-7` |
| `ORCH_OWNER_TIME_ZONE` | Report time zone | `America/Los_Angeles` |
| Watch settings | `ORCH_WATCH_*`, `ORCH_EXTERNAL_TRIAGE`, `ORCH_SECURITY_ALERTS`: `oversee-watch --help` | |
| `ORCH_OVERSEER_REVIEW_TOKEN_FILE` | `overseer-approve`'s app token: an absolute path, one line, mode 600, outside lane roots, swapped atomically before expiry by the control VM (hosted) or fleet worker (local) | |
| `ORCH_LANE_HOST` | `lane-host`'s host: `local`, `claude-cloud` (Claude Code's own cloud sessions) or a provider executable, each a [host kind](schemas/lane-host.md#host-kinds); `ORCH_LANE_HOST_MAX_CALLS` and `ORCH_LANE_HOST_BUSY_WAIT_SECS` cap a provider: [Host protocol](schemas/lane-host.md) | `local` |
| `ORCH_OVERSEER_HOST` | Runtime of the overseer's own session: `tmux`, the included provider; another is refused as `runtime-unsupported`. [Protocol](schemas/overseer-host.md) | `tmux` |
| `QA_PERF_PATHS` | Space-separated path globs whose modification adds the `needs-perf-test` QA signal | empty |
| `QA_UI_PATHS` | Space-separated path globs whose modification adds the `needs-ui-review` QA signal | empty |
| `QA_UI_DESIGN_DOC` | Repository path of the design-system doc the `frontend` agent builds to and the `needs-ui-review` pass judges against; unset is reported as a gap | empty |
| `RECONCILE_STALE_HOURS` | Hours before an In Progress or In Review item counts as started-stale in `reconcile-work-items` sweeps | `24` |
| `WORKTREE_CLI` | Path to the worktree CLI `open-terminal` drives; empty resolves the installed worktree skill's script | resolved |
| Review-gate settings | `PR_REVIEW_WAIT_SECS`, `PR_COPILOT_REQUESTS`: [references/gates.md](references/gates.md) | |
| `ORCH_LANE_MAX_PCT` | Usage share at or above which `lanes pick` refuses an account, Codex credits exempt; bucket, overrides, other lane settings: `lanes --help`, `open-terminal --help` | `95` |
| `ORCH_LANE_CODEX_CREDIT_FLOOR` | Credits a spent Codex account must exceed to stay pickable, after plan room, since credits never reset. Provisional; lane-day arithmetic: [guide](kendex.settings.toml.example) | `5000` |
| `ORCH_SIZE_RENDER_ROOTS` | Render-mirror roots excluded from production and test counts when their source changes in the same branch | `.agents .claude .codex .pi` |
| `ORCH_SIZE_TEST_PATHS` | Extra test-path globs for the shared CI change classification | empty |

`ORCH_OVERSEER_PREFERENCE` reads the deprecated `harness:positive-integer:effort` form until the next major release: [kendex.settings.toml.example](kendex.settings.toml.example) § Fleet.

Launch settings and Codex compaction limits: [skill-rules.md](references/skill-rules.md#coordination), Compaction.

Every lane merges its own pull request, past the merge queue or through it, as the github skill's `pr-merge --help` § Merge route says.

Maintainer notes and test entry point: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/orch/DEVELOPMENT.md).

## Licence

MIT, in the repository's LICENSE file.
