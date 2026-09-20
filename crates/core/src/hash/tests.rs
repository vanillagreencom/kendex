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
/// character. Only Linux can create such names — APFS refuses filenames
/// that are not valid UTF-8 — so the case is built there and the property
/// holds by the same code path everywhere.
#[cfg(target_os = "linux")]
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

/// A clean Git conversion is portable metadata, while a content edit and a
/// binary file remain exact bytes.
#[test]
fn clean_checkout_hash_normalizes_only_gits_text_conversion() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    let git = |args: &[&str]| {
        let output = crate::process::Hardened::git(args, Some(root))
            .run()
            .unwrap();
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    };
    git(&["init", "-q", "-b", "main"]);
    git(&["config", "core.autocrlf", "true"]);
    std::fs::write(root.join("text"), b"one\ntwo\n").unwrap();
    std::fs::write(root.join("binary"), b"one\0\r\ntwo\r\n").unwrap();
    git(&["add", "text", "binary"]);
    git(&[
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit",
        "-qm",
        "fixture",
    ]);
    std::fs::remove_file(root.join("text")).unwrap();
    std::fs::remove_file(root.join("binary")).unwrap();
    git(&["checkout", "--", "text", "binary"]);

    assert_eq!(std::fs::read(root.join("text")).unwrap(), b"one\r\ntwo\r\n");
    assert_eq!(
        hash_clean_checkout_tree(&root.join("text")).unwrap(),
        Some(hash_bytes(b"one\ntwo\n"))
    );
    assert_eq!(
        hash_clean_checkout_tree(&root.join("binary")).unwrap(),
        Some(hash_bytes(b"one\0\r\ntwo\r\n"))
    );

    std::fs::write(root.join("text"), b"one\r\nchanged\r\n").unwrap();
    assert_eq!(hash_clean_checkout_tree(&root.join("text")).unwrap(), None);
}

/// The destination decides the portable identity before kendex creates it.
/// This covers a fresh nested install, an attribute-only EOL rule, and a
/// binary override through the same owner observed readers use later.
#[test]
fn rendered_identity_uses_the_absent_destination_git_policy() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    let git = |args: &[&str]| {
        let output = crate::process::Hardened::git(args, Some(root))
            .run()
            .unwrap();
        assert!(
            output.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    };
    git(&["init", "-q", "-b", "main"]);
    git(&["config", "core.autocrlf", "false"]);
    std::fs::write(
        root.join(".gitattributes"),
        "portable/** text eol=crlf\nbinary/** -text\n",
    )
    .unwrap();
    git(&["add", ".gitattributes"]);
    git(&[
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit",
        "-qm",
        "attributes",
    ]);

    let bytes = b"one\r\ntwo\r\n".to_vec();
    let files = vec![(PathBuf::new(), bytes.clone())];
    let portable = root.join("portable/deep/item/SKILL.md");
    assert!(!portable.parent().unwrap().exists());
    let planned = RenderedIdentity::rendered(&portable, &files);
    assert_eq!(planned.persisted(), hash_bytes(b"one\ntwo\n"));
    assert_ne!(planned.exact(), planned.persisted());

    std::fs::create_dir_all(portable.parent().unwrap()).unwrap();
    std::fs::write(&portable, &bytes).unwrap();
    let observed = RenderedIdentity::from_path(&portable, true).unwrap();
    assert!(observed.matches(planned.persisted()));

    let binary = root.join("binary/deep/item.bin");
    let binary_planned = RenderedIdentity::rendered(&binary, &files);
    assert_eq!(binary_planned.persisted(), hash_bytes(&bytes));

    let unspecified = root.join("unspecified/deep/item.md");
    let unspecified_planned = RenderedIdentity::rendered(&unspecified, &files);
    assert_eq!(unspecified_planned.persisted(), hash_bytes(&bytes));

    git(&["config", "core.autocrlf", "true"]);
    let automatic = root.join("automatic/deep/item.md");
    assert_eq!(
        RenderedIdentity::rendered(&automatic, &files).persisted(),
        hash_bytes(b"one\ntwo\n")
    );

    let nul = vec![(PathBuf::new(), b"one\0\r\ntwo\r\n".to_vec())];
    assert_eq!(
        RenderedIdentity::rendered(&automatic, &nul).persisted(),
        hash_bytes(b"one\0\r\ntwo\r\n")
    );
}

/// LF text and NUL-marked binary bytes have the same exact and portable
/// identity under every Git policy. All constructors must return that
/// identity without starting Git; this keeps ordinary catalog planning
/// proportional to bytes, not outputs.
#[test]
fn normalization_ineligible_identities_need_no_git_policy_queries() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    let existing = root.join("existing");
    std::fs::create_dir_all(&existing).unwrap();
    std::fs::write(existing.join("item.md"), b"one\ntwo\n").unwrap();
    std::fs::write(existing.join("image.bin"), b"binary\0payload\r\n").unwrap();
    let files = vec![
        (PathBuf::from("item.md"), b"one\ntwo\n".to_vec()),
        (PathBuf::from("image.bin"), b"binary\0payload\r\n".to_vec()),
    ];
    let exact = hash_files(&files);
    GIT_QUERY_COUNT.with(|count| count.set(0));

    let rendered = RenderedIdentity::rendered(&root.join("absent"), &files);
    let observed = RenderedIdentity::observed_files(&existing, &files, false);
    let from_path = RenderedIdentity::from_path(&existing, true).unwrap();

    for identity in [rendered, observed, from_path] {
        assert_eq!(identity.exact(), exact);
        assert_eq!(identity.persisted(), exact);
    }
    GIT_QUERY_COUNT.with(|count| assert_eq!(count.get(), 0));
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
