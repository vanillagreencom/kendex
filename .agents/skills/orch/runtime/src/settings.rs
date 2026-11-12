//! The runtime's settings: orch's keys, read over the one settings reader
//! (`agent_runtime::settings`, its ladder and its account and engine key
//! blocks), with the command line's state directory over every rung.
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::settings::{
    self as shared, AccountSettings, ControllerSettings, EngineSettings, FileRead, Judged, Keys,
    LaunchSettings, Roots,
};

use crate::archive::ArchiveRoot;
use crate::error::Result;

/// The folder the per-item state is kept in, relative to the main checkout
/// unless absolute; `tmp` when nothing names one.
pub const STATE_DIR_KEY: &str = "ORCH_STATE_DIR";
/// Seconds a stop waits after SIGTERM before SIGKILL.
pub const CLOSE_SECS_KEY: &str = "ORCH_LANE_CLOSE_SECS";
/// The worktree program that resolves a lane's directory; empty finds the
/// installed worktree package.
pub const WORKTREE_CLI_KEY: &str = "WORKTREE_CLI";
/// The worktree package's program under the project's install.
pub const WORKTREE_CLI_DEFAULT: &str = ".agents/skills/worktree/scripts/worktree";
/// The agent-runtime command the wake duty delivers through; empty finds
/// the installed agent-runtime package's own wrapper.
pub const AGENT_RUNTIME_KEY: &str = "ORCH_AGENT_RUNTIME";
/// The agent-runtime package's wrapper under the project's install.
pub const AGENT_RUNTIME_DEFAULT: &str = ".agents/skills/agent-runtime/scripts/agent-runtime";
/// The lanes the fleet cap admits at once: every lane kind but
/// `claude-cloud`, which the cloud cap bounds.
pub const LANE_CAP_KEY: &str = "ORCH_OVERSEER_LANES";
/// The Claude cloud sessions one overseer holds at once: the record's
/// declared `claude-cloud` kind owns this cap, whatever its host name.
pub const CLOUD_LANE_CAP_KEY: &str = "ORCH_OVERSEER_CLOUD_LANES";
/// The watch's state directory, which holds the claim store `<dir>/claims`
/// (`lib/lane-claims.sh`, `lane_claims_dir`) and the relaunch markers; the
/// main checkout's `tmp/oversee-watch` when unset.
pub const CLAIM_STATE_DIR_KEY: &str = "OVERSEE_WATCH_STATE_DIR";
/// The mailbox program a close asks for a lane's unanswered asks; empty
/// finds the installed mailbox package.
pub const LANE_MAIL_CLI_KEY: &str = "LANE_MAIL_CLI";
/// The mailbox package's program under the project's install.
pub const LANE_MAIL_CLI_DEFAULT: &str = ".agents/skills/mailbox/scripts/lane-mail";
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
/// The `harness[@host]:model:effort` entries a lane launch walks
/// (`lane walk`); unset, a launch takes the model it names.
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
/// The minutes to the account's wall, at the measured rate, the overseer
/// hands off at; 0 is no rate mark.
pub const OVERSEER_WALL_MINUTES_KEY: &str = "ORCH_OVERSEER_WALL_MINUTES";
/// The percent of its cgroup's memory cap the overseer's harness process
/// hands off at; unset is no memory mark.
pub const OVERSEER_MEMORY_PCT_KEY: &str = "ORCH_OVERSEER_MEMORY_PCT";
/// The share of the context window a reading is due strictly past, held
/// to the judge's ceiling.
pub const HANDOFF_CONTEXT_PCT_KEY: &str = "ORCH_HANDOFF_CONTEXT_PCT";
/// The tokens an attached launch keeps below the context mark for the
/// returns still to come.
pub const HANDOFF_AGENT_RESERVE_KEY: &str = "ORCH_HANDOFF_AGENT_RESERVE_TOKENS";
const DEFAULT_OVERSEER_WALL_MINUTES: u32 = 20;
const DEFAULT_HANDOFF_CONTEXT_PCT: u32 = 90;
// The provider's account keys.
/// `<name>=<owner>/<repo>` pairs: the repository each account was given
/// access to, which a `cloud-session` pick admits an account on.
pub const LANE_CLOUD_REPOS_KEY: &str = "ORCH_LANE_CLOUD_REPOS";
/// The lane host a pick runs under; `local` or unset is this machine's
/// own reading.
pub const LANE_HOST_KEY: &str = "ORCH_LANE_HOST";
/// A Copilot home the CLI reads, measured as the account it names and
/// never a candidate.
pub const COPILOT_HOME_KEY: &str = "COPILOT_HOME";
/// Pi's own root, where a Pi launch that names no account of Pi's runs.
pub const PI_ROOT_KEY: &str = "PI_CODING_AGENT_DIR";
/// Seconds the provider's `accounts` verb may take; 0 asks for no bound.
pub const HOST_ACCOUNTS_TIMEOUT_KEY: &str = "ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S";
/// The dispatcher's slot wait on that verb, passed on as it stands and
/// held under the bound.
pub const HOST_BUSY_WAIT_KEY: &str = "ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS";
const DEFAULT_HOST_ACCOUNTS_TIMEOUT: u64 = 30;

