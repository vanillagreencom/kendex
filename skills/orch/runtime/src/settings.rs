//! The runtime's one settings reader: the project's `[env]` tables, its
//! private env file and the caller's environment, layered the way the
//! shell store loads them, read as data and never run.
//!
//! Precedence, highest first: a flag on the command line, the caller's own
//! environment, the private env file (`.env.local`, or the file
//! `KENDEX_ENV_FILE` names, skipped under `--no-private-env`),
//! `.kendex/settings.toml`, then `kendex.settings.toml`. An empty value is
//! an unset one, as a shell `${KEY:-default}` read takes it.
//!
//! The settings files follow the kendex `[env]` contract the shell loader
//! holds them to: `[env]` assignments of single-line basic strings with no
//! `"` or `\`, or literal strings with no apostrophe, an optional trailing
//! `#` comment, a duplicate key refused, a `[`-led line a lone `[name]`
//! header or refused, a leading byte-order mark refused. The private env
//! file is shell to the loader that sources it; here it is read and never
//! run, one assignment line at a time, `KEY=VALUE` with an optional leading
//! `export`. A key's value is read as the sourcing shell assigns it in the
//! forms [`decode_account_value`] names. Any other form of a key only some
//! verbs read is passed over with a notice; of a key of `LOAD_KEYS` it
//! refuses, since reading past it would take the shell's value for
//! another. A line of any other shape assigns nothing here.
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::host;
use agent_runtime::launch::{Permission, QuestionTool};

use crate::archive::ArchiveRoot;
use crate::error::Result;

/// The folder the per-item state is kept in, relative to the main checkout
/// unless absolute; `tmp` when nothing names one.
pub const STATE_DIR_KEY: &str = "ORCH_STATE_DIR";
/// The tmux session every lane window opens in.
pub const TMUX_SESSION_KEY: &str = "ORCH_TMUX_SESSION";
/// Seconds a launch waits for the harness to come up at its composer.
pub const VERIFY_SECS_KEY: &str = "ORCH_TMUX_VERIFY_SECS";
/// Seconds a stop waits after SIGTERM before SIGKILL.
pub const CLOSE_SECS_KEY: &str = "ORCH_LANE_CLOSE_SECS";
/// Whether a launched overseer keeps the harness's question dialog.
pub const QUESTION_TOOL_KEY: &str = "ORCH_QUESTION_TOOL";
/// The permission posture every launch runs under: `bypass`, the
/// unattended default, or `native`, the harness's own prompts.
pub const LAUNCH_PERMISSION_KEY: &str = "ORCH_LAUNCH_PERMISSION";
/// Where a harness executable is installed when not on `PATH`, as
/// `harness=/absolute/path` pairs separated by commas.
pub const HARNESS_BINARIES_KEY: &str = "ORCH_HARNESS_BINARIES";
/// The worktree program that resolves a lane's directory; empty finds the
/// installed worktree package.
pub const WORKTREE_CLI_KEY: &str = "WORKTREE_CLI";
/// Whether a controller may ask for its own succession: `on`, the default,
/// or `off`, under which `request-transfer` refuses before any intent
/// persists.
pub const SUCCESSION_KEY: &str = "ORCH_OVERSEER_SUCCESSION";
/// The job-unit launcher a succession's effect is detached through; empty
/// finds the installed orch package's own.
pub const JOB_UNIT_KEY: &str = "ORCH_JOB_UNIT";
/// The settings key naming the project's private env file.
pub const ENV_FILE_KEY: &str = "KENDEX_ENV_FILE";
/// The private env file read when the project names none.
pub const DEFAULT_ENV_FILE: &str = ".env.local";
/// The settings files in loading order; a later file outranks an earlier.
pub const SETTINGS_FILES: [&str; 2] = ["kendex.settings.toml", ".kendex/settings.toml"];
/// The worktree package's program under the project's install.
pub const WORKTREE_CLI_DEFAULT: &str = ".agents/skills/worktree/scripts/worktree";
/// The agent-runtime command the wake duty delivers through; empty finds
/// the installed agent-runtime package's own wrapper.
pub const AGENT_RUNTIME_KEY: &str = "ORCH_AGENT_RUNTIME";
/// The agent-runtime package's wrapper under the project's install.
pub const AGENT_RUNTIME_DEFAULT: &str = ".agents/skills/agent-runtime/scripts/agent-runtime";
/// The orch package's job-unit launcher under the project's install.
pub const JOB_UNIT_DEFAULT: &str = ".agents/skills/orch/scripts/lib/job-unit.sh";
/// The lanes the fleet cap admits at once: every lane kind but
/// `claude-cloud`, which the cloud cap bounds.
pub const LANE_CAP_KEY: &str = "ORCH_OVERSEER_LANES";
/// The Claude cloud sessions one overseer holds at once: the record's
/// declared `claude-cloud` kind owns this cap, whatever its host name.
pub const CLOUD_LANE_CAP_KEY: &str = "ORCH_OVERSEER_CLOUD_LANES";
/// The watch's state directory, which holds the claim store `<dir>/claims`
/// (`lib/lane-claims.sh`, `lane_claims_dir`), the account walls, the usage
/// cache and the relaunch markers; the main checkout's `tmp/oversee-watch`
/// when unset.
pub const CLAIM_STATE_DIR_KEY: &str = "OVERSEE_WATCH_STATE_DIR";
/// The mailbox program a close asks for a lane's unanswered asks; empty
/// finds the installed mailbox package.
pub const LANE_MAIL_CLI_KEY: &str = "LANE_MAIL_CLI";
/// The program a close ends a worktree's validation runs through; empty
/// finds the installed orch package's own.
pub const DEV_VALIDATE_CLI_KEY: &str = "DEV_VALIDATE_CLI";
/// The mailbox package's program under the project's install.
pub const LANE_MAIL_CLI_DEFAULT: &str = ".agents/skills/mailbox/scripts/lane-mail";
/// The orch package's validation runner under the project's install.
pub const DEV_VALIDATE_CLI_DEFAULT: &str = ".agents/skills/orch/scripts/dev-validate-run";
// The project's validation declaration, which `validate start`
// resolves the mode from (`dev-validate-run --help`).
/// The project's whole battery; empty is no declaration, which a start
/// refuses.
pub const DEV_VALIDATE_CMD_KEY: &str = "DEV_VALIDATE_CMD";
/// The command that validates the changes since a base; empty declares no
/// range mode.
pub const DEV_VALIDATE_RANGE_CMD_KEY: &str = "DEV_VALIDATE_RANGE_CMD";
/// The required status-check context that runs the project's validation;
/// empty declares no CI deferral.
pub const DEV_VALIDATE_CI_CONTEXT_KEY: &str = "DEV_VALIDATE_CI_CONTEXT";
/// The selector that previews the command's own selection; empty is none.
pub const DEV_VALIDATE_SELECTION_CMD_KEY: &str = "DEV_VALIDATE_SELECTION_CMD";
/// The prefix the project's commands print each finding with; empty is
/// none recorded, and such a run is never reuse evidence.
pub const DEV_VALIDATE_FINDING_PREFIX_KEY: &str = "DEV_VALIDATE_FINDING_PREFIX";
/// The bound on the command, seconds.
pub const DEV_VALIDATE_TIMEOUT_SECS_KEY: &str = "DEV_VALIDATE_TIMEOUT_SECS";
/// The memory cap on a validation run's whole process tree; unset is none.
pub const VALIDATE_MEMORY_MAX_KEY: &str = "ORCH_VALIDATE_MEMORY_MAX";
/// `pr`, the default, or `push-base`: direct delivery keeps every ci
/// request on local validation.
pub const DELIVERY_KEY: &str = "ORCH_DELIVERY";
/// The disk use percent at or past which `prune-round` reclaims the lane
/// worktree's Cargo output; the op judges it.
pub const ROUND_PRUNE_KEY: &str = "ORCH_ROUND_PRUNE_DISK_PCT";
/// The QA decision's path globs and the performance review's declaration,
/// each read as written; `record-qa-decision` judges them.
pub const QA_KEYS: [&str; 5] = [
    "QA_UI_PATHS",
    "QA_PERF_PATHS",
    "QA_PERF_RUNNER",
    "QA_PERF_WORKLOAD",
    "QA_PERF_BASELINE",
];
/// The program the lane admission reads a diff range's changed paths
/// through; empty finds the installed change-scope
/// package's `harness-only`.
pub const SCOPE_PATHS_CLI_KEY: &str = "CHANGE_SCOPE_PATHS_CLI";
/// The change-scope package's path reader under the project's install.
pub const SCOPE_PATHS_CLI_DEFAULT: &str = ".agents/skills/change-scope/scripts/harness-only";
/// The claim store under the main checkout when no directory is named.
pub const CLAIM_STORE_DEFAULT: &str = "tmp/oversee-watch/claims";
/// Seconds a transfer's or a stop's caller waits for its detached job to
/// claim the intent: the claim's own bound, apart from the
/// tmux verification bound a test shortens to force a failed delivery.
pub const JOB_CLAIM_SECS_KEY: &str = "ORCH_JOB_CLAIM_SECS";
/// Seconds between the end of one mail turn and the start of the next
pub const WATCH_MAIL_INTERVAL_KEY: &str = "ORCH_WATCH_MAIL_INTERVAL";
/// Long passes between two repeats of a standing mark or stall line.
pub const OVERSEER_MARK_REPEAT_KEY: &str = "ORCH_OVERSEER_MARK_REPEAT";
/// Long passes an overseer pane reads dead before the watch reports it.
pub const OVERSEER_DEAD_PASSES_KEY: &str = "ORCH_OVERSEER_DEAD_PASSES";
/// Pane lines a lane event carries under it.
pub const WATCH_TAIL_LINES_KEY: &str = "ORCH_WATCH_TAIL_LINES";
/// Seconds a lane may read `preparing` before `lane-prepare-stuck`.
pub const WATCH_PREPARE_SECS_KEY: &str = "ORCH_WATCH_PREPARE_SECS";
/// Seconds a sent directive may stay unread before `directive-unread`.
pub const DIRECTIVE_UNREAD_SECS_KEY: &str = "ORCH_DIRECTIVE_UNREAD_SECS";
/// Seconds since `running_at` with no status file before `start-stalled`.
pub const WATCH_START_STALL_SECS_KEY: &str = "ORCH_WATCH_START_STALL_SECS";
/// Seconds a cloud lane's head and status may stand before `lane-stalled`.
pub const WATCH_LANE_STALL_SECS_KEY: &str = "ORCH_WATCH_LANE_STALL_SECS";
/// Minutes a stalled cloud lane's directive may stay unanswered before the
/// watch closes it.
pub const CLOUD_STALL_MINUTES_KEY: &str = "ORCH_CLOUD_STALL_MINUTES";
/// Seconds past `launched_at` before `lane-long`.
pub const WATCH_LANE_AGE_SECS_KEY: &str = "ORCH_WATCH_LANE_AGE_SECS";
/// Whether the watch relaunches a walled lane itself (`auto`) or leaves the
/// wall to the overseer (`ask`).
pub const WALL_RELAUNCH_KEY: &str = "ORCH_WALL_RELAUNCH";
/// The `owner/repo:workflow.yml` entries whose main-branch runs the watch
/// reads, separated by whitespace.
pub const MAIN_WORKFLOWS_KEY: &str = "ORCH_MAIN_WORKFLOWS";
/// The Linear team the tracker duties read; unset leaves them off.
pub const LINEAR_TEAM_KEY: &str = "LINEAR_TEAM";
/// The tracker program the tracker duty reads through; empty finds the
/// installed linear package's own.
pub const TRACKER_CLI_KEY: &str = "OVERSEE_WATCH_TRACKER";
/// The linear package's program under the project's install.
pub const TRACKER_CLI_DEFAULT: &str = ".agents/skills/linear/scripts/linear.sh";
/// The github skill's reducer the GitHub duty runs per repository with
/// `GH_REPO`; empty finds the installed github package's own.
pub const PR_WATCH_CLI_KEY: &str = "OVERSEE_WATCH_PR_WATCH";
/// The github package's reducer under the project's install.
pub const PR_WATCH_CLI_DEFAULT: &str = ".agents/skills/github/scripts/pr-watch.sh";
/// Whether the GitHub duty reads each repository's open security alerts:
/// `on`, the default, or `off`.
pub const SECURITY_ALERTS_KEY: &str = "ORCH_SECURITY_ALERTS";
/// The file holding the installation token the alert reads run under; no
/// default, and an unset file reads the alerts with no token.
pub const SECURITY_ALERT_TOKEN_FILE_KEY: &str = "ORCH_SECURITY_ALERT_TOKEN_FILE";
/// Whether the GitHub duty reports outside contributions: `on`, the
/// default, or `off`.
pub const EXTERNAL_TRIAGE_KEY: &str = "ORCH_EXTERNAL_TRIAGE";
/// Further `owner/repo` names the GitHub duty reads beside the fleet's,
/// separated by whitespace, lowercased and deduplicated as the shell
/// `orch_connected_repos` reads them.
pub const CONNECTED_REPOS_KEY: &str = "ORCH_CONNECTED_REPOS";
/// The owner's tracker account, whose comments answer a tracker-posted ask
/// (`mailbox-append.sh` `owner_tracker_settings`); `KENDEX_USER_EMAIL`
/// stands in when unset.
pub const OWNER_EMAIL_KEY: &str = "ORCH_OWNER_EMAIL";
/// The fallback for `ORCH_OWNER_EMAIL`.
pub const USER_EMAIL_KEY: &str = "KENDEX_USER_EMAIL";
/// The label a tracker-posted ask carries; the owner-answer read is
/// configured only with both the label and an email.
pub const OWNER_ASK_LABEL_KEY: &str = "ORCH_OWNER_ASK_LABEL";
// The overseer mark line's payload names the preference.
/// The `harness:model:effort` entries a succession walks for the
/// successor lane (`lib/overseer-launch.sh`, `ol_preference`); the mark
/// line's payload names its value.
pub const OVERSEER_PREFERENCE_KEY: &str = "ORCH_OVERSEER_PREFERENCE";
/// The standard class on each harness (`OL_DEFAULT_PREFERENCE`).
pub const DEFAULT_OVERSEER_PREFERENCE: &str = "claude:standard:high,codex:standard:high";
/// The `harness[@host]:model:effort` entries a lane launch walks
/// (`accounts walk`); unset, a launch takes the model it names.
pub const LANE_PREFERENCE_KEY: &str = "ORCH_LANE_PREFERENCE";
/// Days past a record's own recorded end before the retention duty removes
/// it (the key `lane-mail compact` reads too): the event log's rotated
/// segments, an ended lane's paths and every other unit of the state
/// directory. A count of none is a misconfiguration: nothing would stand a
/// day.
pub const RECORD_RETENTION_DAYS_KEY: &str = "ORCH_RECORD_RETENTION_DAYS";
/// Seconds `queue-watch` keeps polling a pull request no poll has seen queued
/// or armed before answering `not_queued`: enqueue registration lags the
/// merge call.
pub const QUEUE_WAIT_ARM_GRACE_KEY: &str = "QUEUE_WAIT_ARM_GRACE";
/// Consecutive polls a `conflicting`, `ejected` or `disarmed` reading must
/// hold before `queue-watch` ends on it, so one blip starts no recovery.
pub const QUEUE_WAIT_CONFIRM_POLLS_KEY: &str = "QUEUE_WAIT_CONFIRM_POLLS";
/// The least seconds between two of `queue-watch`'s review-thread probes and
/// between two of its check probes, each on its own clock.
pub const QUEUE_WAIT_PROBE_INTERVAL_KEY: &str = "QUEUE_WAIT_PROBE_INTERVAL";
/// The command that answers whether a red merge group's failed checks are
/// ones the change's paths select; empty is none.
pub const QUEUE_WAIT_REACH_CMD_KEY: &str = "QUEUE_WAIT_REACH_CMD";
const DEFAULT_QUEUE_WAIT_ARM_GRACE_SECS: u32 = 120;
const DEFAULT_QUEUE_WAIT_CONFIRM_POLLS: u32 = 2;
const DEFAULT_QUEUE_WAIT_PROBE_INTERVAL_SECS: u32 = 120;
/// Where the prune and an item's close-out archive what they remove. A set
/// value is an absolute path, else every archive write refuses it, while a
/// verb that writes no archive runs; empty takes `archive/` under
/// `FLEET_DIR`, else under `~/.fleet`.
pub const ARCHIVE_ROOT_KEY: &str = "ORCH_ARCHIVE_ROOT";
/// The fleet directory the default archive root sits under.
pub const FLEET_DIR_KEY: &str = "FLEET_DIR";
/// A path in the orch scripts directory: the account judge, its listing and
/// the walk run `lane-host` from the directory it names, and the heartbeat
/// names the path in its `account-unread` line. Empty takes the project's
/// installed orch package.
pub const LANES_CLI_KEY: &str = "OVERSEE_WATCH_LANES";
/// The orch package's account reader under the project's install.
pub const LANES_CLI_DEFAULT: &str = ".agents/skills/orch/scripts/lanes";
const DEFAULT_RECORD_RETENTION_DAYS: u32 = 5;
// The state verbs' keys.
/// The fleet-log rows a successor reads whole at takeover, so the bound on
/// each row's text is what bounds that read.
pub const TAKEOVER_ROWS_KEY: &str = "ORCH_TAKEOVER_ROWS";
/// The bytes of text one fleet-log row may carry.
pub const FLEET_LOG_ROW_BYTES_KEY: &str = "ORCH_FLEET_LOG_ROW_BYTES";
/// The owner progress reports' directory; a relative path joins the main
/// checkout.
pub const PROGRESS_REPORT_DIR_KEY: &str = "ORCH_PROGRESS_REPORT_DIR";
/// The round caps: re-review cycles, external review rounds, CI-fix cycles.
pub const REVIEW_MAX_CYCLES_KEY: &str = "REVIEW_MAX_CYCLES";
pub const REVIEW_MAX_EXTERNAL_ROUNDS_KEY: &str = "REVIEW_MAX_EXTERNAL_ROUNDS";
pub const CI_FIX_MAX_CYCLES_KEY: &str = "CI_FIX_MAX_CYCLES";
const DEFAULT_TAKEOVER_ROWS: u64 = 10;
const DEFAULT_FLEET_LOG_ROW_BYTES: u64 = 600;
const DEFAULT_PROGRESS_REPORT_DIR: &str = "tmp/progress-reports";
const DEFAULT_REVIEW_MAX_CYCLES: u64 = 1;
const DEFAULT_REVIEW_MAX_EXTERNAL_ROUNDS: u64 = 4;
const DEFAULT_CI_FIX_MAX_CYCLES: u64 = 6;
// The accounts judge's keys.
/// A providerless machine's own statement of a plan's end, `<name>=<YYYY-
/// MM-DD>` pairs: the account is picked until that UTC day and measured
/// after it, so a stated end a live reading contradicts is seen. The judge
/// reads it; the account reader is run with it emptied, so it measures the
/// account instead of listing it `retired` unread.
pub const LANE_RETIRE_KEY: &str = "ORCH_LANE_RETIRE";
/// The bound a pick admits an account under, in percent used (`lanes`'
/// `--max-pct` default).
pub const LANE_MAX_PCT_KEY: &str = "ORCH_LANE_MAX_PCT";
/// A live lane's hourly spend where its account measured no rate, in
/// points of five hours' room: a week is charged 5/168 of it an hour, a
/// month 5/720.
pub const LANE_BURN_PCT_KEY: &str = "ORCH_LANE_BURN_PCT_PER_HOUR";
/// The account headroom the overseer hands off at, and so the room a seat
/// keeps for it: a worker's pick holds a seat to `min(ORCH_LANE_MAX_PCT,
/// 100 - this)`.
pub const OVERSEER_HEADROOM_PCT_KEY: &str = "ORCH_OVERSEER_HEADROOM_PCT";
/// The minutes to the account's wall, at the measured rate, the overseer
/// hands off at; 0 is no rate mark.
pub const OVERSEER_WALL_MINUTES_KEY: &str = "ORCH_OVERSEER_WALL_MINUTES";
/// The percent of its cgroup's memory cap the overseer's harness process
/// hands off at; unset is no memory mark.
pub const OVERSEER_MEMORY_PCT_KEY: &str = "ORCH_OVERSEER_MEMORY_PCT";
/// The share of the context window a reading is due strictly past, held
/// to the judge's ceiling.
pub const HANDOFF_CONTEXT_PCT_KEY: &str = "ORCH_HANDOFF_CONTEXT_PCT";
const DEFAULT_OVERSEER_WALL_MINUTES: u32 = 20;
const DEFAULT_HANDOFF_CONTEXT_PCT: u32 = 90;
/// The Codex credit balance a window wall is lifted above (`lanes`'
/// `ORCH_LANE_CODEX_CREDIT_FLOOR`).
pub const CODEX_CREDIT_FLOOR_KEY: &str = "ORCH_LANE_CODEX_CREDIT_FLOOR";
/// The dollars a cloud or API credit grant must exceed to be picked
/// (`lanes`' `ORCH_LANE_CLOUD_CREDIT_FLOOR`).
pub const CLOUD_CREDIT_FLOOR_KEY: &str = "ORCH_LANE_CLOUD_CREDIT_FLOOR";
/// `<name>=<owner>/<repo>` pairs: the repository each account was given
/// access to, which a `cloud-session` pick admits an account on.
pub const LANE_CLOUD_REPOS_KEY: &str = "ORCH_LANE_CLOUD_REPOS";
/// `<pi root>=<used>/<granted>` pairs: the Copilot pool each Pi root
/// spends, as the owner states it, judged where no provider row reads it
/// (`lanes`' own setting).
pub const LANE_COPILOT_POOL_KEY: &str = "ORCH_LANE_COPILOT_POOL";
/// The lane names the reader never reads (`lanes`' own setting), read here
/// for the stated Pi roots alone, which no reader lists.
pub const LANE_EXCLUDE_KEY: &str = "ORCH_LANE_EXCLUDE";
/// `<discovered name>=<alias>` pairs, the owner's names over the discovered
/// ones (`lanes`' own setting), read here for the stated Pi roots alone:
/// the reader names every row it lists through it and matches an
/// exclusion or a retirement through that name.
pub const LANE_ALIASES_KEY: &str = "ORCH_LANE_ALIASES";
/// The lane host a pick runs under; `local` or unset is this machine's
/// own reading.
pub const LANE_HOST_KEY: &str = "ORCH_LANE_HOST";
/// The home a relative `ORCH_LANE_DIRS` entry is resolved under.
pub const HOME_KEY: &str = "HOME";
/// Colon-separated config directories, each an account of the harness
/// whose credential it holds: the accounts the chooser picks among, an
/// entry relative to `HOME` resolved under it. Unset, none is.
pub const LANE_DIRS_KEY: &str = "ORCH_LANE_DIRS";
/// A Codex home the CLI reads, measured as the account it names and never
/// a candidate; a Copilot home likewise.
pub const CODEX_HOME_KEY: &str = "CODEX_HOME";
pub const COPILOT_HOME_KEY: &str = "COPILOT_HOME";
/// Pi's own root, where a Pi launch that names no account of Pi's runs.
pub const PI_ROOT_KEY: &str = "PI_CODING_AGENT_DIR";
/// Seconds a cached usage figure is served within; 0 declines every
/// cached figure. The default outlasts the longest watch interval, since a
/// window under it has every pass find the figure expired and post again.
pub const USAGE_TTL_KEY: &str = "ORCH_LANES_USAGE_TTL";
/// A caller's own pass interval, which widens the window and never
/// narrows it.
pub const USAGE_MAX_AGE_KEY: &str = "ORCH_LANES_USAGE_MAX_AGE";
/// Seconds the provider's `accounts` verb may take; 0 asks for no bound.
pub const HOST_ACCOUNTS_TIMEOUT_KEY: &str = "ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S";
/// The dispatcher's slot wait on that verb, passed on as it stands and
/// held under the bound.
pub const HOST_BUSY_WAIT_KEY: &str = "ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS";
/// The usage endpoints, for a host that reaches them through another
/// address.
pub const CLAUDE_USAGE_URL_KEY: &str = "ORCH_LANES_CLAUDE_USAGE_URL";
pub const CODEX_USAGE_URL_KEY: &str = "ORCH_LANES_CODEX_USAGE_URL";
/// The Claude token endpoint a renewal posts its refresh-token grant to,
/// and the OAuth client id it posts with; with no client id every expired
/// Claude account reads `error` naming the key.
pub const CLAUDE_TOKEN_URL_KEY: &str = "ORCH_LANES_CLAUDE_TOKEN_URL";
pub const CLAUDE_CLIENT_ID_KEY: &str = "ORCH_LANES_CLAUDE_CLIENT_ID";
const DEFAULT_USAGE_TTL: u64 = 300;
const DEFAULT_HOST_ACCOUNTS_TIMEOUT: u64 = 30;
const CLAUDE_USAGE_URL_DEFAULT: &str = "https://api.anthropic.com/api/oauth/usage";
const CODEX_USAGE_URL_DEFAULT: &str = "https://chatgpt.com/backend-api/wham/usage";
const CLAUDE_TOKEN_URL_DEFAULT: &str = "https://platform.claude.com/v1/oauth/token";
const DEFAULT_LANE_MAX_PCT: u32 = 95;
const DEFAULT_LANE_BURN_PCT: u32 = 5;
const DEFAULT_OVERSEER_HEADROOM_PCT: u32 = 5;
const DEFAULT_CODEX_CREDIT_FLOOR: u64 = 5000;
const DEFAULT_CLOUD_CREDIT_FLOOR: u64 = 10;

