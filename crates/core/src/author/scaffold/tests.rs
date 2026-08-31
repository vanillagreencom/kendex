use super::*;

/// A removal that cannot finish is not silent: the error names the folder
/// left behind, so the next attempt is not told to register something
/// kendex abandoned there. Pinned with a child nothing may unlink from,
/// which is the shape of every real refusal (EACCES, EBUSY, a handle
/// somebody holds on Windows).
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_cleanup_that_cannot_finish_names_what_it_left() {
    use std::os::unix::fs::PermissionsExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("made");
    let held = dir.join("held");
    std::fs::create_dir_all(&held).unwrap();
    std::fs::write(held.join("file"), "").unwrap();
    std::fs::set_permissions(&held, std::fs::Permissions::from_mode(0o500)).unwrap();
    let unlock =
        || std::fs::set_permissions(&held, std::fs::Permissions::from_mode(0o700)).unwrap();
    if std::fs::write(held.join("probe"), "").is_ok() {
        // Permissions do not bind this user (root): the removal cannot be
        // made to fail here.
        unlock();
        return;
    }

    let said = unmade(
        &dir,
        CoreError::Authoring {
            message: "the registry refused".to_owned(),
        },
    )
    .to_string();
    unlock();

    assert!(said.contains("the registry refused"), "{said}");
    assert!(said.contains(&dir.display().to_string()), "{said}");
    assert!(said.contains("left behind"), "{said}");
    assert!(dir.is_dir(), "the folder really is still there");
}

/// A build that failed before it made anything reports that failure, not
/// a folder left behind that was never there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_cleanup_with_nothing_to_remove_returns_the_failure_itself() {
    let tmp = tempfile::tempdir().unwrap();
    let said = unmade(
        &tmp.path().join("never-made"),
        CoreError::Authoring {
            message: "the build failed".to_owned(),
        },
    )
    .to_string();
    assert_eq!(said, "the build failed");
}
