use std::fmt::Write as _;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::process::Stdio;

use color_eyre::eyre::{bail, Result, WrapErr};
use fs2::FileExt;
use serde::Serialize;
use serde_json::Value;
use tokio::process::Command;

use crate::cli::{FocusOrLaunchArgs, LaunchArgs, MotionArg, ThemeArg};
use crate::daemon::lifecycle::{pid_alive, read_pid};
use crate::state::{run_history, tracked_entries};
use crate::util::paths::{fd_resolve_state_dir, resolve_session_key};

const DASHBOARD_ENTRY_ID: &str = "flightdeck-dashboard";
const DEFAULT_WINDOW_NAME: &str = " FD";
const DEFAULT_WINDOW_NAME_PLAIN: &str = "FD";
const DASHBOARD_ENV: &str = "FLIGHTDECK_DASHBOARD";
const WINDOW_ENV: &str = "FLIGHTDECK_DASHBOARD_WINDOW";
const WINDOW_ICON_ENV: &str = "FLIGHTDECK_DASHBOARD_WINDOW_ICON";
const MOTION_ENV: &str = "FLIGHTDECK_DASHBOARD_MOTION";
const THEME_ENV: &str = "FLIGHTDECK_DASHBOARD_THEME";
const DAEMON_RUST_ENV: &str = "FLIGHTDECK_DAEMON_RUST";
const SESSION_BIN_ENV: &str = "FLIGHTDECK_SESSION_BIN";
const SKILL_DIR_ENV: &str = "FLIGHTDECK_SKILL_DIR";
const NO_MOTION_ENV: &str = "NO_MOTION";
const NO_COLOR_ENV: &str = "NO_COLOR";

struct DashboardLaunchLock {
    file: File,
    path: PathBuf,
}

impl DashboardLaunchLock {
    fn acquire(session_key: &str) -> Result<Self> {
        let state_dir = fd_resolve_state_dir();
        fs::create_dir_all(&state_dir).wrap_err_with(|| {
            format!(
                "failed to create dashboard launch lock directory {}",
                state_dir.display()
            )
        })?;
        let path = state_dir.join(format!("dashboard-launch-{session_key}.lock"));
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&path)
            .wrap_err_with(|| format!("failed to open dashboard launch lock {}", path.display()))?;
        file.lock_exclusive()
            .wrap_err_with(|| format!("failed to lock dashboard launch lock {}", path.display()))?;
        Ok(Self { file, path })
    }
}

