use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use tokio::sync::{broadcast, mpsc, RwLock};

use crate::state::snapshot::DashboardSnapshot;
use crate::state::tracked_entries::{self, SessionResolution, SnapshotError};
use crate::watcher::{StateWatcher, WatcherEvent};

use super::lifecycle::RuntimePaths;
use super::rpc::DaemonStatus;

const WATCH_DEBOUNCE_MS: u64 = 150;
const SNAPSHOT_CHANNEL_CAP: usize = 64;

#[derive(Debug, Clone)]
pub enum DaemonSnapshotSource {
    File { path: PathBuf, session: String },
    Session(SessionResolution),
}

impl DaemonSnapshotSource {
    #[must_use]
    pub fn session(&self) -> &str {
        match self {
            Self::File { session, .. } => session,
            Self::Session(resolution) => &resolution.session,
        }
    }

    #[must_use]
    pub fn live_path(&self) -> PathBuf {
        match self {
            Self::File { path, .. } => path.clone(),
            Self::Session(resolution) => resolution.state_path.clone(),
        }
    }

    #[must_use]
    pub fn archive_dir(&self) -> PathBuf {
        match self {
            Self::File { path, .. } => path
                .parent()
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(".")),
            Self::Session(resolution) => resolution.state_dir.clone(),
        }
    }
}

#[derive(Debug)]
pub struct SharedState {
    pub snapshot: RwLock<DashboardSnapshot>,
    pub status: RwLock<DaemonStatus>,
    pub snapshots: broadcast::Sender<DashboardSnapshot>,
}

#[derive(Debug)]
pub struct StateRuntime {
    pub shared: Arc<SharedState>,
    _watcher: StateWatcher,
    _task: tokio::task::JoinHandle<()>,
}

pub async fn start_state_runtime(
    source: DaemonSnapshotSource,
    paths: RuntimePaths,
) -> Result<StateRuntime, SnapshotError> {
    let now = Utc::now();
    let snapshot = load_snapshot_or_error(&source, now);
    let (snapshots, _) = broadcast::channel(SNAPSHOT_CHANNEL_CAP);
    let status = DaemonStatus {
        session: paths.session_key.clone(),
        running: true,
        pid: Some(std::process::id()),
        socket: Some(paths.socket.clone()),
        uptime_secs: Some(0),
        last_change_at: Some(now),
        listener_path: Some(paths.socket.clone()),
    };
    let shared = Arc::new(SharedState {
        snapshot: RwLock::new(snapshot.clone()),
        status: RwLock::new(status),
        snapshots,
    });
    if shared.snapshots.send(snapshot).is_err() {
        tracing::debug!("daemon snapshot channel has no initial subscribers");
    }

    let (watch_tx, mut watch_rx) = mpsc::unbounded_channel();
    let watcher = StateWatcher::spawn(
        source.live_path(),
        source.archive_dir(),
        watch_tx,
        Duration::from_millis(WATCH_DEBOUNCE_MS),
    )
    .map_err(|error| SnapshotError::Resolve(error.to_string()))?;
    let task_shared = Arc::clone(&shared);
    let task = tokio::spawn(async move {
        while let Some(WatcherEvent::Reload) = watch_rx.recv().await {
            let now = Utc::now();
            let snapshot = load_snapshot_or_error(&source, now);
            let mut current = task_shared.snapshot.write().await;
            if !current.structural_eq(&snapshot) {
                *current = snapshot.clone();
                task_shared.status.write().await.last_change_at = Some(now);
                if task_shared.snapshots.send(snapshot).is_err() {
                    tracing::debug!("daemon snapshot channel has no subscribers");
                }
            }
        }
    });
    Ok(StateRuntime {
        shared,
        _watcher: watcher,
        _task: task,
    })
}

pub fn load_snapshot(
    source: &DaemonSnapshotSource,
    now: DateTime<Utc>,
) -> Result<DashboardSnapshot, SnapshotError> {
    match source {
        DaemonSnapshotSource::File { path, .. } => tracked_entries::snapshot_from_file(path, now),
        DaemonSnapshotSource::Session(resolution) => {
            match tracked_entries::read_session_snapshot(resolution, now) {
                Ok(snapshot) => Ok(snapshot),
                Err(SnapshotError::StateFileMissing { .. }) => {
                    Ok(DashboardSnapshot::empty_for_session(
                        &resolution.session,
                        resolution.state_path.clone(),
                        now,
                    ))
                }
                Err(error) => Err(error),
            }
        }
    }
}

fn load_snapshot_or_error(source: &DaemonSnapshotSource, now: DateTime<Utc>) -> DashboardSnapshot {
    match load_snapshot(source, now) {
        Ok(mut snapshot) => {
            snapshot.master_error = None;
            snapshot.pre_purge_state = false;
            snapshot
        }
        Err(error) => {
            tracing::warn!(%error, "daemon failed to reload snapshot");
            error_snapshot(source, now, &error)
        }
    }
}

fn error_snapshot(
    source: &DaemonSnapshotSource,
    now: DateTime<Utc>,
    error: &SnapshotError,
) -> DashboardSnapshot {
    let pre_purge_state = matches!(error, SnapshotError::PrePurgeState);
    match source {
        DaemonSnapshotSource::File { path, session } => tracked_entries::snapshot_for_error(
            session.clone(),
            path.clone(),
            now,
            error.to_string(),
            pre_purge_state,
        ),
        DaemonSnapshotSource::Session(resolution) => tracked_entries::snapshot_for_error(
            resolution.session.clone(),
            resolution.state_path.clone(),
            now,
            error.to_string(),
            pre_purge_state,
        ),
    }
}
