//! The comparison's answers, and every arm where it refuses to give one.

use std::path::PathBuf;

use super::*;

#[allow(clippy::expect_used)]
fn tmp() -> tempfile::TempDir {
    tempfile::tempdir().expect("tempdir")
}

#[test]
#[allow(clippy::expect_used)]
fn identical_bytes_compare_equal_and_a_changed_byte_does_not() {
    let dir = tmp();
    let path = dir.path().join("SKILL.md");
    std::fs::write(&path, b"body\n").expect("write");
    assert!(
        of_file(&path, b"body\n").expect("comparable").identical(),
        "same bytes are identical"
    );
    let changed = of_file(&path, b"other\n").expect("comparable");
    assert_eq!(changed.differing, vec!["SKILL.md".to_owned()]);
    assert_eq!(changed.differing_total, 1);
}

/// Anything that is not a plain readable file of its own is no answer.
/// An "identical" claim off an unread side is what this arm prevents.
#[test]
#[allow(clippy::expect_used)]
fn of_file_refuses_a_link_a_directory_and_an_absent_path() {
    let dir = tmp();
    let real = dir.path().join("real.md");
    std::fs::write(&real, b"body\n").expect("write");
    let link = dir.path().join("link.md");
    std::os::unix::fs::symlink(&real, &link).expect("symlink");
    assert!(of_file(&link, b"body\n").is_none(), "a link is not read");
    let folder = dir.path().join("folder");
    std::fs::create_dir(&folder).expect("mkdir");
    assert!(of_file(&folder, b"body\n").is_none());
    assert!(of_file(&dir.path().join("gone.md"), b"body\n").is_none());
}

#[test]
#[allow(clippy::expect_used)]
fn a_tree_names_every_side_that_only_one_holds() {
    let dir = tmp();
    let root = dir.path().join("skill");
    std::fs::create_dir_all(root.join("references")).expect("mkdir");
    std::fs::write(root.join("SKILL.md"), b"same\n").expect("write");
    std::fs::write(root.join("references/old.md"), b"gone\n").expect("write");
    let wanted = vec![
        (PathBuf::from("SKILL.md"), b"same\n".to_vec()),
        (PathBuf::from("references/new.md"), b"fresh\n".to_vec()),
    ];
    let compared = of_tree(&root, &wanted).expect("comparable");
    assert_eq!(
        compared.differing,
        vec![
            "references/new.md".to_owned(),
            "references/old.md".to_owned()
        ]
    );
    assert_eq!(compared.differing_total, 2);
}

/// A path is an identity, and `shown` is not injective: a name holding a
/// real newline and one holding the two characters that spell its escape
/// render alike. Merged before counting, one of two differing files would
/// vanish from both the list and the total.
#[test]
#[allow(clippy::expect_used)]
fn two_names_that_render_alike_stay_two_files() {
    let dir = tmp();
    let root = dir.path().join("skill");
    std::fs::create_dir_all(&root).expect("mkdir");
    std::fs::write(root.join("we\nird.md"), b"mine\n").expect("write");
    std::fs::write(root.join("we\\nird.md"), b"mine\n").expect("write");
    let compared = of_tree(&root, &[]).expect("comparable");
    assert_eq!(compared.differing_total, 2, "{:?}", compared.differing);
    assert_eq!(compared.differing.len(), 2, "{:?}", compared.differing);
}

/// Both bounds hold on their own, and they multiply: five hundred files at
/// eight megabytes each is four gigabytes of reading for one position.
#[test]
#[allow(clippy::expect_used)]
fn a_tree_past_the_cumulative_budget_gives_no_answer() {
    let dir = tmp();
    let root = dir.path().join("wide");
    std::fs::create_dir_all(&root).expect("mkdir");
    // Each file is well under MAX_BYTES and the count is well under
    // MAX_ENTRIES; together they cross the budget.
    let chunk = vec![b'x'; usize::try_from(MAX_BYTES).expect("bound fits")];
    let each = MAX_TOTAL_BYTES / MAX_BYTES;
    for n in 0..each {
        std::fs::write(root.join(format!("f{n}")), &chunk).expect("write");
    }
    assert!(
        of_tree(&root, &[]).is_some(),
        "the budget itself still reads"
    );
    std::fs::write(root.join("one-more"), b"x").expect("write");
    assert!(of_tree(&root, &[]).is_none(), "past the budget, no answer");
}