impl Drop for DashboardLaunchLock {
    fn drop(&mut self) {
        if let Err(error) = fs2::FileExt::unlock(&self.file) {
            tracing::warn!(path = %self.path.display(), %error, "failed to unlock dashboard launch lock");
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct FocusOrLaunchReport {
    pub status: &'static str,
    pub reason: String,
    pub pane: Option<String>,
    pub window: Option<String>,
    pub stderr: Option<String>,
    pub path: Option<String>,
    pub command: Option<String>,
}

impl FocusOrLaunchReport {
    fn new(status: &'static str, reason: impl Into<String>) -> Self {
        Self {
            status,
            reason: reason.into(),
            pane: None,
            window: None,
            stderr: None,
            path: None,
            command: None,
        }
    }

    fn with_target(mut self, target: &DashboardTarget) -> Self {
        self.pane = Some(target.pane_id.clone());
        self.window = target.window_id.clone();
        self
    }

    fn with_probe_error(mut self, error: &DashboardProbeError) -> Self {
        self.stderr = error.stderr.clone();
        self.path = error.path.as_ref().map(|path| path.display().to_string());
        self.command = error.command.clone();
        self
    }

    fn with_probe(mut self, probe: &DashboardProbe) -> Self {
        match probe {
            DashboardProbe::Found(_) => {}
            DashboardProbe::Missing { path, .. } => {
                self.path = path.as_ref().map(|path| path.display().to_string());
            }
            DashboardProbe::Stale {
                path,
                command,
                stderr,
                ..
            } => {
                self.path = path.as_ref().map(|path| path.display().to_string());
                self.command = command.clone();
                self.stderr = stderr.clone();
            }
        }
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DashboardTarget {
    pane_id: String,
    window_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum DashboardProbe {
    Found(DashboardTarget),
    Missing {
        reason: String,
        path: Option<PathBuf>,
    },
    Stale {
        reason: String,
        path: Option<PathBuf>,
        command: Option<String>,
        stderr: Option<String>,
    },
}

impl DashboardProbe {
    fn reason(&self) -> &str {
        match self {
            Self::Found(_) => "found",
            Self::Missing { reason, .. } | Self::Stale { reason, .. } => reason,
        }
    }
}

fn merge_stderr(left: Option<String>, right: Option<String>) -> Option<String> {
    match (left, right) {
        (Some(left), Some(right)) if !left.is_empty() && !right.is_empty() => {
            Some(format!("{left}; {right}"))
        }
        (Some(left), _) if !left.is_empty() => Some(left),
        (_, Some(right)) if !right.is_empty() => Some(right),
        _ => None,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DashboardProbeError {
    reason: String,
    path: Option<PathBuf>,
    command: Option<String>,
    stderr: Option<String>,
}

impl DashboardProbeError {
    fn new(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
            path: None,
            command: None,
            stderr: None,
        }
    }

    fn path(mut self, path: &Path) -> Self {
        self.path = Some(path.to_path_buf());
        self
    }

    fn command(mut self, command: impl Into<String>) -> Self {
        self.command = Some(command.into());
        self
    }
}

impl std::fmt::Display for DashboardProbeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.reason)?;
        if let Some(path) = &self.path {
            write!(f, " path={}", path.display())?;
        }
        if let Some(command) = &self.command {
            write!(f, " command={command}")?;
        }
        if let Some(stderr) = &self.stderr {
            write!(f, " stderr={stderr}")?;
        }
        Ok(())
    }
}

impl std::error::Error for DashboardProbeError {}

pub async fn run(args: LaunchArgs) -> Result<()> {
    if dashboard_disabled() {
        return Ok(());
    }
    if std::env::var_os("TMUX").is_none() {
        eprintln!("flightdeck-dashboard: not in tmux; skipping launch");
        return Ok(());
    }

    let session = resolve_session(args.session.as_deref())
        .await
        .wrap_err("failed to resolve tmux session")?;
    let session_key = resolve_session_key(&session)
        .wrap_err_with(|| format!("failed to resolve session key for {session}"))?;
    let window_name = select_window_name(args.window_name.as_deref());
    let theme = select_theme(args.theme);
    let motion = select_motion(args.motion);
    let project_root = resolve_project_root();
    let explicit_state_file = args.state_file.as_deref().map(absolutize);
    let mut state_file =
        resolve_state_file(explicit_state_file.as_deref(), &session, &project_root);
    if explicit_state_file.is_none() {
        if let Some(ensured_state_file) = ensure_active_run_for_dashboard(&session, &project_root) {
            state_file = Some(ensured_state_file);
        }
    }
    let _launch_lock = DashboardLaunchLock::acquire(&session_key)?;
    let launch_plan = DashboardLaunchPlan {
        session: &session,
        session_key: &session_key,
        window_name: &window_name,
        after_window_id: args.after_window_id.as_deref(),
        theme,
        motion,
        explicit_state_file: explicit_state_file.as_deref(),
        state_file: state_file.as_deref(),
        project_root: &project_root,
        no_daemon: args.no_daemon,
        force: args.force,
    };

    launch_dashboard_locked(&launch_plan).await?;
    Ok(())
}

pub async fn run_focus_or_launch(args: FocusOrLaunchArgs) -> Result<()> {
    let report = focus_or_launch(&args).await;
    match &report {
        Ok(report) => emit_focus_report(report, args.json)?,
        Err(report) => {
            emit_focus_report(report, args.json)?;
            bail!(report.reason.clone());
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DashboardLaunchOutcome {
    AlreadyAlive,
    Launched,
}

struct DashboardLaunchPlan<'a> {
    session: &'a str,
    session_key: &'a str,
    window_name: &'a str,
    after_window_id: Option<&'a str>,
    theme: Option<ThemeArg>,
    motion: Option<MotionArg>,
    explicit_state_file: Option<&'a Path>,
    state_file: Option<&'a Path>,
    project_root: &'a Path,
    no_daemon: bool,
    force: bool,
}

async fn launch_dashboard_locked(plan: &DashboardLaunchPlan<'_>) -> Result<DashboardLaunchOutcome> {
    if !plan.force {
        match tracked_dashboard_alive(
            plan.state_file,
            plan.session,
            plan.project_root,
            plan.window_name,
        )
        .await
        {
            Ok(true) => {
                tracing::info!(
                    entry = DASHBOARD_ENTRY_ID,
                    "flightdeck dashboard entry already alive; launch skipped"
                );
                return Ok(DashboardLaunchOutcome::AlreadyAlive);
            }
            Ok(false) => {}
            Err(error) => bail!("dashboard tracked-entry probe failed: {error}"),
        }
        match tmux_window_exists(plan.window_name).await {
            Ok(true) => {
                bail!(
                    "dashboard window '{}' exists but no live tracked dashboard entry was verified; refusing duplicate launch",
                    plan.window_name
                );
            }
            Ok(false) => {}
            Err(error) => bail!("tmux window probe failed: {error}"),
        }
    }

    if !plan.no_daemon && rust_daemon_enabled() {
        start_daemon_if_needed(
            plan.session,
            plan.session_key,
            plan.explicit_state_file,
            plan.force,
        )
        .await;
    } else if plan.no_daemon {
        tracing::info!("flightdeck dashboard launch skipping daemon by --no-daemon");
    } else {
        tracing::info!(
            "flightdeck dashboard launch defers daemon to canonical TS flightdeck daemon"
        );
    }

    launch_window(
        plan.session,
        plan.window_name,
        plan.after_window_id,
        plan.theme,
        plan.motion,
        plan.explicit_state_file,
        plan.project_root,
    )
    .await?;
    let Some(path) = plan.state_file else {
        bail!("flightdeck dashboard launch could not resolve state file for verification");
    };
    if !tracked_dashboard_alive(
        Some(path),
        plan.session,
        plan.project_root,
        plan.window_name,
    )
    .await?
    {
        bail!(
            "flightdeck dashboard launch did not register a live tracked entry in {}",
            path.display()
        );
    }
    Ok(DashboardLaunchOutcome::Launched)
}

async fn focus_or_launch(
    args: &FocusOrLaunchArgs,
) -> std::result::Result<FocusOrLaunchReport, FocusOrLaunchReport> {
    if dashboard_disabled() {
        return Err(FocusOrLaunchReport::new(
            "blocked",
            format!("{DASHBOARD_ENV}=0; dashboard launch disabled"),
        ));
    }
    if std::env::var_os("TMUX").is_none() {
        return Err(FocusOrLaunchReport::new(
            "blocked",
            "not in tmux; run /flightdeck from inside the Flightdeck tmux session",
        ));
    }

    let session = match resolve_session(args.session.as_deref()).await {
        Ok(session) => session,
        Err(error) => {
            return Err(FocusOrLaunchReport::new(
                "error",
                format!("failed to resolve tmux session: {error}"),
            ))
        }
    };
    let session_key = match resolve_session_key(&session) {
        Ok(session_key) => session_key,
        Err(error) => {
            return Err(FocusOrLaunchReport::new(
                "error",
                format!("failed to resolve tmux session key: {error}"),
            ))
        }
    };
    let project_root = resolve_project_root();
    let window_name = select_window_name(args.window_name.as_deref());
    let explicit_state_file = args.state_file.as_deref().map(absolutize);
    let mut state_file =
        resolve_state_file(explicit_state_file.as_deref(), &session, &project_root);
    if explicit_state_file.is_none() {
        if let Some(ensured_state_file) = ensure_active_run_for_dashboard(&session, &project_root) {
            state_file = Some(ensured_state_file);
        }
    }
    let _launch_lock = match DashboardLaunchLock::acquire(&session_key) {
        Ok(lock) => lock,
        Err(error) => {
            return Err(FocusOrLaunchReport::new(
                "error",
                format!("dashboard launch lock failed: {error}"),
            ))
        }
    };

    let mut initial_stale_probe: Option<DashboardProbe> = None;
    match dashboard_target(state_file.as_deref(), &session, &project_root, &window_name).await {
        Ok(DashboardProbe::Found(target)) => match focus_dashboard_target(&target).await {
            Ok(()) => {
                return Ok(
                    FocusOrLaunchReport::new("focused", "existing dashboard app focused")
                        .with_target(&target),
                );
            }
            Err(error) => {
                return Err(FocusOrLaunchReport::new(
                    "error",
                    format!("failed to focus dashboard app: {error}"),
                )
                .with_target(&target)
                .with_probe_error(&DashboardProbeError::new(error.to_string())));
            }
        },
        Ok(DashboardProbe::Missing { .. }) => {}
        Ok(probe @ DashboardProbe::Stale { .. }) => {
            initial_stale_probe = Some(probe);
        }
        Err(error) => {
            return Err(FocusOrLaunchReport::new(
                "error",
                format!("dashboard target probe failed: {error}"),
            )
            .with_probe_error(&error));
        }
    }

    let launch_plan = DashboardLaunchPlan {
        session: &session,
        session_key: &session_key,
        window_name: &window_name,
        after_window_id: args.after_window_id.as_deref(),
        theme: args.theme,
        motion: args.motion,
        explicit_state_file: explicit_state_file.as_deref(),
        state_file: state_file.as_deref(),
        project_root: &project_root,
        no_daemon: args.no_daemon,
        force: args.force,
    };
    let launch_outcome = match launch_dashboard_locked(&launch_plan).await {
        Ok(outcome) => outcome,
        Err(error) => {
            let launch_error = error.to_string();
            let mut report =
                FocusOrLaunchReport::new("error", format!("dashboard app launch failed: {error}"));
            report.stderr = Some(launch_error.clone());
            if let Some(probe) = &initial_stale_probe {
                report.reason = format!(
                    "dashboard app launch failed after stale tracked-entry probe ({}): {error}",
                    probe.reason()
                );
                report = report.with_probe(probe);
                let stale_stderr = report.stderr.take();
                report.stderr =
                    merge_stderr(stale_stderr, Some(format!("launch error: {launch_error}")));
            }
            return Err(report);
        }
    };

    match dashboard_target(state_file.as_deref(), &session, &project_root, &window_name).await {
        Ok(DashboardProbe::Found(target)) => match focus_dashboard_target(&target).await {
            Ok(()) => {
                let report = match launch_outcome {
                    DashboardLaunchOutcome::AlreadyAlive => FocusOrLaunchReport::new(
                        "focused",
                        "dashboard app became available while waiting for launch lock",
                    ),
                    DashboardLaunchOutcome::Launched => {
                        FocusOrLaunchReport::new("launched", "dashboard app launched and focused")
                    }
                }
                .with_target(&target);
                Ok(report)
            }
            Err(error) => Err(FocusOrLaunchReport::new(
                "error",
                format!("dashboard app launched but focus failed: {error}"),
            )
            .with_target(&target)
            .with_probe_error(&DashboardProbeError::new(error.to_string()))),
        },
        Ok(probe) => Err(FocusOrLaunchReport::new(
            "error",
            format!(
                "dashboard app launch finished but no live tracked pane was found: {}",
                probe.reason()
            ),
        )
        .with_probe(&probe)),
        Err(error) => Err(FocusOrLaunchReport::new(
            "error",
            format!("dashboard app launch finished but target probe failed: {error}"),
        )
        .with_probe_error(&error)),
    }
}

fn focus_report_detail_suffix(report: &FocusOrLaunchReport) -> String {
    let mut suffix = String::new();
    if let Some(path) = report.path.as_deref() {
        let _ = write!(suffix, " path={path}");
    }
    if let Some(command) = report.command.as_deref() {
        let _ = write!(suffix, " command={command}");
    }
    if let Some(stderr) = report.stderr.as_deref() {
        let _ = write!(suffix, " stderr={stderr}");
    }
    suffix
}

fn emit_focus_report(report: &FocusOrLaunchReport, json: bool) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string(report)?);
    } else if matches!(report.status, "focused" | "launched") {
        println!(
            "flightdeck-dashboard: {} ({}){}{}",
            report.status,
            report.reason,
            report
                .window
                .as_deref()
                .map(|window| format!(" window={window}"))
                .unwrap_or_default(),
            report
                .pane
                .as_deref()
                .map(|pane| format!(" pane={pane}"))
                .unwrap_or_default()
        );
    } else {
        eprintln!(
            "flightdeck-dashboard: {}: {}{}",
            report.status,
            report.reason,
            focus_report_detail_suffix(report)
        );
    }
    Ok(())
}

fn dashboard_disabled() -> bool {
    std::env::var(DASHBOARD_ENV).is_ok_and(|value| value.trim() == "0")
}

fn rust_daemon_enabled() -> bool {
    std::env::var(DAEMON_RUST_ENV).is_ok_and(|value| value.trim() == "1")
}

fn select_window_name(cli: Option<&str>) -> String {
    cli.map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .or_else(|| {
            std::env::var(WINDOW_ENV)
                .ok()
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
        })
        .unwrap_or_else(default_window_name)
}

fn default_window_name() -> String {
    if std::env::var(WINDOW_ICON_ENV).is_ok_and(|value| value.trim() == "0") {
        DEFAULT_WINDOW_NAME_PLAIN.to_owned()
    } else {
        DEFAULT_WINDOW_NAME.to_owned()
    }
}

fn select_theme(cli: Option<ThemeArg>) -> Option<ThemeArg> {
    cli.or_else(|| {
        std::env::var(THEME_ENV)
            .ok()
            .and_then(|value| theme_from_str(value.trim()))
    })
}

fn theme_from_str(value: &str) -> Option<ThemeArg> {
    if value.eq_ignore_ascii_case("moon") {
        Some(ThemeArg::Moon)
    } else if value.eq_ignore_ascii_case("dawn") {
        Some(ThemeArg::Dawn)
    } else if value.eq_ignore_ascii_case("pantera") {
        Some(ThemeArg::Pantera)
    } else if value.eq_ignore_ascii_case("system") {
        Some(ThemeArg::System)
    } else {
        None
    }
}

fn select_motion(cli: Option<MotionArg>) -> Option<MotionArg> {
    cli.or_else(|| {
        (std::env::var_os(NO_MOTION_ENV).is_some() || std::env::var_os(NO_COLOR_ENV).is_some())
            .then_some(MotionArg::Off)
    })
    .or_else(|| {
        std::env::var(MOTION_ENV)
            .ok()
            .and_then(|value| motion_from_str(value.trim()))
    })
}

fn motion_from_str(value: &str) -> Option<MotionArg> {
    if value.eq_ignore_ascii_case("full") {
        Some(MotionArg::Full)
    } else if value.eq_ignore_ascii_case("reduced") {
        Some(MotionArg::Reduced)
    } else if value.eq_ignore_ascii_case("off") {
        Some(MotionArg::Off)
    } else {
        None
    }
}

async fn resolve_session(explicit: Option<&str>) -> Result<String> {
    if let Some(session) = explicit
        .map(str::trim)
        .filter(|session| !session.is_empty())
    {
        return Ok(session.to_owned());
    }
    let output = Command::new("tmux")
        .args(["display-message", "-p", "#S"])
        .output()
        .await?;
    if !output.status.success() {
        color_eyre::eyre::bail!("tmux display-message failed with status {}", output.status);
    }
    let session = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if session.is_empty() {
        color_eyre::eyre::bail!("tmux display-message returned empty session");
    }
    Ok(session)
}

fn resolve_project_root() -> PathBuf {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    tracked_entries::resolve_project_root(&cwd).unwrap_or(cwd)
}

fn resolve_state_file(cli: Option<&Path>, session: &str, project_root: &Path) -> Option<PathBuf> {
    if let Some(path) = cli {
        return Some(path.to_path_buf());
    }
    tracked_entries::resolve_session_state_from(project_root, session)
        .ok()
        .map(|resolution| resolution.state_path)
}

fn absolutize(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    }
}

async fn start_daemon_if_needed(
    session: &str,
    session_key: &str,
    state_file: Option<&Path>,
    force: bool,
) {
    let state_dir = fd_resolve_state_dir();
    if !force {
        if let Some(pid) = read_pid(&state_dir, session_key).filter(|pid| pid_alive(*pid)) {
            tracing::info!(
                pid,
                session_key,
                "flightdeck dashboard daemon already running"
            );
            return;
        }
    }

    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(error) => {
            warn(format!("failed to resolve dashboard executable: {error}"));
            return;
        }
    };
    let mut command = Command::new(exe);
    command.args(["daemon", "start", "--detach", "--session", session]);
    if let Some(path) = state_file {
        command.arg("--state-file").arg(path);
    }
    command.stdout(Stdio::null()).stderr(Stdio::piped());
    match command.output().await {
        Ok(output) if output.status.success() => {
            tracing::info!(session, "flightdeck dashboard daemon started")
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            warn(format!(
                "dashboard daemon start failed with status {}: {}",
                output.status,
                stderr.trim()
            ));
        }
        Err(error) => warn(format!("failed to spawn dashboard daemon: {error}")),
    }
}

fn ensure_active_run_for_dashboard(session: &str, project_root: &Path) -> Option<PathBuf> {
    match run_history::ensure_active_state_path(project_root, session) {
        Ok(path) => Some(path),
        Err(error) => {
            warn(format!(
                "active-run stale check skipped before dashboard launch/focus: {error}"
            ));
            None
        }
    }
}

async fn tracked_dashboard_alive(
    state_file: Option<&Path>,
    session: &str,
    project_root: &Path,
    expected_window_name: &str,
) -> Result<bool> {
    match dashboard_target(state_file, session, project_root, expected_window_name).await? {
        DashboardProbe::Found(_) => Ok(true),
        DashboardProbe::Missing { .. } | DashboardProbe::Stale { .. } => Ok(false),
    }
}

async fn dashboard_target(
    state_file: Option<&Path>,
    session: &str,
    project_root: &Path,
    expected_window_name: &str,
) -> std::result::Result<DashboardProbe, DashboardProbeError> {
    let Some(path) = state_file else {
        return Ok(DashboardProbe::Missing {
            reason: "state file could not be resolved".to_owned(),
            path: None,
        });
    };
    let body = match fs::read_to_string(path) {
        Ok(body) => body,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(DashboardProbe::Missing {
                reason: "state file does not exist".to_owned(),
                path: Some(path.to_path_buf()),
            });
        }
        Err(error) => {
            return Err(DashboardProbeError::new(format!(
                "failed to read dashboard state file: {error}"
            ))
            .path(path));
        }
    };
    let value = serde_json::from_str::<Value>(&body).map_err(|error| {
        DashboardProbeError::new(format!("failed to parse dashboard state JSON: {error}"))
            .path(path)
    })?;
    let Some(entry) = value.pointer(&format!("/entries/{DASHBOARD_ENTRY_ID}")) else {
        return Ok(DashboardProbe::Missing {
            reason: "dashboard entry missing from state file".to_owned(),
            path: Some(path.to_path_buf()),
        });
    };
    validate_dashboard_entry_metadata(entry, path)?;
    let Some(pane_id) = entry
        .get("pane_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|pane| !pane.is_empty())
    else {
        return Ok(DashboardProbe::Missing {
            reason: "dashboard entry has no pane_id".to_owned(),
            path: Some(path.to_path_buf()),
        });
    };
    tmux_pane_target(
        entry,
        pane_id,
        session,
        project_root,
        expected_window_name,
        path,
    )
    .await
}

fn validate_dashboard_entry_metadata(
    entry: &Value,
    path: &Path,
) -> std::result::Result<(), DashboardProbeError> {
    if let Some(id) = entry.get("id").and_then(Value::as_str) {
        if id != DASHBOARD_ENTRY_ID {
            return Err(DashboardProbeError::new(format!(
                "dashboard entry id mismatch: expected {DASHBOARD_ENTRY_ID}, found {id}"
            ))
            .path(path));
        }
    }
    if let Some(harness) = entry.get("harness").and_then(Value::as_str) {
        if harness != "shell" {
            return Err(DashboardProbeError::new(format!(
                "dashboard entry harness mismatch: expected shell, found {harness}"
            ))
            .path(path));
        }
    }
    if let Some(kind) = entry.get("kind").and_then(Value::as_str) {
        if kind != "workflow" {
            return Err(DashboardProbeError::new(format!(
                "dashboard entry kind mismatch: expected workflow, found {kind}"
            ))
            .path(path));
        }
    }
    if let Some(cmd) = entry
        .pointer("/launch/cmd")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|cmd| !cmd.is_empty())
    {
        if !(cmd.contains("flightdeck-dashboard") && cmd.contains("tui")) {
            return Err(DashboardProbeError::new(
                "dashboard entry launch command does not look like flightdeck-dashboard tui",
            )
            .path(path));
        }
    }
    Ok(())
}

