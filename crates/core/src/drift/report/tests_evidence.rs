//! What the check says about evidence it could not read, and a fetch that
//! has been failing for a while.

use super::tests::*;
use super::*;
use crate::drift::snapshot::{SNAPSHOT_SCHEMA, ScopeSnapshot, UnreadableSnapshot};
use crate::drift::stamps;

#[test]
fn missing_remote_comparison_data_names_each_package() {
    for (evaluated, current) in [
        (Some("same-refs"), None),
        (None, Some("same-refs")),
        (None, None),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let scope = project_scope(tmp.path());
        write_manifest(&env, &scope, &manifest_with_remote());
        snapshot_with(
            &env,
            &scope,
            vec![crate::drift::snapshot::PackageSnapshot {
                refs_state: evaluated.map(str::to_owned),
                ..package("orch")
            }],
        );
        record_refs(&env, "owner/repo", current);

        let report = check(
            &env,
            std::slice::from_ref(&scope),
            crate::drift::copies::CheckMode::Settle,
        );
        assert_eq!(report.status.exit_code(), 1, "{evaluated:?}, {current:?}");
        let line = &report.sections[0].lines[0];
        assert!(
            line.text
                .contains("skill 'orch': could not compare source versions")
        );
        assert_eq!(line.class, Class::Unevaluated);
        assert_eq!(line.remedy, Some(Remedy::Refresh { global: false }));
    }
}

#[test]
fn a_local_package_keeps_its_snapshot_verdict_without_remote_evidence() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let mut local = package("local");
    local.repo.clear();
    local.refs_state = None;
    local.update_available = true;
    snapshot_with(&env, &scope, vec![local]);

    let report = check(
        &env,
        std::slice::from_ref(&scope),
        crate::drift::copies::CheckMode::Settle,
    );
    assert_eq!(report.sections[0].title, "stale");
    assert!(report.sections[0].lines[0].text.contains("skill 'local'"));
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

    let report = check(
        &env,
        std::slice::from_ref(&scope),
        crate::drift::copies::CheckMode::Settle,
    );
    assert_eq!(report.status, CheckStatus::Unknown);
    let text = render_plain(&report, Verbosity::Verbose);
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
        check(
            &env,
            std::slice::from_ref(&scope),
            crate::drift::copies::CheckMode::Settle
        )
        .status,
        CheckStatus::Clean
    );
}

#[test]
fn unreadable_evidence_is_current_only_at_its_evaluated_source() {
    for (repo, evaluated, current, changed) in [
        ("owner/repo", Some("same-refs"), Some("same-refs"), false),
        ("owner/repo", Some("old-refs"), Some("new-refs"), true),
        ("owner/repo", None, Some("new-refs"), true),
        ("owner/repo", None, None, false),
        ("", None, Some("new-refs"), false),
    ] {
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
                unreadable: vec![UnreadableSnapshot {
                    kind: crate::model::ItemKind::Skill,
                    name: "gh".into(),
                    message: "history could not be read".into(),
                    detail: None,
                    repo: repo.into(),
                    refs_state: evaluated.map(str::to_owned),
                }],
            },
        )
        .unwrap();

        record_refs(&env, "owner/repo", current);

        let report = check(
            &env,
            std::slice::from_ref(&scope),
            crate::drift::copies::CheckMode::Settle,
        );
        assert_eq!(
            report.sections[0].lines[0].class,
            if evaluated.is_some() && current.is_some() && changed {
                Class::Settling
            } else {
                Class::Unknown
            }
        );
        assert_eq!(
            wants_background_refresh(&env, std::slice::from_ref(&scope), &report),
            changed
        );
    }
}