const DEFAULT_STATE_DIR: &str = "tmp";
const DEFAULT_CLOSE_SECS: u64 = 15;
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
    CLOSE_SECS_KEY,
    WORKTREE_CLI_KEY,
    AGENT_RUNTIME_KEY,
    LANE_CAP_KEY,
    CLOUD_LANE_CAP_KEY,
    CLAIM_STATE_DIR_KEY,
    LANE_MAIL_CLI_KEY,
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
    crate::policy::STAGES_KEY,
    ROUND_PRUNE_KEY,
    QA_KEYS[0],
    QA_KEYS[1],
    QA_KEYS[2],
    QA_KEYS[3],
    QA_KEYS[4],
    SCOPE_PATHS_CLI_KEY,
    WATCH_MAIL_INTERVAL_KEY,
    OVERSEER_MARK_REPEAT_KEY,
    OVERSEER_DEAD_PASSES_KEY,
    OVERSEER_WALL_MINUTES_KEY,
    OVERSEER_MEMORY_PCT_KEY,
    HANDOFF_CONTEXT_PCT_KEY,
    HANDOFF_AGENT_RESERVE_KEY,
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
    LANE_CLOUD_REPOS_KEY,
    LANE_HOST_KEY,
    COPILOT_HOME_KEY,
    PI_ROOT_KEY,
    HOST_ACCOUNTS_TIMEOUT_KEY,
    HOST_BUSY_WAIT_KEY,
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

/// Every key this runtime reads from the private env file: its own, the
/// account readers' and the engine's.
pub(crate) const KEYS: Keys = Keys {
    read: &[READ_KEYS, shared::ACCOUNT_KEYS, shared::ENGINE_KEYS],
    load: LOAD_KEYS,
};

/// What the command line says about the settings: a state directory that
/// outranks every file and key, and whether the private env file is read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Flags {
    pub state_dir: Option<PathBuf>,
    pub private_env: bool,
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

impl ReadSettings {
    /// The repositories the fleet watches: `named` first, then the
    /// connected ones, lowercased, once each, since GitHub reads a
    /// repository's name without case.
    pub fn watched<'a>(&self, named: impl IntoIterator<Item = &'a str>) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        let named = named.into_iter().map(str::to_ascii_lowercase);
        for repo in named.chain(self.connected_repos.iter().map(|r| r.to_ascii_lowercase())) {
            if !out.contains(&repo) {
                out.push(repo);
            }
        }
        out
    }
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

