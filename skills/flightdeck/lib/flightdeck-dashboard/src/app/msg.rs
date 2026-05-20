use crossterm::event::KeyEvent;

use crate::activity::ActivityEvent;
use crate::app::command::SnapshotSource;
use crate::app::hitmap::ClickAction;
use crate::app::model::ReadSourceState;
use crate::cost::SessionTotals;
use crate::daemon::rpc::DaemonStatus as RuntimeDaemonStatus;
use crate::settings_catalog::SettingsSaveResult;
use crate::state::run_history::{HistoryRun, ImportSummary, LoadedRunSnapshot};
use crate::state::snapshot::{DashboardSnapshot, Event};
use crate::tmux::panes::PaneSnapshot;
use crate::watcher::WatcherEvent;

#[derive(Debug)]
pub struct ActiveRunSnapshot {
    pub snapshot: DashboardSnapshot,
    pub source: SnapshotSource,
    pub source_state: ReadSourceState,
}

#[derive(Debug)]
pub struct NoActiveRunSnapshot {
    pub message: String,
    pub snapshot: DashboardSnapshot,
    pub source: SnapshotSource,
}

#[derive(Debug)]
pub enum ActiveRunLoad {
    Loaded(Box<ActiveRunSnapshot>),
    NoActive(Box<NoActiveRunSnapshot>),
}

#[derive(Debug)]
pub enum Msg {
    Tick,
    AnimateTick,
    KeyPressed(KeyEvent),
    Click(ClickAction),
    Resize(u16, u16),
    SnapshotUpdated {
        snapshot: Box<DashboardSnapshot>,
        source_state: ReadSourceState,
    },
    EventReceived(Event),
    ActivityRefreshed(Vec<ActivityEvent>),
    ActivityFilterChanged,
    ActivityExport,
    HistoryLoaded(Result<Vec<HistoryRun>, String>),
    HistorySnapshotLoaded(Result<Box<LoadedRunSnapshot>, String>),
    ActiveRunLoaded(Result<ActiveRunLoad, String>),
    LegacyImportCompleted(Result<ImportSummary, String>),
    WatcherEvent(WatcherEvent),
    DaemonStatus(RuntimeDaemonStatus),
    CostUpdated(SessionTotals),
    PaneSnapshotUpdated(PaneSnapshot),
    SettingsSaved(Result<SettingsSaveResult, String>),
    ActionCompleted(Result<String, String>),
    Error(String),
    Quit,
}
