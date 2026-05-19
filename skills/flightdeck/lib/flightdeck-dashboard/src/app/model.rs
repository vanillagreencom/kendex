use std::collections::{BTreeSet, HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::time::Instant;

use ratatui::style::Style;
use regex::Regex;

use chrono::{DateTime, Utc};

use crate::actions::WriteAction;
use crate::activity::{
    format as activity_format, ActivityEvent, Importance, JsonlActivitySource, Severity,
};
use crate::app::command::SnapshotSource;
use crate::app::motion::{EffectInstance, MotionLevel};
use crate::app::reload::ReloadCoalescer;
use crate::app::theme::{Palette, Theme};
use crate::cost::{CostMetrics, PricingTable, SessionTotals};
use crate::settings_catalog::SettingsState;
use crate::state::snapshot::{
    DashboardSnapshot, Event, EventImportance, SessionKind, SessionState, TrackedSession,
};
use crate::state::tracked_entries;
use crate::tmux::panes::PaneSnapshot;

pub type Clock = fn() -> DateTime<Utc>;

pub const RECENT_EVENTS_CAP: usize = 500;
pub const TABS_WIDE_THRESHOLD: u16 = 140;
pub const TABS_MEDIUM_THRESHOLD: u16 = 110;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Tab {
    Overview,
    Activity,
    Conversations,
    Merges,
    Decisions,
    Costs,
    Daemon,
}

impl Tab {
    pub const ALL: [Self; 7] = [
        Self::Overview,
        Self::Activity,
        Self::Conversations,
        Self::Merges,
        Self::Decisions,
        Self::Costs,
        Self::Daemon,
    ];

    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Overview => "Overview",
            Self::Activity => "Activity",
            Self::Conversations => "Conversations",
            Self::Merges => "Merges",
            Self::Decisions => "Decisions",
            Self::Costs => "Costs",
            Self::Daemon => "Daemon",
        }
    }

    #[must_use]
    pub const fn issue_mode_label(self) -> &'static str {
        self.label()
    }

    #[must_use]
    pub const fn medium_label(self) -> &'static str {
        match self {
            Self::Overview => "Overview",
            Self::Activity => "Activity",
            Self::Conversations => "Convos",
            Self::Merges => "Merges",
            Self::Decisions => "Decisions",
            Self::Costs => "Costs",
            Self::Daemon => "Daemon",
        }
    }

    #[must_use]
    pub const fn narrow_label(self) -> &'static str {
        match self {
            Self::Overview => "Ov",
            Self::Activity => "Act",
            Self::Conversations => "Conv",
            Self::Merges => "Merg",
            Self::Decisions => "Dec",
            Self::Costs => "Cost",
            Self::Daemon => "Daem",
        }
    }

    #[must_use]
    pub fn index(self) -> usize {
        Self::ALL.iter().position(|tab| *tab == self).unwrap_or(0)
    }

    #[must_use]
    pub fn next(self) -> Self {
        let idx = self.index();
        Self::ALL[(idx + 1) % Self::ALL.len()]
    }

    #[must_use]
    pub fn previous(self) -> Self {
        let idx = self.index();
        let len = Self::ALL.len();
        Self::ALL[(idx + len - 1) % len]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UiFlags {
    pub compact: bool,
    pub filter_open: bool,
    pub hide_noise: bool,
}

#[derive(Debug, Clone)]
pub struct FeedFilter {
    pub input: String,
    pub pattern: String,
    pub regex: Option<Regex>,
    pub error: Option<String>,
}

impl FeedFilter {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            input: String::new(),
            pattern: String::new(),
            regex: None,
            error: None,
        }
    }

    pub fn begin_edit(&mut self) {
        self.input.clone_from(&self.pattern);
        self.error = None;
    }

    pub fn clear(&mut self) {
        self.input.clear();
        self.pattern.clear();
        self.regex = None;
        self.error = None;
    }

    pub fn commit(&mut self) -> bool {
        if self.input.trim().is_empty() {
            self.clear();
            return true;
        }
        match Regex::new(&self.input) {
            Ok(regex) => {
                self.pattern.clone_from(&self.input);
                self.regex = Some(regex);
                self.error = None;
                true
            }
            Err(error) => {
                self.error = Some(error.to_string());
                false
            }
        }
    }

    #[must_use]
    pub fn matches(&self, event: &Event) -> bool {
        self.regex.as_ref().map_or(true, |regex| {
            regex.is_match(&event.message) || regex.is_match(event.source.as_chip())
        })
    }

    #[must_use]
    pub fn matches_activity(&self, event: &ActivityEvent) -> bool {
        self.regex
            .as_ref()
            .map_or(true, |regex| regex.is_match(&event.searchable_text()))
    }
}

