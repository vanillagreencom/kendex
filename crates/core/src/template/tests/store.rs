//! The store a template keeps its copies in: what a recorded path may be,
//! what a delete is allowed to reach, and what a licence file already
//! there means.

use std::fs;

use super::super::*;
use super::home;

/// A template with no members, which is all [`copy_path`] reads: it
/// resolves against the store folder the id names.
fn stored(id: &str) -> Template {
    Template {
        name: "Mine".to_owned(),
        id: id.to_owned(),
        members: Vec::new(),
        customizations: Customizations::default(),
    }
}

/// A recorded path is judged by the rule this repository already keeps for
/// what a name may be, so the spellings Windows resolves and trims are
/// refused wherever kendex runs.
///
/// Driven over the shapes directly rather than over a platform: the escape
/// this closes is a Windows one, and a row that only ran the host's own
/// spelling of `..` could not fail here. Each of these resolves to
/// somewhere else on Windows, and prune deletes what resolves.
#[test]
#[allow(clippy::unwrap_used)]
fn a_recorded_path_that_windows_would_resolve_elsewhere_is_refused() {
    let (_tmp, env) = home();
    let template = stored("mine");
    for spelling in [
        // The parent directory, spelled with the separator Windows uses.
        r"..\victim",
        r"skills\..\..\victim",
        // Drive-relative: the colon opens a drive, a device prefix or an
        // alternate data stream.
        "C:victim",
        r"C:\victim",
        // Trimmed back to `..` and `.` by Win32 after any comparison
        // against the literals has passed them.
        ".. ",
        "...",
        ". ",
        // The literals themselves, and a path that names nothing.
        "..",
        ".",
        "",
        "skills//gh",
        "/victim",
        // A device, which is written to rather than created.
        "NUL",
    ] {
        let refused = copy_path(&env, &template, spelling);
        assert!(
            matches!(refused, Err(CoreError::TemplateCopyUnreadable { .. })),
            "{spelling:?} should be refused: {refused:?}"
        );
    }

    // The inverse: what the store actually writes still resolves, or the
    // rows above would pass over a check that refuses everything.
    let good = copy_path(&env, &template, "skills/house-style").unwrap();
    assert!(good.ends_with("skills/house-style"), "{}", good.display());
    assert!(
        copy_path(&env, &template, "NOTICES/cat/LICENSE").is_ok(),
        "a recorded notice path must still resolve"
    );
}

/// A delete is asked where it would land before it happens.
///
/// A recorded id cannot spell its way out of the store, but a link dropped
/// into the store puts a path that reads as inside it over content that is
/// not. The reader every read of this store goes through refuses that, and
/// prune asks it before removing rather than after.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn prune_refuses_a_delete_that_would_land_outside_the_store() {
    let (tmp, env) = home();
    let root = env.template_store_dir().join("mine");
    fs::create_dir_all(&root).unwrap();

    // Somebody else's directory, and a link inside the store pointing at
    // it — the shape a copy id alone cannot make.
    let theirs = tmp.path().join("theirs");
    fs::create_dir_all(&theirs).unwrap();
    fs::write(theirs.join("keep.md"), "their bytes").unwrap();
    std::os::unix::fs::symlink(&theirs, root.join("skills")).unwrap();

    let before = Template {
        members: vec![Member {
            kind: MemberKind::Skill,
            name: "keep".to_owned(),
            enabled: true,
            source: MemberSource::Copy {
                copy: "skills/keep.md".to_owned(),
                from: None,
                notices: Vec::new(),
            },
        }],
        ..stored("mine")
    };
    // The member is gone, so prune would remove what its id resolves to.
    let refused = super::super::store::prune(&env, &before, &stored("mine"));

    assert!(
        matches!(refused, Err(CoreError::SourceEscape { .. })),
        "a delete outside the store must refuse: {refused:?}"
    );
    assert!(
        theirs.join("keep.md").is_file(),
        "the refusal deleted somebody else's file"
    );
}