const DEFAULT_STATE_DIR: &str = "tmp";
const DEFAULT_VERIFY_SECS: u64 = 15;
const DEFAULT_CLOSE_SECS: u64 = 15;
const DEFAULT_CLAIM_SECS: u64 = 15;
const DEFAULT_LANE_CAP: u32 = 4;
const DEFAULT_CLOUD_LANE_CAP: u32 = 10;
const DEFAULT_MAIL_INTERVAL_SECS: u64 = 20;
const DEFAULT_MARK_REPEAT: u32 = 5;
const DEFAULT_DEAD_PASSES: u32 = 2;
const DEFAULT_TAIL_LINES: u32 = 12;
const DEFAULT_PREPARE_SECS: u64 = 1800;
const DEFAULT_DIRECTIVE_UNREAD_SECS: u64 = 300;
const DEFAULT_START_STALL_SECS: u64 = 600;
const DEFAULT_LANE_STALL_SECS: u64 = 3600;
const DEFAULT_CLOUD_STALL_MINUTES: u64 = 30;
const DEFAULT_LANE_AGE_SECS: u64 = 12600;
const GIT_TIMEOUT: Duration = Duration::from_secs(15);

/// The keys this runtime reads from the private env file.
const READ_KEYS: &[&str] = &[
    TRACKER_CLI_KEY,
    "RECONCILE_STALE_HOURS",
    "RECONCILE_GH_CLI",
    PR_WATCH_CLI_KEY,
    SECURITY_ALERTS_KEY,
    SECURITY_ALERT_TOKEN_FILE_KEY,
    EXTERNAL_TRIAGE_KEY,
    CONNECTED_REPOS_KEY,
    OWNER_EMAIL_KEY,
    USER_EMAIL_KEY,
    OWNER_ASK_LABEL_KEY,
    STATE_DIR_KEY,
    TMUX_SESSION_KEY,
    VERIFY_SECS_KEY,
    CLOSE_SECS_KEY,
    QUESTION_TOOL_KEY,
    LAUNCH_PERMISSION_KEY,
    HARNESS_BINARIES_KEY,
    WORKTREE_CLI_KEY,
    AGENT_RUNTIME_KEY,
    SUCCESSION_KEY,
    JOB_UNIT_KEY,
    LANE_CAP_KEY,
    CLOUD_LANE_CAP_KEY,
    CLAIM_STATE_DIR_KEY,
    LANE_MAIL_CLI_KEY,
    DEV_VALIDATE_CLI_KEY,
    "ORCH_APPLE_WORKFLOW",
    "ORCH_APPLE_LABELS",
    DEV_VALIDATE_CMD_KEY,
    DEV_VALIDATE_RANGE_CMD_KEY,
    DEV_VALIDATE_CI_CONTEXT_KEY,
    DEV_VALIDATE_SELECTION_CMD_KEY,
    "DEV_VALIDATE_TEXT_CMD",
    DEV_VALIDATE_FINDING_PREFIX_KEY,
    DEV_VALIDATE_TIMEOUT_SECS_KEY,
    VALIDATE_MEMORY_MAX_KEY,
    DELIVERY_KEY,
    ROUND_PRUNE_KEY,
    QA_KEYS[0],
    QA_KEYS[1],
    QA_KEYS[2],
    QA_KEYS[3],
    QA_KEYS[4],
    SCOPE_PATHS_CLI_KEY,
    JOB_CLAIM_SECS_KEY,
    WATCH_MAIL_INTERVAL_KEY,
    OVERSEER_MARK_REPEAT_KEY,
    OVERSEER_DEAD_PASSES_KEY,
    OVERSEER_WALL_MINUTES_KEY,
    OVERSEER_MEMORY_PCT_KEY,
    HANDOFF_CONTEXT_PCT_KEY,
    WATCH_TAIL_LINES_KEY,
    WATCH_PREPARE_SECS_KEY,
    DIRECTIVE_UNREAD_SECS_KEY,
    WATCH_START_STALL_SECS_KEY,
    WATCH_LANE_STALL_SECS_KEY,
    CLOUD_STALL_MINUTES_KEY,
    WATCH_LANE_AGE_SECS_KEY,
    WALL_RELAUNCH_KEY,
    MAIN_WORKFLOWS_KEY,
    LINEAR_TEAM_KEY,
    OVERSEER_PREFERENCE_KEY,
    LANE_PREFERENCE_KEY,
    RECORD_RETENTION_DAYS_KEY,
    QUEUE_WAIT_ARM_GRACE_KEY,
    QUEUE_WAIT_CONFIRM_POLLS_KEY,
    QUEUE_WAIT_PROBE_INTERVAL_KEY,
    QUEUE_WAIT_REACH_CMD_KEY,
    crate::watch::report::ENABLED_KEY,
    crate::watch::report::MINUTES_KEY,
    crate::watch::report::ISSUES_KEY,
    crate::watch::report::UPCOMING_KEY,
    crate::watch::report::QUIET_HOURS_KEY,
    crate::watch::report::ZONE_KEY,
    LANES_CLI_KEY,
    COPILOT_HOLD_SECS_KEY,
    "ORCH_OVERSEER_REVIEW_TOKEN_FILE",
    "ORCH_OVERSEER_REVIEW_LOGIN",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_BOT_TOKEN",
    "GH_HOST",
    REVIEW_WAIT_SECS_KEY,
    REVIEW_ON_TIMEOUT_KEY,
    COPILOT_REQUESTS_KEY,
    ARCHIVE_ROOT_KEY,
    FLEET_DIR_KEY,
    TAKEOVER_ROWS_KEY,
    FLEET_LOG_ROW_BYTES_KEY,
    PROGRESS_REPORT_DIR_KEY,
    REVIEW_MAX_CYCLES_KEY,
    REVIEW_MAX_EXTERNAL_ROUNDS_KEY,
    CI_FIX_MAX_CYCLES_KEY,
    LANE_OUTPUT_KEY,
];

/// The keys every verb needs, so the load itself judges them and a private
/// env file line of one in a form only a shell reads refuses the load: the
/// state directory every record lives under.
const LOAD_KEYS: &[&str] = &[STATE_DIR_KEY];

/// The keys the overseer's head approval reads, its credential and its
/// reply check's reader credentials among them.
const APPROVAL_KEYS: &[&str] = &[
    "ORCH_OVERSEER_REVIEW_TOKEN_FILE",
    "ORCH_OVERSEER_REVIEW_LOGIN",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_BOT_TOKEN",
    "GH_HOST",
];

/// The account readers' keys (the listing, the renewal and the judge), read
/// from the private env file beside [`READ_KEYS`]. A spelling of one that
/// only a shell reads is passed over with a notice, never refused: an
/// operator wrote these for a loader that sourced the file, so such a line
/// stays the shell's, as a key this runtime does not read does. Every key of
/// [`READ_KEYS`] but [`LOAD_KEYS`] is read the same way.
const ACCOUNT_KEYS: &[&str] = &[
    LANE_RETIRE_KEY,
    LANE_CLOUD_REPOS_KEY,
    LANE_COPILOT_POOL_KEY,
    LANE_EXCLUDE_KEY,
    LANE_ALIASES_KEY,
    LANE_MAX_PCT_KEY,
    LANE_BURN_PCT_KEY,
    OVERSEER_HEADROOM_PCT_KEY,
    CODEX_CREDIT_FLOOR_KEY,
    CLOUD_CREDIT_FLOOR_KEY,
    LANE_HOST_KEY,
    HOME_KEY,
    LANE_DIRS_KEY,
    CODEX_HOME_KEY,
    COPILOT_HOME_KEY,
    PI_ROOT_KEY,
    USAGE_TTL_KEY,
    USAGE_MAX_AGE_KEY,
    HOST_ACCOUNTS_TIMEOUT_KEY,
    HOST_BUSY_WAIT_KEY,
    CLAUDE_USAGE_URL_KEY,
    CODEX_USAGE_URL_KEY,
    CLAUDE_TOKEN_URL_KEY,
    CLAUDE_CLIENT_ID_KEY,
];

