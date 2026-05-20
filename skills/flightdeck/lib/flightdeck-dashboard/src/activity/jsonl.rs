use std::collections::VecDeque;
use std::fs::{self, File, Metadata};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use tracing::warn;

use crate::state::archive_order;

use super::{ActivityEvent, ActivitySource};

pub const MAX_EVENTS_IN_MEMORY: usize = 5_000;

const ACTIVITY_PREFIX: &str = "flightdeck-activity-";
const LIVE_SUFFIX: &str = ".jsonl";
const ARCHIVE_SUFFIX: &str = ".jsonl.archive";

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
    active_path: Option<PathBuf>,
    active_file_id: Option<FileIdentity>,
    offset: u64,
    pending: String,
    events: VecDeque<ActivityEvent>,
    malformed_lines: u64,
    malformed_warnings: u64,
}

impl JsonlActivitySource {
    #[must_use]
    pub fn new(state_dir: impl Into<PathBuf>, session_name: impl Into<String>) -> Self {
        Self {
            state_dir: state_dir.into(),
            session_name: session_name.into(),
            explicit_path: None,
            active_path: None,
            active_file_id: None,
            offset: 0,
            pending: String::new(),
            events: VecDeque::with_capacity(MAX_EVENTS_IN_MEMORY.min(1024)),
            malformed_lines: 0,
            malformed_warnings: 0,
        }
    }

    #[must_use]
    pub fn from_path(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
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
            active_path: None,
            active_file_id: None,
            offset: 0,
            pending: String::new(),
            events: VecDeque::with_capacity(MAX_EVENTS_IN_MEMORY.min(1024)),
            malformed_lines: 0,
            malformed_warnings: 0,
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
        let Some(path) = self.resolve_path() else {
            self.reset_active(None, None);
            return Vec::new();
        };
        let metadata = match fs::metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) => {
                warn!(path = %path.display(), %error, "activity source metadata failed");
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
            warn!(path = %path.display(), %error, "activity source read failed");
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

    fn resolve_path(&self) -> Option<PathBuf> {
        if let Some(path) = &self.explicit_path {
            return path.exists().then(|| path.clone());
        }
        let live = self.live_path();
        if live.exists() {
            return Some(live);
        }
        self.archive_path_candidates().into_iter().next()
    }

    fn read_new_records(&mut self, path: &Path) -> Result<(), std::io::Error> {
        let mut file = File::open(path)?;
        file.seek(SeekFrom::Start(self.offset))?;
        let mut bytes = Vec::new();
        let read = file.read_to_end(&mut bytes)?;
        if read == 0 {
            return Ok(());
        }
        self.offset = self.offset.saturating_add(read as u64);
        let chunk = String::from_utf8_lossy(&bytes);
        self.pending.push_str(&chunk);
        let mut start = 0;
        let pending = std::mem::take(&mut self.pending);
        for (idx, ch) in pending.char_indices() {
            if ch == '\n' {
                self.parse_line(&pending[start..idx]);
                start = idx + 1;
            }
        }
        let tail = &pending[start..];
        if tail.trim().is_empty() {
            self.pending.clear();
        } else if tail.trim_start().starts_with('{') && tail.trim_end().ends_with('}') {
            self.parse_line(tail);
            self.pending.clear();
        } else {
            self.pending = tail.to_owned();
        }
        Ok(())
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
