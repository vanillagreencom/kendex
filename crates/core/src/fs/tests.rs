use super::*;

/// A link is a leaf of the tree it sits in: its parent's sync persists
/// the entry, and nothing on the far side is this tree's to touch.
/// Pinned with a link to a directory outside the tree holding a file
/// nobody may open — followed, the sync would fail on it.
#[cfg(unix)]
#[test]
fn sync_tree_never_follows_a_link() {
    use std::os::unix::fs::PermissionsExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let outside = tmp.path().join("outside");
    fs::create_dir_all(&outside).unwrap();
    let sealed = outside.join("sealed");
    fs::write(&sealed, "x").unwrap();
    fs::set_permissions(&sealed, fs::Permissions::from_mode(0o000)).unwrap();
    let unlock = || fs::set_permissions(&sealed, fs::Permissions::from_mode(0o600)).unwrap();
    if fs::File::open(&sealed).is_ok() {
        // Permissions do not bind this user (root): following the link
        // cannot be made to fail here.
        unlock();
        return;
    }
    let tree = tmp.path().join("tree");
    fs::create_dir_all(&tree).unwrap();
    fs::write(tree.join("a"), "a").unwrap();
    std::os::unix::fs::symlink(&outside, tree.join("out")).unwrap();
    std::os::unix::fs::symlink(".", tree.join("loop")).unwrap();

    let result = sync_tree(&tree);
    unlock();
    result.unwrap();
}

/// The app saves settings from a Tokio thread pool, so a slider drag can
/// put several writes of one file in flight at once. Sharing a temp name
/// made them collide: the loser either failed to rename or wrote its
/// payload over the live file, leaving it half one write and half the
/// other.
#[test]
fn concurrent_writers_of_one_file_all_succeed_and_leave_it_whole() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("settings.toml");
    let bodies: Vec<String> = (0..8)
        .map(|writer| {
            format!(
                "writer = {writer}\npadding = \"{}\"\n",
                "x".repeat(writer * 40)
            )
        })
        .collect();

    for _ in 0..50 {
        std::thread::scope(|scope| {
            for body in &bodies {
                scope.spawn(|| atomic_write(&path, body).expect("every writer succeeds"));
            }
        });
        let written = fs::read_to_string(&path).unwrap();
        assert!(
            bodies.contains(&written),
            "the file is one writer's bytes, not a mixture: {written:?}"
        );
    }
    // Nothing is left behind for the next reader to trip over.
    let leftovers: Vec<_> = fs::read_dir(tmp.path())
        .unwrap()
        .filter_map(|entry| entry.ok().map(|e| e.file_name()))
        .filter(|name| name != "settings.toml")
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
}

/// Renaming onto a directory is the failure this can force; every other
/// one leaves the same debris. Both entry points share the helper, so
/// both are checked.
#[test]
fn a_write_that_cannot_finish_leaves_no_temp_file_behind() {
    let tmp = tempfile::tempdir().unwrap();
    let occupied = tmp.path().join("settings.toml");
    fs::create_dir(&occupied).unwrap();

    for write in [atomic_write, atomic_write_durable] {
        assert!(write(&occupied, "schema = 1\n").is_err());
    }

    let leftovers: Vec<_> = fs::read_dir(tmp.path())
        .unwrap()
        .filter_map(|entry| entry.ok().map(|e| e.file_name()))
        .filter(|name| name != "settings.toml")
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
}

#[cfg(unix)]
#[test]
fn a_symlinked_file_is_rewritten_through_the_link() {
    let tmp = tempfile::tempdir().unwrap();
    let real = tmp.path().join("dotfiles/kendex.toml");
    fs::create_dir_all(real.parent().unwrap()).unwrap();
    fs::write(&real, "old").unwrap();
    let link = tmp.path().join("kendex.toml");
    std::os::unix::fs::symlink(&real, &link).unwrap();

    atomic_write(&link, "new").unwrap();
    atomic_write_durable(&link, "newer").unwrap();

    assert!(link.is_symlink());
    assert_eq!(fs::read_to_string(&real).unwrap(), "newer");
}

#[cfg(unix)]
#[test]
fn an_owned_cache_write_replaces_the_link_not_its_target() {
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("target");
    fs::write(&target, "keep").unwrap();
    let cache = tmp.path().join("cache.json");
    std::os::unix::fs::symlink(&target, &cache).unwrap();

    atomic_write_no_follow(&cache, "cached").unwrap();

    assert!(!cache.is_symlink());
    assert_eq!(fs::read_to_string(cache).unwrap(), "cached");
    assert_eq!(fs::read_to_string(target).unwrap(), "keep");
}