/// What the command line says about the settings: a state directory that
/// outranks every file and key, and whether the private env file is read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Flags {
    pub state_dir: Option<PathBuf>,
    pub private_env: bool,
}

/// The checkout the settings belong to: the toplevel of the directory the
/// runtime runs in, and the main checkout a relative state directory is
/// resolved against (a linked worktree keeps its state beside the main
/// checkout's, as the store's `project_path` resolves it).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Roots {
    pub project: PathBuf,
    pub common: PathBuf,
}

/// Which question dialog setting a launched overseer runs under.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuestionToolSetting {
    Off,
    Overseer,
}

impl QuestionToolSetting {
    /// The intent an overseer launch carries; a lane never keeps the
    /// dialog, whatever the setting says.
    pub fn for_overseer(self) -> QuestionTool {
        match self {
            QuestionToolSetting::Off => QuestionTool::Off,
            QuestionToolSetting::Overseer => QuestionTool::Keep,
        }
    }
}

/// Whether a controller may ask for its own succession.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Succession {
    On,
    Off,
}

impl Succession {
    /// The setting's word, as the watch's `succession=` field printed it.
    pub fn word(self) -> &'static str {
        match self {
            Succession::On => "on",
            Succession::Off => "off",
        }
    }
}

/// Whether the watch relaunches a walled lane itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WallRelaunch {
    Auto,
    Ask,
}

/// The fleet watch's settings, which `watch run` judges at its start, before
/// its claim: the cadence the mail duty keeps and the bounds the
/// observation, mail and GitHub duties judge against. `--interval` and
/// `--max-loops` are the runner's own flags.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatchSettings {
    pub mail_interval: Duration,
    pub mark_repeat: u32,
    pub dead_passes: u32,
    pub tail_lines: u32,
    pub prepare: Duration,
    pub directive_unread: Duration,
    pub start_stall: Duration,
    pub lane_stall: Duration,
    pub cloud_stall: Duration,
    pub lane_age: Duration,
    pub wall_relaunch: WallRelaunch,
    /// `owner/repo:workflow.yml` entries, lowercased repository; an entry
    /// of another shape is refused.
    pub main_workflows: Vec<String>,
    pub security_alerts: Audit,
    pub external_triage: Audit,
}

/// Whether a GitHub audit runs: the `on`/`off` switches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Audit {
    On,
    Off,
}

/// The owner's tracker account and the label a tracker-posted ask carries,
/// read together: the owner-answer read is configured only with both
/// (`mailbox-append.sh` `owner_tracker_settings`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnerTracker {
    pub email: String,
    pub label: String,
}

/// What the tracker and GitHub read duties consume.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadSettings {
    /// The tracker program the tracker duty reads through.
    pub tracker_cli: PathBuf,
    /// The reducer the GitHub duty runs per repository.
    pub pr_watch_cli: PathBuf,
    /// The installation token file the alert reads run under.
    pub security_alert_token_file: Option<PathBuf>,
    /// Lowercased, deduplicated, in the order given.
    pub connected_repos: Vec<String>,
    pub owner_tracker: Option<OwnerTracker>,
}

/// The project's validation declaration, the one source `validate
/// start` resolves a run's mode from: the whole battery,
/// the range command where declared, the CI context where declared, the
/// selector, the finding prefix, the bound and the delivery. A command is
/// its text, trimmed of nothing; an empty or blank value is no declaration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidateSettings {
    pub cmd: Option<String>,
    pub range_cmd: Option<String>,
    pub ci_context: Option<String>,
    pub selection_cmd: Option<String>,
    /// `DEV_VALIDATE_TEXT_CMD` as written, an empty value kept: the docs
    /// mode, its one reader, judges it.
    pub text_cmd: Option<String>,
    /// The finding prefix, the bound, the delivery and the memory cap as
    /// written: the validation start judges each, so a value outside its
    /// form refuses no verb that never reads it.
    pub finding_prefix: Option<String>,
    pub timeout: Option<String>,
    pub delivery: Option<String>,
    pub memory_max: Option<String>,
}

/// What `queue-watch` reads beside its request: the arming grace, the
/// confirmation count and the probe interval, each a whole number above
/// zero, and the reach command, a blank value no declaration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueWatchSettings {
    pub arm_grace: Judged<Duration>,
    pub confirm_polls: Judged<u32>,
    pub probe_interval: Judged<Duration>,
    pub reach_cmd: Option<String>,
}

/// One stated retirement, `<name>=<YYYY-MM-DD>`: the account whose
/// alias or directory name is `name` ends its plan on that UTC day.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Retirement {
    pub name: String,
    pub date: String,
}

/// What the accounts judge reads beside the listing: the local retirement
/// statement and the pick's bounds, each the `lanes` default where unset,
/// refused by key and value as `lanes` refuses them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountSettings {
    pub retire: Vec<Retirement>,
    pub max_pct: u32,
    pub burn_pct_per_hour: u32,
    pub overseer_headroom_pct: u32,
    pub codex_credit_floor: u64,
    pub cloud_credit_floor: u64,
    pub cloud_repos: Vec<CloudRepo>,
    /// `ORCH_LANE_COPILOT_POOL`: the Copilot pool each Pi root spends, as
    /// the owner states it.
    pub copilot_pool: Vec<CopilotPool>,
    /// `ORCH_LANE_EXCLUDE`'s names, applied to the stated Pi roots alone:
    /// the reader applies the setting to every row it lists.
    pub exclude: Vec<String>,
    /// `ORCH_LANE_ALIASES`, read for the stated Pi roots alone: the reader
    /// names every row it lists through it.
    pub aliases: Vec<Alias>,
    /// The provider a pick runs under, `None` for this machine's own read.
    pub host: Option<String>,
    pub lane_dirs: Vec<String>,
    pub codex_home: Option<String>,
    pub usage_ttl: u64,
    pub usage_max_age: u64,
    pub accounts_timeout: u64,
    pub host_busy_wait: Option<String>,
    pub claude_usage_url: String,
    pub codex_usage_url: String,
    pub claude_token_url: String,
    pub claude_client_id: Option<String>,
}

/// One `ORCH_LANE_CLOUD_REPOS` entry, `<name>=<owner>/<repo>`: the
/// account whose alias or directory name is `name` has access to `repo`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudRepo {
    pub name: String,
    pub repo: String,
}

/// One `ORCH_LANE_COPILOT_POOL` entry, `<pi root>=<used>/<granted>`:
/// the Copilot pool the Pi root at `dir` spends, `used` of `granted`
/// credits spent, as the owner states it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopilotPool {
    pub dir: String,
    pub used: u64,
    pub granted: u64,
}

/// One `ORCH_LANE_ALIASES` entry, `<name>=<alias>`: the lane whose
/// directory name is `name`, with or without its dot, is called `alias`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alias {
    pub name: String,
    pub alias: String,
}

/// The settings the runtime acts on, resolved once per process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settings {
    pub roots: Roots,
    pub reads: ReadSettings,
    pub reconcile_stale_hours: String,
    pub reconcile_gh_cli: PathBuf,
    pub state_dir: PathBuf,
    pub tmux_session: Option<String>,
    pub verify: Judged<Duration>,
    pub close_grace: Judged<Duration>,
    pub claim: Judged<Duration>,
    pub watch: Judged<WatchSettings>,
    /// The tracker duties' team, which the report and the admission read too.
    pub linear_team: Option<String>,
    pub question_tool: Judged<QuestionToolSetting>,
    pub permission: Judged<Permission>,
    pub harness_binaries: Judged<BTreeMap<Harness, PathBuf>>,
    pub worktree_cli: PathBuf,
    pub agent_runtime: PathBuf,
    pub succession: Judged<Succession>,
    /// The controller's own marks.
    pub marks: MarkSettings,
    pub job_unit: PathBuf,
    pub lane_cap: Judged<u32>,
    pub cloud_lane_cap: Judged<u32>,
    /// The claim store under the watch's state directory, whose parent its
    /// readers take.
    pub claim_store: PathBuf,
    pub lane_mail_cli: PathBuf,
    pub dev_validate_cli: PathBuf,
    pub apple_workflow: String,
    pub apple_labels: Vec<String>,
    pub validate: ValidateSettings,
    pub scope_paths_cli: PathBuf,
    /// The succession's preference entries, which the overseer mark
    /// line's payload names; an empty value reads as the default, as this
    /// reader takes every key.
    pub overseer_preference: String,
    /// Whether the setting names the succession's preference, an empty
    /// value included: unset, a context mark's succession walks the
    /// controller's own entry alone, since a context handoff replaces the
    /// session and not its harness or model.
    pub overseer_preference_set: bool,
    /// A lane launch's preference entries; `None` where the setting
    /// names none.
    pub lane_preference: Option<String>,
    pub retention_days: Judged<u32>,
    pub queue_watch: QueueWatchSettings,
    pub archive_root: ArchiveRoot,
    /// The report's keys as their text, an empty value kept, since an
    /// empty value turns the timed report or quiet hours off and the report
    /// alone judges them (`report::Policy::of`).
    pub report: Vec<(String, String)>,
    pub lanes_cli: PathBuf,
    pub accounts: Judged<AccountSettings>,
    /// `HOME`, `COPILOT_HOME` and `PI_CODING_AGENT_DIR`: the homes an
    /// accountless launch and the watch's lane readers run under, which the
    /// accounts judge reads too.
    pub home: Option<String>,
    pub copilot_home: Option<String>,
    pub pi_root: Option<String>,
    pub store: StoreSettings,
    pub review: ReviewSettings,
    /// `ORCH_ROUND_PRUNE_DISK_PCT` as written.
    pub round_prune_mark: Option<String>,
    /// The `QA_KEYS` that are set, as written.
    pub qa: BTreeMap<String, String>,
    pub lane_output: Judged<LaneOutput>,
}

pub const LANE_OUTPUT_KEY: &str = "ORCH_LANE_OUTPUT";

/// What a lane prints in its pane, stated in its launch brief so its first
/// reply already follows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaneOutput {
    Quiet,
    Normal,
}

/// The controller's own marks beyond the headroom trigger: the rate mark
/// in minutes, the memory mark where set, and the context share, each
/// judged apart, since a lane's turn end reads the context share alone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkSettings {
    pub wall_minutes: Judged<u32>,
    pub memory_pct: Judged<Option<u32>>,
    pub context_pct: Judged<u32>,
}

/// The state verbs' settings: the takeover window and the row bound of the
/// fleet log, the progress report directory, and the round caps. A cap of
/// none is a documented value, so each is a whole number from zero.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoreSettings {
    pub takeover_rows: Judged<u64>,
    pub fleet_log_row_bytes: Judged<u64>,
    /// Absolute: a relative setting is joined to the main checkout.
    pub progress_report_dir: PathBuf,
    pub review_max_cycles: Judged<u64>,
    pub review_max_external_rounds: Judged<u64>,
    pub ci_fix_max_cycles: Judged<u64>,
}

/// The review settings as read: the overseer app's approval credential
/// and login with the reader credentials its reply check keeps, then the
/// hold on Copilot's work in flight, the reviewer's period, what a spent
/// period answers, and whether Copilot is asked at all. The last four are
/// carried as their text (the default where unset), since the verbs that
/// read them refuse a value outside its form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewSettings {
    pub approval_token_file: Option<PathBuf>,
    pub approval_login: Option<String>,
    pub approval_reader_env: Vec<(String, String)>,
    /// The approval keys the private env file sets in a form only a shell
    /// reads, with no caller value over them: the approval cannot know
    /// them, and the github router, which sources the file, reads them.
    pub approval_unread: Vec<String>,
    pub copilot_hold: String,
    pub wait: String,
    pub on_timeout: String,
    pub copilot_requests: String,
}

pub const COPILOT_HOLD_SECS_KEY: &str = "ORCH_COPILOT_HOLD_SECS";
const DEFAULT_COPILOT_HOLD_SECS: &str = "600";
pub const REVIEW_WAIT_SECS_KEY: &str = "PR_REVIEW_WAIT_SECS";
const DEFAULT_REVIEW_WAIT_SECS: &str = "900";
pub const REVIEW_ON_TIMEOUT_KEY: &str = "PR_REVIEW_ON_TIMEOUT";
pub const COPILOT_REQUESTS_KEY: &str = "PR_COPILOT_REQUESTS";

fn refused(key: &'static str, fields: &[(&str, &str)]) -> crate::Error {
    agent_runtime::Error::refused(key, fields).into()
}

fn file_refusal(path: &Path, key: &str, reason: &str) -> crate::Error {
    refused(
        "settings-invalid",
        &[
            ("path", &path.display().to_string()),
            ("key", key),
            ("reason", reason),
        ],
    )
}

pub(crate) fn value_refusal(key: &str, value: &str) -> crate::Error {
    refused("setting-invalid", &[("key", key), ("value", value)])
}

/// A key only some verbs read: the key's one parse ran in the load, and its
/// answer waits here, so a value outside its form refuses the verb that
/// reads it and no other.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Judged<T> {
    /// The key and the text it refused.
    read: std::result::Result<T, (&'static str, String)>,
}

impl<T: Clone> Judged<T> {
    fn of(key: &'static str, read: std::result::Result<T, &str>) -> Judged<T> {
        Judged {
            read: read.map_err(|text| (key, text.to_owned())),
        }
    }

    /// A key read as one of its words, unset the first word's value.
    fn word(key: &'static str, text: Option<&str>, words: &[(&str, T)]) -> Judged<T> {
        let read = match text {
            None => Ok(words[0].1.clone()),
            Some(text) => words
                .iter()
                .find(|(word, _)| *word == text)
                .map(|(_, value)| value.clone())
                .ok_or(text),
        };
        Judged::of(key, read)
    }

    /// The value, or `setting-invalid` naming the key and the text refused.
    pub fn get(&self) -> Result<T> {
        self.read
            .clone()
            .map_err(|(key, value)| value_refusal(key, &value))
    }

    #[cfg(test)]
    pub(crate) fn valid(value: T) -> Judged<T> {
        Judged { read: Ok(value) }
    }
}

/// The checkout roots for `cwd`, read from git through the one runner. A
/// directory outside any repository is its own root, as the shell
/// `git rev-parse --show-toplevel || pwd` takes it.
pub fn roots(cwd: &Path) -> Result<Roots> {
    let cwd_text = cwd.display().to_string();
    let Some(toplevel) = git_line(&cwd_text, "toplevel", &["--show-toplevel"])? else {
        return Ok(Roots {
            project: cwd.to_path_buf(),
            common: cwd.to_path_buf(),
        });
    };
    let project = PathBuf::from(toplevel);
    let common_dir = git_line(&cwd_text, "common-dir", &["--git-common-dir"])?
        .map(PathBuf::from)
        .unwrap_or_else(|| project.join(".git"));
    // `mailbox_common_root`: a common dir named `.git` is a checkout's own,
    // whose parent is the main checkout; anything else is this toplevel.
    let common = if common_dir.file_name().is_some_and(|n| n == ".git") {
        let git_dir = if common_dir.is_absolute() {
            common_dir
        } else {
            cwd.join(common_dir)
        };
        let parent = git_dir.parent().unwrap_or(&git_dir);
        fs::canonicalize(parent).map_err(|e| agent_runtime::Error::io("resolve", parent, e))?
    } else {
        project.clone()
    };
    Ok(Roots { project, common })
}

/// One line of `git -C cwd rev-parse ARG`, or `None` where `cwd` is in no
/// repository, git's one answer this reads as an absence.
#[allow(
    clippy::disallowed_methods,
    reason = "the settings reader runs git for the checkout roots it resolves, no effect on a lane or a controller"
)]
fn git_line(cwd: &str, operation: &'static str, args: &[&str]) -> Result<Option<String>> {
    let mut full = vec!["-C", cwd, "rev-parse"];
    full.extend_from_slice(args);
    // git's "not a git repository" is read by its words, which a translated
    // git words otherwise: the C locale outranks `LANGUAGE` too.
    let c_locale = [("LC_ALL", std::ffi::OsStr::new("C"))];
    let output = host::run_tagged_in(
        "settings",
        "git",
        Path::new("git"),
        operation,
        &full,
        host::Place {
            cwd: None,
            env: &c_locale,
        },
        GIT_TIMEOUT,
    )?;
    if output.status.success() {
        return Ok(Some(host::stdout_text(&output)));
    }
    let err = host::stderr_text(&output);
    if err.starts_with("fatal: not a git repository") {
        return Ok(None);
    }
    Err(agent_runtime::Error::External {
        program: "git",
        operation,
        cause: err,
    }
    .into())
}

/// A file's text under a checkout's root, or `None` where the checkout
/// has no such file; `Err` is the read's cause. The disk reader is
/// [`read_text`]; a hosted checkout's is the provider's `cat`.
pub type FileRead<'a> = &'a dyn Fn(&Path) -> Result<Option<String>>;

