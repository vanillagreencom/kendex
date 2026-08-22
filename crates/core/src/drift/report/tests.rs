use std::path::Path;

use super::*;
use crate::drift::snapshot::{PackageSnapshot, SNAPSHOT_SCHEMA, ScopeSnapshot};
use crate::drift::stamps;
use crate::env::FakeOs;
use crate::model::Scope;

pub(super) fn env_in(dir: &Path) -> Env {
    Env::fake(dir, FakeOs::Linux)
}

pub(super) fn project_scope(dir: &Path) -> Scope {
    let root = dir.join("proj");
    std::fs::create_dir_all(&root).unwrap();
    Scope::Project {
        root: root.canonicalize().unwrap(),
    }
}

pub(super) fn write_manifest(env: &Env, scope: &Scope, manifest: &crate::manifest::Manifest) {
    crate::manifest::save(&crate::manifest::manifest_path(env, scope), manifest).unwrap();
}

pub(super) fn manifest_with_remote() -> crate::manifest::Manifest {
    let mut manifest = crate::manifest::Manifest {
        schema: crate::manifest::MANIFEST_SCHEMA,
        ..Default::default()
    };
    manifest.sources.insert(
        "cat".into(),
        crate::manifest::SourceDecl {
            repo: Some("owner/repo".into()),
            path: None,
            rev: None,
            enabled: true,
        },
    );
    manifest
}

pub(super) fn package(name: &str) -> PackageSnapshot {
    PackageSnapshot {
        kind: crate::model::ItemKind::Skill,
        name: name.into(),
        source: "cat".into(),
        repo: "owner/repo".into(),
        refs_state: None,
        update_available: false,
        removed_upstream: false,
        held: false,
        ignored: false,
        edited: false,
        mixed: false,
        forked: false,
        derived: false,
        can_discard: true,
        open_findings: 0,
    }
}

pub(super) fn snapshot_with(env: &Env, scope: &Scope, packages: Vec<PackageSnapshot>) {
    snapshot_aged(env, scope, packages, crate::clock::unix_now());
}

pub(super) fn snapshot_aged(
    env: &Env,
    scope: &Scope,
    packages: Vec<PackageSnapshot>,
    taken_at: u64,
) {
    crate::drift::snapshot::store(
        env,
        scope,
        &ScopeSnapshot {
            schema: SNAPSHOT_SCHEMA,
            taken_at,
            scope: scope.canonical().label(),
            packages,
            unreadable: Vec::new(),
            held_back_items: 0,
            open_evidence: 0,
        },
    )
    .unwrap();
}

#[test]
fn a_clean_scope_is_silent_and_exit_zero() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(&env, &scope, vec![package("gh")]);

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Clean);
    assert_eq!(report.status.exit_code(), 0);
    assert_eq!(render_plain(&report), "");
}

#[test]
fn held_only_and_ignored_only_drift_stays_silent() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    let held = PackageSnapshot {
        update_available: true,
        held: true,
        ..package("held-one")
    };
    let ignored = PackageSnapshot {
        update_available: true,
        removed_upstream: false,
        ignored: true,
        ..package("muted-one")
    };
    // Even an edited or removed-upstream package stays quiet while held:
    // a hold is a decision already made.
    let held_edited = PackageSnapshot {
        edited: true,
        held: true,
        ..package("held-two")
    };
    snapshot_with(&env, &scope, vec![held, ignored, held_edited]);

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Clean, "{report:?}");
    assert_eq!(render_plain(&report), "");
}

#[test]
fn a_mirror_that_moved_since_evaluation_reads_as_unevaluated() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    let key = crate::remote::store::repo_key(&crate::remote::clone_url(&env, "owner/repo"));
    stamps::record_success(
        &env,
        &key,
        Some("new-refs".into()),
        crate::clock::unix_now(),
    )
    .unwrap();
    snapshot_with(
        &env,
        &scope,
        vec![PackageSnapshot {
            update_available: true,
            refs_state: Some("old-refs".into()),
            ..package("moved")
        }],
    );

    let report = check(&env, std::slice::from_ref(&scope));
    // The honest "maybe": never a guessed verdict, and unknown beats drift.
    assert_eq!(report.status, CheckStatus::Unknown);
    assert_eq!(report.status.exit_code(), 2);
    let text = render_plain(&report);
    assert!(text.contains("not yet evaluated"), "{text}");
    assert!(!text.contains("stale:"), "{text}");
}

