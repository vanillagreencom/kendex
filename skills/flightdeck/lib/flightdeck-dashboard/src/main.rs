mod terminal_guard;

use std::io::{self, IsTerminal, Stdout};
use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::Parser;
use color_eyre::eyre::Result;
use crossterm::event::{Event, EventStream, KeyEventKind, MouseButton, MouseEventKind};
use flightdeck_dashboard::app::command::{RunSnapshotSource, SnapshotSource};
use flightdeck_dashboard::app::effects::Effects;
use flightdeck_dashboard::app::hitmap::{ClickAction, HitMap};
use flightdeck_dashboard::app::model::{utc_now, Model, ReadSourceState};
use flightdeck_dashboard::app::motion::{self, MotionLevel};
use flightdeck_dashboard::app::msg::Msg;
use flightdeck_dashboard::app::theme::Theme;
use flightdeck_dashboard::app::{update, view};
use flightdeck_dashboard::cli::{
    Cli, Command, DaemonAction, DaemonArgs, MotionArg, ThemeArg, TuiArgs,
};
use flightdeck_dashboard::cost::CostAggregator;
use flightdeck_dashboard::daemon::client::DaemonClient;
use flightdeck_dashboard::daemon::rpc::DaemonStatus as RuntimeDaemonStatus;
use flightdeck_dashboard::events::{self, EventSource};
use flightdeck_dashboard::fixtures;
use flightdeck_dashboard::settings_catalog::{self, SettingsState};
use flightdeck_dashboard::state::run_history::{self, LoadedRunSnapshot};
use flightdeck_dashboard::state::snapshot::{
    DaemonStatus as SnapshotDaemonStatus, DashboardSnapshot,
};
use flightdeck_dashboard::state::tracked_entries::{self, SnapshotError};
use flightdeck_dashboard::util::logging;
use flightdeck_dashboard::util::paths::{
    dashboard_socket_file, fd_resolve_state_dir, resolve_session_key,
};
use flightdeck_dashboard::watcher::{StateWatcher, WatcherEvent};
use futures::StreamExt;
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;
use terminal_guard::TerminalGuard;
use tokio::sync::mpsc;
use tokio::time::{timeout, MissedTickBehavior};

const ANIMATION_TICK_MS: u64 = 80;
const CLOCK_TICK_MS: u64 = 1_000;
const WATCH_DEBOUNCE_MS: u64 = 150;
const DEFAULT_COST_POLL_SECS: u64 = 5;

fn main() -> Result<()> {
    color_eyre::install()?;
    let cli = Cli::parse();
    let settings_project_root = settings_catalog::resolve_project_root();
    let ambient_settings = settings_catalog::capture_ambient_env();
    // Keep env mutation before logging/runtime setup. `init_file_logging` starts
    // a tracing appender worker thread, and `env::set_var` is only safe here
    // while the process is still single-threaded.
    let settings_error = match &settings_project_root {
        Ok(project_root) => settings_catalog::apply_project_overrides_pre_runtime(project_root)
            .err()
            .map(|error| error.to_string()),
        Err(error) => Some(error.to_string()),
    };
    let _log_guard = logging::init_file_logging()?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async move {
        match cli.command {
            Command::Tui(args) => {
                run_tui(
                    args,
                    settings_project_root,
                    ambient_settings,
                    settings_error,
                )
                .await
            }
            Command::Daemon(args) => {
                warn_settings_error(settings_error);
                flightdeck_dashboard::daemon::cli::run_daemon(args).await
            }
            Command::Status(args) => {
                warn_settings_error(settings_error);
                flightdeck_dashboard::daemon::cli::run_daemon(DaemonArgs {
                    action: DaemonAction::Status(args),
                })
                .await
            }
            Command::Supervise(args) => {
                warn_settings_error(settings_error);
                flightdeck_dashboard::daemon::cli::run_supervise(args).await
            }
            Command::Launch(args) => {
                warn_settings_error(settings_error);
                flightdeck_dashboard::launch::run(args).await
            }
            Command::FocusOrLaunch(args) => {
                warn_settings_error(settings_error);
                flightdeck_dashboard::launch::run_focus_or_launch(args).await
            }
        }
    })
}

fn warn_settings_error(error: Option<String>) {
    if let Some(error) = error {
        eprintln!("Warning: {error}");
    }
}

async fn run_tui(
    args: TuiArgs,
    settings_project_root: Result<PathBuf, settings_catalog::SettingsError>,
    ambient_settings: std::collections::BTreeMap<String, String>,
    settings_error: Option<String>,
) -> Result<()> {
    let mut initial = initial_snapshot(&args).await?;
    if !matches!(initial.source, SnapshotSource::Socket(_)) {
        initial.snapshot.daemon = file_mode_daemon_status_for(&initial.source_state);
    }
    let theme = theme_choice(args.theme);
    let settings = SettingsState::load_from_root_result(settings_project_root, ambient_settings);
    let settings_error = settings_error.or_else(|| settings.last_error.clone());
    tracing::info!(source = ?initial.source, theme = theme.as_str(), "dashboard read mode selected");
    let mut model = Model::new_with_settings(
        initial.snapshot,
        initial.source,
        motion_level(&args),
        theme,
        settings,
        utc_now,
    );
    model.read_source_state = initial.source_state;
    model.sync_activity_source();
    model.poll_activity_source();
    if let Some(error) = initial.status_error {
        model.error = Some(error);
    }
    let settings_error_for_stderr = settings_error.clone();
    if let Some(error) = settings_error {
        model.status_message = Some(flightdeck_dashboard::app::model::ActionStatus {
            message: format!("settings override ignored: {error}"),
            success: false,
        });
    }
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        if let Some(error) = settings_error_for_stderr {
            eprintln!("Warning: settings override ignored: {error}");
        }
        tracing::info!(
            source = ?model.snapshot_source,
            entries = model.snapshot.sessions.len(),
            "non-terminal dashboard smoke render skipped"
        );
        return Ok(());
    }

    let mut terminal = TerminalGuard::enter()?;
    run_app_loop(terminal.terminal_mut()?, &mut model).await
}

