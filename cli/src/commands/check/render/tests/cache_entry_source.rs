//! Rendering a scope whose lock source is a PATH into vstack's own cache. The
//! entries are verified through the remote that entry clones, and when that
//! remote cannot be established they are reported unverifiable rather than
//! counted clean against bytes nothing will ever fetch.

use super::*;

/// A lock source recorded as a PATH into vstack's own cache is verified
/// through the remote that entry clones. When that remote cannot be
/// established the entries are unverifiable and named — never counted clean
/// against bytes nothing will ever fetch, which is the whole of the silent
/// under-propagation this closes.
#[test]
fn a_cache_entry_recorded_as_a_path_is_verified_through_its_remote() {
    with_sandbox("cache-path-source", |project, _source| {
        let cache = clone_at_cache_key("owner/repo", "https://github.com/owner/repo.git");
        write_skill(&cache, "alpha", "one");
        install_skill_on_disk(project, "alpha");
        let locked_entry = |cache: &std::path::Path| {
            let mut lock = LockFile::default();
            // The recorded source is the cache DIRECTORY, which is what
            // `vstack add ~/.vstack/cache/<entry>` writes.
            let mut entry = locked(cache, ItemKind::Skill, "alpha");
            entry.source_hash = config::compute_source_hash(&entry);
            lock.add(entry);
            lock
        };

        // Control: an entry whose origin IS a usable remote verifies exactly
        // as it always did. Without this the refusal below could come from the
        // fixture rather than from the origin under test.
        let clean = check_scope(false, &locked_entry(&cache), CheckOptions::default()).unwrap();
        assert!(clean.source_issues.is_empty(), "{clean:?}");
        assert!(!clean.has_drift(), "{clean:?}");
        let mut clean_out = String::new();
        render_scope(&mut clean_out, &clean, false);
        // The exact wording the refused render below must NOT carry — pinned
        // here so that negative assertion cannot pass on a typo.
        assert!(clean_out.contains("✓ alpha"), "{clean_out}");

        // The same entry, with an origin that names no remote vstack can
        // fetch: its bytes are no longer evidence of anything.
        let git = |args: &[&str]| {
            let output = crate::refresh_sources::hardened_git_command(&cache)
                .args(args)
                .output()
                .unwrap();
            assert!(output.status.success(), "git {args:?} failed");
        };
        git(&["remote", "set-url", "origin", "/somewhere/local"]);

        let report = check_scope(false, &locked_entry(&cache), CheckOptions::default()).unwrap();
        assert_eq!(report.source_issues.len(), 1, "{report:?}");
        assert!(
            matches!(
                &report.source_issues[0].problem,
                SourceProblem::Unverifiable { entries, reason, .. }
                    if entries == &vec!["alpha".to_string()]
                        && reason.contains(&cache.to_string_lossy().into_owned())
                        && reason.contains("is not a remote vstack can fetch")
            ),
            "{report:?}"
        );
        assert!(report.has_drift(), "an unverifiable source is never clean");

        let mut out = String::new();
        render_scope(&mut out, &report, false);
        assert!(out.contains("cannot be verified"), "{out}");
        assert!(out.contains("is not a remote vstack can fetch"), "{out}");
        assert!(
            !out.contains("✓ alpha"),
            "the entry must never appear as clean: {out}"
        );
    });
}

