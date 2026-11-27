# Settings

Read when a workflow, a reference or a `--help` names a setting and the task needs where it is set, what it changes or its default. For example overrides, see [kendex.settings.toml.example](../kendex.settings.toml.example). Installation adds no settings.

Look up orch runtime defaults by key in [settings.rs](../runtime/src/settings.rs), at the key's use in `load`. Where another reader supplies a default, the section for that setting points to the reader.

## Where a setting is set

The runtime reads each key from the first of these that sets it:

1. The caller's own environment.
2. The private env file: `.env.local`, or the project file `KENDEX_ENV_FILE` names. `--no-private-env` skips it.
3. `.kendex/settings.toml`, under `[env]`.
4. `kendex.settings.toml`, under `[env]`.

- An empty value is an unset one.
- Commit shared defaults in `kendex.settings.toml`.
- Put a secret or a personal override in the private env file.

The private env file is read as data and never run, one `KEY=VALUE` line at a time, with an optional leading `export`. Its two readers differ on a value outside a plain form:

- The runtime (`orch-runtime`, `agent-runtime`) reads a single-quoted string, a double-quoted string or a bare word.
- The runtime reads `$HOME`, `${HOME}` and a leading `~` as the home.
- The runtime passes over any other shell form of a key only some verbs read. Such a line for `ORCH_STATE_DIR` refuses every verb.
- The shell loader that skill scripts use, `skills/change-scope/scripts/lib/kendex-env.sh`, reads a bare word of letters, digits and `_./:@%+,=-`, or a quoted string with no `$` or backtick inside double quotes.
- Any other value of a key a script asks for fails that script's load.
- The shell loader reads no home form.

Write a value both readers read alike: a bare word or a quoted string with no `$`, `~` or backtick.

## Repository and tools

| Key | What it changes |
|---|---|
| `ORCH_STATE_DIR` | The per-item state folder, relative to the main checkout unless absolute. |
| `ORCH_ARCHIVE_ROOT` | Where the retention duty and an item's close-out archive what they remove. Leaving it unset disables archiving. |
| `ORCH_POST_MERGE_CMD` | A Bash command `scripts/post-merge` runs in the base checkout after a sync. |
| `RECONCILE_STALE_HOURS` | Hours since its last update after which `orch-runtime reconcile-items` reports a started item with no open pull request as `started-stale`. |
| `RECONCILE_GH_CLI` | The `gh` program `reconcile-items` runs. |
| `WORKTREE_CLI` | The worktree program the runtime drives. |
| `ORCH_AGENT_RUNTIME` | The agent-runtime wrapper the wake duty delivers through. |
| `LANE_MAIL_CLI` | The mailbox program a lane close asks for unanswered asks and for a hosted lane's last mail before its sandbox goes. |
| `CHANGE_SCOPE_PATHS_CLI` | The program the lane admission reads a range's changed paths through. |
| `OVERSEE_WATCH_TRACKER` | The tracker program the watch's tracker duty reads through. |
| `OVERSEE_WATCH_PR_WATCH` | The reducer the watch's GitHub duty runs per repository. |
| `LINEAR_TEAM` | The Linear team the tracker duties, the report and the admission read. |

The keys' rules, in the table's order:

- `ORCH_STATE_DIR`: `--state-dir` wins over it.
- `ORCH_ARCHIVE_ROOT`: a set value is an absolute path outside linked worktrees and state or mailbox folders.
- `ORCH_ARCHIVE_ROOT`: any other value refuses each archive write; a verb that writes no archive still runs.
- `ORCH_POST_MERGE_CMD`: `ORCH_POST_MERGE_BEFORE` and `ORCH_POST_MERGE_AFTER` name the range.
- `ORCH_POST_MERGE_CMD`: a failed command keeps the range for the next run.
- `RECONCILE_STALE_HOURS`: `--stale-hours` wins.
- `LINEAR_TEAM`: unset, the tracker duties stay off.

## Review and CI

