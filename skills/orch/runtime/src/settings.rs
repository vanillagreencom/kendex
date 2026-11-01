//! The runtime's one settings reader: the project's `[env]` tables, its
//! private env file and the caller's environment, layered the way the
//! legacy `workflow-state` loads them, read as data and never run.
//!
//! Precedence, highest first: a flag on the command line, the caller's own
//! environment, the private env file (`.env.local`, or the file
//! `KENDEX_ENV_FILE` names, skipped under `--no-private-env`),
//! `.kendex/settings.toml`, then `kendex.settings.toml`. An empty value is
//! an unset one, as the legacy `${KEY:-default}` reads take it.
//!
//! The settings files follow the kendex `[env]` contract the shell loader
//! holds them to: `[env]` assignments of single-line basic strings with no
//! `"` or `\`, or literal strings with no apostrophe, an optional trailing
//! `#` comment, a duplicate key refused, a `[`-led line a lone `[name]`
//! header or refused, a leading byte-order mark refused. The private env
//! file is shell to its legacy loader; here it is read as data, which is the
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
/// persists (decision 78).
pub const SUCCESSION_KEY: &str = "ORCH_OVERSEER_SUCCESSION";
/// The job-unit launcher a succession's effect is detached through
/// (decision 76); empty finds the installed orch package's own.
pub const JOB_UNIT_KEY: &str = "ORCH_JOB_UNIT";
/// The settings key naming the project's private env file.
pub const ENV_FILE_KEY: &str = "KENDEX_ENV_FILE";
/// The private env file read when the project names none.
pub const DEFAULT_ENV_FILE: &str = ".env.local";
/// The settings files in loading order; a later file outranks an earlier.
pub const SETTINGS_FILES: [&str; 2] = ["kendex.settings.toml", ".kendex/settings.toml"];
/// The worktree package's program under the project's install.
pub const WORKTREE_CLI_DEFAULT: &str = ".agents/skills/worktree/scripts/worktree";
// U5g: the agent-runtime command the wake duty delivers through.
/// The agent-runtime command the wake duty delivers through; empty finds
/// the installed agent-runtime package's own wrapper.
pub const AGENT_RUNTIME_KEY: &str = "ORCH_AGENT_RUNTIME";
/// The agent-runtime package's wrapper under the project's install.
pub const AGENT_RUNTIME_DEFAULT: &str = ".agents/skills/agent-runtime/scripts/agent-runtime";
/// The orch package's job-unit launcher under the project's install.
pub const JOB_UNIT_DEFAULT: &str = ".agents/skills/orch/scripts/lib/job-unit.sh";
/// The lanes the fleet cap admits at once: every lane kind but
/// `claude-cloud`, which the legacy cloud cap bounds. The shipped default
/// is 4; the legacy launcher keeps its own, 3 (`open-terminal`, `orch-env
/// ORCH_OVERSEER_LANES 3`), until it retires (decision 94).
pub const LANE_CAP_KEY: &str = "ORCH_OVERSEER_LANES";
/// The directory the legacy launcher keeps its claim store under, as
/// `<dir>/claims` (`lib/lane-claims.sh`, `lane_claims_dir`); the main
/// checkout's `tmp/oversee-watch` when unset. Read, never written, by the
/// lane cap's admission during coexistence (decision 97).
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
/// The program the lane admission reads a diff range's changed paths
/// through (decision 118 (4)); empty finds the installed change-scope
/// package's `harness-only`.
pub const SCOPE_PATHS_CLI_KEY: &str = "CHANGE_SCOPE_PATHS_CLI";
/// The change-scope package's path reader under the project's install.
pub const SCOPE_PATHS_CLI_DEFAULT: &str = ".agents/skills/change-scope/scripts/harness-only";
/// The claim store under the main checkout when no directory is named.
pub const CLAIM_STORE_DEFAULT: &str = "tmp/oversee-watch/claims";
/// Seconds a transfer's or a stop's caller waits for its detached job to
/// claim the intent (decision 143): the claim's own bound, apart from the
/// tmux verification bound a test shortens to force a failed delivery.
pub const JOB_CLAIM_SECS_KEY: &str = "ORCH_JOB_CLAIM_SECS";
/// Seconds between the end of one mail turn and the start of the next
/// (step5-map F1).
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
/// The tracker program the tracker duty reads through (the legacy
/// `oversee-watch` key); empty finds the installed linear package's own.
pub const TRACKER_CLI_KEY: &str = "OVERSEE_WATCH_TRACKER";
/// The linear package's program under the project's install.
pub const TRACKER_CLI_DEFAULT: &str = ".agents/skills/linear/scripts/linear.sh";
// U5e2: the reducer the GitHub duty runs per repository.
/// The github skill's reducer the GitHub duty runs per repository with
/// `GH_REPO` (the legacy `oversee-watch` key); empty finds the installed
/// github package's own.
pub const PR_WATCH_CLI_KEY: &str = "OVERSEE_WATCH_PR_WATCH";
/// The github package's reducer under the project's install.
pub const PR_WATCH_CLI_DEFAULT: &str = ".agents/skills/github/scripts/pr-watch.sh";
/// Whether the GitHub duty reads each repository's open security alerts:
/// `on`, the default, or `off` (`lib/security-alerts.sh`).
pub const SECURITY_ALERTS_KEY: &str = "ORCH_SECURITY_ALERTS";
/// The file holding the installation token the alert reads run under; no
/// default, and an unset file reads the alerts with no token.
pub const SECURITY_ALERT_TOKEN_FILE_KEY: &str = "ORCH_SECURITY_ALERT_TOKEN_FILE";
/// Whether the GitHub duty reports outside contributions: `on`, the
/// default, or `off` (`lib/outside-contribution.sh`).
pub const EXTERNAL_TRIAGE_KEY: &str = "ORCH_EXTERNAL_TRIAGE";
/// Further `owner/repo` names the GitHub duty reads beside the fleet's,
/// separated by whitespace, lowercased and deduplicated as the legacy
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
// U5d2: the overseer mark line's payload names the preference.
/// The `harness:model:effort` entries a succession walks for the
/// successor lane (`lib/overseer-launch.sh`, `ol_preference`); the mark
/// line's payload names its value.
pub const OVERSEER_PREFERENCE_KEY: &str = "ORCH_OVERSEER_PREFERENCE";
/// The standard class on each harness (`OL_DEFAULT_PREFERENCE`).
pub const DEFAULT_OVERSEER_PREFERENCE: &str = "claude:standard:high,codex:standard:high";
// U5f: the retention, report and heartbeat duties' keys.
/// Days past a record's own recorded end before the retention duty removes
/// it (the key `workflow-state prune` and `lane-mail compact` read): the
/// event log's rotated segments and an ended lane's paths. A count of none
/// is a misconfiguration, as the legacy `find -mtime -0` kept everything.
pub const RECORD_RETENTION_DAYS_KEY: &str = "ORCH_RECORD_RETENTION_DAYS";
/// The report judge the report duty calls each long cadence (the legacy
/// `oversee-watch` key); empty finds the installed orch package's own.
pub const REPORT_CLI_KEY: &str = "OVERSEE_WATCH_REPORT";
/// The orch package's report judge under the project's install.
pub const REPORT_CLI_DEFAULT: &str = ".agents/skills/orch/scripts/oversee-report";
/// The account reader the heartbeat's roster and owed verdicts run (the
/// legacy `oversee-watch` key; decision 121 Q9); empty finds the installed
/// orch package's own.
pub const LANES_CLI_KEY: &str = "OVERSEE_WATCH_LANES";
/// The orch package's account reader under the project's install.
pub const LANES_CLI_DEFAULT: &str = ".agents/skills/orch/scripts/lanes";
const DEFAULT_RECORD_RETENTION_DAYS: u32 = 5;

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
const READ_KEYS: [&str; 43] = [
    TRACKER_CLI_KEY,
    PR_WATCH_CLI_KEY, // U5e2
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
    AGENT_RUNTIME_KEY, // U5g
    SUCCESSION_KEY,
    JOB_UNIT_KEY,
    LANE_CAP_KEY,
    CLAIM_STATE_DIR_KEY,
    LANE_MAIL_CLI_KEY,
    DEV_VALIDATE_CLI_KEY,
    SCOPE_PATHS_CLI_KEY,
    JOB_CLAIM_SECS_KEY,
    WATCH_MAIL_INTERVAL_KEY,
    OVERSEER_MARK_REPEAT_KEY,
    OVERSEER_DEAD_PASSES_KEY,
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
    OVERSEER_PREFERENCE_KEY, // U5d2
    // U5f
    RECORD_RETENTION_DAYS_KEY,
    REPORT_CLI_KEY,
    LANES_CLI_KEY,
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
/// checkout's, as the legacy `project_path` resolves it).
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

/// Whether a controller may ask for its own succession (decision 78).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Succession {
    On,
    Off,
}

