use std::io::Write;
use std::path::Path;

use chrono::{DateTime, Utc};
use tokio::sync::mpsc;

use crate::app::command::RunSnapshotSource;
use crate::app::model::{Clock, ReadSourceState};
use crate::daemon::client::DaemonClient;
use crate::fixtures;
use crate::state::run_history;
use crate::state::snapshot::DashboardSnapshot;
use crate::state::tracked_entries::{self, SessionResolution, SnapshotError};

use super::command::{Cmd, SnapshotSource};
use super::msg::Msg;

#[derive(Clone)]
pub struct Effects {
    tx: mpsc::UnboundedSender<Msg>,
    clock: Clock,
}

impl Effects {
    #[must_use]
    pub const fn new(tx: mpsc::UnboundedSender<Msg>, clock: Clock) -> Self {
        Self { tx, clock }
    }

    pub fn run_commands(&self, commands: Vec<Cmd>) {
        for command in commands {
            match command {
                Cmd::Render => {}
                Cmd::RequestSnapshot(source) | Cmd::ReloadFromSource(source) => {
                    self.request_snapshot(source);
                }
                Cmd::LogAction(action) => tracing::info!(action = %action, "dashboard action"),
                Cmd::PauseSideEffects { bell } => self.pause_side_effects(bell),
                Cmd::ProbePanes => self.probe_panes(),
                Cmd::Spawn(future) => self.spawn_msg(future),
            }
        }
    }

    fn request_snapshot(&self, source: SnapshotSource) {
        match source {
            SnapshotSource::Demo(name) => {
                let msg = match fixtures::load_demo_snapshot(name, (self.clock)()) {
                    Ok(snapshot) => snapshot_msg(snapshot, ReadSourceState::Demo),
                    Err(error) => Msg::Error(error.to_string()),
                };
                send_msg(&self.tx, msg);
            }
            SnapshotSource::File(path) => {
                let tx = self.tx.clone();
                let clock = self.clock;
                tokio::spawn(async move {
                    let msg = snapshot_file_msg(&path, clock());
                    send_msg(&tx, msg);
                });
            }
            SnapshotSource::Session(resolution) => {
                let tx = self.tx.clone();
                let clock = self.clock;
                tokio::spawn(async move {
                    let msg = snapshot_session_msg(&resolution, clock());
                    send_msg(&tx, msg);
                });
            }
            SnapshotSource::Run(source) => {
                let tx = self.tx.clone();
                let clock = self.clock;
                tokio::spawn(async move {
                    let msg = snapshot_run_msg(&source, clock());
                    send_msg(&tx, msg);
                });
            }
            SnapshotSource::Socket(path) => {
                let tx = self.tx.clone();
                tokio::spawn(async move {
                    let msg = match DaemonClient::connect(&path).await {
                        Ok(mut client) => match client.get_snapshot().await {
                            Ok(snapshot) => {
                                snapshot_msg(snapshot, ReadSourceState::ActiveRun { run_id: None })
                            }
                            Err(error) => Msg::Error(error.to_string()),
                        },
                        Err(error) => Msg::Error(error.to_string()),
                    };
                    send_msg(&tx, msg);
                });
            }
        }
    }

    fn spawn_msg(&self, future: futures::future::BoxFuture<'static, Msg>) {
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let msg = future.await;
            send_msg(&tx, msg);
        });
    }

    fn probe_panes(&self) {
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let snapshot = tokio::task::spawn_blocking(crate::tmux::panes::current)
                .await
                .unwrap_or_default();
            send_msg(&tx, Msg::PaneSnapshotUpdated(snapshot));
        });
    }

    fn pause_side_effects(&self, bell: bool) {
        if bell {
            print!("\x07");
            if let Err(error) = std::io::stdout().flush() {
                tracing::debug!(%error, "failed to flush dashboard pause bell");
            }
        }
    }
}

fn snapshot_file_msg(path: &Path, now: DateTime<Utc>) -> Msg {
    match tracked_entries::snapshot_from_file(path, now) {
        Ok(snapshot) => {
            let source_state = ReadSourceState::from_snapshot(&snapshot);
            snapshot_msg(snapshot, source_state)
        }
        Err(SnapshotError::PrePurgeState) => snapshot_msg(
            tracked_entries::snapshot_for_error_path(
                path,
                now,
                SnapshotError::PrePurgeState.to_string(),
                true,
            ),
            ReadSourceState::LiveFile,
        ),
        Err(error) => Msg::Error(error.to_string()),
    }
}

fn snapshot_session_msg(resolution: &SessionResolution, now: DateTime<Utc>) -> Msg {
    match tracked_entries::read_session_snapshot(resolution, now) {
        Ok(snapshot) => {
            let source_state = ReadSourceState::from_snapshot(&snapshot);
            snapshot_msg(snapshot, source_state)
        }
        Err(SnapshotError::PrePurgeState) => snapshot_msg(
            tracked_entries::snapshot_for_error(
                &resolution.session,
                resolution.state_path.clone(),
                now,
                SnapshotError::PrePurgeState.to_string(),
                true,
            ),
            ReadSourceState::LiveFile,
        ),
        Err(SnapshotError::StateFileMissing { .. }) => snapshot_msg(
            DashboardSnapshot::empty_for_session(
                &resolution.session,
                resolution.state_path.clone(),
                now,
            ),
            ReadSourceState::NoActiveRun,
        ),
        Err(error) => Msg::Error(error.to_string()),
    }
}

fn snapshot_run_msg(source: &RunSnapshotSource, now: DateTime<Utc>) -> Msg {
    match run_history::load_run_snapshot(
        &source.project_root,
        &source.run_id,
        source.snapshot.as_deref(),
        now,
    ) {
        Ok(loaded) => {
            let archived_at = loaded
                .metadata
                .terminated_at
                .unwrap_or(loaded.snapshot.updated_at);
            let source_state = if loaded.metadata.imported {
                ReadSourceState::ImportedArchive {
                    run_id: loaded.metadata.run_id,
                    archived_at,
                }
            } else if source.read_only || loaded.metadata.terminated {
                ReadSourceState::ArchivedRun {
                    run_id: loaded.metadata.run_id,
                    archived_at,
                }
            } else {
                ReadSourceState::ActiveRun {
                    run_id: Some(loaded.metadata.run_id),
                }
            };
            snapshot_msg(loaded.snapshot, source_state)
        }
        Err(error) => Msg::Error(error.to_string()),
    }
}

fn snapshot_msg(snapshot: DashboardSnapshot, source_state: ReadSourceState) -> Msg {
    Msg::SnapshotUpdated {
        snapshot: Box::new(snapshot),
        source_state,
    }
}

fn send_msg(tx: &mpsc::UnboundedSender<Msg>, msg: Msg) {
    if tx.send(msg).is_err() {
        tracing::debug!("dashboard message receiver dropped");
    }
}
