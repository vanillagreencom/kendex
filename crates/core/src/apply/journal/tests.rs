use super::*;

/// The filtered restore is what keeps a refused apply from destroying
/// the very bytes the refusal protected: a path whose op never ran
/// keeps whatever a writer outside the transaction put there after the
/// journal was taken.
#[test]
fn a_filtered_rollback_leaves_unmutated_paths_as_the_world_left_them() {
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("work");
    fs::create_dir_all(&work).unwrap();
    let a = work.join("a.md");
    let b = work.join("kendex.toml");
    fs::write(&a, "a0").unwrap();
    fs::write(&b, "b0").unwrap();

    let journal_dir = tmp.path().join("journal/global");
    write(&journal_dir, &[a.clone(), b.clone()]).unwrap();
    // The transaction mutates `a`; a writer outside it lands on `b`
    // before `b`'s own op refuses its precondition.
    fs::write(&a, "a1").unwrap();
    fs::write(&b, "external edit").unwrap();

    rollback_mutated(&journal_dir, std::slice::from_ref(&a)).unwrap();

    assert_eq!(fs::read_to_string(&a).unwrap(), "a0");
    assert_eq!(fs::read_to_string(&b).unwrap(), "external edit");
    assert!(!pending(&journal_dir));
}

/// A crash mid filtered restore must not widen the restore set: the
/// filter was persisted before the first path was touched, recovery
/// re-runs exactly it, and the external bytes it left alone survive
/// the second pass too.
#[test]
fn crash_recovery_honors_the_persisted_restore_filter() {
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("work");
    fs::create_dir_all(&work).unwrap();
    let a = work.join("a.md");
    let b = work.join("kendex.toml");
    fs::write(&a, "a0").unwrap();
    fs::write(&b, "b0").unwrap();

    let journal_dir = tmp.path().join("journal/global");
    write(&journal_dir, &[a.clone(), b.clone()]).unwrap();
    fs::write(&a, "a1").unwrap();
    fs::write(&b, "external edit").unwrap();
    // The filtered restore persisted its set, then the process died
    // before restoring anything: the journal is still pending.
    persist_restore_set(&journal_dir, std::slice::from_ref(&a)).unwrap();
    assert!(pending(&journal_dir));

    rollback(&journal_dir).unwrap();

    assert_eq!(fs::read_to_string(&a).unwrap(), "a0");
    assert_eq!(fs::read_to_string(&b).unwrap(), "external edit");
    assert!(!pending(&journal_dir));
}

/// The persisted set guards a crash; it must never gate the restore.
/// With the persist failing (a directory squatting on its path forces
/// the atomic rename to fail), the filtered restore still runs and
/// clears the journal — skipping it would hand recovery an unfiltered
/// full restore over the external bytes.
#[test]
fn a_failed_restore_set_persist_does_not_skip_the_filtered_restore() {
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("work");
    fs::create_dir_all(&work).unwrap();
    let a = work.join("a.md");
    let b = work.join("kendex.toml");
    fs::write(&a, "a0").unwrap();
    fs::write(&b, "b0").unwrap();

    let journal_dir = tmp.path().join("journal/global");
    write(&journal_dir, &[a.clone(), b.clone()]).unwrap();
    fs::write(&a, "a1").unwrap();
    fs::write(&b, "external edit").unwrap();
    fs::create_dir(restore_set_path(&journal_dir)).unwrap();

    rollback_mutated(&journal_dir, std::slice::from_ref(&a)).unwrap();

    assert_eq!(fs::read_to_string(&a).unwrap(), "a0");
    assert_eq!(fs::read_to_string(&b).unwrap(), "external edit");
    assert!(!pending(&journal_dir));
}