struct InitialSnapshot {
    snapshot: DashboardSnapshot,
    source: SnapshotSource,
    source_state: ReadSourceState,
    status_error: Option<String>,
}

async fn initial_socket_snapshot(path: &Path) -> Result<InitialSnapshot> {
    let mut client = DaemonClient::connect(path).await?;
    let mut snapshot = client.get_snapshot().await?;
    let status_error = match client.get_status().await {
        Ok(status) => {
            snapshot.daemon = runtime_daemon_status_chip(&status);
            None
        }
        Err(error) => {
            snapshot.daemon = SnapshotDaemonStatus {
                label: String::from("daemon: socket"),
                healthy: None,
                pid: None,
                last_heartbeat_at: None,
            };
            Some(error.to_string())
        }
    };
    Ok(InitialSnapshot {
        snapshot,
        source: SnapshotSource::Socket(path.to_path_buf()),
        source_state: ReadSourceState::ActiveRun { run_id: None },
        status_error,
    })
}

async fn discover_socket_snapshot_for_session(session: &str) -> Option<InitialSnapshot> {
    let session_key = match resolve_session_key(session) {
        Ok(session_key) => session_key,
        Err(error) => {
            tracing::debug!(%error, "dashboard socket discovery skipped");
            return None;
        }
    };
    let socket = dashboard_socket_file(&fd_resolve_state_dir(), &session_key);
    if !socket.exists() {
        return None;
    }
    match timeout(Duration::from_millis(50), initial_socket_snapshot(&socket)).await {
        Ok(Ok(snapshot)) => Some(snapshot),
        Ok(Err(error)) => {
            tracing::debug!(path = %socket.display(), %error, "dashboard socket discovery failed");
            None
        }
        Err(_) => {
            tracing::debug!(path = %socket.display(), "dashboard socket discovery timed out");
            None
        }
    }
}

fn theme_choice(cli: Option<ThemeArg>) -> Theme {
    let env_theme = std::env::var("FLIGHTDECK_DASHBOARD_THEME").ok();
    Theme::from_cli_or_env(cli.map(ThemeArg::as_str), env_theme.as_deref())
}

fn motion_level(args: &TuiArgs) -> MotionLevel {
    match args.motion {
        Some(MotionArg::Full) => MotionLevel::Full,
        Some(MotionArg::Reduced) => MotionLevel::Reduced,
        Some(MotionArg::Off) => MotionLevel::Off,
        None => MotionLevel::from_env(),
    }
}

fn file_mode_daemon_status_for(source_state: &ReadSourceState) -> SnapshotDaemonStatus {
    let label = match source_state {
        ReadSourceState::Demo => "state: demo",
        ReadSourceState::LiveFile | ReadSourceState::ActiveRun { .. } => "state: live file",
        ReadSourceState::NoActiveRun => "state: no active run",
        ReadSourceState::ArchivedRun { .. } => "state: history archive",
        ReadSourceState::ImportedArchive { .. } => "state: imported archive",
        ReadSourceState::LegacyArchive { .. } => "state: legacy archive",
    };
    SnapshotDaemonStatus {
        label: String::from(label),
        healthy: Some(true),
        pid: None,
        last_heartbeat_at: None,
    }
}

fn cost_poll_secs() -> u64 {
    std::env::var("FLIGHTDECK_DASHBOARD_COST_POLL_SECS")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_COST_POLL_SECS)
}

fn runtime_daemon_status_chip(status: &RuntimeDaemonStatus) -> SnapshotDaemonStatus {
    let label = if status.running {
        status.pid.map_or_else(
            || String::from("daemon: rust"),
            |pid| format!("daemon: rust pid={pid}"),
        )
    } else {
        String::from("daemon: stopped")
    };
    SnapshotDaemonStatus {
        label,
        healthy: Some(status.running),
        pid: status.pid,
        last_heartbeat_at: status.last_change_at,
    }
}