/// The provider's account keys: who reads the accounts, and the
/// repository access a cloud session is picked on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderSettings {
    /// The provider a pick runs under, `None` for this machine's own read.
    pub host: Option<String>,
    pub cloud_repos: Vec<CloudRepo>,
    pub accounts_timeout: u64,
    pub host_busy_wait: Option<String>,
}

/// One `ORCH_LANE_CLOUD_REPOS` entry, `<name>=<owner>/<repo>`: the
/// account whose alias or directory name is `name` has access to `repo`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudRepo {
    pub name: String,
    pub repo: String,
}

/// The settings the runtime acts on, resolved once per process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settings {
    pub roots: Roots,
    pub reads: ReadSettings,
    pub reconcile_stale_hours: String,
    pub reconcile_gh_cli: PathBuf,
    pub state_dir: PathBuf,
    pub engine: EngineSettings,
    /// The launch's posture, a lane's and a controller's.
    pub launch: LaunchSettings,
    /// The hand-over's question dialog, switch and successor preference.
    pub controller: ControllerSettings,
    pub close_grace: Judged<Duration>,
    pub watch: Judged<WatchSettings>,
    /// The tracker duties' team, which the report and the admission read too.
    pub linear_team: Option<String>,
    pub worktree_cli: PathBuf,
    pub agent_runtime: PathBuf,
    /// The controller's own marks.
    pub marks: MarkSettings,
    pub lane_cap: Judged<u32>,
    pub cloud_lane_cap: Judged<u32>,
    /// The claim store under the watch's state directory, whose parent its
    /// readers take.
    pub claim_store: PathBuf,
    pub lane_mail_cli: PathBuf,
    /// The mailbox and tmux server a watch's start named on its command
    /// line; `None` in every other process. `effects::fleet_reach` is its
    /// one reader.
    pub reach: Option<agent_runtime::effects::Reach>,
    pub apple_workflow: String,
    pub apple_labels: Vec<String>,
    pub validate: ValidateSettings,
    pub scope_paths_cli: PathBuf,
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
    pub accounts: Judged<AccountSettings>,
    pub provider: Judged<ProviderSettings>,
    /// The account records' root, the usage cache's and the wall records'.
    pub account_state: Judged<PathBuf>,
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

/// The setups every orch launch builds its directory's install through
/// before the window: orch's own, then the agent-runtime its scripts run,
/// the sibling they reach as `../../agent-runtime`.
const LAUNCH_SETUPS: &[&str] = &[
    ".agents/skills/orch/scripts/setup",
    ".agents/skills/orch/scripts/../../agent-runtime/scripts/setup",
];

impl Settings {
    /// What every orch launch's preparation is handed: the homes an
    /// accountless launch inherits, as this load read them, and orch's
    /// setups.
    pub fn inherited(&self) -> agent_runtime::effects::prepare::Inherited<'_> {
        agent_runtime::effects::prepare::Inherited {
            copilot_home: self.copilot_home.as_deref(),
            pi_root: self.pi_root.as_deref(),
            setups: LAUNCH_SETUPS,
        }
    }
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
    /// The attached-launch reserve as written, unset where empty: its one
    /// consumer, the attached-launch check, judges it.
    pub agent_reserve: Option<String>,
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