See [verify_review.rs](../runtime/src/ops/verify_review.rs) for how `verify-review` reads the refresh policy. The calls to `orch-env` in [base publication](../workflows/base-publication.md#5-verify-the-published-head) and [reviewer persistence](skill-rules.md#reviewer-persistence-is-budget-conditional) supply the fallbacks for `CI_WAIT_MAX_SECS` and `REVIEWER_SLOT_BUDGET`, respectively.

| Key | What it changes |
|---|---|
| `ORCH_DELIVERY` | `pr` delivers through a pull request. `push-base` keeps the tier's local checks and review, then pushes the resolved base branch. |
| `ORCH_PR_ORDER` | Publication order: `review-first`, `open-first` or `push-first`. |
| `ORCH_STAGES` | The optional stages the consumer runs, space-separated: `external-review`, `local-review`, `preflight`, `doc-limits`, `git-hooks`, `focused-proof`. |
| `PR_REVIEW_WAIT_SECS` | The reviewer's period on a head: [gates.md](gates.md). |
| `PR_REVIEW_ON_TIMEOUT` | What a spent review period answers: [gates.md](gates.md). |
| `PR_COPILOT_REQUESTS` | Whether orch requests a Copilot review: [gates.md](gates.md). |
| `ORCH_COPILOT_HOLD_SECS` | The bound on Copilot's work in flight on a head, in whole seconds above zero. |
| `ORCH_OVERSEER_REVIEW_TOKEN_FILE` | The app token file `approve-head` reads on every call. |
| `ORCH_OVERSEER_REVIEW_LOGIN` | The token app's bot login. |
| `CI_WAIT_MAX_SECS` | The budget of a workflow's CI wait, the repeated `verify-pr` call. |
| `QUEUE_WAIT_ARMED_MINUTES` | Minutes the merge workflow keeps waiting on an armed head whose checks are pending or unmergeable, from the first such result on that head. |
| `QUEUE_WAIT_ARM_GRACE` | Seconds `queue-watch` keeps polling a pull request that no poll has seen queued or armed, before it answers `not_queued`. |
| `QUEUE_WAIT_CONFIRM_POLLS` | Consecutive polls a `conflicting`, `ejected` or `disarmed` reading must hold before `queue-watch` ends on it. |
| `QUEUE_WAIT_PROBE_INTERVAL` | Least seconds between two review-thread probes of `queue-watch`, and between two of its check probes. |
| `QUEUE_WAIT_REACH_CMD` | A Bash command `queue-watch` runs in the project's checkout on an `ejected` verdict. |
| `CI_FIX_MAX_CYCLES` | Automatic ci-fix cycles for one pull request, counted across the heads they push. |
| `REVIEW_MAX_CYCLES` | Re-review cycles per item. |
| `REVIEW_MAX_EXTERNAL_ROUNDS` | External comment-triage passes and automatic review-wait restarts on one head. |
| `REVIEWER_SLOT_BUDGET` | Concurrent agent sessions a review may hold, the primary counted. `0` is unlimited. |
| `REVIEW_GATE_REFRESH_REVIEW`, `REVIEW_GATE_REFRESH_BRANCH`, `REVIEW_GATE_REFRESH_AUTHOR` | The refresh pull request's review route, branch and author. |

The keys' rules, in the table's order:

- `ORCH_PR_ORDER`: unset, the order follows the repository's visibility. `orch-runtime pr order --help` owns the defaults.
- `ORCH_PR_ORDER`: it decides when the pull request opens. No validation start or mode read takes it as an input.
- `ORCH_STAGES`: it is read from the base checkout's files alone, never the environment. In those files an empty value selects no optional stages. For the fallback when the key is absent, see `Stages::of` in [policy.rs](../runtime/src/policy.rs).
- `ORCH_STAGES`: a chosen stage runs whether or not its tool is installed.
- `ORCH_COPILOT_HOLD_SECS`: `approve-head` with `hold_copilot` counts it from that wait's start.
- `ORCH_COPILOT_HOLD_SECS`: what the hold does is [copilot-head-notices.md § The Copilot hold](copilot-head-notices.md#the-copilot-hold).
- `ORCH_COPILOT_HOLD_SECS`: the token app needs the repository's Checks read permission.
- `ORCH_OVERSEER_REVIEW_TOKEN_FILE`: keep it outside lane roots.
- `ORCH_OVERSEER_REVIEW_TOKEN_FILE`: the host that renews the token swaps the file atomically before expiry.
- `ORCH_OVERSEER_REVIEW_TOKEN_FILE`: the file rules are [copilot-head-notices.md § What the runtime checks](copilot-head-notices.md#what-the-runtime-checks).
- `ORCH_OVERSEER_REVIEW_LOGIN`: each approval records it, and its read-back matches it.
- `ORCH_OVERSEER_REVIEW_LOGIN`: unset, `approve-head` refuses before any call.
- `CI_WAIT_MAX_SECS`: set it above the longest required job.
- `QUEUE_WAIT_ARMED_MINUTES`: [merge-contracts.md § Armed budget](merge-contracts.md#armed-budget) reads it through `orch-env`.
- `QUEUE_WAIT_REACH_CMD`: its input is the group head's failed check names, one per line.
- `QUEUE_WAIT_REACH_CMD`: `QUEUE_REACH_CLASS`, `QUEUE_REACH_DOCS_ONLY` and `QUEUE_REACH_PATHS` (a file of paths) describe the change.
- `QUEUE_WAIT_REACH_CMD`: the command prints `outside NAME` or `within NAME` per check and exits 0.
- `QUEUE_WAIT_REACH_CMD`: a check left unanswered reads `unread`, and so do any other line, any other exit and an empty value.
- `CI_FIX_MAX_CYCLES`: a passing CI run clears the count.
- `REVIEW_MAX_CYCLES`: `0` allows one blockers-only fix round, accepted on its validation without re-review.
- `REVIEW_MAX_CYCLES`: `1` allows one fix round and one re-review of its diff.
- `REVIEWER_SLOT_BUDGET`: how reviews fit it is [skill-rules.md](skill-rules.md).
- `REVIEWER_SLOT_BUDGET`: on Codex, `agent-runtime subagent room --harness codex` reads the thread cap.
- `REVIEW_GATE_REFRESH_REVIEW`, `REVIEW_GATE_REFRESH_BRANCH`, `REVIEW_GATE_REFRESH_AUTHOR`: `verify-review` reads them from the base checkout's policy.

## Validation

`orch-runtime validate entry --help` describes how a start resolves its mode from these keys. See `prune_round` in [ops/item.rs](../runtime/src/ops/item.rs) for the `ORCH_ROUND_PRUNE_DISK_PCT` fallback.

| Key | What it changes |
|---|---|
| `DEV_VALIDATE_CMD` | The project's whole battery. |
| `DEV_VALIDATE_RANGE_CMD` | The command that validates the changes since a base. |
| `DEV_VALIDATE_SELECTION_CMD` | The selector that previews the command's own selection. |
| `DEV_VALIDATE_TEXT_CMD` | The docs mode's command. |
| `DEV_VALIDATE_CI_CONTEXT` | The required status-check context that runs the project's validation. |
| `DEV_VALIDATE_FINDING_PREFIX` | The prefix the project's commands print each finding with. |
| `ORCH_VALIDATE_MEMORY_MAX` | The memory a validation run's whole process tree is held to: whole bytes, or `K`, `M`, `G` or `T` in base 1024, at least `1G`. |
| `ORCH_ROUND_PRUNE_DISK_PCT` | Disk use percent, `1` to `100`, of the volume that holds the lane worktree's `target/`. |
| `ORCH_APPLE_WORKFLOW`, `ORCH_APPLE_LABELS` | The macOS run workflow, and the item labels that call for it. |

The keys' rules, in the table's order:

- `DEV_VALIDATE_CMD`: unset, a validation start refuses.
- `DEV_VALIDATE_TEXT_CMD`: an empty value stays set.
- `DEV_VALIDATE_FINDING_PREFIX`: unset, no run is reuse evidence.
- `ORCH_VALIDATE_MEMORY_MAX`: a value over the host's room refuses the start.
- `ORCH_ROUND_PRUNE_DISK_PCT`: at or past it, `prune-round` clears that Cargo output at a round's start.
- `ORCH_APPLE_WORKFLOW`, `ORCH_APPLE_LABELS`: `dev-return write`'s Apple gate reads them.

## Talking to you

See [orch-env](../scripts/orch-env) for the mode and its composed defaults, [agent-runtime settings](../../agent-runtime/runtime/src/settings.rs) for the question tool, and `lane-mail ask --help` for the owner ask deadline.

| Key | What it changes |
|---|---|
| `COMMUNICATION_TECHNICAL` | Wording for owner messages. See [Presentation](communication-modes.md#presentation). |
| `ORCH_USER_MODE` | The [autonomy defaults](communication-modes.md#composition). |
| `ORCH_DECISION_MODE` | `ask` presents decision points. `auto-recommended` takes the recommended one. |
| `ORCH_MERGE_AUTONOMY` | `ask` requires authorization per merge. `auto` merges once every gate is green. |
| `PM_CREATE_AUTONOMY` | Audit creation and cancellation: project-management's README. |
| `AGENT_RUNTIME_QUESTION_TOOL` | `off` or `overseer`: whether a launched controller keeps the harness's question dialog. |
| `ORCH_ASK_WAIT_MINUTES` | Minutes an owner ask waits when `lane-mail` gets no `--wait`. |
| `ORCH_OWNER_EMAIL` | The owner's tracker account, whose comments answer a tracker-posted ask. |
| `ORCH_OWNER_ASK_LABEL` | The label a tracker-posted ask carries. |
| `ORCH_VERIFY_SCHEDULE` | Free text naming where and how often `/orch verify` runs, such as a routine or a cron job on the base checkout. |

The keys' rules, in the table's order:

- `ORCH_USER_MODE`: the default is `engineer`. An unrecognized value uses the default.
- `AGENT_RUNTIME_QUESTION_TOOL`: a worker never keeps the dialog.
- `ORCH_OWNER_EMAIL`: the answer read needs both this key and `ORCH_OWNER_ASK_LABEL`.
- `ORCH_VERIFY_SCHEDULE`: it starts nothing.
- `ORCH_VERIFY_SCHEDULE`: a Stop with open boxes needs it: [oversee.md](../workflows/oversee.md) § 5.

## Reports

`Policy::read` in [watch/report.rs](../runtime/src/watch/report.rs) supplies defaults and judges the settings at the report. A value outside its form refuses the report.

| Key | What it changes |
|---|---|
| `ORCH_REPORT` | `on` or `off`: whether the overseer writes progress reports. |
| `ORCH_REPORT_EVERY_MINUTES` | Minutes between timed reports. `0` turns the timer off. |
| `ORCH_REPORT_EVERY_ISSUES` | Items finished between reports. `0` turns it off. |
| `ORCH_REPORT_UPCOMING` | Upcoming items a report lists. |
| `ORCH_REPORT_QUIET_HOURS` | Owner-local hours in which the overseer writes and prints a report with no owner notice. Empty turns quiet hours off. |
| `ORCH_OWNER_TIME_ZONE` | The zone the quiet hours and report times read in. |

What stays immediate during `ORCH_REPORT_QUIET_HOURS`: [oversee-events.md](oversee-events.md), `report-due`.

## Fleet lanes

Launch settings and Codex compaction: [skill-rules.md](skill-rules.md) § Coordination.

See [provider.rs](../runtime/src/provider.rs) for provider call limits and waits, [agent-runtime settings](../../agent-runtime/runtime/src/settings.rs) for the launch settings it reads, and [effects/grants.rs](../runtime/src/effects/grants.rs) for the `SECOND_OPINION_MODELS` fallback used by lane grants. For target selection, see `second-opinion --help`.

| Key | What it changes |
|---|---|
| `ORCH_OVERSEER_LANES` | The fleet cap: the lanes of every kind but `claude-cloud` that a launch's admission counts. |
| `ORCH_OVERSEER_CLOUD_LANES` | The Claude cloud sessions one overseer holds at once. |
| `ORCH_LANE_PREFERENCE` | The `harness[@host]:model:effort` entries a lane launch walks (`orch-runtime lane walk`). |
| `ORCH_LANE_OUTPUT` | `quiet` or `normal`: what a lane prints in its pane, stated in its brief. |
| `ORCH_LANE_HOST` | The lane host: `local`, `claude-cloud` or a provider executable: [lane-host.md](../schemas/lane-host.md) § Host kinds. |
| `ORCH_VALIDATE_HOST` | The host a `validate entry --host` run goes to, in `ORCH_LANE_HOST`'s forms: [lane-host.md](../schemas/lane-host.md) § Host selection. |
| `ORCH_LANE_HOST_MAX_CALLS`, `ORCH_LANE_HOST_BUSY_WAIT_SECS` | The provider's long-call cap per home, and the seconds to wait at it. |
| `ORCH_LANE_HOST_SHORT_MAX_CALLS`, `ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS` | The independent short-call cap and wait, so mailbox reads run while long calls wait. |
| `ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S` | Seconds the provider's `accounts` verb may take. `0` asks for no bound. |
| `ORCH_LANE_CLOUD_REPOS` | `<name>=<owner>/<repo>` pairs: the repository each account can reach. |
| `ORCH_LANE_CLOSE_SECS` | Seconds a lane stop waits after SIGTERM before SIGKILL. |
| `ORCH_LANE_WRITABLE` | Further folders a confined local lane may write, `:`-separated, each absolute or `~/`. |
| `SECOND_OPINION_MODELS` | The second-opinion roster a lane's review walks. |
| `ORCH_MODEL_RECOVERY_LIMIT` | Model recoveries that may relaunch a lane since its last reset. |
| `AGENT_RUNTIME_TMUX_VERIFY_SECS` | Seconds a launch waits for the harness to come up at its composer, the bound of each pane wait, and how long a started fleet server has to answer before `tmux-server-unstarted`. |
| `AGENT_RUNTIME_JOB_CLAIM_SECS` | Seconds a transfer's or a stop's caller waits for its detached job to claim the intent. |
| `AGENT_RUNTIME_TMUX_SESSION` | The tmux session every harness window opens in, where the caller names none. |
| `AGENT_RUNTIME_LAUNCH_PERMISSION` | `bypass` runs every launch unattended. `native` keeps the harness's own prompts. |
| `AGENT_RUNTIME_HARNESS_BINARIES` | `harness=/absolute/path` pairs, comma-separated, for a harness not on `PATH`. |

The keys' rules, in the table's order:

- `ORCH_LANE_PREFERENCE`: unset, a launch takes the model it names.
- `ORCH_LANE_PREFERENCE`: the grammar is the example's § Fleet.
- `ORCH_VALIDATE_HOST`: unset, host runs are off. A `--host` start takes the local route, and no host step runs.
- `ORCH_VALIDATE_HOST`: a stop of a host run by its directory (`validate stop --run-dir`), and a lane close's or a round recovery's stop of its worktree, read it from the stopping process's settings, never from the run folder.
- `ORCH_VALIDATE_HOST`: `validate entry --stop` never reads it, since that stop's settings are the worktree's, which the lane writes.
- `ORCH_LANE_CLOUD_REPOS`: a `cloud-session` pick admits an account on it.
- `ORCH_LANE_WRITABLE`: it is read from the overseer's settings alone, never the lane's tree.
- `ORCH_LANE_WRITABLE`: a fleet whose `origin` is a local path or a `file://` remote names that repository here, or its lanes cannot push.
- `ORCH_LANE_WRITABLE`: an entry that is relative, the home, a folder holding the home, or inside an account seat refuses the launch.
- `SECOND_OPINION_MODELS`: a confined lane's grants bind each listed harness's accounts.
- `ORCH_MODEL_RECOVERY_LIMIT`: the recovery that would reach it is refused and logged.

A local lane on Linux runs confined, except a Copilot CLI lane and a Codex lane whose home holds a link leading outside its grants, named `linked-seat` in its launch record and in `orch-runtime ready`. Every lane on macOS runs unconfined.

## Accounts

The account judge, `orch-runtime lane pick`, reads these through [agent-runtime settings](../../agent-runtime/runtime/src/settings.rs). See `AccountSettings::read_except_retirements` for the judge's defaults and `account_state_dir` for the records folder.

| Key | What it changes |
|---|---|
| `AGENT_RUNTIME_ACCOUNT_DIRS` | The accounts the judge picks among: `:`-separated account folders, each absolute or relative to `HOME`. With no folders, the judge has no local candidates. |
| `AGENT_RUNTIME_ACCOUNT_ALIASES` | `<discovered name>=<alias>` pairs: the names the roster and the judge use. |
| `AGENT_RUNTIME_ACCOUNT_EXCLUDE` | Comma-separated account names, never paths. |
| `AGENT_RUNTIME_ACCOUNT_RETIRE` | Comma-separated `name=YYYY-MM-DD` pairs. |
| `AGENT_RUNTIME_ACCOUNT_MAX_PCT` | The usage share at or above which a pick refuses an account, read on the window that binds the lane and, for a launch, on the 5-hour window where the reading carries one. |
| `AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR` | A live session's hourly spend, in points of five hours' room, where its account measured no rate. `0` turns the charge off. |
| `AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT` | The headroom a controller hands off at, on its own account. |
| `AGENT_RUNTIME_CODEX_CREDIT_FLOOR` | The Codex credit balance above which a walled window still leaves the account pickable. |
| `AGENT_RUNTIME_CLOUD_CREDIT_FLOOR` | The dollars a cloud or API credit grant must exceed to be picked. |
| `AGENT_RUNTIME_COPILOT_POOL` | `<pi root>=<used>/<granted>` pairs: the Copilot pool each Pi root spends, as you state it, where no login or provider row reads it. |
| `AGENT_RUNTIME_ACCOUNT_STATE_DIR` | The account records' root: the usage cache and the wall records. Absolute or `~/`. |
| `AGENT_RUNTIME_USAGE_TTL` | Seconds the runtime serves a cached usage figure. `0` declines every cached figure. |
| `AGENT_RUNTIME_USAGE_MAX_AGE` | A caller's own pass interval. |
| `AGENT_RUNTIME_CLAUDE_USAGE_URL`, `AGENT_RUNTIME_CODEX_USAGE_URL`, `AGENT_RUNTIME_CLAUDE_TOKEN_URL` | The usage and token endpoints, for a host that reaches them through another address. |
| `AGENT_RUNTIME_CLAUDE_CLIENT_ID` | The OAuth client id a Claude token renewal posts with. |
| `CODEX_HOME`, `COPILOT_HOME` | A home the harness's CLI reads. |

The keys' rules, in the table's order:

- `AGENT_RUNTIME_ACCOUNT_DIRS`: the judge reads an entry's harness from the credential it holds.
- `AGENT_RUNTIME_ACCOUNT_EXCLUDE`: the judge still measures an excluded account, and never picks it.
- `AGENT_RUNTIME_ACCOUNT_RETIRE`: the judge picks the account until that UTC day, and measures it after.
- `AGENT_RUNTIME_ACCOUNT_RETIRE`: a provider row's `plan-ends` replaces the entry for that account.
- `AGENT_RUNTIME_ACCOUNT_RETIRE`: the judge reads this key at each pick, and the provider's row through the usage cache (`AGENT_RUNTIME_USAGE_TTL`).
- `AGENT_RUNTIME_ACCOUNT_MAX_PCT`: the judge weighs a launch on the projected room of the binding window and of the 5-hour window where the reading carries one; the smaller decides.
- `AGENT_RUNTIME_ACCOUNT_MAX_PCT`: a launch reads an account it would otherwise read `room` as `unmeasured` where its reading is older than one lane, at the burn its projection charges a window, takes to spend the room that window shows below this bound.
- `AGENT_RUNTIME_ACCOUNT_MAX_PCT`: the projection charges the window, for each live lane on the account and for the candidate, the burn below until the window's reset.
- `AGENT_RUNTIME_ACCOUNT_MAX_PCT`: a pick's `--max-pct` replaces this key.
- `AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR`: the 5-hour window is charged all of it an hour, a week 5/168 of it, a month 5/720.
- `AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR`: it sets how old a reading a launch still trusts, by the `AGENT_RUNTIME_ACCOUNT_MAX_PCT` rule above.
- `AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR`: each live lane, and the lane or controller a launch adds, is charged one hour of it, whatever the window's reset.
- `AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR`: in an overseer's choice among accounts, each other controller seated on an account is charged one hour as the candidate is.
- `AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR`: a rate the account measured on that window, shared among the spenders at the sample, replaces this key.
- `AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR`: where no lane was live at the sample, a lane is charged no less than this key.
- `AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT`: it holds nothing back from a worker: a worker's pick holds an account a controller sits on to `AGENT_RUNTIME_ACCOUNT_MAX_PCT`, as it holds any account.
- `AGENT_RUNTIME_CLOUD_CREDIT_FLOOR`: the judge weighs a grant pool on its grant's verdict alone.
- `AGENT_RUNTIME_USAGE_MAX_AGE`: it widens the cache window and never narrows it.
- `AGENT_RUNTIME_CLAUDE_CLIENT_ID`: unset, every expired Claude account reads `error`.
- `CODEX_HOME`, `COPILOT_HOME`: the judge measures it as the account it names, and never makes it a candidate.

## Handoff and succession

See [turnend/marks.rs](../runtime/src/turnend/marks.rs) for the reserve and [agent-runtime settings](../../agent-runtime/runtime/src/settings.rs) for controller succession.

| Key | What it changes |
|---|---|
| `ORCH_HANDOFF_CONTEXT_PCT` | The share of the context window strictly past which a context reading is due, held to the judge's ceiling: [oversee-events.md](oversee-events.md) § Hand off a lane before it runs out. |
| `ORCH_HANDOFF_CONTEXT_TOKENS` | Tokens used at which every context reading is due, whatever the window. |
| `ORCH_HANDOFF_AGENT_RESERVE_TOKENS` | Tokens an attached launch keeps below the context mark for returns still to come: a whole number. |
| `ORCH_HANDOFF_HEADROOM_PCT` | The account headroom a lane's turn end hands off at. |
| `ORCH_OVERSEER_WALL_MINUTES` | Minutes to the account's wall, at the measured rate, at which the overseer hands off. `0` turns the mark off. |
| `ORCH_OVERSEER_MEMORY_PCT` | The percentage of `memory.max` that anonymous memory (`anon` in `memory.stat`) must reach for the overseer to hand off. The watch reads the harness process's own cgroup or the level named by `ORCH_OVERSEER_MEMORY_CGROUP`. An uncapped group has no memory mark. If the anonymous-memory reading is unavailable, the mark is unmeasured. |
| `ORCH_OVERSEER_MEMORY_CGROUP` | The name of the cgroup on the harness process's path, such as `tmux.service`, whose cap the memory mark judges: the nearest group so named. A name no group on the path carries reads the mark unmeasured. |
| `AGENT_RUNTIME_CONTROLLER_SUCCESSION` | `on` or `off`: whether a controller may ask for its own succession. |
| `AGENT_RUNTIME_CONTROLLER_PREFERENCE` | The `harness:model:effort` entries a succession walks for the successor. |
| `AGENT_RUNTIME_ACCOUNT_TOKEN_FILES` | `<account dir>=<token file>` pairs, both absolute: the file each Claude account signs in with. |
| `ORCH_WAKE_PROCESS`, `ORCH_WAKE_START` | For a controller with no live watch claim: a regular expression over each process's command line that names the process that wakes the controller, and the start command its turn end prints where none runs. |

The keys' rules, in the table's order:

- `AGENT_RUNTIME_CONTROLLER_SUCCESSION`: under `off`, `request-transfer` refuses before any intent persists.
- `AGENT_RUNTIME_CONTROLLER_PREFERENCE`: unset, a context mark's succession walks the controller's own entry alone.
- `AGENT_RUNTIME_CONTROLLER_PREFERENCE`: the grammar is the example's § Fleet.
- `AGENT_RUNTIME_ACCOUNT_TOKEN_FILES`: the successor walk and the transfer judge a declared account by its file alone, and any other account by its stored login. A declared account whose file holds no token, or an undeclared account holding no stored login, is no candidate.
- `AGENT_RUNTIME_ACCOUNT_TOKEN_FILES`: a successor's, a local lane's or `agent-runtime launch`'s launch on a declared account exports the file's text as `CLAUDE_CODE_OAUTH_TOKEN` in its own window.
- `AGENT_RUNTIME_ACCOUNT_TOKEN_FILES`: a cloud session signs in by its account's stored login whatever the setting declares, and exports no file.
- Every launch on a named Claude account clears the Claude credentials its window inherits that would outrank the account's own sign-in. A token the tmux server's environment holds signs no named account in.
- A successor's, a local lane's or `agent-runtime launch`'s launch on a named Claude account holding no sign-in refuses `successor-not-signed-in` before any window opens. A declared account whose file is missing or empty refuses with `cause=declared-token-absent file=<path>`.
- `AGENT_RUNTIME_ACCOUNT_TOKEN_FILES`: the value names paths, never a token.
- `AGENT_RUNTIME_ACCOUNT_TOKEN_FILES`: declare it in `kendex.settings.toml` `[env]`, `.env.local` or the tmux server's environment, which every successor inherits; a successor does not inherit its predecessor's own environment.

## Fleet watch

`orch-runtime watch run` judges these at its start.

| Key | What it changes |
|---|---|
| `OVERSEE_WATCH_STATE_DIR` | The watch's state folder: the claim store and the relaunch markers. |
| `ORCH_WATCH_MAIL_INTERVAL` | Seconds between the end of one mail turn and the start of the next. |
| `ORCH_OVERSEER_MARK_REPEAT` | Long passes between two repeats of a standing mark or stall line. |
| `ORCH_OVERSEER_DEAD_PASSES` | Long passes an overseer pane reads dead before the watch reports it. |
| `ORCH_WATCH_TAIL_LINES` | Pane lines a lane event carries. |
| `ORCH_WATCH_PREPARE_SECS` | Seconds a lane may read `preparing` before `lane-prepare-stuck`. |
| `ORCH_DIRECTIVE_UNREAD_SECS` | Seconds a sent directive may stay unread before `directive-unread`. |
| `ORCH_WATCH_START_STALL_SECS` | Seconds since `running_at` with no status file before `start-stalled`. |
| `ORCH_WATCH_LANE_STALL_SECS` | Seconds a cloud lane's head and status may stand before `lane-stalled`. |
| `ORCH_CLOUD_STALL_MINUTES` | Minutes a stalled cloud lane's directive may stay unanswered before the watch closes the lane. |
| `ORCH_WATCH_LANE_AGE_SECS` | Seconds past `launched_at` before `lane-long`. |
| `ORCH_WALL_RELAUNCH` | The watch's recovery of a stopped worker ([lane-directive.md § Watch recovery](lane-directive.md#watch-recovery)). `auto`: the watch relaunches the lane itself at a usage or sign-in wall, moves it to another provider after 30 minutes of provider stops, and relaunches it when its harness exits. `ask`: the watch leaves each of these to the overseer; it still resumes a provider stop on the lane's own account. |
| `ORCH_CONNECTED_REPOS` | Further `OWNER/REPO` names the watch's GitHub duty reads beside the fleet's, whitespace-separated. |
| `ORCH_MAIN_WORKFLOWS` | `OWNER/REPO:FILE` entries whose main-branch runs the watch reads. |
| `ORCH_EXTERNAL_TRIAGE` | `on` or `off`: whether the GitHub duty reports outside contributions. |
| `ORCH_SECURITY_ALERTS` | `on` or `off`: whether the GitHub duty reads each repository's open security alerts. |
| `ORCH_SECURITY_ALERT_TOKEN_FILE` | The installation token file the alert reads run under. |

The keys' rules:

- `ORCH_SECURITY_ALERT_TOKEN_FILE`: the file is held to the same file rules as the review token.
- `ORCH_SECURITY_ALERT_TOKEN_FILE`: unset or unfit, the alert read refuses.

## Recording

| Key | What it changes |
|---|---|
| `ORCH_RECORD_RETENTION_DAYS` | Days past a record's own end, or a scratch entry's last write, before the retention duty removes it. |
| `ORCH_FLEET_LOG_ROW_BYTES` | Bytes of text one fleet-log row may carry. |
| `ORCH_TAKEOVER_ROWS` | Fleet-log rows a successor reads whole at takeover. |
| `ORCH_PROGRESS_REPORT_DIR` | The owner progress reports' folder. A relative path joins the main checkout. |

The keys' rules:

- `ORCH_RECORD_RETENTION_DAYS`: `lane-mail compact` reads it too.

## QA

| Key | What it changes |
|---|---|
| `QA_PERF_PATHS` | Space-separated globs whose change adds the `needs-perf-test` signal. |
| `QA_PERF_RUNNER`, `QA_PERF_WORKLOAD`, `QA_PERF_BASELINE` | The performance review's runner command, workload and baseline. |
| `QA_UI_PATHS` | Space-separated globs whose change adds the `needs-ui-review` signal. |
| `QA_UI_DESIGN_DOC` | The design-system doc a view-changing round builds to and the UI review judges against. |

The keys' rules, in the table's order:

- `QA_PERF_RUNNER`, `QA_PERF_WORKLOAD`, `QA_PERF_BASELINE`: `record-qa-decision` records `needs-perf-test` as gating only with all three set. Otherwise it records the signal as advisory.
- `QA_UI_DESIGN_DOC`: unset is reported as a gap.

## Change measurement

change-scope reads these from the base commit's settings files or the caller's environment. See `change-scope --help` for how it measures changes and [branch-growth.sh](../../change-scope/scripts/lib/branch-growth.sh) for the render roots it uses when none are configured.

| Key | What it changes |
|---|---|
| `ORCH_SIZE_RENDER_ROOTS` | The render-mirror roots the measurement sets aside from production and test counts where their source changes in the same branch. |
| `ORCH_SIZE_TEST_PATHS` | Extra test-path globs for the measurement. |
