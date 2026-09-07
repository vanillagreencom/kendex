//! What a plain name's slot in the local source already holds. A plain
//! name and a namespaced one share one directory — `plugin` is the
//! directory `plugin/item` is stored in — so a capture written at the
//! plain slot can take a namespaced item with it. Every test here asks
//! what the slot holds and what the refusal leaves on disk.

use super::super::*;
use crate::env::FakeOs;
use std::fs;

use crate::test_util::rooted;

/// A skill written straight into the global scope's local source. These
/// controls ask what the slot HOLDS, and how it came to hold it is not part
/// of that question.
fn store_local_skill(env: &Env, rel: &str, body: &str) -> PathBuf {
    let dir = crate::source::local_source_root(env, &Scope::Global)
        .join("skills")
        .join(rel);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), body).unwrap();
    dir
}

/// A skill Claude holds at the global scope, for a capture to take.
fn hold_claude_skill(home: &Path, name: &str, body: &str) -> PathBuf {
    let held = home.join(".claude/skills").join(name);
    fs::create_dir_all(&held).unwrap();
    fs::write(held.join("SKILL.md"), body).unwrap();
    held
}

/// A skill adopted into the global scope's local source from Claude's
/// tree, the way a stored namespaced item usually came to be there.
fn adopt_claude_skill(env: &Env, home: &Path, held_as: &str, name: &str, body: &str) {
    hold_claude_skill(home, held_as, body);
    let plan = adopt(
        env,
        &Scope::Global,
        ItemKind::Skill,
        name,
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(env, &plan).unwrap();
}

/// The listing the local source gives of its skills.
fn listed_skills(env: &Env) -> Vec<String> {
    let root = crate::source::local_source_root(env, &Scope::Global);
    let sealed = crate::source_read::SealedSource::open(&root).unwrap();
    let config = crate::source::source_config_for(&sealed, LOCAL_SOURCE_NAME).unwrap();
    crate::source::list_items(&sealed, &config, ItemKind::Skill)
}

/// Where the local source resolves a skill name to.
fn found_skill(env: &Env, name: &str) -> Option<PathBuf> {
    let root = crate::source::local_source_root(env, &Scope::Global);
    let sealed = crate::source_read::SealedSource::open(&root).unwrap();
    let config = crate::source::source_config_for(&sealed, LOCAL_SOURCE_NAME).unwrap();
    crate::source::find_item(&sealed, &config, ItemKind::Skill, name)
}

/// Why the plain name was refused.
#[derive(Debug)]
enum Refusal {
    /// The slot holds this item, which the capture would be written over:
    /// `AdoptNameUnusable` naming the plain name and the occupant.
    Occupant(&'static str),
    /// The slot or its parent is past the reader's bound: `SourceEscape`
    /// at this path, for this reason.
    Bound(PathBuf, String),
    /// The occupancy read itself failed at this path: `Io`.
    #[cfg_attr(
        not(unix),
        allow(dead_code, reason = "built only by the permission-bit rows")
    )]
    Unreadable(PathBuf),
}

/// One slot layout: what was planted, the plain name asked for, the
/// refusal it gets, the stored files that must survive untouched with
/// their bytes, a path whose mode is put back after the call, and where
/// that is the point what the local source still lists afterwards and
/// where it resolves the first listed name to.
struct Planted {
    name: &'static str,
    refusal: Refusal,
    kept: Vec<(PathBuf, &'static str)>,
    #[cfg_attr(
        not(unix),
        allow(dead_code, reason = "set only by the permission-bit rows")
    )]
    restore: Option<PathBuf>,
    listed: Option<(Vec<&'static str>, PathBuf)>,
}

