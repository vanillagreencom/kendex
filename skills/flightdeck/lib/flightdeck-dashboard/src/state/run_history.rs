use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use chrono::{DateTime, Utc};
use serde::Deserialize;
use thiserror::Error;

use super::snapshot::DashboardSnapshot;
use super::tracked_entries;

#[derive(Debug, Error)]
pub enum RunHistoryError {
    #[error(
        "flightdeck-state command not found; set FLIGHTDECK_STATE_BIN or FLIGHTDECK_SKILL_DIR"
    )]
    CommandNotFound,
    #[error("failed to run flightdeck-state: {0}")]
    Io(#[from] std::io::Error),
    #[error("flightdeck-state {command} failed with status {status}: {stderr}")]
    CommandFailed {
        command: &'static str,
        status: std::process::ExitStatus,
        stderr: String,
    },
    #[error("failed to parse flightdeck-state JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("failed to load run snapshot: {0}")]
    Snapshot(#[from] tracked_entries::SnapshotError),
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct RunMetadata {
    pub run_id: String,
    pub project_root: PathBuf,
    pub tmux_session: String,
    pub state_path: PathBuf,
    pub activity_path: PathBuf,
    pub summary_path: Option<PathBuf>,
    pub snapshots_path: PathBuf,
    pub started_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub terminated: bool,
    pub terminated_at: Option<DateTime<Utc>>,
    pub imported: bool,
    pub imported_from: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryRun {
    pub metadata: RunMetadata,
    pub snapshots: Vec<String>,
}

impl HistoryRun {
    #[must_use]
    pub fn status_label(&self) -> &'static str {
        if self.metadata.imported {
            "imported"
        } else if self.metadata.terminated {
            "terminated"
        } else {
            "active"
        }
    }

    #[must_use]
    pub fn searchable_text(&self) -> String {
        let mut text = format!(
            "{} {} {} {}",
            self.metadata.run_id,
            self.metadata.tmux_session,
            self.status_label(),
            self.metadata.project_root.display()
        );
        if let Some(path) = &self.metadata.summary_path {
            text.push(' ');
            text.push_str(&path.display().to_string());
        }
        if let Some(path) = &self.metadata.imported_from {
            text.push(' ');
            text.push_str(&path.display().to_string());
        }
        text
    }
}

#[derive(Debug, Clone)]
pub struct LoadedRunSnapshot {
    pub snapshot: DashboardSnapshot,
    pub metadata: RunMetadata,
    pub snapshot_name: Option<String>,
    pub snapshots: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportSummary {
    pub imported: usize,
    pub skipped: usize,
    pub diagnostics: Vec<String>,
    pub runs: Vec<HistoryRun>,
}

#[derive(Debug, Deserialize)]
struct RunListOutput {
    runs: Vec<RunMetadata>,
}

#[derive(Debug, Deserialize)]
struct ActiveRunOutput {
    active: ActivePointer,
}

#[derive(Debug, Deserialize)]
struct ActivePointer {
    run_id: String,
}

#[derive(Debug, Deserialize)]
struct RunShowOutput {
    metadata: RunMetadata,
    state: serde_json::Value,
    snapshot: Option<String>,
    snapshots: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct ImportOutput {
    imported: Vec<RunMetadata>,
    skipped: Vec<RunMetadata>,
    diagnostics: Vec<String>,
}

pub fn list_runs(project_root: &Path) -> Result<Vec<HistoryRun>, RunHistoryError> {
    let output = run_state_command(
        "run list",
        &[
            "run".to_owned(),
            "list".to_owned(),
            "--project-root".to_owned(),
            project_root.display().to_string(),
            "--json".to_owned(),
        ],
    )?;
    let parsed: RunListOutput = serde_json::from_slice(&output)?;
    Ok(parsed
        .runs
        .into_iter()
        .map(|metadata| HistoryRun {
            snapshots: list_snapshot_files(&metadata.snapshots_path),
            metadata,
        })
        .collect())
}

pub fn load_active_run(
    project_root: &Path,
    now: DateTime<Utc>,
) -> Result<Option<LoadedRunSnapshot>, RunHistoryError> {
    let output = run_state_command(
        "run active",
        &[
            "run".to_owned(),
            "active".to_owned(),
            "--project-root".to_owned(),
            project_root.display().to_string(),
        ],
    )?;
    if output_is_json_null(&output) {
        return Ok(None);
    }
    let active: ActiveRunOutput = serde_json::from_slice(&output)?;
    load_run_snapshot(project_root, &active.active.run_id, None, now).map(Some)
}

pub fn load_run_snapshot(
    project_root: &Path,
    run_id: &str,
    snapshot_name: Option<&str>,
    now: DateTime<Utc>,
) -> Result<LoadedRunSnapshot, RunHistoryError> {
    let mut args = vec![
        "run".to_owned(),
        "show".to_owned(),
        run_id.to_owned(),
        "--project-root".to_owned(),
        project_root.display().to_string(),
    ];
    if let Some(snapshot) = snapshot_name {
        args.push("--snapshot".to_owned());
        args.push(snapshot.to_owned());
    }
    let output = run_state_command("run show", &args)?;
    let parsed: RunShowOutput = serde_json::from_slice(&output)?;
    let raw_state = serde_json::to_string(&parsed.state)?;
    let mut warn = stderr_warning;
    let mut snapshot = tracked_entries::snapshot_from_str_with_warn(&raw_state, now, &mut warn)?;
    snapshot.project_root = parsed.metadata.project_root.clone();
    snapshot.master_state_path = selected_state_path(&parsed.metadata, parsed.snapshot.as_deref());
    if snapshot.session_id.is_empty() {
        snapshot
            .session_id
            .clone_from(&parsed.metadata.tmux_session);
    }
    if snapshot.summary_path.is_none() {
        snapshot.summary_path = parsed.metadata.summary_path.clone();
    }
    Ok(LoadedRunSnapshot {
        snapshot,
        metadata: parsed.metadata,
        snapshot_name: parsed.snapshot,
        snapshots: parsed.snapshots,
    })
}

pub fn import_legacy_archives(project_root: &Path) -> Result<ImportSummary, RunHistoryError> {
    let output = run_state_command(
        "run import-legacy",
        &[
            "run".to_owned(),
            "import-legacy".to_owned(),
            "--project-root".to_owned(),
            project_root.display().to_string(),
        ],
    )?;
    let parsed: ImportOutput = serde_json::from_slice(&output)?;
    let runs = list_runs(project_root)?;
    Ok(ImportSummary {
        imported: parsed.imported.len(),
        skipped: parsed.skipped.len(),
        diagnostics: parsed.diagnostics,
        runs,
    })
}

fn selected_state_path(metadata: &RunMetadata, snapshot_name: Option<&str>) -> PathBuf {
    snapshot_name.map_or_else(
        || metadata.state_path.clone(),
        |snapshot| metadata.snapshots_path.join(snapshot),
    )
}

fn list_snapshot_files(path: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(path) else {
        return Vec::new();
    };
    let mut snapshots = entries
        .filter_map(Result::ok)
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| is_snapshot_name(name))
        .collect::<Vec<_>>();
    snapshots.sort_by(|left, right| right.cmp(left));
    snapshots
}

fn is_snapshot_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    bytes.len() == "2026-05-19T120000Z.json".len()
        && bytes.get(4) == Some(&b'-')
        && bytes.get(7) == Some(&b'-')
        && bytes.get(10) == Some(&b'T')
        && bytes.get(17) == Some(&b'Z')
        && name.ends_with(".json")
        && name[..4].chars().all(|ch| ch.is_ascii_digit())
        && name[5..7].chars().all(|ch| ch.is_ascii_digit())
        && name[8..10].chars().all(|ch| ch.is_ascii_digit())
        && name[11..17].chars().all(|ch| ch.is_ascii_digit())
}

fn output_is_json_null(output: &[u8]) -> bool {
    std::str::from_utf8(output)
        .map(|text| text.trim() == "null")
        .unwrap_or(false)
}

fn run_state_command(command: &'static str, args: &[String]) -> Result<Vec<u8>, RunHistoryError> {
    let bin = resolve_flightdeck_state_bin().ok_or(RunHistoryError::CommandNotFound)?;
    let output = Command::new(bin).args(args).output()?;
    if output.status.success() {
        return Ok(output.stdout);
    }
    Err(RunHistoryError::CommandFailed {
        command,
        status: output.status,
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
    })
}

fn resolve_flightdeck_state_bin() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("FLIGHTDECK_STATE_BIN").map(PathBuf::from) {
        if path.is_file() {
            return Some(path);
        }
    }
    if let Some(path) = std::env::var_os("FLIGHTDECK_SKILL_DIR")
        .map(PathBuf::from)
        .map(|skill_dir| skill_dir.join("scripts/flightdeck-state"))
    {
        if path.is_file() {
            return Some(path);
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        let dev_path = cwd.join("../../scripts/flightdeck-state");
        if dev_path.is_file() {
            return Some(dev_path);
        }
        let canonical = cwd.join("skills/flightdeck/scripts/flightdeck-state");
        if canonical.is_file() {
            return Some(canonical);
        }
        let installed = cwd.join(".agents/skills/flightdeck/scripts/flightdeck-state");
        if installed.is_file() {
            return Some(installed);
        }
    }
    which("flightdeck-state")
}

fn which(bin: &str) -> Option<PathBuf> {
    let output = Command::new("bash")
        .args(["-lc", &format!("command -v {}", shell_quote(bin))])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (!path.is_empty()).then(|| PathBuf::from(path))
}

fn shell_quote(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '_' | '-' | ':' | '='))
    {
        return value.to_owned();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn stderr_warning(message: &str) {
    eprintln!("{message}");
}