async fn tmux_pane_target(
    entry: &Value,
    pane_id: &str,
    expected_session: &str,
    project_root: &Path,
    expected_window_name: &str,
    state_path: &Path,
) -> std::result::Result<DashboardProbe, DashboardProbeError> {
    let command = format!(
        "tmux display-message -p -t {pane_id} '#{{pane_id}}\\t#{{window_id}}\\t#{{session_name}}\\t#{{window_name}}\\t#{{pane_current_path}}'"
    );
    let output = Command::new("tmux")
        .args([
            "display-message",
            "-p",
            "-t",
            pane_id,
            "#{pane_id}\t#{window_id}\t#{session_name}\t#{window_name}\t#{pane_current_path}",
        ])
        .output()
        .await
        .map_err(|error| {
            DashboardProbeError::new(format!("failed to run tmux display-message: {error}"))
                .path(state_path)
                .command(command.clone())
        })?;
    if !output.status.success() {
        return Ok(DashboardProbe::Stale {
            reason: format!("tracked dashboard pane {pane_id} is not live"),
            path: Some(state_path.to_path_buf()),
            command: Some(command),
            stderr: stderr_string(&output.stderr),
        });
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut fields = stdout.trim_end().splitn(5, '\t');
    let resolved_pane = fields.next().unwrap_or_default().trim();
    let resolved_window = fields.next().unwrap_or_default().trim();
    let resolved_session = fields.next().unwrap_or_default().trim();
    let resolved_window_name = fields.next().unwrap_or_default().trim();
    let resolved_cwd = fields.next().unwrap_or_default().trim();

    if resolved_pane != pane_id {
        return Err(DashboardProbeError::new(format!(
            "dashboard pane identity mismatch: state has {pane_id}, tmux resolved {resolved_pane}"
        ))
        .path(state_path)
        .command(command));
    }
    if !resolved_session.is_empty() && resolved_session != expected_session {
        return Err(DashboardProbeError::new(format!(
            "dashboard pane session mismatch: expected {expected_session}, found {resolved_session}"
        ))
        .path(state_path)
        .command(command));
    }
    if let Some(hinted_window) = entry
        .get("window_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|window| !window.is_empty())
    {
        if resolved_window.is_empty() {
            return Err(DashboardProbeError::new(format!(
                "dashboard pane window mismatch: state has {hinted_window}, tmux resolved no window id"
            ))
            .path(state_path)
            .command(command));
        }
        if resolved_window != hinted_window {
            return Err(DashboardProbeError::new(format!(
                "dashboard pane window mismatch: state has {hinted_window}, tmux resolved {resolved_window}"
            ))
            .path(state_path)
            .command(command));
        }
    } else if !resolved_window_name.is_empty() {
        let expected_title = entry
            .get("title")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|title| !title.is_empty())
            .unwrap_or(expected_window_name);
        if !expected_title.is_empty() && resolved_window_name != expected_title {
            return Err(DashboardProbeError::new(format!(
                "dashboard pane window name mismatch: expected {expected_title}, found {resolved_window_name}"
            ))
            .path(state_path)
            .command(command));
        }
    }
    if let Some(entry_cwd) = entry
        .get("cwd")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|cwd| !cwd.is_empty())
    {
        if !resolved_cwd.is_empty()
            && !paths_equivalent(Path::new(entry_cwd), Path::new(resolved_cwd))
        {
            return Err(DashboardProbeError::new(format!(
                "dashboard pane cwd mismatch: state has {entry_cwd}, tmux resolved {resolved_cwd}"
            ))
            .path(state_path)
            .command(command));
        }
    } else if !resolved_cwd.is_empty() && !paths_equivalent(project_root, Path::new(resolved_cwd)) {
        return Err(DashboardProbeError::new(format!(
            "dashboard pane cwd mismatch: expected project root {}, tmux resolved {resolved_cwd}",
            project_root.display()
        ))
        .path(state_path)
        .command(command));
    }

    Ok(DashboardProbe::Found(DashboardTarget {
        pane_id: pane_id.to_owned(),
        window_id: (!resolved_window.is_empty()).then(|| resolved_window.to_owned()),
    }))
}

