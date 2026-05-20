use std::collections::VecDeque;
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use tracing::warn;

use crate::state::archive_order;

use super::{ActivityEvent, ActivitySource};

pub const MAX_EVENTS_IN_MEMORY: usize = 5_000;

const ACTIVITY_PREFIX: &str = "flightdeck-activity-";
const LIVE_SUFFIX: &str = ".jsonl";
const ARCHIVE_SUFFIX: &str = ".jsonl.archive";
const READ_CHUNK_BYTES: usize = 64 * 1024;
const MAX_READ_BYTES_PER_POLL: usize = 2 * 1024 * 1024;
const MAX_PENDING_LINE_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ActivitySourceError {
    #[error("activity file missing {path}", path = path.display())]
    Missing { path: PathBuf },
    #[error("activity metadata failed {path}: {message}", path = path.display())]
    Metadata { path: PathBuf, message: String },
    #[error("activity file is a symlink {path}", path = path.display())]
    Symlink { path: PathBuf },
    #[error("activity path is not a regular file {path}", path = path.display())]
    NotRegularFile { path: PathBuf },
    #[error("activity path {path} escapes expected directory {expected}", path = path.display(), expected = expected.display())]
    OutsideExpectedDirectory { path: PathBuf, expected: PathBuf },
    #[error("activity open failed {path}: {message}", path = path.display())]
    Open { path: PathBuf, message: String },
    #[error("activity seek failed {path}: {message}", path = path.display())]
    Seek { path: PathBuf, message: String },
    #[error("activity read failed {path}: {message}", path = path.display())]
    Read { path: PathBuf, message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    dev: u64,
    ino: u64,
}

impl FileIdentity {
    fn from_metadata(metadata: &Metadata) -> Self {
        Self {
            dev: metadata.dev(),
            ino: metadata.ino(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct JsonlActivitySource {
    state_dir: PathBuf,
    session_name: String,
    explicit_path: Option<PathBuf>,
    expected_dir: Option<PathBuf>,
    active_path: Option<PathBuf>,
    active_file_id: Option<FileIdentity>,
    offset: u64,
    pending: String,
    events: VecDeque<ActivityEvent>,
    malformed_lines: u64,
    malformed_warnings: u64,
    last_error: Option<ActivitySourceError>,
    last_warning: Option<String>,
}

impl JsonlActivitySource {
    #[must_use]
    pub fn new(state_dir: impl Into<PathBuf>, session_name: impl Into<String>) -> Self {
        Self {
            state_dir: state_dir.into(),
            session_name: session_name.into(),
            explicit_path: None,
            expected_dir: None,
            active_path: None,
            active_file_id: None,
            offset: 0,
            pending: String::new(),
            events: VecDeque::with_capacity(MAX_EVENTS_IN_MEMORY.min(1024)),
            malformed_lines: 0,
            malformed_warnings: 0,
            last_error: None,
            last_warning: None,
        }
    }

    #[must_use]
    pub fn from_path(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let expected_dir = path.parent().map(Path::to_path_buf);
        Self::from_path_with_expected_dir(path, expected_dir)
    }

    #[must_use]
    pub fn from_run_path(path: impl Into<PathBuf>, run_dir: impl Into<PathBuf>) -> Self {
        Self::from_path_with_expected_dir(path.into(), Some(run_dir.into()))
    }

    fn from_path_with_expected_dir(path: PathBuf, expected_dir: Option<PathBuf>) -> Self {
        let state_dir = path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        let session_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("activity.jsonl")
            .to_owned();
        Self {
            state_dir,
            session_name,
            explicit_path: Some(path),
            expected_dir,
            active_path: None,
            active_file_id: None,
            offset: 0,
            pending: String::new(),
            events: VecDeque::with_capacity(MAX_EVENTS_IN_MEMORY.min(1024)),
            malformed_lines: 0,
            malformed_warnings: 0,
            last_error: None,
            last_warning: None,
        }
    }

    #[must_use]
    pub fn state_dir(&self) -> &Path {
        self.state_dir.as_path()
    }

    #[must_use]
    pub fn session_name(&self) -> &str {
        self.session_name.as_str()
    }

    #[must_use]
    pub fn active_path(&self) -> Option<&Path> {
        self.active_path.as_deref()
    }

    #[must_use]
    pub const fn offset(&self) -> u64 {
        self.offset
    }

    #[must_use]
    pub const fn malformed_lines(&self) -> u64 {
        self.malformed_lines
    }

    #[must_use]
    pub const fn last_error(&self) -> Option<&ActivitySourceError> {
        self.last_error.as_ref()
    }

    #[must_use]
    pub fn last_warning(&self) -> Option<&str> {
        self.last_warning.as_deref()
    }

    #[must_use]
    pub fn events(&self) -> Vec<ActivityEvent> {
        self.events.iter().cloned().collect()
    }

    #[must_use]
    pub fn live_path(&self) -> PathBuf {
        live_activity_path(&self.state_dir, &self.session_name)
    }

    #[must_use]
    pub fn archive_path_candidates(&self) -> Vec<PathBuf> {
        archive_candidates(&self.state_dir, &self.session_name)
    }

    fn poll_inner(&mut self) -> Vec<ActivityEvent> {
        self.last_error = None;
        let path = match self.resolve_path() {
            Ok(Some(path)) => path,
            Ok(None) => {
                self.reset_active(None, None);
                return Vec::new();
            }
            Err(error) => {
                warn!(%error, "activity source path resolution failed");
                self.last_error = Some(error);
                return self.events();
            }
        };
        let metadata = match self.validate_path(&path) {
            Ok(metadata) => metadata,
            Err(error) => {
                warn!(%error, "activity source metadata failed");
                self.last_error = Some(error);
                return self.events();
            }
        };
        let file_id = FileIdentity::from_metadata(&metadata);
        if self.active_path.as_deref() != Some(path.as_path())
            || self.active_file_id != Some(file_id)
            || metadata.len() < self.offset
        {
            self.reset_active(Some(path.clone()), Some(file_id));
        }
        if let Err(error) = self.read_new_records(&path) {
            warn!(%error, "activity source read failed");
            self.last_error = Some(error);
        }
        self.events()
    }

    fn reset_active(&mut self, path: Option<PathBuf>, file_id: Option<FileIdentity>) {
        self.active_path = path;
        self.active_file_id = file_id;
        self.offset = 0;
        self.pending.clear();
        self.events.clear();
    }

    fn resolve_path(&self) -> Result<Option<PathBuf>, ActivitySourceError> {
        if let Some(path) = &self.explicit_path {
            return Ok(Some(path.clone()));
        }
        let live = self.live_path();
        if fs::symlink_metadata(&live).is_ok() {
            return Ok(Some(live));
        }
        Ok(self.archive_path_candidates().into_iter().next())
    }

    fn validate_path(&self, path: &Path) -> Result<Metadata, ActivitySourceError> {
        let metadata = fs::symlink_metadata(path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                ActivitySourceError::Missing {
                    path: path.to_path_buf(),
                }
            } else {
                ActivitySourceError::Metadata {
                    path: path.to_path_buf(),
                    message: error.to_string(),
                }
            }
        })?;
        let file_type = metadata.file_type();
        if file_type.is_symlink() {
            return Err(ActivitySourceError::Symlink {
                path: path.to_path_buf(),
            });
        }
        if !file_type.is_file() {
            return Err(ActivitySourceError::NotRegularFile {
                path: path.to_path_buf(),
            });
        }
        if let Some(expected_dir) = &self.expected_dir {
            ensure_path_inside_expected_dir(path, expected_dir)?;
        }
        Ok(metadata)
    }

    fn read_new_records(&mut self, path: &Path) -> Result<(), ActivitySourceError> {
        let mut file = open_activity_file(path)?;
        file.seek(SeekFrom::Start(self.offset))
            .map_err(|error| ActivitySourceError::Seek {
                path: path.to_path_buf(),
                message: error.to_string(),
            })?;
        let mut total_read = 0usize;
        let mut buffer = [0_u8; READ_CHUNK_BYTES];
        while total_read < MAX_READ_BYTES_PER_POLL {
            let cap = READ_CHUNK_BYTES.min(MAX_READ_BYTES_PER_POLL - total_read);
            let read =
                file.read(&mut buffer[..cap])
                    .map_err(|error| ActivitySourceError::Read {
                        path: path.to_path_buf(),
                        message: error.to_string(),
                    })?;
            if read == 0 {
                break;
            }
            total_read = total_read.saturating_add(read);
            self.offset = self.offset.saturating_add(read as u64);
            self.consume_bytes(&buffer[..read]);
        }
        if total_read > 0 {
            self.parse_complete_pending_json();
        }
        Ok(())
    }

    fn consume_bytes(&mut self, bytes: &[u8]) {
        let chunk = String::from_utf8_lossy(bytes);
        for segment in chunk.split_inclusive('\n') {
            let complete = segment.ends_with('\n');
            let text = segment.strip_suffix('\n').unwrap_or(segment);
            if !self.append_pending(text) {
                continue;
            }
            if complete {
                let line = std::mem::take(&mut self.pending);
                self.parse_line(&line);
            }
        }
    }

    fn append_pending(&mut self, text: &str) -> bool {
        if self.pending.len().saturating_add(text.len()) > MAX_PENDING_LINE_BYTES {
            self.malformed_lines = self.malformed_lines.saturating_add(1);
            self.pending.clear();
            self.last_warning = Some(format!(
                "activity record exceeded {MAX_PENDING_LINE_BYTES} bytes; dropped oversized record"
            ));
            if self.should_warn_malformed() {
                warn!(
                    limit = MAX_PENDING_LINE_BYTES,
                    "activity JSONL record oversized; dropping"
                );
            }
            return false;
        }
        self.pending.push_str(text);
        true
    }

    fn parse_complete_pending_json(&mut self) {
        let pending = self.pending.trim();
        if pending.is_empty() {
            self.pending.clear();
            return;
        }
        if pending.starts_with('{') && pending.ends_with('}') {
            let line = std::mem::take(&mut self.pending);
            self.parse_line(&line);
        }
    }

    fn parse_line(&mut self, line: &str) {
        let line = line.trim();
        if line.is_empty() {
            return;
        }
        match serde_json::from_str::<ActivityEvent>(line) {
            Ok(event) => self.push_event(event),
            Err(error) => {
                self.malformed_lines = self.malformed_lines.saturating_add(1);
                self.last_warning = Some(format!(
                    "{} malformed activity line(s); latest: {error}",
                    self.malformed_lines
                ));
                if self.should_warn_malformed() {
                    warn!(line = self.malformed_lines, %error, "activity JSONL line malformed; skipping");
                }
            }
        }
    }

    fn should_warn_malformed(&mut self) -> bool {
        self.malformed_warnings = self.malformed_warnings.saturating_add(1);
        self.malformed_warnings <= 3 || self.malformed_warnings % 100 == 0
    }

    fn push_event(&mut self, event: ActivityEvent) {
        if self.events.len() >= MAX_EVENTS_IN_MEMORY {
            self.events.pop_front();
        }
        self.events.push_back(event);
    }
}

impl ActivitySource for JsonlActivitySource {
    fn poll(&mut self) -> Vec<ActivityEvent> {
        self.poll_inner()
    }

    fn last_id(&self) -> Option<String> {
        self.events.back().map(|event| event.id.clone())
    }
}

#[must_use]
pub fn live_activity_path(state_dir: &Path, session_name: &str) -> PathBuf {
    state_dir.join(format!("{ACTIVITY_PREFIX}{session_name}{LIVE_SUFFIX}"))
}

#[must_use]
pub fn archive_candidates(state_dir: &Path, session_name: &str) -> Vec<PathBuf> {
    let prefix = format!("{ACTIVITY_PREFIX}{session_name}-");
    let Ok(entries) = fs::read_dir(state_dir) else {
        return Vec::new();
    };
    let mut candidates = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(&prefix) && name.ends_with(ARCHIVE_SUFFIX))
        })
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| archive_order::cmp_archive_paths_desc(left, right));
    candidates
}

