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
    fs::write(&a, "a1").unwrap();

    fs::remove_file(journal_dir.join("meta.json")).unwrap();
    assert!(!pending(&journal_dir));
    clear(&journal_dir).unwrap();
    assert!(!journal_dir.exists());
    assert_eq!(fs::read_to_string(&a).unwrap(), "a1");
}

/// `clear` takes meta.json down before the sweep, so a sweep that cannot
/// finish leaves a leftover rather than a pending journal.
///
/// It runs on the success path of every apply. A pending journal there
/// means the next recovery pass rolls a completed apply back: it removes
/// each path before restoring, and the pre-image it would put back went
/// with the half-taken store.
///
/// Pinned with a journal directory that takes an unlink and refuses to be
/// opened, which is what separates the two orders rather than testing
/// them both. Under the order here the unlink needs no read and goes
/// through, and what stops the run is the `sync_dir_durable` behind it.
/// Under the other order `remove_dir_all` opens the directory before it
/// removes anything, so it would fail having taken nothing, meta.json
/// included, and the journal would still be pending.
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
    // The apply ran: the file holds what it wrote, and its pre-image sits
    // in the journal's store.
    fs::write(&a, "applied").unwrap();

    fs::set_permissions(&journal_dir, fs::Permissions::from_mode(0o300)).unwrap();
    let unlock = || fs::set_permissions(&journal_dir, fs::Permissions::from_mode(0o700)).unwrap();
    if fs::File::open(&journal_dir).is_ok() {
        // Permissions do not bind this user (root): the sweep cannot be
        // made to fail here, so the order cannot be observed.
        unlock();
        return;
    }

    // Captured before the mode goes back, so a `clear` that unexpectedly
    // succeeds cannot panic with the directory still sealed and leave the
    // temp dir unable to clean up after itself.
    let outcome = clear(&journal_dir);
    unlock();
    let error = outcome.unwrap_err();
    assert!(matches!(error, CoreError::Io { .. }), "{error:?}");
    assert!(!journal_dir.join("meta.json").exists());
    assert!(!pending(&journal_dir), "a spent journal is not pending");

    // What a later recovery pass makes of what is left: nothing to roll
    // back, so the completed apply stands.
    let _ = rollback(&journal_dir);
    assert_eq!(
        fs::read_to_string(&a).unwrap(),
        "applied",
        "the completed apply was not rolled back"
    );
}

/// A directory holding a link back into itself journals and restores:
/// the snapshot copies the link as a link, and syncing the copy treats it
/// as a leaf instead of walking the same directory through it again.
#[cfg(unix)]
#[test]
fn a_dir_linking_to_itself_journals_and_restores() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("work/skill");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), "v1").unwrap();
    std::os::unix::fs::symlink(".", dir.join("loop")).unwrap();

    let journal_dir = tmp.path().join("journal/global");
    write(&journal_dir, std::slice::from_ref(&dir)).unwrap();
    fs::write(dir.join("SKILL.md"), "v2").unwrap();
    fs::remove_file(dir.join("loop")).unwrap();

    rollback(&journal_dir).unwrap();
    assert_eq!(fs::read_to_string(dir.join("SKILL.md")).unwrap(), "v1");
    assert!(dir.join("loop").is_symlink());
    assert_eq!(fs::read_link(dir.join("loop")).unwrap().as_os_str(), ".");
    assert!(!pending(&journal_dir));
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