fn paths_equivalent(expected: &Path, actual: &Path) -> bool {
    if expected == actual {
        return true;
    }
    match (expected.canonicalize(), actual.canonicalize()) {
        (Ok(expected), Ok(actual)) => expected == actual,
        _ => false,
    }
}

fn stderr_string(stderr: &[u8]) -> Option<String> {
    let stderr = String::from_utf8_lossy(stderr).trim().to_owned();
    (!stderr.is_empty()).then_some(stderr)
}

async fn focus_dashboard_target(target: &DashboardTarget) -> Result<()> {
    if let Some(window_id) = target.window_id.as_deref() {
        let output = Command::new("tmux")
            .args(["select-window", "-t", window_id])
            .output()
            .await?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            bail!(
                "tmux select-window failed with status {}: {}",
                output.status,
                stderr.trim()
            );
        }
    }
    let output = Command::new("tmux")
        .args(["select-pane", "-t", target.pane_id.as_str()])
        .output()
        .await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!(
            "tmux select-pane failed with status {}: {}",
            output.status,
            stderr.trim()
        );
    }
    Ok(())
}

async fn tmux_window_exists(window_name: &str) -> Result<bool> {
    let output = Command::new("tmux")
        .args(["list-windows", "-F", "#{window_name}"])
        .output()
        .await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        color_eyre::eyre::bail!(
            "tmux list-windows failed with status {}: {}",
            output.status,
            stderr.trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|line| line.trim() == window_name))
}

