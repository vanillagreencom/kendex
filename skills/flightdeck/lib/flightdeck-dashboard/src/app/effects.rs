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
    match active_session_snapshot(resolution, now) {
        Ok((snapshot, source_state)) => snapshot_msg(snapshot, source_state),
        Err(error) => Msg::Error(error),
    }
}

fn active_session_snapshot(
    resolution: &SessionResolution,
    now: DateTime<Utc>,
) -> Result<(DashboardSnapshot, ReadSourceState), String> {
    let lookup =
        run_history::load_active_run_metadata(&resolution.project_root, &resolution.session)
            .map_err(|error| error.to_string());
    active_session_snapshot_for_lookup_result(resolution, now, lookup)
}

fn active_session_snapshot_for_lookup_result(
    resolution: &SessionResolution,
    now: DateTime<Utc>,
    lookup: Result<run_history::ActiveRunLookup, String>,
) -> Result<(DashboardSnapshot, ReadSourceState), String> {
    let lookup = match lookup {
        Ok(lookup) => lookup,
        Err(error) => {
            let mut snapshot = no_active_snapshot(resolution, now);
            snapshot.master_error = Some(format!("run history unavailable: {error}"));
            return Ok((snapshot, ReadSourceState::NoActiveRun));
        }
    };
    active_session_snapshot_for_lookup(resolution, now, lookup)
}

fn active_session_snapshot_for_lookup(
    resolution: &SessionResolution,
    now: DateTime<Utc>,
    lookup: run_history::ActiveRunLookup,
) -> Result<(DashboardSnapshot, ReadSourceState), String> {
    match lookup {
        run_history::ActiveRunLookup::None | run_history::ActiveRunLookup::Mismatched { .. } => {
            Ok((
                no_active_snapshot(resolution, now),
                ReadSourceState::NoActiveRun,
            ))
        }
        run_history::ActiveRunLookup::Matched(metadata) if metadata.terminated => Ok((
            no_active_snapshot(resolution, now),
            ReadSourceState::NoActiveRun,
        )),
        run_history::ActiveRunLookup::Matched(metadata) => {
            let mut snapshot = match tracked_entries::read_session_snapshot(resolution, now) {
                Ok(snapshot) if !snapshot.terminated => snapshot,
                Ok(_) | Err(SnapshotError::StateFileMissing { .. }) => {
                    return Ok((
                        no_active_snapshot(resolution, now),
                        ReadSourceState::NoActiveRun,
                    ));
                }
                Err(SnapshotError::PrePurgeState) => tracked_entries::snapshot_for_error(
                    &resolution.session,
                    resolution.state_path.clone(),
                    now,
                    SnapshotError::PrePurgeState.to_string(),
                    true,
                ),
                Err(error) => return Err(error.to_string()),
            };
            snapshot.project_root.clone_from(&resolution.project_root);
            Ok((
                snapshot,
                ReadSourceState::ActiveRun {
                    run_id: Some(metadata.run_id),
                },
            ))
        }
    }
}