#[test]
fn a_scope_with_remotes_and_no_snapshot_is_unevaluated() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Unknown);
    assert!(render_plain(&report).contains("not yet evaluated"));
}

#[test]
fn snapshot_age_is_rendered() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_aged(
        &env,
        &scope,
        vec![PackageSnapshot {
            update_available: true,
            ..package("stale-one")
        }],
        crate::clock::unix_now() - 3 * 3600,
    );

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.snapshot_age_secs.map(|age| age / 3600), Some(3));
    assert!(render_plain(&report).contains("(checked against sources 3h ago)"));
}

#[test]
fn missing_skill_reference_stays_a_failure() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let mut manifest = manifest_with_remote();
    manifest
        .agent_skills
        .insert("orch".into(), vec!["ghost".into()]);
    write_manifest(&env, &scope, &manifest);
    snapshot_with(&env, &scope, vec![]);

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Drift);
    let text = render_plain(&report);
    assert!(
        text.contains("references skill 'ghost'") && text.contains("kendex add --skill ghost"),
        "{text}"
    );
}

#[test]
fn corrupt_manifest_and_lock_are_could_not_check() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let manifest_path = crate::manifest::manifest_path(&env, &scope);
    std::fs::create_dir_all(manifest_path.parent().unwrap()).unwrap();
    std::fs::write(&manifest_path, "not = [valid").unwrap();
    std::fs::write(crate::lock::lock_path(&env, &scope), "{definitely not json").unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Unknown);
    let text = render_plain(&report);
    assert!(text.contains("could not check:"), "{text}");
    assert!(text.contains("manifest:"), "{text}");
    assert!(text.contains("lock:"), "{text}");
}

#[test]
fn an_old_fetch_failure_becomes_a_line_dated_from_first_failure() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(&env, &scope, vec![]);
    let key = crate::remote::store::repo_key(&crate::remote::clone_url(&env, "owner/repo"));
    let first = crate::clock::unix_now() - 3 * stamps::TTL.as_secs();
    stamps::record_failure(&env, &key, "could not resolve host", first).unwrap();
    stamps::record_failure(&env, &key, "still down", first + 60).unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Unknown);
    let text = render_plain(&report);
    assert!(
        text.contains(&format!(
            "source owner/repo unreachable since {}",
            crate::clock::iso_from_unix(first)
        )),
        "{text}"
    );

    // A fresh failure is not yet drift — a flaky hour never nags.
    stamps::record_success(&env, &key, None, crate::clock::unix_now()).unwrap();
    stamps::record_failure(&env, &key, "blip", crate::clock::unix_now()).unwrap();
    assert_eq!(
        check(&env, std::slice::from_ref(&scope)).status,
        CheckStatus::Clean
    );
}

#[test]
fn open_findings_and_held_back_render_with_the_findings_remedy() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    crate::drift::snapshot::store(
        &env,
        &scope,
        &ScopeSnapshot {
            schema: SNAPSHOT_SCHEMA,
            taken_at: crate::clock::unix_now(),
            scope: scope.canonical().label(),
            packages: vec![],
            unreadable: vec![],
            held_back_items: 1,
            open_evidence: 3,
        },
    )
    .unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Drift);
    let text = render_plain(&report);
    assert!(
        text.contains("1 install(s) held back, 3 finding(s) awaiting review")
            && text.contains("fix: kendex findings"),
        "{text}"
    );
}

#[test]
fn unreadable_evidence_is_could_not_check() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    crate::drift::snapshot::store(
        &env,
        &scope,
        &ScopeSnapshot {
            schema: SNAPSHOT_SCHEMA,
            taken_at: crate::clock::unix_now(),
            scope: scope.canonical().label(),
            packages: vec![],
            unreadable: vec!["skill gh: history could not be read".into()],
            held_back_items: 0,
            open_evidence: 0,
        },
    )
    .unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Unknown);
    assert!(render_plain(&report).contains("history could not be read"));
}
