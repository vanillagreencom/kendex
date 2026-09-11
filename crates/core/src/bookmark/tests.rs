//! What a bookmark records, what two spellings of one marketplace do to
//! it, and what it says about itself once the marketplace it names has
//! moved on.

use std::fs;
use std::path::{Path, PathBuf};

use super::*;
use crate::env::FakeOs;
use crate::model::{ItemKind, Scope};
use crate::source::browse::Catalog;
use crate::test_util::{rooted, source_path};

/// A machine with one folder marketplace on it, subscribed personally. The
/// catalog offers one skill and one curated set, which is every shape a
/// bookmark can name.
struct Machine {
    /// Kept so the fixture outlives the test that holds it.
    _tmp: tempfile::TempDir,
    home: PathBuf,
    env: Env,
    catalog: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn machine() -> Machine {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let catalog = home.join("catalog");
    let skill = catalog.join("skills/gh");
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        "---\nname: gh\ndescription: about gh\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        catalog.join("kendex.toml"),
        "[marketplace]\nname = \"cat\"\n\n[bundles.starter]\nskills = [\"gh\"]\n",
    )
    .unwrap();
    Machine {
        _tmp: tmp,
        home,
        env,
        catalog,
    }
}

/// Declare the catalog as a personal subscription under this alias.
#[allow(clippy::unwrap_used)]
fn subscribe(machine: &Machine, alias: &str) {
    write_manifest(
        &crate::manifest::manifest_path(&machine.env, &Scope::Global),
        alias,
        &machine.catalog,
    );
}

/// A registered project that subscribes to the same catalog under its own
/// alias — the shape that proves a bookmark is not keyed by an alias.
#[allow(clippy::unwrap_used)]
fn project_subscribing(machine: &Machine, name: &str, alias: &str) -> PathBuf {
    let root = machine.home.join(name);
    fs::create_dir_all(&root).unwrap();
    let root = crate::paths::canonical(&root).unwrap();
    write_manifest(
        &crate::manifest::manifest_path(&machine.env, &Scope::Project { root: root.clone() }),
        alias,
        &machine.catalog,
    );
    crate::settings::register_project(&machine.env, &root).unwrap();
    root
}

#[allow(clippy::unwrap_used)]
fn write_manifest(path: &Path, alias: &str, catalog: &Path) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        path,
        format!("schema = 6\n[sources.{alias}]\n{}\n", source_path(catalog)),
    )
    .unwrap();
}

fn package(repo: &str, kind: ItemKind, name: &str) -> Bookmark {
    Bookmark {
        repo: repo.to_owned(),
        item: BookmarkItem::Package { kind },
        name: name.to_owned(),
    }
}

fn set(repo: &str, name: &str) -> Bookmark {
    Bookmark {
        repo: repo.to_owned(),
        item: BookmarkItem::Bundle,
        name: name.to_owned(),
    }
}

/// A personal scope that removed the default marketplace: a manifest that
/// exists and subscribes to nothing, so the machine's subscriptions are
/// exactly what the projects declare.
#[allow(clippy::unwrap_used)]
fn personal_without_default(env: &Env) {
    let path = crate::manifest::manifest_path(env, &Scope::Global);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, "schema = 6\n").unwrap();
}

/// A fake home with nothing on it, for the index cases that need no
/// catalog.
#[allow(clippy::unwrap_used)]
fn bare() -> (tempfile::TempDir, Env) {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let env = Env::fake(&root, FakeOs::Linux);
    (tmp, env)
}

/// What is saved survives the write and the read, in every shape a
/// bookmark can take, and the same file answers whichever process asks —
/// the window and the command line call these same functions.
#[test]
#[allow(clippy::unwrap_used)]
fn what_is_saved_reads_back_whole() {
    let (_tmp, env) = bare();
    let saved = [
        package("vanillagreencom/kendex", ItemKind::Skill, "gh"),
        package("vanillagreencom/kendex", ItemKind::McpServer, "gh"),
        set("vanillagreencom/kendex", "starter"),
        package("../catalog", ItemKind::Agent, "gh"),
    ];
    for one in &saved {
        add(&env, one.clone()).unwrap();
    }
    assert_eq!(list(&env).unwrap(), saved.to_vec());

    // A second reader on the same file — the command line's read after the
    // window's write — sees exactly what was written, from disk.
    let again = Env::fake(&env.home, FakeOs::Linux);
    assert_eq!(list(&again).unwrap(), saved.to_vec());
    assert!(env.bookmarks_file().is_file());
}