impl Succession {
    /// The setting's word, as the legacy `succession=` field printed it.
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

/// The fleet watch's settings, read once at the runner's start (step5-map
/// A2-A10): the cadence the mail duty keeps and the bounds the observation,
/// mail and tracker duties judge against, each with the legacy
/// `oversee-watch` default. `--interval` and `--max-loops` are the runner's
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
    /// `owner/repo:workflow.yml` entries, lowercased repository, as the
    /// legacy read them; an entry of another shape is refused.
    pub main_workflows: Vec<String>,
    pub linear_team: Option<String>,
}

/// Whether a GitHub audit runs: the legacy `on`/`off` switches.
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

/// What the tracker and GitHub read duties consume (step5-map A4, A10),
/// each with its legacy `oversee-watch` default.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadSettings {
    /// The tracker program the tracker duty reads through.
    pub tracker_cli: PathBuf,
    /// The reducer the GitHub duty runs per repository (U5e2).
    pub pr_watch_cli: PathBuf,
    pub security_alerts: Audit,
    /// The installation token file the alert reads run under.
    pub security_alert_token_file: Option<PathBuf>,
    pub external_triage: Audit,
    /// Lowercased, deduplicated, in the order given.
    pub connected_repos: Vec<String>,
    pub owner_tracker: Option<OwnerTracker>,
}