/// The file rung of the settings ladder, read through `read` under `root`:
/// the `[env]` tables of the two settings files in order, the later
/// outranking, and under `private` the private env file they name
/// (`KENDEX_ENV_FILE`, else `.env.local`); `private` carries the caller's
/// own name for that file and its home, which outrank the files' in naming
/// it and in expanding its account keys. With `local`, `root` is a checkout
/// on this host's disk, and the private file's directory is held inside it
/// before the file is read.
pub(crate) struct FileRung {
    pub(crate) values: BTreeMap<String, String>,
    pub(crate) private: Option<(PathBuf, PrivateEnv)>,
}

pub(crate) fn file_rung(
    root: &Path,
    read: FileRead,
    private: Option<(Option<&str>, Option<&str>)>,
    local: bool,
) -> Result<FileRung> {
    let mut values: BTreeMap<String, String> = BTreeMap::new();
    for name in SETTINGS_FILES {
        let path = root.join(name);
        if let Some(text) = read(&path)? {
            for (key, value) in settings_text(&path, &text)? {
                values.insert(key, value);
            }
        }
    }
    let Some((named, home)) = private else {
        return Ok(FileRung {
            values,
            private: None,
        });
    };
    let named = named
        .or_else(|| values.get(ENV_FILE_KEY).map(String::as_str))
        .filter(|v| !v.is_empty())
        .map(str::to_owned);
    let named = private_env_name(named.as_deref())?;
    if local {
        private_env_inside(root, &named)?;
    }
    let path = root.join(named);
    let home = home
        .or_else(|| values.get(HOME_KEY).map(String::as_str))
        .map(str::to_owned);
    let env = match read(&path)? {
        Some(text) => private_env_text(&path, home.as_deref(), &text)?,
        None => PrivateEnv {
            values: Vec::new(),
            passed_over: Vec::new(),
        },
    };
    Ok(FileRung {
        values,
        private: Some((path, env)),
    })
}

/// The state directory a checkout's own files name, as its `workflow-state`
/// resolves it with no caller environment: `ORCH_STATE_DIR` of its settings
/// files and private env file, `tmp` where none names one; a relative
/// directory is under the common root git names for the checkout.
pub fn state_dir_named(root: &Path, read: FileRead) -> Result<PathBuf> {
    let rung = file_rung(root, read, Some((None, None)), false)?;
    let mut values = rung.values;
    if let Some((_, private)) = rung.private {
        values.extend(private.values);
    }
    Ok(PathBuf::from(
        values
            .get(STATE_DIR_KEY)
            .filter(|v| !v.is_empty())
            .map_or(DEFAULT_STATE_DIR, String::as_str),
    ))
}