/// Two spellings of one repository are one bookmark, and the same name in
/// two marketplaces is two.
#[test]
#[allow(clippy::unwrap_used)]
fn one_repository_spelled_two_ways_is_one_bookmark() {
    let (_tmp, env) = bare();
    for repo in [
        "vanillagreencom/kendex",
        "https://github.com/VanillaGreenCom/kendex.git",
        "git@github.com:vanillagreencom/kendex",
    ] {
        let saved = add(&env, package(repo, ItemKind::Skill, "gh")).unwrap();
        // A save hands back what the index holds, so a confirmation names
        // the spelling that is stored rather than the one just typed.
        assert_eq!(saved.repo, "vanillagreencom/kendex", "saving {repo}");
    }
    let held = list(&env).unwrap();
    assert_eq!(held.len(), 1, "{held:?}");
    // The first spelling stands: a later save of the same item is the same
    // bookmark, not a re-spelling of the one already there.
    assert_eq!(held[0].repo, "vanillagreencom/kendex");

    // Removing it through a third spelling reaches it, because the removal
    // folds the same way the save did.
    remove(
        &env,
        &package(
            "HTTPS://GitHub.com/vanillagreencom/kendex/",
            ItemKind::Skill,
            "gh",
        ),
    )
    .unwrap();
    assert_eq!(list(&env).unwrap(), Vec::new());
}

/// The same kind and name from two marketplaces are two bookmarks, and
/// removing one leaves the other.
#[test]
#[allow(clippy::unwrap_used)]
fn the_same_name_in_two_marketplaces_stays_two_bookmarks() {
    let (_tmp, env) = bare();
    add(&env, package("one/cat", ItemKind::Skill, "gh")).unwrap();
    add(&env, package("two/cat", ItemKind::Skill, "gh")).unwrap();
    // And a curated set of that name is a third thing again: the item type
    // is part of what a bookmark is.
    add(&env, set("one/cat", "gh")).unwrap();
    assert_eq!(list(&env).unwrap().len(), 3);

    remove(&env, &package("one/cat", ItemKind::Skill, "gh")).unwrap();
    let left = list(&env).unwrap();
    assert_eq!(
        left,
        vec![
            package("two/cat", ItemKind::Skill, "gh"),
            set("one/cat", "gh")
        ]
    );
}

/// A bookmark nothing saved cannot be removed, and the refusal names it.
#[test]
#[allow(clippy::unwrap_used)]
fn removing_something_that_was_never_saved_refuses() {
    let (_tmp, env) = bare();
    assert!(matches!(
        remove(&env, &package("one/cat", ItemKind::Skill, "gh")),
        Err(CoreError::NoSuchBookmark { .. })
    ));
}

/// A bookmark naming nothing is refused where it is offered and refused
/// again where it is read back, so a hand-edited file cannot put a row on
/// screen that no control can act on.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bookmark_naming_nothing_is_refused_both_ways() {
    let (_tmp, env) = bare();
    for unusable in [
        package("one/cat", ItemKind::Skill, "  "),
        package("  ", ItemKind::Skill, "gh"),
    ] {
        assert!(
            matches!(
                add(&env, unusable.clone()),
                Err(CoreError::BookmarkUnusable { .. })
            ),
            "{unusable:?} was saved"
        );
    }
    // The inverse: what a surface really saves is admitted, or the rows
    // above would pass over a rule that refuses everything.
    add(&env, package("one/cat", ItemKind::Skill, "gh")).unwrap();

    fs::write(
        env.bookmarks_file(),
        "[[bookmarks]]\nrepo = \"one/cat\"\nname = \"\"\n\n[bookmarks.item]\nis = \"bundle\"\n",
    )
    .unwrap();
    assert!(matches!(
        list(&env),
        Err(CoreError::BookmarkIndexUnusable { .. })
    ));
}

/// Saving and forgetting touch the bookmark file and nothing else: no
/// install, no subscription, no other preference.
#[test]
#[allow(clippy::unwrap_used)]
fn saving_and_forgetting_change_nothing_but_the_bookmark_file() {
    let machine = machine();
    subscribe(&machine, "cat");
    let mut settings = crate::settings::load(&machine.env).unwrap();
    settings.appearance = crate::settings::Appearance::Dark;
    let base = crate::settings::read_for_mutation(&machine.env).unwrap().1;
    crate::settings::replace(&machine.env, &settings, &base).unwrap();

    let before = snapshot(&machine.home);
    let saved = package("../catalog", ItemKind::Skill, "gh");
    add(&machine.env, saved.clone()).unwrap();
    remove(&machine.env, &saved).unwrap();
    let after = snapshot(&machine.home);

    let bookmarks = crate::paths::slashed(
        machine
            .env
            .bookmarks_file()
            .strip_prefix(&machine.home)
            .unwrap(),
    );
    // The file itself, and the lock beside it that every writer of a
    // personal file takes.
    let changed: Vec<&String> = after
        .keys()
        .filter(|path| before.get(*path) != after.get(*path))
        .filter(|path| **path != format!("{bookmarks}.lock"))
        .collect();
    assert_eq!(changed, vec![&bookmarks], "{changed:?}");
    assert_eq!(
        crate::settings::load(&machine.env).unwrap().appearance,
        crate::settings::Appearance::Dark,
        "an unrelated preference was rewritten"
    );
}