/// Fetch age is not recovery evidence. Supersession requires known refs
/// and the same enabled mirror, with no recorded failure.
#[test]
#[allow(clippy::too_many_lines)]
fn unreadable_evidence_due_a_fetch_keeps_its_cause() {
    let due = 2 * stamps::TTL.as_secs();
    // (fetch age, declaration, enabled, failure age, evaluated, current, class)
    for (fetched_ago, declared, enabled, failure, evaluated, current, class) in [
        (
            due,
            "owner/repo",
            true,
            None,
            Some("refs"),
            Some("refs"),
            Class::Unknown,
        ),
        (
            0,
            "owner/repo",
            true,
            None,
            Some("refs"),
            Some("refs"),
            Class::Unknown,
        ),
        (
            due,
            "owner/repo",
            true,
            None,
            None,
            Some("refs"),
            Class::Unknown,
        ),
        (
            due,
            "owner/repo",
            true,
            None,
            Some("refs"),
            None,
            Class::Unknown,
        ),
        (due, "owner/repo", true, None, None, None, Class::Unknown),
        (
            0,
            "owner/repo",
            true,
            None,
            Some("old"),
            Some("refs"),
            Class::Settling,
        ),
        (
            due,
            "https://github.com/owner/repo.git",
            true,
            None,
            Some("old"),
            Some("refs"),
            Class::Settling,
        ),
        (
            due,
            "owner/repo",
            false,
            None,
            Some("old"),
            Some("refs"),
            Class::Unevaluated,
        ),
        (
            due,
            "unrelated/repo",
            true,
            None,
            Some("old"),
            Some("refs"),
            Class::Unevaluated,
        ),
        (
            due,
            "owner/repo",
            true,
            Some(0),
            Some("old"),
            Some("refs"),
            Class::Unevaluated,
        ),
        (
            due,
            "owner/repo",
            true,
            Some(3 * stamps::TTL.as_secs()),
            Some("old"),
            Some("refs"),
            Class::Unevaluated,
        ),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let scope = project_scope(tmp.path());
        let mut manifest = manifest_with_remote();
        let source = manifest.sources.get_mut("cat").unwrap();
        source.repo = Some(declared.into());
        source.enabled = enabled;
        write_manifest(&env, &scope, &manifest);
        let now = crate::clock::unix_now();
        let note = UnreadableSnapshot {
            kind: crate::model::ItemKind::Skill,
            name: "gh".into(),
            message: "its version history could not be read".into(),
            detail: Some("git log failed: fatal: bad object f7db7e89".into()),
            repo: "owner/repo".into(),
            refs_state: evaluated.map(str::to_owned),
        };
        for with_package in [false, true] {
            crate::drift::snapshot::store(
                &env,
                &scope,
                &ScopeSnapshot {
                    schema: SNAPSHOT_SCHEMA,
                    taken_at: now - 7 * 3600,
                    scope: scope.canonical().label(),
                    packages: if with_package {
                        vec![crate::drift::snapshot::PackageSnapshot {
                            refs_state: evaluated.map(str::to_owned),
                            ..package("gh")
                        }]
                    } else {
                        vec![]
                    },
                    unreadable: vec![note.clone(), note.clone()],
                },
            )
            .unwrap();
            let key = crate::remote::cache_key(&env, "owner/repo");
            stamps::record_success(&env, &key, current.map(str::to_owned), now - fetched_ago)
                .unwrap();
            if let Some(failed_ago) = failure {
                stamps::record_failure(&env, &key, "could not resolve host", now - failed_ago)
                    .unwrap();
            }
            let report = check(
                &env,
                std::slice::from_ref(&scope),
                crate::drift::copies::CheckMode::Settle,
            );
            let lines: Vec<_> = report
                .sections
                .iter()
                .flat_map(|section| &section.lines)
                .collect();
            let line = lines.iter().find(|line| line.text.contains("gh")).unwrap();
            assert_eq!(line.class, class, "{declared}, {evaluated:?}, {current:?}");
            assert_eq!(
                lines.iter().filter(|line| line.text.contains("gh")).count(),
                1
            );
            assert!(line.text.contains(&note.message));
            assert!(
                line.detail
                    .as_deref()
                    .unwrap()
                    .contains(note.detail.as_deref().unwrap())
            );
            if failure.is_some() {
                assert!(
                    line.detail
                        .as_deref()
                        .unwrap()
                        .contains("could not resolve host")
                );
            }
            let old_failure = failure.is_some_and(|age| age > 2 * stamps::TTL.as_secs());
            assert_eq!(
                report.status,
                if old_failure || class == Class::Unknown {
                    CheckStatus::Unknown
                } else {
                    CheckStatus::Drift
                }
            );
            assert_eq!(line.remedy.is_none(), class != Class::Unevaluated);
        }
    }
}

/// A snapshot from before the schema split a warning's message from its
/// detail carries the git command and its output in `message`. It reads as
/// not yet evaluated, so that text never reaches the report and the
/// background refresh derives a current one. The current schema with the
/// same note is the control that does print it.
#[test]
fn a_snapshot_from_before_the_detail_split_reads_as_not_evaluated() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    record_refs(&env, "owner/repo", Some("refs"));
    for (schema, current) in [(3, false), (SNAPSHOT_SCHEMA, true)] {
        let path = crate::drift::snapshot::snapshot_path(&env, &scope);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            serde_json::json!({
                "schema": schema,
                "taken-at": crate::clock::unix_now(),
                "scope": scope.canonical().label(),
                "packages": [],
                "unreadable": [{
                    "kind": "skill",
                    "name": "gh",
                    "message": "history could not be read: git log failed: fatal: bad object f7db7e89",
                    "repo": "owner/repo",
                    "refs-state": "refs",
                }],
            })
            .to_string(),
        )
        .unwrap();

        let loaded = crate::drift::snapshot::load(&env, &scope);
        assert_eq!(
            matches!(loaded, crate::drift::snapshot::SnapshotFile::Current(_)),
            current,
            "schema {schema}: {loaded:?}"
        );
        let report = check(
            &env,
            std::slice::from_ref(&scope),
            crate::drift::copies::CheckMode::Settle,
        );
        let said = report
            .sections
            .iter()
            .flat_map(|section| &section.lines)
            .any(|line| line.text.contains("bad object"));
        assert_eq!(said, current, "schema {schema}: {report:?}");
        if !current {
            assert!(wants_background_refresh(
                &env,
                std::slice::from_ref(&scope),
                &report
            ));
        }
    }
}
