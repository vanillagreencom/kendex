//! What the check says about evidence it could not read, findings waiting
//! on a person, and a fetch that has been failing for a while.

use super::tests::*;
use super::*;
use crate::drift::snapshot::{SNAPSHOT_SCHEMA, ScopeSnapshot};
use crate::drift::stamps;

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
        text.contains("1 install(s) held back by the safety check, 3 finding(s) awaiting review")
            // Reading the findings settles nothing on its own, so the line
            // points at it rather than calling it the fix.
            && text.contains("see: kendex findings"),
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