fn no_active_snapshot(resolution: &SessionResolution, now: DateTime<Utc>) -> DashboardSnapshot {
    let mut snapshot = DashboardSnapshot::empty_for_session(
        &resolution.session,
        resolution.state_path.clone(),
        now,
    );
    snapshot.project_root.clone_from(&resolution.project_root);
    snapshot
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

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};

    use chrono::{TimeZone, Utc};
    use serde_json::json;

    use crate::state::run_history::{ActiveRunLookup, RunMetadata};

    use super::*;

    #[test]
    fn watched_session_reload_with_no_active_pointer_stays_no_active() {
        with_reload_fixture(|ctx| {
            write_live_state(&ctx.project, "S", false);

            let (snapshot, source_state) = active_session_snapshot_for_lookup(
                &ctx.resolution("S"),
                fixed_now(),
                ActiveRunLookup::None,
            )
            .expect("no-active snapshot");

            assert_no_active_snapshot(snapshot, source_state, &ctx.project, "S");
        });
    }

    #[test]
    fn watched_session_reload_with_mismatched_active_pointer_stays_no_active() {
        with_reload_fixture(|ctx| {
            write_live_state(&ctx.project, "S", false);

            let (snapshot, source_state) = active_session_snapshot_for_lookup(
                &ctx.resolution("S"),
                fixed_now(),
                ActiveRunLookup::Mismatched {
                    run_id: String::from("run-other"),
                    expected_session: String::from("S"),
                    actual_session: Some(String::from("OTHER")),
                },
            )
            .expect("no-active snapshot");

            assert_no_active_snapshot(snapshot, source_state, &ctx.project, "S");
        });
    }

    #[test]
    fn watched_session_reload_with_active_lookup_error_stays_no_active() {
        with_reload_fixture(|ctx| {
            write_live_state(&ctx.project, "S", false);

            let (snapshot, source_state) = active_session_snapshot_for_lookup_result(
                &ctx.resolution("S"),
                fixed_now(),
                Err(String::from("invalid run metadata JSON: forged path")),
            )
            .expect("no-active snapshot");

            assert_no_active_snapshot(snapshot, source_state, &ctx.project, "S");
        });
    }

    #[test]
    fn watched_session_reload_with_terminated_live_state_stays_no_active() {
        with_reload_fixture(|ctx| {
            write_live_state(&ctx.project, "S", true);

            let (snapshot, source_state) = active_session_snapshot_for_lookup(
                &ctx.resolution("S"),
                fixed_now(),
                ActiveRunLookup::Matched(run_metadata("run-1", "S")),
            )
            .expect("no-active snapshot");

            assert_no_active_snapshot(snapshot, source_state, &ctx.project, "S");
        });
    }

    #[test]
    fn watched_session_reload_with_terminated_active_metadata_stays_no_active() {
        with_reload_fixture(|ctx| {
            write_live_state(&ctx.project, "S", false);
            let mut metadata = run_metadata("run-1", "S");
            metadata.terminated = true;
            metadata.terminated_at = Some(fixed_now());

            let (snapshot, source_state) = active_session_snapshot_for_lookup(
                &ctx.resolution("S"),
                fixed_now(),
                ActiveRunLookup::Matched(metadata),
            )
            .expect("no-active snapshot");

            assert_no_active_snapshot(snapshot, source_state, &ctx.project, "S");
        });
    }

    #[test]
    fn watched_session_reload_with_matching_active_pointer_loads_live_state() {
        with_reload_fixture(|ctx| {
            write_live_state(&ctx.project, "S", false);

            let (snapshot, source_state) = active_session_snapshot_for_lookup(
                &ctx.resolution("S"),
                fixed_now(),
                ActiveRunLookup::Matched(run_metadata("run-1", "S")),
            )
            .expect("live snapshot");

            assert!(matches!(
                source_state,
                ReadSourceState::ActiveRun { run_id: Some(ref run_id) } if run_id == "run-1"
            ));
            assert_eq!(snapshot.sessions.len(), 1);
        });
    }

    struct ReloadFixture {
        project: PathBuf,
    }

    impl ReloadFixture {
        fn resolution(&self, session: &str) -> SessionResolution {
            SessionResolution {
                project_root: self.project.clone(),
                state_dir: self.project.join("tmp"),
                session: session.to_owned(),
                state_path: live_state_path(&self.project, session),
            }
        }
    }

    fn with_reload_fixture(test: impl FnOnce(&ReloadFixture)) {
        let temp = tempfile::tempdir().expect("tempdir");
        let project = temp.path().join("project");
        fs::create_dir_all(project.join("tmp")).expect("project tmp");
        fs::write(project.join("vstack.toml"), "").expect("project marker");
        test(&ReloadFixture { project });
    }

    fn run_metadata(run_id: &str, session: &str) -> RunMetadata {
        serde_json::from_value(json!({
            "run_id": run_id,
            "project_root": "/project",
            "tmux_session": session,
            "state_path": format!("/store/{run_id}/state.json"),
            "activity_path": format!("/store/{run_id}/activity.jsonl"),
            "summary_path": null,
            "snapshots_path": format!("/store/{run_id}/snapshots"),
            "started_at": "2026-05-19T12:00:00Z",
            "last_seen_at": "2026-05-19T12:01:00Z",
            "terminated": false,
            "terminated_at": null,
            "imported": false,
            "imported_from": null
        }))
        .expect("run metadata")
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
            "entries": {
                "entry-1": {
                    "id": "entry-1",
                    "kind": "adhoc",
                    "state": "waiting",
                    "title": "Stale live row",
                    "harness": "pi",
                    "created_at": "2026-05-19T12:00:00Z",
                    "updated_at": "2026-05-19T12:01:00Z"
                }
            },
            "merge_queue": [],
            "conflict_graph": { "edges": [], "computed_at": "2026-05-19T12:01:00Z" },
            "paused_for_user": null
        })
    }

    fn assert_no_active_snapshot(
        snapshot: DashboardSnapshot,
        source_state: ReadSourceState,
        project: &Path,
        session: &str,
    ) {
        assert_eq!(source_state, ReadSourceState::NoActiveRun);
        assert!(snapshot.sessions.is_empty());
        assert_eq!(
            snapshot.master_state_path,
            live_state_path(project, session)
        );
    }

    fn fixed_now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 5, 19, 12, 10, 0)
            .single()
            .expect("fixed timestamp")
    }
}
