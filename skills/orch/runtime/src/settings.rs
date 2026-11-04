//! The runtime's one settings reader: the project's `[env]` tables, its
//! private env file and the caller's environment, layered the way the
//! shell store loaded them, read as data and never run.
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
//! file is shell to the loader that sources it; here it is read as data, which is the
//! only way to answer what it says without running what it does: an
//! assignment line, `KEY=VALUE` with an optional leading `export`, whose
//! value is single-quoted, double-quoted under the contract above, or one
//! bare word with no quote, `$`, `#`, backslash or whitespace. A line of any
//! other shape assigns nothing here; one that assigns a key this runtime
//! reads in a shape it cannot decode refuses, since reading past it would
//! take the shell's value for another.
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
/// `claude-cloud`, which the cloud cap bounds. The shipped default
/// is 4; the shell launcher `open-terminal` defaults to 3.
pub const LANE_CAP_KEY: &str = "ORCH_OVERSEER_LANES";
/// The directory the shell launcher keeps its claim store under, as
/// `<dir>/claims` (`lib/lane-claims.sh`, `lane_claims_dir`); the main
/// checkout's `tmp/oversee-watch` when unset. Read, never written, by the
/// lane cap's admission while both launchers run.
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
/// `pr`, the default, or `push-base`: direct delivery keeps every ci
/// request on local validation.
pub const DELIVERY_KEY: &str = "ORCH_DELIVERY";
const DEFAULT_VALIDATE_TIMEOUT_SECS: u64 = 3600;
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
/// `orch_connected_repos` read them.
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
/// The report judge the report duty calls each long cadence; empty finds
/// the installed orch package's own.
pub const REPORT_CLI_KEY: &str = "OVERSEE_WATCH_REPORT";
/// The orch package's report judge under the project's install.
pub const REPORT_CLI_DEFAULT: &str = ".agents/skills/orch/scripts/oversee-report";
/// The account reader the heartbeat's roster and owed verdicts run;
/// empty finds the installed orch package's own.
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
/// Points of the 5-hour session window one live lane is expected to spend
/// an hour where its account measured no rate.
pub const LANE_BURN_PCT_KEY: &str = "ORCH_LANE_BURN_PCT_PER_HOUR";
/// The account headroom the overseer hands off at, and so the room a seat
/// keeps for it: a worker's pick holds a seat to `min(ORCH_LANE_MAX_PCT,
/// 100 - this)`.
pub const OVERSEER_HEADROOM_PCT_KEY: &str = "ORCH_OVERSEER_HEADROOM_PCT";
/// The minutes to the account's wall, at the measured rate, the overseer
/// hands off at; 0 is no rate mark.
pub const OVERSEER_WALL_MINUTES_KEY: &str = "ORCH_OVERSEER_WALL_MINUTES";
/// The count of accounts above the headroom trigger, the overseer's own
/// among them, at or under which the overseer moves onto the one with more
/// room; 0 is no qualifying mark.
pub const OVERSEER_SUCCESSOR_ACCOUNTS_KEY: &str = "ORCH_OVERSEER_SUCCESSOR_ACCOUNTS";
/// The percent of its cgroup's memory cap the overseer's harness process
/// hands off at; unset is no memory mark.
pub const OVERSEER_MEMORY_PCT_KEY: &str = "ORCH_OVERSEER_MEMORY_PCT";
/// The share of the context window a reading is due strictly past, held
/// to the judge's ceiling.
pub const HANDOFF_CONTEXT_PCT_KEY: &str = "ORCH_HANDOFF_CONTEXT_PCT";
const DEFAULT_OVERSEER_WALL_MINUTES: u32 = 20;
const DEFAULT_OVERSEER_SUCCESSOR_ACCOUNTS: u32 = 1;
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
/// The home whose `.<harness>` and `.*<harness>*` directories the listing
/// discovers accounts in.
pub const HOME_KEY: &str = "HOME";
/// Colon-separated config directories, each an account of the harness
/// whose credential it holds; the entries of a harness replace its
/// discovery.
pub const LANE_DIRS_KEY: &str = "ORCH_LANE_DIRS";
/// A Codex home the CLI reads, joined to the Codex inventory as the account
/// it names; a Copilot home likewise.
pub const CODEX_HOME_KEY: &str = "CODEX_HOME";
pub const COPILOT_HOME_KEY: &str = "COPILOT_HOME";
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
    CLAIM_STATE_DIR_KEY,
    LANE_MAIL_CLI_KEY,
    DEV_VALIDATE_CLI_KEY,
    DEV_VALIDATE_CMD_KEY,
    DEV_VALIDATE_RANGE_CMD_KEY,
    DEV_VALIDATE_CI_CONTEXT_KEY,
    DEV_VALIDATE_SELECTION_CMD_KEY,
    DEV_VALIDATE_FINDING_PREFIX_KEY,
    DEV_VALIDATE_TIMEOUT_SECS_KEY,
    DELIVERY_KEY,
    SCOPE_PATHS_CLI_KEY,
    JOB_CLAIM_SECS_KEY,
    WATCH_MAIL_INTERVAL_KEY,
    OVERSEER_MARK_REPEAT_KEY,
    OVERSEER_DEAD_PASSES_KEY,
    OVERSEER_WALL_MINUTES_KEY,
    OVERSEER_SUCCESSOR_ACCOUNTS_KEY,
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
    REPORT_CLI_KEY,
    LANES_CLI_KEY,
    COPILOT_HOLD_SECS_KEY,
    REVIEW_WAIT_SECS_KEY,
    REVIEW_ON_TIMEOUT_KEY,
    COPILOT_REQUESTS_KEY,
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

