# Settings

Read when a workflow, a reference or a `--help` names a setting and the task needs where it is set, what it does or its default. A committed default goes in `kendex.settings.toml` under `[env]`; a secret or a personal override goes in `.env.local`. Installation adds no settings; [kendex.settings.toml.example](../kendex.settings.toml.example) is the annotated guide.

| Variable | Purpose | Default |
|---------|---------|---------|
| `ORCH_STATE_DIR` | Workflow state directory; the `--state-dir` flag wins where both are set | `tmp` |
| `ORCH_ARCHIVE_ROOT` | Archive folder. The runtime archives there in its retention duty, `state remove` and an item's terminal close-out; `lane-close`'s close-out through `workflow-state remove`, `lane-mail compact` and SSH lane close archive there through `scripts/lib/state-archive.sh`, which needs Python for a configured value. Set an absolute path outside linked worktrees and state or mailbox folders. A configured value requires a readable Git worktree list. A relative or `~` value refuses each archive write, the runtime's as `setting-invalid`; the settings load accepts it | `${FLEET_DIR:-$HOME/.fleet}/archive` |
| `OVERSEE_WATCH_STATE_DIR` | Directory for watch baselines, lane claims, the weekly walls recorded from lane banners and cached account usage, shared by `oversee-watch`, `lanes` and `open-terminal` | `tmp/oversee-watch` under the project root |
| `GH_ISSUE_PATTERN` | Regex for issue IDs in branch names, matched case-insensitively and canonicalized | `([A-Z]+-[0-9]+\|issue-[0-9]+)` |
| `CI_WAIT_NO_CHECKS_GRACE` | Seconds `ci-wait`, the failed-check probe `queue-wait` runs, keeps polling when no CI check has registered before it fails | `600` |
| `CI_WAIT_MAX_SECS` | Budget in seconds of a workflow's CI wait, the repeated `verify-pr` call, and the default budget of the `ci-wait` probe. Set it above the longest required job's run time | `600` |
| `CI_FIX_MAX_CYCLES` | Automatic ci-fix cycles for one PR, counted across the heads they push; a passing CI run clears the count | `6` |
| `REVIEW_MAX_CYCLES` | Re-review cycles per issue. `0`: one blockers-only fix round, accepted on its validation without re-review; `1`: one fix round and one re-review of its diff | `1` |
| `REVIEW_MAX_EXTERNAL_ROUNDS` | External comment-triage passes and automatic review-wait restarts on one PR head | `4` |
| `REVIEWER_SLOT_BUDGET` | Concurrent agent-session budget counting the primary; `0` is unlimited; reviews run in waves past it. On Codex, the cap `spawn-adapter slots` reports | `0` |
| `ORCH_USER_MODE` | `ceo` or `engineer`: [ask set and composition](communication-modes.md), [prose](../../communication/references/messages.md#reader-modes) | `ceo` |
| `ORCH_DECISION_MODE` | `ask` presents decision points; `auto-recommended` takes the recommended one | `auto-recommended` |
| `ORCH_MERGE_AUTONOMY` | `auto` merges once every gate is green on authorization already given; `ask` requires it per merge | `auto` |
| `PM_CREATE_AUTONOMY` | Audit creation and cancellation: project-management's `README.md` § Setup | `ask`; `auto` under `ceo` |
| `ORCH_VERIFY_SCHEDULE` | Free text naming where and how often `/orch verify` runs: a Claude Code routine, a cron job that starts a harness on the base checkout, or the overseer's watch while it runs. A Stop handoff requires a reader that survives Stop. Names an existing schedule and starts nothing | empty |
| `ORCH_POST_MERGE_CMD` | Bash command that `scripts/post-merge` runs in the base checkout after synchronization. `ORCH_POST_MERGE_BEFORE` is the base before the oldest unprocessed synchronization; `ORCH_POST_MERGE_AFTER` is the current synchronized head. `sync-base` saves the first in `refs/kendex/post-merge-base`; only a successful or empty command advances it. A failed command stops before project refresh and verification and keeps the range for retry | empty |
| `PR_REVIEW_ON_TIMEOUT` | `proceed` advances only when no reviewer engaged and no thread is open; `block` reports the timeout | `proceed` |
| `ORCH_OVERSEER_LANES` | Fleet lane cap: `open-terminal --help` | `4` |
| `ORCH_OVERSEER_CLOUD_LANES` | Separate Claude cloud session cap per overseer: `open-terminal --help` | `10` |
| `ORCH_CONNECTED_REPOS` | Blank-separated `OWNER/REPO` list of repositories the overseer may launch lanes in beside its own. `open-terminal` reads it in the overseer's checkout without the launcher's own value or `KENDEX_ENV_FILE`, which can be the launch checkout's, and matches it to a launch checkout's origin remote: `open-terminal --help`. The watch and `oversee-report` run in the overseer's checkout, honor both, and read each one beside their `--repo` values: `oversee-report --help` | empty |
| `ORCH_MAIN_WORKFLOWS` | Blank-separated `OWNER/REPO:FILE` list of workflow files whose red push or nightly run on `main` the watch reports for that repository, beside `skill-tests.yml` and `ci.yml`, which every repository reads; an entry whose file the repository lacks, or whose repository the watch does not read, is reported | empty |
| `ORCH_WAKE_PROCESS` | `pgrep -f` wake pattern for `lane-mail-check`. Empty disables the check with no watch record | empty |
| `ORCH_WAKE_START` | Wake start command printed by the turn-end refusal. Empty disables the check with no watch record | empty |
| `ORCH_LANE_OUTPUT` | Lane pane output: [skill-rules.md](skill-rules.md) § Lane Output | `quiet` |
| `ORCH_ROUND_PRUNE_DISK_PCT` | Disk use percent at or past which `round-prune` clears the item worktree's Cargo output before a dev round: [skill-rules.md](skill-rules.md) § Round Closure | `75` |
| `ORCH_HANDOFF_CONTEXT_PCT` | Earlier handoff percentage (1 to 100, capped at 90); strict for lane handoff and overseer succession alike: [context rule](oversee-events.md#judgement-rules) | `90` |
| `ORCH_HANDOFF_AGENT_RESERVE_TOKENS` | Nonnegative whole token reserve for attached agent returns: [pre-panel launch admission](../workflows/review-pr.md#2-prepare-reviewers) and the [native launch refusal](oversee-events.md#judgement-rules). Ordinary checkpoints and succession use the plain mark. | `150000` |
| `ORCH_HANDOFF_HEADROOM_PCT` | Account headroom mark the turn-end hook passes to `orch-runtime accounts pick --fleet --lane` through `--min-headroom-pct`; a reached mark requires the lane's handoff. Overseer seats keep their own room: [context and account marks](oversee-events.md#hand-off-a-lane-before-it-runs-out) | `3` |
| `ORCH_WALL_RELAUNCH` | `auto` has the watch relaunch a walled lane on an account the orch runtime's account judge qualifies for its model, as `lane-relaunched`; `ask` reports `usage-limit` with the judge's answer: [oversee-events.md](oversee-events.md#event-kinds) | `auto` |
| `ORCH_OVERSEER_PREFERENCE` | Comma-separated `harness:model:effort` entries `oversee launch` and `oversee-succeed` try in order. With the setting unset, context-mark succession keeps the caller's harness and model; other marks and first launch use the default. `kendex tier-model` classifies each model at launch: a Claude class runs the family alias selected by `model-classes`; another provider's override stops the preference walk. Codex uses its native default until its model list reaches the launch; grammar: [guide](../kendex.settings.toml.example) § Fleet. An empty setting names none | `claude:standard:high,codex:standard:high` |
| `ORCH_PR_ORDER` | Publication order: `review-first`, `open-first` or `push-first`. A set value overrides visibility. [`pr-order --help`](../scripts/pr-order) owns the defaults, validation and draft rules | unset |
| `ORCH_DELIVERY` | `pr` uses pull requests. `push-base` keeps the tier's local checks and review, then fast-forward pushes the resolved base branch. The lane reports the pushed commit for the existing direct-push cycle record. An item with an open post-merge box stops for the PR route: [submit-pr.md § 2.1](../workflows/submit-pr.md#21-base-publication) | `pr`, also when unset |
| `ORCH_LANE_PREFERENCE` | `harness[@host]:model:effort` entries in default-model order. Each named host applies to its entry; an omitted host keeps the caller's route. A `:last` after the final entry marks it a last choice the walk holds back under the rule in [Lane preference](lane-directive.md#lane-preference). Explicit models keep that route. [Lane preference](lane-directive.md#lane-preference) | unset |
| Owner-ask settings | `ORCH_QUESTION_TOOL`, `ORCH_ASK_WAIT_MINUTES`, `ORCH_OWNER_EMAIL` (defaults to `KENDEX_USER_EMAIL`), `ORCH_OWNER_ASK_LABEL` (unset by default): [guide](../kendex.settings.toml.example) § Talking to you | |
| `ORCH_OVERSEER_SUCCESSION` | `on` lets `oversee-succeed` launch the successor overseer; `off` launches none and turns off the account-mark turn-end refusals, not the context one: [guide](../kendex.settings.toml.example) | `on` |
| `ORCH_OVERSEER_DEAD_PASSES` | Watch passes that read the overseer exited or walled before it is reported: [guide](../kendex.settings.toml.example) | `2` |
| `ORCH_OVERSEER_HEADROOM_PCT` | Account headroom at or below which the overseer succeeds onto an account above it and `lane-mail-check` refuses its turn end. An overseer's seat keeps this room for it: a worker's pick holds a seat to `min(ORCH_LANE_MAX_PCT, 100 - ORCH_OVERSEER_HEADROOM_PCT)` and returns it last, and a lane on a seat hands off at `max(ORCH_HANDOFF_HEADROOM_PCT, ORCH_OVERSEER_HEADROOM_PCT)` room. Codex credits count as room on a seat as on any account | `5` |
| `ORCH_OVERSEER_WALL_MINUTES` | Projected wall minutes that fire overseer succession. `0` disables it | `20` |
| `ORCH_OVERSEER_SUCCESSOR_ACCOUNTS` | Qualifying-account count that fires succession: `oversee-succeed --help`. `0` disables it | `1` |
| `ORCH_OVERSEER_MARK_REPEAT` | Watch passes a standing `overseer-mark` waits before it repeats | `5` |
| Recording settings | `ORCH_FLEET_LOG_ROW_BYTES`, `ORCH_TAKEOVER_ROWS`, `ORCH_RECORD_RETENTION_DAYS`, `ORCH_PROGRESS_REPORT_DIR`: [recording policy](../schemas/workflow-state.md#recording-policy) | |
| `ORCH_REPORT_QUIET_HOURS` | Owner-local window: reports write and print, with no owner notice. Empty disables it. The first due morning brief covers work since the last sent report. Asks and critical notices stay immediate. | `0-7` |
| `ORCH_OWNER_TIME_ZONE` | Report time zone | `America/Los_Angeles` |
| Watch settings | `ORCH_WATCH_*`, `ORCH_EXTERNAL_TRIAGE`, `ORCH_SECURITY_ALERTS`: [guide](../kendex.settings.toml.example) | |
| `ORCH_OVERSEER_REVIEW_TOKEN_FILE` | `overseer-approve`'s app token: an absolute path, one line, mode 600, outside lane roots, swapped atomically before expiry by the control VM (hosted) or fleet worker (local) | |
| `ORCH_OVERSEER_REVIEW_LOGIN` | The token app's bot login, such as `vanillagreen-overseer[bot]`. Required for failed-POST read-back; unset refuses confirmation | |
| `ORCH_COPILOT_HOLD_SECS` | Bound for current-head Copilot checks and pending timeline work: `copilot-wait --help`, `overseer-approve --help`. Requires the token app's repository Checks: read permission | `600` |
| `ORCH_LANE_HOST` | `lane-host`'s host: `local`, `claude-cloud` (Claude Code's own cloud sessions) or a provider executable, each a [host kind](../schemas/lane-host.md#host-kinds) | `local` |
| `ORCH_LANE_HOST_MAX_CALLS` / `ORCH_LANE_HOST_BUSY_WAIT_SECS` | Per-home long-call cap and seconds to wait at that cap; [Host protocol](../schemas/lane-host.md#provider-protocol) places the verbs | `4` / `30` |
| `ORCH_LANE_HOST_SHORT_MAX_CALLS` / `ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS` | Independent per-home short-call cap and wait; mailbox reads can run while long calls wait on sandbox preparation | `4` / `30` |
| `ORCH_OVERSEER_HOST` | Runtime of the overseer's own session: `tmux`, the included provider; another is refused as `runtime-unsupported`. [Protocol](../schemas/overseer-host.md) | `tmux` |
| `QA_PERF_PATHS` | Space-separated path globs whose modification adds the `needs-perf-test` QA signal | empty |
| `QA_UI_PATHS` | Space-separated path globs whose modification adds the `needs-ui-review` QA signal | empty |
| `QA_UI_DESIGN_DOC` | Repository path of the design-system doc a dev round that changes a view builds to and the `needs-ui-review` pass judges against; unset is reported as a gap | empty |
| `RECONCILE_STALE_HOURS` | Hours before an In Progress or In Review item counts as started-stale in `reconcile-work-items` sweeps | `24` |
| `WORKTREE_CLI` | Path to the worktree CLI `open-terminal` drives; empty resolves the installed worktree skill's script | resolved |
| Reviewer-gate settings | `PR_REVIEW_WAIT_SECS`, `PR_COPILOT_REQUESTS`: [references/gates.md](gates.md) | |
| `ORCH_LANE_MAX_PCT` | Usage share at or above which the orch runtime's account judge, `orch-runtime accounts pick`, refuses an account for every launch, turn-end mark and succession pick; credit exemptions, bucket, overrides, other lane settings: `lanes --help`, `open-terminal --help` | `95` |
| `ORCH_LANE_RETIRE` | Comma-separated `name=YYYY-MM-DD` pairs naming the day an account ends. The orch runtime's account judge picks the account until that UTC day and refuses it after; `lanes` lists it retired and never looks inside its directory: [guide](../kendex.settings.toml.example) | empty |
| `ORCH_LANE_CLOUD_CREDIT_FLOOR` | Dollars a Claude cloud or Pi Anthropic API grant must exceed to stay pickable; tier and refusal: `lanes --help` | `10` |
| `ORCH_LANE_CODEX_CREDIT_FLOOR` | Credits a spent Codex account must exceed to stay pickable, after plan room, since credits never reset. Provisional; lane-day arithmetic: [guide](../kendex.settings.toml.example) | `5000` |
| `ORCH_SIZE_RENDER_ROOTS` | Render-mirror roots excluded from production and test counts when their source changes in the same branch | `.agents .claude .codex .pi` |
| `ORCH_SIZE_TEST_PATHS` | Extra test-path globs for the shared CI change classification | empty |

`ORCH_OVERSEER_PREFERENCE` reads the deprecated `harness:positive-integer:effort` form, and a claude exact model id, until the next major release; a codex or copilot exact id is a supported form: [kendex.settings.toml.example](../kendex.settings.toml.example) § Fleet. The refresh report lists the numeric form only.

Launch settings and Codex compaction limits: [skill-rules.md](skill-rules.md#coordination), Compaction.
