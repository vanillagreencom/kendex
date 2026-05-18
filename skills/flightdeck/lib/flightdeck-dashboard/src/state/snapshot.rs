use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::path::PathBuf;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use super::schema::{
    AdapterMetadata, DecisionLogEntry, DomainBlock, LaunchInfo, MasterState, OwnerBlock,
    TrackedEntry, TrackedIssueDomain,
};

#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub enum SessionKind {
    #[default]
    Adhoc,
    Issue,
    Workflow,
    Other(String),
}

impl SessionKind {
    #[must_use]
    pub fn from_label(value: &str) -> Self {
        match value {
            "adhoc" => Self::Adhoc,
            "issue" => Self::Issue,
            "workflow" => Self::Workflow,
            other => Self::Other(other.to_owned()),
        }
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        match self {
            Self::Adhoc => "adhoc",
            Self::Issue => "issue",
            Self::Workflow => "workflow",
            Self::Other(value) => value.as_str(),
        }
    }

    #[must_use]
    pub const fn badge(&self) -> &'static str {
        match self {
            Self::Adhoc => "AH",
            Self::Issue => "ISS",
            Self::Workflow => "WF",
            Self::Other(_) => "??",
        }
    }
}

impl Serialize for SessionKind {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for SessionKind {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Ok(Self::from_label(value.trim()))
    }
}

impl PartialOrd for SessionKind {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for SessionKind {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.as_str().cmp(other.as_str())
    }
}

impl fmt::Display for SessionKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.pad(self.as_str())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub enum SessionState {
    #[default]
    Waiting,
    Prompting,
    Submitting,
    Ready,
    Complete,
    Cancelled,
    Dead,
    MergeReady,
    Merged,
    Aborted,
    Other(String),
}

impl SessionState {
    #[must_use]
    pub fn from_label(value: &str) -> Self {
        match value {
            "waiting" => Self::Waiting,
            "prompting" => Self::Prompting,
            "submitting" => Self::Submitting,
            "ready" => Self::Ready,
            "complete" => Self::Complete,
            "cancelled" => Self::Cancelled,
            "dead" => Self::Dead,
            "merge-ready" => Self::MergeReady,
            "merged" => Self::Merged,
            "aborted" => Self::Aborted,
            other => Self::Other(other.to_owned()),
        }
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        match self {
            Self::Waiting => "waiting",
            Self::Prompting => "prompting",
            Self::Submitting => "submitting",
            Self::Ready => "ready",
            Self::Complete => "complete",
            Self::Cancelled => "cancelled",
            Self::Dead => "dead",
            Self::MergeReady => "merge-ready",
            Self::Merged => "merged",
            Self::Aborted => "aborted",
            Self::Other(value) => value.as_str(),
        }
    }

    #[must_use]
    pub const fn is_transient(&self) -> bool {
        matches!(self, Self::Waiting | Self::Prompting | Self::Submitting)
    }

    #[must_use]
    pub const fn operator_priority(&self) -> u8 {
        match self {
            Self::Prompting => 0,
            Self::Submitting => 1,
            Self::Waiting => 2,
            Self::Ready => 3,
            Self::MergeReady => 4,
            Self::Complete => 5,
            Self::Merged => 6,
            Self::Cancelled => 7,
            Self::Aborted => 8,
            Self::Dead => 9,
            Self::Other(_) => 10,
        }
    }
}

impl Serialize for SessionState {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for SessionState {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Ok(Self::from_label(value.trim()))
    }
}

impl PartialOrd for SessionState {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for SessionState {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.as_str().cmp(other.as_str())
    }
}

