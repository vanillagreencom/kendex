//! The `update-pi` plan and its execution, exercised end to end against a
//! sandboxed Pi directory.

use super::*;
use crate::pi_extension::SourceIndexEntry;
use crate::test_util::with_pi_dir;

fn make_sandbox(tag: &str) -> PathBuf {
    let sandbox = std::env::temp_dir().join(format!(
        "vstack_update_pi_{}_{}_{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    let _ = std::fs::remove_dir_all(&sandbox);
    std::fs::create_dir_all(&sandbox).unwrap();
    sandbox
}

fn write_source_pkg(repo: &Path, dir_name: &str, manifest_name: &str, version: &str) -> PathBuf {
    let dir = repo.join("pi-extensions").join(dir_name);
    std::fs::create_dir_all(dir.join("extensions")).unwrap();
    std::fs::write(dir.join("extensions").join("mini.ts"), "// noop\n").unwrap();
    std::fs::write(
        dir.join("package.json"),
        format!(
            r#"{{ "name": "{manifest_name}", "version": "{version}", "pi": {{ "extensions": ["./extensions/mini.ts"] }} }}"#
        ),
    )
    .unwrap();
    dir
}

fn write_installed_pkg(pi_dir: &Path, name: &str, version: &str) -> PathBuf {
    let dir = pi_dir.join("packages").join(name);
    std::fs::create_dir_all(dir.join("extensions")).unwrap();
    std::fs::write(dir.join("extensions").join("mini.ts"), "// noop\n").unwrap();
    std::fs::write(
        dir.join("package.json"),
        format!(r#"{{ "name": "{name}", "version": "{version}" }}"#),
    )
    .unwrap();
    dir
}

fn write_settings_packages(pi_dir: &Path, entries: &[&str]) {
    std::fs::create_dir_all(pi_dir).unwrap();
    let arr: Vec<serde_json::Value> = entries
        .iter()
        .map(|s| serde_json::Value::String((*s).to_string()))
        .collect();
    let value = serde_json::json!({ "packages": arr });
    std::fs::write(
        pi_dir.join("settings.json"),
        serde_json::to_string_pretty(&value).unwrap(),
    )
    .unwrap();
}

fn install_index(pi_dir: &Path, entries: &[(&str, SourceIndexEntry)]) {
    let mut idx = SourceIndex::new();
    for (k, v) in entries {
        idx.insert((*k).to_string(), v.clone());
    }
    std::fs::create_dir_all(pi_dir).unwrap();
    let path = pi_dir.join(".vstack-source.json");
    std::fs::write(&path, serde_json::to_string_pretty(&idx).unwrap()).unwrap();
}

#[test]
fn parse_semver_strips_prefix_and_suffix() {
    assert_eq!(parse_semver("1.2.3"), Some(vec![1, 2, 3]));
    assert_eq!(parse_semver("v1.2.3"), Some(vec![1, 2, 3]));
    assert_eq!(parse_semver("1.2.3-rc.1"), Some(vec![1, 2, 3]));
    assert_eq!(parse_semver("1.2.3+build.42"), Some(vec![1, 2, 3]));
    assert_eq!(parse_semver("0.1"), Some(vec![0, 1, 0]));
    assert_eq!(parse_semver("not-a-version"), None);
}

#[test]
fn is_newer_handles_unknown_and_equal() {
    assert!(is_newer(Some("0.2.0"), Some("0.1.0")));
    assert!(is_newer(Some("1.0.0"), Some("0.99.0")));
    assert!(!is_newer(Some("0.1.0"), Some("0.1.0")));
    assert!(!is_newer(Some("0.1.0"), Some("0.2.0")));
    assert!(!is_newer(None, Some("0.1.0")));
    assert!(!is_newer(Some("0.1.0"), None));
    // Major bump.
    assert!(is_newer(Some("2.0.0"), Some("1.99.99")));
}

#[test]
fn parse_scope_filter_accepts_aliases_and_rejects_garbage() {
    // Order matches ScopeFilter::globals() — project (false) before global (true) for All.
    assert_eq!(parse_scope_filter(None).unwrap(), vec![false, true]);
    assert_eq!(parse_scope_filter(Some("all")).unwrap(), vec![false, true]);
    assert_eq!(parse_scope_filter(Some("global")).unwrap(), vec![true]);
    assert_eq!(parse_scope_filter(Some("user")).unwrap(), vec![true]);
    assert_eq!(parse_scope_filter(Some("project")).unwrap(), vec![false]);
    assert_eq!(parse_scope_filter(Some("local")).unwrap(), vec![false]);
    assert!(parse_scope_filter(Some("garbage")).is_err());
}

#[test]
fn plan_marks_outdated_vstack_source_packages() {
    let sandbox = make_sandbox("plan_outdated");
    let repo = sandbox.join("repo");
    let pi_dir = sandbox.join("pi");
    write_source_pkg(&repo, "pi-foo", "pi-foo", "0.2.0");
    write_installed_pkg(&pi_dir, "pi-foo", "0.1.0");
    write_settings_packages(&pi_dir, &["./packages/pi-foo"]);
    install_index(
        &pi_dir,
        &[(
            "pi-foo",
            SourceIndexEntry {
                source_repo: Some(repo.to_string_lossy().into_owned()),
                source_path: Some(
                    repo.join("pi-extensions/pi-foo")
                        .to_string_lossy()
                        .into_owned(),
                ),
                source_version: Some("0.1.0".into()),
                ..Default::default()
            },
        )],
    );

    with_pi_dir(&pi_dir, || {
        let plan = plan_for_scope(true).unwrap();
        let item = plan
            .iter()
            .find(|p| p.name == "pi-foo")
            .expect("foo present");
        assert!(matches!(item.status, Status::Outdated));
        assert_eq!(item.installed_version.as_deref(), Some("0.1.0"));
        assert_eq!(item.latest_version.as_deref(), Some("0.2.0"));
        assert!(matches!(item.source, SourceKind::Vstack { .. }));
    });
    std::fs::remove_dir_all(&sandbox).ok();
}

#[test]
fn plan_resolves_source_when_dir_name_differs_from_package_name() {
    let sandbox = make_sandbox("plan_dir_mismatch");
    let repo = sandbox.join("repo");
    let pi_dir = sandbox.join("pi");
    // Source dir is `session-bridge` but manifest name is `pi-session-bridge`.
    let src_dir = write_source_pkg(&repo, "session-bridge", "pi-session-bridge", "0.5.0");
    write_installed_pkg(&pi_dir, "pi-session-bridge", "0.1.0");
    write_settings_packages(&pi_dir, &["./packages/pi-session-bridge"]);
    install_index(
        &pi_dir,
        &[(
            "pi-session-bridge",
            SourceIndexEntry {
                source_repo: Some(repo.to_string_lossy().into_owned()),
                source_path: Some(src_dir.to_string_lossy().into_owned()),
                source_version: Some("0.1.0".into()),
                ..Default::default()
            },
        )],
    );

    with_pi_dir(&pi_dir, || {
        let plan = plan_for_scope(true).unwrap();
        let item = plan
            .iter()
            .find(|p| p.name == "pi-session-bridge")
            .expect("item present");
        assert!(matches!(item.status, Status::Outdated));
        assert_eq!(item.latest_version.as_deref(), Some("0.5.0"));
    });
    std::fs::remove_dir_all(&sandbox).ok();
}

#[test]
fn plan_marks_stale_index_when_package_dir_missing() {
    let sandbox = make_sandbox("plan_stale");
    let repo = sandbox.join("repo");
    let pi_dir = sandbox.join("pi");
    // Index references a package that never got installed (no packages dir).
    std::fs::create_dir_all(&repo).unwrap();
    std::fs::create_dir_all(&pi_dir).unwrap();
    install_index(
        &pi_dir,
        &[(
            "pi-ghost",
            SourceIndexEntry {
                source_repo: Some(repo.to_string_lossy().into_owned()),
                source_version: Some("0.1.0".into()),
                ..Default::default()
            },
        )],
    );

    with_pi_dir(&pi_dir, || {
        let plan = plan_for_scope(true).unwrap();
        let item = plan.iter().find(|p| p.name == "pi-ghost").expect("present");
        assert!(matches!(item.status, Status::StaleIndex));
    });
    std::fs::remove_dir_all(&sandbox).ok();
}

#[test]
fn plan_marks_unknown_when_source_repo_missing() {
    let sandbox = make_sandbox("plan_repo_missing");
    let pi_dir = sandbox.join("pi");
    let bogus_repo = sandbox.join("does/not/exist");
    write_installed_pkg(&pi_dir, "pi-foo", "0.1.0");
    write_settings_packages(&pi_dir, &["./packages/pi-foo"]);
    install_index(
        &pi_dir,
        &[(
            "pi-foo",
            SourceIndexEntry {
                source_repo: Some(bogus_repo.to_string_lossy().into_owned()),
                source_version: Some("0.1.0".into()),
                ..Default::default()
            },
        )],
    );

    with_pi_dir(&pi_dir, || {
        let plan = plan_for_scope(true).unwrap();
        let item = plan.iter().find(|p| p.name == "pi-foo").expect("present");
        assert!(matches!(item.status, Status::Unknown));
    });
    std::fs::remove_dir_all(&sandbox).ok();
}

#[test]
fn plan_marks_installed_without_index_as_unknown() {
    let sandbox = make_sandbox("plan_no_index");
    let pi_dir = sandbox.join("pi");
    write_installed_pkg(&pi_dir, "pi-orphan", "0.1.0");
    write_settings_packages(&pi_dir, &["./packages/pi-orphan"]);
    // No source index file at all.

    with_pi_dir(&pi_dir, || {
        let plan = plan_for_scope(true).unwrap();
        let item = plan
            .iter()
            .find(|p| p.name == "pi-orphan")
            .expect("present");
        assert!(matches!(item.status, Status::Unknown));
        assert_eq!(item.installed_version.as_deref(), Some("0.1.0"));
    });
    std::fs::remove_dir_all(&sandbox).ok();
}

#[test]
fn execute_updates_outdated_vstack_package_and_advances_index() {
    let sandbox = make_sandbox("exec_update");
    let repo = sandbox.join("repo");
    let pi_dir = sandbox.join("pi");
    let src_dir = write_source_pkg(&repo, "pi-bar", "pi-bar", "0.2.0");
    write_installed_pkg(&pi_dir, "pi-bar", "0.1.0");
    write_settings_packages(&pi_dir, &["./packages/pi-bar"]);
    install_index(
        &pi_dir,
        &[(
            "pi-bar",
            SourceIndexEntry {
                source_repo: Some(repo.to_string_lossy().into_owned()),
                source_path: Some(src_dir.to_string_lossy().into_owned()),
                source_version: Some("0.1.0".into()),
                ..Default::default()
            },
        )],
    );

    with_pi_dir(&pi_dir, || {
        let plan = plan_for_scope(true).unwrap();
        execute(&plan).unwrap();

        let manifest_after = pi_dir.join("packages/pi-bar/package.json");
        let raw = std::fs::read_to_string(&manifest_after).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(parsed["version"].as_str(), Some("0.2.0"));

        let idx = read_source_index(true).unwrap();
        assert_eq!(
            idx.get("pi-bar").and_then(|e| e.source_version.clone()),
            Some("0.2.0".into())
        );
    });
    std::fs::remove_dir_all(&sandbox).ok();
}

#[test]
fn execute_drops_stale_index_entry() {
    let sandbox = make_sandbox("exec_stale");
    let repo = sandbox.join("repo");
    let pi_dir = sandbox.join("pi");
    std::fs::create_dir_all(&repo).unwrap();
    std::fs::create_dir_all(&pi_dir).unwrap();
    install_index(
        &pi_dir,
        &[(
            "pi-ghost",
            SourceIndexEntry {
                source_repo: Some(repo.to_string_lossy().into_owned()),
                source_version: Some("0.1.0".into()),
                ..Default::default()
            },
        )],
    );

    with_pi_dir(&pi_dir, || {
        let plan = plan_for_scope(true).unwrap();
        execute(&plan).unwrap();
        let idx = read_source_index(true).unwrap();
        assert!(!idx.contains_key("pi-ghost"));
    });
    std::fs::remove_dir_all(&sandbox).ok();
}

/// A source cache another vstack process is fetching and resetting is not a
/// source to compare versions against — an older `package.json` mid-reset
/// reads as an update, and update-pi would then copy a half-written package
/// over a live Pi install. The plan reports the contention and stands down.
#[cfg(unix)]
#[test]
fn plan_stands_down_while_a_source_cache_is_being_refreshed() {
    use std::os::unix::io::AsRawFd;

    let sandbox = make_sandbox("plan_busy_cache");
    let repo = sandbox.join("repo");
    let pi_dir = sandbox.join("pi");
    write_source_pkg(&repo, "pi-foo", "pi-foo", "0.2.0");
    write_installed_pkg(&pi_dir, "pi-foo", "0.1.0");
    write_settings_packages(&pi_dir, &["./packages/pi-foo"]);
    install_index(
        &pi_dir,
        &[(
            "pi-foo",
            SourceIndexEntry {
                source_repo: Some(repo.to_string_lossy().into_owned()),
                source_path: Some(
                    repo.join("pi-extensions/pi-foo")
                        .to_string_lossy()
                        .into_owned(),
                ),
                source_version: Some("0.1.0".into()),
                ..Default::default()
            },
        )],
    );

    // Control: uncontended, the update is planned exactly as before.
    with_pi_dir(&pi_dir, || {
        let plan = plan_for_scope(true).unwrap();
        let item = plan.iter().find(|p| p.name == "pi-foo").unwrap();
        assert!(matches!(item.status, Status::Outdated));
    });

    std::fs::create_dir_all(repo.join(".git")).unwrap();
    let lock = std::fs::File::options()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(repo.join(".git").join("vstack-fetch.lock"))
        .unwrap();
    // SAFETY: the descriptor is live for the whole call, and the lock is
    // released when the file is dropped at the end of the test.
    assert_eq!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0
    );

    with_pi_dir(&pi_dir, || {
        let plan = plan_for_scope(true).unwrap();
        let item = plan.iter().find(|p| p.name == "pi-foo").unwrap();
        assert!(
            matches!(item.status, Status::Unknown),
            "a cache being rewritten cannot answer the version question"
        );
        assert_eq!(item.note.as_deref(), Some(BUSY_SOURCE_NOTE));
        assert_eq!(item.latest_version, None);
    });
    drop(lock);
    std::fs::remove_dir_all(&sandbox).ok();
}
