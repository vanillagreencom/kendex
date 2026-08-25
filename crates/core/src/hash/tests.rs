use super::*;
use crate::manifest::MANIFEST_SCHEMA;

#[cfg(unix)]
#[test]
fn a_link_looping_into_its_own_tree_is_an_error_not_a_crash() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("skill");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("SKILL.md"), "hello").unwrap();
    std::os::unix::fs::symlink(&root, root.join("loop")).unwrap();
    assert!(hash_tree(&root).is_err());
}

/// The as-is hash names the entries a move carries: a dangling link
/// is one of them, by its target, where the content hash has nothing
/// to read and refuses the tree.
#[cfg(unix)]
#[test]
fn as_is_hash_names_a_link_by_its_target_and_never_follows_it() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("dir");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("a"), "bytes").unwrap();
    std::os::unix::fs::symlink("nowhere", root.join("gone")).unwrap();
    assert!(hash_tree(&root).is_err());

    let dangling = hash_tree_as_is(&root).unwrap();
    std::fs::remove_file(root.join("gone")).unwrap();
    std::os::unix::fs::symlink("a", root.join("gone")).unwrap();
    let resolving = hash_tree_as_is(&root).unwrap();
    assert_ne!(dangling, resolving, "the target is part of the record");

    std::fs::remove_file(root.join("gone")).unwrap();
    std::fs::write(root.join("gone"), "a").unwrap();
    let file = hash_tree_as_is(&root).unwrap();
    assert_ne!(
        resolving, file,
        "a file spelling the target is not the link"
    );

    std::fs::create_dir(root.join("empty")).unwrap();
    let with_dir = hash_tree_as_is(&root).unwrap();
    assert_ne!(
        file, with_dir,
        "an empty directory is an entry the move carries"
    );
}

/// The encoding frames every field: bytes inside a file that spell a
/// record boundary never read as one, so one file holding `x\0b\0y`
/// is not two files holding `x` and `y`.
#[test]
fn as_is_hash_cannot_be_forged_by_bytes_that_spell_a_boundary() {
    let tmp = tempfile::tempdir().unwrap();
    let one = tmp.path().join("one");
    std::fs::create_dir_all(&one).unwrap();
    std::fs::write(one.join("a"), b"x\0b\0y").unwrap();
    let two = tmp.path().join("two");
    std::fs::create_dir_all(&two).unwrap();
    std::fs::write(two.join("a"), b"x").unwrap();
    std::fs::write(two.join("b"), b"y").unwrap();
    assert_ne!(
        hash_tree_as_is(&one).unwrap(),
        hash_tree_as_is(&two).unwrap()
    );
}

/// Names go in as the bytes the OS holds, so two names that are not
/// UTF-8 stay two names instead of collapsing into one replacement
/// character.
#[cfg(unix)]
#[test]
fn as_is_hash_keeps_distinct_non_utf8_names_distinct() {
    use std::os::unix::ffi::OsStrExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let one = tmp.path().join("one");
    std::fs::create_dir_all(&one).unwrap();
    std::fs::write(one.join(std::ffi::OsStr::from_bytes(b"\xff")), "same").unwrap();
    let two = tmp.path().join("two");
    std::fs::create_dir_all(&two).unwrap();
    std::fs::write(two.join(std::ffi::OsStr::from_bytes(b"\xfe")), "same").unwrap();
    assert_ne!(
        hash_tree_as_is(&one).unwrap(),
        hash_tree_as_is(&two).unwrap()
    );
}

#[test]
fn tree_hash_is_content_and_layout_sensitive() {
    let tmp = tempfile::tempdir().unwrap();
    let a = tmp.path().join("a");
    std::fs::create_dir_all(a.join("sub")).unwrap();
    std::fs::write(a.join("SKILL.md"), "hello").unwrap();
    std::fs::write(a.join("sub/x.sh"), "x").unwrap();
    let first = hash_tree(&a).unwrap();
    assert_eq!(first, hash_tree(&a).unwrap());

    std::fs::write(a.join("sub/x.sh"), "y").unwrap();
    assert_ne!(first, hash_tree(&a).unwrap());
}

#[test]
fn editing_a_shared_key_invalidates_dependents() {
    let tmp = tempfile::tempdir().unwrap();
    let skill = tmp.path().join("skill");
    std::fs::create_dir_all(&skill).unwrap();
    std::fs::write(skill.join("SKILL.md"), "content").unwrap();

    let mut manifest = Manifest {
        schema: MANIFEST_SCHEMA,
        ..Manifest::default()
    };
    let sealed = crate::source_read::SealedSource::open(tmp.path()).unwrap();
    let skill = sealed.root().join("skill");
    let before = installation_hash(
        &sealed,
        &skill,
        &manifest,
        ItemKind::Skill,
        "github",
        HarnessId::Claude,
    )
    .unwrap();

    manifest
        .skill_instructions
        .insert("all".into(), "shared instruction".into());
    let after = installation_hash(
        &sealed,
        &skill,
        &manifest,
        ItemKind::Skill,
        "github",
        HarnessId::Claude,
    )
    .unwrap();
    assert_ne!(before, after);

    let unrelated = installation_hash(
        &sealed,
        &skill,
        &manifest,
        ItemKind::Command,
        "github",
        HarnessId::Claude,
    )
    .unwrap();
    let unrelated_before = {
        let clean = Manifest {
            schema: MANIFEST_SCHEMA,
            ..Manifest::default()
        };
        installation_hash(
            &sealed,
            &skill,
            &clean,
            ItemKind::Command,
            "github",
            HarnessId::Claude,
        )
        .unwrap()
    };
    assert_eq!(unrelated, unrelated_before);
}
