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
///
/// Unix only because the collision needs both names to exist at once, and
/// Windows admits neither: a newline in a name is refused outright, and a
/// backslash in one is a separator.
#[cfg(unix)]
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

/// One row per path `of_file` gives no answer for. Anything that is not
/// a plain readable file of its own is no answer, and an "identical" claim
/// off an unread side is what this arm prevents: a link, a directory, an
/// absent path, and a file bigger than the bound. The link row needs a
/// link, and only a platform that hands them out without a privilege can
/// make one in a test.
#[test]
#[allow(clippy::expect_used)]
fn of_file_gives_no_answer_off_anything_but_a_plain_readable_file() {
    /// The path to read and the bytes to compare it against.
    type Plant = fn(&Path) -> (PathBuf, Vec<u8>);
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut rows: Vec<(&str, Plant)> = vec![
        ("a directory", |dir| {
            let folder = dir.join("folder");
            std::fs::create_dir(&folder).expect("mkdir");
            (folder, b"body\n".to_vec())
        }),
        ("an absent path", |dir| {
            (dir.join("gone.md"), b"body\n".to_vec())
        }),
        ("a file bigger than the bound", |dir| {
            let bytes = vec![b'x'; usize::try_from(MAX_BYTES).expect("bound fits") + 1];
            let path = dir.join("big.bin");
            std::fs::write(&path, &bytes).expect("write");
            (path, bytes)
        }),
    ];
    #[cfg(unix)]
    rows.push(("a link", |dir| {
        let real = dir.join("real.md");
        std::fs::write(&real, b"body\n").expect("write");
        let link = dir.join("link.md");
        std::os::unix::fs::symlink(&real, &link).expect("symlink");
        (link, b"body\n".to_vec())
    }));
    for (label, plant) in rows {
        let dir = tmp();
        let (path, bytes) = plant(dir.path());
        assert!(of_file(&path, &bytes).is_none(), "{label}");
    }
}

/// A directory a row's tree needs put back after the read.
#[derive(Default)]
struct Held {
    #[cfg_attr(
        not(unix),
        allow(dead_code, reason = "set only by the permission-bit row")
    )]
    restore: Option<PathBuf>,
}

