use std::io;
use std::path::{Path, PathBuf};

use chrono::{TimeZone, Utc};
use serde_json::Value;

use super::*;
use crate::state::snapshot::SessionKind;

fn fixture_path(relative: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/state")
        .join(relative)
}

fn fixture_source(relative: &str) -> String {
    std::fs::read_to_string(fixture_path(relative)).expect("fixture reads")
}

fn fixed_now() -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 5, 15, 10, 30, 0)
        .single()
        .expect("fixed timestamp is valid")
}

fn write_archive(dir: &Path, name: &str, source: &str) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, source).expect("archive writes");
    path
}

fn valid_terminated_archive(entry_id: &str) -> String {
    format!(
        r#"{{
  "session_id": "HT",
  "updated_at": "2026-05-15T10:15:00Z",
  "terminated": true,
  "terminated_at": "2026-05-15T10:15:00Z",
  "entries": {{
    "{entry_id}": {{
      "id": "{entry_id}",
      "title": "Valid archive",
      "kind": "adhoc",
      "state": "complete",
      "decisions_log": []
    }}
  }},
  "merge_queue": [],
  "conflict_graph": {{ "edges": [], "computed_at": null }},
  "paused_for_user": null
}}"#
    )
}

#[test]
fn happy_path_reads_three_entries_and_defaults_kind() {
    let source = fixture_source("entries-happy.json");
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let snapshot =
        snapshot_from_str_with_warn(&source, fixed_now(), &mut warn).expect("snapshot reads");

    assert!(
        warnings.is_empty(),
        "happy fixture should not warn: {warnings:?}"
    );
    assert_eq!(snapshot.sessions.len(), 3);
    let adhoc = snapshot
        .sessions
        .iter()
        .find(|entry| entry.id == "adhoc-default")
        .expect("adhoc entry exists");
    assert_eq!(adhoc.kind, SessionKind::Adhoc);
    assert_eq!(snapshot.conflict_graph.edges.len(), 2);
    assert_eq!(
        snapshot.conflict_graph.edges[0],
        ("ISS-7".to_owned(), "workflow.plan".to_owned())
    );
    assert_eq!(snapshot.merge_queue, ["ISS-7", "workflow.plan"]);
}

#[test]
fn current_tmux_window_name_overrides_spawn_title_for_display() {
    let source = r#"{
      "session_id": "HT",
      "entries": {
        "pane-a": {
          "id": "pane-a",
          "title": "Spawn title",
          "window_name_current": "Pi renamed title",
          "kind": "adhoc",
          "state": "ready",
          "decisions_log": []
        }
      },
      "merge_queue": [],
      "conflict_graph": { "edges": [], "computed_at": null },
      "paused_for_user": null
    }"#;
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let snapshot =
        snapshot_from_str_with_warn(source, fixed_now(), &mut warn).expect("snapshot reads");

    assert!(warnings.is_empty());
    let session = snapshot.sessions.first().expect("session exists");
    assert_eq!(session.title, "Pi renamed title");
    assert_eq!(
        session.window_name_current.as_deref(),
        Some("Pi renamed title")
    );
}

#[test]
fn read_tracked_entries_returns_vec() {
    let value: Value =
        serde_json::from_str(&fixture_source("entries-happy.json")).expect("json parses");
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let entries = read_tracked_entries(Some(&value), &mut warn).expect("entries read");

    assert!(warnings.is_empty());
    assert_eq!(entries.len(), 3);
    assert!(entries.iter().any(|entry| entry.id == "workflow.plan"));
}

#[test]
fn pre_purge_issues_only_is_typed_error() {
    let source = fixture_source("pre-purge-issues-only.json");
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let error = parse_master_state_with_warn(&source, &mut warn).expect_err("pre-purge errors");

    assert!(matches!(error, SnapshotError::PrePurgeState));
    assert_eq!(error.to_string(), PRE_PURGE_STATE_MESSAGE);
    assert!(warnings.is_empty());
}

#[test]
fn malformed_entry_warns_skips_and_falls_back_to_key() {
    let source = fixture_source("malformed-entry.json");
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let snapshot =
        snapshot_from_str_with_warn(&source, fixed_now(), &mut warn).expect("snapshot reads");

    assert_eq!(snapshot.sessions.len(), 2);
    assert!(warnings.iter().any(
        |message| message == "Warning: invalid .entries value(s) for \"bad-value\"; skipping."
    ));
    assert!(warnings.iter().any(|message| {
        message == "Warning: invalid .entries[\"fallback-id\"].id 42; using entry key."
    }));
    assert!(warnings.iter().any(|message| {
        message == "Warning: invalid .entries[\"fallback-id\"].decisions_log[1]; skipping."
    }));
    let fallback = snapshot
        .sessions
        .iter()
        .find(|entry| entry.id == "fallback-id")
        .expect("fallback entry exists");
    assert_eq!(fallback.kind, SessionKind::Adhoc);
    assert_eq!(fallback.decisions_log.len(), 1);
}

#[test]
fn issue_domain_comes_from_domain_issue_not_top_level_fields() {
    let source = fixture_source("entries-happy.json");
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let snapshot =
        snapshot_from_str_with_warn(&source, fixed_now(), &mut warn).expect("snapshot reads");
    let issue = snapshot
        .sessions
        .iter()
        .find(|entry| entry.id == "ISS-7")
        .and_then(|entry| entry.issue())
        .expect("issue domain exists");

    assert_eq!(issue.pr_number, Some(7));
    assert_eq!(
        issue.worktree.as_deref(),
        Some(Path::new("/repo/worktrees/iss-7"))
    );
    assert_eq!(issue.merge_commit.as_deref(), Some("abc123"));
}