/// One row per shape a plain skill's slot can already be in, at the global
/// scope, where the local source is a plain skill's destination (a
/// project's plain skill is its own source in `.agents`). Every row plants
/// one layout, has Claude hold a plain skill of the name, and asks
/// adoption to keep it; the refusal is the collision's or the read's, the
/// stored bytes are still there, nothing reached the trash, and where the
/// source is asked afterwards it still offers the stored item under its
/// own name.
///
/// The rows that fail the occupancy READ are as much the point as the
/// rows that find an occupant: a read that fails is not an answer of "the
/// slot is free". A slot past the sealed reader's listing bound, a slot
/// wider than the descendant search's entry budget, and a kind directory
/// past the bound are refused as the bound's, since nothing else in those
/// rows would refuse. A POSIX directory can be searchable and writable
/// without being listable (mode 0311, or an ACL), and a child can be
/// listable but not traversable (mode 000): both keep the nested skill
/// reachable while the scan sees nothing, and read as empty they would
/// hand the capture the occupied slot. Root reads and traverses any
/// directory whatever its mode, so there the denial does not exist and
/// those two rows expect the ordinary collision instead.
#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one table: twelve slot layouts refused by one adopt call, each row a layout of its own"
)]
fn a_plain_skill_over_an_occupied_or_unreadable_slot_refuses() {
    type Plant = fn(&Env, &Path) -> Planted;
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut rows: Vec<(&str, Plant)> = vec![
        // `data-science/eda` is stored at `<local>/skills/data-science`, so
        // the slot a plain `data-science` asks for is the directory
        // holding it — and the slot existing is not a previous copy of
        // `data-science`, a name the local source lists nowhere. The
        // declaration still resolves to content that is there.
        ("the namespaced one stored there", |env, home| {
            adopt_claude_skill(
                env,
                home,
                "data-science__eda",
                "data-science/eda",
                "the namespaced one",
            );
            let root = crate::source::local_source_root(env, &Scope::Global);
            Planted {
                name: "data-science",
                refusal: Refusal::Occupant("skills/data-science/eda"),
                kept: vec![(
                    root.join("skills/data-science/eda/SKILL.md"),
                    "the namespaced one",
                )],
                restore: None,
                listed: Some((
                    vec!["data-science/eda"],
                    root.join("skills/data-science/eda"),
                )),
            }
        }),
        // The spelling half of the same collision. A macOS or Windows
        // volume hands `Data-Science` and `data-science` to one directory,
        // so the stored `Data-Science/eda` sits in the slot a plain
        // `data-science` asks for even though the two names differ
        // character by character. The refusal reads both sides under
        // `names::fold`, a fact about the names rather than about the host
        // running the test, so it holds here too.
        ("a differently cased namespaced one", |env, home| {
            adopt_claude_skill(
                env,
                home,
                "Data-Science__eda",
                "Data-Science/eda",
                "the namespaced one",
            );
            let root = crate::source::local_source_root(env, &Scope::Global);
            Planted {
                name: "data-science",
                refusal: Refusal::Occupant("skills/Data-Science/eda"),
                kept: vec![(
                    root.join("skills/Data-Science/eda/SKILL.md"),
                    "the namespaced one",
                )],
                restore: None,
                listed: Some((
                    vec!["Data-Science/eda"],
                    root.join("skills/Data-Science/eda"),
                )),
            }
        }),
        // The directory holding `data-science/eda` is past the bound the
        // sealed reader lists within, so the listing the guard asks for
        // cannot be made. A local source that declares its own layout is
        // the shape that reaches this: without a control file the search
        // table walks the same directory first and refuses there.
        ("a slot whose listing fails", |env, home| {
            adopt_claude_skill(
                env,
                home,
                "data-science__eda",
                "data-science/eda",
                "the namespaced one",
            );
            let root = crate::source::local_source_root(env, &Scope::Global);
            fs::write(root.join("kendex.toml"), "schema = 6\n").unwrap();
            let stored = root.join("skills/data-science");
            for n in 0..4_096 {
                fs::create_dir(stored.join(format!("filler-{n:04}"))).unwrap();
            }
            Planted {
                name: "data-science",
                refusal: Refusal::Bound(
                    stored.clone(),
                    "more than 4096 entries in one catalog directory".to_owned(),
                ),
                kept: vec![(stored.join("eda/SKILL.md"), "the namespaced one")],
                restore: None,
                listed: None,
            }
        }),
        // A local source whose own config will not parse offers nothing
        // at all — every listing of it is empty, and an empty listing is
        // not an empty directory. The skill stored in the slot is stored
        // there either way.
        ("a slot in an unreadable local source", |env, _| {
            let stored = store_local_skill(env, "data-science/eda", "the namespaced one");
            let root = crate::source::local_source_root(env, &Scope::Global);
            fs::write(root.join("kendex.toml"), "schema = [").unwrap();
            Planted {
                name: "data-science",
                refusal: Refusal::Occupant("skills/data-science/eda"),
                kept: vec![(stored.join("SKILL.md"), "the namespaced one")],
                restore: None,
                listed: None,
            }
        }),
        // A catalog that declares where its skills live: `skills/data-science`
        // is this source's skill directory, so what it stores is listed as
        // `foo/eda` — a name whose plugin half is not the slot's, and whose
        // path is inside the slot regardless.
        ("a slot holding a differently named item", |env, _| {
            let stored = store_local_skill(env, "data-science/foo/eda", "the stored one");
            let root = crate::source::local_source_root(env, &Scope::Global);
            fs::write(
                root.join("kendex.toml"),
                "[catalog]\nskills = [\"skills/data-science\"]\n",
            )
            .unwrap();
            Planted {
                name: "data-science",
                refusal: Refusal::Occupant("skills/data-science/foo"),
                kept: vec![(stored.join("SKILL.md"), "the stored one")],
                restore: None,
                listed: None,
            }
        }),
        // The same catalog with the slot holding a plain skill of its own,
        // which makes the slot replaceable rather than empty. Its one
        // immediate child, `foo`, is no item — the item is `foo/eda`, a
        // level further down, which is where a declared catalog directory
        // legitimately keeps it. A search that stops at the children
        // reports the slot free and the capture takes the stored item with
        // the directory.
        ("an item stored deeper in its slot", |env, _| {
            let stored = store_local_skill(env, "data-science/foo/eda", "the stored one");
            store_local_skill(env, "data-science", "the earlier plain one");
            let root = crate::source::local_source_root(env, &Scope::Global);
            fs::write(
                root.join("kendex.toml"),
                "[catalog]\nskills = [\"skills/data-science\"]\n",
            )
            .unwrap();
            Planted {
                name: "data-science",
                refusal: Refusal::Occupant("skills/data-science/foo/eda"),
                kept: vec![(stored.join("SKILL.md"), "the stored one")],
                restore: None,
                listed: Some((vec!["foo/eda"], stored)),
            }
        }),
        // The descendant search looks at a bounded number of entries, and
        // a slot wider than that bound is one it has not finished looking
        // at. Nothing is stored under this slot but the earlier copy's own
        // filler, one entry past the budget counting its SKILL.md.
        ("a slot too wide to search", |env, _| {
            let stored = store_local_skill(env, "data-science", "the earlier plain one");
            for n in 0..crate::source_read::TREE_BOUND.files {
                fs::create_dir(stored.join(format!("filler-{n:04}"))).unwrap();
            }
            Planted {
                name: "data-science",
                refusal: Refusal::Bound(
                    stored.clone(),
                    format!(
                        "more than {} entries under one slot — cannot tell what is stored there",
                        crate::source_read::TREE_BOUND.files
                    ),
                ),
                kept: vec![(stored.join("SKILL.md"), "the earlier plain one")],
                restore: None,
                listed: None,
            }
        }),
        // A listing skips a `tests` directory wherever it finds one — the
        // support vocabulary a browse row is drawn through, since files
        // there are about the items rather than items. A legal `tests/foo`
        // is therefore a skill no listing names, and it occupies the plain
        // `tests` slot all the same.
        ("a slot no listing names", |env, _| {
            let stored = store_local_skill(env, "tests/foo", "the namespaced one");
            Planted {
                name: "tests",
                refusal: Refusal::Occupant("skills/tests/foo"),
                kept: vec![(stored.join("SKILL.md"), "the namespaced one")],
                restore: None,
                listed: None,
            }
        }),
        // A plain item and a namespaced one legitimately share one
        // directory: `skills/plugin/SKILL.md` beside
        // `skills/plugin/item/SKILL.md`, both listed and both resolved. So
        // the slot being the plain item makes it replaceable, not empty —
        // the capture replaces the plain item's own files, and
        // `plugin/item` is a second item it would take with it.
        ("itself beside a namespaced one", |env, _| {
            let plain = store_local_skill(env, "plugin", "the earlier plain one");
            let nested = store_local_skill(env, "plugin/item", "the namespaced one");
            Planted {
                name: "plugin",
                refusal: Refusal::Occupant("skills/plugin/item"),
                kept: vec![
                    (nested.join("SKILL.md"), "the namespaced one"),
                    (plain.join("SKILL.md"), "the earlier plain one"),
                ],
                restore: None,
                listed: None,
            }
        }),
        // The parent scan is a read of a source, so it carries the reader's
        // work bound like every other one. A kind directory past the bound
        // is refused rather than scanned, which also keeps adoption from
        // writing into a source that discovery will later refuse to read
        // back. Nothing here is stored in the slot.
        ("a parent past the entry bound", |env, _| {
            let unrelated = store_local_skill(env, "unrelated", "somebody else's");
            let kind_dir = crate::source::local_source_root(env, &Scope::Global).join("skills");
            for n in 0..4_096 {
                fs::create_dir(kind_dir.join(format!("filler-{n:04}"))).unwrap();
            }
            assert!(!kind_dir.join("data-science").exists());
            Planted {
                name: "data-science",
                refusal: Refusal::Bound(
                    kind_dir,
                    "more than 4096 entries in one catalog directory".to_owned(),
                ),
                kept: vec![(unrelated.join("SKILL.md"), "somebody else's")],
                restore: None,
                listed: None,
            }
        }),
    ];
    #[cfg(unix)]
    rows.extend([
        // The parent is searchable and writable but not listable.
        (
            "a parent that will not enumerate",
            (|env, _| {
                use std::os::unix::fs::PermissionsExt;
                let stored = store_local_skill(env, "data-science/eda", "the namespaced one");
                let root = crate::source::local_source_root(env, &Scope::Global);
                fs::write(root.join("kendex.toml"), "schema = 6\n").unwrap();
                let kind_dir = root.join("skills");
                fs::set_permissions(&kind_dir, fs::Permissions::from_mode(0o311)).unwrap();
                let refusal = match fs::read_dir(&kind_dir).is_err() {
                    true => Refusal::Unreadable(kind_dir.clone()),
                    false => Refusal::Occupant("skills/data-science/eda"),
                };
                Planted {
                    name: "data-science",
                    refusal,
                    kept: vec![(stored.join("SKILL.md"), "the namespaced one")],
                    restore: Some(kind_dir),
                    listed: None,
                }
            }) as Plant,
        ),
        // `plugin/item` sits beside the plain `plugin`, and its directory
        // can be listed but not traversed, so the `SKILL.md` probe into it
        // fails; the refusal names the probe it could not make, not the
        // slot.
        (
            "a child that cannot be probed",
            (|env, _| {
                use std::os::unix::fs::PermissionsExt;
                store_local_skill(env, "plugin", "the earlier plain one");
                let nested = store_local_skill(env, "plugin/item", "the namespaced one");
                fs::set_permissions(&nested, fs::Permissions::from_mode(0o000)).unwrap();
                let refusal = match fs::metadata(nested.join("SKILL.md")).is_err() {
                    true => Refusal::Unreadable(nested.join("SKILL.md")),
                    false => Refusal::Occupant("skills/plugin/item"),
                };
                Planted {
                    name: "plugin",
                    refusal,
                    kept: vec![(nested.join("SKILL.md"), "the namespaced one")],
                    restore: Some(nested),
                    listed: None,
                }
            }) as Plant,
        ),
    ]);

    for (label, plant) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let env = Env::fake(&home, FakeOs::Linux);
        let planted = plant(&env, &home);
        hold_claude_skill(&home, planted.name, "the plain one");
        let trashed = || fs::read_dir(env.trash_dir()).map_or(0, Iterator::count);
        let before = trashed();

        // The mode goes back before anything can panic: a directory left
        // unreadable outlives the TempDir that cannot remove it.
        let outcome = adopt(
            &env,
            &Scope::Global,
            ItemKind::Skill,
            planted.name,
            &[HarnessId::Claude],
        );
        #[cfg(unix)]
        if let Some(path) = &planted.restore {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
        }
        let refused = outcome.unwrap_err();

        match (&planted.refusal, &refused) {
            (Refusal::Occupant(held), CoreError::AdoptNameUnusable { name, problem }) => {
                assert_eq!(name, planted.name, "{label}");
                assert_eq!(
                    problem,
                    &format!("`{held}` is stored here, and this name would be written over it"),
                    "{label}"
                );
            }
            (Refusal::Bound(at, why), CoreError::SourceEscape { path, reason }) => {
                assert_eq!(path, at, "{label}");
                assert_eq!(reason, why, "{label}");
            }
            (Refusal::Unreadable(at), CoreError::Io { path, .. }) => {
                assert_eq!(path, at, "{label}");
            }
            (expected, got) => panic!("{label}: expected {expected:?}, got {got:?}"),
        }
        for (path, body) in &planted.kept {
            assert_eq!(&fs::read_to_string(path).unwrap(), body, "{label}");
        }
        assert_eq!(trashed(), before, "{label}");
        if let Some((listed, at)) = &planted.listed {
            assert_eq!(&listed_skills(&env), listed, "{label}");
            assert_eq!(found_skill(&env, listed[0]).as_ref(), Some(at), "{label}");
        }
    }
}