async fn initial_snapshot(args: &TuiArgs) -> Result<InitialSnapshot> {
    let now = utc_now();
    if let Some(path) = &args.socket {
        return initial_socket_snapshot(path).await;
    }
    if let Some(run_id) = &args.run_id {
        let project_root = tracked_entries::resolve_project_root(&std::env::current_dir()?)?;
        let loaded =
            run_history::load_run_snapshot(&project_root, run_id, args.snapshot.as_deref(), now)?;
        return Ok(initial_from_loaded_run(loaded, true));
    }
    if let Some(path) = &args.archive {
        return Ok(match tracked_entries::snapshot_from_file(path, now) {
            Ok(snapshot) => {
                let archived_at = snapshot.terminated_at.unwrap_or(snapshot.updated_at);
                InitialSnapshot {
                    snapshot,
                    source: SnapshotSource::File(path.clone()),
                    source_state: ReadSourceState::LegacyArchive { archived_at },
                    status_error: None,
                }
            }
            Err(SnapshotError::PrePurgeState) => InitialSnapshot {
                snapshot: tracked_entries::snapshot_for_error_path(
                    path,
                    now,
                    SnapshotError::PrePurgeState.to_string(),
                    true,
                ),
                source: SnapshotSource::File(path.clone()),
                source_state: ReadSourceState::LegacyArchive { archived_at: now },
                status_error: None,
            },
            Err(error) => return Err(error.into()),
        });
    }
    if let Some(path) = &args.state_file {
        return Ok(match tracked_entries::snapshot_from_file(path, now) {
            Ok(snapshot) => {
                let source_state = ReadSourceState::from_snapshot(&snapshot);
                InitialSnapshot {
                    snapshot,
                    source: SnapshotSource::File(path.clone()),
                    source_state,
                    status_error: None,
                }
            }
            Err(SnapshotError::PrePurgeState) => InitialSnapshot {
                snapshot: tracked_entries::snapshot_for_error_path(
                    path,
                    now,
                    SnapshotError::PrePurgeState.to_string(),
                    true,
                ),
                source: SnapshotSource::File(path.clone()),
                source_state: ReadSourceState::LiveFile,
                status_error: None,
            },
            Err(error) => return Err(error.into()),
        });
    }

    if args.demo.is_some() || !args.wants_live_state() {
        let demo_name = fixtures::canonical_name(args.demo_name())?;
        let snapshot = fixtures::load_demo_snapshot(demo_name, now)?;
        return Ok(InitialSnapshot {
            snapshot,
            source: SnapshotSource::Demo(demo_name),
            source_state: ReadSourceState::Demo,
            status_error: None,
        });
    }

    let resolution = tracked_entries::resolve_session_state(args.session.as_deref())?;
    let source = SnapshotSource::Session(resolution.clone());
    match run_history::load_active_run_metadata(&resolution.project_root, &resolution.session) {
        Ok(run_history::ActiveRunLookup::Matched(metadata)) if metadata.terminated => {
            Ok(no_active_snapshot(
                &resolution,
                now,
                source,
                Some(format!(
                    "active run {} is terminated; press H for History",
                    metadata.run_id
                )),
            ))
        }
        Ok(run_history::ActiveRunLookup::Matched(metadata)) => {
            if let Some(mut snapshot) = discover_socket_snapshot_for_session(&resolution.session).await {
                snapshot.source_state = ReadSourceState::ActiveRun {
                    run_id: Some(metadata.run_id.clone()),
                };
                return Ok(snapshot);
            }
            initial_from_active_live_session(&resolution, source, now, Some(metadata.run_id), None)
        }
        Ok(run_history::ActiveRunLookup::None) => Ok(no_active_snapshot(
            &resolution,
            now,
            source,
            Some(String::from("no active run pointer; press H for History")),
        )),
        Ok(run_history::ActiveRunLookup::Mismatched {
            run_id,
            expected_session,
            actual_session,
        }) => Ok(no_active_snapshot(
            &resolution,
            now,
            source,
            Some(format!(
                "active run {run_id} belongs to session {}; requested {expected_session}; press H for History",
                actual_session.unwrap_or_else(|| String::from("unknown"))
            )),
        )),
        Err(error) => Ok(no_active_snapshot(
            &resolution,
            now,
            source,
            Some(format!("run history unavailable: {error}")),
        )),
    }
}

fn initial_from_active_live_session(
    resolution: &tracked_entries::SessionResolution,
    source: SnapshotSource,
    now: chrono::DateTime<chrono::Utc>,
    run_id: Option<String>,
    status_error: Option<String>,
) -> Result<InitialSnapshot> {
    match tracked_entries::read_session_snapshot(resolution, now) {
        Ok(mut snapshot) if !snapshot.terminated => {
            snapshot.project_root.clone_from(&resolution.project_root);
            Ok(InitialSnapshot {
                snapshot,
                source,
                source_state: ReadSourceState::ActiveRun { run_id },
                status_error,
            })
        }
        Ok(_) | Err(SnapshotError::StateFileMissing { .. }) => Ok(no_active_snapshot(
            resolution,
            now,
            source,
            status_error
                .or_else(|| Some(String::from("no live active state; press H for History"))),
        )),
        Err(SnapshotError::PrePurgeState) => Ok(InitialSnapshot {
            snapshot: tracked_entries::snapshot_for_error(
                &resolution.session,
                resolution.state_path.clone(),
                now,
                SnapshotError::PrePurgeState.to_string(),
                true,
            ),
            source,
            source_state: ReadSourceState::LiveFile,
            status_error,
        }),
        Err(read_error) => Ok(no_active_snapshot(
            resolution,
            now,
            source,
            Some(
                status_error
                    .map(|error| format!("{error}; {read_error}"))
                    .unwrap_or_else(|| read_error.to_string()),
            ),
        )),
    }
}

fn initial_from_loaded_run(loaded: LoadedRunSnapshot, force_archive: bool) -> InitialSnapshot {
    let archived_at = loaded
        .metadata
        .terminated_at
        .unwrap_or(loaded.snapshot.updated_at);
    let source_state = if force_archive || loaded.metadata.terminated || loaded.metadata.imported {
        if loaded.metadata.imported {
            ReadSourceState::ImportedArchive {
                run_id: loaded.metadata.run_id.clone(),
                archived_at,
            }
        } else {
            ReadSourceState::ArchivedRun {
                run_id: loaded.metadata.run_id.clone(),
                archived_at,
            }
        }
    } else {
        ReadSourceState::ActiveRun {
            run_id: Some(loaded.metadata.run_id.clone()),
        }
    };
    InitialSnapshot {
        source: SnapshotSource::Run(RunSnapshotSource {
            project_root: loaded.metadata.project_root.clone(),
            run_id: loaded.metadata.run_id.clone(),
            snapshot: loaded.snapshot_name.clone(),
            state_path: loaded.snapshot.master_state_path.clone(),
            activity_path: loaded.metadata.activity_path.clone(),
            run_dir: loaded.metadata.run_dir(),
            imported: loaded.metadata.imported,
            terminated_at: loaded.metadata.terminated_at,
            read_only: force_archive || loaded.metadata.terminated || loaded.metadata.imported,
        }),
        snapshot: loaded.snapshot,
        source_state,
        status_error: None,
    }
}

