//! Receipt trust lasts for one operation, across all of its package reads.

use super::*;
use crate::{apply, drift, engine, manifest, model::Scope, package};

#[test]
fn a_multi_package_refresh_and_updates_hash_each_distinct_snapshot_once() {
    let f = fixture();
    let project = f._tmp.path().join("project");
    fs::create_dir_all(&project).unwrap();
    let scope = Scope::Project { root: project };
    let mut declaration = manifest::seed(&scope, &[]);
    declaration.sources.clear();
    declaration.install.harnesses = vec![
        crate::model::HarnessId::Claude,
        crate::model::HarnessId::Codex,
        crate::model::HarnessId::Pi,
    ];
    let mut snapshots = Vec::new();
    for catalog in ["first", "second", "third"] {
        let repo = format!("owner/{catalog}");
        let upstream = f._tmp.path().join("base").join(&repo);
        for suffix in ["alpha", "beta", "gamma", "delta"] {
            let name = format!("{catalog}-{suffix}");
            let skill = upstream.join("skills").join(&name);
            fs::create_dir_all(&skill).unwrap();
            fs::write(
                skill.join("SKILL.md"),
                format!("---\nname: {name}\ndescription: fixture\n---\nFixture.\n"),
            )
            .unwrap();
            declaration
                .skills
                .insert(name, manifest::ItemDecl::from_source(catalog));
        }
        git(&upstream, &["init", "--quiet", "-b", "main"]);
        commit(&upstream, "catalog");
        declaration.sources.insert(
            catalog.to_owned(),
            manifest::SourceDecl {
                repo: Some(repo.clone()),
                path: None,
                rev: None,
                enabled: true,
            },
        );
        snapshots.push(sync(&f.env, &repo, None).unwrap().root);
    }
    manifest::save(&manifest::manifest_path(&f.env, &scope), &declaration).unwrap();
    apply::execute(&f.env, &engine::audit(&f.env, &scope).unwrap().plan).unwrap();

    let refresh = f.env.next_invocation();
    let before: Vec<_> = snapshots
        .iter()
        .map(|p| store::signature_calls(p))
        .collect();
    assert!(
        sync_declared_sources(&refresh, &declaration)
            .failures
            .is_empty()
    );
    let plan = engine::audit(&refresh, &scope).unwrap().plan;
    assert!(plan.is_empty());
    apply::execute(&refresh, &plan).unwrap();
    let snapshot = drift::snapshot::record(&refresh.clone(), &scope).unwrap();
    assert_eq!(snapshot.packages.len(), declaration.skills.len());
    assert!(snapshot.packages.iter().all(|row| !row.update_available));
    for (root, before) in snapshots.iter().zip(before) {
        assert_eq!(store::signature_calls(root) - before, 1);
    }

    let updates = refresh.next_invocation();
    let before: Vec<_> = snapshots
        .iter()
        .map(|p| store::signature_calls(p))
        .collect();
    let report = package::updates::updates(&updates, &scope).unwrap();
    assert_eq!(report.rows.len(), declaration.skills.len());
    assert!(report.warnings.is_empty());
    assert!(report.rows.iter().all(|row| !row.update_available));
    assert_eq!(
        report,
        package::updates::updates(&updates.clone(), &scope).unwrap()
    );
    for (root, before) in snapshots.iter().zip(before) {
        assert_eq!(store::signature_calls(root) - before, 1);
    }
}

#[test]
fn a_new_operation_revalidates_tampered_snapshots_and_a_new_revision() {
    let f = fixture();
    let first = sync(&f.env, REPO, None).unwrap();
    let key = key_for(&f.env);
    assert!(store::published(&f.env, &key, &first.commit).is_some());
    assert!(store::published(&f.env.clone(), &key, &first.commit).is_some());
    let before = store::signature_calls(&first.root);
    let next = f.env.next_invocation();
    assert!(store::published(&next, &key, &first.commit).is_some());
    assert_eq!(store::signature_calls(&first.root) - before, 1);
    write_skill(&first.root, "tampered");
    let next = next.next_invocation();
    assert!(store::published(&next, &key, &first.commit).is_none());
    assert!(next.held().checkouts.is_empty());
    let repaired = cached(&next, REPO, None).unwrap().unwrap();
    assert!(body(&repaired.root).contains("v1"));

    write_skill(&f.upstream, "v2");
    let revision = commit(&f.upstream, "two");
    let second = sync(&next, REPO, None).unwrap();
    assert_eq!(second.commit, revision);
    assert_ne!(second.root, first.root);
    let before = store::signature_calls(&second.root);
    assert!(store::published(&next, &key, &second.commit).is_some());
    assert_eq!(store::signature_calls(&second.root) - before, 1);
    assert!(body(&second.root).contains("v2"));
}