/// Resolve the settings for a process: the files under `roots`, the
/// caller's `environment` and the command-line `flags`.
pub fn load(
    roots: &Roots,
    environment: &[(OsString, OsString)],
    flags: &Flags,
) -> Result<Settings> {
    let caller: BTreeMap<String, String> = environment
        .iter()
        .filter_map(|(k, v)| Some((k.to_str()?.to_owned(), v.to_str()?.to_owned())))
        .collect();
    let disk = |path: &Path| read_text(path);
    let rung = file_rung(
        &roots.project,
        &disk,
        flags.private_env.then(|| {
            (
                caller.get(ENV_FILE_KEY).map(String::as_str),
                caller.get(HOME_KEY).map(String::as_str),
            )
        }),
        true,
    )?;
    let mut values: BTreeMap<String, String> = BTreeMap::new();
    let mut passed_over = Vec::new();
    if let Some((path, private)) = rung.private {
        // The default ladder, lowest rung first: the settings files, the
        // private env file, then the caller's environment over all.
        values.extend(rung.values);
        for key in &private.passed_over {
            use std::io::Write as _;
            let _ = writeln!(
                std::io::stderr(),
                "settings-skipped path={} key={key} reason=shell-form",
                path.display()
            );
        }
        passed_over = private.passed_over;
        values.extend(private.values);
        for (key, value) in caller {
            values.insert(key, value);
        }
    } else {
        // Under `--no-private-env` the shell loader takes `ORCH_STATE_DIR`
        // alone from the files, the later file outranking the earlier and
        // both outranking the caller's environment, and reads no other key
        // from them (`workflow-state` § State directory). Every other key
        // comes from the caller's environment.
        values.extend(caller);
        if let Some(state_dir) = rung.values.get(STATE_DIR_KEY) {
            values.insert(STATE_DIR_KEY.to_owned(), state_dir.clone());
        }
    }
    // Keys a consumer's settings may still set that no verb reads: one
    // notice per load for each one set, naming the key that does its job
    // where one does, so the value is not dropped in silence. Never a
    // refusal: such a line in a settings file stops no verb.
    {
        const RETIRED: [(&str, Option<&str>); 7] = [
            ("CI_WAIT_NO_CHECKS_GRACE", None),
            ("ORCH_LANE_SSH_PROMPT_SECS", None),
            ("ORCH_MERGE_BYPASS", None),
            (
                "ORCH_OVERSEER_SEAT_RESERVE_PCT",
                Some(OVERSEER_HEADROOM_PCT_KEY),
            ),
            ("ORCH_OVERSEER_SUCCESSOR_ACCOUNTS", None),
            ("ORCH_OVERSEER_SYNC_TIMEOUT_S", None),
            ("ORCH_WORKTREE_BIN", Some(WORKTREE_CLI_KEY)),
        ];
        use std::io::Write as _;
        for (key, stand_in) in RETIRED {
            if values.get(key).is_none_or(String::is_empty) {
                continue;
            }
            let _ = match stand_in {
                Some(stand_in) => writeln!(
                    std::io::stderr(),
                    "settings-retired key={key} stand-in={stand_in}"
                ),
                None => writeln!(std::io::stderr(), "settings-retired key={key}"),
            };
        }
    }
    let get = |key: &str| {
        values
            .get(key)
            .filter(|v| !v.is_empty())
            .map(String::as_str)
    };

    let state_dir = match &flags.state_dir {
        Some(dir) if dir.as_os_str().is_empty() => {
            return Err(refused("state-dir-value", &[("option", "--state-dir")]));
        }
        Some(dir) => dir.clone(),
        None => PathBuf::from(get(STATE_DIR_KEY).unwrap_or(DEFAULT_STATE_DIR)),
    };
    let state_dir = if state_dir.is_absolute() {
        state_dir
    } else {
        roots.common.join(state_dir)
    };
    let secs = |key: &'static str, default: u64| -> Judged<Duration> {
        Judged::of(
            key,
            match get(key) {
                None => Ok(Duration::from_secs(default)),
                Some(text) => match text.parse::<u64>() {
                    Ok(n) if n > 0 && !text.starts_with('0') && !text.starts_with('+') => {
                        Ok(Duration::from_secs(n))
                    }
                    Ok(_) | Err(_) => Err(text),
                },
            },
        )
    };
    // Zero, or digits with no leading zero: a wait of none is a documented
    // value (the mail read once a turn, a directive reported unread at once).
    let secs_or_none = |key: &'static str, default: u64| -> Judged<Duration> {
        match get(key) {
            Some("0") => Judged::of(key, Ok(Duration::ZERO)),
            None | Some(_) => secs(key, default),
        }
    };
    let question_tool = Judged::word(
        QUESTION_TOOL_KEY,
        get(QUESTION_TOOL_KEY),
        &[
            ("off", QuestionToolSetting::Off),
            ("overseer", QuestionToolSetting::Overseer),
        ],
    );
    let permission = Judged::word(
        LAUNCH_PERMISSION_KEY,
        get(LAUNCH_PERMISSION_KEY),
        &[
            ("bypass", Permission::Bypass),
            ("native", Permission::Native),
        ],
    );
    let harness_binaries = Judged::of(
        HARNESS_BINARIES_KEY,
        match get(HARNESS_BINARIES_KEY) {
            None => Ok(BTreeMap::new()),
            Some(text) => harness_binaries(text).ok_or(text),
        },
    );
    let worktree_cli = match get(WORKTREE_CLI_KEY) {
        Some(path) => PathBuf::from(path),
        None => roots.project.join(WORKTREE_CLI_DEFAULT),
    };
    let succession = Judged::word(
        SUCCESSION_KEY,
        get(SUCCESSION_KEY),
        &[("on", Succession::On), ("off", Succession::Off)],
    );
    let job_unit = match get(JOB_UNIT_KEY) {
        Some(path) => PathBuf::from(path),
        None => roots.project.join(JOB_UNIT_DEFAULT),
    };
    // Base ten, no sign and no leading zero; a count of none names a
    // misconfiguration (a cap of none admits no lane, a repeat of none
    // repeats every pass).
    let count = |key: &'static str, default: u32| -> Judged<u32> {
        Judged::of(
            key,
            match get(key) {
                None => Ok(default),
                Some(text) => match text.parse::<u32>() {
                    Ok(n) if n > 0 && !text.starts_with('0') && !text.starts_with('+') => Ok(n),
                    Ok(_) | Err(_) => Err(text),
                },
            },
        )
    };
    let lane_cap = count(LANE_CAP_KEY, DEFAULT_LANE_CAP);
    let cloud_lane_cap = count(CLOUD_LANE_CAP_KEY, DEFAULT_CLOUD_LANE_CAP);
    // Digits alone with the value at least 1, a leading zero admitted.
    let passes = |key: &'static str, default: u32| -> Judged<u32> {
        Judged::of(
            key,
            match get(key) {
                None => Ok(default),
                Some(text) => match text.parse::<u32>() {
                    Ok(n) if n > 0 && text.bytes().all(|b| b.is_ascii_digit()) => Ok(n),
                    Ok(_) | Err(_) => Err(text),
                },
            },
        )
    };
    let audit =
        |key: &'static str| Judged::word(key, get(key), &[("on", Audit::On), ("off", Audit::Off)]);
    let watch = Judged {
        read: (|| {
            Ok(WatchSettings {
                mail_interval: secs_or_none(WATCH_MAIL_INTERVAL_KEY, DEFAULT_MAIL_INTERVAL_SECS)
                    .read?,
                mark_repeat: count(OVERSEER_MARK_REPEAT_KEY, DEFAULT_MARK_REPEAT).read?,
                dead_passes: passes(OVERSEER_DEAD_PASSES_KEY, DEFAULT_DEAD_PASSES).read?,
                tail_lines: count(WATCH_TAIL_LINES_KEY, DEFAULT_TAIL_LINES).read?,
                prepare: secs(WATCH_PREPARE_SECS_KEY, DEFAULT_PREPARE_SECS).read?,
                directive_unread: secs_or_none(
                    DIRECTIVE_UNREAD_SECS_KEY,
                    DEFAULT_DIRECTIVE_UNREAD_SECS,
                )
                .read?,
                start_stall: secs(WATCH_START_STALL_SECS_KEY, DEFAULT_START_STALL_SECS).read?,
                lane_stall: secs(WATCH_LANE_STALL_SECS_KEY, DEFAULT_LANE_STALL_SECS).read?,
                cloud_stall: secs(CLOUD_STALL_MINUTES_KEY, DEFAULT_CLOUD_STALL_MINUTES)
                    .read?
                    .saturating_mul(60),
                lane_age: secs(WATCH_LANE_AGE_SECS_KEY, DEFAULT_LANE_AGE_SECS).read?,
                wall_relaunch: Judged::word(
                    WALL_RELAUNCH_KEY,
                    get(WALL_RELAUNCH_KEY),
                    &[("auto", WallRelaunch::Auto), ("ask", WallRelaunch::Ask)],
                )
                .read?,
                main_workflows: Judged::of(
                    MAIN_WORKFLOWS_KEY,
                    match get(MAIN_WORKFLOWS_KEY) {
                        None => Ok(Vec::new()),
                        Some(text) => main_workflows(text).ok_or(text),
                    },
                )
                .read?,
                security_alerts: audit(SECURITY_ALERTS_KEY).read?,
                external_triage: audit(EXTERNAL_TRIAGE_KEY).read?,
            })
        })(),
    };
    let claim_store = match get(CLAIM_STATE_DIR_KEY) {
        Some(dir) => {
            let dir = PathBuf::from(dir);
            let dir = if dir.is_absolute() {
                dir
            } else {
                roots.project.join(dir)
            };
            dir.join("claims")
        }
        None => roots.common.join(CLAIM_STORE_DEFAULT),
    };
    let program = |key: &str, default: &str| match get(key) {
        Some(path) => PathBuf::from(path),
        None => roots.project.join(default),
    };
    let lane_mail_cli = program(LANE_MAIL_CLI_KEY, LANE_MAIL_CLI_DEFAULT);
    let agent_runtime = program(AGENT_RUNTIME_KEY, AGENT_RUNTIME_DEFAULT);
    let dev_validate_cli = program(DEV_VALIDATE_CLI_KEY, DEV_VALIDATE_CLI_DEFAULT);
    // A command whose value is blank is no declaration, as the shell
    // `${cmd//[[:space:]]/}` reads it.
    let command = |key: &str| get(key).filter(|v| !v.trim().is_empty()).map(str::to_owned);
    let validate = ValidateSettings {
        cmd: command(DEV_VALIDATE_CMD_KEY),
        range_cmd: command(DEV_VALIDATE_RANGE_CMD_KEY),
        ci_context: command(DEV_VALIDATE_CI_CONTEXT_KEY),
        selection_cmd: command(DEV_VALIDATE_SELECTION_CMD_KEY),
        text_cmd: get("DEV_VALIDATE_TEXT_CMD").map(str::to_owned),
        finding_prefix: get(DEV_VALIDATE_FINDING_PREFIX_KEY).map(str::to_owned),
        timeout: get(DEV_VALIDATE_TIMEOUT_SECS_KEY).map(str::to_owned),
        delivery: get(DELIVERY_KEY).map(str::to_owned),
        memory_max: get(VALIDATE_MEMORY_MAX_KEY).map(str::to_owned),
    };
    let scope_paths_cli = program(SCOPE_PATHS_CLI_KEY, SCOPE_PATHS_CLI_DEFAULT);
    // A preference set empty names no entry, which the overseer launch
    // refuses; unset is the default.
    let overseer_preference = values
        .get(OVERSEER_PREFERENCE_KEY)
        .map_or(DEFAULT_OVERSEER_PREFERENCE, String::as_str)
        .to_owned();
    let overseer_preference_set = values.contains_key(OVERSEER_PREFERENCE_KEY);
    let lane_preference = get(LANE_PREFERENCE_KEY).map(str::to_owned);
    let retention_days = count(RECORD_RETENTION_DAYS_KEY, DEFAULT_RECORD_RETENTION_DAYS);
    let count_secs = |key: &'static str, default: u32| Judged {
        read: count(key, default)
            .read
            .map(|n| Duration::from_secs(u64::from(n))),
    };
    let queue_watch = QueueWatchSettings {
        arm_grace: count_secs(QUEUE_WAIT_ARM_GRACE_KEY, DEFAULT_QUEUE_WAIT_ARM_GRACE_SECS),
        confirm_polls: count(
            QUEUE_WAIT_CONFIRM_POLLS_KEY,
            DEFAULT_QUEUE_WAIT_CONFIRM_POLLS,
        ),
        probe_interval: count_secs(
            QUEUE_WAIT_PROBE_INTERVAL_KEY,
            DEFAULT_QUEUE_WAIT_PROBE_INTERVAL_SECS,
        ),
        reach_cmd: command(QUEUE_WAIT_REACH_CMD_KEY),
    };
    let archive_root = match get(ARCHIVE_ROOT_KEY) {
        Some(text) if Path::new(text).is_absolute() => ArchiveRoot::Configured(PathBuf::from(text)),
        Some(text) => ArchiveRoot::Invalid(text.to_owned()),
        None => {
            let fleet = match get(FLEET_DIR_KEY) {
                Some(dir) => PathBuf::from(dir),
                None => PathBuf::from(get("HOME").unwrap_or("")).join(".fleet"),
            };
            let fleet = if fleet.is_absolute() {
                fleet
            } else {
                roots.project.join(fleet)
            };
            ArchiveRoot::Default(fleet.join("archive"))
        }
    };
    let report = crate::watch::report::KEYS
        .into_iter()
        .filter_map(|key| values.get(key).map(|v| (key.to_owned(), v.clone())))
        .collect();
    let lanes_cli = program(LANES_CLI_KEY, LANES_CLI_DEFAULT);
    let pct = |key: &'static str, default: u32| -> Judged<u32> {
        Judged::of(
            key,
            match get(key) {
                None => Ok(default),
                Some(text) => match text.parse::<u32>() {
                    Ok(n)
                        if n <= 100
                            && text.len() <= 3
                            && text.bytes().all(|b| b.is_ascii_digit()) =>
                    {
                        Ok(n)
                    }
                    Ok(_) | Err(_) => Err(text),
                },
            },
        )
    };
    let whole = |key: &'static str, default: u64| -> Judged<u64> {
        Judged::of(
            key,
            match get(key) {
                None => Ok(default),
                Some(text) => match text.parse::<u64>() {
                    Ok(n) if text.bytes().all(|b| b.is_ascii_digit()) => Ok(n),
                    Ok(_) | Err(_) => Err(text),
                },
            },
        )
    };
    // A whole number of at most nine digits, 0 included: 0 turns a mark off.
    let minutes = |key: &'static str, default: u32| -> Judged<u32> {
        Judged::of(
            key,
            match get(key) {
                None => Ok(default),
                Some(text) => match text.parse::<u32>() {
                    Ok(n) if text.len() <= 9 && text.bytes().all(|b| b.is_ascii_digit()) => Ok(n),
                    Ok(_) | Err(_) => Err(text),
                },
            },
        )
    };
    let marks = MarkSettings {
        wall_minutes: minutes(OVERSEER_WALL_MINUTES_KEY, DEFAULT_OVERSEER_WALL_MINUTES),
        // Unset or 0 is no memory mark, as 0 turns the other marks off.
        memory_pct: Judged {
            read: pct(OVERSEER_MEMORY_PCT_KEY, 0)
                .read
                .map(|pct| Some(pct).filter(|&pct| pct > 0)),
        },
        context_pct: Judged {
            read: pct(HANDOFF_CONTEXT_PCT_KEY, DEFAULT_HANDOFF_CONTEXT_PCT)
                .read
                .and_then(|pct| match pct {
                    0 => Err((HANDOFF_CONTEXT_PCT_KEY, "0".to_owned())),
                    n => Ok(n),
                }),
        },
    };
    // The accounts judge's keys, held to `lanes`' own grammar
    // (`validate_lane_settings`, `pct_valid`), judged together since every
    // entry of the judge reads them: a retirement names a lane (no `/`, no
    // `~`) and a real calendar day; a percentage is a whole number 0 to 100;
    // a value nobody can read is refused, never defaulted.
    let accounts = Judged {
        read: (|| {
            let mut retire = Vec::new();
            if let Some(text) = get(LANE_RETIRE_KEY) {
                for item in text.split(',').map(str::trim).filter(|i| !i.is_empty()) {
                    let valid = item.split_once('=').filter(|(name, date)| {
                        lane_key_valid(name.trim()) && calendar_date_valid(date.trim())
                    });
                    let Some((name, date)) = valid else {
                        return Err((LANE_RETIRE_KEY, item.to_owned()));
                    };
                    retire.push(Retirement {
                        name: name.trim().to_owned(),
                        date: date.trim().to_owned(),
                    });
                }
            }
            // A cloud repository entry names a lane (as a retirement does) and
            // an `owner/repo` in GitHub's own alphabet; one nobody can read is
            // refused, never dropped, since a dropped entry would hand a cloud
            // session an account with no access to the repository.
            let mut cloud_repos = Vec::new();
            if let Some(text) = get(LANE_CLOUD_REPOS_KEY) {
                for item in text.split(',').map(str::trim).filter(|i| !i.is_empty()) {
                    let valid = item.split_once('=').filter(|(name, repo)| {
                        let name = name.trim();
                        let repo = repo.trim();
                        let (owner, project) = repo.split_once('/').unwrap_or(("", ""));
                        lane_key_valid(name)
                            && !owner.is_empty()
                            && owner
                                .bytes()
                                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
                            && !project.is_empty()
                            && project.bytes().all(|b| {
                                b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')
                            })
                    });
                    let Some((name, repo)) = valid else {
                        return Err((LANE_CLOUD_REPOS_KEY, item.to_owned()));
                    };
                    cloud_repos.push(CloudRepo {
                        name: name.trim().to_owned(),
                        repo: repo.trim().to_owned(),
                    });
                }
            }
            // The stated Copilot pool, `lanes`' `copilot_pool_entries` rule:
            // an absolute Pi root, the credits used and granted as whole numbers of
            // at most twelve digits, the grant above zero, one entry per root; an
            // entry nobody can read is refused, never dropped, since a reading
            // nobody can parse is not judged as room.
            let mut copilot_pool: Vec<CopilotPool> = Vec::new();
            if let Some(text) = get(LANE_COPILOT_POOL_KEY) {
                for item in text.split(',').map(str::trim).filter(|i| !i.is_empty()) {
                    let whole = |s: &str| {
                        (1..=12).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_digit())
                    };
                    let entry = item.rsplit_once('=').and_then(|(dir, value)| {
                        let dir = dir.trim().trim_end_matches('/');
                        let (used, granted) = value.trim().split_once('/')?;
                        (dir.starts_with('/') && whole(used) && whole(granted)).then(|| {
                            CopilotPool {
                                dir: dir.to_owned(),
                                used: used.parse().unwrap_or(0),
                                granted: granted.parse().unwrap_or(0),
                            }
                        })
                    });
                    let Some(entry) = entry.filter(|e| e.granted > 0) else {
                        return Err((LANE_COPILOT_POOL_KEY, item.to_owned()));
                    };
                    if copilot_pool.iter().any(|e| e.dir == entry.dir) {
                        return Err((LANE_COPILOT_POOL_KEY, item.to_owned()));
                    }
                    copilot_pool.push(entry);
                }
            }
            // `ORCH_LANE_EXCLUDE` names lanes, never paths (`lanes`' `lane_key_valid`).
            let mut exclude = Vec::new();
            if let Some(text) = get(LANE_EXCLUDE_KEY) {
                for item in text.split(',').map(str::trim).filter(|i| !i.is_empty()) {
                    if !lane_key_valid(item) {
                        return Err((LANE_EXCLUDE_KEY, item.to_owned()));
                    }
                    exclude.push(item.to_owned());
                }
            }
            // `ORCH_LANE_ALIASES` as `lanes` reads it (`validate_lane_settings`):
            // an item without `=` or with an empty side is passed over, never refused.
            let mut aliases = Vec::new();
            if let Some(text) = get(LANE_ALIASES_KEY) {
                for item in text.split(',').map(str::trim).filter(|i| !i.is_empty()) {
                    let Some((name, alias)) = item.split_once('=') else {
                        continue;
                    };
                    let (name, alias) = (name.trim(), alias.trim());
                    if name.is_empty() || alias.is_empty() {
                        continue;
                    }
                    aliases.push(Alias {
                        name: name.to_owned(),
                        alias: alias.to_owned(),
                    });
                }
            }
            Ok(AccountSettings {
                retire,
                max_pct: pct(LANE_MAX_PCT_KEY, DEFAULT_LANE_MAX_PCT).read?,
                burn_pct_per_hour: pct(LANE_BURN_PCT_KEY, DEFAULT_LANE_BURN_PCT).read?,
                overseer_headroom_pct: pct(
                    OVERSEER_HEADROOM_PCT_KEY,
                    DEFAULT_OVERSEER_HEADROOM_PCT,
                )
                .read?,
                codex_credit_floor: whole(CODEX_CREDIT_FLOOR_KEY, DEFAULT_CODEX_CREDIT_FLOOR)
                    .read?,
                cloud_credit_floor: whole(CLOUD_CREDIT_FLOOR_KEY, DEFAULT_CLOUD_CREDIT_FLOOR)
                    .read?,
                cloud_repos,
                copilot_pool,
                exclude,
                aliases,
                host: get(LANE_HOST_KEY)
                    .filter(|h| *h != "local")
                    .map(str::to_owned),
                lane_dirs: get(LANE_DIRS_KEY)
                    .unwrap_or_default()
                    .split(':')
                    .filter(|d| !d.is_empty())
                    .map(str::to_owned)
                    .collect(),
                codex_home: get(CODEX_HOME_KEY).map(str::to_owned),
                usage_ttl: whole(USAGE_TTL_KEY, DEFAULT_USAGE_TTL).read?,
                usage_max_age: whole(USAGE_MAX_AGE_KEY, 0).read?,
                accounts_timeout: whole(HOST_ACCOUNTS_TIMEOUT_KEY, DEFAULT_HOST_ACCOUNTS_TIMEOUT)
                    .read?,
                host_busy_wait: get(HOST_BUSY_WAIT_KEY).map(str::to_owned),
                claude_usage_url: get(CLAUDE_USAGE_URL_KEY)
                    .unwrap_or(CLAUDE_USAGE_URL_DEFAULT)
                    .to_owned(),
                codex_usage_url: get(CODEX_USAGE_URL_KEY)
                    .unwrap_or(CODEX_USAGE_URL_DEFAULT)
                    .to_owned(),
                claude_token_url: get(CLAUDE_TOKEN_URL_KEY)
                    .unwrap_or(CLAUDE_TOKEN_URL_DEFAULT)
                    .to_owned(),
                claude_client_id: get(CLAUDE_CLIENT_ID_KEY).map(str::to_owned),
            })
        })(),
    };
    // The read duties' keys; the connected repositories and the owner
    // tracker keep the shell's grammar (`orch_connected_repos`,
    // `owner_tracker_settings`).
    let mut connected_repos: Vec<String> = Vec::new();
    for entry in get(CONNECTED_REPOS_KEY)
        .unwrap_or_default()
        .split_whitespace()
    {
        let entry = entry.to_ascii_lowercase();
        if !connected_repos.contains(&entry) {
            connected_repos.push(entry);
        }
    }
    let owner_tracker = match (
        get(OWNER_EMAIL_KEY).or_else(|| get(USER_EMAIL_KEY)),
        get(OWNER_ASK_LABEL_KEY),
    ) {
        (Some(email), Some(label)) => Some(OwnerTracker {
            email: email.to_owned(),
            label: label.to_owned(),
        }),
        (None, _) | (_, None) => None,
    };
    let reads = ReadSettings {
        tracker_cli: program(TRACKER_CLI_KEY, TRACKER_CLI_DEFAULT),
        pr_watch_cli: program(PR_WATCH_CLI_KEY, PR_WATCH_CLI_DEFAULT),
        security_alert_token_file: get(SECURITY_ALERT_TOKEN_FILE_KEY).map(PathBuf::from),
        connected_repos,
        owner_tracker,
    };
    let progress_report_dir =
        PathBuf::from(get(PROGRESS_REPORT_DIR_KEY).unwrap_or(DEFAULT_PROGRESS_REPORT_DIR));
    let store = StoreSettings {
        takeover_rows: whole(TAKEOVER_ROWS_KEY, DEFAULT_TAKEOVER_ROWS),
        fleet_log_row_bytes: whole(FLEET_LOG_ROW_BYTES_KEY, DEFAULT_FLEET_LOG_ROW_BYTES),
        progress_report_dir: if progress_report_dir.is_absolute() {
            progress_report_dir
        } else {
            roots.common.join(progress_report_dir)
        },
        review_max_cycles: whole(REVIEW_MAX_CYCLES_KEY, DEFAULT_REVIEW_MAX_CYCLES),
        review_max_external_rounds: whole(
            REVIEW_MAX_EXTERNAL_ROUNDS_KEY,
            DEFAULT_REVIEW_MAX_EXTERNAL_ROUNDS,
        ),
        ci_fix_max_cycles: whole(CI_FIX_MAX_CYCLES_KEY, DEFAULT_CI_FIX_MAX_CYCLES),
    };
    let text = |key: &str, default: &str| get(key).unwrap_or(default).to_owned();
    let review = ReviewSettings {
        approval_token_file: get("ORCH_OVERSEER_REVIEW_TOKEN_FILE").map(PathBuf::from),
        approval_login: get("ORCH_OVERSEER_REVIEW_LOGIN").map(str::to_owned),
        approval_reader_env: ["GH_TOKEN", "GITHUB_TOKEN", "GH_BOT_TOKEN", "GH_HOST"]
            .into_iter()
            .filter_map(|key| values.get(key).map(|v| (key.to_owned(), v.clone())))
            .collect(),
        approval_unread: passed_over
            .iter()
            .filter(|key| APPROVAL_KEYS.contains(&key.as_str()) && !values.contains_key(*key))
            .cloned()
            .collect(),
        copilot_hold: text(COPILOT_HOLD_SECS_KEY, DEFAULT_COPILOT_HOLD_SECS),
        wait: text(REVIEW_WAIT_SECS_KEY, DEFAULT_REVIEW_WAIT_SECS),
        on_timeout: text(REVIEW_ON_TIMEOUT_KEY, "proceed"),
        copilot_requests: text(COPILOT_REQUESTS_KEY, "on"),
    };
    let round_prune_mark = get(ROUND_PRUNE_KEY).map(str::to_owned);
    let qa = QA_KEYS
        .iter()
        .filter_map(|key| get(key).map(|v| ((*key).to_owned(), v.to_owned())))
        .collect();
    Ok(Settings {
        round_prune_mark,
        qa,
        roots: roots.clone(),
        reads,
        reconcile_stale_hours: get("RECONCILE_STALE_HOURS")
            .filter(|s| !s.is_empty())
            .unwrap_or("24")
            .to_owned(),
        reconcile_gh_cli: PathBuf::from(
            get("RECONCILE_GH_CLI")
                .filter(|s| !s.is_empty())
                .unwrap_or("gh"),
        ),
        state_dir,
        store,
        review,
        tmux_session: get(TMUX_SESSION_KEY).map(str::to_owned),
        verify: secs(VERIFY_SECS_KEY, DEFAULT_VERIFY_SECS),
        close_grace: secs(CLOSE_SECS_KEY, DEFAULT_CLOSE_SECS),
        claim: secs(JOB_CLAIM_SECS_KEY, DEFAULT_CLAIM_SECS),
        watch,
        linear_team: get(LINEAR_TEAM_KEY).map(str::to_owned),
        question_tool,
        permission,
        harness_binaries,
        worktree_cli,
        agent_runtime,
        succession,
        marks,
        job_unit,
        lane_cap,
        cloud_lane_cap,
        claim_store,
        lane_mail_cli,
        dev_validate_cli,
        apple_workflow: values
            .get("ORCH_APPLE_WORKFLOW")
            .map(String::as_str)
            .unwrap_or(".github/workflows/mac-run.yml")
            .to_owned(),
        apple_labels: values
            .get("ORCH_APPLE_LABELS")
            .map(String::as_str)
            .unwrap_or("ios macos")
            .split_whitespace()
            .map(str::to_owned)
            .collect(),
        validate,
        scope_paths_cli,
        overseer_preference,
        overseer_preference_set,
        lane_preference,
        retention_days,
        queue_watch,
        archive_root,
        report,
        lanes_cli,
        accounts,
        home: get(HOME_KEY).map(str::to_owned),
        copilot_home: get(COPILOT_HOME_KEY).map(str::to_owned),
        pi_root: get(PI_ROOT_KEY).map(str::to_owned),
        lane_output: Judged::word(
            LANE_OUTPUT_KEY,
            get(LANE_OUTPUT_KEY),
            &[("quiet", LaneOutput::Quiet), ("normal", LaneOutput::Normal)],
        ),
    })
}

/// `harness=/absolute/path` pairs separated by commas, one per harness;
/// `None` is any other shape.
fn harness_binaries(text: &str) -> Option<BTreeMap<Harness, PathBuf>> {
    let mut binaries = BTreeMap::new();
    for pair in text.split(',') {
        let (name, path) = pair.trim().split_once('=')?;
        let harness = Harness::parse(name.trim())?;
        let path = PathBuf::from(path.trim());
        if !path.is_absolute() || binaries.insert(harness, path).is_some() {
            return None;
        }
    }
    Some(binaries)
}

/// `owner/repo:workflow.yml` entries separated by whitespace, the
/// repository lowercased; `None` is any other shape.
fn main_workflows(text: &str) -> Option<Vec<String>> {
    let word = |s: &str| {
        !s.is_empty()
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
    };
    let mut workflows = Vec::new();
    for entry in text.split_whitespace() {
        let (repo, workflow) = entry.split_once(':')?;
        let repo_ok = repo
            .split_once('/')
            .is_some_and(|(o, n)| word(o) && word(n));
        let workflow_ok = workflow
            .strip_suffix(".yml")
            .or_else(|| workflow.strip_suffix(".yaml"))
            .is_some_and(word);
        if !repo_ok || !workflow_ok {
            return None;
        }
        workflows.push(format!("{}:{workflow}", repo.to_ascii_lowercase()));
    }
    Some(workflows)
}

/// `lanes`' `lane_key_valid`, the one grammar of a name that stands
/// for a lane in a setting (`ORCH_LANE_EXCLUDE`, `ORCH_LANE_RETIRE`,
/// `ORCH_LANE_CLOUD_REPOS`): a directory name or an alias, never empty;
/// a `/` or a `~` makes it a path, which names no lane, so a statement
/// written that way would cover nothing.
fn lane_key_valid(name: &str) -> bool {
    !name.is_empty() && !name.contains('/') && !name.contains('~')
}