/// A restore set that exists but does not parse is outside
/// interference over a file the atomic write cannot tear. Falling back
/// to the full restore would destroy the bytes the filter protects, so
/// recovery refuses loudly and the journal stays pending.
#[test]
fn a_corrupt_restore_set_refuses_recovery_instead_of_widening_it() {
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("work");
    fs::create_dir_all(&work).unwrap();
    let b = work.join("kendex.toml");
    fs::write(&b, "b0").unwrap();

    let journal_dir = tmp.path().join("journal/global");
    write(&journal_dir, std::slice::from_ref(&b)).unwrap();
    fs::write(&b, "external edit").unwrap();
    fs::write(restore_set_path(&journal_dir), "not json").unwrap();

    let error = rollback(&journal_dir).unwrap_err();
    assert!(matches!(error, CoreError::JsonParse { .. }), "{error:?}");
    assert_eq!(fs::read_to_string(&b).unwrap(), "external edit");
    assert!(pending(&journal_dir));
}

/// A restore that fails midway leaves the persisted filter behind for
/// recovery: the set goes down before the first path is touched, so
/// the re-run restores the same paths and no more.
#[test]
fn a_restore_failing_midway_leaves_the_filter_for_recovery() {
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("work");
    fs::create_dir_all(&work).unwrap();
    let a = work.join("a.md");
    let b = work.join("kendex.toml");
    fs::write(&a, "a0").unwrap();
    fs::write(&b, "b0").unwrap();

    let journal_dir = tmp.path().join("journal/global");
    write(&journal_dir, &[a.clone(), b.clone()]).unwrap();
    fs::write(&a, "a1").unwrap();
    fs::write(&b, "external edit").unwrap();
    // The pre-image slot for `a` is gone, so its copy-back fails after
    // the filter was persisted and `a` was already removed.
    let slot = journal_dir.join("store/0");
    fs::remove_file(&slot).unwrap();

    rollback_mutated(&journal_dir, std::slice::from_ref(&a)).unwrap_err();
    assert!(restore_set_path(&journal_dir).is_file());
    assert!(pending(&journal_dir));

    // With the slot repaired, recovery re-runs the persisted filter:
    // `a` comes back, and the external bytes at `b` still stand.
    fs::write(&slot, "a0").unwrap();
    rollback(&journal_dir).unwrap();
    assert_eq!(fs::read_to_string(&a).unwrap(), "a0");
    assert_eq!(fs::read_to_string(&b).unwrap(), "external edit");
    assert!(!pending(&journal_dir));
}

/// Both halves failing is the one path that reaches an unfiltered
/// recovery, and the error says so with both failures in it: the restore
/// error alone would read as a retry of the same filtered restore.
#[test]
fn a_restore_failing_with_its_set_unsaved_names_both_failures() {
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("work");
    fs::create_dir_all(&work).unwrap();
    let a = work.join("a.md");
    fs::write(&a, "a0").unwrap();

    let journal_dir = tmp.path().join("journal/global");
    write(&journal_dir, std::slice::from_ref(&a)).unwrap();
    fs::write(&a, "a1").unwrap();
    fs::create_dir(restore_set_path(&journal_dir)).unwrap();
    fs::remove_file(journal_dir.join("store/0")).unwrap();

    let error = rollback_mutated(&journal_dir, std::slice::from_ref(&a)).unwrap_err();
    assert!(
        matches!(&error, CoreError::RestoreSetLost { restore, persist }
            if matches!(**restore, CoreError::Io { .. })
                && matches!(**persist, CoreError::Io { .. })),
        "{error:?}"
    );
    assert!(pending(&journal_dir));
}

/// With meta.json gone the dir is a leftover, not a journal: recovery
/// reads it as non-pending and sweeps it instead of replaying it.
#[test]
fn a_journal_without_meta_is_not_pending_and_is_swept() {
    let tmp = tempfile::tempdir().unwrap();
    let a = tmp.path().join("work/a.md");
    fs::create_dir_all(a.parent().unwrap()).unwrap();
    fs::write(&a, "a0").unwrap();
    let journal_dir = tmp.path().join("journal/global");
    write(&journal_dir, std::slice::from_ref(&a)).unwrap();
    persist_restore_set(&journal_dir, std::slice::from_ref(&a)).unwrap();
    fs::write(&a, "a1").unwrap();

    fs::remove_file(journal_dir.join("meta.json")).unwrap();
    assert!(!pending(&journal_dir));
    clear(&journal_dir).unwrap();
    assert!(!journal_dir.exists());
    assert_eq!(fs::read_to_string(&a).unwrap(), "a1");
}

