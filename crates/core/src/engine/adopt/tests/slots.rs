//! What a plain name's slot in the local source already holds. A plain
//! name and a namespaced one share one directory — `plugin` is the
//! directory `plugin/item` is stored in — so a capture written at the
//! plain slot can take a namespaced item with it. Every test here asks
//! what the slot holds and what the refusal leaves on disk.

use super::super::*;
use crate::env::FakeOs;
use std::fs;

use crate::test_util::rooted;

use super::trash_is_empty;

/// The same nesting from the other side, and the direction that used to
/// delete. `data-science/eda` is stored at `<local>/skills/data-science`,
/// so the slot a plain `data-science` asks for is the directory holding
/// it — and the slot existing is not an earlier copy of `data-science`,
/// a name the local source lists nowhere. A project's plain skill is its
/// own source in `.agents`, so the local source is a plain skill's
/// destination only at the global scope.
#[test]
fn a_plain_skill_over_the_namespaced_one_stored_there_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Global;
    let held = home.join(".claude/skills");
    fs::create_dir_all(held.join("data-science__eda")).unwrap();
    fs::write(
        held.join("data-science__eda/SKILL.md"),
        "the namespaced one",
    )
    .unwrap();
    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan).unwrap();

    fs::create_dir_all(held.join("data-science")).unwrap();
    fs::write(held.join("data-science/SKILL.md"), "the plain one").unwrap();
    let trashed = || fs::read_dir(env.trash_dir()).map_or(0, Iterator::count);
    let before = trashed();
    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science",
        &[HarnessId::Claude],
    )
    .unwrap_err()
    .to_string();

    assert!(refused.contains("data-science/eda"), "{refused:?}");
    // The local source still offers the namespaced skill under its own
    // name, and the declaration still resolves to content that is there.
    let root = crate::source::local_source_root(&env, &scope);
    let sealed = crate::source_read::SealedSource::open(&root).unwrap();
    let config = crate::source::source_config_for(&sealed, LOCAL_SOURCE_NAME).unwrap();
    assert_eq!(
        crate::source::list_items(&sealed, &config, ItemKind::Skill),
        ["data-science/eda"]
    );
    let manifest =
        crate::manifest::load_for_mutation(&crate::manifest::manifest_path(&env, &scope))
            .unwrap()
            .unwrap();
    assert_eq!(
        manifest.declared(ItemKind::Skill)["data-science/eda"].source,
        LOCAL_SOURCE_NAME
    );
    assert_eq!(
        crate::source::find_item(&sealed, &config, ItemKind::Skill, "data-science/eda"),
        Some(root.join("skills/data-science/eda"))
    );
    assert_eq!(
        fs::read_to_string(root.join("skills/data-science/eda/SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert_eq!(trashed(), before);

    // The refusal is the collision's, not a refusal of every plain name:
    // one whose slot holds nothing is still kept.
    fs::create_dir_all(held.join("handmade")).unwrap();
    fs::write(held.join("handmade/SKILL.md"), "mine").unwrap();
    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan).unwrap();
    assert!(root.join("skills/handmade/SKILL.md").is_file());
}

/// The spelling half of the same collision. A macOS or Windows volume
/// hands `Data-Science` and `data-science` to one directory, so the stored
/// `Data-Science/eda` sits in the slot a plain `data-science` asks for even
/// though the two names differ character by character. The refusal reads
/// both sides under `names::fold`, which is a fact about the names rather
/// than about the host running the test, so it holds here too.
#[test]
fn a_plain_skill_over_a_differently_cased_namespaced_one_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Global;
    let held = home.join(".claude/skills");
    fs::create_dir_all(held.join("Data-Science__eda")).unwrap();
    fs::write(
        held.join("Data-Science__eda/SKILL.md"),
        "the namespaced one",
    )
    .unwrap();
    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "Data-Science/eda",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan).unwrap();

    fs::create_dir_all(held.join("data-science")).unwrap();
    fs::write(held.join("data-science/SKILL.md"), "the plain one").unwrap();
    let trashed = || fs::read_dir(env.trash_dir()).map_or(0, Iterator::count);
    let before = trashed();
    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science",
        &[HarnessId::Claude],
    )
    .unwrap_err()
    .to_string();

    assert!(refused.contains("Data-Science/eda"), "{refused:?}");
    let root = crate::source::local_source_root(&env, &scope);
    let sealed = crate::source_read::SealedSource::open(&root).unwrap();
    let config = crate::source::source_config_for(&sealed, LOCAL_SOURCE_NAME).unwrap();
    assert_eq!(
        crate::source::list_items(&sealed, &config, ItemKind::Skill),
        ["Data-Science/eda"]
    );
    assert_eq!(
        fs::read_to_string(root.join("skills/Data-Science/eda/SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert_eq!(trashed(), before);
}

/// The occupancy read is a read, and a read that fails is not an answer of
/// "the slot is free". Here the directory holding `data-science/eda` is
/// past the bound the sealed reader lists within, so the listing the guard
/// asks for cannot be made — and adoption refuses instead of trashing what
/// the plain name would land on top of. A local source that declares its
/// own layout is the shape that reaches this: without a control file the
/// search table walks the same directory first and refuses there.
#[test]
fn a_plain_skill_over_a_slot_whose_listing_fails_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let scope = Scope::Global;
    let held = home.join(".claude/skills");
    fs::create_dir_all(held.join("data-science__eda")).unwrap();
    fs::write(
        held.join("data-science__eda/SKILL.md"),
        "the namespaced one",
    )
    .unwrap();
    let plan = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science/eda",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan).unwrap();

    let root = crate::source::local_source_root(&env, &scope);
    fs::write(root.join("kendex.toml"), "schema = 6\n").unwrap();
    let stored = root.join("skills/data-science");
    for n in 0..4_096 {
        fs::create_dir(stored.join(format!("filler-{n:04}"))).unwrap();
    }

    fs::create_dir_all(held.join("data-science")).unwrap();
    fs::write(held.join("data-science/SKILL.md"), "the plain one").unwrap();
    let trashed = || fs::read_dir(env.trash_dir()).map_or(0, Iterator::count);
    let before = trashed();
    let refused = adopt(
        &env,
        &scope,
        ItemKind::Skill,
        "data-science",
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::SourceEscape { .. }),
        "{refused:?}"
    );
    assert_eq!(
        fs::read_to_string(root.join("skills/data-science/eda/SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert_eq!(trashed(), before);
}

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

/// The refusal a plain `name` gets at the global scope, with Claude holding
/// a skill of that name for the capture to take.
fn refuse_plain_skill(env: &Env, home: &Path, name: &str) -> String {
    let held = home.join(".claude/skills").join(name);
    fs::create_dir_all(&held).unwrap();
    fs::write(held.join("SKILL.md"), "the plain one").unwrap();
    adopt(
        env,
        &Scope::Global,
        ItemKind::Skill,
        name,
        &[HarnessId::Claude],
    )
    .unwrap_err()
    .to_string()
}

/// A local source whose own config will not parse offers nothing at all —
/// every listing of it is empty, and an empty listing is not an empty
/// directory. The skill stored in the slot is stored there either way.
#[test]
fn a_plain_skill_over_a_slot_in_an_unreadable_local_source_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let stored = store_local_skill(&env, "data-science/eda", "the namespaced one");
    let root = crate::source::local_source_root(&env, &Scope::Global);
    fs::write(root.join("kendex.toml"), "schema = [").unwrap();

    let refused = refuse_plain_skill(&env, &home, "data-science");

    assert!(refused.contains("data-science/eda"), "{refused:?}");
    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert!(trash_is_empty(&env));
}

/// A catalog that declares where its skills live: `skills/data-science` is
/// this source's skill directory, so what it stores is listed as `foo/eda`
/// — a name whose plugin half is not the slot's, and whose path is inside
/// the slot regardless.
#[test]
fn a_plain_skill_over_a_slot_holding_a_differently_named_item_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let stored = store_local_skill(&env, "data-science/foo/eda", "the stored one");
    let root = crate::source::local_source_root(&env, &Scope::Global);
    fs::write(
        root.join("kendex.toml"),
        "[catalog]\nskills = [\"skills/data-science\"]\n",
    )
    .unwrap();

    let refused = refuse_plain_skill(&env, &home, "data-science");

    assert!(refused.contains("data-science/foo"), "{refused:?}");
    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the stored one"
    );
    assert!(trash_is_empty(&env));
}

