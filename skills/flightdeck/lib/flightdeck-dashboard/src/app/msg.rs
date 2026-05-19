use crossterm::event::KeyEvent;

use crate::activity::ActivityEvent;
use crate::app::hitmap::ClickAction;
use crate::app::model::ReadSourceState;
use crate::cost::SessionTotals;
use crate::daemon::rpc::DaemonStatus as RuntimeDaemonStatus;
use crate::settings_catalog::SettingsSaveResult;
use crate::state::snapshot::{DashboardSnapshot, Event};
use crate::tmux::panes::PaneSnapshot;
use crate::watcher::WatcherEvent;

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
    WatcherEvent(WatcherEvent),
    DaemonStatus(RuntimeDaemonStatus),
    CostUpdated(SessionTotals),
    PaneSnapshotUpdated(PaneSnapshot),
    SettingsSaved(Result<SettingsSaveResult, String>),
    ActionCompleted(Result<String, String>),
    Error(String),
    Quit,
}