/// The must-fail half: what the descendant search must NOT call an
/// occupant. A slot that is an empty directory holds nothing, and the
/// earlier copy of the name being kept holds only its own supporting tree,
/// which the capture is written over — the search descends through every
/// level of that tree and finds no item there, so both adoptions land. A
/// guard that refuses these refuses every re-adopt.
#[test]
fn a_plain_skill_over_a_slot_holding_nothing_of_its_own_lands() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let stored = store_local_skill(&env, "handmade", "the earlier one");
    fs::create_dir_all(stored.join("references/deep/deeper")).unwrap();
    fs::write(stored.join("references/deep/deeper/notes.md"), "supporting").unwrap();
    fs::create_dir_all(stored.join("scripts")).unwrap();
    fs::write(stored.join("scripts/run.sh"), "#!/bin/sh\n").unwrap();
    let vacant = crate::source::local_source_root(&env, &Scope::Global).join("skills/vacant");
    fs::create_dir_all(&vacant).unwrap();

    for (name, body) in [("handmade", "the newer one"), ("vacant", "a first copy")] {
        adopt_claude_skill(&env, &home, name, name, body);
    }

    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the newer one"
    );
    assert_eq!(
        fs::read_to_string(vacant.join("SKILL.md")).unwrap(),
        "a first copy"
    );
}

/// A slot holding this very name is not a collision. The plain item stored
/// there is a previous copy of the name being kept, and replacing it is
/// what a capture over it is for — the refusal above is the collision's,
/// not a refusal of every plain name whose slot exists.
#[test]
fn a_plain_skill_over_an_earlier_copy_of_itself_lands() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let stored = store_local_skill(&env, "handmade", "the earlier one");

    adopt_claude_skill(&env, &home, "handmade", "handmade", "the newer one");

    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the newer one"
    );
}
