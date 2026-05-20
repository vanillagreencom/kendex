use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use chrono::{DateTime, Utc};
use serde::Deserialize;
use thiserror::Error;

use super::snapshot::DashboardSnapshot;
use super::tracked_entries;

const MAX_SNAPSHOTS_PER_RUN: usize = 50;

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
    #[error("active run {run_id} has no metadata")]
    ActiveRunMissingMetadata { run_id: String },
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

impl RunMetadata {
    #[must_use]
    pub fn run_dir(&self) -> PathBuf {
        self.state_path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| self.project_root.clone())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryRun {
    pub metadata: RunMetadata,
    pub snapshots: Vec<String>,
    pub snapshots_truncated: bool,
    pub snapshot_warning: Option<String>,
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActiveRunLookup {
    None,
    Matched(RunMetadata),
    Mismatched {
        run_id: String,
        expected_session: String,
        actual_session: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
struct RunListOutput {
    runs: Vec<RunMetadata>,
}

#[derive(Debug, Deserialize)]
struct ActiveRunOutput {
    active: ActivePointer,
    metadata: Option<RunMetadata>,
}

#[derive(Debug, Deserialize)]
struct ActivePointer {
    run_id: String,
    tmux_session: String,
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
        .map(|metadata| {
            let snapshot_list = list_snapshot_files(&metadata.snapshots_path);
            HistoryRun {
                metadata,
                snapshots: snapshot_list.snapshots,
                snapshots_truncated: snapshot_list.truncated,
                snapshot_warning: snapshot_list.warning,
            }
        })
        .collect())
}

pub fn load_active_run_metadata(
    project_root: &Path,
    expected_session: &str,
) -> Result<ActiveRunLookup, RunHistoryError> {
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
        return Ok(ActiveRunLookup::None);
    }
    let active: ActiveRunOutput = serde_json::from_slice(&output)?;
    let Some(metadata) = active.metadata else {
        return Err(RunHistoryError::ActiveRunMissingMetadata {
            run_id: active.active.run_id,
        });
    };
    if active.active.tmux_session != expected_session {
        return Ok(ActiveRunLookup::Mismatched {
            run_id: active.active.run_id,
            expected_session: expected_session.to_owned(),
            actual_session: Some(active.active.tmux_session),
        });
    }
    if metadata.tmux_session != expected_session {
        return Ok(ActiveRunLookup::Mismatched {
            run_id: metadata.run_id,
            expected_session: expected_session.to_owned(),
            actual_session: Some(metadata.tmux_session),
        });
    }
    Ok(ActiveRunLookup::Matched(metadata))
}

pub fn load_active_run(
    project_root: &Path,
    expected_session: &str,
    now: DateTime<Utc>,
) -> Result<Option<LoadedRunSnapshot>, RunHistoryError> {
    match load_active_run_metadata(project_root, expected_session)? {
        ActiveRunLookup::None | ActiveRunLookup::Mismatched { .. } => Ok(None),
        ActiveRunLookup::Matched(metadata) if metadata.terminated => Ok(None),
        ActiveRunLookup::Matched(metadata) => {
            load_run_snapshot(project_root, &metadata.run_id, None, now).map(Some)
        }
    }
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

#[derive(Debug, Clone, PartialEq, Eq)]
struct SnapshotList {
    snapshots: Vec<String>,
    truncated: bool,
    warning: Option<String>,
}

fn list_snapshot_files(path: &Path) -> SnapshotList {
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(error) => {
            return SnapshotList {
                snapshots: Vec::new(),
                truncated: false,
                warning: Some(format!(
                    "snapshot directory unavailable {}: {error}",
                    path.display()
                )),
            };
        }
    };
    let mut snapshots = entries
        .filter_map(Result::ok)
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| is_snapshot_name(name))
        .collect::<Vec<_>>();
    snapshots.sort_by(|left, right| right.cmp(left));
    let truncated = snapshots.len() > MAX_SNAPSHOTS_PER_RUN;
    snapshots.truncate(MAX_SNAPSHOTS_PER_RUN);
    SnapshotList {
        snapshots,
        truncated,
        warning: truncated.then(|| {
            format!(
                "showing newest {MAX_SNAPSHOTS_PER_RUN} snapshots for {}",
                path.display()
            )
        }),
    }
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

#[cfg(test)]
mod tests {
    use std::env;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::sync::Mutex;

    use chrono::TimeZone;
    use serde_json::json;

    use super::*;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn active_metadata_matches_and_mismatches_expected_session() {
        with_fake_state_bin(|ctx| {
            write_json(
                &ctx.responses.join("active.json"),
                active_output("run-1", "S"),
            );

            let matched = load_active_run_metadata(&ctx.project, "S").expect("active metadata");
            assert!(
                matches!(matched, ActiveRunLookup::Matched(metadata) if metadata.run_id == "run-1")
            );

            let mismatched =
                load_active_run_metadata(&ctx.project, "OTHER").expect("active mismatch");
            assert!(matches!(
                mismatched,
                ActiveRunLookup::Mismatched { run_id, actual_session: Some(session), .. }
                    if run_id == "run-1" && session == "S"
            ));
            assert_log_contains(&ctx.log, "run\nactive\n--project-root");
        });
    }

    #[test]
    fn active_pointer_tmux_session_mismatch_blocks_match() {
        with_fake_state_bin(|ctx| {
            let mut active = active_output("run-1", "S");
            active["active"]["tmux_session"] = json!("OTHER");
            write_json(&ctx.responses.join("active.json"), active);

            let lookup = load_active_run_metadata(&ctx.project, "S").expect("active mismatch");

            assert!(matches!(
                lookup,
                ActiveRunLookup::Mismatched { run_id, actual_session: Some(session), .. }
                    if run_id == "run-1" && session == "OTHER"
            ));
        });
    }

    #[test]
    fn active_null_returns_none_and_failed_command_errors() {
        with_fake_state_bin(|ctx| {
            fs::write(ctx.responses.join("active.json"), "null\n").expect("active null");
            let lookup = load_active_run_metadata(&ctx.project, "S").expect("active null parsed");
            assert_eq!(lookup, ActiveRunLookup::None);

            fs::write(ctx.responses.join("fail-active"), "1").expect("fail marker");
            let error = load_active_run_metadata(&ctx.project, "S").expect_err("active fails");
            assert!(error
                .to_string()
                .contains("flightdeck-state run active failed"));
        });
    }

    #[test]
    fn list_runs_caps_snapshots_and_reports_snapshot_directory_warning() {
        with_fake_state_bin(|ctx| {
            let snapshots = ctx.project.join("runs/run-1/snapshots");
            fs::create_dir_all(&snapshots).expect("snapshots dir");
            for idx in 0..55 {
                fs::write(
                    snapshots.join(format!("2026-05-19T1200{idx:02}Z.json")),
                    "{}",
                )
                .expect("snapshot");
            }
            let missing = ctx.project.join("runs/run-2/missing-snapshots");
            write_json(
                &ctx.responses.join("list.json"),
                json!({
                    "runs": [
                        metadata("run-1", "S", &ctx.project, &snapshots),
                        metadata("run-2", "S", &ctx.project, &missing)
                    ]
                }),
            );

            let runs = list_runs(&ctx.project).expect("list runs");
            assert_eq!(runs.len(), 2);
            assert_eq!(runs[0].snapshots.len(), MAX_SNAPSHOTS_PER_RUN);
            assert!(runs[0].snapshots_truncated);
            assert!(runs[0]
                .snapshot_warning
                .as_deref()
                .is_some_and(|warning| warning.contains("showing newest")));
            assert!(runs[1].snapshots.is_empty());
            assert!(runs[1]
                .snapshot_warning
                .as_deref()
                .is_some_and(|warning| warning.contains("snapshot directory unavailable")));
        });
    }

    #[test]
    fn load_run_snapshot_passes_snapshot_arg_and_parses_state() {
        with_fake_state_bin(|ctx| {
            let snapshots = ctx.project.join("runs/run-1/snapshots");
            fs::create_dir_all(&snapshots).expect("snapshots dir");
            write_json(
                &ctx.responses.join("show.json"),
                json!({
                    "metadata": metadata("run-1", "S", &ctx.project, &snapshots),
                    "state": state_json("S", false),
                    "snapshot": "2026-05-19T120000Z.json",
                    "snapshots": ["2026-05-19T120000Z.json"]
                }),
            );

            let loaded = load_run_snapshot(
                &ctx.project,
                "run-1",
                Some("2026-05-19T120000Z.json"),
                Utc.with_ymd_and_hms(2026, 5, 19, 12, 0, 0).unwrap(),
            )
            .expect("load snapshot");
            assert_eq!(loaded.metadata.run_id, "run-1");
            assert_eq!(loaded.snapshot.session_id, "S");
            assert_eq!(
                loaded.snapshot_name.as_deref(),
                Some("2026-05-19T120000Z.json")
            );
            assert_log_contains(&ctx.log, "--snapshot\n2026-05-19T120000Z.json");
        });
    }

    #[test]
    fn import_legacy_returns_summary_and_refreshes_runs() {
        with_fake_state_bin(|ctx| {
            let snapshots = ctx.project.join("runs/imported/snapshots");
            fs::create_dir_all(&snapshots).expect("snapshots dir");
            write_json(
                &ctx.responses.join("import.json"),
                json!({
                    "imported": [metadata("imported", "S", &ctx.project, &snapshots)],
                    "skipped": [],
                    "diagnostics": ["copied legacy archive"]
                }),
            );
            write_json(
                &ctx.responses.join("list.json"),
                json!({ "runs": [metadata("imported", "S", &ctx.project, &snapshots)] }),
            );

            let summary = import_legacy_archives(&ctx.project).expect("import legacy");
            assert_eq!(summary.imported, 1);
            assert_eq!(summary.skipped, 0);
            assert_eq!(summary.diagnostics, vec!["copied legacy archive"]);
            assert_eq!(summary.runs.len(), 1);
            assert_log_contains(&ctx.log, "run\nimport-legacy\n--project-root");
        });
    }

    #[test]
    fn malformed_json_surfaces_parse_error() {
        with_fake_state_bin(|ctx| {
            fs::write(ctx.responses.join("list.json"), "not-json").expect("bad json");
            let error = list_runs(&ctx.project).expect_err("malformed list fails");
            assert!(error.to_string().contains("failed to parse"));
        });
    }

    struct FakeCtx {
        project: PathBuf,
        responses: PathBuf,
        log: PathBuf,
    }

    fn with_fake_state_bin(test: impl FnOnce(&FakeCtx)) {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let temp = tempfile::tempdir().expect("tempdir");
        let project = temp.path().join("project");
        let responses = temp.path().join("responses");
        let log = temp.path().join("args.log");
        fs::create_dir_all(&project).expect("project dir");
        fs::create_dir_all(&responses).expect("response dir");
        fs::write(project.join("vstack.toml"), "").expect("project marker");
        write_fake_bin(&temp.path().join("flightdeck-state"), &responses, &log);
        let old = env::var_os("FLIGHTDECK_STATE_BIN");
        env::set_var("FLIGHTDECK_STATE_BIN", temp.path().join("flightdeck-state"));
        test(&FakeCtx {
            project,
            responses,
            log,
        });
        if let Some(old) = old {
            env::set_var("FLIGHTDECK_STATE_BIN", old);
        } else {
            env::remove_var("FLIGHTDECK_STATE_BIN");
        }
    }

    fn write_fake_bin(path: &Path, responses: &Path, log: &Path) {
        let script = format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
{{ printf '%s\n' "$@"; printf -- '--END--\n'; }} >> {log}
case "$1 $2" in
  "run active")
    if [[ -f {responses}/fail-active ]]; then echo forced failure >&2; exit 7; fi
    cat {responses}/active.json
    ;;
  "run list") cat {responses}/list.json ;;
  "run show") cat {responses}/show.json ;;
  "run import-legacy") cat {responses}/import.json ;;
  *) echo unexpected "$@" >&2; exit 64 ;;