async fn launch_window(
    session: &str,
    window_name: &str,
    after_window_id: Option<&str>,
    theme: Option<ThemeArg>,
    motion: Option<MotionArg>,
    state_file: Option<&Path>,
    project_root: &Path,
) -> Result<()> {
    let Some(session_bin) = resolve_flightdeck_session_bin(project_root) else {
        bail!("flightdeck-session not found; dashboard window not launched");
    };
    let cmd = tui_command(session, theme, motion, state_file);
    let mut command = Command::new(session_bin);
    command.args([
        "start",
        "--session-id",
        DASHBOARD_ENTRY_ID,
        "--title",
        window_name,
        "--cwd",
    ]);
    command.arg(project_root);
    command.args(["--harness", "shell", "--kind", "workflow", "--cmd"]);
    command.arg(cmd);
    command.arg("--no-active-run");
    if let Some(window_id) = after_window_id.filter(|value| !value.trim().is_empty()) {
        command.args(["--after-window-id", window_id.trim()]);
    }
    command.env("FLIGHTDECK_DASHBOARD_LAUNCHING", "1");
    command.env("FLIGHTDECK_SKIP_ACTIVE_RUN", "1");
    command.env("FLIGHTDECK_NO_ACTIVE_RUN", "1");
    command.stdout(Stdio::null()).stderr(Stdio::piped());
    match command.output().await {
        Ok(output) if output.status.success() => {
            tracing::info!(window = %window_name, "flightdeck dashboard window launched");
            Ok(())
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            bail!(
                "flightdeck-session start failed with status {}: {}",
                output.status,
                stderr.trim()
            )
        }
        Err(error) => bail!("failed to spawn flightdeck-session: {error}"),
    }
}

