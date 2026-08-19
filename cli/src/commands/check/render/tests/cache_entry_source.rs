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
                SourceProblem::Unverifiable { entries, reason }
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
                SourceProblem::Unverifiable { entries, reason }
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