/// `clear` takes meta.json down before anything else: a sweep that dies
/// midway leaves a leftover the next pass finishes, never a pending
/// journal whose restore set already went. Pinned by a sweep that cannot
/// finish — a subdirectory nothing may unlink from — after which meta is
/// gone and the journal reads as non-pending.
#[cfg(unix)]
#[test]
fn clear_takes_meta_down_before_the_sweep() {
    use std::os::unix::fs::PermissionsExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let a = tmp.path().join("work/a.md");
    fs::create_dir_all(a.parent().unwrap()).unwrap();
    fs::write(&a, "a0").unwrap();
    let journal_dir = tmp.path().join("journal/global");
    write(&journal_dir, std::slice::from_ref(&a)).unwrap();
    persist_restore_set(&journal_dir, std::slice::from_ref(&a)).unwrap();

    let locked = journal_dir.join("store/locked");
    fs::create_dir(&locked).unwrap();
    fs::write(locked.join("held"), "").unwrap();
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o500)).unwrap();
    let unlock = || fs::set_permissions(&locked, fs::Permissions::from_mode(0o700)).unwrap();
    if fs::write(locked.join("probe"), "").is_ok() {
        // Permissions do not bind this user (root): the sweep cannot be
        // made to fail here, so the order cannot be observed.
        unlock();
        return;
    }

    let error = clear(&journal_dir).unwrap_err();
    assert!(matches!(error, CoreError::Io { .. }), "{error:?}");
    assert!(!journal_dir.join("meta.json").exists());
    assert!(!pending(&journal_dir));
    unlock();
}

/// A journaled directory root above a mutated path is part of the
/// transaction's footprint: the chain it created comes down with the
/// rollback even though only the leaf is named as mutated.
#[test]
fn a_filtered_rollback_still_removes_the_chain_above_a_mutated_path() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("work/.codex");
    let leaf = root.join("skills/x.md");

    let journal_dir = tmp.path().join("journal/global");
    write(&journal_dir, &[leaf.clone(), root.clone()]).unwrap();
    fs::create_dir_all(leaf.parent().unwrap()).unwrap();
    fs::write(&leaf, "installed").unwrap();

    rollback_mutated(&journal_dir, std::slice::from_ref(&leaf)).unwrap();

    assert!(!root.exists());
}

#[test]
fn rollback_restores_files_dirs_symlinks_and_absence() {
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("work");
    fs::create_dir_all(work.join("tree/sub")).unwrap();
    fs::write(work.join("file.md"), "original").unwrap();
    fs::write(work.join("tree/sub/x"), "x").unwrap();
    make_symlink(Path::new("/nowhere"), &work.join("link")).unwrap();
    let absent = work.join("was-absent");

    let journal_dir = tmp.path().join("journal/global");
    write(
        &journal_dir,
        &[
            work.join("file.md"),
            work.join("tree"),
            work.join("link"),
            absent.clone(),
        ],
    )
    .unwrap();

    fs::write(work.join("file.md"), "clobbered").unwrap();
    fs::remove_dir_all(work.join("tree")).unwrap();
    fs::remove_file(work.join("link")).unwrap();
    fs::write(&absent, "should vanish").unwrap();

    rollback(&journal_dir).unwrap();

    assert_eq!(
        fs::read_to_string(work.join("file.md")).unwrap(),
        "original"
    );
    assert_eq!(fs::read_to_string(work.join("tree/sub/x")).unwrap(), "x");
    assert_eq!(
        fs::read_link(work.join("link")).unwrap(),
        Path::new("/nowhere")
    );
    assert!(!absent.exists());
    assert!(!pending(&journal_dir));
}
