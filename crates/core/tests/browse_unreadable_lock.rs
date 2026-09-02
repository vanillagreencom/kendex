//! What a source offers is a fact about the source, so a project whose lock
//! this build cannot read still lists every catalog it subscribes to.
//!
//! The lock only answers what is already installed here. Loading it as a
//! precondition of listing meant one project's damaged or older-generation
//! record hid every package on the Packages tab while the Subscribed tab,
//! which never reads the lock, went on counting the same catalogs. The rows
//! come through with their installed state answered as unknown — never
//! guessed as available, which would offer an install the engine refuses
//! for the same unreadable record.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::Path;

use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, Scope};
use kendex_core::source::browse::{self, Catalog, InstallState};

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    lock_path: std::path::PathBuf,
}

impl Fixture {
    fn manifest_path(&self) -> std::path::PathBuf {
        kendex_core::manifest::manifest_path(&self.env, &self.scope)
    }
}

#[allow(clippy::unwrap_used)]
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// A project subscribed to one local catalog offering a single skill, with
/// no lock written yet.
#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("dev/app");
    let source = home.join("catalog");
    put(
        &source.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: work a pull request\n---\n\nBody.\n",
    );
    put(
        &source.join("kendex.toml"),
        "[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"gh\"]\n",
    );
    put(
        &project.join("kendex.toml"),
        &format!(
            "schema = {}\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n",
            kendex_core::manifest::MANIFEST_SCHEMA,
            source.display()
        ),
    );
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        lock_path: project.join(".kendex-lock.json"),
        _tmp: tmp,
    }
}

fn catalog(scope: &Scope) -> Catalog {
    Catalog::Subscription {
        scope: scope.clone(),
        source: "cat".to_owned(),
    }
}

#[allow(clippy::unwrap_used)]
fn offered(f: &Fixture) -> Vec<(String, InstallState)> {
    browse::packages(&f.env, &catalog(&f.scope))
        .unwrap()
        .into_iter()
        .map(|package| (package.name, package.state))
        .collect()
}

#[allow(clippy::unwrap_used)]
fn members(f: &Fixture) -> Vec<(String, InstallState)> {
    browse::bundle(&f.env, &catalog(&f.scope), "starter")
        .unwrap()
        .members
        .into_iter()
        .map(|member| (member.name, member.state))
        .collect()
}

/// The control the degraded read is measured against: with a readable
/// record, nothing installed reads as available.
#[test]
#[allow(clippy::unwrap_used)]
fn a_readable_lock_answers_the_state_it_records() {
    let f = fixture();
    assert_eq!(
        offered(&f),
        [("gh".to_owned(), InstallState::Available)],
        "a scope with no lock on disk has an empty one, not an unreadable one"
    );
}

/// A record an older kendex wrote. Nothing converts it, and the Problems
/// page is where it is explained — but the catalog is still readable, so
/// its packages are still listed.
#[test]
#[allow(clippy::unwrap_used)]
fn an_older_generation_lock_still_lists_what_the_catalog_offers() {
    let f = fixture();
    fs::write(&f.lock_path, r#"{"version":1,"entries":{}}"#).unwrap();
    assert_eq!(offered(&f), [("gh".to_owned(), InstallState::Unknown)]);
}

/// Damaged bytes reach the same answer by the same route: the read that
/// lists is not the read that judges installed state.
#[test]
#[allow(clippy::unwrap_used)]
fn a_damaged_lock_still_lists_what_the_catalog_offers() {
    let f = fixture();
    fs::write(&f.lock_path, "{not json").unwrap();
    assert_eq!(offered(&f), [("gh".to_owned(), InstallState::Unknown)]);
}

/// One project's unreadable record is that project's alone — a second
/// scope subscribed to the same catalog answers exactly as before.
#[test]
#[allow(clippy::unwrap_used)]
fn another_scope_reading_the_same_catalog_is_untouched() {
    let broken = fixture();
    fs::write(&broken.lock_path, "{not json").unwrap();
    let healthy = fixture();

    assert_eq!(offered(&broken), [("gh".to_owned(), InstallState::Unknown)]);
    assert_eq!(
        offered(&healthy),
        [("gh".to_owned(), InstallState::Available)]
    );
}

/// A curated set's members answer through the same record, so the set page
/// says the same thing the table does rather than reading an unreadable
/// lock as "nothing installed here".
#[test]
#[allow(clippy::unwrap_used)]
fn a_curated_sets_members_are_unknown_rather_than_available() {
    let f = fixture();
    assert_eq!(
        members(&f),
        [("gh".to_owned(), InstallState::Available)],
        "the control: a readable record answers what it records"
    );

    fs::write(&f.lock_path, "{not json").unwrap();
    assert_eq!(members(&f), [("gh".to_owned(), InstallState::Unknown)]);
}

/// The manifest can say a member was removed on purpose without the lock,
/// but the row it draws offers Restore, and a restore lands on the record
/// this read could not open. So the unreadable lock answers first for every
/// member the catalog still offers: no standing claimed, no button offered.
#[test]
#[allow(clippy::unwrap_used)]
fn a_suppressed_member_under_an_unreadable_lock_offers_no_restore() {
    let f = fixture();
    let manifest = fs::read_to_string(f.manifest_path()).unwrap();
    put(
        &f.manifest_path(),
        &format!("{manifest}\n[suppressed]\nskill = [\"gh\"]\n"),
    );
    assert_eq!(
        members(&f),
        [("gh".to_owned(), InstallState::RemovedByYou)],
        "the control: with a readable record, their choice is theirs to see"
    );

    fs::write(&f.lock_path, "{not json").unwrap();
    assert_eq!(members(&f), [("gh".to_owned(), InstallState::Unknown)]);
}

/// The page a Packages row opens reads the same standing the row showed,
/// so it can withhold its Install for the same reason the row withheld
/// one — rather than offering a button the engine refuses on that record.
#[test]
#[allow(clippy::unwrap_used)]
fn the_package_page_carries_the_same_unknown_the_row_showed() {
    let f = fixture();
    let preview = |f: &Fixture| {
        browse::package_preview(&f.env, &catalog(&f.scope), ItemKind::Skill, "gh")
            .unwrap()
            .state
    };
    assert_eq!(preview(&f), InstallState::Available);

    fs::write(&f.lock_path, "{not json").unwrap();
    assert_eq!(preview(&f), InstallState::Unknown);
}