/// One row per tree `of_tree` gives no answer for, each with the tree at
/// the bound still reading where the bound is the point. Neither bound is
/// a rendered item's shape, and a position past one is unread rather than
/// assumed equal: the entry bound counts folders too, the per-file bound
/// holds inside a tree as well, and the two multiply into a cumulative
/// budget (five hundred files at eight megabytes each is four gigabytes
/// of reading for one position). A link that loops back into its own tree
/// stops at the same depth `hash_tree` uses rather than running until the
/// stack does. The position belongs to somebody else, so a link inside it
/// would aim the read at a file nothing about this item chose, and the
/// tree is refused whole rather than read through it. A folder the walk
/// cannot enumerate must refuse the answer: skipped, it would leave a
/// partial tree comparing as whole, which is what "identical to the
/// catalog" is printed from. Something that is neither file nor directory
/// is nobody's to read; the third thing an entry can be here is a Unix
/// socket. The link, permission-bit and socket rows run where a test can
/// make those without a privilege.
#[test]
#[allow(clippy::expect_used, clippy::too_many_lines)]
fn of_tree_gives_no_answer_past_a_bound_or_off_an_entry_it_will_not_read() {
    /// The tree at the bound, still readable, with the differing total
    /// and shown-name count the at-bound read carries where a row pins
    /// them; then the one step past it.
    type Build = fn(&Path) -> Held;
    struct Row {
        label: &'static str,
        wanted: Vec<(PathBuf, Vec<u8>)>,
        at_bound: Option<Build>,
        at_bound_counts: Option<(u32, usize)>,
        past: Build,
    }
    #[cfg_attr(not(unix), allow(unused_variables))]
    let skill = || vec![(PathBuf::from("SKILL.md"), b"same\n".to_vec())];
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut rows = vec![
        Row {
            label: "past the cumulative budget",
            wanted: vec![],
            at_bound: Some(|root| {
                // Each file is well under MAX_BYTES and the count is well
                // under MAX_ENTRIES; together they cross the budget.
                let chunk = vec![b'x'; usize::try_from(MAX_BYTES).expect("bound fits")];
                for n in 0..MAX_TOTAL_BYTES / MAX_BYTES {
                    std::fs::write(root.join(format!("f{n}")), &chunk).expect("write");
                }
                Held::default()
            }),
            at_bound_counts: None,
            past: |root| {
                std::fs::write(root.join("one-more"), b"x").expect("write");
                Held::default()
            },
        },
        Row {
            label: "more entries than the bound",
            wanted: vec![],
            at_bound: Some(|root| {
                for n in 0..MAX_ENTRIES - 1 {
                    std::fs::write(root.join(format!("f{n}")), b"x").expect("write");
                }
                Held::default()
            }),
            at_bound_counts: Some((MAX_ENTRIES as u32 - 1, SHOWN_DIFFERING)),
            past: |root| {
                std::fs::create_dir(root.join("one-more")).expect("mkdir");
                Held::default()
            },
        },
        Row {
            label: "a file bigger than the bound inside the tree",
            wanted: vec![],
            at_bound: None,
            at_bound_counts: None,
            past: |root| {
                let bytes = vec![b'x'; usize::try_from(MAX_BYTES).expect("bound fits") + 1];
                std::fs::write(root.join("big.bin"), &bytes).expect("write");
                Held::default()
            },
        },
        Row {
            label: "deeper than the bound",
            wanted: vec![],
            at_bound: None,
            at_bound_counts: None,
            past: |root| {
                let mut at = root.to_path_buf();
                for _ in 0..=crate::hash::MAX_DEPTH {
                    at = at.join("d");
                }
                std::fs::create_dir_all(&at).expect("mkdir");
                std::fs::write(at.join("SKILL.md"), b"deep\n").expect("write");
                Held::default()
            },
        },
    ];
    #[cfg(unix)]
    rows.extend([
        Row {
            label: "a link inside the tree",
            wanted: skill(),
            at_bound: Some(|root| {
                std::fs::write(root.join("SKILL.md"), b"same\n").expect("write");
                Held::default()
            }),
            at_bound_counts: None,
            past: |root| {
                let outside = root.parent().expect("parent").join("outside.md");
                std::fs::write(&outside, b"elsewhere\n").expect("write");
                std::os::unix::fs::symlink(&outside, root.join("linked.md")).expect("symlink");
                Held::default()
            },
        },
        Row {
            label: "a folder that will not enumerate",
            wanted: skill(),
            at_bound: Some(|root| {
                std::fs::create_dir_all(root.join("locked")).expect("mkdir");
                std::fs::write(root.join("SKILL.md"), b"same\n").expect("write");
                std::fs::write(root.join("locked/inner.md"), b"same\n").expect("write");
                Held::default()
            }),
            at_bound_counts: None,
            past: |root| {
                use std::os::unix::fs::PermissionsExt;
                let hidden = root.join("locked");
                std::fs::set_permissions(&hidden, std::fs::Permissions::from_mode(0o000))
                    .expect("chmod");
                Held {
                    restore: Some(hidden),
                }
            },
        },
        Row {
            label: "an entry that is neither file nor directory",
            wanted: vec![],
            at_bound: None,
            at_bound_counts: None,
            past: |root| {
                // The listener can go; its socket stays in the tree.
                drop(std::os::unix::net::UnixListener::bind(root.join("sock")).expect("socket"));
                Held::default()
            },
        },
    ]);

    for row in rows {
        let label = row.label;
        let dir = tmp();
        let root = dir.path().join("skill");
        std::fs::create_dir_all(&root).expect("mkdir");
        if let Some(at_bound) = row.at_bound {
            let _held = at_bound(&root);
            let compared = of_tree(&root, &row.wanted)
                .unwrap_or_else(|| panic!("{label}: the bound itself still reads"));
            if let Some((total, shown)) = row.at_bound_counts {
                assert_eq!(compared.differing_total, total, "{label}");
                assert_eq!(
                    compared.differing.len(),
                    shown,
                    "{label}: the row carries at most SHOWN_DIFFERING names"
                );
            }
        }
        #[cfg_attr(not(unix), allow(unused_variables))]
        let held = (row.past)(&root);
        let answer = of_tree(&root, &row.wanted);
        #[cfg(unix)]
        if let Some(path) = &held.restore {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        }
        assert!(answer.is_none(), "{label}: past the bound, no answer");
    }
}
