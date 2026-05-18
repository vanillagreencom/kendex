use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use color_eyre::eyre::{bail, Result, WrapErr};
use serde_json::Value;
use tokio::process::Command;

use crate::cli::{LaunchArgs, MotionArg, ThemeArg};
use crate::daemon::lifecycle::{pid_alive, read_pid};
use crate::state::tracked_entries;
use crate::util::paths::{fd_resolve_state_dir, resolve_session_key};

const DASHBOARD_ENTRY_ID: &str = "flightdeck-dashboard";
const DEFAULT_WINDOW_NAME: &str = "flightdeck";
const DASHBOARD_ENV: &str = "FLIGHTDECK_DASHBOARD";
const WINDOW_ENV: &str = "FLIGHTDECK_DASHBOARD_WINDOW";
const MOTION_ENV: &str = "FLIGHTDECK_DASHBOARD_MOTION";
const THEME_ENV: &str = "FLIGHTDECK_DASHBOARD_THEME";
const DAEMON_RUST_ENV: &str = "FLIGHTDECK_DAEMON_RUST";
const SESSION_BIN_ENV: &str = "FLIGHTDECK_SESSION_BIN";
const SKILL_DIR_ENV: &str = "FLIGHTDECK_SKILL_DIR";
const NO_MOTION_ENV: &str = "NO_MOTION";
const NO_COLOR_ENV: &str = "NO_COLOR";

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
    let state_file = resolve_state_file(explicit_state_file.as_deref(), &session, &project_root);

    if !args.force {
        match tracked_dashboard_alive(state_file.as_deref()).await {
            Ok(true) => {
                tracing::info!(
                    entry = DASHBOARD_ENTRY_ID,
                    "flightdeck dashboard entry already alive; launch skipped"
                );
                return Ok(());
            }
            Ok(false) => {}
            Err(error) => {
                warn(format!(
                    "tmux tracked-entry probe failed; attempting dashboard launch anyway: {error}"
                ));
            }
        }
        match tmux_window_exists(&window_name).await {
            Ok(true) => {
                warn(format!(
                    "dashboard window '{window_name}' exists but no live tracked dashboard entry was verified; launching a tracked dashboard anyway"
                ));
            }
            Ok(false) => {}
            Err(error) => {
                warn(format!(
                    "tmux window probe failed; attempting dashboard launch anyway: {error}"
                ));
            }
        }
    }

    let daemon_state_file = explicit_state_file.clone();

    if !args.no_daemon && rust_daemon_enabled() {
        start_daemon_if_needed(
            &session,
            &session_key,
            daemon_state_file.as_deref(),
            args.force,
        )
        .await;
    } else if args.no_daemon {
        tracing::info!("flightdeck dashboard launch skipping daemon by --no-daemon");
    } else {
        tracing::info!(
            "flightdeck dashboard launch defers daemon to canonical TS flightdeck daemon"
        );
    }

    launch_window(
        &session,
        &window_name,
        theme,
        motion,
        explicit_state_file.as_deref(),
        &project_root,
    )
    .await?;
    let Some(path) = state_file.as_deref() else {
        bail!("flightdeck dashboard launch could not resolve state file for verification");
    };
    if !tracked_dashboard_alive(Some(path)).await? {
        bail!(
            "flightdeck dashboard launch did not register a live tracked entry in {}",
            path.display()
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
        .unwrap_or_else(|| DEFAULT_WINDOW_NAME.to_owned())
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

async fn tracked_dashboard_alive(state_file: Option<&Path>) -> Result<bool> {
    let Some(path) = state_file else {
        return Ok(false);
    };
    let Ok(body) = fs::read_to_string(path) else {
        return Ok(false);
    };
    let Ok(value) = serde_json::from_str::<Value>(&body) else {
        return Ok(false);
    };
    let pane_id = value
        .pointer(&format!("/entries/{DASHBOARD_ENTRY_ID}/pane_id"))
        .and_then(Value::as_str)
        .filter(|pane| !pane.is_empty());
    let Some(pane_id) = pane_id else {
        return Ok(false);
    };
    tmux_pane_alive(pane_id).await
}

async fn tmux_pane_alive(pane_id: &str) -> Result<bool> {
    let output = Command::new("tmux")
        .args(["list-panes", "-a", "-F", "#{pane_id}"])
        .output()
        .await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        color_eyre::eyre::bail!(
            "tmux list-panes failed with status {}: {}",
            output.status,
            stderr.trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|line| line.trim() == pane_id))
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