/// The same, one directory deeper: `<cache>/<entry>/<subdir>`, which is what
/// `vstack add <cache>/<entry>/sub` writes for a repository whose catalog is
/// nested. Under parent-equality membership this shape took the ordinary
/// local-directory branch and reproduced #1495 verbatim — a green tick over a
/// tree nothing fetched.
///
/// It is VERIFIED rather than refused. A subdirectory has no remote-plus-path
/// spelling, which is why it is never migrated onto a remote spec — but
/// resolution needs a directory and a freshness mechanism, not a string, and
/// both exist: the entry's own fetch keeps the whole subtree current, and the
/// recorded path names the subdirectory inside it unambiguously. Refusing it
/// would fail closed on a state that is now provably verifiable, and would
/// turn a working install into exit 1 whose only remedy is re-adding from a
/// different source.
///
/// Fail-closed still reaches it: an unverifiable ENTRY makes every source
/// inside it unverifiable, named by its own recorded path.
#[test]
fn a_path_below_a_cache_entry_is_verified_through_that_entry() {
    with_sandbox("cache-subpath-source", |project, _source| {
        let cache = clone_at_cache_key("owner/repo", "https://github.com/owner/repo.git");
        let nested = cache.join("nested");
        std::fs::create_dir_all(&nested).unwrap();
        write_skill(&nested, "alpha", "one");
        install_skill_on_disk(project, "alpha");
        let locked_entry = || {
            let mut lock = LockFile::default();
            let mut entry = locked(&nested, ItemKind::Skill, "alpha");
            entry.source_hash = config::compute_source_hash(&entry);
            lock.add(entry);
            lock
        };

        // Verified, and clean: the subdirectory resolves inside the tree its
        // entry's fetch left behind.
        let clean = check_scope(false, &locked_entry(), CheckOptions::default()).unwrap();
        assert!(clean.source_issues.is_empty(), "{clean:?}");
        assert!(!clean.has_drift(), "{clean:?}");
        let mut clean_out = String::new();
        render_scope(&mut clean_out, &clean, false);
        assert!(clean_out.contains("✓ alpha"), "{clean_out}");

        // The entry's remote can no longer be established, so nothing inside
        // it can be verified either — reported against the path the lock
        // actually records.
        let git = |args: &[&str]| {
            let output = crate::refresh_sources::hardened_git_command(&cache)
                .args(args)
                .output()
                .unwrap();
            assert!(output.status.success(), "git {args:?} failed");
        };
        git(&["remote", "set-url", "origin", "/somewhere/local"]);

        let report = check_scope(false, &locked_entry(), CheckOptions::default()).unwrap();
        assert_eq!(report.source_issues.len(), 1, "{report:?}");
        assert!(
            matches!(
                &report.source_issues[0].problem,
                SourceProblem::Unverifiable { entries, reason, .. }
                    if entries == &vec!["alpha".to_string()]
                        && reason.contains(&cache.to_string_lossy().into_owned())
                        && reason.contains("is not a remote vstack can fetch")
            ),
            "{report:?}"
        );
        assert_eq!(
            report.source_issues[0].source,
            nested.to_string_lossy(),
            "the issue is filed against the source the lock records"
        );
        assert!(report.has_drift(), "an unverifiable source is never clean");

        let mut out = String::new();
        render_scope(&mut out, &report, false);
        assert!(out.contains("cannot be verified"), "{out}");
        assert!(
            !out.contains("✓ alpha"),
            "the entry must never appear as clean: {out}"
        );
    });
}

/// A vanished cache entry. Under the same-tree migration rule a legacy-key
/// source keeps its cache path in the lock permanently, so a wiped cache is
/// the durable steady state for exactly the population this defect was found
/// on — and the report used to answer it with ``run `vstack add <that path>` ``,
/// which cannot work: there is nothing at the path to read. The remedy comes
/// from the identity the lock still records instead.
#[test]
fn a_vanished_cache_entry_is_restored_from_the_identity_the_lock_records() {
    with_sandbox("cache-path-vanished", |project, _source| {
        let cache = clone_at_cache_key("owner/repo", "https://github.com/owner/repo.git");
        install_skill_on_disk(project, "alpha");
        let locked_entry = |source_repo: Option<&str>| {
            let mut lock = LockFile::default();
            let mut entry = locked(&cache, ItemKind::Skill, "alpha");
            entry.source_repo = source_repo.map(str::to_string);
            lock.add(entry);
            lock
        };
        // Gone: cache wipe, new machine, dotfile restore.
        std::fs::remove_dir_all(&cache).unwrap();

        let report = check_scope(
            false,
            &locked_entry(Some("owner/repo")),
            CheckOptions::default(),
        )
        .unwrap();
        assert_eq!(report.source_issues.len(), 1, "{report:?}");
        assert!(
            matches!(
                &report.source_issues[0].problem,
                SourceProblem::Unresolvable { restore, .. } if restore.as_deref() == Some("owner/repo")
            ),
            "{report:?}"
        );
        let mut out = String::new();
        render_scope(&mut out, &report, false);
        assert!(out.contains("`vstack add owner/repo`"), "{out}");
        assert!(
            !out.contains(&format!("vstack add {}", cache.display())),
            "the dead path must never be prescribed: {out}"
        );

        // No identity recorded: no `add` is offered at all, rather than one
        // that cannot succeed.
        let report = check_scope(false, &locked_entry(None), CheckOptions::default()).unwrap();
        assert!(
            matches!(
                &report.source_issues[0].problem,
                SourceProblem::Unresolvable { restore, .. } if restore.is_none()
            ),
            "{report:?}"
        );
        let mut out = String::new();
        render_scope(&mut out, &report, false);
        assert!(out.contains("nothing recorded can restore it"), "{out}");
        assert!(
            !out.contains(&format!("vstack add {}", cache.display())),
            "the dead path must never be prescribed: {out}"
        );

        // Control: an ordinary source that vanishes IS restored by re-adding
        // itself, so the rule is keyed on the cache root and nothing else.
        let elsewhere = project.join("gone-source");
        let mut lock = LockFile::default();
        lock.add(locked(&elsewhere, ItemKind::Skill, "alpha"));
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        let mut out = String::new();
        render_scope(&mut out, &report, false);
        assert!(
            out.contains(&format!("`vstack add {}`", elsewhere.display())),
            "{out}"
        );
    });
}