/// The fleet watch's settings, read once at the runner's start: the cadence
/// the mail duty keeps and the bounds the observation, the mail and tracker
/// duties judge against. `--interval` and `--max-loops` are the runner's
/// own flags.
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
    pub linear_team: Option<String>,
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
    pub security_alerts: Audit,
    /// The installation token file the alert reads run under.
    pub security_alert_token_file: Option<PathBuf>,
    pub external_triage: Audit,
    /// Lowercased, deduplicated, in the order given.
    pub connected_repos: Vec<String>,
    pub owner_tracker: Option<OwnerTracker>,
}

/// How a change is delivered, which decides whether a ci request may
/// defer to the pull request's required CI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Delivery {
    Pr,
    PushBase,
}

/// The project's validation declaration, the one source `validate
/// start` resolves a run's mode from: the whole battery,
/// the range command where declared, the CI context where declared, the
/// selector, the finding prefix and the bound. A command is its text,
/// trimmed of nothing; an empty or blank value is no declaration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidateSettings {
    pub cmd: Option<String>,
    pub range_cmd: Option<String>,
    pub ci_context: Option<String>,
    pub selection_cmd: Option<String>,
    pub finding_prefix: Option<String>,
    pub timeout: Duration,
    pub delivery: Delivery,
}

/// What `queue-watch` reads beside its request: the arming grace, the
/// confirmation count and the probe interval, each a whole number above
/// zero, refused by key and value otherwise.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueWatchSettings {
    pub arm_grace: Duration,
    pub confirm_polls: u32,
    pub probe_interval: Duration,
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
    pub home: Option<String>,
    pub lane_dirs: Vec<String>,
    pub codex_home: Option<String>,
    pub copilot_home: Option<String>,
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
    pub state_dir: PathBuf,
    pub tmux_session: Option<String>,
    pub verify: Duration,
    pub close_grace: Duration,
    pub claim: Duration,
    pub watch: WatchSettings,
    pub question_tool: QuestionToolSetting,
    pub permission: Permission,
    pub harness_binaries: BTreeMap<Harness, PathBuf>,
    pub worktree_cli: PathBuf,
    pub agent_runtime: PathBuf,
    pub succession: Succession,
    /// The controller's own marks.
    pub marks: MarkSettings,
    pub job_unit: PathBuf,
    pub lane_cap: u32,
    /// The shell launcher's claim store the cap's admission reads, never writes.
    pub claim_store: PathBuf,
    pub lane_mail_cli: PathBuf,
    pub dev_validate_cli: PathBuf,
    pub validate: ValidateSettings,
    pub scope_paths_cli: PathBuf,
    /// The succession's preference entries, which the overseer mark
    /// line's payload names; an empty value reads as the default, as this
    /// reader takes every key.
    pub overseer_preference: String,
    /// A lane launch's preference entries; `None` where the setting
    /// names none.
    pub lane_preference: Option<String>,
    pub retention_days: u32,
    pub queue_watch: QueueWatchSettings,
    pub archive_root: ArchiveRoot,
    pub report_cli: PathBuf,
    pub lanes_cli: PathBuf,
    pub accounts: AccountSettings,
    pub store: StoreSettings,
    pub review: ReviewSettings,
}

/// The controller's own marks beyond the headroom trigger: the rate mark
/// in minutes, the qualifying count, the memory mark where set, and the
/// context share.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkSettings {
    pub wall_minutes: u32,
    pub successor_accounts: u32,
    pub memory_pct: Option<u32>,
    pub context_pct: u32,
}

/// The state verbs' settings: the takeover window and the row bound of the
/// fleet log, the progress report directory, and the round caps. A cap of
/// none is a documented value, so each is a whole number from zero.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoreSettings {
    pub takeover_rows: u64,
    pub fleet_log_row_bytes: u64,
    /// Absolute: a relative setting is joined to the main checkout.
    pub progress_report_dir: PathBuf,
    pub review_max_cycles: u64,
    pub review_max_external_rounds: u64,
    pub ci_fix_max_cycles: u64,
}