/// A saved item resolves through whichever subscription carries its
/// marketplace, whatever alias that subscription was declared under and
/// whichever place declared it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_saved_item_resolves_through_the_subscription_that_carries_it() {
    let machine = machine();
    let root = project_subscribing(&machine, "app", "their-name-for-it");
    add(
        &machine.env,
        package(
            &crate::paths::slashed(&machine.catalog),
            ItemKind::Skill,
            "gh",
        ),
    )
    .unwrap();
    add(
        &machine.env,
        set(&crate::paths::slashed(&machine.catalog), "starter"),
    )
    .unwrap();

    let resolved = resolve(&machine.env).unwrap();
    assert_eq!(resolved.len(), 2, "{resolved:?}");
    for item in &resolved {
        assert_eq!(item.reach, Reach::Offered, "{item:?}");
        assert_eq!(
            item.catalog,
            Some(Catalog::Subscription {
                scope: Scope::Project { root: root.clone() },
                source: "their-name-for-it".to_owned(),
            }),
            "{item:?}"
        );
    }

    // The personal subscription is read first once it exists, because that
    // is the order the declarations are walked in.
    subscribe(&machine, "mine");
    let resolved = resolve(&machine.env).unwrap();
    assert_eq!(
        resolved[0].catalog,
        Some(Catalog::Subscription {
            scope: Scope::Global,
            source: "mine".to_owned(),
        }),
        "{resolved:?}"
    );
}

/// A folder is the directory it resolves to from the place declaring it,
/// never its spelling: two projects each declaring `catalog` are two
/// marketplaces, and the item saved from each resolves through that
/// project's own subscription and reads that project's own directory. A
/// declaration spelled `./catalog` or `catalog/` is the directory the saved
/// `catalog` names.
#[test]
#[allow(clippy::unwrap_used)]
fn one_relative_folder_declared_in_two_places_is_two_marketplaces() {
    let machine = machine();
    personal_without_default(&machine.env);
    let mut expected = Vec::new();
    for (project, offered, spelled) in [
        ("alpha", "only-alpha", "./catalog"),
        ("beta", "only-beta", "catalog/"),
    ] {
        let root = machine.home.join(project);
        let skill = root.join("catalog/skills").join(offered);
        fs::create_dir_all(&skill).unwrap();
        fs::write(
            skill.join("SKILL.md"),
            format!("---\nname: {offered}\ndescription: about {offered}\n---\nBody.\n"),
        )
        .unwrap();
        let root = crate::paths::canonical(&root).unwrap();
        fs::write(
            crate::manifest::manifest_path(&machine.env, &Scope::Project { root: root.clone() }),
            format!("schema = 6\n[sources.catalog]\npath = \"{spelled}\"\n"),
        )
        .unwrap();
        crate::settings::register_project(&machine.env, &root).unwrap();
        let folder = crate::paths::slashed(&root.join("catalog"));
        add(&machine.env, package(&folder, ItemKind::Skill, offered)).unwrap();
        expected.push((root, folder));
    }

    let identities: Vec<String> = crate::source_ops::subscriptions(&machine.env)
        .unwrap()
        .into_iter()
        .map(|row| row.repo_identity)
        .collect();
    let folders: Vec<String> = expected
        .iter()
        .map(|(_, folder)| crate::source_ref::repo_identity(folder))
        .collect();
    assert_eq!(identities, folders);

    let resolved = resolve(&machine.env).unwrap();
    assert_eq!(resolved.len(), 2, "{resolved:?}");
    for ((root, _), item) in expected.iter().zip(&resolved) {
        // Offered is the proof of which directory was read: each project's
        // folder offers a skill the other does not.
        assert_eq!(item.reach, Reach::Offered, "{item:?}");
        assert_eq!(
            item.catalog,
            Some(Catalog::Subscription {
                scope: Scope::Project { root: root.clone() },
                source: "catalog".to_owned(),
            }),
            "{item:?}"
        );
    }
}

