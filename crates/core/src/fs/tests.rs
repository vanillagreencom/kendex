use super::*;

/// A link is a leaf of the tree it sits in: the durable copy reproduces
/// the link and never reads through it, so nothing on the far side is
/// opened or synced. Pinned with a link to a directory outside the tree
/// holding a file nobody may open, and a link back into the tree —
/// followed, the copy would fail on the first and never end on the
/// second.
#[cfg(unix)]
#[test]
fn a_durable_tree_copy_never_follows_a_link() {
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

    let held = tmp.path().join("held");
    let result = copy_tree_durable(&tree, &held);
    unlock();
    result.unwrap();

    assert!(held.join("out").is_symlink());
    assert!(held.join("loop").is_symlink());
    assert_eq!(fs::read_to_string(held.join("a")).unwrap(), "a");
}

/// A directory whose entries did not reach disk fails the copy instead of
/// passing for a durable one — the journal writes its meta on the
/// strength of this Ok. Pinned with a destination the copy can write into
/// and cannot open for the sync: `sync_dir_durable` opens the directory,
/// which needs read permission, and 0o333 withholds it.
#[cfg(unix)]
#[test]
fn a_durable_tree_copy_reports_a_directory_that_did_not_sync() {
    use std::os::unix::fs::PermissionsExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let source = tmp.path().join("skill");
    fs::create_dir_all(&source).unwrap();
    fs::write(source.join("SKILL.md"), "body").unwrap();
    let held = tmp.path().join("held");
    fs::create_dir_all(&held).unwrap();
    fs::set_permissions(&held, fs::Permissions::from_mode(0o333)).unwrap();
    let unlock = || fs::set_permissions(&held, fs::Permissions::from_mode(0o700)).unwrap();
    if fs::File::open(&held).is_ok() {
        // Permissions do not bind this user (root): the sync cannot be
        // made to fail here.
        unlock();
        return;
    }

    let outcome = copy_tree_durable(&source, &held);
    unlock();

    assert!(outcome.is_err(), "an unsynced directory passed as durable");
    // The bytes did land: what failed is the proof they are on disk, and
    // that is the part the caller must not be told succeeded.
    assert_eq!(fs::read_to_string(held.join("SKILL.md")).unwrap(), "body");
}

/// The mode comes across with the bytes, and a mode that refuses a write
/// handle does not stop the flush: it is relaxed for the flush and put
/// back. This is the one place a Linux run exercises the code Windows
/// always takes, since there every flush needs a write handle — drop the
/// restore and the mode assertion below goes red.
#[test]
fn a_read_only_file_is_copied_durably_and_keeps_its_mode() {
    let tmp = tempfile::tempdir().unwrap();
    let source = tmp.path().join("hook.sh");
    fs::write(&source, "#!/bin/sh\n").unwrap();
    #[cfg(unix)]
    let sealed = {
        use std::os::unix::fs::PermissionsExt as _;
        fs::Permissions::from_mode(0o500)
    };
    #[cfg(not(unix))]
    let sealed = {
        let mut mode = fs::metadata(&source).unwrap().permissions();
        mode.set_readonly(true);
        mode
    };
    fs::set_permissions(&source, sealed).unwrap();
    if fs::OpenOptions::new().write(true).open(&source).is_ok() {
        // Permissions do not bind this user (root): a file that refuses a
        // write handle cannot be set up here.
        return;
    }

    let slot = tmp.path().join("store/0");
    fs::create_dir_all(slot.parent().unwrap()).unwrap();
    copy_file_durable(&source, &slot).unwrap();

    assert_eq!(fs::read_to_string(&slot).unwrap(), "#!/bin/sh\n");
    let kept = fs::metadata(&slot).unwrap().permissions();
    assert!(
        kept.readonly(),
        "the copy is writable, the original was not"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        assert_eq!(
            kept.mode() & 0o777,
            0o500,
            "the execute bit did not come across"
        );
    }
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

/// A pre-image is a copy of somebody's file, so it carries what that file
/// carried. The journal takes one of every path an apply is about to
/// write, and the project's private env file is one of them: a copy made
/// by reading the bytes and writing them again would leave a second,
/// world-readable copy of a credential under the app's own directory.
///
/// The platform's own copy is what preserves the mode, which is why
/// [`copy_file_durable`] uses it rather than a byte loop.
#[cfg(unix)]
#[test]
fn a_durable_file_copy_carries_the_mode_across() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().expect("fixture dir");
    let from = dir.path().join("private.env");
    fs::write(&from, "TOKEN='secret'\n").expect("fixture file");
    fs::set_permissions(&from, fs::Permissions::from_mode(0o600)).expect("fixture mode");

    let to = dir.path().join("store/0");
    fs::create_dir_all(dir.path().join("store")).expect("fixture store");
    copy_file_durable(&from, &to).expect("the copy runs");

    let mode = fs::metadata(&to)
        .expect("the copy is there")
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600, "{mode:o}");
    // The control this reads against: an ordinary file's mode comes
    // through too, so the assertion above is about what was carried and
    // not about a mode this function imposes.
    let open = dir.path().join("ordinary.txt");
    fs::write(&open, "plain\n").expect("fixture file");
    fs::set_permissions(&open, fs::Permissions::from_mode(0o644)).expect("fixture mode");
    let copied = dir.path().join("store/1");
    copy_file_durable(&open, &copied).expect("the copy runs");
    assert_eq!(
        fs::metadata(&copied)
            .expect("the copy is there")
            .permissions()
            .mode()
            & 0o777,
        0o644
    );
}