/// The position belongs to somebody else. A link inside it would aim the
/// read at a file nothing about this item chose, so the tree is refused
/// whole rather than read through it.
#[test]
#[allow(clippy::expect_used)]
fn a_link_inside_the_tree_refuses_the_whole_comparison() {
    let dir = tmp();
    let outside = dir.path().join("outside.md");
    std::fs::write(&outside, b"elsewhere\n").expect("write");
    let root = dir.path().join("skill");
    std::fs::create_dir_all(&root).expect("mkdir");
    std::fs::write(root.join("SKILL.md"), b"same\n").expect("write");
    let wanted = vec![(PathBuf::from("SKILL.md"), b"same\n".to_vec())];
    assert!(of_tree(&root, &wanted).is_some(), "the plain tree compares");
    std::os::unix::fs::symlink(&outside, root.join("linked.md")).expect("symlink");
    assert!(of_tree(&root, &wanted).is_none(), "a link stops the answer");
}

/// A folder the walk cannot enumerate must refuse the answer. Skipped, it
/// would leave a partial tree comparing as whole, which is what "identical
/// to the catalog" is printed from.
#[test]
#[allow(clippy::expect_used)]
fn a_folder_that_will_not_enumerate_refuses_rather_than_dropping_out() {
    let dir = tmp();
    let root = dir.path().join("skill");
    let hidden = root.join("locked");
    std::fs::create_dir_all(&hidden).expect("mkdir");
    std::fs::write(root.join("SKILL.md"), b"same\n").expect("write");
    std::fs::write(hidden.join("inner.md"), b"same\n").expect("write");
    let wanted = vec![(PathBuf::from("SKILL.md"), b"same\n".to_vec())];
    assert!(
        of_tree(&root, &wanted).is_some(),
        "readable, so it compares"
    );

    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&hidden, std::fs::Permissions::from_mode(0o000)).expect("chmod");
    let refused = of_tree(&root, &wanted).is_none();
    std::fs::set_permissions(&hidden, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    assert!(
        refused,
        "a folder that will not enumerate compared as whole"
    );
}

/// Neither bound is a rendered item's shape, and a position past one is
/// unread rather than assumed equal. Folders count too: a tree wide in
/// directories is as much of a read as one wide in files.
#[test]
#[allow(clippy::expect_used)]
fn a_tree_with_more_entries_than_the_bound_gives_no_answer() {
    let dir = tmp();
    let root = dir.path().join("wide");
    std::fs::create_dir_all(&root).expect("mkdir");
    for n in 0..MAX_ENTRIES - 1 {
        std::fs::write(root.join(format!("f{n}")), b"x").expect("write");
    }
    let compared = of_tree(&root, &[]).expect("the bound itself still reads");
    assert_eq!(compared.differing_total, MAX_ENTRIES as u32 - 1);
    assert_eq!(
        compared.differing.len(),
        SHOWN_DIFFERING,
        "the row carries at most SHOWN_DIFFERING names"
    );

    std::fs::create_dir(root.join("one-more")).expect("mkdir");
    assert!(of_tree(&root, &[]).is_none(), "a folder counts as an entry");
}

#[test]
#[allow(clippy::expect_used)]
fn a_file_bigger_than_the_bound_gives_no_answer() {
    let dir = tmp();
    let bytes = vec![b'x'; usize::try_from(MAX_BYTES).expect("bound fits") + 1];
    let path = dir.path().join("big.bin");
    std::fs::write(&path, &bytes).expect("write");
    assert!(of_file(&path, &bytes).is_none(), "too large to read");

    let root = dir.path().join("skill");
    std::fs::create_dir_all(&root).expect("mkdir");
    std::fs::write(root.join("big.bin"), &bytes).expect("write");
    assert!(of_tree(&root, &[]).is_none(), "and inside a tree as well");
}

/// A link that loops back into its own tree stops at the same depth
/// `hash_tree` uses rather than running until the stack does.
#[test]
#[allow(clippy::expect_used)]
fn a_tree_deeper_than_the_bound_gives_no_answer() {
    let dir = tmp();
    let root = dir.path().join("deep");
    let mut at = root.clone();
    for _ in 0..=crate::hash::MAX_DEPTH {
        at = at.join("d");
    }
    std::fs::create_dir_all(&at).expect("mkdir");
    std::fs::write(at.join("SKILL.md"), b"deep\n").expect("write");
    assert!(of_tree(&root, &[]).is_none());
}

/// Something that is neither file nor directory is nobody's to read.
#[test]
#[allow(clippy::expect_used)]
fn an_entry_that_is_neither_file_nor_directory_stops_the_answer() {
    let dir = tmp();
    let root = dir.path().join("skill");
    std::fs::create_dir_all(&root).expect("mkdir");
    let socket = std::os::unix::net::UnixListener::bind(root.join("sock")).expect("socket");
    assert!(of_tree(&root, &[]).is_none());
    drop(socket);
}