impl Default for FeedFilter {
    fn default() -> Self {
        Self::new()
    }
}

pub const ACTIVITY_TYPE_CHIPS: [&str; 9] = [
    "agent", "bg", "question", "decision", "pr", "issue", "linear", "daemon", "session",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivitySeverityFilter {
    All,
    Exact(Severity),
}

impl ActivitySeverityFilter {
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::All => "all severities",
            Self::Exact(severity) => severity.as_str(),
        }
    }

    #[must_use]
    pub fn matches(self, severity: Severity) -> bool {
        match self {
            Self::All => true,
            Self::Exact(expected) => expected == severity,
        }
    }

    #[must_use]
    pub fn next(self) -> Self {
        match self {
            Self::All => Self::Exact(Severity::Info),
            Self::Exact(Severity::Info) => Self::Exact(Severity::Success),
            Self::Exact(Severity::Success) => Self::Exact(Severity::Warning),
            Self::Exact(Severity::Warning) => Self::Exact(Severity::Error),
            Self::Exact(Severity::Error) => Self::Exact(Severity::Debug),
            Self::Exact(Severity::Debug) => Self::All,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ActivityFilter {
    pub visible_types: BTreeSet<String>,
    pub severity: ActivitySeverityFilter,
    pub session: Option<String>,
}

impl ActivityFilter {
    #[must_use]
    pub fn new() -> Self {
        Self {
            visible_types: ACTIVITY_TYPE_CHIPS.into_iter().map(str::to_owned).collect(),
            severity: ActivitySeverityFilter::All,
            session: None,
        }
    }

    #[must_use]
    pub fn matches(
        &self,
        event: &ActivityEvent,
        hide_noise: bool,
        text_filter: &FeedFilter,
    ) -> bool {
        if hide_noise
            && (event.noisy
                || event.importance == Importance::Noisy
                || event.severity == Severity::Debug)
        {
            return false;
        }
        let chip = activity_format::event_chip_for(event);
        self.visible_types.contains(chip)
            && self.severity.matches(event.severity)
            && self
                .session
                .as_deref()
                .map_or(true, |session| event.session_label() == session)
            && text_filter.matches_activity(event)
    }

    pub fn toggle_type(&mut self, chip: &str) {
        if !ACTIVITY_TYPE_CHIPS.contains(&chip) {
            return;
        }
        if self.visible_types.contains(chip) {
            self.visible_types.remove(chip);
        } else {
            self.visible_types.insert(chip.to_owned());
        }
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }
}

impl Default for ActivityFilter {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone)]
pub struct ActivityView {
    pub events: Vec<ActivityEvent>,
    pub filter: ActivityFilter,
    pub filter_cursor: usize,
    pub malformed_lines: u64,
    source: Option<JsonlActivitySource>,
}

impl ActivityView {
    #[must_use]
    pub fn new() -> Self {
        Self::with_default_filter()
    }

    pub fn with_default_filter() -> Self {
        Self {
            events: Vec::new(),
            filter: ActivityFilter::new(),
            filter_cursor: 0,
            malformed_lines: 0,
            source: None,
        }
    }

    pub fn set_source(&mut self, source: Option<JsonlActivitySource>) {
        self.source = source;
        self.events.clear();
        self.malformed_lines = 0;
    }

    pub fn set_events(&mut self, events: Vec<ActivityEvent>) {
        self.events = events;
    }

    pub fn poll_source(&mut self) -> Vec<ActivityEvent> {
        let Some(source) = &mut self.source else {
            return self.events.clone();
        };
        let events = crate::activity::ActivitySource::poll(source);
        self.malformed_lines = source.malformed_lines();
        self.events.clone_from(&events);
        events
    }

    #[must_use]
    pub fn source_matches(&self, state_dir: &Path, session_name: &str) -> bool {
        self.source.as_ref().is_some_and(|source| {
            source.state_dir() == state_dir && source.session_name() == session_name
        })
    }

    #[must_use]
    pub fn filtered_events<'a>(
        &'a self,
        hide_noise: bool,
        text_filter: &'a FeedFilter,
    ) -> Vec<&'a ActivityEvent> {
        self.events
            .iter()
            .rev()
            .filter(|event| self.filter.matches(event, hide_noise, text_filter))
            .collect()
    }

    #[must_use]
    pub fn hidden_noise_count(&self, text_filter: &FeedFilter) -> usize {
        self.events
            .iter()
            .filter(|event| {
                event.noisy
                    || event.importance == Importance::Noisy
                    || event.severity == Severity::Debug
            })
            .filter(|event| self.filter.matches(event, false, text_filter))
            .count()
    }

    #[must_use]
    pub fn row_count(&self, hide_noise: bool, text_filter: &FeedFilter) -> usize {
        self.filtered_events(hide_noise, text_filter)
            .len()
            .saturating_add(usize::from(
                hide_noise && self.hidden_noise_count(text_filter) > 0,
            ))
    }

    #[must_use]
    pub fn session_options(&self) -> Vec<String> {
        let mut sessions = self
            .events
            .iter()
            .map(|event| event.session_label().to_owned())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        sessions.retain(|session| session != "—");
        sessions
    }

    pub fn cycle_session_filter(&mut self) {
        let sessions = self.session_options();
        if sessions.is_empty() {
            self.filter.session = None;
            return;
        }
        self.filter.session = match self.filter.session.as_deref() {
            None => sessions.first().cloned(),
            Some(current) => sessions
                .iter()
                .position(|session| session == current)
                .and_then(|idx| sessions.get(idx + 1).cloned()),
        };
    }

    #[must_use]
    pub fn decision_events(&self) -> Vec<&ActivityEvent> {
        let mut events = self
            .events
            .iter()
            .filter(|event| event.event_type.as_str() == "decision.recorded")
            .collect::<Vec<_>>();
        events.sort_by(|left, right| right.ts.cmp(&left.ts));
        events
    }
}

