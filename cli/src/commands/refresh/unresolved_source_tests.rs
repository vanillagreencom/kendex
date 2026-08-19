//! What `refresh` reports for an item whose recorded source produced nothing.
//!
//! The cause has to be the true one — a refused source and a source that was
//! never cloned are repaired differently — and no unresolved source may be
//! quietly substituted by another, which is how an item ends up refreshed from
//! a tree it was never installed from.

use super::*;
use crate::commands::refresh::tests::{
    git_ok, init_repo_with_commit, lock_entry, make_source, tmpdir, write_colliding_source,
};
use crate::config::{InstallMethod, LockEntry, LockFile};

/// The single-source fallback must not silently reinstall an entry from a
/// source it was never installed from — it reports missing instead.
#[test]
fn refresh_reports_missing_when_the_recorded_source_is_not_loaded() {
    let root = tmpdir("unloaded-source");
    let project = root.join("project");
    let loaded = make_source(&root, "loaded");
    let alternate = root.join(".agents");
    std::fs::create_dir_all(alternate.join("skills/shared")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    write_colliding_source(&loaded, "1", "PreToolUse", "source-model");

    let mut lock = LockFile::default();
    lock.add(lock_entry(
        "shared",
        ItemKind::Skill,
        &alternate,
        vec!["claude-code"],
    ));
    let sources = vec![RefreshSource::from_root(&loaded)];

    let stats = crate::test_util::with_project_root(&project, || {
        let mut project_config = ProjectConfig::default();
        refresh_items_in_scope(
            false,
            &lock,
            &sources,
            &mut project_config,
            &project,
            None,
            &Default::default(),
        )
    });

    assert_eq!(stats.skills_refreshed, 0);
    assert_eq!(
        stats.missing.get("shared").map(String::as_str),
        Some(
            format!(
                "source not found: {p} — run `vstack add {p}`",
                p = alternate.display()
            )
            .as_str()
        )
    );
    assert!(
        !project.join(".claude/skills/shared/SKILL.md").exists(),
        "must not install from a source the entry was never installed from"
    );

    let _ = std::fs::remove_dir_all(root);
}

/// A recorded source that vanished is not a legacy placeholder: with exactly
/// one other source loaded that carries a same-named asset, the entry must be
/// reported missing (naming the vanished source), never refreshed from the
/// unrelated source — that would silently replace the real asset.
#[test]
fn refresh_reports_missing_instead_of_rebinding_a_vanished_source() {
    let root = tmpdir("vanished-source");
    let project = root.join("project");
    let loaded = make_source(&root, "loaded");
    let gone = root.join("gone");
    std::fs::create_dir_all(&project).unwrap();
    write_colliding_source(&loaded, "1", "PreToolUse", "source-model");

    let mut lock = LockFile::default();
    lock.add(lock_entry(
        "shared",
        ItemKind::Skill,
        &gone,
        vec!["claude-code"],
    ));
    let sources = vec![RefreshSource::from_root(&loaded)];

    let stats = crate::test_util::with_project_root(&project, || {
        let mut project_config = ProjectConfig::default();
        refresh_items_in_scope(
            false,
            &lock,
            &sources,
            &mut project_config,
            &project,
            None,
            &Default::default(),
        )
    });

    assert_eq!(stats.skills_refreshed, 0);
    assert!(!stats.successful_items.contains("shared"));
    assert_eq!(
        stats.missing.get("shared").map(String::as_str),
        Some(
            format!(
                "source not found: {p} — run `vstack add {p}`",
                p = gone.display()
            )
            .as_str()
        )
    );
    assert!(
        !project.join(".claude/skills/shared/SKILL.md").exists(),
        "must not install the same-named asset from a source the entry was never installed from"
    );

    let _ = std::fs::remove_dir_all(root);
}

/// A refused remote cache is a source that exists. The entry it backs is
/// reported as not refreshed with the refusal as its reason, is never
/// reinstalled from another loaded source, keeps its recorded source, and the
/// run exits non-zero.
#[test]
fn refresh_reports_a_refused_remote_cache_instead_of_substituting_another_source() {
    let root = tmpdir("refused-remote-cache");
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let home = root.join("home");
    let cache_root = home.join(".vstack").join("cache");

    // The remote's cache entry: a real clone whose `core.worktree` names a
    // victim directory holding a same-named tracked file.
    let origin = root.join("origin");
    std::fs::create_dir_all(origin.join("skills/demo")).unwrap();
    std::fs::write(
        origin.join("skills/demo/SKILL.md"),
        "---\nname: demo\ndescription: Remote demo\n---\n# Demo\n\nRemote body.\n",
    )
    .unwrap();
    assert!(init_repo_with_commit(&origin));
    let victim = root.join("victim");
    std::fs::create_dir_all(&victim).unwrap();
    std::fs::write(victim.join(".vstack-test-base"), "precious\n").unwrap();
    let cache = crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        crate::refresh_sources::RemoteSource::parse("owner/repo")
            .unwrap()
            .unwrap()
            .cache_dir
    });
    std::fs::create_dir_all(&cache_root).unwrap();
    // Cloned from the local origin, then pointed at the URL the recorded
    // source derives, as a clone made by `vstack add owner/repo` would be.
    assert!(git_ok(
        &cache_root,
        &[
            "clone",
            "-q",
            origin.to_str().unwrap(),
            cache.to_str().unwrap()
        ]
    ));
    assert!(git_ok(
        &cache,
        &[
            "remote",
            "set-url",
            "origin",
            "https://github.com/owner/repo.git"
        ]
    ));
    assert!(git_ok(
        &cache,
        &["config", "core.worktree", victim.to_str().unwrap()]
    ));

    // A local source carrying a same-named skill, plus one of its own.
    let local = root.join("local");
    for name in ["demo", "other"] {
        std::fs::create_dir_all(local.join("skills").join(name)).unwrap();
        std::fs::write(
            local.join("skills").join(name).join("SKILL.md"),
            format!("---\nname: {name}\ndescription: Local {name}\n---\n# {name}\n\nLocal body.\n"),
        )
        .unwrap();
    }

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "demo".into(),
        kind: ItemKind::Skill,
        source: "owner/repo".into(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.add(lock_entry(
        "other",
        ItemKind::Skill,
        &local,
        vec!["claude-code"],
    ));
    lock.save(&project.join(".vstack-lock.json")).unwrap();
    // Both are installed already (a lock entry with no files is pruned).
    let installed_demo =
        "---\nname: demo\ndescription: Installed demo\n---\n# Demo\n\nInstalled body.\n";
    for name in ["demo", "other"] {
        for root in [".agents/skills", ".claude/skills"] {
            let dir = project.join(root).join(name);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("SKILL.md"), installed_demo).unwrap();
        }
    }

    let err = crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        crate::test_util::with_project_root(&project, || {
            let err = run(crate::scope::ScopeFilter::Project, false).unwrap_err();

            // The reason the user is shown for this item, not just the run's
            // exit: "source not found" would name the wrong cause and send
            // them to re-add a source that is present.
            let lock = LockFile::load(&project.join(".vstack-lock.json")).unwrap();
            let records = crate::refresh_sources::resolve_source_records(&lock);
            let sources = crate::refresh_sources::load_refresh_sources(&records.sources);
            let mut project_config = ProjectConfig::default();
            let stats = refresh_items_in_scope(
                false,
                &lock,
                &sources,
                &mut project_config,
                &project,
                None,
                &records.refused,
            );
            assert!(
                stats.missing["demo"].contains("does not resolve to its cache entry"),
                "{:?}",
                stats.missing
            );
            // Control: an entry whose source carries nothing still reads as
            // absent, so the assertion above is about the refusal and not
            // about every missing item carrying the same text.
            let empty = root.join("empty-source");
            std::fs::create_dir_all(&empty).unwrap();
            let mut gone = LockFile::default();
            gone.add(lock_entry(
                "demo",
                ItemKind::Skill,
                &empty,
                vec!["claude-code"],
            ));
            let absent = refresh_items_in_scope(
                false,
                &gone,
                &sources,
                &mut project_config,
                &project,
                None,
                &records.refused,
            );
            assert_eq!(
                absent.missing["demo"],
                format!(
                    "source not found: {p} — run `vstack add {p}`",
                    p = empty.display()
                )
            );
            err
        })
    });

    let message = format!("{err:#}");
    assert!(message.contains("missing from their source"), "{message}");
    for root in [".agents/skills", ".claude/skills"] {
        assert_eq!(
            std::fs::read_to_string(project.join(root).join("demo/SKILL.md")).unwrap(),
            installed_demo,
            "the refused entry must not be reinstalled from the local source ({root})"
        );
    }
    assert!(
        std::fs::read_to_string(project.join(".claude/skills/other/SKILL.md"))
            .unwrap()
            .contains("Local body."),
        "the local entry still refreshes"
    );
    let saved = LockFile::load(&project.join(".vstack-lock.json")).unwrap();
    assert_eq!(
        saved.entries["demo"].source, "owner/repo",
        "the refused entry keeps its recorded source"
    );
    assert_eq!(
        std::fs::read_to_string(victim.join(".vstack-test-base")).unwrap(),
        "precious\n",
        "the redirected worktree must be untouched"
    );

    let _ = std::fs::remove_dir_all(root);
}

/// The same contract on `refresh`'s side: the remedy it prints for a global
/// entry has to repair the global scope. `RefreshStats` carries the scope it
/// ran in for exactly this, because the reason is built well below the layer
/// that knows one.
#[test]
fn a_global_refreshs_missing_reason_carries_the_global_flag() {
    let entry = lock_entry(
        "rust",
        ItemKind::Agent,
        Path::new("/no/such/dir/plain"),
        vec!["codex"],
    );
    let mut global = RefreshStats {
        global: true,
        ..RefreshStats::default()
    };
    global.mark_source_missing("rust", &entry);
    let reason = global.missing.get("rust").expect("marked missing");
    assert!(
        reason.contains("`vstack add -g /no/such/dir/plain`"),
        "{reason}"
    );

    // Control: the project scope prints the same command without the flag.
    let mut project = RefreshStats::default();
    project.mark_source_missing("rust", &entry);
    let reason = project.missing.get("rust").expect("marked missing");
    assert!(
        reason.contains("`vstack add /no/such/dir/plain`"),
        "{reason}"
    );
    assert!(!reason.contains(" -g "), "{reason}");
}