/// The review gate's settings as read: the hold on Copilot's work in
/// flight, the reviewer's period, what a spent period answers, and
/// whether Copilot is asked at all. Each is carried as its text (the
/// default where unset), since the review gate is the one verb that
/// reads them and the one that refuses a value outside its form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewSettings {
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
    let output = host::run_tagged(
        "settings",
        "git",
        Path::new("git"),
        operation,
        &full,
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

/// Resolve the settings for a process: the files under `roots`, the
/// caller's `environment` and the command-line `flags`.
pub fn load(
    roots: &Roots,
    environment: &[(OsString, OsString)],
    flags: &Flags,
) -> Result<Settings> {
    let mut file_values: BTreeMap<String, String> = BTreeMap::new();
    for name in SETTINGS_FILES {
        let path = roots.project.join(name);
        for (key, value) in settings_file(&path)? {
            file_values.insert(key, value);
        }
    }
    let caller: BTreeMap<String, String> = environment
        .iter()
        .filter_map(|(k, v)| Some((k.to_str()?.to_owned(), v.to_str()?.to_owned())))
        .collect();
    let mut values: BTreeMap<String, String> = BTreeMap::new();
    if flags.private_env {
        // The default ladder, lowest rung first: the settings files, the
        // private env file, then the caller's environment over all.
        values.extend(file_values);
        let named = caller
            .get(ENV_FILE_KEY)
            .or_else(|| values.get(ENV_FILE_KEY))
            .filter(|v| !v.is_empty())
            .cloned();
        let path = roots.project.join(private_env_name(named.as_deref())?);
        for (key, value) in private_env_file(&path)? {
            values.insert(key, value);
        }
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
        if let Some(state_dir) = file_values.remove(STATE_DIR_KEY) {
            values.insert(STATE_DIR_KEY.to_owned(), state_dir);
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
    let secs = |key: &str, default: u64| -> Result<Duration> {
        match get(key) {
            None => Ok(Duration::from_secs(default)),
            Some(text) => match text.parse::<u64>() {
                Ok(n) if n > 0 && !text.starts_with('0') && !text.starts_with('+') => {
                    Ok(Duration::from_secs(n))
                }
                Ok(_) | Err(_) => Err(value_refusal(key, text)),
            },
        }
    };
    // Zero, or digits with no leading zero: a wait of none is a documented
    // value (the mail read once a turn, a directive reported unread at once).
    let secs_or_none = |key: &str, default: u64| -> Result<Duration> {
        match get(key) {
            None => Ok(Duration::from_secs(default)),
            Some("0") => Ok(Duration::ZERO),
            Some(_) => secs(key, default),
        }
    };
    let question_tool = match get(QUESTION_TOOL_KEY) {
        None | Some("off") => QuestionToolSetting::Off,
        Some("overseer") => QuestionToolSetting::Overseer,
        Some(other) => return Err(value_refusal(QUESTION_TOOL_KEY, other)),
    };
    let permission = match get(LAUNCH_PERMISSION_KEY) {
        None | Some("bypass") => Permission::Bypass,
        Some("native") => Permission::Native,
        Some(other) => return Err(value_refusal(LAUNCH_PERMISSION_KEY, other)),
    };
    let mut harness_binaries = BTreeMap::new();
    if let Some(text) = get(HARNESS_BINARIES_KEY) {
        for pair in text.split(',') {
            let pair = pair.trim();
            let (Some((name, path)), true) = (pair.split_once('='), !pair.is_empty()) else {
                return Err(value_refusal(HARNESS_BINARIES_KEY, text));
            };
            let path = PathBuf::from(path.trim());
            let Some(harness) = Harness::parse(name.trim()) else {
                return Err(value_refusal(HARNESS_BINARIES_KEY, text));
            };
            if !path.is_absolute() || harness_binaries.insert(harness, path).is_some() {
                return Err(value_refusal(HARNESS_BINARIES_KEY, text));
            }
        }
    }
    let worktree_cli = match get(WORKTREE_CLI_KEY) {
        Some(path) => PathBuf::from(path),
        None => roots.project.join(WORKTREE_CLI_DEFAULT),
    };
    let succession = match get(SUCCESSION_KEY) {
        None | Some("on") => Succession::On,
        Some("off") => Succession::Off,
        Some(other) => return Err(value_refusal(SUCCESSION_KEY, other)),
    };
    let job_unit = match get(JOB_UNIT_KEY) {
        Some(path) => PathBuf::from(path),
        None => roots.project.join(JOB_UNIT_DEFAULT),
    };
    // Base ten, no sign and no leading zero, as the shell launcher parses
    // it; a count of none names a misconfiguration (a cap of none admits no
    // lane, a repeat of none repeats every pass).
    let count = |key: &str, default: u32| -> Result<u32> {
        match get(key) {
            None => Ok(default),
            Some(text) => match text.parse::<u32>() {
                Ok(n) if n > 0 && !text.starts_with('0') && !text.starts_with('+') => Ok(n),
                Ok(_) | Err(_) => Err(value_refusal(key, text)),
            },
        }
    };
    let lane_cap = count(LANE_CAP_KEY, DEFAULT_LANE_CAP)?;
    // Digits alone with the value at least 1, a leading zero admitted.
    let passes = |key: &str, default: u32| -> Result<u32> {
        match get(key) {
            None => Ok(default),
            Some(text) => match text.parse::<u32>() {
                Ok(n) if n > 0 && text.bytes().all(|b| b.is_ascii_digit()) => Ok(n),
                Ok(_) | Err(_) => Err(value_refusal(key, text)),
            },
        }
    };
    let wall_relaunch = match get(WALL_RELAUNCH_KEY) {
        None | Some("auto") => WallRelaunch::Auto,
        Some("ask") => WallRelaunch::Ask,
        Some(other) => return Err(value_refusal(WALL_RELAUNCH_KEY, other)),
    };
    let mut main_workflows = Vec::new();
    if let Some(text) = get(MAIN_WORKFLOWS_KEY) {
        for entry in text.split_whitespace() {
            let Some((repo, workflow)) = entry.split_once(':') else {
                return Err(value_refusal(MAIN_WORKFLOWS_KEY, text));
            };
            let word = |s: &str| {
                !s.is_empty()
                    && s.chars()
                        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
            };
            let repo_ok = repo
                .split_once('/')
                .is_some_and(|(o, n)| word(o) && word(n));
            let workflow_ok = workflow
                .strip_suffix(".yml")
                .or_else(|| workflow.strip_suffix(".yaml"))
                .is_some_and(word);
            if !repo_ok || !workflow_ok {
                return Err(value_refusal(MAIN_WORKFLOWS_KEY, text));
            }
            main_workflows.push(format!("{}:{workflow}", repo.to_ascii_lowercase()));
        }
    }
    let watch = WatchSettings {
        mail_interval: secs_or_none(WATCH_MAIL_INTERVAL_KEY, DEFAULT_MAIL_INTERVAL_SECS)?,
        mark_repeat: count(OVERSEER_MARK_REPEAT_KEY, DEFAULT_MARK_REPEAT)?,
        dead_passes: passes(OVERSEER_DEAD_PASSES_KEY, DEFAULT_DEAD_PASSES)?,
        tail_lines: count(WATCH_TAIL_LINES_KEY, DEFAULT_TAIL_LINES)?,
        prepare: secs(WATCH_PREPARE_SECS_KEY, DEFAULT_PREPARE_SECS)?,
        directive_unread: secs_or_none(DIRECTIVE_UNREAD_SECS_KEY, DEFAULT_DIRECTIVE_UNREAD_SECS)?,
        start_stall: secs(WATCH_START_STALL_SECS_KEY, DEFAULT_START_STALL_SECS)?,
        lane_stall: secs(WATCH_LANE_STALL_SECS_KEY, DEFAULT_LANE_STALL_SECS)?,
        cloud_stall: secs(CLOUD_STALL_MINUTES_KEY, DEFAULT_CLOUD_STALL_MINUTES)?.saturating_mul(60),
        lane_age: secs(WATCH_LANE_AGE_SECS_KEY, DEFAULT_LANE_AGE_SECS)?,
        wall_relaunch,
        main_workflows,
        linear_team: get(LINEAR_TEAM_KEY).map(str::to_owned),
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
    // `${cmd//[[:space:]]/}` read it; a prefix with a newline inside can
    // prefix no line, which the shell left unrecorded, and is refused.
    let command = |key: &str| get(key).filter(|v| !v.trim().is_empty()).map(str::to_owned);
    let finding_prefix = match get(DEV_VALIDATE_FINDING_PREFIX_KEY) {
        Some(text) if text.contains('\n') => {
            return Err(value_refusal(DEV_VALIDATE_FINDING_PREFIX_KEY, text));
        }
        other => other.map(str::to_owned),
    };
    // The shell `check_seconds` rule: every byte a digit and the value above
    // zero, a leading zero admitted.
    let validate_timeout = match get(DEV_VALIDATE_TIMEOUT_SECS_KEY) {
        None => Duration::from_secs(DEFAULT_VALIDATE_TIMEOUT_SECS),
        Some(text) => match text.parse::<u64>() {
            Ok(n) if n > 0 && text.bytes().all(|b| b.is_ascii_digit()) => Duration::from_secs(n),
            Ok(_) | Err(_) => return Err(value_refusal(DEV_VALIDATE_TIMEOUT_SECS_KEY, text)),
        },
    };
    let delivery = match get(DELIVERY_KEY) {
        None | Some("pr") => Delivery::Pr,
        Some("push-base") => Delivery::PushBase,
        Some(other) => return Err(value_refusal(DELIVERY_KEY, other)),
    };
    let validate = ValidateSettings {
        cmd: command(DEV_VALIDATE_CMD_KEY),
        range_cmd: command(DEV_VALIDATE_RANGE_CMD_KEY),
        ci_context: command(DEV_VALIDATE_CI_CONTEXT_KEY),
        selection_cmd: command(DEV_VALIDATE_SELECTION_CMD_KEY),
        finding_prefix,
        timeout: validate_timeout,
        delivery,
    };
    let scope_paths_cli = program(SCOPE_PATHS_CLI_KEY, SCOPE_PATHS_CLI_DEFAULT);
    let overseer_preference = get(OVERSEER_PREFERENCE_KEY)
        .unwrap_or(DEFAULT_OVERSEER_PREFERENCE)
        .to_owned();
    let lane_preference = get(LANE_PREFERENCE_KEY).map(str::to_owned);
    let retention_days = count(RECORD_RETENTION_DAYS_KEY, DEFAULT_RECORD_RETENTION_DAYS)?;
    let queue_watch = QueueWatchSettings {
        arm_grace: Duration::from_secs(u64::from(count(
            QUEUE_WAIT_ARM_GRACE_KEY,
            DEFAULT_QUEUE_WAIT_ARM_GRACE_SECS,
        )?)),
        confirm_polls: count(
            QUEUE_WAIT_CONFIRM_POLLS_KEY,
            DEFAULT_QUEUE_WAIT_CONFIRM_POLLS,
        )?,
        probe_interval: Duration::from_secs(u64::from(count(
            QUEUE_WAIT_PROBE_INTERVAL_KEY,
            DEFAULT_QUEUE_WAIT_PROBE_INTERVAL_SECS,
        )?)),
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
    let report_cli = program(REPORT_CLI_KEY, REPORT_CLI_DEFAULT);
    let lanes_cli = program(LANES_CLI_KEY, LANES_CLI_DEFAULT);
    // The accounts judge's keys, held to `lanes`' own grammar
    // (`validate_lane_settings`, `pct_valid`): a retirement names a lane
    // (no `/`, no `~`) and a real calendar day; a percentage is a whole
    // number 0 to 100; a value nobody can read is refused, never defaulted.
    let mut retire = Vec::new();
    if let Some(text) = get(LANE_RETIRE_KEY) {
        for item in text.split(',').map(str::trim).filter(|i| !i.is_empty()) {
            let valid = item.split_once('=').filter(|(name, date)| {
                lane_key_valid(name.trim()) && calendar_date_valid(date.trim())
            });
            let Some((name, date)) = valid else {
                return Err(value_refusal(LANE_RETIRE_KEY, item));
            };
            retire.push(Retirement {
                name: name.trim().to_owned(),
                date: date.trim().to_owned(),
            });
        }
    }
    let pct = |key: &str, default: u32| -> Result<u32> {
        match get(key) {
            None => Ok(default),
            Some(text) => match text.parse::<u32>() {
                Ok(n)
                    if n <= 100 && text.len() <= 3 && text.bytes().all(|b| b.is_ascii_digit()) =>
                {
                    Ok(n)
                }
                Ok(_) | Err(_) => Err(value_refusal(key, text)),
            },
        }
    };
    let whole = |key: &str, default: u64| -> Result<u64> {
        match get(key) {
            None => Ok(default),
            Some(text) => match text.parse::<u64>() {
                Ok(n) if text.bytes().all(|b| b.is_ascii_digit()) => Ok(n),
                Ok(_) | Err(_) => Err(value_refusal(key, text)),
            },
        }
    };
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
                    && project
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
            });
            let Some((name, repo)) = valid else {
                return Err(value_refusal(LANE_CLOUD_REPOS_KEY, item));
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
            let whole =
                |s: &str| (1..=12).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_digit());
            let entry = item.rsplit_once('=').and_then(|(dir, value)| {
                let dir = dir.trim().trim_end_matches('/');
                let (used, granted) = value.trim().split_once('/')?;
                (dir.starts_with('/') && whole(used) && whole(granted)).then(|| CopilotPool {
                    dir: dir.to_owned(),
                    used: used.parse().unwrap_or(0),
                    granted: granted.parse().unwrap_or(0),
                })
            });
            let Some(entry) = entry.filter(|e| e.granted > 0) else {
                return Err(value_refusal(LANE_COPILOT_POOL_KEY, item));
            };
            if copilot_pool.iter().any(|e| e.dir == entry.dir) {
                return Err(value_refusal(LANE_COPILOT_POOL_KEY, item));
            }
            copilot_pool.push(entry);
        }
    }
    // `ORCH_LANE_EXCLUDE` names lanes, never paths (`lanes`' `lane_key_valid`).
    let mut exclude = Vec::new();
    if let Some(text) = get(LANE_EXCLUDE_KEY) {
        for item in text.split(',').map(str::trim).filter(|i| !i.is_empty()) {
            if !lane_key_valid(item) {
                return Err(value_refusal(LANE_EXCLUDE_KEY, item));
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
    // A whole number of at most nine digits, 0 included: 0 turns a mark off.
    let minutes = |key: &str, default: u32| -> Result<u32> {
        match get(key) {
            None => Ok(default),
            Some(text) => match text.parse::<u32>() {
                Ok(n) if text.len() <= 9 && text.bytes().all(|b| b.is_ascii_digit()) => Ok(n),
                Ok(_) | Err(_) => Err(value_refusal(key, text)),
            },
        }
    };
    let marks = MarkSettings {
        wall_minutes: minutes(OVERSEER_WALL_MINUTES_KEY, DEFAULT_OVERSEER_WALL_MINUTES)?,
        successor_accounts: minutes(
            OVERSEER_SUCCESSOR_ACCOUNTS_KEY,
            DEFAULT_OVERSEER_SUCCESSOR_ACCOUNTS,
        )?,
        memory_pct: match get(OVERSEER_MEMORY_PCT_KEY) {
            None => None,
            Some(_) => Some(pct(OVERSEER_MEMORY_PCT_KEY, 0)?),
        },
        context_pct: match pct(HANDOFF_CONTEXT_PCT_KEY, DEFAULT_HANDOFF_CONTEXT_PCT)? {
            0 => return Err(value_refusal(HANDOFF_CONTEXT_PCT_KEY, "0")),
            n => n,
        },
    };
    let accounts = AccountSettings {
        retire,
        max_pct: pct(LANE_MAX_PCT_KEY, DEFAULT_LANE_MAX_PCT)?,
        burn_pct_per_hour: pct(LANE_BURN_PCT_KEY, DEFAULT_LANE_BURN_PCT)?,
        overseer_headroom_pct: pct(OVERSEER_HEADROOM_PCT_KEY, DEFAULT_OVERSEER_HEADROOM_PCT)?,
        codex_credit_floor: whole(CODEX_CREDIT_FLOOR_KEY, DEFAULT_CODEX_CREDIT_FLOOR)?,
        cloud_credit_floor: whole(CLOUD_CREDIT_FLOOR_KEY, DEFAULT_CLOUD_CREDIT_FLOOR)?,
        cloud_repos,
        copilot_pool,
        exclude,
        aliases,
        host: get(LANE_HOST_KEY)
            .filter(|h| *h != "local")
            .map(str::to_owned),
        home: get(HOME_KEY).map(str::to_owned),
        lane_dirs: get(LANE_DIRS_KEY)
            .unwrap_or_default()
            .split(':')
            .filter(|d| !d.is_empty())
            .map(str::to_owned)
            .collect(),
        codex_home: get(CODEX_HOME_KEY).map(str::to_owned),
        copilot_home: get(COPILOT_HOME_KEY).map(str::to_owned),
        usage_ttl: whole(USAGE_TTL_KEY, DEFAULT_USAGE_TTL)?,
        usage_max_age: whole(USAGE_MAX_AGE_KEY, 0)?,
        accounts_timeout: whole(HOST_ACCOUNTS_TIMEOUT_KEY, DEFAULT_HOST_ACCOUNTS_TIMEOUT)?,
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
    };
    // The read duties' keys; the connected repositories and the owner
    // tracker keep the shell's grammar (`orch_connected_repos`,
    // `owner_tracker_settings`).
    let audit = |key: &str| match get(key) {
        None | Some("on") => Ok(Audit::On),
        Some("off") => Ok(Audit::Off),
        Some(other) => Err(value_refusal(key, other)),
    };
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
        security_alerts: audit(SECURITY_ALERTS_KEY)?,
        security_alert_token_file: get(SECURITY_ALERT_TOKEN_FILE_KEY).map(PathBuf::from),
        external_triage: audit(EXTERNAL_TRIAGE_KEY)?,
        connected_repos,
        owner_tracker,
    };
    let progress_report_dir =
        PathBuf::from(get(PROGRESS_REPORT_DIR_KEY).unwrap_or(DEFAULT_PROGRESS_REPORT_DIR));
    let store = StoreSettings {
        takeover_rows: whole(TAKEOVER_ROWS_KEY, DEFAULT_TAKEOVER_ROWS)?,
        fleet_log_row_bytes: whole(FLEET_LOG_ROW_BYTES_KEY, DEFAULT_FLEET_LOG_ROW_BYTES)?,
        progress_report_dir: if progress_report_dir.is_absolute() {
            progress_report_dir
        } else {
            roots.common.join(progress_report_dir)
        },
        review_max_cycles: whole(REVIEW_MAX_CYCLES_KEY, DEFAULT_REVIEW_MAX_CYCLES)?,
        review_max_external_rounds: whole(
            REVIEW_MAX_EXTERNAL_ROUNDS_KEY,
            DEFAULT_REVIEW_MAX_EXTERNAL_ROUNDS,
        )?,
        ci_fix_max_cycles: whole(CI_FIX_MAX_CYCLES_KEY, DEFAULT_CI_FIX_MAX_CYCLES)?,
    };
    let text = |key: &str, default: &str| get(key).unwrap_or(default).to_owned();
    let review = ReviewSettings {
        copilot_hold: text(COPILOT_HOLD_SECS_KEY, DEFAULT_COPILOT_HOLD_SECS),
        wait: text(REVIEW_WAIT_SECS_KEY, DEFAULT_REVIEW_WAIT_SECS),
        on_timeout: text(REVIEW_ON_TIMEOUT_KEY, "proceed"),
        copilot_requests: text(COPILOT_REQUESTS_KEY, "on"),
    };
    Ok(Settings {
        roots: roots.clone(),
        reads,
        state_dir,
        store,
        review,
        tmux_session: get(TMUX_SESSION_KEY).map(str::to_owned),
        verify: secs(VERIFY_SECS_KEY, DEFAULT_VERIFY_SECS)?,
        close_grace: secs(CLOSE_SECS_KEY, DEFAULT_CLOSE_SECS)?,
        claim: secs(JOB_CLAIM_SECS_KEY, DEFAULT_CLAIM_SECS)?,
        watch,
        question_tool,
        permission,
        harness_binaries,
        worktree_cli,
        agent_runtime,
        succession,
        marks,
        job_unit,
        lane_cap,
        claim_store,
        lane_mail_cli,
        dev_validate_cli,
        validate,
        scope_paths_cli,
        overseer_preference,
        lane_preference,
        retention_days,
        queue_watch,
        archive_root,
        report_cli,
        lanes_cli,
        accounts,
    })
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

fn read_text(path: &Path) -> Result<Option<String>> {
    match fs::read(path) {
        Ok(bytes) => {
            if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
                return Err(file_refusal(path, "", "byte-order-mark"));
            }
            Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(agent_runtime::Error::io("read", path, e).into()),
    }
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
    let Some(text) = read_text(path)? else {
        return Ok(Vec::new());
    };
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

/// Decode a shell assignment's value as data: single-quoted, double-quoted
/// under the `[env]` contract, or one bare word. `None` is a shape that
/// means something to the shell this reader cannot stand in for.
fn decode_shell_value(raw: &str) -> Option<String> {
    let raw = raw.trim_end();
    if raw.starts_with('\'') || raw.starts_with('"') {
        return decode_toml_value(raw);
    }
    let bare = !raw.is_empty()
        && !raw.contains(|c: char| {
            c.is_whitespace() || matches!(c, '$' | '#' | '\\' | '\'' | '"' | '`')
        });
    bare.then(|| raw.to_owned())
}

/// The assignments of the private env file this runtime reads, in file
/// order, read as data. A line that assigns nothing this runtime reads is
/// the shell's alone.
pub(crate) fn private_env_file(path: &Path) -> Result<Vec<(String, String)>> {
    let Some(text) = read_text(path)? else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        let line = line
            .strip_prefix("export ")
            .map(str::trim_start)
            .unwrap_or(line);
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if !READ_KEYS.contains(&key) {
            continue;
        }
        let Some(value) = decode_shell_value(value) else {
            return Err(file_refusal(path, key, "value-syntax"));
        };
        out.push((key.to_owned(), value));
    }
    Ok(out)
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
        assert_eq!(settings.verify, Duration::from_secs(3));
        assert_eq!(settings.close_grace, Duration::from_secs(15));
    }

    #[test]
    fn a_private_file_line_this_runtime_reads_must_decode_as_data() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        write(
            &roots.project,
            ".env.local",
            "ORCH_TMUX_SESSION=a $b\nSOMETHING_ELSE=$(date)\nfunction f() { :; }\n",
        );
        let err = load(&roots, &env(&[]), &FLAGS).unwrap_err();
        assert_eq!(err.key(), "settings-invalid");
        assert_eq!(err.fields()[1], ("key".into(), TMUX_SESSION_KEY.into()));
        write(
            &roots.project,
            ".env.local",
            "ORCH_TMUX_SESSION=plain\nexport ORCH_TMUX_VERIFY_SECS=\"4\"\nORCH_LANE_CLOSE_SECS='5'\n",
        );
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(settings.tmux_session.as_deref(), Some("plain"));
        assert_eq!(settings.verify, Duration::from_secs(4));
        assert_eq!(settings.close_grace, Duration::from_secs(5));
    }

    /// Each typed key: its default, its words and what it refuses.
    #[test]
    fn typed_keys_take_their_words_and_refuse_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(settings.permission, Permission::Bypass);
        assert_eq!(settings.question_tool, QuestionToolSetting::Off);
        assert_eq!(settings.verify, Duration::from_secs(15));
        assert_eq!(settings.close_grace, Duration::from_secs(15));
        assert_eq!(settings.claim, Duration::from_secs(15));
        assert_eq!(
            settings.watch,
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
                linear_team: None,
            },
            "the watch's documented defaults"
        );
        assert!(settings.harness_binaries.is_empty());
        assert_eq!(
            settings.worktree_cli,
            roots.project.join(WORKTREE_CLI_DEFAULT)
        );
        assert_eq!(
            settings.agent_runtime,
            roots.project.join(AGENT_RUNTIME_DEFAULT)
        );
        assert_eq!(settings.succession, Succession::On);
        assert_eq!(settings.job_unit, roots.project.join(JOB_UNIT_DEFAULT));
        assert_eq!(settings.lane_cap, 4);
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
                (LINEAR_TEAM_KEY, "KEN"),
            ]),
            &FLAGS,
        )
        .unwrap();
        assert_eq!(settings.claim, Duration::from_secs(40));
        assert_eq!(
            settings.watch,
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
                linear_team: Some("KEN".to_owned()),
            }
        );
        assert_eq!(settings.succession, Succession::Off);
        assert_eq!(settings.job_unit, PathBuf::from("/opt/job-unit.sh"));
        assert_eq!(settings.lane_cap, 7);
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
        assert_eq!(settings.permission, Permission::Native);
        assert_eq!(settings.question_tool, QuestionToolSetting::Overseer);
        assert_eq!(settings.question_tool.for_overseer(), QuestionTool::Keep);
        assert_eq!(
            settings.harness_binaries,
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
        ];
        for (key, value) in refused {
            let err = load(&roots, &env(&[(key, value)]), &FLAGS).unwrap_err();
            assert_eq!(err.key(), "setting-invalid", "{key}={value}");
            assert_eq!(
                err.fields(),
                vec![("key".into(), key.into()), ("value".into(), value.into())],
                "{key}={value}"
            );
        }
    }

    /// The read duties' keys: each default, word and shape, the rest
    /// refused by key and value, and the owner tracker configured only by
    /// both its halves.
    #[test]
    fn the_read_duties_keys_take_their_defaults_words_and_refusals() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(
            settings.reads,
            ReadSettings {
                tracker_cli: roots.project.join(TRACKER_CLI_DEFAULT),
                pr_watch_cli: roots.project.join(PR_WATCH_CLI_DEFAULT),
                security_alerts: Audit::On,
                security_alert_token_file: None,
                external_triage: Audit::On,
                connected_repos: Vec::new(),
                owner_tracker: None,
            }
        );
        let settings = load(
            &roots,
            &env(&[
                (TRACKER_CLI_KEY, "/opt/linear.sh"),
                (PR_WATCH_CLI_KEY, "/opt/pr-watch.sh"),
                (SECURITY_ALERTS_KEY, "off"),
                (SECURITY_ALERT_TOKEN_FILE_KEY, "/run/token"),
                (EXTERNAL_TRIAGE_KEY, "off"),
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
                security_alerts: Audit::Off,
                security_alert_token_file: Some(PathBuf::from("/run/token")),
                external_triage: Audit::Off,
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
        for (key, value) in [(SECURITY_ALERTS_KEY, "yes"), (EXTERNAL_TRIAGE_KEY, "1")] {
            let err = load(&roots, &env(&[(key, value)]), &FLAGS).unwrap_err();
            assert_eq!(err.key(), "setting-invalid", "{key}={value}");
            assert_eq!(
                err.fields(),
                vec![("key".into(), key.into()), ("value".into(), value.into())]
            );
        }
    }

    /// Defect: the three watch keys read through the stricter
    /// parsers of the launcher's keys, refusing values the watch
    /// admits and so refusing every
    /// runtime verb on a fleet that sets them. Each key's admitted edge
    /// reads as the watch read it.
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
        assert_eq!(settings.watch.mail_interval, Duration::ZERO);
        assert_eq!(settings.watch.directive_unread, Duration::ZERO);
        assert_eq!(settings.watch.dead_passes, 2);
    }

    /// Defect: a mistyped retention read as the default, or a count of
    /// none, which keeps nothing a day; and a report or account program
    /// read from anywhere but its own key. A set value is taken as given,
    /// and a value outside `[1-9][0-9]*` is refused by key and value.
    #[test]
    fn the_retention_report_and_lanes_keys_take_their_defaults_and_refuse_by_key_and_value() {
        let dir = tempfile::tempdir().unwrap();
        let roots = roots_in(dir.path());
        let settings = load(&roots, &env(&[]), &FLAGS).unwrap();
        assert_eq!(settings.retention_days, 5);
        assert_eq!(settings.report_cli, roots.project.join(REPORT_CLI_DEFAULT));
        assert_eq!(settings.lanes_cli, roots.project.join(LANES_CLI_DEFAULT));
        let settings = load(
            &roots,
            &env(&[
                (RECORD_RETENTION_DAYS_KEY, "12"),
                (REPORT_CLI_KEY, "/opt/oversee-report"),
                (LANES_CLI_KEY, "/opt/lanes"),
            ]),
            &FLAGS,
        )
        .unwrap();
        assert_eq!(settings.retention_days, 12);
        assert_eq!(settings.report_cli, PathBuf::from("/opt/oversee-report"));
        assert_eq!(settings.lanes_cli, PathBuf::from("/opt/lanes"));
        for value in ["0", "05", "x", "-1", "5d", "+5"] {
            let err =
                load(&roots, &env(&[(RECORD_RETENTION_DAYS_KEY, value)]), &FLAGS).unwrap_err();
            assert_eq!(err.key(), "setting-invalid", "{value:?}");
            assert_eq!(
                err.fields(),
                vec![
                    ("key".into(), RECORD_RETENTION_DAYS_KEY.into()),
                    ("value".into(), value.into())
                ],
                "{value:?}"
            );
        }
    }

    /// Defect: an archive root read as a bare relative path lands the
    /// archive under whatever directory the duty runs in, and a `~` taken
    /// literally makes a directory named `~`; a default that ignores the
    /// fleet directory archives beside the wrong fleet. A set value is an
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
}
