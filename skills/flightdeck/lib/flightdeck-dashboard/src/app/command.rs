use std::path::PathBuf;

use chrono::{DateTime, Utc};
use futures::future::BoxFuture;

use crate::state::tracked_entries::SessionResolution;

use super::msg::Msg;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunSnapshotSource {
    pub project_root: PathBuf,
    pub run_id: String,
    pub snapshot: Option<String>,
    pub state_path: PathBuf,
    pub activity_path: PathBuf,
    pub run_dir: PathBuf,
    pub imported: bool,
    pub terminated_at: Option<DateTime<Utc>>,
    pub read_only: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SnapshotSource {
    Demo(&'static str),
    File(PathBuf),
    Session(SessionResolution),
    Run(RunSnapshotSource),
    Socket(PathBuf),
}

pub enum Cmd {
    Render,
    RequestSnapshot(SnapshotSource),
    ReloadFromSource(SnapshotSource),
    LogAction(String),
    PauseSideEffects { bell: bool },
    ProbePanes,
    Spawn(BoxFuture<'static, Msg>),
}
