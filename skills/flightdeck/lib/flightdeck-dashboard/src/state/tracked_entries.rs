use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use chrono::{DateTime, Utc};
use serde_json::{Map, Value};
use thiserror::Error;

use super::archive_order;
use super::normalizers::{self, WarnCallback};
use super::schema::{MasterState, TrackedEntry};
use super::snapshot::DashboardSnapshot;

pub const ENTRY_ID_PATTERN: &str = "^[A-Za-z0-9._-]+$";
pub const PRE_PURGE_STATE_MESSAGE: &str = "state file uses pre-purge `.issues` schema with no `.entries`; archive it manually and rerun `flightdeck session start`";
pub const PRE_PURGE_BANNER: &str =
    "Pre-purge state file detected (.issues without .entries). Re-init the session.";

pub type StateError = SnapshotError;

#[derive(Debug, Error)]
pub enum SnapshotError {
    #[error("state file missing {path}", path = path.display())]
    StateFileMissing { path: PathBuf },
    #[error("failed to read state file {path}: {source}")]
    ReadFile {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to parse master state JSON: {0}")]
    Parse(#[from] serde_json::Error),
    #[error("master state JSON is not an object")]
    RootNotObject,
    #[error("{PRE_PURGE_STATE_MESSAGE}")]
    PrePurgeState,
    #[error("failed to normalize .entries[{key:?}]: {source}")]
    InvalidEntry {
        key: String,
        #[source]
        source: serde_json::Error,
    },
    #[error("failed to normalize master state: {0}")]
    InvalidState(serde_json::Error),
    #[error(transparent)]
    Archive(#[from] ArchiveError),
    #[error("failed to resolve state path: {0}")]
    Resolve(String),
}

#[derive(Debug, Error)]
pub enum ArchiveError {
    #[error("no terminated archives found for session {session:?} in {state_dir}", state_dir = state_dir.display())]
    NoArchives { session: String, state_dir: PathBuf },
    #[error("no readable terminated archive: {candidate_count} candidates failed (latest {latest_path}: {latest_error})", latest_path = latest_path.display())]
    AllCandidatesMalformed {
        candidate_count: usize,
        latest_path: PathBuf,
        latest_error: String,
        failures: Vec<ArchiveFailure>,
    },
    #[error("archive directory unreadable {path}: {source}", path = path.display())]
    DirectoryRead {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchiveFailure {
    pub path: PathBuf,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionResolution {
    pub project_root: PathBuf,
    pub state_dir: PathBuf,
    pub session: String,
    pub state_path: PathBuf,
}

pub fn parse_master_state(raw: &str) -> Result<MasterState, SnapshotError> {
    let mut warn = stderr_warning;
    parse_master_state_with_warn(raw, &mut warn)
}

pub fn parse_master_state_with_warn(
    raw: &str,
    warn: &mut WarnCallback<'_>,
) -> Result<MasterState, SnapshotError> {
    let value: Value = serde_json::from_str(raw)?;
    parse_master_state_value(value, warn)
}

pub fn snapshot_from_str(
    raw: &str,
    now: DateTime<Utc>,
) -> Result<DashboardSnapshot, SnapshotError> {
    parse_master_state(raw).map(|state| DashboardSnapshot::from_master_state(state, now))
}

pub fn snapshot_from_str_with_warn(
    raw: &str,
    now: DateTime<Utc>,
    warn: &mut WarnCallback<'_>,
) -> Result<DashboardSnapshot, SnapshotError> {
    parse_master_state_with_warn(raw, warn)
        .map(|state| DashboardSnapshot::from_master_state(state, now))
}

pub fn snapshot_from_file(
    path: &Path,
    now: DateTime<Utc>,
) -> Result<DashboardSnapshot, SnapshotError> {
    let mut warn = stderr_warning;
    snapshot_from_file_with_warn(path, now, &mut warn)
}

pub fn snapshot_from_file_with_warn(
    path: &Path,
    now: DateTime<Utc>,
    warn: &mut WarnCallback<'_>,
) -> Result<DashboardSnapshot, SnapshotError> {
    let source = fs::read_to_string(path).map_err(|source| {
        if source.kind() == std::io::ErrorKind::NotFound {
            SnapshotError::StateFileMissing {
                path: path.to_path_buf(),
            }
        } else {
            SnapshotError::ReadFile {
                path: path.to_path_buf(),
                source,
            }
        }
    })?;
    let mut snapshot = snapshot_from_str_with_warn(&source, now, warn)?;
    snapshot.master_state_path = path.to_path_buf();
    Ok(snapshot)
}

#[must_use]
pub fn snapshot_for_error_path(
    path: &Path,
    now: DateTime<Utc>,
    error: String,
    pre_purge_state: bool,
) -> DashboardSnapshot {
    snapshot_for_error(
        session_id_from_state_path(path),
        path.to_path_buf(),
        now,
        error,
        pre_purge_state,
    )
}

#[must_use]
pub fn snapshot_for_error(
    session_id: impl Into<String>,
    path: PathBuf,
    now: DateTime<Utc>,
    error: String,
    pre_purge_state: bool,
) -> DashboardSnapshot {
    DashboardSnapshot::empty_with_error(session_id, path, now, error, pre_purge_state)
}

#[must_use]
pub fn session_id_from_state_path(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.strip_prefix("flightdeck-state-"))
        .and_then(|name| name.strip_suffix(".json"))
        .filter(|value| !value.is_empty())
        .unwrap_or("state-file")
        .to_owned()
}

pub fn read_tracked_entries(
    state: Option<&Value>,
    warn: &mut WarnCallback<'_>,
) -> Result<Vec<TrackedEntry>, SnapshotError> {
    let entries = normalized_entry_values(state.and_then(|value| value.get("entries")), warn);
    entries
        .into_iter()
        .map(|(key, value)| {
            serde_json::from_value(value)
                .map_err(|source| SnapshotError::InvalidEntry { key, source })
        })
        .collect()
}

pub fn read_session_snapshot(
    resolution: &SessionResolution,
    now: DateTime<Utc>,
) -> Result<DashboardSnapshot, SnapshotError> {
    let mut warn = stderr_warning;
    read_session_snapshot_with_warn(resolution, now, &mut warn)
}

pub fn read_session_snapshot_with_warn(
    resolution: &SessionResolution,
    now: DateTime<Utc>,
    warn: &mut WarnCallback<'_>,
) -> Result<DashboardSnapshot, SnapshotError> {
    match fs::read_to_string(&resolution.state_path) {
        Ok(source) => {
            let mut snapshot = snapshot_from_str_with_warn(&source, now, warn)?;
            snapshot.master_state_path = resolution.state_path.clone();
            snapshot.project_root = resolution.project_root.clone();
            if snapshot.session_id.is_empty() {
                snapshot.session_id.clone_from(&resolution.session);
            }
            Ok(snapshot)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Err(SnapshotError::StateFileMissing {
                path: resolution.state_path.clone(),
            })
        }
        Err(source) => Err(SnapshotError::ReadFile {
            path: resolution.state_path.clone(),
            source,
        }),
    }
}

pub fn read_archive_fallback(
    state_dir: &Path,
    session: &str,
    project_root: &Path,
    now: DateTime<Utc>,
) -> Result<DashboardSnapshot, ArchiveError> {
    let mut warn = stderr_warning;
    read_archive_fallback_with_warn(state_dir, session, project_root, now, &mut warn)
}

pub fn read_archive_fallback_with_warn(
    state_dir: &Path,
    session: &str,
    project_root: &Path,
    now: DateTime<Utc>,
    warn: &mut WarnCallback<'_>,
) -> Result<DashboardSnapshot, ArchiveError> {
    let archives = list_terminated_archives(state_dir, session)?;
    if archives.is_empty() {
        return Err(ArchiveError::NoArchives {
            session: session.to_owned(),
            state_dir: state_dir.to_path_buf(),
        });
    }

    let mut failures = Vec::new();
    for archive in archives {
        let source = match fs::read_to_string(&archive) {
            Ok(source) => source,
            Err(error) => {
                failures.push(ArchiveFailure {
                    path: archive,
                    reason: format!("read failed: {error}"),
                });
                continue;
            }
        };
        if source.trim().is_empty() {
            normalizers::warn(
                warn,
                format!("Warning: blank archive {}; skipping.", archive.display()),
            );
            failures.push(ArchiveFailure {
                path: archive,
                reason: "blank archive".to_owned(),
            });
            continue;
        }
        let state = match parse_master_state_with_warn(&source, warn) {
            Ok(state) => state,
            Err(error) => {
                failures.push(ArchiveFailure {
                    path: archive,
                    reason: error.to_string(),
                });
                continue;
            }
        };
        if !state.terminated {
            failures.push(ArchiveFailure {
                path: archive,
                reason: "archive missing terminated:true".to_owned(),
            });
            continue;
        }
        let mut snapshot = DashboardSnapshot::from_master_state(state, now);
        snapshot.project_root = project_root.to_path_buf();
        snapshot.master_state_path = archive;
        if snapshot.session_id.is_empty() {
            snapshot.session_id = session.to_owned();
        }
        return Ok(snapshot);
    }

    if let Some(latest) = failures.first() {
        return Err(ArchiveError::AllCandidatesMalformed {
            candidate_count: failures.len(),
            latest_path: latest.path.clone(),
            latest_error: latest.reason.clone(),
            failures,
        });
    }

    Err(ArchiveError::NoArchives {
        session: session.to_owned(),
        state_dir: state_dir.to_path_buf(),
    })
}

pub fn resolve_session(explicit: Option<&str>) -> Result<String, SnapshotError> {
    if let Some(session) = explicit.map(str::trim).filter(|value| !value.is_empty()) {
        return Ok(session.to_owned());
    }
    if std::env::var_os("TMUX").is_none() {
        return Err(SnapshotError::Resolve(
            "no $TMUX session and no --session given".to_owned(),
        ));
    }
    let output = Command::new("tmux")
        .args(["display-message", "-p", "#S"])
        .output()
        .map_err(|error| SnapshotError::Resolve(format!("failed to run tmux: {error}")))?;
    if !output.status.success() {
        return Err(SnapshotError::Resolve(format!(
            "tmux display-message failed with status {}",
            output.status
        )));
    }
    let session = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if session.is_empty() {
        return Err(SnapshotError::Resolve(
            "tmux display-message returned empty session name".to_owned(),
        ));
    }
    Ok(session)
}

pub fn resolve_session_state(explicit: Option<&str>) -> Result<SessionResolution, SnapshotError> {
    let session = resolve_session(explicit)?;
    let cwd = std::env::current_dir()
        .map_err(|error| SnapshotError::Resolve(format!("failed to read current dir: {error}")))?;
    resolve_session_state_from(cwd, &session)
}

pub fn resolve_session_state_from(
    cwd: impl AsRef<Path>,
    session: &str,
) -> Result<SessionResolution, SnapshotError> {
    let project_root = resolve_project_root(cwd.as_ref())?;
    let state_dir = resolve_state_dir(&project_root);
    let state_path = state_dir.join(format!("flightdeck-state-{session}.json"));
    Ok(SessionResolution {
        project_root,
        state_dir,
        session: session.to_owned(),
        state_path,
    })
}

pub fn resolve_project_root(cwd: &Path) -> Result<PathBuf, SnapshotError> {
    let mut current = cwd
        .canonicalize()
        .map_err(|error| SnapshotError::Resolve(format!("failed to canonicalize cwd: {error}")))?;
    loop {
        if current.join(".git").exists()
            || current.join(".vstack-lock.json").exists()
            || current.join("vstack.toml").exists()
        {
            return Ok(current);
        }
        if !current.pop() {
            return Err(SnapshotError::Resolve(
                "not inside a Flightdeck project".to_owned(),
            ));
        }
    }
}

#[must_use]
pub fn resolve_state_dir(project_root: &Path) -> PathBuf {
    let configured = std::env::var("FLIGHTDECK_STATE_DIR")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "tmp".to_owned());
    let path = PathBuf::from(configured);
    if path.is_absolute() {
        path
    } else {
        project_root.join(path)
    }
}

fn parse_master_state_value(
    value: Value,
    warn: &mut WarnCallback<'_>,
) -> Result<MasterState, SnapshotError> {
    let Value::Object(mut object) = value else {
        return Err(SnapshotError::RootNotObject);
    };

    let entries = normalized_entry_values(object.get("entries"), warn);
    if entries.is_empty() && has_non_empty_issues(&object) {
        return Err(SnapshotError::PrePurgeState);
    }

    object.insert("entries".to_owned(), Value::Object(entries));
    object.insert(
        "merge_queue".to_owned(),
        normalizers::normalize_merge_queue(object.get("merge_queue"), warn),
    );
    object.insert(
        "conflict_graph".to_owned(),
        normalizers::normalize_conflict_graph(object.get("conflict_graph"), warn),
    );
    serde_json::from_value(Value::Object(object)).map_err(SnapshotError::InvalidState)
}

fn normalized_entry_values(
    raw_entries: Option<&Value>,
    warn: &mut WarnCallback<'_>,
) -> Map<String, Value> {
    let Some(Value::Object(entries)) = raw_entries else {
        return Map::new();
    };

    let invalid = entries
        .iter()
        .filter_map(|(key, value)| (!value.is_object()).then_some(key.as_str()))
        .collect::<Vec<_>>();
    if !invalid.is_empty() {
        normalizers::warn(warn, invalid_entries_warning(&invalid));
    }

    entries
        .iter()
        .filter_map(|(key, value)| {
            let Value::Object(raw_entry) = value else {
                return None;
            };
            Some((key.clone(), normalize_entry_value(key, raw_entry, warn)))
        })
        .collect()
}

fn normalize_entry_value(
    key: &str,
    raw_entry: &Map<String, Value>,
    warn: &mut WarnCallback<'_>,
) -> Value {
    let mut entry = raw_entry.clone();
    let key_id = validate_entry_id(key).unwrap_or_else(|| key.to_owned());
    let raw_id = entry.get("id");
    let normalized_id = raw_id.and_then(Value::as_str).and_then(validate_entry_id);
    if let Some(raw_id) = raw_id.filter(|_| normalized_id.is_none()) {
        normalizers::warn(warn, invalid_entry_id_warning(key, raw_id));
    }
    entry.insert(
        "id".to_owned(),
        Value::String(normalized_id.unwrap_or(key_id)),
    );

    let kind = entry
        .get("kind")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("adhoc")
        .to_owned();
    entry.insert("kind".to_owned(), Value::String(kind));
    entry.insert(
        "decisions_log".to_owned(),
        normalizers::normalize_decisions_log(entry.get("decisions_log"), key, warn),
    );
    Value::Object(entry)
}

fn validate_entry_id(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() || !trimmed.chars().all(is_entry_id_char) {
        return None;
    }
    Some(trimmed.to_owned())
}

const fn is_entry_id_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-')
}

fn invalid_entries_warning(ids: &[&str]) -> String {
    let quoted = ids
        .iter()
        .map(|id| serde_json::to_string(id).unwrap_or_else(|_| format!("\"{id}\"")))
        .collect::<Vec<_>>()
        .join(", ");
    format!("Warning: invalid .entries value(s) for {quoted}; skipping.")
}

fn invalid_entry_id_warning(entry_key: &str, raw_id: &Value) -> String {
    let raw = serde_json::to_string(raw_id).unwrap_or_else(|_| raw_id.to_string());
    let key = serde_json::to_string(entry_key).unwrap_or_else(|_| format!("\"{entry_key}\""));
    format!("Warning: invalid .entries[{key}].id {raw}; using entry key.")
}

fn has_non_empty_issues(object: &Map<String, Value>) -> bool {
    matches!(object.get("issues"), Some(Value::Object(issues)) if !issues.is_empty())
}

fn list_terminated_archives(state_dir: &Path, session: &str) -> Result<Vec<PathBuf>, ArchiveError> {
    let entries = match fs::read_dir(state_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(source) => {
            return Err(ArchiveError::DirectoryRead {
                path: state_dir.to_path_buf(),
                source,
            })
        }
    };

    let path_results = entries.map(|entry| entry.map(|entry| entry.path()));
    collect_matching_archives(path_results, state_dir, session)
}

fn collect_matching_archives<I>(
    entries: I,
    state_dir: &Path,
    session: &str,
) -> Result<Vec<PathBuf>, ArchiveError>
where
    I: IntoIterator<Item = Result<PathBuf, std::io::Error>>,
{
    let prefix = format!("flightdeck-state-{session}-");
    let suffix = ".json.archive";
    let mut archives = Vec::new();
    for entry in entries {
        let path = entry.map_err(|source| ArchiveError::DirectoryRead {
            path: state_dir.to_path_buf(),
            source,
        })?;
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if name.starts_with(&prefix) && name.ends_with(suffix) {
            archives.push(path);
        }
    }
    archives.sort_by(|left, right| archive_order::cmp_archive_paths_desc(left, right));
    Ok(archives)
}

fn stderr_warning(message: &str) {
    eprintln!("{message}");
}

#[cfg(test)]
#[path = "tracked_entries_tests.rs"]
mod tests;