fn no_active_snapshot(
    resolution: &tracked_entries::SessionResolution,
    now: chrono::DateTime<chrono::Utc>,
    source: SnapshotSource,
    status_error: Option<String>,
) -> InitialSnapshot {
    let mut snapshot = DashboardSnapshot::empty_for_session(
        &resolution.session,
        resolution.state_path.clone(),
        now,
    );
    snapshot.project_root = resolution.project_root.clone();
    InitialSnapshot {
        snapshot,
        source,
        source_state: ReadSourceState::NoActiveRun,
        status_error,
    }
}

#[allow(dead_code)]
fn legacy_session_snapshot(
    resolution: &tracked_entries::SessionResolution,
    now: chrono::DateTime<chrono::Utc>,
    source: SnapshotSource,
) -> Result<InitialSnapshot> {
    match tracked_entries::read_session_snapshot(resolution, now) {
        Ok(snapshot) => {
            let source_state = ReadSourceState::from_snapshot(&snapshot);
            Ok(InitialSnapshot {
                snapshot,
                source,
                source_state,
                status_error: None,
            })
        }
        Err(SnapshotError::PrePurgeState) => Ok(InitialSnapshot {
            snapshot: tracked_entries::snapshot_for_error(
                &resolution.session,
                resolution.state_path.clone(),
                now,
                SnapshotError::PrePurgeState.to_string(),
                true,
            ),
            source,
            source_state: ReadSourceState::LiveFile,
            status_error: None,
        }),
        Err(SnapshotError::StateFileMissing { .. }) => Ok(InitialSnapshot {
            snapshot: DashboardSnapshot::empty_for_session(
                &resolution.session,
                resolution.state_path.clone(),
                now,
            ),
            source,
            source_state: ReadSourceState::NoActiveRun,
            status_error: None,
        }),
        Err(error) => Ok(InitialSnapshot {
            snapshot: tracked_entries::snapshot_for_error(
                &resolution.session,
                resolution.state_path.clone(),
                now,
                error.to_string(),
                false,
            ),
            source,
            source_state: ReadSourceState::LiveFile,
            status_error: Some(error.to_string()),
        }),
    }
}

fn start_state_watcher(
    source: &SnapshotSource,
    source_state: &ReadSourceState,
    tx: mpsc::UnboundedSender<WatcherEvent>,
    model: &mut Model,
) -> Option<StateWatcher> {
    if source_state.is_read_only() {
        return None;
    }
    let (live_path, archive_dir) = match source {
        SnapshotSource::Demo(_) | SnapshotSource::Socket(_) | SnapshotSource::Run(_) => {
            return None
        }
        SnapshotSource::File(path) => {
            let archive_dir = path
                .parent()
                .unwrap_or_else(|| std::path::Path::new("."))
                .to_path_buf();
            (path.clone(), archive_dir)
        }
        SnapshotSource::Session(resolution) => {
            (resolution.state_path.clone(), resolution.state_dir.clone())
        }
    };
    match StateWatcher::spawn(
        live_path,
        archive_dir,
        tx,
        Duration::from_millis(WATCH_DEBOUNCE_MS),
    ) {
        Ok(watcher) => Some(watcher),
        Err(error) => {
            model.error = Some(error.to_string());
            None
        }
    }
}

fn start_event_sources(
    source: &SnapshotSource,
    source_state: &ReadSourceState,
    tx: mpsc::UnboundedSender<Msg>,
) -> Option<tokio::task::JoinHandle<()>> {
    if !matches!(
        source_state,
        ReadSourceState::LiveFile | ReadSourceState::ActiveRun { .. }
    ) {
        return None;
    }
    let session = match source {
        SnapshotSource::Demo(_) | SnapshotSource::Socket(_) | SnapshotSource::Run(_) => {
            return None
        }
        SnapshotSource::File(path) => tracked_entries::session_id_from_state_path(path),
        SnapshotSource::Session(resolution) => resolution.session.clone(),
    };
    let source = match events::default_sources(&session) {
        Ok(source) => source,
        Err(error) => {
            tracing::warn!(%error, session, "activity sources disabled");
            return None;
        }
    };
    let mut rx = source.subscribe();
    Some(tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            if tx.send(Msg::EventReceived(event)).is_err() {
                break;
            }
        }
    }))
}

fn start_socket_subscription(
    source: &SnapshotSource,
    tx: mpsc::UnboundedSender<Msg>,
) -> Option<tokio::task::JoinHandle<()>> {
    let path = match source {
        SnapshotSource::Socket(path) => path.clone(),
        SnapshotSource::Demo(_)
        | SnapshotSource::File(_)
        | SnapshotSource::Session(_)
        | SnapshotSource::Run(_) => return None,
    };
    Some(tokio::spawn(async move {
        let msg = match DaemonClient::connect(&path).await {
            Ok(mut client) => match client.subscribe_snapshots().await {
                Ok(mut rx) => {
                    while let Some(result) = rx.recv().await {
                        let should_return = result.is_err();
                        let msg = match result {
                            Ok(snapshot) => Msg::SnapshotUpdated {
                                snapshot: Box::new(snapshot),
                                source_state: ReadSourceState::ActiveRun { run_id: None },
                            },
                            Err(error) => Msg::Error(format!("daemon: {error}")),
                        };
                        if tx.send(msg).is_err() || should_return {
                            return;
                        }
                    }
                    return;
                }
                Err(error) => Msg::Error(error.to_string()),
            },
            Err(error) => Msg::Error(error.to_string()),
        };
        if tx.send(msg).is_err() {
            tracing::debug!("dashboard message receiver dropped");
        }
    }))
}