/// The same catalog with the slot holding a plain skill of its own, which
/// makes the slot replaceable rather than empty. Its one immediate child,
/// `foo`, is no item — the item is `foo/eda`, a level further down, which
/// is where a declared catalog directory legitimately keeps it. A search
/// that stops at the children reports the slot free and the capture takes
/// the stored item with the directory.
#[test]
fn a_plain_skill_over_an_item_stored_deeper_in_its_slot_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let stored = store_local_skill(&env, "data-science/foo/eda", "the stored one");
    store_local_skill(&env, "data-science", "the earlier plain one");
    let root = crate::source::local_source_root(&env, &Scope::Global);
    fs::write(
        root.join("kendex.toml"),
        "[catalog]\nskills = [\"skills/data-science\"]\n",
    )
    .unwrap();

    let refused = refuse_plain_skill(&env, &home, "data-science");

    assert!(refused.contains("data-science/foo/eda"), "{refused:?}");
    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the stored one"
    );
    // The source still offers the stored item under its own name, so a
    // declaration naming it still resolves to content that is there.
    let sealed = crate::source_read::SealedSource::open(&root).unwrap();
    let config = crate::source::source_config_for(&sealed, LOCAL_SOURCE_NAME).unwrap();
    assert_eq!(
        crate::source::list_items(&sealed, &config, ItemKind::Skill),
        ["foo/eda"]
    );
    assert_eq!(
        crate::source::find_item(&sealed, &config, ItemKind::Skill, "foo/eda"),
        Some(stored)
    );
    assert!(trash_is_empty(&env));
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
        let held = home.join(".claude/skills").join(name);
        fs::create_dir_all(&held).unwrap();
        fs::write(held.join("SKILL.md"), body).unwrap();
        let plan = adopt(
            &env,
            &Scope::Global,
            ItemKind::Skill,
            name,
            &[HarnessId::Claude],
        )
        .unwrap();
        crate::apply::execute(&env, &plan).unwrap();
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

