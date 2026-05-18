use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

use crate::util::paths::fd_wake_events_log;

use super::busy::{self, BusyPaths};

pub const PI_BG_TASK_EXIT_TAG: &str = "pi-bg-task-exit";
pub const PI_EMPTY_AFTER_COMPACT_TAG: &str = "pi-empty-after-compact";
pub const PI_QUESTION_TAG: &str = "pi-question";
pub const PI_SUBAGENT_COMPLETION_TAG: &str = "pi-subagent-completion";
pub const DOMAIN_MISMATCH_TAG: &str = "domain-mismatch";

#[derive(Debug, Error)]
pub enum WakeError {
    #[error("wake io error at {path}: {source}", path = path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("wake JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Busy(#[from] busy::BusyError),
    #[error("wake dedupe state poisoned")]
    DedupePoisoned,
}

#[derive(Debug, Clone)]
pub struct WakeAppender {
    paths: WakePaths,
    dedupe: Arc<Mutex<HashSet<String>>>,
    sequence: Arc<AtomicU64>,
}

impl WakeAppender {
    #[must_use]
    pub fn new(state_dir: &Path, session_key: &str) -> Self {
        Self {
            paths: WakePaths::new(state_dir, session_key),
            dedupe: Arc::new(Mutex::new(HashSet::new())),
            sequence: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn append_event(&self, mut event: WakeEvent) -> Result<bool, WakeError> {
        if event.ts.is_empty() {
            event.ts = Utc::now().to_rfc3339();
        }
        let dedupe_key = event.dedupe_key();
        {
            let mut dedupe = self.dedupe.lock().map_err(|_| WakeError::DedupePoisoned)?;
            if !dedupe.insert(dedupe_key.clone()) {
                return Ok(false);
            }
        }

        let appended = busy::with_session_lock(&self.paths.busy, || {
            append_jsonl(&self.paths.wake_events_log, &event).map_err(|source| {
                busy::BusyError::Io {
                    path: self.paths.wake_events_log.clone(),
                    source,
                }
            })?;
            Ok(())
        });
        match appended {
            Ok(()) => {
                self.sequence.fetch_add(1, Ordering::Relaxed);
                Ok(true)
            }
            Err(error) => {
                if let Ok(mut dedupe) = self.dedupe.lock() {
                    dedupe.remove(&dedupe_key);
                }
                Err(error.into())
            }
        }
    }

    #[must_use]
    pub fn sequence(&self) -> u64 {
        self.sequence.load(Ordering::Relaxed)
    }

    #[must_use]
    pub fn paths(&self) -> &WakePaths {
        &self.paths
    }
}

#[derive(Debug, Clone)]
pub struct WakePaths {
    pub wake_events_log: PathBuf,
    pub busy: BusyPaths,
}

impl WakePaths {
    #[must_use]
    pub fn new(state_dir: &Path, session_key: &str) -> Self {
        Self {
            wake_events_log: fd_wake_events_log(state_dir, session_key),
            busy: BusyPaths::new(state_dir, session_key),
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct WakeEvent {
    #[serde(default)]
    pub ts: String,
    pub pane_id: String,
    pub harness: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_type: Option<String>,
    pub classifier_tag: String,
    pub hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub question: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completion: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_assistant_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

impl WakeEvent {
    #[must_use]
    pub fn bg_task_exit(pane_id: String, task: Value, hash: String) -> Self {
        Self {
            ts: String::new(),
            pane_id,
            harness: "pi".to_owned(),
            event_type: Some("bg-task-exit".to_owned()),
            classifier_tag: PI_BG_TASK_EXIT_TAG.to_owned(),
            hash,
            request_id: None,
            question: None,
            completion: None,
            task: Some(task),
            last_assistant_text: None,
            details: None,
        }
    }

    #[must_use]
    pub fn pi_question(pane_id: String, request_id: String, question: Value, hash: String) -> Self {
        Self {
            ts: String::new(),
            pane_id,
            harness: "pi".to_owned(),
            event_type: Some("question".to_owned()),
            classifier_tag: PI_QUESTION_TAG.to_owned(),
            hash,
            request_id: Some(request_id),
            question: Some(question),
            completion: None,
            task: None,
            last_assistant_text: None,
            details: None,
        }
    }

    #[must_use]
    pub fn assistant_text(
        pane_id: String,
        text: String,
        classifier_tag: String,
        hash: String,
    ) -> Self {
        Self {
            ts: String::new(),
            pane_id,
            harness: "pi".to_owned(),
            event_type: None,
            classifier_tag,
            hash,
            request_id: None,
            question: None,
            completion: None,
            task: None,
            last_assistant_text: Some(text),
            details: None,
        }
    }

    #[must_use]
    pub fn terminal_state(pane_id: String, hash: String) -> Self {
        Self::assistant_text(
            pane_id,
            String::new(),
            "terminal-state-reached".to_owned(),
            hash,
        )
    }

    #[must_use]
    pub fn subagent_completion(pane_id: String, completion: Value, hash: String) -> Self {
        Self {
            ts: String::new(),
            pane_id,
            harness: "pi".to_owned(),
            event_type: Some("subagent-completion".to_owned()),
            classifier_tag: PI_SUBAGENT_COMPLETION_TAG.to_owned(),
            hash,
            request_id: None,
            question: None,
            completion: Some(completion),
            task: None,
            last_assistant_text: None,
            details: None,
        }
    }

    #[must_use]
    pub fn empty_after_compact(pane_id: String, hash: String, details: Value) -> Self {
        Self {
            ts: String::new(),
            pane_id,
            harness: "pi".to_owned(),
            event_type: Some("empty-after-compact".to_owned()),
            classifier_tag: PI_EMPTY_AFTER_COMPACT_TAG.to_owned(),
            hash,
            request_id: None,
            question: None,
            completion: None,
            task: None,
            last_assistant_text: None,
            details: Some(details),
        }
    }

    #[must_use]
    pub fn dedupe_key(&self) -> String {
        format!("{}|{}|{}", self.pane_id, self.hash, self.classifier_tag)
    }
}

pub fn is_canonical_tag(tag: &str) -> bool {
    matches!(
        tag,
        "terminal-state-reached"
            | "force-push-prompt"
            | "merge-now"
            | "cleanup-prompt"
            | "stale-no-pr-branch"
            | "stale-orphan-worktree"
            | "rebase-multi-choice"
            | "generic-multi-choice"
            | "multi-select-tabbed"
            | "awaiting-direction"
            | "bash-permission-prompt"
            | "modal-prompt"
            | "bot-review-wait-stuck"
            | "audit-relation-prompt"
            | "merge-ready-but-unknown"
            | "force-merge-confirm"
            | "external-fix-suggestions"
            | "cycle-fix-suggestions"
            | "descope-related"
            | "oc-question"
            | PI_QUESTION_TAG
            | PI_SUBAGENT_COMPLETION_TAG
            | PI_BG_TASK_EXIT_TAG
            | "daemon-exited"
            | DOMAIN_MISMATCH_TAG
    )
}

pub fn apply_domain_guard(tag: &str, entry_kind: &str) -> String {
    if !is_issue_only_tag(tag) || entry_kind == "issue" {
        return tag.to_owned();
    }
    DOMAIN_MISMATCH_TAG.to_owned()
}

#[must_use]
pub fn is_issue_only_tag(tag: &str) -> bool {
    matches!(
        tag,
        "force-merge-confirm"
            | "merge-ready-but-unknown"
            | "merge-now"
            | "bot-review-wait-stuck"
            | "rebase-multi-choice"
            | "force-push-prompt"
            | "stale-no-pr-branch"
            | "stale-orphan-worktree"
            | "cleanup-prompt"
            | "audit-relation-prompt"
            | "descope-related"
            | "external-fix-suggestions"
            | "cycle-fix-suggestions"
            | "scope-creep-detected"
            | "multi-select-tabbed"
    )
}

fn append_jsonl(path: &Path, event: &WakeEvent) -> Result<(), io::Error> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    let mut line = serde_json::to_vec(event).map_err(io::Error::other)?;
    line.push(b'\n');
    file.write_all(&line)
}