/// The settings the runtime acts on, resolved once per process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settings {
    pub roots: Roots,
    /// The tracker and GitHub read duties' keys.
    pub reads: ReadSettings,
    pub state_dir: PathBuf,
    pub tmux_session: Option<String>,
    pub verify: Duration,
    pub close_grace: Duration,
    /// How long a caller waits for its detached job to claim the intent
    /// (decision 143).
    pub claim: Duration,
    pub watch: WatchSettings,
    pub question_tool: QuestionToolSetting,
    pub permission: Permission,
    pub harness_binaries: BTreeMap<Harness, PathBuf>,
    pub worktree_cli: PathBuf,
    /// U5g: the agent-runtime command the wake duty delivers through.
    pub agent_runtime: PathBuf,
    pub succession: Succession,
    /// The job-unit launcher a transfer's effect is detached through.
    pub job_unit: PathBuf,
    /// The lanes the fleet cap admits at once (decision 97).
    pub lane_cap: u32,
    /// The legacy claim store the cap's admission reads, never writes.
    pub claim_store: PathBuf,
    /// The mailbox program a close asks for unanswered asks.
    pub lane_mail_cli: PathBuf,
    /// The program a close ends a worktree's validation runs through.
    pub dev_validate_cli: PathBuf,
    /// The program the lane admission reads a range's changed paths
    /// through.
    pub scope_paths_cli: PathBuf,
    /// U5d2: the succession's preference entries, which the overseer mark
    /// line's payload names; an empty value reads as the default, as this
    /// reader takes every key.
    pub overseer_preference: String,
    // U5f: the retention, report and heartbeat duties.
    /// Days past its own recorded end before the retention duty removes a
    /// record.
    pub retention_days: u32,
    /// The report judge the report duty calls (`oversee-report due`).
    pub report_cli: PathBuf,
    /// The account reader the heartbeat runs (`lanes list --json`, `lanes
    /// pick`).
    pub lanes_cli: PathBuf,
}

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

fn value_refusal(key: &str, value: &str) -> crate::Error {
    refused("setting-invalid", &[("key", key), ("value", value)])
}