impl Default for ActivityView {
    fn default() -> Self {
        Self::with_default_filter()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadSourceState {
    Live,
    Archive { archived_at: DateTime<Utc> },
    Missing,
}

impl ReadSourceState {
    #[must_use]
    pub fn from_snapshot(snapshot: &DashboardSnapshot) -> Self {
        if is_archive_path(&snapshot.master_state_path) {
            return Self::Archive {
                archived_at: snapshot.terminated_at.unwrap_or(snapshot.updated_at),
            };
        }
        Self::Live
    }
}

fn is_archive_path(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.ends_with(".json.archive"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModalState {
    None,
    Help,
    ThemePicker,
    DecisionDetail,
    SessionDetail,
    EventDetail,
    ActivityFilter,
    FilterInput,
    ConfirmAction,
    PricingDetail,
    Settings,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfirmDialog {
    pub title: String,
    pub body: String,
    pub destructive: bool,
    pub primary_label: String,
    pub secondary_label: String,
    pub action: WriteAction,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActionStatus {
    pub message: String,
    pub success: bool,
}

#[derive(Debug)]
pub struct Model {
    pub current_tab: Tab,
    pub tabs_enabled: Vec<Tab>,
    pub snapshot: DashboardSnapshot,
    pub snapshot_source: SnapshotSource,
    pub read_source_state: ReadSourceState,
    pub activity: ActivityView,
    pub recent_events: VecDeque<Event>,
    pub snapshot_diff_drops: u64,
    pub reload_coalescer: ReloadCoalescer,
    pub now: DateTime<Utc>,
    pub motion: MotionLevel,
    pub theme: Theme,
    pub motion_clock: Instant,
    pub active_effects: Vec<EffectInstance>,
    pub selection: HashMap<Tab, usize>,
    overview_selection_initialized: bool,
    pub show_help: bool,
    pub modal: ModalState,
    pub theme_picker_index: usize,
    pub popup_scroll: usize,
    pub ui: UiFlags,
    pub feed_filter: FeedFilter,
    pub event_detail: Option<usize>,
    pub current_pane_id: Option<String>,
    pub tmux_panes: PaneSnapshot,
    pub cost_totals: SessionTotals,
    pub pricing_table: PricingTable,
    pub settings: SettingsState,
    pub confirm: Option<ConfirmDialog>,
    pub status_message: Option<ActionStatus>,
    pub quit_requested: bool,
    pub error: Option<String>,
    pub clock: Clock,
    pub animate_frame: u64,
}

impl Model {
    #[must_use]
    pub fn new(
        snapshot: DashboardSnapshot,
        snapshot_source: SnapshotSource,
        motion: MotionLevel,
        theme: Theme,
        clock: Clock,
    ) -> Self {
        let settings = SettingsState::load_current();
        Self::new_with_settings(snapshot, snapshot_source, motion, theme, settings, clock)
    }

    #[must_use]
    pub fn new_with_settings(
        snapshot: DashboardSnapshot,
        snapshot_source: SnapshotSource,
        motion: MotionLevel,
        theme: Theme,
        settings: SettingsState,
        clock: Clock,
    ) -> Self {
        let tabs_enabled = enabled_tabs_for(&snapshot);
        let mut selection = HashMap::with_capacity(Tab::ALL.len());
        for tab in Tab::ALL {
            selection.insert(tab, 0);
        }
        let read_source_state = ReadSourceState::from_snapshot(&snapshot);
        let recent_events = snapshot.recent_events.clone();
        let mut activity = ActivityView::new();
        if let SnapshotSource::Demo(name) = &snapshot_source {
            if let Ok(events) = crate::fixtures::load_demo_activity(name) {
                activity.set_events(events);
            }
        } else {
            activity.set_source(activity_source_for(&snapshot, &snapshot_source));
            activity.poll_source();
        }
        let mut model = Self {
            current_tab: Tab::Overview,
            tabs_enabled,
            snapshot,
            snapshot_source,
            read_source_state,
            activity,
            recent_events,
            snapshot_diff_drops: 0,
            reload_coalescer: ReloadCoalescer::new(),
            now: clock(),
            motion,
            theme,
            motion_clock: Instant::now(),
            active_effects: Vec::with_capacity(8),
            selection,
            overview_selection_initialized: false,
            show_help: false,
            modal: ModalState::None,
            theme_picker_index: theme.index(),
            popup_scroll: 0,
            ui: UiFlags {
                compact: false,
                filter_open: false,
                hide_noise: true,
            },
            feed_filter: FeedFilter::new(),
            event_detail: None,
            current_pane_id: std::env::var("TMUX_PANE")
                .ok()
                .filter(|pane| !pane.is_empty()),
            tmux_panes: PaneSnapshot::default(),
            cost_totals: SessionTotals::default(),
            pricing_table: PricingTable::load(),
            settings,
            confirm: None,
            status_message: None,
            quit_requested: false,
            error: None,
            clock,
            animate_frame: 0,
        };
        model.initialize_overview_selection();
        model
    }

    pub fn refresh_now(&mut self) {
        self.now = (self.clock)();
    }

    #[must_use]
    pub const fn palette(&self) -> &'static Palette {
        self.theme.palette()
    }

    #[must_use]
    pub fn selection_style(&self) -> Style {
        self.theme.row_style_selected()
    }

    #[must_use]
    pub fn selected_index(&self) -> usize {
        self.selection
            .get(&self.current_tab)
            .copied()
            .unwrap_or_default()
    }

    pub fn set_selected_index(&mut self, value: usize) {
        let max = self.max_selection_index();
        self.selection.insert(self.current_tab, value.min(max));
    }

    pub fn mark_overview_selection_initialized(&mut self) {
        if self.current_tab == Tab::Overview {
            self.overview_selection_initialized = true;
        }
    }

    pub fn initialize_overview_selection(&mut self) {
        if self.overview_selection_initialized {
            return;
        }
        let Some(index) = default_overview_selection(&self.snapshot) else {
            return;
        };
        self.selection.insert(Tab::Overview, index);
        self.overview_selection_initialized = true;
    }

    #[must_use]
    pub fn selected_session(&self) -> Option<&TrackedSession> {
        self.snapshot.sessions.get(self.selected_index())
    }

    #[must_use]
    pub fn max_selection_index(&self) -> usize {
        let len = match self.current_tab {
            Tab::Overview => self.snapshot.sessions.len(),
            Tab::Activity => self.activity_row_count(),
            Tab::Conversations => self.snapshot.conversations.len(),
            Tab::Merges => self
                .snapshot
                .merge_queue
                .len()
                .saturating_add(self.snapshot.conflict_graph.edges.len()),
            Tab::Decisions => self.decision_count(),
            Tab::Costs => self.cost_row_count(),
            Tab::Daemon => 1,
        };
        len.saturating_sub(1)
    }

    pub fn clamp_selection(&mut self) {
        if !self.tabs_enabled.contains(&self.current_tab) {
            self.current_tab = self.tabs_enabled.first().copied().unwrap_or(Tab::Overview);
        }
        let current = self.selected_index();
        self.set_selected_index(current);
    }

    pub fn refresh_tabs_enabled(&mut self) {
        self.tabs_enabled = enabled_tabs_for(&self.snapshot);
        self.clamp_selection();
    }

    #[must_use]
    pub fn selected_tab_position(&self) -> usize {
        self.tabs_enabled
            .iter()
            .position(|tab| *tab == self.current_tab)
            .unwrap_or_default()
    }

    #[must_use]
    pub fn tab_label(&self, tab: Tab) -> &'static str {
        self.tab_label_for_width(tab, u16::MAX)
    }

    #[must_use]
    pub fn tab_label_for_width(&self, tab: Tab, available_width: u16) -> &'static str {
        if available_width >= TABS_WIDE_THRESHOLD {
            if tab == Tab::Merges && self.has_issue_sessions() {
                return tab.issue_mode_label();
            }
            tab.label()
        } else if available_width >= TABS_MEDIUM_THRESHOLD {
            tab.medium_label()
        } else {
            tab.narrow_label()
        }
    }

    #[must_use]
    pub fn next_tab(&self) -> Tab {
        let current = self.selected_tab_position();
        self.tabs_enabled
            .get((current + 1) % self.tabs_enabled.len().max(1))
            .copied()
            .unwrap_or(Tab::Overview)
    }

    #[must_use]
    pub fn previous_tab(&self) -> Tab {
        let len = self.tabs_enabled.len();
        if len == 0 {
            return Tab::Overview;
        }
        let current = self.selected_tab_position();
        self.tabs_enabled[(current + len - 1) % len]
    }

    #[must_use]
    pub fn has_issue_sessions(&self) -> bool {
        self.snapshot
            .sessions
            .iter()
            .any(|session| session.kind == SessionKind::Issue)
    }

    #[must_use]
    pub fn decision_count(&self) -> usize {
        let activity_decisions = self.activity.decision_events().len();
        if activity_decisions > 0 {
            return activity_decisions;
        }
        self.snapshot
            .sessions
            .iter()
            .map(|session| session.decisions_log.len())
            .sum()
    }

    #[must_use]
    pub fn is_observer(&self) -> bool {
        let Some(current) = self.current_pane_id.as_deref() else {
            return false;
        };
        let Some(owner) = &self.snapshot.owner else {
            return false;
        };
        owner
            .pane_id
            .as_deref()
            .is_some_and(|owner_pane| owner_pane != current)
    }

    pub fn push_event(&mut self, event: Event) {
        if self.recent_events.len() >= RECENT_EVENTS_CAP {
            self.recent_events.pop_front();
        }
        self.recent_events.push_back(event);
    }

    #[must_use]
    pub fn filtered_events(&self) -> Vec<&Event> {
        self.recent_events
            .iter()
            .rev()
            .filter(|event| !self.ui.hide_noise || event.importance > EventImportance::Low)
            .filter(|event| self.feed_filter.matches(event))
            .collect()
    }

    #[must_use]
    pub fn hidden_noise_count(&self) -> usize {
        if !self.ui.hide_noise {
            return 0;
        }
        self.recent_events
            .iter()
            .rev()
            .filter(|event| event.importance == EventImportance::Low)
            .filter(|event| self.feed_filter.matches(event))
            .count()
    }

    #[must_use]
    pub fn activity_events(&self) -> Vec<&ActivityEvent> {
        self.activity
            .filtered_events(self.ui.hide_noise, &self.feed_filter)
    }

    #[must_use]
    pub fn hidden_activity_noise_count(&self) -> usize {
        if !self.ui.hide_noise {
            return 0;
        }
        self.activity.hidden_noise_count(&self.feed_filter)
    }

    #[must_use]
    pub fn activity_row_count(&self) -> usize {
        self.activity
            .row_count(self.ui.hide_noise, &self.feed_filter)
    }

    pub fn set_activity_events(&mut self, events: Vec<ActivityEvent>) {
        self.activity.set_events(events);
    }

    pub fn push_activity_event(&mut self, event: ActivityEvent) {
        let mut events = self.activity.events.clone();
        events.push(event);
        if events.len() > crate::activity::MAX_EVENTS_IN_MEMORY {
            let drop_count = events
                .len()
                .saturating_sub(crate::activity::MAX_EVENTS_IN_MEMORY);
            events.drain(..drop_count);
        }
        self.activity.set_events(events);
    }

    pub fn poll_activity_source(&mut self) -> Vec<ActivityEvent> {
        self.activity.poll_source()
    }

    pub fn sync_activity_source(&mut self) {
        let Some(source) = activity_source_for(&self.snapshot, &self.snapshot_source) else {
            self.activity.set_source(None);
            return;
        };
        if !self
            .activity
            .source_matches(source.state_dir(), source.session_name())
        {
            self.activity.set_source(Some(source));
        }
    }

    #[must_use]
    pub fn cost_for_entry(&self, entry_id: &str) -> Option<&CostMetrics> {
        self.cost_totals.by_entry.get(entry_id)
    }

    #[must_use]
    pub fn cost_row_count(&self) -> usize {
        self.snapshot.sessions.len()
    }

    pub fn set_tmux_panes(&mut self, panes: PaneSnapshot) {
        self.tmux_panes = panes;
    }

    #[must_use]
    pub fn session_is_stale(&self, session: &TrackedSession) -> bool {
        let Some(pane_id) = session.pane_id.as_deref() else {
            return false;
        };
        self.tmux_panes.is_loaded() && !self.tmux_panes.contains(pane_id)
    }
}

fn default_overview_selection(snapshot: &DashboardSnapshot) -> Option<usize> {
    if snapshot.sessions.is_empty() {
        return None;
    }
    if let Some(entry_id) = snapshot
        .paused_for_user
        .as_ref()
        .and_then(|pause| pause.entry_id.as_deref())
    {
        if let Some(index) = snapshot
            .sessions
            .iter()
            .position(|session| session.id == entry_id)
        {
            return Some(index);
        }
    }
    snapshot
        .sessions
        .iter()
        .position(|session| {
            matches!(
                session.state,
                SessionState::Prompting | SessionState::Submitting
            )
        })
        .or_else(|| {
            snapshot.sessions.iter().position(|session| {
                matches!(
                    session.state,
                    SessionState::Waiting | SessionState::Ready | SessionState::MergeReady
                )
            })
        })
        .or(Some(0))
}

fn activity_source_for(
    snapshot: &DashboardSnapshot,
    source: &SnapshotSource,
) -> Option<JsonlActivitySource> {
    let (state_dir, session_name): (PathBuf, String) = match source {
        SnapshotSource::Demo(_) | SnapshotSource::Socket(_) => return None,
        SnapshotSource::File(path) => {
            let state_dir = path.parent().map(Path::to_path_buf)?;
            let session = if snapshot.session_id.is_empty() {
                tracked_entries::session_id_from_state_path(path)
            } else {
                snapshot.session_id.clone()
            };
            (state_dir, session)
        }
        SnapshotSource::Session(resolution) => {
            (resolution.state_dir.clone(), resolution.session.clone())
        }
    };
    Some(JsonlActivitySource::new(state_dir, session_name))
}

fn enabled_tabs_for(snapshot: &DashboardSnapshot) -> Vec<Tab> {
    Tab::ALL
        .into_iter()
        .filter(|tab| {
            *tab != Tab::Merges
                || snapshot
                    .sessions
                    .iter()
                    .any(|session| session.kind == SessionKind::Issue)
        })
        .collect()
}

pub fn utc_now() -> DateTime<Utc> {
    Utc::now()
}