#[test]
fn archive_newest_first_returns_terminated_archive() {
    let dir = fixture_path("archive-newest-first");
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let snapshot = read_archive_fallback_with_warn(
        &dir,
        "HT",
        Path::new("/repo/project"),
        fixed_now(),
        &mut warn,
    )
    .expect("archive reads");

    assert!(warnings.is_empty());
    assert!(snapshot.terminated);
    assert_eq!(snapshot.session_id, "HT");
    assert_eq!(
        snapshot.terminated_at,
        Some(
            Utc.with_ymd_and_hms(2026, 5, 15, 10, 15, 0)
                .single()
                .expect("timestamp valid")
        )
    );
    assert!(snapshot
        .master_state_path
        .ends_with("flightdeck-state-HT-20260515T101500Z.json.archive"));
    assert!(snapshot
        .sessions
        .iter()
        .any(|entry| entry.id == "newest-done"));
}

#[test]
fn archive_all_malformed_returns_typed_error() {
    let dir = fixture_path("archive-all-malformed");
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let error = read_archive_fallback_with_warn(
        &dir,
        "HT",
        Path::new("/repo/project"),
        fixed_now(),
        &mut warn,
    )
    .expect_err("all candidates fail");

    match error {
        ArchiveError::AllCandidatesMalformed {
            candidate_count,
            latest_path,
            failures,
            ..
        } => {
            assert_eq!(candidate_count, 3);
            assert_eq!(failures.len(), 3);
            assert!(latest_path.ends_with("flightdeck-state-HT-20260515T101500Z.json.archive"));
        }
        other => panic!("unexpected archive error: {other:?}"),
    }
}

#[test]
fn archive_blank_then_valid_returns_valid_archive() {
    let dir = tempfile::tempdir().expect("tempdir creates");
    write_archive(
        dir.path(),
        "flightdeck-state-HT-20260515T101600Z.json.archive",
        "\n\t\n",
    );
    write_archive(
        dir.path(),
        "flightdeck-state-HT-20260515T101500Z.json.archive",
        &valid_terminated_archive("valid-after-blank"),
    );
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let snapshot = read_archive_fallback_with_warn(
        dir.path(),
        "HT",
        Path::new("/repo/project"),
        fixed_now(),
        &mut warn,
    )
    .expect("valid archive after blank should load");

    assert!(snapshot
        .sessions
        .iter()
        .any(|entry| entry.id == "valid-after-blank"));
    assert!(warnings
        .iter()
        .any(|message| message.contains("Warning: blank archive")));
}

#[test]
fn archive_blank_and_malformed_returns_all_candidates_malformed() {
    let dir = tempfile::tempdir().expect("tempdir creates");
    let blank = write_archive(
        dir.path(),
        "flightdeck-state-HT-20260515T101600Z.json.archive",
        "   \n",
    );
    write_archive(
        dir.path(),
        "flightdeck-state-HT-20260515T101500Z.json.archive",
        "{not json",
    );
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let error = read_archive_fallback_with_warn(
        dir.path(),
        "HT",
        Path::new("/repo/project"),
        fixed_now(),
        &mut warn,
    )
    .expect_err("blank plus malformed should be malformed candidates");

    match error {
        ArchiveError::AllCandidatesMalformed {
            candidate_count,
            latest_path,
            latest_error,
            failures,
        } => {
            assert_eq!(candidate_count, 2);
            assert_eq!(latest_path, blank);
            assert_eq!(latest_error, "blank archive");
            assert_eq!(failures[0].reason, "blank archive");
            assert!(!failures[1].reason.is_empty());
            assert_ne!(failures[1].reason, "blank archive");
        }
        other => panic!("unexpected archive error: {other:?}"),
    }
    assert!(warnings
        .iter()
        .any(|message| message.contains("Warning: blank archive")));
}

#[test]
fn archive_per_entry_read_dir_error_surfaces() {
    let dir = Path::new("/synthetic/archive-dir");
    let error = collect_matching_archives(
        [Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "synthetic entry failure",
        ))],
        dir,
        "HT",
    )
    .expect_err("per-entry read_dir error should surface");

    match error {
        ArchiveError::DirectoryRead { path, source } => {
            assert_eq!(path, dir);
            assert_eq!(source.kind(), io::ErrorKind::PermissionDenied);
        }
        other => panic!("unexpected archive error: {other:?}"),
    }
}

#[test]
fn archive_empty_dir_returns_no_archives() {
    let dir = fixture_path("archive-enoent");
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let error = read_archive_fallback_with_warn(
        &dir,
        "HT",
        Path::new("/repo/project"),
        fixed_now(),
        &mut warn,
    )
    .expect_err("no archives");

    assert!(matches!(error, ArchiveError::NoArchives { .. }));
    assert!(warnings.is_empty());
}

#[test]
fn archive_blank_warns_and_returns_all_candidates_malformed() {
    let dir = fixture_path("archive-blank");
    let mut warnings = Vec::new();
    let mut warn = |message: &str| warnings.push(message.to_owned());

    let error = read_archive_fallback_with_warn(
        &dir,
        "HT",
        Path::new("/repo/project"),
        fixed_now(),
        &mut warn,
    )
    .expect_err("blank archive is malformed");

    match error {
        ArchiveError::AllCandidatesMalformed {
            candidate_count,
            latest_error,
            failures,
            ..
        } => {
            assert_eq!(candidate_count, 1);
            assert_eq!(latest_error, "blank archive");
            assert_eq!(failures.len(), 1);
            assert_eq!(failures[0].reason, "blank archive");
        }
        other => panic!("unexpected archive error: {other:?}"),
    }
    assert!(warnings
        .iter()
        .any(|message| message.contains("Warning: blank archive")));
}