/// Whether `text` is a `YYYY-MM-DD` naming a real calendar day
/// (`lanes`' `calendar_date_valid`, arithmetic rather than `date(1)`).
pub fn calendar_date_valid(text: &str) -> bool {
    let bytes = text.as_bytes();
    if bytes.len() != 10
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || !bytes
            .iter()
            .enumerate()
            .all(|(i, b)| i == 4 || i == 7 || b.is_ascii_digit())
    {
        return false;
    }
    let (Ok(y), Ok(m), Ok(d)) = (
        text[0..4].parse::<u32>(),
        text[5..7].parse::<u32>(),
        text[8..10].parse::<u32>(),
    ) else {
        return false;
    };
    let days = match m {
        4 | 6 | 9 | 11 => 30,
        2 if y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) => 29,
        2 => 28,
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        _ => return false,
    };
    (1..=days).contains(&d)
}

/// The private env file's project-relative name: the default, or the
/// configured one held to the spelling the shell loader admits.
fn private_env_name(named: Option<&str>) -> Result<PathBuf> {
    let Some(named) = named else {
        return Ok(PathBuf::from(DEFAULT_ENV_FILE));
    };
    let outside = named.starts_with('/')
        || named.contains(':')
        || named.contains('\\')
        || named == ".."
        || named.starts_with("../")
        || named.contains("/../")
        || named.ends_with("/..");
    if outside {
        return Err(refused("private-env-path", &[("path", named)]));
    }
    Ok(PathBuf::from(named))
}

/// Whether the directory the private env file `named` sits in stays inside
/// the project once every link on the way is followed, judged as the shell
/// loader judges it before it reads the file: the deepest existing ancestor
/// of that directory is resolved, a component that exists as something
/// other than a directory blocks the path, and a directory this process
/// cannot enter is unresolved. The file itself may be a link, as a
/// worktree's `.env.local` linked to its main checkout's is.
fn private_env_inside(root: &Path, named: &Path) -> Result<()> {
    // The kernel looks `.` up inside `dir` only where this process may enter
    // it, as `cd -P` must; the resolution itself drops a trailing `.`
    // without entering.
    let enter = |dir: &Path| fs::metadata(dir.join(".")).and_then(|_| fs::canonicalize(dir));
    let unresolved = |dir: &Path| {
        refused(
            "private-env-unresolved",
            &[("path", &dir.display().to_string())],
        )
    };
    let shown = named.display().to_string();
    let top = match enter(root) {
        Ok(top) => top,
        // A root that does not exist holds no file to read.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(unresolved(root)),
    };
    let path = root.join(named);
    // The climb passes only components the loader's `-e` reads as absent,
    // which takes any failed lookup for absence.
    let mut dir = path.parent();
    while let Some(d) = dir {
        if fs::metadata(d).is_ok() {
            break;
        }
        dir = d.parent();
    }
    let dir = dir.unwrap_or(Path::new("/"));
    if !fs::metadata(dir).is_ok_and(|m| m.is_dir()) {
        return Err(refused("private-env-blocked", &[("path", &shown)]));
    }
    let at = enter(dir).map_err(|_| unresolved(dir))?;
    if !at.starts_with(&top) {
        return Err(refused("private-env-outside", &[("path", &shown)]));
    }
    Ok(())
}

/// A settings source's text, the source classified as the shell loader
/// classifies one before reading it: only a path that is absent and no link
/// reads as no file; a link that resolves to nothing refuses
/// `unresolved-link`, anything but a regular file refuses `not-file` before
/// any read (a FIFO would hold the read open), a file this process may not
/// read refuses `unreadable`, and a leading byte-order mark refuses
/// `byte-order-mark`.
pub(crate) fn read_text(path: &Path) -> Result<Option<String>> {
    let refusal = |reason: &str| file_refusal(path, "", reason);
    match fs::metadata(path) {
        Ok(meta) if !meta.is_file() => return Err(refusal("not-file")),
        Ok(_) => {}
        Err(_) if fs::symlink_metadata(path).is_ok() => return Err(refusal("unresolved-link")),
        Err(_) => return Ok(None),
    }
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            return Err(refusal("unreadable"));
        }
        Err(e) => return Err(agent_runtime::Error::io("read", path, e).into()),
    };
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return Err(refusal("byte-order-mark"));
    }
    Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
}