/// A wiped cache entry beneath which the lock recorded a SUBDIRECTORY. The
/// recorded identity names the repository, not the directory inside it, so
/// offering it would install the repository ROOT over the subtree the lock
/// chose — failing outright when the root carries no catalog, and worse when
/// it carries a same-named item: exit 0, `source` rewritten to the repository,
/// check green, and the item now propagating from a subtree the user never
/// chose. No command is offered instead.
#[test]
fn a_wiped_subpath_source_is_never_offered_its_repository_identity() {
    with_sandbox("cache-subpath-vanished", |project, _source| {
        let cache = clone_at_cache_key("owner/repo", "https://github.com/owner/repo.git");
        let nested = cache.join("nested");
        install_skill_on_disk(project, "alpha");
        let locked_at = |source: &std::path::Path| {
            let mut lock = LockFile::default();
            let mut entry = locked(source, ItemKind::Skill, "alpha");
            entry.source_repo = Some("owner/repo".into());
            lock.add(entry);
            lock
        };
        std::fs::remove_dir_all(&cache).unwrap();

        let report = check_scope(false, &locked_at(&nested), CheckOptions::default()).unwrap();
        assert!(
            matches!(
                &report.source_issues[0].problem,
                SourceProblem::Unresolvable { restore, .. } if restore.is_none()
            ),
            "{report:?}"
        );
        let mut out = String::new();
        render_scope(&mut out, &report, false);
        assert!(
            !out.contains("vstack add owner/repo"),
            "a repository identity cannot restore a directory inside it: {out}"
        );
        assert!(
            !out.contains(&format!("vstack add {}", nested.display())),
            "and the dead path is no remedy either: {out}"
        );
        // The reader is told WHY the identity their lock plainly records was
        // not offered.
        assert!(
            out.contains("which no repository identity restores"),
            "{out}"
        );
        assert!(
            !out.contains("vstack add"),
            "the no-remedy line must offer no `vstack add` shape at all: {out}"
        );
        assert!(report.has_drift());

        // Control: the same identity, the same wiped entry, but the lock
        // recorded the ENTRY — where the identity does restore it. Only the
        // subpath changes the answer.
        let report = check_scope(false, &locked_at(&cache), CheckOptions::default()).unwrap();
        let mut out = String::new();
        render_scope(&mut out, &report, false);
        assert!(out.contains("`vstack add owner/repo`"), "{out}");
    });
}

/// A refusal a re-add provably clears is named. Most refusals are circular —
/// `add` asks the same questions and reaches the same answer — but a cache
/// entry that redirects elsewhere still yields a remote, and `add` given that
/// path installs from the remote's OWN entry instead. That was the one state
/// the report stayed silent about, leaving a permanent exit 1 under a refusal
/// whose own text says to remove the entry, which is not what fixes it.
#[test]
fn a_refusal_a_re_add_clears_names_the_command_that_clears_it() {
    with_sandbox("cache-refused-remedy", |project, _source| {
        // A legacy-key entry whose `.git` is a file redirect: refused, but its
        // origin still reads, and its remote's own entry is a different
        // directory.
        let real = clone_at_cache_key("owner/repo", "https://github.com/owner/repo.git");
        let legacy = crate::refresh_sources::remote_cache_root().join("legacy_key");
        std::fs::create_dir_all(&legacy).unwrap();
        std::fs::write(
            legacy.join(".git"),
            format!("gitdir: {}\n", real.join(".git").display()),
        )
        .unwrap();
        install_skill_on_disk(project, "alpha");
        let mut lock = LockFile::default();
        lock.add(locked(&legacy, ItemKind::Skill, "alpha"));

        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        let restore = match &report.source_issues[0].problem {
            SourceProblem::Unverifiable { restore, .. } => restore.clone(),
            other => panic!("expected a refusal, got {other:?}"),
        };
        assert_eq!(
            restore.as_deref(),
            Some(legacy.to_string_lossy().as_ref()),
            "re-adding this path installs from the remote's own entry"
        );
        let mut out = String::new();
        render_scope(&mut out, &report, false);
        assert!(out.contains("cannot be verified"), "{out}");
        assert!(
            out.contains(&format!("`vstack add {}`", legacy.display())),
            "{out}"
        );

        // Control: an entry whose origin cannot be established at all has no
        // one-command repair, and none is invented for it.
        let dead = crate::refresh_sources::remote_cache_root().join("dead_key");
        std::fs::create_dir_all(dead.join(".git")).unwrap();
        let mut lock = LockFile::default();
        lock.add(locked(&dead, ItemKind::Skill, "alpha"));
        let report = check_scope(false, &lock, CheckOptions::default()).unwrap();
        assert!(
            matches!(
                &report.source_issues[0].problem,
                SourceProblem::Unverifiable { restore, .. } if restore.is_none()
            ),
            "{report:?}"
        );
        let mut out = String::new();
        render_scope(&mut out, &report, false);
        assert!(!out.contains("vstack add"), "no remedy is invented: {out}");
    });
}
