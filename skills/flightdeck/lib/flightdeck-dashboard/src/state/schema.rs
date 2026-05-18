use std::collections::HashMap;
use std::path::PathBuf;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::snapshot::{ConflictGraph, ConversationStream, PauseInfo, SessionKind, SessionState};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct MasterState {
    #[serde(default)]
    pub session_id: String,
    pub started_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub terminated: bool,
    pub terminated_at: Option<DateTime<Utc>>,
    pub owner: Option<OwnerBlock>,
    #[serde(default)]
    pub entries: HashMap<String, TrackedEntry>,
    #[serde(default)]
    pub merge_queue: Vec<String>,
    #[serde(default)]
    pub conflict_graph: ConflictGraph,
    #[serde(default)]
    pub paused_for_user: Option<PauseInfo>,
    #[serde(default)]
    pub conversations: Vec<ConversationStream>,
    #[serde(default)]
    pub master_archive_error: Option<String>,
    #[serde(default)]
    pub summary_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct OwnerBlock {
    pub harness: Option<String>,
    pub pane_id: Option<String>,
    pub pane_target: Option<String>,
    pub cwd: Option<PathBuf>,
    pub pid: Option<u32>,
    pub pi_session_id: Option<String>,
    pub pi_bridge_socket: Option<String>,
    pub discovery_error: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct TrackedEntry {
    pub id: String,
    pub title: Option<String>,
    #[serde(default)]
    pub kind: SessionKind,
    pub state: Option<SessionState>,
    pub substate: Option<String>,
    pub harness: Option<String>,
    pub cwd: Option<PathBuf>,
    pub window: Option<String>,
    pub pane_target: Option<String>,
    pub pane_id: Option<String>,
    pub launch: Option<LaunchInfo>,
    pub adapter: Option<AdapterMetadata>,
    pub domain: Option<DomainBlock>,
    pub last_capture_hash: Option<String>,
    pub last_response_at: Option<DateTime<Utc>>,
    pub spawned_at: Option<DateTime<Utc>>,
    pub last_polled_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub decisions_log: Vec<DecisionLogEntry>,
    pub unknown_since: Option<DateTime<Utc>>,
    pub merge_commit: Option<String>,
    pub pr_number: Option<u32>,
    pub worktree: Option<PathBuf>,
    pub branch: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct LaunchInfo {
    pub model: Option<String>,
    pub effort: Option<String>,
    pub cmd: Option<String>,
    pub requested_model: Option<String>,
    pub requested_effort: Option<String>,
    pub resolved_model: Option<String>,
    pub resolved_effort: Option<String>,
    pub model_source: Option<String>,
    pub effort_source: Option<String>,
    pub reasoning_status: Option<String>,
    pub unsupported_reason: Option<String>,
    pub argv: Option<Vec<String>>,
}

#[cfg(test)]
mod tests {
    use super::LaunchInfo;

    #[test]
    fn launch_info_accepts_resolved_metadata_fields() {
        let launch = serde_json::from_str::<LaunchInfo>(
            r#"{
                "model": "openai-codex/gpt-5.5",
                "effort": "xhigh",
                "requested_model": "gpt-5.5",
                "requested_effort": "max",
                "resolved_model": "openai-codex/gpt-5.5",
                "resolved_effort": "xhigh",
                "model_source": "explicit",
                "effort_source": "explicit",
                "reasoning_status": "configured",
                "unsupported_reason": null,
                "argv": ["pi", "--model", "openai-codex/gpt-5.5"]
            }"#,
        )
        .expect("launch metadata deserializes");
        assert_eq!(launch.requested_model.as_deref(), Some("gpt-5.5"));
        assert_eq!(launch.resolved_effort.as_deref(), Some("xhigh"));
        assert_eq!(
            launch.argv.as_deref(),
            Some(
                &[
                    "pi".to_owned(),
                    "--model".to_owned(),
                    "openai-codex/gpt-5.5".to_owned(),
                ][..]
            )
        );
    }
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct AdapterMetadata {
    pub pi_bridge_pid: Option<u32>,
    pub pi_bridge_socket: Option<String>,
    pub pi_session_id: Option<String>,
    pub oc_url: Option<String>,
    pub oc_session_id: Option<String>,
    pub oc_port: Option<u16>,
    pub cc_url: Option<String>,
    pub cc_session_uuid: Option<String>,
    pub cc_transcript: Option<String>,
    pub cc_port: Option<u16>,
    pub cx_ws: Option<String>,
    pub cx_thread_id: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct DomainBlock {
    pub issue: Option<TrackedIssueDomain>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct TrackedIssueDomain {
    pub id: String,
    pub worktree: Option<PathBuf>,
    pub pr_number: Option<u32>,
    pub scope_files_declared: Option<u32>,
    pub scope_files_actual: Option<u32>,
    pub orchestration_started: Option<bool>,
    pub merge_commit: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct DecisionLogEntry {
    pub ts: DateTime<Utc>,
    pub prompt_tag: String,
    pub answer: String,
}