fn start_daemon_status_poll(
    source: &SnapshotSource,
    tx: mpsc::UnboundedSender<Msg>,
) -> Option<tokio::task::JoinHandle<()>> {
    let path = match source {
        SnapshotSource::Socket(path) => path.clone(),
        SnapshotSource::Demo(_)
        | SnapshotSource::File(_)
        | SnapshotSource::Session(_)
        | SnapshotSource::Run(_) => return None,
    };
    Some(tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(1));
        interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
        loop {
            interval.tick().await;
            let msg = match DaemonClient::connect(&path).await {
                Ok(mut client) => match client.get_status().await {
                    Ok(status) => Msg::DaemonStatus(status),
                    Err(error) => Msg::Error(error.to_string()),
                },
                Err(error) => Msg::Error(error.to_string()),
            };
            if tx.send(msg).is_err() {
                break;
            }
        }
    }))
}

#[derive(Clone, PartialEq, Eq)]
struct RuntimeSourceKey {
    source: SnapshotSource,
    source_state: ReadSourceState,
}

impl RuntimeSourceKey {
    fn from_model(model: &Model) -> Self {
        Self {
            source: model.snapshot_source.clone(),
            source_state: model.read_source_state.clone(),
        }
    }
}

struct SourceTasks {
    key: RuntimeSourceKey,
    state_watcher: Option<StateWatcher>,
    event_task: Option<tokio::task::JoinHandle<()>>,
    socket_task: Option<tokio::task::JoinHandle<()>>,
    daemon_status_task: Option<tokio::task::JoinHandle<()>>,
}

impl SourceTasks {
    fn start(
        model: &mut Model,
        msg_tx: mpsc::UnboundedSender<Msg>,
        watch_tx: mpsc::UnboundedSender<WatcherEvent>,
    ) -> Self {
        let key = RuntimeSourceKey::from_model(model);
        Self {
            state_watcher: start_state_watcher(&key.source, &key.source_state, watch_tx, model),
            event_task: start_event_sources(&key.source, &key.source_state, msg_tx.clone()),
            socket_task: start_socket_subscription(&key.source, msg_tx.clone()),
            daemon_status_task: start_daemon_status_poll(&key.source, msg_tx),
            key,
        }
    }

    fn sync(
        &mut self,
        model: &mut Model,
        msg_tx: mpsc::UnboundedSender<Msg>,
        watch_tx: mpsc::UnboundedSender<WatcherEvent>,
    ) {
        let next_key = RuntimeSourceKey::from_model(model);
        if next_key == self.key {
            return;
        }
        self.stop();
        self.key = next_key;
        self.state_watcher =
            start_state_watcher(&self.key.source, &self.key.source_state, watch_tx, model);
        self.event_task =
            start_event_sources(&self.key.source, &self.key.source_state, msg_tx.clone());
        self.socket_task = start_socket_subscription(&self.key.source, msg_tx.clone());
        self.daemon_status_task = start_daemon_status_poll(&self.key.source, msg_tx);
    }

    fn stop(&mut self) {
        self.state_watcher = None;
        abort_task(&mut self.event_task);
        abort_task(&mut self.socket_task);
        abort_task(&mut self.daemon_status_task);
    }
}

impl Drop for SourceTasks {
    fn drop(&mut self) {
        self.stop();
    }
}

fn abort_task(task: &mut Option<tokio::task::JoinHandle<()>>) {
    if let Some(task) = task.take() {
        task.abort();
    }
}

async fn run_app_loop(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    model: &mut Model,
) -> Result<()> {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let effects = Effects::new(tx.clone(), model.clock);
    let (watch_tx, mut watch_rx) = mpsc::unbounded_channel();
    let mut source_tasks = SourceTasks::start(model, tx.clone(), watch_tx.clone());
    let mut events = EventStream::new();
    let mut anim = tokio::time::interval(Duration::from_millis(ANIMATION_TICK_MS));
    anim.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let mut clock = tokio::time::interval(Duration::from_millis(CLOCK_TICK_MS));
    clock.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let mut hitmap = HitMap::default();
    let mut cost_aggregator = CostAggregator::default();
    let mut cost = tokio::time::interval(Duration::from_secs(cost_poll_secs()));
    cost.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let commands = update(
        model,
        Msg::CostUpdated(cost_aggregator.poll_snapshot(&model.snapshot, (model.clock)())),
    );
    effects.run_commands(commands);
    effects.run_commands(vec![flightdeck_dashboard::app::command::Cmd::ProbePanes]);

    terminal.draw(|frame| view::render_with_hitmap(frame, model, &mut hitmap))?;
    loop {
        tokio::select! {
            biased;
            Some(msg) = rx.recv() => {
                let commands = update(model, msg);
                effects.run_commands(commands);
                source_tasks.sync(model, tx.clone(), watch_tx.clone());
            }
            Some(event) = watch_rx.recv() => {
                let commands = update(model, flightdeck_dashboard::app::msg::Msg::WatcherEvent(event));
                effects.run_commands(commands);
                source_tasks.sync(model, tx.clone(), watch_tx.clone());
            }
            maybe_event = events.next() => {
                if let Some(msg) = event_to_msg(maybe_event, &hitmap) {
                    let commands = update(model, msg);
                    effects.run_commands(commands);
                    source_tasks.sync(model, tx.clone(), watch_tx.clone());
                }
            }
            _ = anim.tick(), if motion::has_active_effects(&model.active_effects, model.motion, model.animate_frame, &model.snapshot.sessions) => {
                let commands = update(model, flightdeck_dashboard::app::msg::Msg::AnimateTick);
                effects.run_commands(commands);
                source_tasks.sync(model, tx.clone(), watch_tx.clone());
            }
            _ = clock.tick() => {
                let commands = update(model, flightdeck_dashboard::app::msg::Msg::Tick);
                effects.run_commands(commands);
                source_tasks.sync(model, tx.clone(), watch_tx.clone());
            }
            _ = cost.tick() => {
                let totals = cost_aggregator.poll_snapshot(&model.snapshot, (model.clock)());
                let commands = update(model, flightdeck_dashboard::app::msg::Msg::CostUpdated(totals));
                effects.run_commands(commands);
                source_tasks.sync(model, tx.clone(), watch_tx.clone());
            }
            _ = tokio::signal::ctrl_c() => {
                let commands = update(model, flightdeck_dashboard::app::msg::Msg::Quit);
                effects.run_commands(commands);
                source_tasks.sync(model, tx.clone(), watch_tx.clone());
            }
        }
        terminal.draw(|frame| view::render_with_hitmap(frame, model, &mut hitmap))?;
        if model.quit_requested {
            break;
        }
    }
    Ok(())
}