/// What is reproduced of a link is the link. Reading through one would put
/// the tree it points at — bytes another installation still reads — at the
/// destination under this link's name.
#[cfg(unix)]
#[test]
fn a_link_to_a_tree_is_reproduced_as_a_link() {
    let tmp = tempfile::tempdir().unwrap();
    let shared = tmp.path().join("shared");
    fs::create_dir_all(&shared).unwrap();
    fs::write(shared.join("SKILL.md"), "body").unwrap();
    let link = tmp.path().join("link");
    std::os::unix::fs::symlink(&shared, &link).unwrap();
    let dest = tmp.path().join("held");

    copy_any(&link, &dest).unwrap();

    assert!(dest.is_symlink());
    assert_eq!(fs::read_link(&dest).unwrap(), shared);
    assert!(shared.join("SKILL.md").is_file());
}

/// The half-present installation this arm exists for: the link is still
/// there and what it points at is gone. Read through, the copy fails with
/// the target's ENOENT under the link's name.
#[cfg(unix)]
#[test]
fn a_link_whose_target_is_gone_is_still_reproduced() {
    let tmp = tempfile::tempdir().unwrap();
    let link = tmp.path().join("link");
    let gone = tmp.path().join("gone");
    std::os::unix::fs::symlink(&gone, &link).unwrap();
    let dest = tmp.path().join("held");

    copy_any(&link, &dest).unwrap();

    assert!(dest.is_symlink());
    assert_eq!(fs::read_link(&dest).unwrap(), gone);
}

/// A tree and a file are reproduced by their bytes. `copy_any` is called
/// directly, because both sides share a filesystem here and a move would
/// rename them without copying a byte.
#[test]
fn plain_bytes_are_reproduced_by_copy() {
    let tmp = tempfile::tempdir().unwrap();
    let tree = tmp.path().join("tree");
    fs::create_dir_all(tree.join("nested")).unwrap();
    fs::write(tree.join("nested/SKILL.md"), "body").unwrap();
    let file = tmp.path().join("one.md");
    fs::write(&file, "one").unwrap();

    copy_any(&tree, &tmp.path().join("held/tree")).unwrap();
    copy_any(&file, &tmp.path().join("held/one.md")).unwrap();

    assert_eq!(
        fs::read_to_string(tmp.path().join("held/tree/nested/SKILL.md")).unwrap(),
        "body"
    );
    assert_eq!(
        fs::read_to_string(tmp.path().join("held/one.md")).unwrap(),
        "one"
    );
    // Reproduced, not moved: copy_any leaves the original alone.
    assert!(tree.join("nested/SKILL.md").is_file());
    assert!(file.is_file());
}

/// Where rename(2) can do it in one step, that step is the whole move.
#[test]
fn a_move_within_one_filesystem_leaves_nothing_behind() {
    let tmp = tempfile::tempdir().unwrap();
    let file = tmp.path().join("one.md");
    fs::write(&file, "one").unwrap();
    let held = tmp.path().join("held");
    fs::create_dir_all(&held).unwrap();

    move_any(&file, &held.join("one.md")).unwrap();

    assert!(!file.exists());
    assert_eq!(fs::read_to_string(held.join("one.md")).unwrap(), "one");
}

/// A move refused twice names both halves, and the two failures are made
/// different so the message cannot pass by carrying one of them twice:
/// rename crosses a mount and is refused for that, and the copy that
/// follows lands in a directory nothing may write to.
#[cfg(target_os = "linux")]
#[test]
fn a_move_that_fails_twice_names_both_failures() {
    use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
    let tmp = tempfile::tempdir().unwrap();
    let Ok(elsewhere) = tempfile::tempdir_in("/dev/shm") else {
        return;
    };
    let (Ok(here), Ok(there)) = (
        fs::metadata(tmp.path()).map(|m| m.dev()),
        fs::metadata(elsewhere.path()).map(|m| m.dev()),
    ) else {
        return;
    };
    if here == there {
        // One mount, so rename cannot be refused for crossing one.
        return;
    }
    let from = elsewhere.path().join("decider");
    fs::write(&from, "body").unwrap();
    let sealed = tmp.path().join("sealed");
    fs::create_dir_all(&sealed).unwrap();
    fs::set_permissions(&sealed, fs::Permissions::from_mode(0o500)).unwrap();
    let unlock = || fs::set_permissions(&sealed, fs::Permissions::from_mode(0o700)).unwrap();
    if fs::write(sealed.join("probe"), "x").is_ok() {
        // Permissions do not bind this user (root): the copy cannot be
        // made to fail here.
        unlock();
        return;
    }

    let outcome = move_any(&from, &sealed.join("decider"));
    unlock();

    let error = outcome.unwrap_err().to_string();
    assert!(error.contains("os error 18"), "no rename refusal: {error}");
    assert!(error.contains("os error 13"), "no copy failure: {error}");
}
