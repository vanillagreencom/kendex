//! Reading a catalog through the sealed door: what it lets through, what
//! it refuses, and where the bounds fall.

use super::*;

fn fixture() -> (tempfile::TempDir, SealedSource) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let root = tmp.path().join("catalog");
    std::fs::create_dir_all(root.join("skills/gh")).expect("mkdir");
    std::fs::write(root.join("skills/gh/SKILL.md"), "---\nname: gh\n---\n").expect("write");
    std::fs::write(tmp.path().join("secret.txt"), "host secret").expect("write");
    let sealed = SealedSource::open(&root).expect("open");
    (tmp, sealed)
}

#[test]
fn reads_inside_the_root_and_refuses_escapes() {
    let (tmp, sealed) = fixture();
    let inside = sealed.root().join("skills/gh/SKILL.md");
    assert!(sealed.is_file(&inside));
    assert!(sealed.read_to_string(&inside).is_ok());

    let outside = tmp.path().join("secret.txt");
    assert!(!sealed.is_file(&outside));
    assert!(matches!(
        sealed.read(&outside),
        Err(CoreError::SourceEscape { .. })
    ));
    let dotted = sealed.root().join("skills/../../secret.txt");
    assert!(matches!(
        sealed.read(&dotted),
        Err(CoreError::SourceEscape { .. })
    ));
}

#[cfg(unix)]
#[test]
fn symlinks_are_refused_through_every_read_path() {
    let (tmp, sealed) = fixture();
    let secret = tmp.path().join("secret.txt");
    std::os::unix::fs::symlink(&secret, sealed.root().join("skills/gh/leak.md")).expect("symlink");
    let leak = sealed.root().join("skills/gh/leak.md");
    assert!(!sealed.is_file(&leak));
    assert!(matches!(
        sealed.read(&leak),
        Err(CoreError::SourceEscape { .. })
    ));
    assert!(matches!(
        sealed.collect_tree(&sealed.root().join("skills/gh"), &[]),
        Err(CoreError::SourceEscape { .. })
    ));
    assert!(matches!(
        sealed.hash_tree(&sealed.root().join("skills/gh")),
        Err(CoreError::SourceEscape { .. })
    ));

    // A symlinked directory cannot recurse forever either.
    std::fs::remove_file(&leak).expect("rm");
    std::os::unix::fs::symlink(sealed.root(), sealed.root().join("skills/gh/loop"))
        .expect("symlink");
    assert!(matches!(
        sealed.collect_tree(sealed.root(), &[]),
        Err(CoreError::SourceEscape { .. })
    ));
}

#[test]
fn tree_budgets_bound_hostile_catalogs() {
    let (_tmp, sealed) = fixture();
    let mut nested = sealed.root().join("skills/deep");
    for _ in 0..(MAX_TREE_DEPTH + 2) {
        nested = nested.join("d");
    }
    std::fs::create_dir_all(&nested).expect("mkdir");
    std::fs::write(nested.join("f"), "x").expect("write");
    assert!(matches!(
        sealed.collect_tree(&sealed.root().join("skills/deep"), &[]),
        Err(CoreError::SourceEscape { .. })
    ));
}

/// The bound is a ceiling, not a wall one short of it: a directory
/// holding exactly the limit is inside it and must still read. The bound
/// is a refusal to do the work, which is the whole answer, not one row a
/// listing can go on without.
#[test]
fn the_directory_bound_admits_exactly_the_limit() {
    let (_tmp, sealed) = fixture();
    let dir = sealed.root().join("many");
    std::fs::create_dir_all(&dir).expect("mkdir");
    for n in 0..MAX_DIR_ENTRIES {
        std::fs::write(dir.join(format!("f{n}")), "x").expect("write");
    }
    assert_eq!(sealed.entries(&dir).expect("list").len(), MAX_DIR_ENTRIES);

    std::fs::write(dir.join("one-too-many"), "x").expect("write");
    assert!(matches!(
        sealed.entries(&dir),
        Err(CoreError::SourceEscape { .. })
    ));
}