fn resolve_flightdeck_session_bin(project_root: &Path) -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(SESSION_BIN_ENV).map(PathBuf::from) {
        if path.is_file() {
            return Some(path);
        }
    }
    if let Some(path) = std::env::var_os(SKILL_DIR_ENV)
        .map(PathBuf::from)
        .map(|skill_dir| skill_dir.join("scripts/flightdeck-session"))
    {
        if path.is_file() {
            return Some(path);
        }
    }
    let canonical = project_root.join("skills/flightdeck/scripts/flightdeck-session");
    if canonical.is_file() {
        return Some(canonical);
    }
    let installed = project_root.join(".agents/skills/flightdeck/scripts/flightdeck-session");
    if installed.is_file() {
        return Some(installed);
    }
    which("flightdeck-session")
}

fn tui_command(
    session: &str,
    theme: Option<ThemeArg>,
    motion: Option<MotionArg>,
    state_file: Option<&Path>,
) -> String {
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("flightdeck-dashboard"));
    let mut args = vec![exe.display().to_string(), "tui".to_owned()];
    if let Some(path) = state_file {
        args.push("--state-file".to_owned());
        args.push(path.display().to_string());
    } else {
        args.push("--session".to_owned());
        args.push(session.to_owned());
    }
    if let Some(theme) = theme {
        args.push("--theme".to_owned());
        args.push(theme.as_str().to_owned());
    }
    if let Some(motion) = motion {
        args.push("--motion".to_owned());
        args.push(motion.as_str().to_owned());
    }
    args.into_iter()
        .map(|arg| shell_quote(&arg))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_quote(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '_' | '-' | ':' | '='))
    {
        return value.to_owned();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn which(bin: &str) -> Option<PathBuf> {
    let output = std::process::Command::new("bash")
        .args(["-lc", &format!("command -v {}", shell_quote(bin))])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (!path.is_empty()).then(|| PathBuf::from(path))
}

fn warn(message: String) {
    tracing::warn!(%message, "flightdeck dashboard launch warning");
    eprintln!("flightdeck-dashboard: warning: {message}");
}