/// The state directory a checkout's own files name, as its `workflow-state`
/// resolves it with no caller environment: `ORCH_STATE_DIR` of its settings
/// files and private env file, `tmp` where none names one; a relative
/// directory is under the common root git names for the checkout.
pub fn state_dir_named(root: &Path, read: FileRead) -> Result<PathBuf> {
    let rung = shared::file_rung(root, read, Some((None, None)), false, &KEYS)?;
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
    let values = shared::layered(&roots.project, environment, flags.private_env, &KEYS)?;
    let passed_over = match &values.passed_over {
        Some((path, keys)) => {
            use std::io::Write as _;
            for key in keys {
                let _ = writeln!(
                    std::io::stderr(),
                    "settings-skipped path={} key={key} reason=shell-form",
                    path.display()
                );
            }
            keys.clone()
        }
        None => Vec::new(),
    };
    let get = |key: &str| values.get(key);

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
    let secs = |key: &'static str, default: u64| values.secs(key, default);
    // Zero, or digits with no leading zero: a wait of none is a documented
    // value (the mail read once a turn, a directive reported unread at once).
    let secs_or_none = |key: &'static str, default: u64| -> Judged<Duration> {
        match get(key) {
            Some("0") => Judged::of(key, Ok(Duration::ZERO)),
            None | Some(_) => secs(key, default),
        }
    };
    let worktree_cli = match get(WORKTREE_CLI_KEY) {
        Some(path) => PathBuf::from(path),
        None => roots.project.join(WORKTREE_CLI_DEFAULT),
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
        .filter_map(|key| values.raw(key).map(|v| (key.to_owned(), v.to_owned())))
        .collect();
    let pct = |key: &'static str, default: u32| values.pct(key, default);
    let whole = |key: &'static str, default: u64| values.whole(key, default);
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
        agent_reserve: get(HANDOFF_AGENT_RESERVE_KEY).map(str::to_owned),
    };
    // A cloud repository entry names an account and an `owner/repo` in
    // GitHub's own alphabet; one nobody can read is refused, never dropped,
    // since a dropped entry would hand a cloud session an account with no
    // access to the repository.
    let provider = Judged {
        read: (|| {
            let mut cloud_repos = Vec::new();
            if let Some(text) = get(LANE_CLOUD_REPOS_KEY) {
                for item in text.split(',').map(str::trim).filter(|i| !i.is_empty()) {
                    let valid = item.split_once('=').filter(|(name, repo)| {
                        shared::account_name_valid(name.trim())
                            && crate::verify::validate_repo(repo.trim()).is_ok()
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
            Ok(ProviderSettings {
                host: get(LANE_HOST_KEY)
                    .filter(|h| *h != "local")
                    .map(str::to_owned),
                cloud_repos,
                accounts_timeout: whole(HOST_ACCOUNTS_TIMEOUT_KEY, DEFAULT_HOST_ACCOUNTS_TIMEOUT)
                    .read?,
                host_busy_wait: get(HOST_BUSY_WAIT_KEY).map(str::to_owned),
            })
        })(),
    };
    // Every reader of the accounts reads them under the provider, so a
    // provider key outside its form refuses each of them as an account key
    // does.
    let accounts = Judged {
        read: AccountSettings::read(&values)
            .read
            .and_then(|accounts| provider.read.clone().map(|_| accounts)),
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
            .filter_map(|key| values.raw(key).map(|v| (key.to_owned(), v.to_owned())))
            .collect(),
        approval_unread: passed_over
            .iter()
            .filter(|key| APPROVAL_KEYS.contains(&key.as_str()) && values.raw(key).is_none())
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
        engine: EngineSettings::read(&values),
        launch: LaunchSettings::read(&values),
        controller: ControllerSettings::read(&values),
        close_grace: secs(CLOSE_SECS_KEY, DEFAULT_CLOSE_SECS),
        watch,
        linear_team: get(LINEAR_TEAM_KEY).map(str::to_owned),
        worktree_cli,
        agent_runtime,
        marks,
        lane_cap,
        cloud_lane_cap,
        claim_store,
        lane_mail_cli,
        reach: None,
        apple_workflow: values
            .raw("ORCH_APPLE_WORKFLOW")
            .unwrap_or(".github/workflows/mac-run.yml")
            .to_owned(),
        apple_labels: values
            .raw("ORCH_APPLE_LABELS")
            .unwrap_or("ios macos")
            .split_whitespace()
            .map(str::to_owned)
            .collect(),
        validate,
        scope_paths_cli,
        lane_preference,
        retention_days,
        queue_watch,
        archive_root,
        report,
        accounts,
        provider,
        account_state: shared::account_state_dir(&values),
        home: get(shared::HOME_KEY).map(str::to_owned),
        copilot_home: get(COPILOT_HOME_KEY).map(str::to_owned),
        pi_root: get(PI_ROOT_KEY).map(str::to_owned),
        lane_output: Judged::word(
            LANE_OUTPUT_KEY,
            get(LANE_OUTPUT_KEY),
            &[("quiet", LaneOutput::Quiet), ("normal", LaneOutput::Normal)],
        ),
    })
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

#[allow(
    clippy::disallowed_methods,
    reason = "the rows write the settings files they read"
)]
#[cfg(test)]
mod tests {
    use std::fs;

    use agent_runtime::Harness;
    use agent_runtime::launch::{Permission, QuestionTool};
    use agent_runtime::settings::{
        ACCOUNT_BURN_PCT_KEY, ACCOUNT_EXCLUDE_KEY, ACCOUNT_MAX_PCT_KEY, ACCOUNT_RETIRE_KEY,
        CLOUD_CREDIT_FLOOR_KEY, CODEX_CREDIT_FLOOR_KEY, CONTROLLER_HEADROOM_PCT_KEY,
        COPILOT_POOL_KEY, HARNESS_BINARIES_KEY, JOB_CLAIM_SECS_KEY, LAUNCH_PERMISSION_KEY,
        QUESTION_TOOL_KEY, QuestionToolSetting, SUCCESSION_KEY, Succession, USAGE_MAX_AGE_KEY,
        USAGE_TTL_KEY, VERIFY_SECS_KEY,
    };

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

    /// The state directory's own rules over the ladder: the default `tmp`
    /// and a relative value on the main checkout, an absolute one kept, the
    /// command line's directory over every rung, and an empty one refused.
    #[test]
    fn the_state_directory_resolves_on_the_main_checkout_under_the_flag() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let common = &roots.common;
        let load_with = |flags: &Flags, environment: &[(&str, &str)]| {
            load(&roots, &env(environment), flags).unwrap().state_dir
        };
        assert_eq!(load_with(&FLAGS, &[]), common.join("tmp"), "the default");
        write(
            &roots.project,
            "kendex.settings.toml",
            "[env]\nORCH_STATE_DIR = \"state-a\"\n",
        );
        assert_eq!(load_with(&FLAGS, &[]), common.join("state-a"));
        assert_eq!(
            load_with(&FLAGS, &[(STATE_DIR_KEY, "/abs/state")]),
            PathBuf::from("/abs/state")
        );
        let flagged = Flags {
            state_dir: Some(PathBuf::from("flagged")),
            private_env: true,
        };
        assert_eq!(
            load_with(&flagged, &[(STATE_DIR_KEY, "/abs/state")]),
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

    /// The approval reads its credential from the private file's lines: a
    /// key whose line only a shell reads is named unread, unless the
    /// caller's own value stands over it.
    #[test]
    fn an_approval_key_a_shell_form_line_hides_is_named_unless_the_caller_sets_it() {
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
    }

    /// Each typed key: its default, its words and what it refuses.
    #[test]
    fn typed_keys_take_their_words_and_refuse_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(
            settings.launch.permission.get().unwrap(),
            Permission::Bypass
        );
        assert_eq!(
            settings.controller.question_tool.get().unwrap(),
            QuestionToolSetting::Off
        );
        assert_eq!(
            settings.engine.verify.get().unwrap(),
            Duration::from_secs(15)
        );
        assert_eq!(settings.close_grace.get().unwrap(), Duration::from_secs(15));
        assert_eq!(
            settings.engine.claim.get().unwrap(),
            Duration::from_secs(15)
        );
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
        assert!(settings.engine.harness_binaries.get().unwrap().is_empty());
        assert_eq!(
            settings.worktree_cli,
            roots.project.join(WORKTREE_CLI_DEFAULT)
        );
        assert_eq!(
            settings.agent_runtime,
            roots.project.join(AGENT_RUNTIME_DEFAULT)
        );
        assert_eq!(
            settings.controller.succession.get().unwrap(),
            Succession::On
        );
        assert_eq!(settings.lane_cap.get().unwrap(), 4);
        assert_eq!(settings.cloud_lane_cap.get().unwrap(), 10);
        assert_eq!(settings.claim_store, roots.common.join(CLAIM_STORE_DEFAULT));
        assert_eq!(
            settings.lane_mail_cli,
            roots.project.join(LANE_MAIL_CLI_DEFAULT)
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
                (LANE_CAP_KEY, "7"),
                (CLOUD_LANE_CAP_KEY, "2"),
                (CLAIM_STATE_DIR_KEY, "/var/watch"),
                (LANE_MAIL_CLI_KEY, "/opt/lane-mail"),
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
        assert_eq!(
            settings.engine.claim.get().unwrap(),
            Duration::from_secs(40)
        );
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
        assert_eq!(
            settings.controller.succession.get().unwrap(),
            Succession::Off
        );
        assert_eq!(settings.lane_cap.get().unwrap(), 7);
        assert_eq!(settings.cloud_lane_cap.get().unwrap(), 2);
        assert_eq!(settings.claim_store, PathBuf::from("/var/watch/claims"));
        assert_eq!(settings.lane_mail_cli, PathBuf::from("/opt/lane-mail"));
        assert_eq!(settings.scope_paths_cli, PathBuf::from("/opt/harness-only"));
        // A relative claim directory is the project's, as the shell
        // launcher reads it from the checkout it runs in.
        let relative = load(&roots, &env(&[(CLAIM_STATE_DIR_KEY, "tmp/w")]), &FLAGS).unwrap();
        assert_eq!(relative.claim_store, roots.project.join("tmp/w/claims"));
        assert_eq!(
            settings.launch.permission.get().unwrap(),
            Permission::Native
        );
        assert_eq!(
            settings.controller.question_tool.get().unwrap(),
            QuestionToolSetting::Overseer
        );
        assert_eq!(
            settings
                .controller
                .question_tool
                .get()
                .unwrap()
                .for_controller(),
            QuestionTool::Keep
        );
        assert_eq!(
            settings.engine.harness_binaries.get().unwrap(),
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
            (ACCOUNT_RETIRE_KEY, "/a/b=2027-01-01"),
            (ACCOUNT_RETIRE_KEY, "a=2027-02-30"),
            (LANE_CLOUD_REPOS_KEY, "a=repo"),
            (LANE_CLOUD_REPOS_KEY, "a=o/.."),
            (COPILOT_POOL_KEY, "/p=1/0"),
            (ACCOUNT_EXCLUDE_KEY, "~/x"),
            (ACCOUNT_MAX_PCT_KEY, "101"),
            (ACCOUNT_BURN_PCT_KEY, "five"),
            (CONTROLLER_HEADROOM_PCT_KEY, "-1"),
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
            s.engine.verify.get().map(drop),
            s.close_grace.get().map(drop),
            s.engine.claim.get().map(drop),
            s.watch.get().map(drop),
            s.controller.question_tool.get().map(drop),
            s.launch.permission.get().map(drop),
            s.engine.harness_binaries.get().map(drop),
            s.controller.succession.get().map(drop),
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
                let e = crate::Error::from(e);
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
    /// none, which keeps nothing a day. A set value is taken as given, and a
    /// value outside `[1-9][0-9]*` is refused by key and value.
    #[test]
    fn the_retention_and_lanes_keys_take_their_defaults_and_refuse_by_key_and_value() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(settings.retention_days.get().unwrap(), 5);
        let settings = load(&roots, &env(&[(RECORD_RETENTION_DAYS_KEY, "12")]), &FLAGS).unwrap();
        assert_eq!(settings.retention_days.get().unwrap(), 12);
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
        for &key in KEYS
            .read
            .iter()
            .flat_map(|block| block.iter())
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
}