impl fmt::Display for SessionState {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.pad(self.as_str())
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct ConflictGraph {
    #[serde(default)]
    pub edges: Vec<(String, String)>,
    pub computed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct PauseInfo {
    pub entry_id: Option<String>,
    pub issue_id: Option<String>,
    pub reason: String,
    pub prompt_text: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DashboardSnapshot {
    pub session_id: String,
    pub project_root: PathBuf,
    pub started_at: Option<DateTime<Utc>>,
    pub updated_at: DateTime<Utc>,
    pub terminated: bool,
    pub terminated_at: Option<DateTime<Utc>>,
    pub master_state_path: PathBuf,
    pub master_archive_error: Option<String>,
    pub master_error: Option<String>,
    pub pre_purge_state: bool,
    pub owner: Option<OwnerBlock>,
    pub daemon: DaemonStatus,
    pub counts: KindCounts,
    pub sessions: Vec<TrackedSession>,
    pub merge_queue: Vec<String>,
    pub conflict_graph: ConflictGraph,
    pub paused_for_user: Option<PauseInfo>,
    pub recent_events: VecDeque<Event>,
    pub conversations: Vec<ConversationStream>,
    pub summary_path: Option<PathBuf>,
}

impl DashboardSnapshot {
    #[must_use]
    pub fn from_master_state(state: MasterState, now: DateTime<Utc>) -> Self {
        let paused_entry_id = state
            .paused_for_user
            .as_ref()
            .and_then(|pause| pause.entry_id.as_deref())
            .map(str::to_owned);
        let mut sessions: Vec<TrackedSession> = state
            .entries
            .into_iter()
            .map(|(key, entry)| TrackedSession::from_entry(key, entry))
            .collect();
        sort_sessions_for_operator(&mut sessions, paused_entry_id.as_deref());
        let counts = KindCounts::from_sessions(&sessions);
        Self {
            session_id: state.session_id,
            project_root: PathBuf::from("."),
            started_at: state.started_at,
            updated_at: state.updated_at.unwrap_or(now),
            terminated: state.terminated,
            terminated_at: state.terminated_at,
            master_state_path: PathBuf::from("<demo-fixture>"),
            master_archive_error: state.master_archive_error,
            master_error: None,
            pre_purge_state: false,
            owner: state.owner,
            daemon: DaemonStatus::unknown(),
            counts,
            sessions,
            merge_queue: state.merge_queue,
            conflict_graph: state.conflict_graph,
            paused_for_user: state.paused_for_user,
            recent_events: VecDeque::with_capacity(0),
            conversations: folded_conversations(state.conversations),
            summary_path: state.summary_path,
        }
    }

    #[must_use]
    pub fn empty_for_session(
        session_id: impl Into<String>,
        master_state_path: PathBuf,
        now: DateTime<Utc>,
    ) -> Self {
        Self::empty_base(session_id, master_state_path, now, None, false)
    }

    pub fn empty_with_error(
        session_id: impl Into<String>,
        master_state_path: PathBuf,
        now: DateTime<Utc>,
        error: impl Into<String>,
        pre_purge_state: bool,
    ) -> Self {
        Self::empty_base(
            session_id,
            master_state_path,
            now,
            Some(error.into()),
            pre_purge_state,
        )
    }

    fn empty_base(
        session_id: impl Into<String>,
        master_state_path: PathBuf,
        now: DateTime<Utc>,
        error: Option<String>,
        pre_purge_state: bool,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            project_root: PathBuf::from("."),
            started_at: None,
            updated_at: now,
            terminated: false,
            terminated_at: None,
            master_state_path,
            master_archive_error: None,
            master_error: error,
            pre_purge_state,
            owner: None,
            daemon: DaemonStatus::unknown(),
            counts: KindCounts::default(),
            sessions: Vec::new(),
            merge_queue: Vec::new(),
            conflict_graph: ConflictGraph::default(),
            paused_for_user: None,
            recent_events: VecDeque::with_capacity(0),
            conversations: Vec::new(),
            summary_path: None,
        }
    }

    #[must_use]
    pub fn structural_eq(&self, other: &Self) -> bool {
        self.session_id == other.session_id
            && self.started_at == other.started_at
            && self.updated_at == other.updated_at
            && self.terminated == other.terminated
            && self.terminated_at == other.terminated_at
            && self.master_state_path == other.master_state_path
            && self.master_archive_error == other.master_archive_error
            && self.master_error == other.master_error
            && self.pre_purge_state == other.pre_purge_state
            && self.owner == other.owner
            && self.daemon == other.daemon
            && self.counts == other.counts
            && self.sessions == other.sessions
            && self.merge_queue == other.merge_queue
            && self.conflict_graph == other.conflict_graph
            && self.paused_for_user == other.paused_for_user
            && self.recent_events == other.recent_events
            && self.conversations == other.conversations
            && self.summary_path == other.summary_path
    }

    #[must_use]
    pub fn staleness(&self, now: DateTime<Utc>) -> Staleness {
        let basis = self.daemon.last_heartbeat_at.unwrap_or(self.updated_at);
        let age = now.signed_duration_since(basis);
        let age = age.to_std().unwrap_or(Duration::ZERO);
        let warn_after = threshold_secs("FLIGHTDECK_DASHBOARD_STALE_WARN_SECS", 30);
        let stale_after = threshold_secs("FLIGHTDECK_DASHBOARD_STALE_DEAD_SECS", 300);
        if age >= stale_after {
            Staleness::StaleAfter(age)
        } else if age >= warn_after {
            Staleness::WarnAfter(age)
        } else {
            Staleness::Fresh
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Staleness {
    Fresh,
    WarnAfter(Duration),
    StaleAfter(Duration),
}

fn threshold_secs(name: &str, default: u64) -> Duration {
    std::env::var(name)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|seconds| *seconds > 0)
        .map(Duration::from_secs)
        .unwrap_or_else(|| Duration::from_secs(default))
}

fn sort_sessions_for_operator(sessions: &mut [TrackedSession], paused_entry_id: Option<&str>) {
    sessions.sort_by(|left, right| {
        let left_paused = paused_entry_id.is_some_and(|entry_id| entry_id == left.id);
        let right_paused = paused_entry_id.is_some_and(|entry_id| entry_id == right.id);
        right_paused
            .cmp(&left_paused)
            .then_with(|| {
                left.state
                    .operator_priority()
                    .cmp(&right.state.operator_priority())
            })
            .then_with(|| left.id.cmp(&right.id))
    });
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct DaemonStatus {
    pub label: String,
    pub healthy: Option<bool>,
    pub pid: Option<u32>,
    pub last_heartbeat_at: Option<DateTime<Utc>>,
}

impl DaemonStatus {
    #[must_use]
    pub fn unknown() -> Self {
        Self {
            label: String::from("daemon: unknown"),
            healthy: None,
            pid: None,
            last_heartbeat_at: None,
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct KindCounts {
    pub total: usize,
    pub adhoc: usize,
    pub issue: usize,
    pub workflow: usize,
    pub by_state: BTreeMap<SessionState, usize>,
}

impl KindCounts {
    #[must_use]
    pub fn from_sessions(sessions: &[TrackedSession]) -> Self {
        let mut counts = Self {
            total: sessions.len(),
            ..Self::default()
        };
        for session in sessions {
            match &session.kind {
                SessionKind::Adhoc => counts.adhoc += 1,
                SessionKind::Issue => counts.issue += 1,
                SessionKind::Workflow => counts.workflow += 1,
                SessionKind::Other(_) => {}
            }
            *counts.by_state.entry(session.state.clone()).or_insert(0) += 1;
        }
        counts
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct TrackedSession {
    pub id: String,
    pub title: String,
    pub kind: SessionKind,
    pub state: SessionState,
    pub substate: Option<String>,
    pub harness: Option<String>,
    pub window: Option<String>,
    pub pane_target: Option<String>,
    pub pane_id: Option<String>,
    pub cwd: Option<PathBuf>,
    pub launch: LaunchInfo,
    pub adapter: AdapterMetadata,
    pub domain: Option<DomainBlock>,
    pub last_response_at: Option<DateTime<Utc>>,
    pub spawned_at: Option<DateTime<Utc>>,
    pub last_polled_at: Option<DateTime<Utc>>,
    pub decisions_log: Vec<DecisionLogEntry>,
    pub stats: PaneStats,
    /// Pull request number for generic ad-hoc/workflow entries. Issue-mode
    /// rows keep the canonical value under `domain.issue.pr_number`; renderers
    /// prefer that and fall back to this field.
    pub pr_number: Option<u32>,
    /// Optional worktree override for generic rows.
    pub worktree: Option<PathBuf>,
    /// Git branch captured at spawn time by `flightdeck-session start`
    /// (vstack#101). Empty / None when the cwd is not a git repo or
    /// HEAD was detached. Informational; staleness is acceptable.
    pub branch: Option<String>,
}

impl TrackedSession {
    #[must_use]
    pub fn from_entry(key: String, entry: TrackedEntry) -> Self {
        let id = if entry.id.trim().is_empty() {
            key
        } else {
            entry.id
        };
        let title = entry.title.unwrap_or_else(|| id.clone());
        Self {
            id,
            title,
            kind: entry.kind,
            state: entry.state.unwrap_or_default(),
            substate: entry.substate,
            harness: entry.harness,
            window: entry.window,
            pane_target: entry.pane_target,
            pane_id: entry.pane_id,
            cwd: entry.cwd,
            launch: entry.launch.unwrap_or_default(),
            adapter: entry.adapter.unwrap_or_default(),
            domain: entry.domain,
            last_response_at: entry.last_response_at,
            spawned_at: entry.spawned_at,
            last_polled_at: entry.last_polled_at,
            decisions_log: entry.decisions_log,
            stats: PaneStats::default(),
            pr_number: entry.pr_number,
            worktree: entry.worktree,
            branch: entry.branch.filter(|value| !value.trim().is_empty()),
        }
    }

    #[must_use]
    pub fn issue(&self) -> Option<&TrackedIssueDomain> {
        self.domain
            .as_ref()
            .and_then(|domain| domain.issue.as_ref())
    }

    #[must_use]
    pub fn pr_number(&self) -> Option<u32> {
        self.issue()
            .and_then(|issue| issue.pr_number)
            .or(self.pr_number)
    }

    #[must_use]
    pub fn worktree(&self) -> Option<&PathBuf> {
        self.issue()
            .and_then(|issue| issue.worktree.as_ref())
            .or(self.worktree.as_ref())
    }

    #[must_use]
    pub fn latest_decision(&self) -> Option<&DecisionLogEntry> {
        self.decisions_log.iter().max_by_key(|entry| entry.ts)
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
pub struct PaneStats {
    pub turns: Option<u32>,
    pub tokens: Option<u64>,
    pub cost_usd: Option<f64>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Event {
    pub ts: DateTime<Utc>,
    pub source: ActivitySource,
    pub importance: EventImportance,
    pub message: String,
}

impl Event {
    #[must_use]
    pub fn new(
        ts: DateTime<Utc>,
        source: ActivitySource,
        importance: EventImportance,
        message: impl Into<String>,
    ) -> Self {
        Self {
            ts,
            source,
            importance,
            message: message.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[serde(rename_all = "kebab-case")]
pub enum ActivitySource {
    Daemon,
    Wake,
    Prompt,
    State,
    Decision,
    Error,
}

impl ActivitySource {
    #[must_use]
    pub const fn as_chip(self) -> &'static str {
        match self {
            Self::Daemon => "DAEMON",
            Self::Wake => "WAKE",
            Self::Prompt => "PROMPT",
            Self::State => "STATE",
            Self::Decision => "DECISION",
            Self::Error => "ERR",
        }
    }
}

#[derive(
    Debug, Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord, Hash,
)]
#[serde(rename_all = "kebab-case")]
pub enum EventImportance {
    #[default]
    Low,
    Medium,
    Important,
}

impl EventImportance {
    #[must_use]
    pub const fn dot(self) -> &'static str {
        match self {
            Self::Low => "·",
            Self::Medium => "•",
            Self::Important => "●",
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ConversationStream {
    pub entry_id: String,
    pub excerpt: String,
    pub ts: Option<DateTime<Utc>>,
    pub role: Option<String>,
    #[serde(default)]
    pub partial: bool,
}

fn folded_conversations(mut conversations: Vec<ConversationStream>) -> Vec<ConversationStream> {
    conversations.sort_by(|left, right| right.ts.cmp(&left.ts));
    let mut seen_streams = std::collections::HashSet::new();
    let mut folded = Vec::with_capacity(conversations.len());
    for conversation in conversations {
        let key = (
            conversation.entry_id.clone(),
            conversation.role.clone().unwrap_or_default(),
        );
        if conversation.partial && !seen_streams.insert(key) {
            continue;
        }
        folded.push(conversation);
    }
    folded
}
