use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use super::*;
use crate::lock::{
    EmittedArtifact, LOCK_FILE, LOCK_VERSION, Lock, LockEntry, Reason, entry_key, save,
};
use crate::manifest::Method;
use crate::model::{HarnessId, ItemKind};
use crate::package::updates::IgnoredUpdate;
use crate::settings::tests::env_in;

/// A project that has been installed into: a manifest, a record naming the
/// root it was written under, a package the person keeps locally and a
/// private env file. What a reconnection must leave exactly as it is.
fn installed_project(root: &Path) {
    std::fs::create_dir_all(root.join(".claude/skills/gh")).unwrap();
    std::fs::create_dir_all(root.join(".kendex-local/skills/mine")).unwrap();
    std::fs::write(
        root.join("kendex.toml"),
        "[skills.gh]\nsource = \"kendex\"\n",
    )
    .unwrap();
    std::fs::write(
        root.join("kendex.settings.toml"),
        "[skills.gh]\nGH_HOST = \"github.com\"\n",
    )
    .unwrap();
    std::fs::write(root.join(".kendex-local/skills/mine/SKILL.md"), "mine\n").unwrap();
    std::fs::write(root.join(".env.local"), "TOKEN=secret\n").unwrap();
    std::fs::write(root.join(".claude/skills/gh/SKILL.md"), "gh\n").unwrap();
    record_at(root, root);
}

/// A record written under `recorded`, put down at `root`. Written through
/// the lock's own writer so the fixture cannot spell a record the reader
/// would not accept.
fn record_at(root: &Path, recorded: &Path) {
    let mut lock = Lock {
        version: LOCK_VERSION,
        ..Lock::default()
    };
    lock.entries.insert(
        entry_key(ItemKind::Skill, "gh", HarnessId::Claude),
        LockEntry {
            registration: None,
            name: "gh".into(),
            kind: ItemKind::Skill,
            harness: HarnessId::Claude,
            source: "kendex".into(),
            source_repo: "vanillagreencom/kendex".into(),
            method: Method::Symlink,
            installed_at: crate::clock::timestamp(),
            source_hash: "abc".into(),
            source_commit: None,
            rendered_hash: None,
            enabled: true,
            upstream_skills: None,
            emitted: Some(EmittedArtifact {
                kind: ItemKind::Skill,
                name: "gh".into(),
                paths: vec![recorded.join(".claude/skills/gh")],
            }),
            reasons: BTreeSet::from([Reason::Requested]),
        },
    );
    save(&recorded.join(LOCK_FILE), &lock).unwrap();
    if recorded != root {
        std::fs::rename(recorded.join(LOCK_FILE), root.join(LOCK_FILE)).unwrap();
    }
}

fn ignored(scope: &str, name: &str) -> IgnoredUpdate {
    IgnoredUpdate {
        scope: scope.to_owned(),
        kind: ItemKind::Skill,
        name: name.to_owned(),
        repo: "vanillagreencom/kendex".into(),
    }
}