/// The descendant search looks at a bounded number of entries, and a slot
/// wider than that bound is one it has not finished looking at. Not
/// finished is not empty, so adoption refuses. Nothing is stored under this
/// slot but the earlier copy's own filler: the bound is the only reason to
/// refuse, so the refusal is the bound's or it is nobody's.
#[test]
fn a_plain_skill_over_a_slot_too_wide_to_search_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let stored = store_local_skill(&env, "data-science", "the earlier plain one");
    // One entry past the budget, counting the earlier copy's own SKILL.md.
    for n in 0..crate::source_read::TREE_BOUND.files {
        fs::create_dir(stored.join(format!("filler-{n:04}"))).unwrap();
    }

    let held = home.join(".claude/skills/data-science");
    fs::create_dir_all(&held).unwrap();
    fs::write(held.join("SKILL.md"), "the plain one").unwrap();
    let refused = adopt(
        &env,
        &Scope::Global,
        ItemKind::Skill,
        "data-science",
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::SourceEscape { .. }),
        "{refused:?}"
    );
    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the earlier plain one"
    );
    assert!(trash_is_empty(&env));
}

/// A listing skips a `tests` directory wherever it finds one — the support
/// vocabulary a browse row is drawn through, since files there are about the
/// items rather than items. A legal `tests/foo` is therefore a skill no
/// listing names, and it occupies the plain `tests` slot all the same.
#[test]
fn a_plain_skill_over_a_slot_no_listing_names_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let stored = store_local_skill(&env, "tests/foo", "the namespaced one");

    let refused = refuse_plain_skill(&env, &home, "tests");

    assert!(refused.contains("tests/foo"), "{refused:?}");
    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert!(trash_is_empty(&env));
}

/// A slot holding this very name is not a collision. The plain item stored
/// there is an earlier copy of the name being kept, and replacing it is
/// what a capture over it is for — the refusal above is the collision's,
/// not a refusal of every plain name whose slot exists.
#[test]
fn a_plain_skill_over_an_earlier_copy_of_itself_lands() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let stored = store_local_skill(&env, "handmade", "the earlier one");
    let held = home.join(".claude/skills/handmade");
    fs::create_dir_all(&held).unwrap();
    fs::write(held.join("SKILL.md"), "the newer one").unwrap();

    let plan = adopt(
        &env,
        &Scope::Global,
        ItemKind::Skill,
        "handmade",
        &[HarnessId::Claude],
    )
    .unwrap();
    crate::apply::execute(&env, &plan).unwrap();

    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the newer one"
    );
}