fn is_key(text: &str) -> bool {
    let mut chars = text.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Decode a `[env]` value: `"basic"` with no `"` or `\` inside, or
/// `'literal'` with no apostrophe inside, then optional space and a `#`
/// comment. `None` is a shape outside the contract.
fn decode_toml_value(raw: &str) -> Option<String> {
    let raw = raw.trim();
    let (quote, forbidden): (char, &[char]) = if raw.starts_with('\'') {
        ('\'', &['\''])
    } else {
        ('"', &['"', '\\'])
    };
    let body = raw.strip_prefix(quote)?;
    let end = body.find(quote)?;
    let value = &body[..end];
    if value.contains(forbidden) {
        return None;
    }
    let rest = body[end + 1..].trim_start();
    if rest.is_empty() || rest.starts_with('#') {
        Some(value.to_owned())
    } else {
        None
    }
}

/// The `[env]` assignments of one settings file, in file order; an absent
/// file holds none.
pub(crate) fn settings_file(path: &Path) -> Result<Vec<(String, String)>> {
    match read_text(path)? {
        Some(text) => settings_text(path, &text),
        None => Ok(Vec::new()),
    }
}

/// [`settings_file`] over a file's text; `path` names it in a refusal.
pub(crate) fn settings_text(path: &Path, text: &str) -> Result<Vec<(String, String)>> {
    let mut out = Vec::new();
    let mut section = String::new();
    let mut seen: Vec<String> = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix('[') {
            match rest.strip_suffix(']') {
                Some(name)
                    if !name.is_empty()
                        && name
                            .chars()
                            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-')) =>
                {
                    section = name.to_owned();
                    continue;
                }
                Some(_) | None => return Err(file_refusal(path, "", "table-header")),
            }
        }
        if section != "env" {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if !is_key(key) {
            continue;
        }
        if seen.iter().any(|k| k == key) {
            return Err(file_refusal(path, key, "duplicate-key"));
        }
        seen.push(key.to_owned());
        let Some(value) = decode_toml_value(value) else {
            return Err(file_refusal(path, key, "value-syntax"));
        };
        out.push((key.to_owned(), value));
    }
    Ok(out)
}

/// Read an account key's value as the sourcing shell assigns it, for the
/// forms this reader can stand in for: one single-quoted string as it
/// stands; one double-quoted string or one bare word with `$HOME` and
/// `${HOME}` read as `home`, and in a bare word a `~` at its start or after
/// a `:`, before a `/`, a `:` or its end, read as `home` too, as bash
/// expands it in an assignment; then blanks and an optional `#` comment.
/// An empty value is the empty string, which blanks the key as the shell's
/// assignment does. `None` is any other shell form, or a home form with no
/// home to read.
fn decode_account_value(raw: &str, home: Option<&str>) -> Option<String> {
    let raw = raw.trim_end();
    let comment_only = |rest: &str| {
        let tail = rest.trim_start();
        tail.is_empty() || (tail.starts_with('#') && tail.len() < rest.len())
    };
    if let Some(body) = raw.strip_prefix('\'') {
        let (value, rest) = body.split_once('\'')?;
        return comment_only(rest).then(|| value.to_owned());
    }
    if let Some(body) = raw.strip_prefix('"') {
        let (value, rest) = body.split_once('"')?;
        if !comment_only(rest) || value.contains(['\\', '`']) {
            return None;
        }
        return expand_home(value, home, false);
    }
    let (word, rest) = raw.split_at(raw.find(char::is_whitespace).unwrap_or(raw.len()));
    if word.is_empty() {
        return comment_only(rest).then(String::new);
    }
    if !comment_only(rest) || word.contains(['#', '\\', '\'', '"', '`']) {
        return None;
    }
    expand_home(word, home, true)
}

/// `text` with `$HOME` and `${HOME}` read as `home`, and where `tilde` (a
/// bare word) a `~` at its start or after a `:`, before a `/`, a `:` or its
/// end. `None` is any other `$` or `~` form, or one of these with no home.
fn expand_home(text: &str, home: Option<&str>, tilde: bool) -> Option<String> {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    let mut at_start = true;
    while let Some(c) = rest.chars().next() {
        let after = &rest[c.len_utf8()..];
        let tail = match c {
            '$' => after.strip_prefix("{HOME}").or_else(|| {
                after
                    .strip_prefix("HOME")
                    .filter(|t| !t.starts_with(|n: char| n.is_ascii_alphanumeric() || n == '_'))
            }),
            '~' if tilde && at_start => {
                Some(after).filter(|t| t.is_empty() || t.starts_with(['/', ':']))
            }
            _ => {
                out.push(c);
                at_start = tilde && c == ':';
                rest = after;
                continue;
            }
        };
        rest = tail?;
        out.push_str(home?);
        at_start = false;
    }
    Some(out)
}

/// The private env file's assignments this runtime reads, in file order,
/// and the keys whose line it passed over.
pub(crate) struct PrivateEnv {
    pub(crate) values: Vec<(String, String)>,
    pub(crate) passed_over: Vec<String>,
}

/// The assignments of the private env file this runtime reads, in file
/// order. A key's value is read as the sourcing shell assigns it, `home`
/// the shell's `HOME` until the file assigns one, and a form only a shell
/// reads is passed over, so a value only some verbs read never refuses
/// every verb; for a key of [`LOAD_KEYS`] such a form refuses the load. A
/// line that assigns nothing this runtime reads is the shell's alone.
pub(crate) fn private_env_file(path: &Path, home: Option<&str>) -> Result<PrivateEnv> {
    match read_text(path)? {
        Some(text) => private_env_text(path, home, &text),
        None => Ok(PrivateEnv {
            values: Vec::new(),
            passed_over: Vec::new(),
        }),
    }
}

/// [`private_env_file`] over the file's text; `path` names it in a refusal.
pub(crate) fn private_env_text(path: &Path, home: Option<&str>, text: &str) -> Result<PrivateEnv> {
    let mut env = PrivateEnv {
        values: Vec::new(),
        passed_over: Vec::new(),
    };
    let mut home = home.filter(|h| !h.is_empty()).map(str::to_owned);
    for raw in text.lines() {
        let line = raw.trim();
        let line = line
            .strip_prefix("export ")
            .map(str::trim_start)
            .unwrap_or(line);
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if !ACCOUNT_KEYS.contains(&key) && !READ_KEYS.contains(&key) {
            continue;
        }
        match decode_account_value(value, home.as_deref()) {
            Some(value) => {
                if key == HOME_KEY {
                    home = Some(value.clone()).filter(|h| !h.is_empty());
                }
                env.values.push((key.to_owned(), value));
            }
            None if LOAD_KEYS.contains(&key) => {
                return Err(file_refusal(path, key, "value-syntax"));
            }
            None => env.passed_over.push(key.to_owned()),
        }
    }
    Ok(env)
}

#[allow(
    clippy::disallowed_methods,
    reason = "the rows write the settings files they read"
)]
#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> Vec<(OsString, OsString)> {
        pairs
            .iter()
            .map(|(k, v)| (OsString::from(k), OsString::from(v)))
            .collect()
    }

    fn roots_in(dir: &Path) -> Roots {
        Roots {
            project: dir.join("tree"),
            common: dir.join("main"),
        }
    }

    const FLAGS: Flags = Flags {
        state_dir: None,
        private_env: true,
    };

    fn write(root: &Path, name: &str, text: &str) {
        let path = root.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    /// The ladder, one rung at a time: the flag, the caller's
    /// environment, the private file, `.kendex/settings.toml`,
    /// `kendex.settings.toml`, then `tmp`, a relative value resolved on the
    /// main checkout and an absolute one kept.
    #[test]
    fn the_state_directory_follows_the_flag_environment_and_file_ladder() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let tree = &roots.project;
        let common = &roots.common;
        let load_with = |flags: &Flags, environment: &[(&str, &str)]| {
            load(&roots, &env(environment), flags).unwrap().state_dir
        };
        assert_eq!(load_with(&FLAGS, &[]), common.join("tmp"), "the default");
        write(
            tree,
            "kendex.settings.toml",
            "[env]\nORCH_STATE_DIR = \"state-a\"\n",
        );
        assert_eq!(load_with(&FLAGS, &[]), common.join("state-a"));
        write(
            tree,
            ".kendex/settings.toml",
            "[env]\nORCH_STATE_DIR = 'state-b'\n",
        );
        assert_eq!(
            load_with(&FLAGS, &[]),
            common.join("state-b"),
            "the later file outranks"
        );
        write(tree, ".env.local", "export ORCH_STATE_DIR='state-c'\n");
        assert_eq!(load_with(&FLAGS, &[]), common.join("state-c"));
        let no_private = Flags {
            state_dir: None,
            private_env: false,
        };
        assert_eq!(
            load_with(&no_private, &[]),
            common.join("state-b"),
            "--no-private-env skips the private file"
        );
        assert_eq!(
            load_with(&FLAGS, &[("ORCH_STATE_DIR", "/abs/state")]),
            PathBuf::from("/abs/state"),
            "the caller's environment outranks every file"
        );
        assert_eq!(
            load_with(&FLAGS, &[("ORCH_STATE_DIR", "")]),
            common.join("tmp"),
            "an empty caller value shadows the files and reads as the default"
        );
        let flagged = Flags {
            state_dir: Some(PathBuf::from("flagged")),
            private_env: true,
        };
        assert_eq!(
            load_with(&flagged, &[("ORCH_STATE_DIR", "/abs/state")]),
            common.join("flagged"),
            "the flag outranks the environment"
        );
        let empty_flag = Flags {
            state_dir: Some(PathBuf::new()),
            private_env: true,
        };
        assert_eq!(
            load(&roots, &env(&[]), &empty_flag).unwrap_err().key(),
            "state-dir-value"
        );
    }

    /// Under `--no-private-env` the files give `ORCH_STATE_DIR`
    /// alone, outranking the caller's environment, and no other file key is
    /// read; every other key comes from the environment.
    #[test]
    fn no_private_env_takes_only_the_state_dir_from_the_files() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        write(
            &roots.project,
            "kendex.settings.toml",
            "[env]\nORCH_STATE_DIR = \"from-file\"\nORCH_TMUX_SESSION = \"file-session\"\n",
        );
        let no_private = Flags {
            state_dir: None,
            private_env: false,
        };
        let settings = load(
            &roots,
            &env(&[
                ("ORCH_STATE_DIR", "from-env"),
                ("ORCH_TMUX_SESSION", "env-session"),
            ]),
            &no_private,
        )
        .unwrap();
        assert_eq!(
            settings.state_dir,
            roots.common.join("from-file"),
            "the file's state directory outranks the environment"
        );
        assert_eq!(
            settings.tmux_session.as_deref(),
            Some("env-session"),
            "every other key is the environment's, never the file's"
        );
        // With no caller value, the file's state directory still resolves and
        // no other file key leaks in.
        let settings = load(&roots, &env(&[]), &no_private).unwrap();
        assert_eq!(settings.state_dir, roots.common.join("from-file"));
        assert_eq!(settings.tmux_session, None);
    }

    #[test]
    fn a_named_private_file_is_read_and_an_outside_name_refused() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        write(
            &roots.project,
            "kendex.settings.toml",
            "[env]\nKENDEX_ENV_FILE = \"config/private.env\"\n",
        );
        write(
            &roots.project,
            "config/private.env",
            "# a comment\nOTHER=$(uname)\nORCH_TMUX_SESSION=fleet\n",
        );
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(settings.tmux_session.as_deref(), Some("fleet"));
        for bad in ["/etc/env", "../x", "a/../b", "c:d", "a\\b"] {
            let err = load(&roots, &env(&[("KENDEX_ENV_FILE", bad)]), &FLAGS).unwrap_err();
            assert_eq!(err.key(), "private-env-path", "{bad}");
        }
    }

    /// Each settings source the shell loader refuses before it reads one,
    /// refused here by the same word, with no read of a FIFO; and the
    /// private file's directory held inside the project, a link at the file
    /// itself admitted. Run as root, a closed file or directory is open, so
    /// those two cases are not asked.
    #[test]
    fn a_settings_source_is_judged_before_it_is_read() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
        let outside = tempfile::tempdir().unwrap();
        write(outside.path(), "priv.env", "ORCH_TMUX_SESSION=outside\n");
        let as_root = fs::metadata(outside.path()).unwrap().uid() == 0;
        let settings = |project: &Path| project.join("kendex.settings.toml");
        let mode = |path: &Path, mode: u32| {
            fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
        };
        type Plant<'a> = Box<dyn Fn(&Path) + 'a>;
        type Case<'a> = (&'a str, Plant<'a>, Option<&'a str>, (&'a str, &'a str));
        let cases: Vec<Case> = vec![
            (
                "a dangling link",
                Box::new(|p| symlink(p.join("nowhere"), settings(p)).unwrap()),
                None,
                ("settings-invalid", "unresolved-link"),
            ),
            (
                "a link to itself",
                Box::new(|p| symlink(settings(p), settings(p)).unwrap()),
                None,
                ("settings-invalid", "unresolved-link"),
            ),
            (
                "a directory",
                Box::new(|p| fs::create_dir(settings(p)).unwrap()),
                None,
                ("settings-invalid", "not-file"),
            ),
            (
                "a FIFO",
                Box::new(|p| {
                    let made = std::process::Command::new("mkfifo")
                        .arg(settings(p))
                        .status()
                        .unwrap();
                    assert!(made.success());
                }),
                None,
                ("settings-invalid", "not-file"),
            ),
            (
                "an unreadable file",
                Box::new(|p| {
                    write(p, "kendex.settings.toml", "[env]\n");
                    mode(&settings(p), 0o000);
                }),
                None,
                ("settings-invalid", "unreadable"),
            ),
            (
                "a file where `.kendex` names a directory",
                Box::new(|p| write(p, ".kendex", "")),
                None,
                ("loaded", ""),
            ),
            (
                "a file on the private file's path",
                Box::new(|p| write(p, "conf", "")),
                Some("conf/priv.env"),
                ("private-env-blocked", ""),
            ),
            (
                "a directory link out of the project",
                Box::new(|p| symlink(outside.path(), p.join("conf")).unwrap()),
                Some("conf/priv.env"),
                ("private-env-outside", ""),
            ),
            (
                "a directory this process cannot enter",
                Box::new(|p| {
                    fs::create_dir(p.join("locked")).unwrap();
                    mode(&p.join("locked"), 0o000);
                }),
                Some("locked/priv.env"),
                ("private-env-unresolved", ""),
            ),
            (
                "the file itself a link out",
                Box::new(|p| {
                    symlink(outside.path().join("priv.env"), p.join(".env.local")).unwrap()
                }),
                None,
                ("loaded", "outside"),
            ),
            (
                "directories not yet made",
                Box::new(|_| {}),
                Some("a/b/priv.env"),
                ("loaded", ""),
            ),
        ];
        for (case, plant, named, want) in cases {
            if as_root && (case.contains("unreadable") || case.contains("cannot enter")) {
                continue;
            }
            let dir = tempfile::tempdir().unwrap();
            let roots = roots_in(dir.path());
            fs::create_dir_all(&roots.project).unwrap();
            plant(&roots.project);
            let caller: Vec<(&str, &str)> =
                named.map(|n| ("KENDEX_ENV_FILE", n)).into_iter().collect();
            let got = match load(&roots, &env(&caller), &FLAGS) {
                Ok(loaded) => ("loaded".to_owned(), loaded.tmux_session.unwrap_or_default()),
                Err(e) => {
                    let reason = e
                        .fields()
                        .into_iter()
                        .find_map(|(key, value)| (key == "reason").then_some(value))
                        .unwrap_or_default();
                    (e.key().to_owned(), reason)
                }
            };
            for closed in [settings(&roots.project), roots.project.join("locked")] {
                if fs::symlink_metadata(&closed).is_ok_and(|m| !m.file_type().is_symlink()) {
                    mode(&closed, 0o700);
                }
            }
            assert_eq!((got.0.as_str(), got.1.as_str()), want, "{case}");
        }
    }

    /// The file grammar the shell loader refuses, refused here by the same
    /// reason word; and the shapes it admits, decoded to the same bytes.
    #[test]
    fn settings_files_follow_the_env_table_contract() {
        let refused: [(&str, &str); 5] = [
            (
                "\u{feff}[env]\nORCH_TMUX_SESSION = \"a\"\n",
                "byte-order-mark",
            ),
            ("[env] # c\nORCH_TMUX_SESSION = \"a\"\n", "table-header"),
            (
                "[env]\nORCH_TMUX_SESSION = \"a\"\nORCH_TMUX_SESSION = \"b\"\n",
                "duplicate-key",
            ),
            ("[env]\nORCH_TMUX_SESSION = \"a\\b\"\n", "value-syntax"),
            ("[env]\nORCH_TMUX_SESSION = bare\n", "value-syntax"),
        ];
        for (text, reason) in refused {
            let dir = tempfile::tempdir().unwrap();
            let roots = roots_in(dir.path());
            write(&roots.project, "kendex.settings.toml", text);
            let err = load(&roots, &env(&[]), &FLAGS).unwrap_err();
            assert_eq!(err.key(), "settings-invalid", "{text:?}");
            assert_eq!(
                err.fields()[2],
                ("reason".into(), reason.into()),
                "{text:?}"
            );
        }
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        write(
            &roots.project,
            "kendex.settings.toml",
            "[other]\nORCH_TMUX_SESSION = \"not-env\"\n[env]\n  ORCH_TMUX_SESSION = 'lit' # x\nORCH_TMUX_VERIFY_SECS=\"3\"   # trailing\nnot a key = \"skipped\"\n[tail]\nORCH_LANE_CLOSE_SECS = \"9\"\n",
        );
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(settings.tmux_session.as_deref(), Some("lit"));
        assert_eq!(settings.verify.get().unwrap(), Duration::from_secs(3));
        assert_eq!(settings.close_grace.get().unwrap(), Duration::from_secs(15));
    }

    /// A key's value reads as the sourcing shell assigns it, `$HOME` as the
    /// home; a form only a shell reads is passed over, the load and every
    /// other key read as before; the state directory's refuses the load; an
    /// empty value blanks the key over a settings file's value, as the
    /// sourced file did.
    #[test]
    fn a_private_file_line_this_runtime_reads_must_decode_as_data() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        write(
            &roots.project,
            ".env.local",
            "ORCH_TMUX_SESSION=a $b\nSOMETHING_ELSE=$(date)\nfunction f() { :; }\nORCH_TMUX_VERIFY_SECS=7\n",
        );
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(settings.tmux_session, None);
        assert_eq!(settings.verify.get().unwrap(), Duration::from_secs(7));
        write(&roots.project, ".env.local", "ORCH_STATE_DIR=a $b\n");
        let err = load(&roots, &env(&[]), &FLAGS).unwrap_err();
        assert_eq!(err.key(), "settings-invalid");
        assert_eq!(err.fields()[1], ("key".into(), STATE_DIR_KEY.into()));
        write(
            &roots.project,
            ".env.local",
            "ORCH_TMUX_SESSION=plain\nexport ORCH_TMUX_VERIFY_SECS=\"4\"\nORCH_LANE_CLOSE_SECS='5'\n",
        );
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(settings.tmux_session.as_deref(), Some("plain"));
        assert_eq!(settings.verify.get().unwrap(), Duration::from_secs(4));
        assert_eq!(settings.close_grace.get().unwrap(), Duration::from_secs(5));
        write(
            &roots.project,
            ".env.local",
            "ORCH_TMUX_SESSION=\"$HOME/s\"\nORCH_LANE_DIRS=$(pwd)\nCODEX_HOME=~/c\n",
        );
        for (home, session, codex_home) in
            [(Some("/h"), Some("/h/s"), Some("/h/c")), (None, None, None)]
        {
            let caller: Vec<(&str, &str)> = home.map(|h| ("HOME", h)).into_iter().collect();
            let settings = load(&roots, &env(&caller), &FLAGS).unwrap();
            assert_eq!(settings.tmux_session.as_deref(), session, "{home:?}");
            assert!(
                settings.accounts.get().unwrap().lane_dirs.is_empty(),
                "{home:?}"
            );
            assert_eq!(
                settings.accounts.get().unwrap().codex_home.as_deref(),
                codex_home,
                "{home:?}"
            );
        }
        write(
            &roots.project,
            "kendex.settings.toml",
            "[env]\nORCH_LANE_EXCLUDE = \"lane-x\"\n",
        );
        for (text, exclude) in [
            ("", vec!["lane-x"]),
            ("ORCH_LANE_EXCLUDE=\n", vec![]),
            ("export ORCH_LANE_EXCLUDE=\n", vec![]),
            ("ORCH_LANE_EXCLUDE= # cleared\n", vec![]),
        ] {
            write(&roots.project, ".env.local", text);
            let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
            assert_eq!(
                settings.accounts.get().unwrap().exclude,
                exclude,
                "{text:?}"
            );
        }
    }

    /// Each typed key: its default, its words and what it refuses.
    #[test]
    fn typed_keys_take_their_words_and_refuse_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(settings.permission.get().unwrap(), Permission::Bypass);
        assert_eq!(
            settings.question_tool.get().unwrap(),
            QuestionToolSetting::Off
        );
        assert_eq!(settings.verify.get().unwrap(), Duration::from_secs(15));
        assert_eq!(settings.close_grace.get().unwrap(), Duration::from_secs(15));
        assert_eq!(settings.claim.get().unwrap(), Duration::from_secs(15));
        assert_eq!(
            settings.watch.get().unwrap(),
            WatchSettings {
                mail_interval: Duration::from_secs(20),
                mark_repeat: 5,
                dead_passes: 2,
                tail_lines: 12,
                prepare: Duration::from_secs(1800),
                directive_unread: Duration::from_secs(300),
                start_stall: Duration::from_secs(600),
                lane_stall: Duration::from_secs(3600),
                cloud_stall: Duration::from_secs(1800),
                lane_age: Duration::from_secs(12600),
                wall_relaunch: WallRelaunch::Auto,
                main_workflows: Vec::new(),
                security_alerts: Audit::On,
                external_triage: Audit::On,
            },
            "the watch's documented defaults"
        );
        assert_eq!(settings.linear_team, None);
        assert!(settings.harness_binaries.get().unwrap().is_empty());
        assert_eq!(
            settings.worktree_cli,
            roots.project.join(WORKTREE_CLI_DEFAULT)
        );
        assert_eq!(
            settings.agent_runtime,
            roots.project.join(AGENT_RUNTIME_DEFAULT)
        );
        assert_eq!(settings.succession.get().unwrap(), Succession::On);
        assert_eq!(settings.job_unit, roots.project.join(JOB_UNIT_DEFAULT));
        assert_eq!(settings.lane_cap.get().unwrap(), 4);
        assert_eq!(settings.cloud_lane_cap.get().unwrap(), 10);
        assert_eq!(settings.claim_store, roots.common.join(CLAIM_STORE_DEFAULT));
        assert_eq!(
            settings.lane_mail_cli,
            roots.project.join(LANE_MAIL_CLI_DEFAULT)
        );
        assert_eq!(
            settings.dev_validate_cli,
            roots.project.join(DEV_VALIDATE_CLI_DEFAULT)
        );
        assert_eq!(
            settings.scope_paths_cli,
            roots.project.join(SCOPE_PATHS_CLI_DEFAULT)
        );
        let settings = load(
            &roots,
            &env(&[
                (LAUNCH_PERMISSION_KEY, "native"),
                (QUESTION_TOOL_KEY, "overseer"),
                (
                    HARNESS_BINARIES_KEY,
                    "claude=/opt/claude/claude, pi=/opt/pi",
                ),
                (WORKTREE_CLI_KEY, "/opt/worktree"),
                (SUCCESSION_KEY, "off"),
                (JOB_UNIT_KEY, "/opt/job-unit.sh"),
                (LANE_CAP_KEY, "7"),
                (CLOUD_LANE_CAP_KEY, "2"),
                (CLAIM_STATE_DIR_KEY, "/var/watch"),
                (LANE_MAIL_CLI_KEY, "/opt/lane-mail"),
                (DEV_VALIDATE_CLI_KEY, "/opt/dev-validate-run"),
                (SCOPE_PATHS_CLI_KEY, "/opt/harness-only"),
                (JOB_CLAIM_SECS_KEY, "40"),
                (WATCH_MAIL_INTERVAL_KEY, "5"),
                (OVERSEER_MARK_REPEAT_KEY, "3"),
                (OVERSEER_DEAD_PASSES_KEY, "1"),
                (WATCH_TAIL_LINES_KEY, "20"),
                (WATCH_PREPARE_SECS_KEY, "60"),
                (DIRECTIVE_UNREAD_SECS_KEY, "30"),
                (WATCH_START_STALL_SECS_KEY, "90"),
                (WATCH_LANE_STALL_SECS_KEY, "120"),
                (CLOUD_STALL_MINUTES_KEY, "2"),
                (WATCH_LANE_AGE_SECS_KEY, "600"),
                (WALL_RELAUNCH_KEY, "ask"),
                (MAIN_WORKFLOWS_KEY, "Owner/Repo:ci.yml  other/one:x.yaml"),
                (SECURITY_ALERTS_KEY, "off"),
                (EXTERNAL_TRIAGE_KEY, "off"),
                (LINEAR_TEAM_KEY, "KEN"),
            ]),
            &FLAGS,
        )
        .unwrap();
        assert_eq!(settings.claim.get().unwrap(), Duration::from_secs(40));
        assert_eq!(settings.linear_team.as_deref(), Some("KEN"));
        assert_eq!(
            settings.watch.get().unwrap(),
            WatchSettings {
                mail_interval: Duration::from_secs(5),
                mark_repeat: 3,
                dead_passes: 1,
                tail_lines: 20,
                prepare: Duration::from_secs(60),
                directive_unread: Duration::from_secs(30),
                start_stall: Duration::from_secs(90),
                lane_stall: Duration::from_secs(120),
                cloud_stall: Duration::from_secs(120),
                lane_age: Duration::from_secs(600),
                wall_relaunch: WallRelaunch::Ask,
                main_workflows: vec![
                    "owner/repo:ci.yml".to_owned(),
                    "other/one:x.yaml".to_owned()
                ],
                security_alerts: Audit::Off,
                external_triage: Audit::Off,
            }
        );
        assert_eq!(settings.succession.get().unwrap(), Succession::Off);
        assert_eq!(settings.job_unit, PathBuf::from("/opt/job-unit.sh"));
        assert_eq!(settings.lane_cap.get().unwrap(), 7);
        assert_eq!(settings.cloud_lane_cap.get().unwrap(), 2);
        assert_eq!(settings.claim_store, PathBuf::from("/var/watch/claims"));
        assert_eq!(settings.lane_mail_cli, PathBuf::from("/opt/lane-mail"));
        assert_eq!(
            settings.dev_validate_cli,
            PathBuf::from("/opt/dev-validate-run")
        );
        assert_eq!(settings.scope_paths_cli, PathBuf::from("/opt/harness-only"));
        // A relative claim directory is the project's, as the shell
        // launcher reads it from the checkout it runs in.
        let relative = load(&roots, &env(&[(CLAIM_STATE_DIR_KEY, "tmp/w")]), &FLAGS).unwrap();
        assert_eq!(relative.claim_store, roots.project.join("tmp/w/claims"));
        assert_eq!(settings.permission.get().unwrap(), Permission::Native);
        assert_eq!(
            settings.question_tool.get().unwrap(),
            QuestionToolSetting::Overseer
        );
        assert_eq!(
            settings.question_tool.get().unwrap().for_overseer(),
            QuestionTool::Keep
        );
        assert_eq!(
            settings.harness_binaries.get().unwrap(),
            BTreeMap::from([
                (Harness::Claude, PathBuf::from("/opt/claude/claude")),
                (Harness::Pi, PathBuf::from("/opt/pi")),
            ])
        );
        assert_eq!(settings.worktree_cli, PathBuf::from("/opt/worktree"));
        let refused = [
            (LAUNCH_PERMISSION_KEY, "yes"),
            (QUESTION_TOOL_KEY, "lane"),
            (VERIFY_SECS_KEY, "0"),
            (VERIFY_SECS_KEY, "07"),
            (VERIFY_SECS_KEY, "1.5"),
            (CLOSE_SECS_KEY, "-1"),
            (HARNESS_BINARIES_KEY, "claude=bin/claude"),
            (HARNESS_BINARIES_KEY, "opencode=/opt/oc"),
            (HARNESS_BINARIES_KEY, "claude=/a,claude=/b"),
            (HARNESS_BINARIES_KEY, "claude"),
            (SUCCESSION_KEY, "maybe"),
            (LANE_CAP_KEY, "0"),
            (LANE_CAP_KEY, "03"),
            (LANE_CAP_KEY, "+4"),
            (LANE_CAP_KEY, "four"),
            (JOB_CLAIM_SECS_KEY, "0"),
            (WATCH_MAIL_INTERVAL_KEY, "x"),
            (WATCH_MAIL_INTERVAL_KEY, "01"),
            (WATCH_MAIL_INTERVAL_KEY, "-1"),
            (OVERSEER_MARK_REPEAT_KEY, "0"),
            (OVERSEER_DEAD_PASSES_KEY, "0"),
            (OVERSEER_DEAD_PASSES_KEY, "00"),
            (OVERSEER_DEAD_PASSES_KEY, "+1"),
            (OVERSEER_DEAD_PASSES_KEY, "two"),
            (DIRECTIVE_UNREAD_SECS_KEY, "01"),
            (DIRECTIVE_UNREAD_SECS_KEY, "5s"),
            (WATCH_TAIL_LINES_KEY, "-1"),
            (WATCH_PREPARE_SECS_KEY, "1m"),
            (CLOUD_STALL_MINUTES_KEY, "0"),
            (WALL_RELAUNCH_KEY, "maybe"),
            (MAIN_WORKFLOWS_KEY, "owner/repo"),
            (MAIN_WORKFLOWS_KEY, "repo:ci.yml"),
            (MAIN_WORKFLOWS_KEY, "owner/repo:ci.txt"),
            (SECURITY_ALERTS_KEY, "yes"),
            (EXTERNAL_TRIAGE_KEY, "1"),
            (RECORD_RETENTION_DAYS_KEY, "0"),
            (RECORD_RETENTION_DAYS_KEY, "05"),
            (RECORD_RETENTION_DAYS_KEY, "5d"),
            (OVERSEER_WALL_MINUTES_KEY, "1234567890"),
            (OVERSEER_WALL_MINUTES_KEY, "-5"),
            (OVERSEER_MEMORY_PCT_KEY, "101"),
            (HANDOFF_CONTEXT_PCT_KEY, "0"),
            (HANDOFF_CONTEXT_PCT_KEY, "1000"),
            (QUEUE_WAIT_ARM_GRACE_KEY, "0"),
            (QUEUE_WAIT_CONFIRM_POLLS_KEY, "02"),
            (QUEUE_WAIT_PROBE_INTERVAL_KEY, "x"),
            (TAKEOVER_ROWS_KEY, "x"),
            (FLEET_LOG_ROW_BYTES_KEY, "-1"),
            (REVIEW_MAX_CYCLES_KEY, "1.5"),
            (REVIEW_MAX_EXTERNAL_ROUNDS_KEY, "two"),
            (CI_FIX_MAX_CYCLES_KEY, "+6"),
            (LANE_RETIRE_KEY, "/a/b=2027-01-01"),
            (LANE_RETIRE_KEY, "a=2027-02-30"),
            (LANE_CLOUD_REPOS_KEY, "a=repo"),
            (LANE_COPILOT_POOL_KEY, "/p=1/0"),
            (LANE_EXCLUDE_KEY, "~/x"),
            (LANE_MAX_PCT_KEY, "101"),
            (LANE_BURN_PCT_KEY, "five"),
            (OVERSEER_HEADROOM_PCT_KEY, "-1"),
            (CODEX_CREDIT_FLOOR_KEY, "1.5"),
            (CLOUD_CREDIT_FLOOR_KEY, "x"),
            (USAGE_TTL_KEY, "5m"),
            (USAGE_MAX_AGE_KEY, "+1"),
            (HOST_ACCOUNTS_TIMEOUT_KEY, "-30"),
            (LANE_OUTPUT_KEY, "verbose"),
        ];
        for (key, value) in refused {
            let settings = load(&roots, &env(&[(key, value)]), &FLAGS).unwrap();
            assert_eq!(
                refusals(&settings),
                vec![(key.to_owned(), value.to_owned())],
                "{key}={value}: refused by its own carrier alone"
            );
        }
    }

    /// Every carrier's refusal, as its key and refused value, in one list:
    /// a value outside its key's form refuses that key's carrier and no
    /// other.
    fn refusals(s: &Settings) -> Vec<(String, String)> {
        let judged = [
            s.verify.get().map(drop),
            s.close_grace.get().map(drop),
            s.claim.get().map(drop),
            s.watch.get().map(drop),
            s.question_tool.get().map(drop),
            s.permission.get().map(drop),
            s.harness_binaries.get().map(drop),
            s.succession.get().map(drop),
            s.marks.wall_minutes.get().map(drop),
            s.marks.memory_pct.get().map(drop),
            s.marks.context_pct.get().map(drop),
            s.lane_cap.get().map(drop),
            s.cloud_lane_cap.get().map(drop),
            s.retention_days.get().map(drop),
            s.queue_watch.arm_grace.get().map(drop),
            s.queue_watch.confirm_polls.get().map(drop),
            s.queue_watch.probe_interval.get().map(drop),
            s.store.takeover_rows.get().map(drop),
            s.store.fleet_log_row_bytes.get().map(drop),
            s.store.review_max_cycles.get().map(drop),
            s.store.review_max_external_rounds.get().map(drop),
            s.store.ci_fix_max_cycles.get().map(drop),
            s.accounts.get().map(drop),
            s.lane_output.get().map(drop),
        ];
        judged
            .into_iter()
            .filter_map(std::result::Result::err)
            .map(|e| {
                assert_eq!(e.key(), "setting-invalid");
                let fields = e.fields();
                (fields[0].1.clone(), fields[1].1.clone())
            })
            .collect()
    }

    /// The read duties' keys: each default and shape, and the owner tracker
    /// configured only by both its halves.
    #[test]
    fn the_read_duties_keys_take_their_defaults_and_shapes() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(
            settings.reads,
            ReadSettings {
                tracker_cli: roots.project.join(TRACKER_CLI_DEFAULT),
                pr_watch_cli: roots.project.join(PR_WATCH_CLI_DEFAULT),
                security_alert_token_file: None,
                connected_repos: Vec::new(),
                owner_tracker: None,
            }
        );
        let settings = load(
            &roots,
            &env(&[
                (TRACKER_CLI_KEY, "/opt/linear.sh"),
                (PR_WATCH_CLI_KEY, "/opt/pr-watch.sh"),
                (SECURITY_ALERT_TOKEN_FILE_KEY, "/run/token"),
                (CONNECTED_REPOS_KEY, " Owner/Repo\tother/one owner/repo "),
                (USER_EMAIL_KEY, "user@example.com"),
                (OWNER_ASK_LABEL_KEY, "owner-ask"),
            ]),
            &FLAGS,
        )
        .unwrap();
        assert_eq!(
            settings.reads,
            ReadSettings {
                tracker_cli: PathBuf::from("/opt/linear.sh"),
                pr_watch_cli: PathBuf::from("/opt/pr-watch.sh"),
                security_alert_token_file: Some(PathBuf::from("/run/token")),
                connected_repos: vec!["owner/repo".to_owned(), "other/one".to_owned()],
                owner_tracker: Some(OwnerTracker {
                    email: "user@example.com".to_owned(),
                    label: "owner-ask".to_owned(),
                }),
            }
        );
        // The owner's own key outranks the user email; a label alone or an
        // email alone configures nothing.
        let both = load(
            &roots,
            &env(&[
                (OWNER_EMAIL_KEY, "owner@example.com"),
                (USER_EMAIL_KEY, "user@example.com"),
                (OWNER_ASK_LABEL_KEY, "owner-ask"),
            ]),
            &FLAGS,
        )
        .unwrap();
        assert_eq!(
            both.reads.owner_tracker.map(|o| o.email),
            Some("owner@example.com".to_owned())
        );
        for half in [
            (OWNER_EMAIL_KEY, "owner@example.com"),
            (OWNER_ASK_LABEL_KEY, "l"),
        ] {
            let one = load(&roots, &env(&[half]), &FLAGS).unwrap();
            assert_eq!(one.reads.owner_tracker, None, "{half:?}");
        }
    }

    /// The three watch keys read through their own grammars, never the
    /// launcher keys' stricter parsers, which would refuse values the watch
    /// admits and so every runtime verb on a fleet that sets them. Each
    /// key's admitted edge reads as the watch reads it.
    #[test]
    fn the_watch_keys_admit_their_grammars_edges() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let settings = load(
            &roots,
            &env(&[
                (WATCH_MAIL_INTERVAL_KEY, "0"),
                (DIRECTIVE_UNREAD_SECS_KEY, "0"),
                (OVERSEER_DEAD_PASSES_KEY, "02"),
            ]),
            &FLAGS,
        )
        .unwrap();
        let watch = settings.watch.get().unwrap();
        assert_eq!(watch.mail_interval, Duration::ZERO);
        assert_eq!(watch.directive_unread, Duration::ZERO);
        assert_eq!(watch.dead_passes, 2);
    }

    /// A mistyped retention never reads as the default, nor a count of
    /// none, which keeps nothing a day; the account program is read from its
    /// own key alone. A set value is taken as given,
    /// and a value outside `[1-9][0-9]*` is refused by key and value.
    #[test]
    fn the_retention_and_lanes_keys_take_their_defaults_and_refuse_by_key_and_value() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(settings.retention_days.get().unwrap(), 5);
        assert_eq!(settings.lanes_cli, roots.project.join(LANES_CLI_DEFAULT));
        let settings = load(
            &roots,
            &env(&[
                (RECORD_RETENTION_DAYS_KEY, "12"),
                (LANES_CLI_KEY, "/opt/lanes"),
            ]),
            &FLAGS,
        )
        .unwrap();
        assert_eq!(settings.retention_days.get().unwrap(), 12);
        assert_eq!(settings.lanes_cli, PathBuf::from("/opt/lanes"));
        for value in ["0", "05", "x", "-1", "5d", "+5"] {
            let settings = load(&roots, &env(&[(RECORD_RETENTION_DAYS_KEY, value)]), &FLAGS);
            assert_eq!(
                refusals(&settings.unwrap()),
                vec![(RECORD_RETENTION_DAYS_KEY.to_owned(), value.to_owned())],
                "{value:?}"
            );
        }
    }

    /// An archive root read as a bare relative path would land the
    /// archive under whatever directory the duty runs in, and a `~` taken
    /// literally would make a directory named `~`; a default that ignored
    /// the fleet directory would archive beside the wrong fleet. A set value is an
    /// absolute path or held as given for the archive's write to refuse;
    /// the default follows `FLEET_DIR`, else the home.
    #[test]
    fn the_archive_root_is_absolute_or_refused_and_defaults_under_the_fleet_directory() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let settings = load(&roots, &env(&[("HOME", "/home/o")]), &FLAGS).unwrap();
        assert_eq!(
            settings.archive_root,
            ArchiveRoot::Default(PathBuf::from("/home/o/.fleet/archive"))
        );
        let settings = load(
            &roots,
            &env(&[("HOME", "/home/o"), (FLEET_DIR_KEY, "/fleet")]),
            &FLAGS,
        )
        .unwrap();
        assert_eq!(
            settings.archive_root,
            ArchiveRoot::Default(PathBuf::from("/fleet/archive"))
        );
        let settings = load(
            &roots,
            &env(&[(FLEET_DIR_KEY, "/fleet"), (ARCHIVE_ROOT_KEY, "/archives")]),
            &FLAGS,
        )
        .unwrap();
        assert_eq!(
            settings.archive_root,
            ArchiveRoot::Configured(PathBuf::from("/archives"))
        );
        for value in ["archives", "~/archives", "./x"] {
            let settings = load(&roots, &env(&[(ARCHIVE_ROOT_KEY, value)]), &FLAGS).unwrap();
            assert_eq!(
                settings.archive_root,
                ArchiveRoot::Invalid(value.into()),
                "{value:?}"
            );
        }
    }

    /// A private-file line of a key the state verbs or the archive read is
    /// read as the sourcing loader read it, so a fleet that sets one there
    /// keeps its value: a path, a count and a cap each take the line, the
    /// caller's environment over it, and the default with no line.
    #[test]
    fn the_state_and_archive_keys_private_lines_are_read_as_the_sourced_file_read_them() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let read = |caller: &[(&str, &str)]| {
            let s = load(&roots, &env(caller), &FLAGS).unwrap();
            (
                s.archive_root,
                s.store.takeover_rows.get().unwrap(),
                s.store.review_max_cycles.get().unwrap(),
            )
        };
        let home = ("HOME", "/h");
        assert_eq!(
            read(&[home]),
            (
                ArchiveRoot::Default(PathBuf::from("/h/.fleet/archive")),
                DEFAULT_TAKEOVER_ROWS,
                DEFAULT_REVIEW_MAX_CYCLES
            ),
            "no line: the defaults"
        );
        write(
            &roots.project,
            ".env.local",
            "ORCH_ARCHIVE_ROOT=$HOME/archives\nexport ORCH_TAKEOVER_ROWS=25\nREVIEW_MAX_CYCLES='0'\n",
        );
        assert_eq!(
            read(&[home]),
            (ArchiveRoot::Configured(PathBuf::from("/h/archives")), 25, 0),
            "the private file's lines"
        );
        assert_eq!(
            read(&[home, (TAKEOVER_ROWS_KEY, "3")]).1,
            3,
            "the caller's environment over the line"
        );
    }

    /// A key only some verbs read never refuses the load, so one verb's bad
    /// value cannot refuse every verb and the watch: neither its private
    /// env file line in a form only a shell reads nor a value outside its
    /// form in the caller's environment. The keys are the private reader's
    /// own lists, every key the load reads; [`LOAD_KEYS`] are the load's own.
    #[test]
    fn a_key_only_some_verbs_read_never_refuses_the_settings_load() {
        let mut refused = Vec::new();
        for &key in READ_KEYS
            .iter()
            .chain(ACCOUNT_KEYS)
            .filter(|key| !LOAD_KEYS.contains(key))
        {
            let dir = tempfile::tempdir().unwrap();
            let roots = roots_in(dir.path());
            write(&roots.project, ".env.local", &format!("{key}=$(command)\n"));
            if let Err(e) = load(&roots, &env(&[]), &FLAGS) {
                refused.push(format!("{key} private file: {}", e.key()));
            }
            let dir = tempfile::tempdir().unwrap();
            let roots = roots_in(dir.path());
            if let Err(e) = load(&roots, &env(&[(key, "not a value\n")]), &FLAGS) {
                refused.push(format!("{key} environment: {}", e.key()));
            }
        }
        assert!(refused.is_empty(), "{refused:#?}");
    }

    /// A shell-form line of a key the load does not judge is passed over and
    /// named, never read as a value; the state directory's still refuses.
    #[test]
    fn a_shell_form_private_line_is_passed_over_unless_the_load_judges_its_key() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        write(
            &roots.project,
            ".env.local",
            "GH_TOKEN=$(gh auth token)\nGH_HOST=github.example # enterprise\nGH_BOT_TOKEN=\n",
        );
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(settings.review.approval_unread, ["GH_TOKEN"]);
        assert_eq!(
            settings.review.approval_reader_env,
            [
                ("GH_BOT_TOKEN".to_owned(), String::new()),
                ("GH_HOST".to_owned(), "github.example".to_owned())
            ]
        );
        let settings = load(&roots, &env(&[("GH_TOKEN", "ghs_caller")]), &FLAGS).unwrap();
        assert!(
            settings.review.approval_unread.is_empty(),
            "the caller's value stands"
        );
        write(
            &roots.project,
            ".env.local",
            "ORCH_STATE_DIR=$(pwd)/state\n",
        );
        assert_eq!(
            load(&roots, &env(&[]), &FLAGS).unwrap_err().key(),
            "settings-invalid"
        );
    }

    /// The state directory's value reads as the shell loader read it in each
    /// source: the private file's `$HOME`, `${HOME}` and `~` as the home it
    /// sources under, a single-quoted value and a trailing comment as the
    /// shell assigns them; a settings file's and the caller's value as
    /// written, unexpanded; a form only a shell could evaluate refuses.
    #[test]
    fn the_state_directory_reads_its_home_forms_as_the_sourcing_shell_does() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let home = [("HOME", "/h")];
        for (line, state_dir) in [
            ("ORCH_STATE_DIR=$HOME/state\n", PathBuf::from("/h/state")),
            (
                "ORCH_STATE_DIR=\"${HOME}/state\"\n",
                PathBuf::from("/h/state"),
            ),
            (
                "export ORCH_STATE_DIR=~/state # mine\n",
                PathBuf::from("/h/state"),
            ),
            (
                "ORCH_STATE_DIR='$HOME/state'\n",
                roots.common.join("$HOME/state"),
            ),
        ] {
            write(&roots.project, ".env.local", line);
            let settings = load(&roots, &env(&home), &FLAGS).unwrap();
            assert_eq!(settings.state_dir, state_dir, "{line:?}");
        }
        for line in [
            "ORCH_STATE_DIR=$(pwd)/state\n",
            "ORCH_STATE_DIR=$OTHER/state\n",
        ] {
            write(&roots.project, ".env.local", line);
            assert_eq!(
                load(&roots, &env(&home), &FLAGS).unwrap_err().key(),
                "settings-invalid",
                "{line:?}"
            );
        }
        fs::remove_file(roots.project.join(".env.local")).unwrap();
        write(
            &roots.project,
            "kendex.settings.toml",
            "[env]\nORCH_STATE_DIR = \"$HOME/state\"\n",
        );
        let settings = load(&roots, &env(&home), &FLAGS).unwrap();
        assert_eq!(settings.state_dir, roots.common.join("$HOME/state"));
        let caller = [("HOME", "/h"), ("ORCH_STATE_DIR", "$HOME/state")];
        let settings = load(&roots, &env(&caller), &FLAGS).unwrap();
        assert_eq!(settings.state_dir, roots.common.join("$HOME/state"));
    }
}