/// A skill that is the whole repository excludes VCS internals and
/// dependency dirs — the same bytes render, browse safety, and catalog
/// check must all agree on. A `.git/config` carrying credentials must
/// never reach the installed tree.
#[test]
fn a_repo_root_skill_excludes_vcs_and_dependency_dirs() {
    let (_tmp, sealed) = fixture();
    std::fs::create_dir_all(sealed.root().join(".git")).expect("mkdir");
    std::fs::write(sealed.root().join(".git/config"), "token").expect("write");
    std::fs::create_dir_all(sealed.root().join("node_modules/dep")).expect("mkdir");
    std::fs::write(sealed.root().join("node_modules/dep/i.js"), "x").expect("write");
    std::fs::write(sealed.root().join("SKILL.md"), "# skill").expect("write");

    let files = sealed.collect_skill_tree(sealed.root()).expect("tree");
    let names: Vec<_> = files
        .iter()
        .map(|(p, _)| p.to_string_lossy().into_owned())
        .collect();
    assert!(names.contains(&"SKILL.md".to_owned()));
    assert!(!names.iter().any(|n| n.starts_with(".git/")));
    assert!(!names.iter().any(|n| n.starts_with("node_modules/")));
}

/// A skill nested below the root is scored on all of its own bytes — the
/// vendor-dir skip is a repo-root concession, not a general filter that
/// would let a nested skill hide content from the safety scan.
#[test]
fn a_nested_skill_keeps_every_one_of_its_files() {
    let (_tmp, sealed) = fixture();
    let dir = sealed.root().join("skills/gh");
    std::fs::create_dir_all(dir.join("node_modules")).expect("mkdir");
    std::fs::write(dir.join("node_modules/i.js"), "x").expect("write");
    std::fs::write(dir.join("SKILL.md"), "# gh").expect("write");

    let files = sealed.collect_skill_tree(&dir).expect("tree");
    assert_eq!(files.len(), 2);
}

#[test]
fn skipped_names_are_pruned_from_trees() {
    let (_tmp, sealed) = fixture();
    let pkg = sealed.root().join("pkg");
    std::fs::create_dir_all(pkg.join("node_modules/dep")).expect("mkdir");
    std::fs::write(pkg.join("node_modules/dep/i.js"), "x").expect("write");
    std::fs::write(pkg.join("index.js"), "y").expect("write");
    let files = sealed.collect_tree(&pkg, &["node_modules"]).expect("tree");
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].0, PathBuf::from("index.js"));
}

/// The boolean reading a listing draws rows from: a directory it cannot
/// traverse answers no, because it cannot draw what it cannot read either
/// way. Anything deciding what a write would destroy asks
/// [`crate::fs::entry`], where that refusal survives.
#[test]
fn the_collapsed_reading_answers_no_where_it_cannot_tell() {
    let (_tmp, sealed) = fixture();
    let file = sealed.root().join("skills/gh/SKILL.md");
    let dir = sealed.root().join("skills/gh");
    assert!(sealed.is_file(&file));
    assert!(!sealed.is_dir(&file));
    assert!(sealed.is_dir(&dir));
    assert!(!sealed.is_file(&dir));
    assert!(!sealed.is_file(&dir.join("nowhere")));

    // Absent said the other way, which only the three-valued reading can
    // tell from a refusal: a name built under a plain file, which is what
    // a probe for `<entry>/SKILL.md` reads whenever the entry beside an
    // item is an ordinary file.
    assert!(
        crate::fs::entry(&file.join("SKILL.md"))
            .expect("probe")
            .is_none()
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o000)).expect("chmod");
        // Root traverses any directory whatever its mode, so there the
        // denial under test does not exist and the file is simply there.
        let denied = std::fs::metadata(&file).is_err();
        let collapsed = sealed.is_file(&file);
        let kept = crate::fs::entry(&file);
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).expect("chmod");

        match denied {
            true => {
                assert!(!collapsed, "the tolerant reading answers no");
                assert!(matches!(kept, Err(CoreError::Io { .. })), "{kept:?}");
            }
            false => {
                assert!(collapsed);
                assert!(kept.expect("probe").is_some());
            }
        }
    }
}