/// The reported case: a folder renamed outside kendex. The entry points at
/// the new folder, everything installed there is untouched, and the record
/// reads at its new place with its positions rebased.
#[test]
fn a_renamed_folder_reconnects_without_touching_what_is_installed() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = env_in(&home);
    let old = home.join("dev/vsys-view");
    std::fs::create_dir_all(&old).unwrap();
    installed_project(&old);
    let registered = crate::settings::register_project(&env, &old)
        .unwrap()
        .0
        .projects[0]
        .clone();
    let new = home.join("dev/vsys");
    std::fs::rename(&old, &new).unwrap();

    let (plan, settings, _) = relocate_project(&env, &registered, &new, false).unwrap();

    assert_eq!(plan.standing, Standing::Moved);
    assert_eq!(settings.projects, [crate::paths::canonical(&new).unwrap()]);
    assert_eq!(
        crate::settings::load(&env).unwrap().projects,
        settings.projects,
        "and the file on disk says the same"
    );
    assert_eq!(
        std::fs::read_to_string(new.join(".kendex-local/skills/mine/SKILL.md")).unwrap(),
        "mine\n",
        "the local package is the person's and is not rewritten"
    );
    assert_eq!(
        std::fs::read_to_string(new.join(".env.local")).unwrap(),
        "TOKEN=secret\n"
    );
    assert_eq!(
        std::fs::read_to_string(new.join("kendex.toml")).unwrap(),
        "[skills.gh]\nsource = \"kendex\"\n"
    );
    assert_eq!(
        std::fs::read_to_string(new.join("kendex.settings.toml")).unwrap(),
        "[skills.gh]\nGH_HOST = \"github.com\"\n",
        "the package's own settings at this place are kept as they are"
    );
    let lock = crate::lock::load(&new.join(LOCK_FILE)).unwrap();
    let entry = &lock.entries[&entry_key(ItemKind::Skill, "gh", HarnessId::Claude)];
    assert_eq!(
        entry.emitted.as_ref().unwrap().paths,
        [crate::paths::canonical(&new)
            .unwrap()
            .join(".claude/skills/gh")],
        "the record reads at the new root with its positions rebased there"
    );
}

/// Looking is not moving: what the person is shown before they agree
/// leaves the registry exactly as it was.
#[test]
fn inspecting_a_folder_changes_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = env_in(&home);
    let old = home.join("proj");
    std::fs::create_dir_all(&old).unwrap();
    let registered = crate::settings::register_project(&env, &old)
        .unwrap()
        .0
        .projects[0]
        .clone();
    let new = home.join("moved");
    std::fs::rename(&old, &new).unwrap();
    let before = std::fs::read_to_string(env.settings_file()).unwrap();

    let plan = inspect(&env, &registered, &new).unwrap();

    assert_eq!(plan.standing, Standing::NoRecord);
    assert_eq!(plan.from, registered);
    assert_eq!(
        std::fs::read_to_string(env.settings_file()).unwrap(),
        before
    );
}

/// A folder holding another project's record is not this project under a
/// new name, whatever it is called. The entry stays where it was.
#[test]
fn a_folder_holding_another_projects_record_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = env_in(&home);
    let old = home.join("mine");
    std::fs::create_dir_all(&old).unwrap();
    let registered = crate::settings::register_project(&env, &old)
        .unwrap()
        .0
        .projects[0]
        .clone();
    std::fs::remove_dir(&old).unwrap();
    let other = home.join("other");
    let third = home.join("third");
    std::fs::create_dir_all(&other).unwrap();
    std::fs::create_dir_all(&third).unwrap();
    record_at(&other, &third);

    let plan = inspect(&env, &registered, &other).unwrap();
    let refused = relocate_project(&env, &registered, &other, false).unwrap_err();

    assert_eq!(
        plan.standing,
        Standing::RecordElsewhere {
            root: crate::paths::canonical(&third).unwrap()
        }
    );
    assert!(
        matches!(&refused, CoreError::ProjectRecordElsewhere { path, recorded }
            if path == &crate::paths::canonical(&other).unwrap()
                && recorded == &crate::paths::canonical(&third).unwrap()),
        "{refused:?}"
    );
    assert_eq!(crate::settings::load(&env).unwrap().projects, [registered]);
}

/// A record this build cannot read supports no claim about whose folder it
/// is, so it is said rather than waved through.
#[test]
fn a_folder_holding_an_unreadable_record_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = env_in(&home);
    let old = home.join("mine");
    std::fs::create_dir_all(&old).unwrap();
    let registered = crate::settings::register_project(&env, &old)
        .unwrap()
        .0
        .projects[0]
        .clone();
    std::fs::remove_dir(&old).unwrap();
    let other = home.join("other");
    std::fs::create_dir_all(&other).unwrap();
    std::fs::write(other.join(LOCK_FILE), "{\"version\": 1}\n").unwrap();

    let plan = inspect(&env, &registered, &other).unwrap();
    let refused = relocate_project(&env, &registered, &other, false).unwrap_err();

    assert!(
        matches!(&plan.standing, Standing::RecordUnreadable { .. }),
        "{:?}",
        plan.standing
    );
    assert!(
        matches!(&refused, CoreError::ProjectRecordUnreadable { path, .. }
            if path == &crate::paths::canonical(&other).unwrap()),
        "{refused:?}"
    );
    assert_eq!(crate::settings::load(&env).unwrap().projects, [registered]);
}