/// A plain item and a namespaced one legitimately share one directory:
/// `skills/plugin/SKILL.md` beside `skills/plugin/item/SKILL.md`, both
/// listed and both resolved. So the slot being the plain item makes it
/// replaceable, not empty — the capture replaces the plain item's own
/// files, and `plugin/item` is a second item it would take with it.
#[test]
fn a_plain_skill_over_itself_beside_a_namespaced_one_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let plain = store_local_skill(&env, "plugin", "the earlier plain one");
    let nested = store_local_skill(&env, "plugin/item", "the namespaced one");

    let refused = refuse_plain_skill(&env, &home, "plugin");

    assert!(refused.contains("plugin/item"), "{refused:?}");
    assert_eq!(
        fs::read_to_string(nested.join("SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert_eq!(
        fs::read_to_string(plain.join("SKILL.md")).unwrap(),
        "the earlier plain one"
    );
    assert!(trash_is_empty(&env));
}

/// The occupancy read is a read, and the other way it fails. A POSIX
/// directory can be searchable and writable without being listable — mode
/// 0311, or an ACL — so the slot and the skill nested in it stay reachable
/// while the scan of the parent returns nothing. Reading that nothing as an
/// empty parent reports the occupied slot free, and the capture hashes and
/// trashes what is in it.
#[cfg(unix)]
#[test]
fn a_plain_skill_whose_parent_will_not_enumerate_refuses() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let stored = store_local_skill(&env, "data-science/eda", "the namespaced one");
    let root = crate::source::local_source_root(&env, &Scope::Global);
    fs::write(root.join("kendex.toml"), "schema = 6\n").unwrap();
    let kind_dir = root.join("skills");
    fs::set_permissions(&kind_dir, fs::Permissions::from_mode(0o311)).unwrap();
    // Root reads any directory whatever its mode, so there the denial under
    // test does not exist and the adoption is the ordinary refusal.
    let denied = fs::read_dir(&kind_dir).is_err();

    let held = home.join(".claude/skills/data-science");
    fs::create_dir_all(&held).unwrap();
    fs::write(held.join("SKILL.md"), "the plain one").unwrap();
    let refused = adopt(
        &env,
        &Scope::Global,
        ItemKind::Skill,
        "data-science",
        &[HarnessId::Claude],
    )
    .unwrap_err();
    fs::set_permissions(&kind_dir, fs::Permissions::from_mode(0o755)).unwrap();

    match denied {
        true => assert!(matches!(refused, CoreError::Io { .. }), "{refused:?}"),
        false => assert!(
            refused.to_string().contains("data-science/eda"),
            "{refused}"
        ),
    }
    assert_eq!(
        fs::read_to_string(stored.join("SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert!(trash_is_empty(&env));
}

/// The third shape of the same failure, and the one a boolean probe hides.
/// `plugin/item` sits beside the plain `plugin`, and its directory can be
/// listed but not traversed — mode 000, or an ACL. The `SKILL.md` probe
/// into it fails, and answered as "no item here" the slot reads as holding
/// only the plain skill the capture replaces, so the trash takes the
/// namespaced one with it and leaves its declaration pointing at nothing.
#[cfg(unix)]
#[test]
fn a_plain_skill_over_a_child_that_cannot_be_probed_refuses() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    store_local_skill(&env, "plugin", "the earlier plain one");
    let nested = store_local_skill(&env, "plugin/item", "the namespaced one");
    fs::set_permissions(&nested, fs::Permissions::from_mode(0o000)).unwrap();
    // Root traverses any directory whatever its mode, so there the denial
    // under test does not exist and the refusal is the ordinary one.
    let denied = fs::metadata(nested.join("SKILL.md")).is_err();

    let held = home.join(".claude/skills/plugin");
    fs::create_dir_all(&held).unwrap();
    fs::write(held.join("SKILL.md"), "the plain one").unwrap();
    let refused = adopt(
        &env,
        &Scope::Global,
        ItemKind::Skill,
        "plugin",
        &[HarnessId::Claude],
    )
    .unwrap_err();
    fs::set_permissions(&nested, fs::Permissions::from_mode(0o755)).unwrap();

    match denied {
        // The refusal names the probe it could not make, not the slot.
        true => match &refused {
            CoreError::Io { path, .. } => assert_eq!(path, &nested.join("SKILL.md")),
            other => panic!("expected the unreadable probe, got {other:?}"),
        },
        false => assert!(refused.to_string().contains("plugin/item"), "{refused}"),
    }
    assert_eq!(
        fs::read_to_string(nested.join("SKILL.md")).unwrap(),
        "the namespaced one"
    );
    assert!(trash_is_empty(&env));
}

/// The parent scan is a read of a source, so it carries the reader's work
/// bound like every other one. A kind directory past the bound is refused
/// rather than scanned, which also keeps adoption from writing into a
/// source that discovery will later refuse to read back. Nothing here is
/// stored in the slot: the bound is the only reason to refuse, so the
/// refusal is the bound's or it is nobody's.
#[test]
fn a_plain_skill_whose_parent_is_past_the_entry_bound_refuses() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let unrelated = store_local_skill(&env, "unrelated", "somebody else's");
    let kind_dir = crate::source::local_source_root(&env, &Scope::Global).join("skills");
    for n in 0..4_096 {
        fs::create_dir(kind_dir.join(format!("filler-{n:04}"))).unwrap();
    }
    assert!(!kind_dir.join("data-science").exists());

    let held = home.join(".claude/skills/data-science");
    fs::create_dir_all(&held).unwrap();
    fs::write(held.join("SKILL.md"), "the plain one").unwrap();
    let refused = adopt(
        &env,
        &Scope::Global,
        ItemKind::Skill,
        "data-science",
        &[HarnessId::Claude],
    )
    .unwrap_err();

    assert!(
        matches!(refused, CoreError::SourceEscape { .. }),
        "{refused:?}"
    );
    assert_eq!(
        fs::read_to_string(unrelated.join("SKILL.md")).unwrap(),
        "somebody else's"
    );
    assert!(trash_is_empty(&env));
}