fn mouse_to_msg(
    kind: MouseEventKind,
    column: u16,
    row: u16,
    hitmap: &HitMap,
) -> Option<flightdeck_dashboard::app::msg::Msg> {
    let action = match kind {
        MouseEventKind::Down(MouseButton::Left) => hitmap.hit(column, row),
        MouseEventKind::ScrollUp => hitmap.hit(column, row).and_then(|action| match action {
            ClickAction::ScrollUp(source) | ClickAction::ScrollDown(source) => {
                Some(ClickAction::ScrollUp(source))
            }
            _ => None,
        }),
        MouseEventKind::ScrollDown => hitmap.hit(column, row).and_then(|action| match action {
            ClickAction::ScrollUp(source) | ClickAction::ScrollDown(source) => {
                Some(ClickAction::ScrollDown(source))
            }
            _ => None,
        }),
        _ => None,
    }?;
    Some(flightdeck_dashboard::app::msg::Msg::Click(action))
}

fn event_to_msg(
    event: Option<std::io::Result<Event>>,
    hitmap: &HitMap,
) -> Option<flightdeck_dashboard::app::msg::Msg> {
    match event {
        Some(Ok(Event::Key(key))) if key.kind == KeyEventKind::Press => {
            Some(flightdeck_dashboard::app::msg::Msg::KeyPressed(key))
        }
        Some(Ok(Event::Resize(width, height))) => {
            Some(flightdeck_dashboard::app::msg::Msg::Resize(width, height))
        }
        Some(Ok(Event::Mouse(mouse))) => mouse_to_msg(mouse.kind, mouse.column, mouse.row, hitmap),
        Some(Ok(_)) | None => None,
        Some(Err(error)) => Some(flightdeck_dashboard::app::msg::Msg::Error(
            error.to_string(),
        )),
    }
}

#[cfg(test)]
mod tests {
    use std::env;
    use std::fs;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;
    use std::thread;

    use serde_json::json;

    use super::*;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn active_startup_reads_project_local_live_state_not_durable_state() {
        with_startup_fixture(|ctx| {
            write_active(&ctx.responses, "run-1", "S", false);
            write_live_state(&ctx.project, "S", false);
            let initial = initial_snapshot(&tui_args("S"));

            assert!(matches!(initial.source, SnapshotSource::Session(_)));
            assert!(matches!(
                initial.source_state,
                ReadSourceState::ActiveRun { run_id: Some(ref run_id) } if run_id == "run-1"
            ));
            assert_eq!(
                initial.snapshot.master_state_path,
                live_state_path(&ctx.project, "S")
            );
            assert_eq!(initial.snapshot.session_id, "S");
        });
    }

    #[test]
    fn no_active_pointer_with_existing_archive_does_not_load_archive_as_live() {
        with_startup_fixture(|ctx| {
            fs::write(ctx.responses.join("active.json"), "null\n").expect("active null");
            fs::create_dir_all(ctx.project.join("tmp")).expect("tmp dir");
            fs::write(
                ctx.project
                    .join("tmp/flightdeck-state-S-2026-05-19T120000Z.json.archive"),
                state_json("S", true).to_string(),
            )
            .expect("archive state");

            let initial = initial_snapshot(&tui_args("S"));

            assert!(matches!(initial.source, SnapshotSource::Session(_)));
            assert_eq!(initial.source_state, ReadSourceState::NoActiveRun);
            assert_eq!(
                initial.snapshot.master_state_path,
                live_state_path(&ctx.project, "S")
            );
            assert!(initial.snapshot.sessions.is_empty());
        });
    }

    #[test]
    fn terminated_or_mismatched_active_pointer_clears_live_display() {
        with_startup_fixture(|ctx| {
            write_active_with_terminated(&ctx.responses, "run-1", "S", false, true);
            write_live_state(&ctx.project, "S", false);
            let terminated = initial_snapshot(&tui_args("S"));
            assert_eq!(terminated.source_state, ReadSourceState::NoActiveRun);

            write_active(&ctx.responses, "run-2", "OTHER", false);
            write_live_state(&ctx.project, "S", false);
            let mismatched = initial_snapshot(&tui_args("S"));
            assert_eq!(mismatched.source_state, ReadSourceState::NoActiveRun);
            assert!(mismatched
                .status_error
                .as_deref()
                .is_some_and(|message| message.contains("belongs to session OTHER")));
        });
    }