/// Everything a picked path can be that is not a folder this machine can
/// read. Each is the same answer with the system's own words in it, and
/// each leaves the entry alone.
#[test]
fn a_path_that_is_not_a_readable_folder_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = env_in(&home);
    let old = home.join("mine");
    std::fs::create_dir_all(&old).unwrap();
    let registered = crate::settings::register_project(&env, &old)
        .unwrap()
        .0
        .projects[0]
        .clone();
    std::fs::write(home.join("file.txt"), "not a folder\n").unwrap();

    for picked in [
        home.join("nothing-here"),
        home.join("file.txt"),
        // A component of the path is a file, so the read fails as
        // something other than "nothing is there".
        home.join("file.txt/inside"),
    ] {
        let plan = inspect(&env, &registered, &picked).unwrap();
        let refused = relocate_project(&env, &registered, &picked, false).unwrap_err();

        assert!(
            matches!(&plan.standing, Standing::FolderMissing { said } if !said.is_empty()),
            "{picked:?}: {:?}",
            plan.standing
        );
        assert!(
            matches!(&refused, CoreError::ProjectFolderMissing { path, .. } if path == &picked),
            "{picked:?}: {refused:?}"
        );
        assert_eq!(
            crate::settings::load(&env).unwrap().projects,
            std::slice::from_ref(&registered)
        );
    }
}

/// The folder the entry already names is not a move, and saying so is
/// better than a write that changes nothing.
#[test]
fn the_folder_the_entry_already_names_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = env_in(&home);
    let root = home.join("proj");
    std::fs::create_dir_all(&root).unwrap();
    let registered = crate::settings::register_project(&env, &root)
        .unwrap()
        .0
        .projects[0]
        .clone();

    let plan = inspect(&env, &registered, &root).unwrap();
    let refused = relocate_project(&env, &registered, &root, false).unwrap_err();

    assert_eq!(plan.standing, Standing::Unchanged);
    assert!(
        matches!(&refused, CoreError::ProjectAlreadyRegistered { path } if path == &registered),
        "{refused:?}"
    );
}

/// A destination this machine already tracks joins two entries into one.
/// It takes the person's own answer, and without it the move is refused
/// and both entries stand.
#[test]
fn an_already_registered_destination_is_joined_only_when_that_is_chosen() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = env_in(&home);
    let stale = home.join("vsys-view");
    let live = home.join("vsys");
    std::fs::create_dir_all(&stale).unwrap();
    std::fs::create_dir_all(&live).unwrap();
    installed_project(&live);
    let stale = crate::settings::register_project(&env, &stale).unwrap().2;
    let live = crate::settings::register_project(&env, &live).unwrap().2;
    crate::settings::mutate(&env, |settings| {
        settings.ignored_updates = vec![
            ignored(&crate::paths::slashed(&stale), "gh"),
            ignored(&crate::paths::slashed(&live), "gh"),
            ignored("global", "dev"),
        ];
        Ok(())
    })
    .unwrap();

    let plan = inspect(&env, &stale, &live).unwrap();
    let refused = relocate_project(&env, &stale, &live, false).unwrap_err();
    assert_eq!(plan.standing, Standing::Registered);
    assert!(
        matches!(&refused, CoreError::ProjectFolderRegistered { path } if path == &live),
        "{refused:?}"
    );
    assert_eq!(
        crate::settings::load(&env).unwrap().projects,
        [live.clone(), stale.clone()],
        "both entries stand until the choice is made"
    );

    let (_, settings, _) = relocate_project(&env, &stale, &live, true).unwrap();

    assert_eq!(
        settings.projects,
        std::slice::from_ref(&live),
        "one entry, not two"
    );
    assert_eq!(
        settings.ignored_updates,
        [
            ignored(&crate::paths::slashed(&live), "gh"),
            ignored("global", "dev")
        ],
        "and the preference each entry carried is one row, not the same row twice"
    );
    assert!(
        stale.is_dir() && live.is_dir(),
        "joining two entries deletes no folder"
    );
}

