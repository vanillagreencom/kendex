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
            if changed {
                Class::Unevaluated
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

/// A could-not-check whose source is due a fetch is settled by the
/// background refresh the check starts for that fetch: the line is
/// settling, the check is clean, and the refresh it relies on is wanted.
/// Rows: the same note after a fetch that just ran; a source declared
/// under another spelling of the same mirror, which that refresh fetches;
/// a disabled source, which it never fetches, so the note stays
/// could-not-check; and a due fetch whose retry already failed, which
/// settled nothing.
#[test]
fn unreadable_evidence_due_a_fetch_settles_in_the_background() {
    let due = 2 * stamps::TTL.as_secs();
    let (settling, unknown) = (
        (Class::Settling, CheckStatus::Clean),
        (Class::Unknown, CheckStatus::Unknown),
    );
    // (fetched ago, declared spelling, enabled, retry failed, expected)
    for (fetched_ago, declared, enabled, retry_failed, (class, status)) in [
        (due, "owner/repo", true, false, settling),
        (0, "owner/repo", true, false, unknown),
        (
            due,
            "https://github.com/owner/repo.git",
            true,
            false,
            settling,
        ),
        (due, "owner/repo", false, false, unknown),
        (due, "owner/repo", true, true, unknown),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let scope = project_scope(tmp.path());
        assert_eq!(
            crate::remote::cache_key(&env, declared),
            crate::remote::cache_key(&env, "owner/repo"),
            "the rows name one mirror"
        );
        let mut manifest = manifest_with_remote();
        let source = manifest.sources.get_mut("cat").unwrap();
        source.repo = Some(declared.into());
        source.enabled = enabled;
        write_manifest(&env, &scope, &manifest);
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
                    message: "its version history could not be read".into(),
                    detail: Some("git log failed: fatal: bad object f7db7e89".into()),
                    repo: "owner/repo".into(),
                    refs_state: Some("refs".into()),
                }],
            },
        )
        .unwrap();
        let key = crate::remote::cache_key(&env, "owner/repo");
        stamps::record_success(
            &env,
            &key,
            Some("refs".into()),
            crate::clock::unix_now() - fetched_ago,
        )
        .unwrap();
        if retry_failed {
            stamps::record_failure(
                &env,
                &key,
                "could not resolve host",
                crate::clock::unix_now(),
            )
            .unwrap();
        }

        let report = check(
            &env,
            std::slice::from_ref(&scope),
            crate::drift::copies::CheckMode::Settle,
        );
        let line = &report.sections[0].lines[0];
        let row = format!("{declared} enabled={enabled} retry_failed={retry_failed}");
        assert_eq!(line.class, class, "{row}");
        assert_eq!(report.status, status, "{row}");
        assert_eq!(
            line.detail.as_deref(),
            Some("git log failed: fatal: bad object f7db7e89")
        );
        if class == Class::Settling {
            assert!(wants_background_refresh(
                &env,
                std::slice::from_ref(&scope),
                &report
            ));
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
