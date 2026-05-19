use std::path::PathBuf;

use futures::future::BoxFuture;

use crate::state::tracked_entries::SessionResolution;

use super::msg::Msg;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SnapshotSource {
    Demo(&'static str),
    File(PathBuf),
    Session(SessionResolution),
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