#[test]
fn a_changed_or_unreadable_receipt_revokes_validation_in_the_same_operation() {
    for defect in ["signature", "rules", "missing", "unreadable"] {
        let f = fixture();
        let first = sync(&f.env, REPO, None).unwrap();
        let key = key_for(&f.env);
        let receipt = store::receipt_path(&f.env, &key, &first.commit);
        let valid = fs::read_to_string(&receipt).unwrap();
        assert!(store::published(&f.env, &key, &first.commit).is_some());
        match defect {
            "signature" => fs::write(&receipt, "kendex-checkout 2\nwrong\n").unwrap(),
            "rules" => fs::write(
                &receipt,
                valid.replacen("kendex-checkout 2", "kendex-checkout 1", 1),
            )
            .unwrap(),
            "missing" => fs::remove_file(&receipt).unwrap(),
            "unreadable" => {
                fs::remove_file(&receipt).unwrap();
                fs::create_dir(&receipt).unwrap();
            }
            _ => unreachable!(),
        }
        assert!(
            store::published(&f.env, &key, &first.commit).is_none(),
            "{defect}"
        );
        if defect == "unreadable" {
            fs::remove_dir(&receipt).unwrap();
        }
        fs::write(&receipt, valid).unwrap();
        write_skill(&first.root, "tampered after refusal");
        assert!(
            store::published(&f.env, &key, &first.commit).is_none(),
            "{defect}"
        );
    }
}

#[test]
fn concurrent_operations_share_the_download_and_validate_independently() {
    let f = fixture();
    let key = key_for(&f.env);
    let guard = store::lock_repo(&f.env, &key, REPO).unwrap();
    let (waiting, acknowledgements) = std::sync::mpsc::channel();
    let results = std::thread::scope(|scope| {
        let tasks: Vec<_> = (0..2)
            .map(|_| {
                // A cold clone on CI can exceed the fixture's short deadline.
                let env = f
                    .env
                    .next_invocation()
                    .with_source_cache_wait(crate::env::SourceCacheWait::Foreground);
                let waiting = waiting.clone();
                scope.spawn(move || {
                    store::acknowledge_next_wait(waiting);
                    let result = sync(&env, REPO, None).unwrap();
                    for _ in 0..2 {
                        assert!(store::published(&env, &key_for(&env), &result.commit).is_some());
                    }
                    assert_eq!(store::signature_calls(&result.root), 1);
                    (result.root, result.commit, store::mirror_clone_calls())
                })
            })
            .collect();
        drop(waiting);
        for _ in 0..tasks.len() {
            acknowledgements.recv().unwrap();
        }
        drop(guard);
        tasks
            .into_iter()
            .map(|task| task.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert_eq!(results[0].0, results[1].0);
    assert_eq!(results[0].1, results[1].1);
    assert_eq!(results.iter().map(|result| result.2).sum::<usize>(), 1);
    assert!(body(&results[0].0).contains("v1"));
    assert_eq!(
        store::resolve_ref(&store::mirror_dir(&f.env, &key_for(&f.env)), "HEAD"),
        Some(results[0].1.clone())
    );
}

#[test]
fn the_same_commit_in_another_repository_needs_its_own_validation() {
    let f = fixture();
    let first = sync(&f.env, REPO, None).unwrap();
    assert!(store::published(&f.env, &key_for(&f.env), &first.commit).is_some());
    let other_repo = "owner/other";
    let other = f._tmp.path().join("base").join(other_repo);
    git(
        f._tmp.path(),
        &[
            "clone",
            "--quiet",
            f.upstream.to_str().unwrap(),
            other.to_str().unwrap(),
        ],
    );
    let second = sync(&f.env, other_repo, None).unwrap();
    assert_eq!(first.commit, second.commit);
    assert_ne!(first.root, second.root);
    assert!(store::published(&f.env, &key_for(&f.env), &first.commit).is_some());
    write_skill(&second.root, "tampered");
    let key = store::repo_key(&clone_url(&f.env, other_repo));
    assert!(store::published(&f.env, &key, &second.commit).is_none());
}