/// Terms already in the store answer to the one rule this repository keeps
/// for a licence file that is already where bytes are going: the same
/// bytes are the same terms and are reused, different bytes refuse.
///
/// Overwriting would put one revision's terms over another's; skipping
/// would leave the second copy sitting beside the first one's licence
/// text. Neither is allowed, and the refusal names the file.
#[test]
#[allow(clippy::unwrap_used)]
fn a_licence_file_already_in_the_store_is_reused_or_refuses() {
    let (_tmp, env) = home();
    let notice = |text: &str| {
        vec![(
            std::path::PathBuf::from("NOTICES/cat/LICENSE"),
            text.as_bytes().to_vec(),
        )]
    };
    let files = vec![(std::path::PathBuf::from("SKILL.md"), b"body".to_vec())];
    let root = env.template_store_dir().join("mine");

    super::super::store::write(
        &env,
        "mine",
        ItemKind::Skill,
        "gh",
        &files,
        &notice("MIT License\n"),
    )
    .unwrap();
    let written = root.join("NOTICES/cat/LICENSE");
    assert_eq!(fs::read_to_string(&written).unwrap(), "MIT License\n");

    // The same terms, reached again through a second copy: one file.
    super::super::store::write(
        &env,
        "mine",
        ItemKind::Skill,
        "note",
        &files,
        &notice("MIT License\n"),
    )
    .unwrap();
    assert_eq!(fs::read_to_string(&written).unwrap(), "MIT License\n");

    // Terms that changed upstream are not these terms.
    let refused = super::super::store::write(
        &env,
        "mine",
        ItemKind::Skill,
        "gh",
        &files,
        &notice("MIT License, amended\n"),
    );
    let Err(CoreError::TemplateCopyUnreadable { why, .. }) = refused else {
        panic!("differing terms should refuse: {refused:?}");
    };
    assert!(why.contains("NOTICES/cat/LICENSE"), "{why}");
    // And the refusal changed nothing: the terms in the store are still
    // the ones the copies beside them came under.
    assert_eq!(fs::read_to_string(&written).unwrap(), "MIT License\n");
    assert!(
        root.join("skills/gh/SKILL.md").is_file(),
        "the refusal took the copy with it"
    );
}

/// The folder a template's store lives in is one path segment, and the
/// index is asked for it on the way in.
///
/// `store::root` makes that folder by joining the recorded id, and a join
/// takes an absolute path by replacing the base and takes `..` as the
/// parent — so an id out of a hand-edited file could name a directory
/// outside the store, and delete removes one whole. The member paths
/// inside the store answer the same rule; this is the root that holds
/// them.
///
/// Driven over the spellings directly rather than over a platform, the way
/// the recorded-path rows above are.
#[test]
#[allow(clippy::unwrap_used)]
fn an_index_naming_a_store_folder_it_may_not_is_refused_on_the_way_in() {
    let (tmp, env) = home();
    // Somebody else's directory, which a delete must never reach.
    let theirs = tmp.path().join("theirs");
    fs::create_dir_all(&theirs).unwrap();
    fs::write(theirs.join("keep.md"), "their bytes").unwrap();

    let saved = |id: &str| {
        let file = env.templates_file();
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(
            &file,
            format!("[[templates]]\nname = \"Mine\"\nid = {id}\n"),
        )
        .unwrap();
    };
    for id in [
        // Absolute: a join takes it by replacing the base entirely.
        format!("{:?}", theirs.display().to_string()),
        // The parent directory, in both separators.
        "\"..\"".to_owned(),
        "\"../theirs\"".to_owned(),
        r#""..\\theirs""#.to_owned(),
        // Drive-relative, and the spellings Windows trims back.
        "\"C:theirs\"".to_owned(),
        "\".. \"".to_owned(),
        "\"mine.\"".to_owned(),
        "\"\"".to_owned(),
    ] {
        saved(&id);
        let listed = list(&env);
        assert!(
            matches!(listed, Err(CoreError::TemplateIndexUnusable { .. })),
            "{id} should be refused on load: {listed:?}"
        );
        // And nothing acts on it: delete refuses before it reaches a path.
        let deleted = delete(&env, "Mine");
        assert!(
            matches!(deleted, Err(CoreError::TemplateIndexUnusable { .. })),
            "{id} should be refused before a delete: {deleted:?}"
        );
        assert!(
            theirs.join("keep.md").is_file(),
            "{id} reached somebody else's files"
        );
    }

    // The inverse: an id the product actually writes still loads, and its
    // delete reaches its own tree and nothing else.
    saved("\"mine\"");
    let root = env.template_store_dir().join("mine");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join("held.md"), "our bytes").unwrap();
    assert_eq!(list(&env).unwrap().len(), 1);
    delete(&env, "Mine").unwrap();
    assert!(!root.exists(), "{}", root.display());
    assert!(theirs.join("keep.md").is_file());
}
