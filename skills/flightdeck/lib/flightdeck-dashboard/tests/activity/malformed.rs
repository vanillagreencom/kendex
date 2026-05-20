use std::fs;
use std::os::unix::fs::symlink;

use flightdeck_dashboard::activity::{ActivitySource, JsonlActivitySource};

#[test]
fn malformed_jsonl_lines_are_skipped_and_counted() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("flightdeck-activity-S.jsonl");
    fs::write(
        &path,
        concat!(
            "not json\n",
            "{\"schema_version\":1,\"id\":\"ok-1\",\"ts\":\"2026-05-15T10:00:00Z\",\"session_id\":\"S\",\"source\":\"flightdeck\",\"type\":\"session.started\",\"severity\":\"info\",\"importance\":\"normal\",\"summary\":\"started\"}\n",
            "{\"schema_version\":1,\"id\":\"bad-severity\",\"ts\":\"2026-05-15T10:00:01Z\",\"source\":\"flightdeck\",\"type\":\"session.started\",\"severity\":\"bad\",\"importance\":\"normal\",\"summary\":\"bad\"}\n",
            "{\"schema_version\":1,\"id\":\"ok-2\",\"ts\":\"2026-05-15T10:00:02Z\",\"session_id\":\"S\",\"source\":\"flightdeck\",\"type\":\"daemon.started\",\"severity\":\"success\",\"importance\":\"important\",\"summary\":\"daemon\"}\n",
        ),
    )
    .expect("write fixture");

    let mut source = JsonlActivitySource::new(dir.path(), "S");
    let events = source.poll();

    assert_eq!(events.len(), 2);
    assert_eq!(source.malformed_lines(), 2);
    assert_eq!(events[0].id, "ok-1");
    assert_eq!(events[1].id, "ok-2");
}

#[test]
fn non_v1_schema_version_is_skipped_and_counted() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("flightdeck-activity-S.jsonl");
    fs::write(
        &path,
        concat!(
            "{\"schema_version\":2,\"id\":\"bad-version\",\"ts\":\"2026-05-15T10:00:00Z\",\"session_id\":\"S\",\"source\":\"flightdeck\",\"type\":\"session.started\",\"severity\":\"info\",\"importance\":\"normal\",\"summary\":\"bad version\"}\n",
            "{\"schema_version\":1,\"id\":\"ok-version\",\"ts\":\"2026-05-15T10:00:01Z\",\"session_id\":\"S\",\"source\":\"flightdeck\",\"type\":\"session.started\",\"severity\":\"info\",\"importance\":\"normal\",\"summary\":\"ok\"}\n",
        ),
    )
    .expect("write fixture");

    let mut source = JsonlActivitySource::new(dir.path(), "S");
    let events = source.poll();

    assert_eq!(events.len(), 1);
    assert_eq!(source.malformed_lines(), 1);
    assert_eq!(events[0].id, "ok-version");
}

#[test]
fn explicit_activity_missing_reports_error_not_empty_success() {
    let dir = tempfile::tempdir().expect("tempdir");
    let mut source = JsonlActivitySource::from_path(dir.path().join("missing.jsonl"));

    let events = source.poll();

    assert!(events.is_empty());
    assert!(source
        .last_error()
        .is_some_and(|error| error.to_string().contains("activity file missing")));
}

#[test]
fn directory_as_activity_file_reports_error() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("activity.jsonl");
    fs::create_dir(&path).expect("activity dir");
    let mut source = JsonlActivitySource::from_path(&path);

    let events = source.poll();

    assert!(events.is_empty());
    assert!(source
        .last_error()
        .is_some_and(|error| error.to_string().contains("not a regular file")));
}

#[test]
fn symlink_activity_file_is_rejected_before_open() {
    let dir = tempfile::tempdir().expect("tempdir");
    let target = dir.path().join("target.jsonl");
    let link = dir.path().join("activity.jsonl");
    fs::write(&target, "").expect("target");
    symlink(&target, &link).expect("symlink");
    let mut source = JsonlActivitySource::from_path(&link);

    let events = source.poll();

    assert!(events.is_empty());
    assert!(source
        .last_error()
        .is_some_and(|error| error.to_string().contains("symlink")));
}

#[test]
fn run_activity_path_outside_run_dir_is_rejected() {
    let dir = tempfile::tempdir().expect("tempdir");
    let run_dir = dir.path().join("run");
    let outside = dir.path().join("outside/activity.jsonl");
    fs::create_dir_all(&run_dir).expect("run dir");
    fs::create_dir_all(outside.parent().expect("outside parent")).expect("outside dir");
    fs::write(&outside, "").expect("outside file");
    let mut source = JsonlActivitySource::from_run_path(&outside, &run_dir);

    let events = source.poll();

    assert!(events.is_empty());
    assert!(source
        .last_error()
        .is_some_and(|error| error.to_string().contains("escapes expected directory")));
}

#[test]
fn oversized_malformed_record_is_dropped_and_counted() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("flightdeck-activity-S.jsonl");
    let huge = format!("{{\"oversized\":\"{}\"", "x".repeat(1024 * 1024 + 64));
    fs::write(&path, huge).expect("huge malformed record");
    let mut source = JsonlActivitySource::new(dir.path(), "S");

    let events = source.poll();

    assert!(events.is_empty());
    assert_eq!(source.malformed_lines(), 1);
    assert!(source
        .last_warning()
        .is_some_and(|warning| warning.contains("oversized")));
}