/// A package the marketplace has dropped keeps its row, says so, and is
/// told apart from a marketplace that will not read at all — the two have
/// different remedies.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dropped_package_and_an_unreadable_marketplace_are_different_answers() {
    let machine = machine();
    subscribe(&machine, "cat");
    let repo = crate::paths::slashed(&machine.catalog);
    add(&machine.env, package(&repo, ItemKind::Skill, "gone")).unwrap();

    let resolved = resolve(&machine.env).unwrap();
    let Reach::NotOffered { why } = &resolved[0].reach else {
        panic!("a dropped package should say so: {resolved:?}");
    };
    assert!(why.contains("no longer offers"), "{why}");
    // The row is still there, still naming what was saved.
    assert_eq!(resolved[0].bookmark.name, "gone");

    // The marketplace itself gone is the other answer: nothing is claimed
    // about the package, because nothing read the catalog.
    fs::remove_dir_all(&machine.catalog).unwrap();
    let resolved = resolve(&machine.env).unwrap();
    assert!(
        matches!(resolved[0].reach, Reach::Unavailable { .. }),
        "{resolved:?}"
    );
    assert_eq!(resolved[0].bookmark.name, "gone");
    assert_eq!(list(&machine.env).unwrap().len(), 1);

    // A marketplace that is there but whose own config will not read is
    // that answer too, in the config's own words, for a package and a set
    // alike: a lookup in it finds nothing, whatever it offers.
    fs::create_dir_all(&machine.catalog).unwrap();
    fs::write(machine.catalog.join("kendex.toml"), "[marketplace\n").unwrap();
    add(&machine.env, set(&repo, "starter")).unwrap();
    let sealed = crate::source_read::SealedSource::open(&machine.catalog).unwrap();
    let why = crate::source::source_config(&sealed, "catalog")
        .unwrap()
        .hidden_content()
        .unwrap();
    let resolved = resolve(&machine.env).unwrap();
    assert_eq!(resolved.len(), 2, "{resolved:?}");
    for saved in &resolved {
        assert_eq!(
            saved.reach,
            Reach::Unavailable { why: why.clone() },
            "{:?}",
            saved.bookmark
        );
    }
}

/// A marketplace nothing here subscribes to is not a failure: a repository
/// is still addressable, and a folder nobody declares is not.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unsubscribed_marketplace_is_addressable_only_as_a_repository() {
    let (_tmp, env) = bare();
    add(&env, package("acme/tools", ItemKind::Skill, "gh")).unwrap();
    add(&env, package("/somewhere/else", ItemKind::Skill, "gh")).unwrap();

    let resolved = resolve(&env).unwrap();
    assert_eq!(resolved[0].reach, Reach::Unsubscribed, "{resolved:?}");
    assert_eq!(
        resolved[0].catalog,
        Some(Catalog::Repo {
            repo: "acme/tools".to_owned(),
        })
    );
    assert!(
        matches!(resolved[1].reach, Reach::Unavailable { .. }),
        "{resolved:?}"
    );
    assert_eq!(resolved[1].catalog, None);
}

/// The vocabulary a saved item is named by, in both directions.
#[test]
#[allow(clippy::unwrap_used)]
fn every_kind_the_model_has_can_be_named_and_a_word_it_lacks_cannot() {
    for kind in ItemKind::ALL {
        assert_eq!(
            BookmarkItem::parse(kind.name()).unwrap(),
            BookmarkItem::Package { kind },
            "{}",
            kind.name()
        );
    }
    assert_eq!(BookmarkItem::parse("bundle").unwrap(), BookmarkItem::Bundle);
    assert!(matches!(
        BookmarkItem::parse("skills"),
        Err(CoreError::BookmarkUnusable { .. })
    ));
}

/// Every byte under a root, so a machine can be compared with itself.
#[allow(clippy::unwrap_used)]
fn snapshot(root: &Path) -> std::collections::BTreeMap<String, Vec<u8>> {
    let mut held = std::collections::BTreeMap::new();
    walk(root, root, &mut held);
    held
}

#[allow(clippy::unwrap_used)]
fn walk(root: &Path, dir: &Path, into: &mut std::collections::BTreeMap<String, Vec<u8>>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && !path.is_symlink() {
            walk(root, &path, into);
            continue;
        }
        into.insert(
            crate::paths::slashed(path.strip_prefix(root).unwrap()),
            fs::read(&path).unwrap_or_default(),
        );
    }
}