esac
"#,
            log = shell_path(log),
            responses = shell_path(responses),
        );
        fs::write(path, script).expect("write fake bin");
        let mut perms = fs::metadata(path).expect("fake bin metadata").permissions();
        perms.set_mode(0o755);
        fs::set_permissions(path, perms).expect("chmod fake bin");
    }

    fn active_output(run_id: &str, session: &str) -> serde_json::Value {
        let project = PathBuf::from("/project");
        let snapshots = project.join("runs").join(run_id).join("snapshots");
        json!({
            "project": { "project_id": "project-123" },
            "active": { "run_id": run_id, "tmux_session": session },
            "metadata": metadata(run_id, session, &project, &snapshots)
        })
    }

    fn metadata(
        run_id: &str,
        session: &str,
        project: &Path,
        snapshots: &Path,
    ) -> serde_json::Value {
        let run_dir = snapshots.parent().unwrap_or(project);
        json!({
            "run_id": run_id,
            "project_root": project,
            "tmux_session": session,
            "state_path": run_dir.join("state.json"),
            "activity_path": run_dir.join("activity.jsonl"),
            "summary_path": run_dir.join("summary.md"),
            "snapshots_path": snapshots,
            "started_at": "2026-05-19T12:00:00Z",
            "last_seen_at": "2026-05-19T12:01:00Z",
            "terminated": false,
            "terminated_at": null,
            "imported": false,
            "imported_from": null
        })
    }

    fn state_json(session: &str, terminated: bool) -> serde_json::Value {
        json!({
            "session_id": session,
            "started_at": "2026-05-19T12:00:00Z",
            "updated_at": "2026-05-19T12:01:00Z",
            "terminated": terminated,
            "terminated_at": null,
            "owner": null,
            "entries": {},
            "merge_queue": [],
            "conflict_graph": { "edges": [], "computed_at": "2026-05-19T12:01:00Z" },
            "paused_for_user": null
        })
    }

    fn write_json(path: &Path, value: serde_json::Value) {
        fs::write(path, serde_json::to_vec(&value).expect("serialize json")).expect("write json");
    }

    fn shell_path(path: &Path) -> String {
        format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
    }

    fn assert_log_contains(path: &Path, needle: &str) {
        let log = fs::read_to_string(path).expect("read arg log");
        assert!(log.contains(needle), "arg log missing {needle:?}: {log}");
    }
}