/// The access-control entries a Windows file carries, read back by name
/// through `GetNamedSecurityInfoW`, a path the create never touches; the
/// walk over the list is the module's own.
#[cfg(windows)]
pub(crate) mod acl {
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;
    use std::ptr;

    use windows_sys::Win32::Foundation::{ERROR_SUCCESS, LocalFree};
    use windows_sys::Win32::Security::Authorization::{GetNamedSecurityInfoW, SE_FILE_OBJECT};
    use windows_sys::Win32::Security::DACL_SECURITY_INFORMATION;

    pub(crate) use super::dacl::{Entry, OWNER_ONLY};

    #[allow(clippy::unwrap_used)]
    #[allow(
        unsafe_code,
        reason = "Win32 has no safe binding; each site states its contract"
    )]
    pub(crate) fn entries(path: &Path) -> Vec<Entry> {
        let user = super::dacl::current_user().unwrap();
        let wide: Vec<u16> = crate::paths::verbatim(path)
            .unwrap()
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut dacl = ptr::null_mut();
        let mut descriptor = ptr::null_mut();
        // SAFETY: `wide` is NUL-terminated; the out-parameters are
        // writable; the descriptor the system allocates is freed below
        // after the last read through `dacl`, which points into it.
        let read = unsafe {
            GetNamedSecurityInfoW(
                wide.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                ptr::null_mut(),
                ptr::null_mut(),
                &mut dacl,
                ptr::null_mut(),
                &mut descriptor,
            )
        };
        assert_eq!(read, ERROR_SUCCESS, "GetNamedSecurityInfoW");
        // SAFETY: `dacl` is the list read above, null where the file has
        // none, alive until the free below; the SID points into `user`.
        let rows = unsafe { super::dacl::entries(dacl, user.sid()) };
        // SAFETY: `descriptor` came from `GetNamedSecurityInfoW`, which
        // documents `LocalFree` as its release, and nothing reads through
        // it after this.
        unsafe { LocalFree(descriptor) };
        rows.unwrap()
    }
}

/// A file kendex makes to hold a credential names the account it runs as
/// and nobody else: one entry, this account, full access, and nothing the
/// folder handed down. The temporary folder does hand entries down — that
/// is what the second case reads — so a plain create fails this by count.
#[cfg(windows)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_created_private_file_names_this_account_alone() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".env.local");

    write_private(&path, b"TOKEN='secret'\n").unwrap();

    assert_eq!(fs::read(&path).unwrap(), b"TOKEN='secret'\n");
    assert_eq!(acl::entries(&path), [acl::OWNER_ONLY]);
}

