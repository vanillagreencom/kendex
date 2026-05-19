mod terminal_guard;

use std::io::{self, IsTerminal, Stdout};
use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::Parser;
use color_eyre::eyre::Result;
use crossterm::event::{Event, EventStream, KeyEventKind, MouseButton, MouseEventKind};
use flightdeck_dashboard::app::command::SnapshotSource;
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
use flightdeck_dashboard::state::snapshot::{
    DaemonStatus as SnapshotDaemonStatus, DashboardSnapshot,
};
use flightdeck_dashboard::state::tracked_entries::{self, ArchiveError, SnapshotError};
use flightdeck_dashboard::util::logging;
use flightdeck_dashboard::util::paths::{
    dashboard_socket_file, fd_resolve_state_dir, fd_session_key_from_id, resolve_session_key,
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
        initial.snapshot.daemon = file_mode_daemon_status();
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
        source_state: ReadSourceState::Live,
        status_error,
    })
}

async fn discover_socket_snapshot(args: &TuiArgs) -> Option<InitialSnapshot> {
    if args.demo.is_some() || !args.wants_live_state() {
        return None;
    }
    let session_key = match tui_session_key(args) {
        Ok(Some(session_key)) => session_key,
        Ok(None) => return None,
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

fn tui_session_key(args: &TuiArgs) -> Result<Option<String>> {
    if let Some(session) = &args.session {
        return Ok(Some(resolve_session_key(session)?));
    }
    if let Some(path) = &args.state_file {
        return Ok(Some(file_session_key(
            &tracked_entries::session_id_from_state_path(path),
        )));
    }
    if args.wants_live_state() {
        let resolution = tracked_entries::resolve_session_state(None)?;
        return Ok(Some(resolve_session_key(&resolution.session)?));
    }
    Ok(None)
}

fn file_session_key(session: &str) -> String {
    if session.starts_with('s') && session[1..].chars().all(|ch| ch.is_ascii_digit()) {
        session.to_owned()
    } else if session.starts_with('$') {
        fd_session_key_from_id(session)
    } else {
        session.to_owned()
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

fn file_mode_daemon_status() -> SnapshotDaemonStatus {
    SnapshotDaemonStatus {
        label: String::from("daemon: file-mode"),
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
    if let Some(snapshot) = discover_socket_snapshot(args).await {
        return Ok(snapshot);
    }
    if let Some(path) = &args.state_file {
        return Ok(match tracked_entries::snapshot_from_file(path, now) {
            Ok(snapshot) => InitialSnapshot {
                snapshot,
                source: SnapshotSource::File(path.clone()),
                source_state: ReadSourceState::Live,
                status_error: None,
            },
            Err(SnapshotError::PrePurgeState) => InitialSnapshot {
                snapshot: tracked_entries::snapshot_for_error_path(
                    path,
                    now,
                    SnapshotError::PrePurgeState.to_string(),
                    true,
                ),
                source: SnapshotSource::File(path.clone()),
                source_state: ReadSourceState::Live,
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
            source_state: ReadSourceState::Live,
            status_error: None,
        });
    }

    let resolution = tracked_entries::resolve_session_state(args.session.as_deref())?;
    let source = SnapshotSource::Session(resolution.clone());
    match tracked_entries::read_session_snapshot(&resolution, now) {
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
            source_state: ReadSourceState::Live,
            status_error: None,
        }),
        Err(SnapshotError::Archive(ArchiveError::NoArchives { .. })) => Ok(InitialSnapshot {
            snapshot: DashboardSnapshot::empty_for_session(
                &resolution.session,
                resolution.state_path.clone(),
                now,
            ),
            source,
            source_state: ReadSourceState::Missing,
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
            source_state: ReadSourceState::Live,
            status_error: Some(error.to_string()),
        }),
    }
}

fn start_state_watcher(
    source: &SnapshotSource,
    tx: mpsc::UnboundedSender<WatcherEvent>,
    model: &mut Model,
) -> Option<StateWatcher> {
    let (live_path, archive_dir) = match source {
        SnapshotSource::Demo(_) | SnapshotSource::Socket(_) => return None,
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
    tx: mpsc::UnboundedSender<Msg>,
) -> Option<tokio::task::JoinHandle<()>> {
    let session = match source {
        SnapshotSource::Demo(_) | SnapshotSource::Socket(_) => return None,
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
        SnapshotSource::Demo(_) | SnapshotSource::File(_) | SnapshotSource::Session(_) => {
            return None
        }
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
                                source_state: ReadSourceState::Live,
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
        SnapshotSource::Demo(_) | SnapshotSource::File(_) | SnapshotSource::Session(_) => {
            return None
        }
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

async fn run_app_loop(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    model: &mut Model,
) -> Result<()> {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let effects = Effects::new(tx.clone(), model.clock);
    let source = model.snapshot_source.clone();
    let (watch_tx, mut watch_rx) = mpsc::unbounded_channel();
    let _state_watcher = start_state_watcher(&source, watch_tx, model);
    let _event_task = start_event_sources(&source, tx.clone());
    let _socket_task = start_socket_subscription(&source, tx.clone());
    let _daemon_status_task = start_daemon_status_poll(&source, tx.clone());
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
            }
            Some(event) = watch_rx.recv() => {
                let commands = update(model, flightdeck_dashboard::app::msg::Msg::WatcherEvent(event));
                effects.run_commands(commands);
            }
            maybe_event = events.next() => {
                if let Some(msg) = event_to_msg(maybe_event, &hitmap) {
                    let commands = update(model, msg);
                    effects.run_commands(commands);
                }
            }
            _ = anim.tick(), if motion::has_active_effects(&model.active_effects, model.motion, model.animate_frame, &model.snapshot.sessions) => {
                let commands = update(model, flightdeck_dashboard::app::msg::Msg::AnimateTick);
                effects.run_commands(commands);
            }
            _ = clock.tick() => {
                let commands = update(model, flightdeck_dashboard::app::msg::Msg::Tick);
                effects.run_commands(commands);
            }
            _ = cost.tick() => {
                let totals = cost_aggregator.poll_snapshot(&model.snapshot, (model.clock)());
                let commands = update(model, flightdeck_dashboard::app::msg::Msg::CostUpdated(totals));
                effects.run_commands(commands);
            }
            _ = tokio::signal::ctrl_c() => {
                let commands = update(model, flightdeck_dashboard::app::msg::Msg::Quit);
                effects.run_commands(commands);
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