/// The checkout roots for `cwd`, read from git through the one runner. A
/// directory outside any repository is its own root, as the legacy
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
        // Under `--no-private-env` the legacy loader takes `ORCH_STATE_DIR`
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
    // The legacy watch's `^(0|[1-9][0-9]*)$` (`oversee-watch:623`, `:636`):
    // a wait of none is a documented value (the mail read once a turn, a
    // directive reported unread at once).
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
    // Base ten, no sign and no leading zero, as the legacy launcher parses
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
    // The legacy watch's `^[0-9]+$` with the value at least 1
    // (`oversee-watch:603`): a leading zero is admitted there.
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
    let agent_runtime = program(AGENT_RUNTIME_KEY, AGENT_RUNTIME_DEFAULT); // U5g
    let dev_validate_cli = program(DEV_VALIDATE_CLI_KEY, DEV_VALIDATE_CLI_DEFAULT);
    let scope_paths_cli = program(SCOPE_PATHS_CLI_KEY, SCOPE_PATHS_CLI_DEFAULT);
    let overseer_preference = get(OVERSEER_PREFERENCE_KEY)
        .unwrap_or(DEFAULT_OVERSEER_PREFERENCE)
        .to_owned(); // U5d2
    // U5f
    let retention_days = count(RECORD_RETENTION_DAYS_KEY, DEFAULT_RECORD_RETENTION_DAYS)?;
    let report_cli = program(REPORT_CLI_KEY, REPORT_CLI_DEFAULT);
    let lanes_cli = program(LANES_CLI_KEY, LANES_CLI_DEFAULT);
    // The read duties' keys (`security_alerts_init`, `outside_contribution_init`,
    // `orch_connected_repos`, `owner_tracker_settings`).
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
        pr_watch_cli: program(PR_WATCH_CLI_KEY, PR_WATCH_CLI_DEFAULT), // U5e2
        security_alerts: audit(SECURITY_ALERTS_KEY)?,
        security_alert_token_file: get(SECURITY_ALERT_TOKEN_FILE_KEY).map(PathBuf::from),
        external_triage: audit(EXTERNAL_TRIAGE_KEY)?,
        connected_repos,
        owner_tracker,
    };
    Ok(Settings {
        roots: roots.clone(),
        reads,
        state_dir,
        tmux_session: get(TMUX_SESSION_KEY).map(str::to_owned),
        verify: secs(VERIFY_SECS_KEY, DEFAULT_VERIFY_SECS)?,
        close_grace: secs(CLOSE_SECS_KEY, DEFAULT_CLOSE_SECS)?,
        claim: secs(JOB_CLAIM_SECS_KEY, DEFAULT_CLAIM_SECS)?,
        watch,
        question_tool,
        permission,
        harness_binaries,
        worktree_cli,
        agent_runtime, // U5g
        succession,
        job_unit,
        lane_cap,
        claim_store,
        lane_mail_cli,
        dev_validate_cli,
        scope_paths_cli,
        overseer_preference, // U5d2
        // U5f
        retention_days,
        report_cli,
        lanes_cli,
    })
}

/// The private env file's project-relative name: the default, or the
/// configured one held to the spelling the legacy loader admits.
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
fn settings_file(path: &Path) -> Result<Vec<(String, String)>> {
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
fn private_env_file(path: &Path) -> Result<Vec<(String, String)>> {
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

    /// The legacy ladder, one rung at a time: the flag, the caller's
    /// environment, the private file, `.kendex/settings.toml`,
    /// `kendex.settings.toml`, then `tmp`, a relative value resolved on the
    /// main checkout and an absolute one kept.
    #[test]
    fn the_state_directory_follows_the_legacy_ladder() {
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

    /// Finding 12: under `--no-private-env` the files give `ORCH_STATE_DIR`
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
            "the legacy oversee-watch defaults"
        );
        assert!(settings.harness_binaries.is_empty());
        assert_eq!(
            settings.worktree_cli,
            roots.project.join(WORKTREE_CLI_DEFAULT)
        );
        // U5g
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
        // A relative claim directory is the project's, as the legacy
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

    /// The read duties' keys (U5e): each default is the legacy's, the words
    /// and shapes are the legacy readers', the rest is refused by key and
    /// value, and the owner tracker is configured only by both its halves.
    #[test]
    fn the_read_duties_keys_take_their_legacy_defaults_words_and_refusals() {
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

    /// R-U5a F2. Defect: the three watch keys read through the stricter
    /// parsers of the launcher's keys, refusing values the legacy watch
    /// admits (`oversee-watch:603`, `:623`, `:636`) and so refusing every
    /// runtime verb on a fleet that sets them. Each key's legacy-valid edge
    /// reads as the legacy read it.
    #[test]
    fn the_watch_keys_admit_the_legacy_grammars_edges() {
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

    // U5f: the retention, report and heartbeat duties' keys.
    /// Decision 141 (3). Defect: a mistyped retention read as the default
    /// (the legacy `orch-env` handed `find -mtime` whatever stood), or a
    /// count of none, which the legacy `find -mtime -0` kept everything
    /// under; and a report or account program read from anywhere but the
    /// legacy's own keys. Each default is the legacy's, a set value is
    /// taken as given, and a value outside `[1-9][0-9]*` is refused by key
    /// and value.
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
}