/// A file the person already has keeps the list they gave it: the file is
/// theirs, and kendex is storing a value in it rather than taking it over.
#[cfg(windows)]
#[test]
#[allow(clippy::unwrap_used)]
fn an_existing_private_file_keeps_its_own_list() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(".env.local");
    fs::write(&path, "OTHER='kept'\n").unwrap();
    let before = acl::entries(&path);
    assert!(
        before.iter().any(|entry| entry.inherited),
        "the fixture folder handed nothing down, so this case reads nothing: {before:?}"
    );

    write_private(&path, b"OTHER='kept'\nTOKEN='secret'\n").unwrap();

    assert_eq!(fs::read(&path).unwrap(), b"OTHER='kept'\nTOKEN='secret'\n");
    assert_eq!(acl::entries(&path), before);
}

/// A private file whose plain spelling runs past the legacy path limit is
/// still created, and still owner-only: the create hands Win32 the path
/// itself, so it has to put the verbatim marker on the way `std` would.
/// Against a create that encodes the path as given, `CreateFileW` refuses
/// this one with "path not found" about a folder that exists.
#[cfg(windows)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_private_file_past_the_legacy_path_limit_is_created_owner_only() {
    let tmp = tempfile::tempdir().unwrap();
    // Longer than the limit on its own, and within the name length NTFS
    // takes for one component.
    let path = tmp.path().join("e".repeat(250));

    write_private(&path, b"TOKEN='secret'\n").unwrap();

    assert_eq!(fs::read(&path).unwrap(), b"TOKEN='secret'\n");
    assert_eq!(acl::entries(&path), [acl::OWNER_ONLY]);
}

/// The list is read back through the handle before any byte is written,
/// and a file carrying any other list is refused: a volume that keeps no
/// lists creates the file open to everyone while reporting success. No
/// runner has such a volume, so the other list here is the one a plain
/// create takes from its folder, which is the same answer — not the one
/// written — and the refusal it draws is the one a FAT volume draws.
#[cfg(windows)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_list_the_volume_did_not_keep_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let user = dacl::current_user().unwrap();
    let private = tmp.path().join(".env.local");
    write_private(&private, b"TOKEN='secret'\n").unwrap();
    dacl::applied(&fs::File::open(&private).unwrap(), user.sid()).unwrap();

    let plain = tmp.path().join("plain");
    fs::write(&plain, "").unwrap();
    let refused = dacl::applied(&fs::File::open(&plain).unwrap(), user.sid()).unwrap_err();
    assert_eq!(refused.kind(), std::io::ErrorKind::Unsupported, "{refused}");
}

/// A create that never confirms its list leaves nothing behind: the file
/// is pending deletion from the moment it exists, and only `keep` after
/// the read-back lets it stay. Against a create without that disposition,
/// the unconfirmed file stands, and the next save takes it for a file the
/// person owns.
#[cfg(windows)]
#[test]
#[allow(clippy::unwrap_used)]
fn an_unconfirmed_create_takes_its_file_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let user = dacl::current_user().unwrap();
    let unconfirmed = tmp.path().join("unconfirmed");
    drop(dacl::create_pending(&unconfirmed, user.sid()).unwrap());
    assert!(!unconfirmed.exists());

    let kept = tmp.path().join("kept");
    let file = dacl::create_pending(&kept, user.sid()).unwrap();
    dacl::keep(&file).unwrap();
    drop(file);
    assert!(kept.exists());
}

/// A refusal carries the code the failing call itself reported, not what
/// an earlier call left on the thread: a handle opened without the right
/// to read its security is refused by `GetSecurityInfo` in its return
/// value, and that is the code the refusal names. Against a helper that
/// reads the thread's last error, the code here is whatever the token
/// sizing call left, not access denied.
#[cfg(windows)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_refusal_carries_the_code_of_the_call_that_failed() {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED;
    use windows_sys::Win32::Storage::FileSystem::FILE_WRITE_DATA;
    let tmp = tempfile::tempdir().unwrap();
    let user = dacl::current_user().unwrap();
    let path = tmp.path().join("plain");
    fs::write(&path, "").unwrap();
    let no_read_control = fs::OpenOptions::new()
        .access_mode(FILE_WRITE_DATA)
        .open(&path)
        .unwrap();

    let refused = dacl::applied(&no_read_control, user.sid()).unwrap_err();

    let failed = refused
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<dacl::Failed>())
        .unwrap();
    assert_eq!(
        (failed.step, failed.cause.raw_os_error()),
        ("GetSecurityInfo", Some(ERROR_ACCESS_DENIED as i32)),
        "{refused}"
    );
}
