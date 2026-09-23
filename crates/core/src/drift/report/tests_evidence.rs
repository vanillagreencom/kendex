//! What the check says about evidence it could not read, and a fetch that
//! has been failing for a while.

use super::tests::*;
use super::*;
use crate::drift::snapshot::{SNAPSHOT_SCHEMA, ScopeSnapshot};
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

        let report = check(&env, std::slice::from_ref(&scope));
        assert_eq!(report.status.exit_code(), 1, "{evaluated:?}, {current:?}");
        let line = &report.sections[0].lines[0];
        assert!(
            line.text
                .contains("skill 'orch': could not compare source versions")
        );
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

    let report = check(&env, std::slice::from_ref(&scope));
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
        },
    )
    .unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Unknown);
    assert!(render_plain(&report).contains("history could not be read"));
}