/// The machine-local answers recorded against the old folder are answers
/// about this project, and follow it. Everything else in the file is
/// somebody else's and is left alone.
#[test]
fn preferences_follow_the_project_and_nothing_else_moves() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = env_in(&home);
    let old = home.join("proj");
    let bystander = home.join("other");
    std::fs::create_dir_all(&old).unwrap();
    std::fs::create_dir_all(&bystander).unwrap();
    let old = crate::settings::register_project(&env, &old).unwrap().2;
    let bystander = crate::settings::register_project(&env, &bystander)
        .unwrap()
        .2;
    crate::settings::mutate(&env, |settings| {
        settings.zoom = 150;
        settings.appearance = crate::settings::Appearance::Dark;
        settings.ignored_updates = vec![
            ignored(&crate::paths::slashed(&old), "gh"),
            ignored(&crate::paths::slashed(&bystander), "gh"),
        ];
        Ok(())
    })
    .unwrap();
    let new = home.join("moved");
    std::fs::rename(&old, &new).unwrap();

    let (_, settings, _) = relocate_project(&env, &old, &new, false).unwrap();
    let new = crate::paths::canonical(&new).unwrap();

    assert_eq!(settings.projects, [new.clone(), bystander.clone()]);
    assert_eq!(
        settings.ignored_updates,
        [
            ignored(&crate::paths::slashed(&new), "gh"),
            ignored(&crate::paths::slashed(&bystander), "gh")
        ]
    );
    assert_eq!(settings.zoom, 150);
    assert_eq!(settings.appearance, crate::settings::Appearance::Dark);
}

/// A folder nothing registered is not a project to reconnect, and the
/// spelling the caller asked under is not searched for as one.
#[test]
fn an_entry_that_is_not_registered_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = env_in(&home);
    let new = home.join("moved");
    std::fs::create_dir_all(&new).unwrap();

    let refused = relocate_project(&env, &home.join("never-added"), &new, false).unwrap_err();

    assert!(
        matches!(&refused, CoreError::ProjectNotRegistered { path } if path == &home.join("never-added")),
        "{refused:?}"
    );
}

/// A folder that already carries a record naming itself is the same
/// project once something has applied there since the move — reconnecting
/// to it is the ordinary case, not a mismatch.
#[test]
fn a_folder_whose_record_names_itself_reconnects() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = env_in(&home);
    let old = home.join("proj");
    std::fs::create_dir_all(&old).unwrap();
    let registered = crate::settings::register_project(&env, &old).unwrap().2;
    std::fs::remove_dir(&old).unwrap();
    let new = home.join("moved");
    std::fs::create_dir_all(&new).unwrap();
    record_at(&new, &crate::paths::canonical(&new).unwrap());

    let (plan, settings, _) = relocate_project(&env, &registered, &new, false).unwrap();

    assert_eq!(plan.standing, Standing::Settled);
    assert_eq!(settings.projects, [crate::paths::canonical(&new).unwrap()]);
}

/// The reconnect answers under the spelling the registry stores, whatever
/// spelling the caller asked under.
#[test]
fn the_entry_is_matched_by_the_spelling_the_registry_stores() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    let env = env_in(&home);
    let old = home.join("proj");
    std::fs::create_dir_all(&old).unwrap();
    let registered = crate::settings::register_project(&env, &old).unwrap().2;
    let new = home.join("moved");
    std::fs::rename(&old, &new).unwrap();

    let asked: PathBuf = format!("{}{}", old.display(), std::path::MAIN_SEPARATOR).into();
    let (plan, _, _) = relocate_project(&env, &asked, &new, false).unwrap();

    assert_eq!(plan.from, registered);
}
