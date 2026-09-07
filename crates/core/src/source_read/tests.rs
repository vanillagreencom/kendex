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
fn reads_inside_the_root() {
    let (_tmp, sealed) = fixture();
    let inside = sealed.root().join("skills/gh/SKILL.md");
    assert!(sealed.is_file(&inside));
    assert_eq!(
        sealed.read_to_string(&inside).unwrap(),
        "---\nname: gh\n---\n"
    );
}

/// The bound is a ceiling, not a wall one short of it: a directory
/// holding exactly the limit is inside it and must still read. The entry
/// after that is the row below.
#[test]
fn the_directory_bound_admits_exactly_the_limit() {
    let (_tmp, sealed) = fixture();
    let dir = sealed.root().join("many");
    std::fs::create_dir_all(&dir).expect("mkdir");
    for n in 0..MAX_DIR_ENTRIES {
        std::fs::write(dir.join(format!("f{n}")), "x").expect("write");
    }
    assert_eq!(sealed.entries(&dir).expect("list").len(), MAX_DIR_ENTRIES);
}

/// One row per read the sealed door refuses, each a `SourceEscape` naming
/// the path it stopped at and the reason only that arm gives. A path
/// outside the root and a dotted path climbing out of it; a link, through
/// every read path (a file read, a collected tree, a hashed tree) and as a
/// directory that would recurse forever; a tree nesting past the depth
/// bound; and a directory one entry past the entry bound, which is a
/// refusal to do the work — the whole answer, not one row a listing can
/// go on without. Where the refused path is a file the collapsed reading
/// answers no for it too. The link rows run where a test can make a link
/// without a privilege.
#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one table: eight escapes refused by one seal, each row a read of its own"
)]
fn every_escape_is_refused_naming_the_path_and_the_reason() {
    /// The refused call, the path the refusal names, and its reason.
    type Act = fn(&Path, &SealedSource) -> (Result<()>, PathBuf, String);
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut rows: Vec<(&str, bool, Act)> = vec![
        ("a path outside the root", true, |tmp, sealed| {
            let outside = tmp.join("secret.txt");
            (
                sealed.read(&outside).map(drop),
                outside,
                "outside the source root".to_owned(),
            )
        }),
        ("a dotted path climbing out", true, |_, sealed| {
            let dotted = sealed.root().join("skills/../../secret.txt");
            (
                sealed.read(&dotted).map(drop),
                dotted,
                "path traversal in a catalog path".to_owned(),
            )
        }),
        ("a tree deeper than the bound", false, |_, sealed| {
            let deep = sealed.root().join("skills/deep");
            let mut nested = deep.clone();
            let mut past = deep.clone();
            for level in 0..(MAX_TREE_DEPTH + 2) {
                nested = nested.join("d");
                if level <= MAX_TREE_DEPTH {
                    past = past.join("d");
                }
            }
            std::fs::create_dir_all(&nested).expect("mkdir");
            std::fs::write(nested.join("f"), "x").expect("write");
            (
                sealed.collect_tree(&deep, &[]).map(drop),
                past,
                format!("catalog tree nests deeper than {MAX_TREE_DEPTH} levels"),
            )
        }),
        (
            "a directory one entry past the bound",
            false,
            |_, sealed| {
                let dir = sealed.root().join("many");
                std::fs::create_dir_all(&dir).expect("mkdir");
                for n in 0..=MAX_DIR_ENTRIES {
                    std::fs::write(dir.join(format!("f{n}")), "x").expect("write");
                }
                (
                    sealed.entries(&dir).map(drop),
                    dir,
                    format!("more than {MAX_DIR_ENTRIES} entries in one catalog directory"),
                )
            },
        ),
    ];
    #[cfg(unix)]
    {
        rows.extend([
            (
                "a link read as a file",
                true,
                (|tmp, sealed| {
                    let leak = sealed.root().join("skills/gh/leak.md");
                    std::os::unix::fs::symlink(tmp.join("secret.txt"), &leak).expect("symlink");
                    (
                        sealed.read(&leak).map(drop),
                        leak,
                        "symlink in a catalog — refusing to read through it".to_owned(),
                    )
                }) as Act,
            ),
            ("a link inside a collected tree", false, |tmp, sealed| {
                let leak = sealed.root().join("skills/gh/leak.md");
                std::os::unix::fs::symlink(tmp.join("secret.txt"), &leak).expect("symlink");
                (
                    sealed
                        .collect_tree(&sealed.root().join("skills/gh"), &[])
                        .map(drop),
                    leak,
                    "symlink in a catalog — refusing to read through it".to_owned(),
                )
            }),
            ("a link inside a hashed tree", false, |tmp, sealed| {
                let leak = sealed.root().join("skills/gh/leak.md");
                std::os::unix::fs::symlink(tmp.join("secret.txt"), &leak).expect("symlink");
                (
                    sealed.hash_tree(&sealed.root().join("skills/gh")).map(drop),
                    leak,
                    "symlink in a catalog — refusing to read through it".to_owned(),
                )
            }),
            ("a link that would recurse forever", false, |_, sealed| {
                let looped = sealed.root().join("skills/gh/loop");
                std::os::unix::fs::symlink(sealed.root(), &looped).expect("symlink");
                (
                    sealed.collect_tree(sealed.root(), &[]).map(drop),
                    looped,
                    "symlink in a catalog — refusing to read through it".to_owned(),
                )
            }),
        ]);
    }

    for (label, not_a_file, act) in rows {
        let (tmp, sealed) = fixture();
        let (refused, at, why) = act(tmp.path(), &sealed);
        match refused {
            Err(CoreError::SourceEscape { path, reason }) => {
                assert_eq!(path, at, "{label}");
                assert_eq!(reason, why, "{label}");
            }
            other => panic!("{label}: expected a refused read, got {other:?}"),
        }
        if not_a_file {
            assert!(!sealed.is_file(&at), "{label}");
        }
    }
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

/// The two spellings of one root reach one citation.
///
/// A source opened through a symlinked parent — which is every standard
/// temp location on macOS, through `/var` — canonicalizes its root while
/// callers keep building paths from the spelling they were handed. Both
/// have to name the same catalog file, or a plan preview cites an
/// absolute host path where it means `skills/gh/SKILL.md`.
#[cfg(unix)]
#[test]
fn a_catalog_path_is_the_same_under_either_root_spelling() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let real = tmp.path().join("real");
    std::fs::create_dir_all(real.join("skills/gh")).expect("mkdir");
    std::fs::write(real.join("skills/gh/SKILL.md"), "---\nname: gh\n---\n").expect("write");
    let linked = tmp.path().join("linked");
    std::os::unix::fs::symlink(&real, &linked).expect("symlink");

    let sealed = SealedSource::open(&linked).expect("open");
    assert_eq!(
        sealed.catalog_path(&linked.join("skills/gh/SKILL.md")),
        "skills/gh/SKILL.md",
        "the spelling the caller was handed"
    );
    assert_eq!(
        sealed.catalog_path(&sealed.root().join("skills/gh/SKILL.md")),
        "skills/gh/SKILL.md",
        "the canonical spelling open() resolved to"
    );
}