    #[test]
    fn archive_flag_is_processed_before_auto_socket_discovery() {
        with_startup_fixture(|ctx| {
            let archive = ctx.project.join("tmp/flightdeck-state-S.json");
            fs::write(&archive, state_json("S", true).to_string()).expect("archive state");
            start_fake_dashboard_socket(&ctx.runtime_state.join("dashboard-S.sock"), &ctx.project);
            let mut args = tui_args("S");
            args.archive = Some(archive.clone());
            args.session = None;

            let initial = initial_snapshot(&args);

            assert!(matches!(initial.source, SnapshotSource::File(path) if path == archive));
            assert!(matches!(
                initial.source_state,
                ReadSourceState::LegacyArchive { .. }
            ));
        });
    }

    #[test]
    fn active_command_failure_lands_on_no_active_even_with_live_file() {
        with_startup_fixture(|ctx| {
            fs::write(ctx.responses.join("fail-active"), "1").expect("fail marker");
            write_live_state(&ctx.project, "S", false);

            let initial = initial_snapshot(&tui_args("S"));

            assert!(matches!(initial.source, SnapshotSource::Session(_)));
            assert_eq!(initial.source_state, ReadSourceState::NoActiveRun);
            assert!(initial.snapshot.sessions.is_empty());
            assert!(initial
                .status_error
                .as_deref()
                .is_some_and(|message| message.contains("run history unavailable")));
        });
    }

    #[test]
    fn run_id_snapshot_activity_uses_canonical_run_dir() {
        with_startup_fixture(|ctx| {
            let run_dir = ctx.project.join("runs/run-1");
            let snapshots_dir = run_dir.join("snapshots");
            let snapshot_name = "2026-05-19T120000Z.json";
            fs::create_dir_all(&snapshots_dir).expect("snapshots dir");
            fs::write(
                run_dir.join("activity.jsonl"),
                concat!(
                    "{\"schema_version\":1,\"id\":\"run-activity\",",
                    "\"ts\":\"2026-05-19T12:00:00Z\",",
                    "\"session_id\":\"S\",\"source\":\"flightdeck\",",
                    "\"type\":\"session.started\",\"severity\":\"info\",",
                    "\"importance\":\"normal\",\"summary\":\"run activity\"}\n",
                ),
            )
            .expect("activity");
            write_run_show(&ctx.responses, &ctx.project, &run_dir, snapshot_name);
            let mut args = tui_args("S");
            args.session = None;
            args.run_id = Some(String::from("run-1"));
            args.snapshot = Some(snapshot_name.to_owned());

            let initial = initial_snapshot(&args);
            assert!(matches!(
                &initial.source,
                SnapshotSource::Run(source)
                    if source.state_path == snapshots_dir.join(snapshot_name)
                        && source.run_dir == run_dir
            ));
            let InitialSnapshot {
                snapshot,
                source,
                source_state,
                ..
            } = initial;
            let mut model = Model::new(snapshot, source, MotionLevel::Off, Theme::Moon, utc_now);
            model.read_source_state = source_state;
            model.sync_activity_source();
            model.poll_activity_source();

            assert!(model.activity.source_error.is_none());
            assert_eq!(model.activity.events.len(), 1);
            assert_eq!(model.activity.events[0].id, "run-activity");
        });
    }

    #[test]
    fn archive_flag_forces_read_only_legacy_archive() {
        with_startup_fixture(|ctx| {
            let archive = ctx
                .project
                .join("tmp/flightdeck-state-S-2026-05-19T120000Z.json.archive");
            fs::write(&archive, state_json("S", false).to_string()).expect("archive state");
            let mut args = tui_args("S");
            args.archive = Some(archive.clone());
            args.session = None;

            let initial = initial_snapshot(&args);

            assert!(matches!(initial.source, SnapshotSource::File(path) if path == archive));
            assert!(matches!(
                initial.source_state,
                ReadSourceState::LegacyArchive { .. }
            ));
        });
    }

    fn initial_snapshot(args: &TuiArgs) -> InitialSnapshot {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(super::initial_snapshot(args))
            .expect("initial snapshot")
    }

    struct StartupFixture {
        project: PathBuf,
        responses: PathBuf,
        runtime_state: PathBuf,
    }

    fn with_startup_fixture(test: impl FnOnce(&StartupFixture)) {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let temp = tempfile::tempdir().expect("tempdir");
        let project = temp.path().join("project");
        let responses = temp.path().join("responses");
        let runtime_state = temp.path().join("runtime");
        fs::create_dir_all(project.join("tmp")).expect("project tmp");
        fs::create_dir_all(&responses).expect("responses");
        fs::create_dir_all(&runtime_state).expect("runtime state");
        fs::write(project.join("vstack.toml"), "").expect("project marker");
        write_fake_state_bin(&temp.path().join("flightdeck-state"), &responses);
        let old_bin = env::var_os("FLIGHTDECK_STATE_BIN");
        let old_fd_state_dir = env::var_os("FD_STATE_DIR");
        let old_state_dir = env::var_os("FLIGHTDECK_STATE_DIR");
        let old_cwd = env::current_dir().expect("cwd");
        env::set_var("FLIGHTDECK_STATE_BIN", temp.path().join("flightdeck-state"));
        env::set_var("FD_STATE_DIR", &runtime_state);
        env::set_var("FLIGHTDECK_STATE_DIR", "tmp");
        env::set_current_dir(&project).expect("set cwd");
        test(&StartupFixture {
            project,
            responses,
            runtime_state,
        });
        env::set_current_dir(old_cwd).expect("restore cwd");
        restore_env("FLIGHTDECK_STATE_BIN", old_bin);
        restore_env("FD_STATE_DIR", old_fd_state_dir);
        restore_env("FLIGHTDECK_STATE_DIR", old_state_dir);
    }