fn open_activity_file(path: &Path) -> Result<File, ActivitySourceError> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| ActivitySourceError::Open {
            path: path.to_path_buf(),
            message: error.to_string(),
        })
}

fn ensure_path_inside_expected_dir(
    path: &Path,
    expected_dir: &Path,
) -> Result<(), ActivitySourceError> {
    let expected = expected_dir
        .canonicalize()
        .map_err(|error| ActivitySourceError::Metadata {
            path: expected_dir.to_path_buf(),
            message: error.to_string(),
        })?;
    let parent = path
        .parent()
        .ok_or_else(|| ActivitySourceError::OutsideExpectedDirectory {
            path: path.to_path_buf(),
            expected: expected_dir.to_path_buf(),
        })?
        .canonicalize()
        .map_err(|error| ActivitySourceError::Metadata {
            path: path.to_path_buf(),
            message: error.to_string(),
        })?;
    if !parent.starts_with(&expected) {
        return Err(ActivitySourceError::OutsideExpectedDirectory {
            path: path.to_path_buf(),
            expected,
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use serde_json::json;

    use super::*;

    #[test]
    fn poll_reads_at_most_max_bytes_per_poll() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = live_activity_path(dir.path(), "S");
        let body = "x".repeat(700);
        let mut contents = String::new();
        let mut total_records = 0usize;
        while contents.len() <= MAX_READ_BYTES_PER_POLL + 64 * 1024 {
            contents.push_str(&event_line(total_records, Some(&body)));
            total_records += 1;
        }
        fs::write(&path, contents).expect("activity fixture");
        let total_bytes = fs::metadata(&path).expect("metadata").len();

        let mut source = JsonlActivitySource::new(dir.path(), "S");
        let first = source.poll();

        assert_eq!(source.offset(), MAX_READ_BYTES_PER_POLL as u64);
        assert!(!first.is_empty());
        assert!(first.len() < total_records);

        let second = source.poll();

        assert_eq!(source.offset(), total_bytes);
        assert_eq!(second.len(), total_records);
        assert!(second.len() > first.len());
    }

    #[test]
    fn event_retention_is_bounded_and_evicts_oldest() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = live_activity_path(dir.path(), "S");
        let total_records = MAX_EVENTS_IN_MEMORY + 25;
        let contents = (0..total_records)
            .map(|index| event_line(index, None))
            .collect::<String>();
        fs::write(path, contents).expect("activity fixture");

        let mut source = JsonlActivitySource::new(dir.path(), "S");
        let events = source.poll();

        let expected_last = format!("evt-{}", total_records - 1);
        assert_eq!(events.len(), MAX_EVENTS_IN_MEMORY);
        assert_eq!(
            events.first().map(|event| event.id.as_str()),
            Some("evt-25")
        );
        assert_eq!(
            events.last().map(|event| event.id.as_str()),
            Some(expected_last.as_str())
        );
    }

    fn event_line(index: usize, body: Option<&str>) -> String {
        let mut value = json!({
            "schema_version": 1,
            "id": format!("evt-{index}"),
            "ts": "2026-05-19T12:00:00Z",
            "session_id": "S",
            "source": "flightdeck",
            "type": "session.started",
            "severity": "info",
            "importance": "normal",
            "summary": format!("event {index}"),
        });
        if let Some(body) = body {
            value["body"] = json!(body);
        }
        format!("{value}\n")
    }
}
