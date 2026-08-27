use super::*;

/// What the trash keeps of a link is the link. Copying through one
/// would put the tree it points at — bytes another installation still
/// reads — in the trash under this link's name, and take only the link
/// away.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_to_a_tree_moves_as_a_link() {
    let tmp = tempfile::tempdir().unwrap();
    let shared = tmp.path().join("shared");
    fs::create_dir_all(&shared).unwrap();
    fs::write(shared.join("SKILL.md"), "body").unwrap();
    let link = tmp.path().join("link");
    std::os::unix::fs::symlink(&shared, &link).unwrap();
    let dest = tmp.path().join("trash/held");
    fs::create_dir_all(dest.parent().unwrap()).unwrap();

    relocate(&link, &dest).unwrap();

    assert!(dest.is_symlink());
    assert_eq!(fs::read_link(&dest).unwrap(), shared);
    assert!(!link.is_symlink());
    assert!(shared.join("SKILL.md").is_file());
}

/// The half-present installation this whole arm exists for: the link is
/// still there and what it points at is gone. Read through, the copy
/// fails with the target's ENOENT and the removal that was called to
/// clear the link aborts on it.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_link_whose_target_is_gone_still_moves() {
    let tmp = tempfile::tempdir().unwrap();
    let link = tmp.path().join("link");
    let gone = tmp.path().join("gone");
    std::os::unix::fs::symlink(&gone, &link).unwrap();
    let dest = tmp.path().join("trash/held");
    fs::create_dir_all(dest.parent().unwrap()).unwrap();

    relocate(&link, &dest).unwrap();

    assert!(dest.is_symlink());
    assert_eq!(fs::read_link(&dest).unwrap(), gone);
    assert!(!link.is_symlink());
}

/// A tree and a file still cross by their bytes.
#[test]
#[allow(clippy::unwrap_used)]
fn plain_bytes_cross_by_copy() {
    let tmp = tempfile::tempdir().unwrap();
    let tree = tmp.path().join("tree");
    fs::create_dir_all(tree.join("nested")).unwrap();
    fs::write(tree.join("nested/SKILL.md"), "body").unwrap();
    let file = tmp.path().join("one.md");
    fs::write(&file, "one").unwrap();

    relocate(&tree, &tmp.path().join("trash/tree")).unwrap();
    relocate(&file, &tmp.path().join("trash/one.md")).unwrap();

    assert!(!tree.exists());
    assert!(!file.exists());
    assert_eq!(
        fs::read_to_string(tmp.path().join("trash/tree/nested/SKILL.md")).unwrap(),
        "body"
    );
    assert_eq!(
        fs::read_to_string(tmp.path().join("trash/one.md")).unwrap(),
        "one"
    );
}