    fn restore_env(key: &str, value: Option<std::ffi::OsString>) {
        if let Some(value) = value {
            env::set_var(key, value);
        } else {
            env::remove_var(key);
        }
    }

    fn tui_args(session: &str) -> TuiArgs {
        TuiArgs {
            demo: None,
            state_file: None,
            session: Some(session.to_owned()),
            run_id: None,
            snapshot: None,
            archive: None,
            socket: None,
            theme: None,
            motion: None,
        }
    }

    fn write_fake_state_bin(path: &Path, responses: &Path) {
        let script = format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "run active")
    if [[ -f {responses}/fail-active ]]; then echo forced failure >&2; exit 9; fi
    cat {responses}/active.json
    ;;
  "run show") cat {responses}/show.json ;;
  *) echo unexpected "$@" >&2; exit 64 ;;
esac
"#,
            responses = shell_path(responses),
        );
        fs::write(path, script).expect("fake state bin");
        let mut perms = fs::metadata(path).expect("metadata").permissions();
        perms.set_mode(0o755);
        fs::set_permissions(path, perms).expect("chmod");
    }

    fn write_active(responses: &Path, run_id: &str, session: &str, imported: bool) {
        write_active_with_terminated(responses, run_id, session, imported, false);
    }

    fn write_active_with_terminated(
        responses: &Path,
        run_id: &str,
        session: &str,
        imported: bool,
        terminated: bool,
    ) {
        fs::write(
            responses.join("active.json"),
            json!({
                "active": { "run_id": run_id, "tmux_session": session },
                "metadata": {
                    "run_id": run_id,
                    "project_root": "/project",
                    "tmux_session": session,
                    "state_path": format!("/store/{run_id}/state.json"),
                    "activity_path": format!("/store/{run_id}/activity.jsonl"),
                    "summary_path": null,
                    "snapshots_path": format!("/store/{run_id}/snapshots"),
                    "started_at": "2026-05-19T12:00:00Z",
                    "last_seen_at": "2026-05-19T12:01:00Z",
                    "terminated": terminated,
                    "terminated_at": if terminated { Some("2026-05-19T12:02:00Z") } else { None },
                    "imported": imported,
                    "imported_from": null
                }
            })
            .to_string(),
        )
        .expect("active json");
    }

    fn write_run_show(responses: &Path, project: &Path, run_dir: &Path, snapshot_name: &str) {
        fs::write(
            responses.join("show.json"),
            json!({
                "metadata": {
                    "run_id": "run-1",
                    "project_root": project,
                    "tmux_session": "S",
                    "state_path": run_dir.join("state.json"),
                    "activity_path": run_dir.join("activity.jsonl"),
                    "summary_path": null,
                    "snapshots_path": run_dir.join("snapshots"),
                    "started_at": "2026-05-19T12:00:00Z",
                    "last_seen_at": "2026-05-19T12:01:00Z",
                    "terminated": false,
                    "terminated_at": null,
                    "imported": false,
                    "imported_from": null
                },
                "state": state_json("S", false),
                "snapshot": snapshot_name,
                "snapshots": [snapshot_name]
            })
            .to_string(),
        )
        .expect("show json");
    }

    fn start_fake_dashboard_socket(path: &Path, project: &Path) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("socket parent");
        }
        let _ = fs::remove_file(path);
        let listener = UnixListener::bind(path).expect("dashboard socket bind");
        let snapshot =
            DashboardSnapshot::empty_for_session("S", live_state_path(project, "S"), utc_now());
        let status = json!({
            "session": "S",
            "running": true,
            "pid": null,
            "socket": path,
            "uptime_secs": 1,
            "last_change_at": null,
            "listener_path": path
        });
        thread::spawn(move || {
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            let Ok(reader_stream) = stream.try_clone() else {
                return;
            };
            let mut reader = BufReader::new(reader_stream);
            for _ in 0..2 {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or_default() == 0 {
                    return;
                }
                let Ok(request) = serde_json::from_str::<serde_json::Value>(&line) else {
                    return;
                };
                let method = request.get("method").and_then(serde_json::Value::as_str);
                let result = match method {
                    Some("get_snapshot") => serde_json::to_value(&snapshot).expect("snapshot json"),
                    Some("get_status") => status.clone(),
                    _ => json!(null),
                };
                let response = json!({
                    "jsonrpc": "2.0",
                    "id": request.get("id").cloned().unwrap_or(serde_json::Value::Null),
                    "result": result,
                });
                if writeln!(stream, "{response}").is_err() {
                    return;
                }
            }
        });
    }

    fn write_live_state(project: &Path, session: &str, terminated: bool) {
        fs::write(
            live_state_path(project, session),
            state_json(session, terminated).to_string(),
        )
        .expect("live state");
    }

    fn live_state_path(project: &Path, session: &str) -> PathBuf {
        project
            .join("tmp")
            .join(format!("flightdeck-state-{session}.json"))
    }

    fn state_json(session: &str, terminated: bool) -> serde_json::Value {
        json!({
            "session_id": session,
            "started_at": "2026-05-19T12:00:00Z",
            "updated_at": "2026-05-19T12:01:00Z",
            "terminated": terminated,
            "terminated_at": if terminated { Some("2026-05-19T12:02:00Z") } else { None },
            "owner": null,
            "entries": {},
            "merge_queue": [],
            "conflict_graph": { "edges": [], "computed_at": "2026-05-19T12:01:00Z" },
            "paused_for_user": null
        })
    }

    fn shell_path(path: &Path) -> String {
        format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
    }
}
